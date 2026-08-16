import XCTest
import AgentCore
@testable import Kist

/// Regression pins for Codex P1-C: "Reuse the budget across provider substitution."
///
/// `--budget` (token cap) and `--max-cost` (dollar cap) are documented as HARD ceilings for the
/// ENTIRE run. The read-only one-shot path (`runReadOnlyOneShot`) runs a first attempt and, when a
/// safe-to-replay attempt fails, retries ONCE on a substitute provider. The bug: the retry loop was
/// built with a FRESH `opts.makeBudget()` ledger, so a first attempt could burn ~all of the cap,
/// fail, and the substitute would then spend the full cap AGAIN — one command spending the ceiling
/// twice.
///
/// The fix constructs the ledger EXACTLY ONCE (`runBudget`) before the first attempt and threads the
/// SAME instance into both loops. `BudgetLedger` is an actor (reference type), so the depleted `spent`
/// carries across attempts.
///
/// Two layers of coverage:
///   1. BEHAVIORAL — a shared depleted ledger denies the substitute's spend; a fresh one would allow
///      a second full cap. This proves the INVARIANT the fix relies on.
///   2. SOURCE-LEVEL — pins the single construction site and per-loop-site threading in the real
///      source so a future edit can't silently reintroduce the double-spend. Multi-site discipline:
///      one named assertion per loop call site (first attempt + substitution retry).
final class ReadOnlyPolicyBudgetReuseTests: XCTestCase {

    // MARK: - Source resolution (same idiom as CaptainSelfHealDispatchTests)

    private func repoRoot() -> String {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent(
                "Sources/Kist/KistRunner+ReadOnlyPolicy.swift").path
            if FileManager.default.fileExists(atPath: candidate) { return url.path }
            url.deleteLastPathComponent()
        }
        return FileManager.default.currentDirectoryPath
    }

    private func readOnlyPolicySource() throws -> String {
        try String(
            contentsOfFile: repoRoot() + "/Sources/Kist/KistRunner+ReadOnlyPolicy.swift",
            encoding: .utf8)
    }

    /// Extract only the `runReadOnlyOneShot` function body so the source assertions can't be fooled by
    /// a `makeBudget()` call that lives in some unrelated helper elsewhere in the file.
    private func runReadOnlyOneShotBody() throws -> String {
        let src = try readOnlyPolicySource()
        guard let start = src.range(of: "func runReadOnlyOneShot(") else {
            XCTFail("could not locate runReadOnlyOneShot in the read-only policy source")
            return ""
        }
        // Bound the slice at the next top-level `static func` so we only inspect this one function.
        let after = src[start.upperBound...]
        if let next = after.range(of: "\n    static func ") {
            return String(after[..<next.lowerBound])
        }
        return String(after)
    }

    // MARK: - 1. BEHAVIORAL: the shared depleted ledger blocks a second full cap

    /// The core invariant. A first attempt reserves+commits ~all of the token cap and fails. If the
    /// retry SHARES that ledger, its reservation for a fresh full-cap spend is DENIED (the ceiling is
    /// already depleted). A brand-new ledger (the bug) would happily grant the same cap again.
    func testSharedLedgerDeniesSecondFullCapAfterDepletion() async {
        let cap = 100_000

        // Shared ledger — the fixed behavior. First attempt spends the whole cap and "fails".
        let shared = BudgetLedger(maxTokens: cap)
        guard let r1 = await shared.reserve(tokens: cap, usd: 0) else {
            return XCTFail("first attempt should fit within a fresh cap")
        }
        await shared.commit(reservation: r1, actualTokens: cap, actualUSD: 0)
        let exceededAfterFirst = await shared.isExceeded()
        XCTAssertTrue(exceededAfterFirst,
                      "first attempt burning the full cap must exhaust the shared ledger")

        // Substitution retry draws from the SAME (now-depleted) instance → its full-cap spend is DENIED.
        let retryReservation = await shared.reserve(tokens: cap, usd: 0)
        XCTAssertNil(retryReservation,
                     "substitution retry must NOT be granted a second full cap on the shared ledger — "
                     + "the hard ceiling is for the whole run, not per attempt")

        // Sanity on the bug's shape: a FRESH ledger (what the old code built for the retry) WOULD grant
        // the same cap again. This is exactly the double-spend the fix removes.
        let freshBugLedger = BudgetLedger(maxTokens: cap)
        let bugReservation = await freshBugLedger.reserve(tokens: cap, usd: 0)
        XCTAssertNotNil(bugReservation,
                        "control: a fresh per-retry ledger (the bug) grants a full second cap — "
                        + "demonstrating why the ledger must be shared, not reconstructed")
    }

    /// Same invariant on the DOLLAR cap (`--max-cost`), since either cap independently halts the run.
    func testSharedLedgerDeniesSecondFullCostCapAfterDepletion() async {
        let capUSD = 5.0

        let shared = BudgetLedger(maxUSD: capUSD)
        guard let r1 = await shared.reserve(tokens: 0, usd: capUSD) else {
            return XCTFail("first attempt should fit within a fresh dollar cap")
        }
        await shared.commit(reservation: r1, actualTokens: 0, actualUSD: capUSD)
        let exceeded = await shared.isExceeded()
        XCTAssertTrue(exceeded, "spending the full dollar cap must exhaust the shared ledger")

        let retry = await shared.reserve(tokens: 0, usd: capUSD)
        XCTAssertNil(retry,
                     "substitution retry must NOT be granted a second full dollar cap on the shared ledger")
    }

    // MARK: - 2. SOURCE-LEVEL: single construction, threaded into both sites

    /// EXACTLY ONE ledger construction (`opts.makeBudget()`) in the whole one-shot function. Two
    /// occurrences means a fresh ledger is being built for the retry again — the P1-C regression.
    func testExactlyOneBudgetConstructionSite() throws {
        let body = try runReadOnlyOneShotBody()
        let occurrences = body.components(separatedBy: "opts.makeBudget()").count - 1
        XCTAssertEqual(occurrences, 1,
                       "runReadOnlyOneShot must construct the run budget EXACTLY once (found "
                       + "\(occurrences)); a second opts.makeBudget() re-arms the hard cap for the retry")
        XCTAssertTrue(body.contains("let runBudget = opts.makeBudget()"),
                      "the single ledger must be bound to `runBudget` before the first attempt")
    }

    /// SITE 1 — first-attempt loop threads the shared `runBudget`, not a fresh ledger.
    func testFirstAttemptLoopUsesSharedRunBudget() throws {
        let body = try runReadOnlyOneShotBody()
        // The first `budget:` argument after the construction must reference runBudget.
        XCTAssertTrue(body.contains("budget: runBudget, planMode: opts.planMode"),
                      "SITE 1 (first-attempt makeLoop) must pass `budget: runBudget` — the shared ledger")
    }

    /// SITE 2 — substitution retry loop threads the SAME `runBudget`, and must NOT reconstruct one.
    func testSubstitutionRetryLoopUsesSharedRunBudget() throws {
        let body = try runReadOnlyOneShotBody()
        guard let retryRange = body.range(of: "let retryLoop = makeLoop(") else {
            XCTFail("SITE 2: could not locate the substitution retry loop (retryLoop = makeLoop)")
            return
        }
        let retryBranch = String(body[retryRange.lowerBound...])
        XCTAssertTrue(retryBranch.contains("budget: runBudget"),
                      "SITE 2 (substitution retry makeLoop) must pass `budget: runBudget` — the SAME "
                      + "depleted ledger as the first attempt")
        XCTAssertFalse(retryBranch.contains("opts.makeBudget()"),
                       "SITE 2 must NOT reconstruct a ledger with opts.makeBudget() — that re-arms the "
                       + "cap and lets one command spend the ceiling twice (Codex P1-C)")
    }
}
