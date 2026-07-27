import Foundation

/// The VERIFY-AND-SIGN half of the fleet captain. The foreman REFUSES to accept an agent's surrender
/// ("done") until it has VERIFIED the work over MEASURED evidence and SIGNED OFF on it. A claimed-done
/// STRING can never sign off — only a deterministic GREEN judge over real artifacts mints a sealed signoff.
///
/// THE GATE (in order):
///   1. committed?    — `commitCount(wt) > 0`. No commit ⇒ the done sentinel lied ⇒ not done (claimedDone
///                      stays true so the missing-evidence blockers fire honestly, never a false green).
///   2. diff present? — committed diff (base...HEAD) non-empty. An empty diff cannot be green.
///   3. in lease?     — committed paths ⊆ canonical scopeGlobs (exact path or `<dir>/*`). Malformed raw
///                      wildcards cover nothing, so escapes surface instead of being laundered. RECORD-
///                      ONLY by default (surfaced as outOfScopePaths); the merge gate enforces it.
///   4. tests green?  — the subtask's test exit code. nil/never-run maps to a FAILING code (never green).
///   4b. tree clean?  — after the test, tracked files must still match HEAD. A green attests the committed
///                      bytes that will merge, not source rewritten by the test after commit.
///   5. file size?    — max touched-file line count ≤ 1500 via the `monolith_limit` structural blocker.
///   6. world signal? — derived PURELY from the measured test pass (WorldFacts.fromMeasuredTest), so a
///                      structurally-green subtask can reach `.green` on a real pass, never on a fail.
///
/// Then: BuildFacts (DERIVED from evidence) → GroundedVerdict.fromCode → on `.green` call
/// FleetSignoffLedger.record (the SOLE forge-proof admission path) → mint the Signoff. On non-green: NO
/// seal, REJECT, surface the failed blockers as precise corrective context for the retry path.
///
/// INJECTABLE SEAMS: every real effect (commit count, diff, changed paths, test run, review lookup,
/// claims) is a closure with a real default. Unit tests inject fakes so NO real git/shell runs.
///
/// Ported from TinkySDR's Captain (Stage 1.6a). Adaptations: AgentCell→ForemanSubject (the blackboard
/// is Stage 2); VerifyConscience→WorldFacts.fromMeasuredTest (pure, per-agent-isolated); CodexBuildID→
/// inline `buildID`; FleetMatcher for the lease (matcher==validator). @MainActor dropped (the ledger is
/// lock-guarded now). LABEL: PROTOTYPE.

/// The subject of one verify-and-sign pass — one agent's surrendered work in its worktree.
public struct ForemanSubject: Sendable, Equatable {
    public let agentID: UUID
    public let branch: String
    public let worktreePath: String
    public let baseSHA: String   // the worktree's base SHA ("" when unknown) — matches GitWorktree.base
    public let scopeGlobs: [String]
    public let title: String
    public let acceptanceCriterion: String
    public init(agentID: UUID, branch: String, worktreePath: String, baseSHA: String = "",
                scopeGlobs: [String] = [], title: String = "", acceptanceCriterion: String = "") {
        self.agentID = agentID
        self.branch = branch
        self.worktreePath = worktreePath
        self.baseSHA = baseSHA
        self.scopeGlobs = scopeGlobs
        self.title = title
        self.acceptanceCriterion = acceptanceCriterion
    }
}

/// The foreman's measured findings + verdict for one agent's surrender. `signoff` is non-nil ONLY on a
/// sealed `.green`.
public struct ForemanReport: Equatable, Sendable {
    public let agentID: UUID
    public let branch: String
    public let verdict: CaptainJudgment.Verdict
    /// Precise corrective context (failed structural blocker ids) for the retry path — empty on green.
    public let failedBlockers: [String]
    /// Why, in one human-readable line (drift reason or "all invariants hold").
    public let evidence: String
    public let testExitCode: Int32
    public let changedLines: Int
    public let maxFileLines: Int
    /// Paths the agent touched OUTSIDE its lease (record-only by default — surfaced, not yet blocking).
    public let outOfScopePaths: [String]
    /// The sealed signoff — present iff `verdict == .green` AND the ledger admitted it.
    public let signoff: Signoff?

    public init(agentID: UUID, branch: String, verdict: CaptainJudgment.Verdict, failedBlockers: [String],
                evidence: String, testExitCode: Int32, changedLines: Int, maxFileLines: Int,
                outOfScopePaths: [String], signoff: Signoff?) {
        self.agentID = agentID; self.branch = branch; self.verdict = verdict
        self.failedBlockers = failedBlockers; self.evidence = evidence; self.testExitCode = testExitCode
        self.changedLines = changedLines; self.maxFileLines = maxFileLines
        self.outOfScopePaths = outOfScopePaths; self.signoff = signoff
    }

    public var isGreen: Bool { verdict == .green && signoff != nil }
}

/// Derives BuildFacts from REAL seams, runs the deterministic referee, and on a real green seals a
/// signoff into the fleet's forge-proof ledger. Pure logic; all I/O is behind injected closures.
/// `@unchecked Sendable` justified: the only stored mutable collaborator (the ledger) is itself
/// lock-guarded; the seam closures are call-only.
public final class Foreman: @unchecked Sendable {

    // MARK: - Injected seams (real defaults; tests inject fakes)

    private let commitCount: (_ wt: GitWorktree) -> Int
    private let diff: (_ wt: GitWorktree) -> String
    private let changedPaths: (_ wt: GitWorktree) -> [String]
    private let maxFileLines: (_ wt: GitWorktree, _ changed: [String]) -> Int
    private let runTests: (_ wt: GitWorktree) async -> Int32?
    /// Run a HELD-OUT suite (one the agent could not read or write) for the reward-hacking gap check.
    /// Returns its exit code (0 = pass), or nil = no held-out suite provisioned ⇒ the guard ABSTAINS (it
    /// never invents a gap it couldn't measure). Default nil — provisioning a held-out suite is a separate
    /// concern wired by the orchestrator; the guard + gate are live regardless.
    ///
    /// ⚠️ WIRING CONTRACT (Codex): this closure runs AFTER the `trackedDirty` tree-integrity gate, so a
    /// runner that MUTATES tracked files would not be re-caught before signoff. Any real runner MUST be
    /// READ-ONLY w.r.t. tracked files (run a held-out suite in a throwaway copy / restore before returning).
    /// If a future runner cannot guarantee that, add a SECOND trackedDirty check after this gate.
    private let runHeldOutTests: ((_ wt: GitWorktree) async -> Int32?)?
    /// TRACKED files dirty vs HEAD — sampled AFTER the test run to detect a test that MUTATED the
    /// committed snapshot it was supposed to verify (the TOCTOU forge gap). Default = real git.
    private let trackedDirty: (_ wt: GitWorktree) -> [String]
    private let codexReviewed: (_ buildID: String) -> Bool
    private let readClaims: (_ wt: GitWorktree) -> AgentClaims?
    private let claimEvidence: (_ wt: GitWorktree) -> (files: [String], diff: String)

    private let ledger: FleetSignoffLedger
    private let captain: SymbolicCaptain
    private let leaseRequired: Bool
    private let claimsRequired: Bool
    private let acceptanceTestRequired: Bool

    /// The fleet referee: the full structural rules MINUS `done_needs_codex`. A fleet agent's per-subtask
    /// signoff gates on MEASURED evidence only (tests pass + non-empty diff + in-lease + file size); code
    /// review belongs on the integration→main promotion (downstream of merge), never per-agent. With the
    /// full ruleset every agent would be .blocked on done_needs_codex → sign 0/N. This restores function
    /// WITHOUT weakening forge-proofing: `.green` still requires a real green judge.
    public static var fleetCaptain: SymbolicCaptain {
        SymbolicCaptain(structural: CaptainRuleSet.structural.filter { $0.id != "done_needs_codex" })
    }

    public init(ledger: FleetSignoffLedger,
                captain: SymbolicCaptain = Foreman.fleetCaptain,
                leaseRequired: Bool = false,
                claimsRequired: Bool = false,
                acceptanceTestRequired: Bool = false,
                // Operator opt-in to trust an IN-REPO verifier (base-trusted test.sh / .kist/test-command /
                // structural swift-test/npm). DEFAULT FALSE — the only adversarial-safe verifier is the
                // held-out operator oracle (~/.kist/test-command), because a shell harness can transitively
                // execute ANY agent-modified file. False ⇒ verify via the oracle only, else fail closed.
                allowWorktreeHarness: Bool = false,
                commitCount: ((GitWorktree) -> Int)? = nil,
                diff: ((GitWorktree) -> String)? = nil,
                changedPaths: ((GitWorktree) -> [String])? = nil,
                maxFileLines: ((GitWorktree, [String]) -> Int)? = nil,
                runTests: ((GitWorktree) async -> Int32?)? = nil,
                runHeldOutTests: ((GitWorktree) async -> Int32?)? = nil,
                trackedDirty: ((GitWorktree) -> [String])? = nil,
                codexReviewed: ((String) -> Bool)? = nil,
                readClaims: ((GitWorktree) -> AgentClaims?)? = nil,
                claimEvidence: ((GitWorktree) -> (files: [String], diff: String))? = nil) {
        self.ledger = ledger
        self.captain = captain
        self.leaseRequired = leaseRequired
        self.claimsRequired = claimsRequired
        self.acceptanceTestRequired = acceptanceTestRequired
        self.commitCount = commitCount ?? { wt in Foreman.realCommitCount(wt) }
        // COMMITTED measurement (base...HEAD = what will MERGE), not the transient working tree.
        self.diff = diff ?? { wt in GitIsolation.committedDiff(wt) }
        self.changedPaths = changedPaths ?? { wt in GitIsolation.committedChangedPaths(wt) }
        self.maxFileLines = maxFileLines ?? { wt, changed in Foreman.realMaxFileLines(wt, changed) }
        // Orthogonal union (council-verified 2026-07-03): c7's allowWorktreeHarness gates ONLY the visible
        // realRunTests harness (TOCTOU-closed); main's runHeldOutTests is a SEPARATE advisory oracle closure
        // (nil ⇒ abstains). Different execution paths — combining them reopens no trust hole.
        let allowHarness = allowWorktreeHarness
        self.runTests = runTests ?? { wt in await Foreman.realRunTests(wt, allowWorktreeHarness: allowHarness) }
        self.runHeldOutTests = runHeldOutTests   // nil ⇒ guard abstains (no held-out suite provisioned)
        self.trackedDirty = trackedDirty ?? { wt in GitIsolation.trackedDirtyFiles(wt) }
        self.codexReviewed = codexReviewed ?? { _ in false }
        self.readClaims = readClaims ?? { wt in
            let url = URL(fileURLWithPath: (wt.path as NSString).appendingPathComponent(".fleet-claims.json"))
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ClaimReconciler.parse(body)
        }
        self.claimEvidence = claimEvidence ?? { wt in
            (GitIsolation.committedOnlyChangedPaths(wt), GitIsolation.committedOnlyDiff(wt))
        }
    }

    /// Canonical per-agent build identity: each fleet member is a distinct build, so its measured
    /// world-signal is isolated. The agent's STABLE uuidString (NOT hashValue, which is per-process
    /// randomized) goes in the project component so the buildID is reproducible across restarts.
    public static func buildID(goalID: String, agentID: UUID, turnNumber: Int, claimHash: Int) -> String {
        "\(goalID)#\(agentID.uuidString)@t\(turnNumber)#\(claimHash)"
    }

    // MARK: - The verify-and-sign gate

    /// Inspect one agent's surrender, judge it over MEASURED evidence, and — only on a real deterministic
    /// GREEN — seal a signoff into the ledger. NEVER signs off on a non-green; a forged "done" cannot
    /// enter the chain because `record` is the sole admission path and only admits a refereed `.green`.
    public func inspect(subject: ForemanSubject,
                        goalID: String,
                        turnNumber: Int = 0,
                        claimHash: Int = 0,
                        nowEpoch: Double) async -> ForemanReport {

        // GATE 0 — MANDATORY LEASE (flag-gated, default off). A subtask with no declared scope can't be
        // verified disjoint from its crew, so a mandatory-lease fleet REFUSES it — before any measurement.
        if leaseRequired && subject.scopeGlobs.isEmpty {
            return ForemanReport(
                agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                failedBlockers: ["done_needs_lease"],
                evidence: "no declared file lease — a mandatory-lease fleet refuses to sign an unscoped agent",
                testExitCode: -1, changedLines: 0, maxFileLines: 0, outOfScopePaths: [], signoff: nil)
        }

        let wt = GitWorktree(repo: "", path: subject.worktreePath, branch: subject.branch, base: subject.baseSHA)
        let buildID = Foreman.buildID(goalID: goalID, agentID: subject.agentID,
                                      turnNumber: turnNumber, claimHash: claimHash)

        // GATE 1 — committed? An agent that dropped done without committing has no deliverable.
        let commits = commitCount(wt)

        // GATE 2 — diff present? (also feeds the monolith gate's max-file measure).
        let rawDiff = diff(wt)
        let diffPresent = commits > 0 && !rawDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let changed = changedPaths(wt)
        let changedLines = diffPresent ? max(1, changed.count) : 0
        let maxLines = maxFileLines(wt, changed)

        // GATE 3 — LEASE ENFORCEMENT (C10). An agent that DECLARED a file lease and committed OUTSIDE it
        // does NOT get a green: refuse at signoff, not merely record + defer to the merge gate. The merge
        // gate's off-lease refusal stays as defense in depth (multi-site discipline). This closes the hole
        // where off-lease work sealed a valid green that only the merge gate held back — and it applies to
        // single-agent fleets too (fixing the prior count>1-only enforcement). An unscoped agent (empty
        // lease) is governed by GATE 0 / mandatory-lease, not here.
        let outOfScope = Self.outOfScopePaths(changed: changed, scopeGlobs: subject.scopeGlobs)
        if !subject.scopeGlobs.isEmpty && !outOfScope.isEmpty {
            return ForemanReport(
                agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                failedBlockers: ["out_of_lease"],
                evidence: "committed \(outOfScope.count) file(s) outside its declared lease ("
                    + outOfScope.prefix(5).joined(separator: ", ")
                    + ") — refused at signoff, not deferred to the merge gate",
                testExitCode: -1, changedLines: changedLines, maxFileLines: maxLines,
                outOfScopePaths: outOfScope, signoff: nil)
        }

        // GATE 4 — tests green? A missing exit code maps to a FAILING one (absence is never a pass).
        let exitCode = await runTests(wt) ?? 1
        let testEvidence = TestRunEvidence(exitCode: exitCode)

        // GATE 4b — TREE INTEGRITY (Codex HIGH): the green must attest the COMMITTED snapshot, not a
        // snapshot the test mutated. If the test left TRACKED files dirty vs HEAD, it ran against
        // (or rewrote to) bytes that differ from what will MERGE — the pass is untrustworthy. Refuse it
        // (the caller's contract is a committed, clean deliverable before inspect; SupervisedRun commits
        // first, so only a test that mutates tracked source trips this). Untracked artifacts are tolerated.
        let mutated = trackedDirty(wt)
        if !mutated.isEmpty {
            return ForemanReport(
                agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                failedBlockers: ["tree_dirty_after_test"],
                evidence: "the test run left tracked files modified vs the committed snapshot ("
                    + mutated.prefix(5).joined(separator: ", ")
                    + ") — the pass attests bytes that differ from what would merge; refused",
                testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                outOfScopePaths: Self.outOfScopePaths(changed: changed, scopeGlobs: subject.scopeGlobs),
                signoff: nil)
        }

        // Build the DERIVED facts (GATE 5 monolith_limit is checked inside the rules; GATE 6 world-signal
        // is the pure measured-test mapping).
        let diffEvidence = DiffEvidence(changedLines: changedLines, maxFileLines: maxLines)
        let build = BuildFacts(
            buildID: buildID,
            claimedDone: true,                    // the agent surrendered (dropped done)
            tests: testEvidence,
            diff: diffEvidence,
            codex: CodexEvidence(reviewed: codexReviewed(buildID)),
            stepCapHit: false,
            runIncomplete: false)
        let facts = CaptainFacts(build: build, world: WorldFacts.fromMeasuredTest(exitCode: exitCode))

        // REFEREE — the sole green-minting path. A bragging caller cannot reach here.
        let grounded = GroundedVerdict.fromCode(facts, captain: captain)
        let judgment = captain.judge(facts)   // for the precise failed-blocker context

        // ANTI-HALLUCINATION: reconcile what the agent CLAIMED against the MEASURED (committed-only)
        // artifacts. A CONTRADICTED claim BLOCKS the signoff even if the referee was green. A claim only
        // ever makes the gate STRICTER, never looser.
        if let claims = readClaims(wt) {
            let ev = claimEvidence(wt)
            let findings = ClaimReconciler.reconcile(
                claims: claims, committedFiles: ev.files, diffText: ev.diff, testExitCode: exitCode)
            if !findings.isEmpty {
                return ForemanReport(
                    agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                    failedBlockers: findings.map { "claim_\($0.kind)" },
                    evidence: "HALLUCINATION — claims contradicted by measured evidence: "
                        + findings.map(\.detail).joined(separator: "; "),
                    testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                    outOfScopePaths: outOfScope, signoff: nil)
            }
            if claimsRequired && !claims.hasVerifiableClaim {
                return ForemanReport(
                    agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                    failedBlockers: ["claims_required"],
                    evidence: "claims file has no VERIFIABLE claim (files/symbols/tests) to reconcile — actions alone are unverifiable",
                    testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                    outOfScopePaths: outOfScope, signoff: nil)
            }
        } else if claimsRequired {
            return ForemanReport(
                agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                failedBlockers: ["claims_required"],
                evidence: "no .fleet-claims.json — a claims-required fleet won't sign work with no declared claims to reconcile",
                testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                outOfScopePaths: outOfScope, signoff: nil)
        }

        // CI INTEGRITY (ported from Terminal Captain · C1): a green test is meaningless if the agent
        // made the verifier EASIER. Block the signoff when the committed diff deletes tests, adds an
        // XCTSkip, focuses a JS suite (.only/fdescribe/fit), or makes the runner ignore failures —
        // even when the referee is green. Reads committed-only artifacts; stricter-only.
        let ciFindings = CIIntegrityGuard.inspect(committedFiles: changed, committedDiff: rawDiff)
        if !ciFindings.isEmpty {
            return ForemanReport(
                agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                failedBlockers: ciFindings.map { "ci_\($0.kind)" },
                evidence: "CI-INTEGRITY — the change weakens the verifier: " + ciFindings.map(\.detail).joined(separator: "; "),
                testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                outOfScopePaths: outOfScope, signoff: nil)
        }

        // REWARD-HACKING GAP (held-out evaluator): CI-integrity stops an agent WEAKENING the harness, but
        // not an agent satisfying the visible tests without satisfying intent (e.g. an assertion edited to
        // be vacuously true — not a delete/skip CI-integrity catches). When a HELD-OUT suite the agent
        // could not read or write FAILS while the visible suite passed, that's the test-gaming signature →
        // BLOCK. Only the genuine GAP (.blocked) blocks here; a visible-red is already handled by the
        // referee, and no held-out suite ⇒ the guard ABSTAINS (never invents an unmeasured gap).
        // NOTE (Codex): a visible-RED here returns .visibleFailed (not .blocked) and is intentionally
        // left to the referee, which blocks it via the `done_needs_tests` rule. The default fleetCaptain
        // KEEPS that rule — a custom `captain:` that drops it would need its own exitCode!=0 guard.
        // ADVISORY, NOT BLOCKING (Codex): the held-out signal (base tests vs agent code) CANNOT distinguish
        // a WEAKENED test (gaming) from a LEGITIMATELY changed/renamed API (a normal refactor that updates a
        // test — reverting it to base then fails/won't-compile on the new code). Auto-blocking would trap the
        // highest-frequency case (legit refactors). So a gap is SURFACED for human review on the green
        // signoff's evidence, never an auto-block. (A future compile-fail-vs-test-fail distinction could
        // promote it to blocking.)
        var heldOutAdvisory: String? = nil
        if let runHeldOutTests {
            let heldOutExit = await runHeldOutTests(wt)
            let gap = RewardHackingGuard.verdict(visiblePassed: exitCode == 0,
                                                 heldOutPassed: heldOutExit.map { $0 == 0 })
            if case .blocked = gap {
                heldOutAdvisory = "HELD-OUT ADVISORY: base tests (the agent could not edit) FAILED against the "
                    + "agent's code while its own suite passed — possibly a weakened test (gaming), possibly a "
                    + "legitimate API change. REVIEW before promoting; NOT auto-blocked."
            }
        }

        // ACCEPTANCE TEST (G2/TDD, flag-gated): a subtask that declared an acceptance criterion must
        // PROVE it with an added test, not just inspection.
        if acceptanceTestRequired,
           !subject.acceptanceCriterion.trimmingCharacters(in: .whitespaces).isEmpty,
           !ClaimReconciler.addsATest(committedDiff: claimEvidence(wt).diff) {
            return ForemanReport(
                agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                failedBlockers: ["acceptance_test_missing"],
                evidence: "declared acceptance criterion “\(subject.acceptanceCriterion)” but the commit adds NO test proving it",
                testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                outOfScopePaths: outOfScope, signoff: nil)
        }

        // On a real GREEN, SEAL it. record() re-checks admissibility and only admits a refereed code-green.
        // A report is not allowed to say `.green` unless a sealed signoff exists; if the ledger refuses
        // or persistence fails, the safe outcome is blocked.
        if grounded.verdict == .green {
            let evidence = FleetSignoffEvidence(
                buildID: buildID, testExitCode: exitCode, changedLines: changedLines,
                maxFileLines: maxLines, outOfScopeCount: outOfScope.count, summary: subject.title)
            guard let entry = ledger.record(goalID: goalID, agentID: subject.agentID, branch: subject.branch,
                                            grounded: grounded, evidence: evidence, atEpoch: nowEpoch) else {
                return ForemanReport(
                    agentID: subject.agentID, branch: subject.branch, verdict: .blocked,
                    failedBlockers: ["signoff_record_failed"],
                    evidence: "referee was green, but FleetSignoffLedger refused or failed to persist the signoff — no sealed proof",
                    testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                    outOfScopePaths: outOfScope, signoff: nil)
            }
            let signoff = ledger.signoff(for: entry, atEpoch: nowEpoch)
            return ForemanReport(
                agentID: subject.agentID, branch: subject.branch, verdict: .green,
                failedBlockers: [], evidence: grounded.evidence + (heldOutAdvisory.map { " · ⚠️ " + $0 } ?? ""),
                testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
                outOfScopePaths: outOfScope, signoff: signoff)
        }

        return ForemanReport(
            agentID: subject.agentID, branch: subject.branch, verdict: grounded.verdict,
            failedBlockers: judgment.failedBlockers, evidence: grounded.evidence,
            testExitCode: exitCode, changedLines: changedLines, maxFileLines: maxLines,
            outOfScopePaths: outOfScope, signoff: nil)
    }

    // MARK: - Pure helpers (unit-tested)

    /// Changed paths NOT covered by ANY scope glob — the lease escapes. An empty `scopeGlobs` means "no
    /// lease declared", so nothing is out of scope (we don't invent violations).
    ///
    /// Only CANONICAL lease globs count as covering (Codex MED): an exact path, or a subtree `<dir>/*`.
    /// A raw wildcard the planner's FleetScopeValidator would have rejected — `*`, `*x`, `a*b`, or a
    /// partial-component `Core/Capt*` — covers NOTHING here, so its paths SURFACE as escapes instead of
    /// being silenced. A non-empty-but-all-malformed lease therefore reports every path as an escape
    /// (strict, fail-safe) rather than a dishonest `outOfScopeCount: 0` the merge gate would trust.
    public static func outOfScopePaths(changed: [String], scopeGlobs: [String]) -> [String] {
        guard !scopeGlobs.isEmpty else { return [] }
        let canonical = scopeGlobs.filter { isCanonicalLeaseGlob($0) }
        return changed.filter { path in
            !canonical.contains { glob in FleetMatcher.matches(path: path, glob: glob) }
        }
    }

    /// A lease glob is CANONICAL iff it is either an exact path (no `*`) or a subtree `<dir>/*` (a single
    /// trailing `*` immediately after a `/`, dir non-empty, no other `*`). This is exactly the grammar
    /// FleetScopeValidator canonicalizes its output to, so the Foreman's escape measure and the planner's
    /// validated lease can never diverge.
    public static func isCanonicalLeaseGlob(_ glob: String) -> Bool {
        let g = glob.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return false }
        if !g.contains("*") { return true }                      // exact path
        guard g.hasSuffix("/*") else { return false }            // the only allowed wildcard form
        let dir = String(g.dropLast(2))                          // strip "/*"
        return !dir.isEmpty && !dir.contains("*")                // "<dir>/*", dir has no further wildcard
    }

    // MARK: - Real seam defaults (IO; NOT unit-tested — tests inject fakes)

    /// Commits the branch holds beyond its base (or all of HEAD when base is unknown). Fail-soft 0.
    private static func realCommitCount(_ wt: GitWorktree) -> Int {
        let range = wt.base.isEmpty ? "HEAD" : "\(wt.base)..HEAD"
        let out = shell(["git", "-C", wt.path, "rev-list", "--count", range], cwd: wt.path)
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Largest line count among the changed files that still exist on disk. Best-effort; unreadable
    /// files contribute 0 (never blocks spuriously).
    private static func realMaxFileLines(_ wt: GitWorktree, _ changed: [String]) -> Int {
        var maxLines = 0
        for rel in changed {
            let full = (wt.path as NSString).appendingPathComponent(rel)
            guard let text = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            maxLines = max(maxLines, lines)
        }
        return maxLines
    }

    /// Resolve the verification test command from TRUSTED sources only, or nil (⇒ fail closed).
    /// CRITICAL (C7): the command is NEVER read from the agent's worktree. A fleet worker could commit
    /// `.kist/test-command: rm -rf ~` or a malicious `test.sh` and — since the verifier runs it — get
    /// arbitrary host code execution AND trivially fake its own "tests pass". So the runner is chosen only
    /// from sources the agent cannot control:
    ///   1. operator override `~/.kist/test-command` — set by the human running kist; agents can't touch $HOME.
    ///   2. base-trusted worktree harness — a `.kist/test-command` / `test.sh` PROVEN base-trusted
    ///      (in `baseTrusted`: present at the branch's base, UNCHANGED, tracked, non-symlink — see
    ///      `GitIsolation.baseTrustedFiles`). An agent-added/modified/ignored/symlinked/case-folded
    ///      harness is NOT in that set, so it is never honored.
    ///   3. structural auto-detect — `Package.swift` → `swift test`, `package.json` → `npm test`, but ONLY
    ///      when the manifest itself is base-trusted. A Swift/JS manifest is executable code the toolchain
    ///      RUNS during `test` (SwiftPM evaluates `Package.swift`; npm runs `scripts.test`), so an
    ///      agent-MODIFIED manifest is arbitrary code exec — it must be base-trusted or it is refused.
    ///   4. else nil — fail closed (an unverifiable build never reaches green).
    /// - Parameter baseTrusted: harness/manifest paths PROVEN base-trusted (allow-list). Anything not in
    ///   this set is treated as agent-authored and is NEVER honored — the resolver is trust-by-allowlist.
    static func resolveTestCommand(root: String, home: String = NSHomeDirectory(),
                                   baseTrusted: Set<String> = [],
                                   allowWorktreeHarness: Bool = false) -> ResolvedTest? {
        // 1. operator override — outside any worktree, agent-inaccessible. Read from the host, run as-is.
        //    This is the ONLY adversarial-safe verifier (the held-out oracle), so it is ALWAYS honored.
        let op = (home as NSString).appendingPathComponent(".kist/test-command")
        if let raw = try? String(contentsOfFile: op, encoding: .utf8) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return .operatorInline(line) }
        }
        // Tiers 2–3 (in-repo verifier) trust an agent-adjacent surface: a shell harness can transitively
        // execute any agent-modified file, and a manifest is executable code. They are gated behind the
        // operator's explicit opt-in; OFF ⇒ fail closed here (only the held-out oracle above verifies).
        guard allowWorktreeHarness else { return nil }
        // 2. base-trusted worktree harness — the DECISION only; the command/content is FROZEN from the base
        //    object at run time (never read from the mutable worktree path), so a post-check swap/symlink
        //    can't redirect it (TOCTOU-closed in realRunTests via GitIsolation.baseFileContent).
        if baseTrusted.contains(".kist/test-command") { return .baseCommand(rel: ".kist/test-command") }
        if baseTrusted.contains("test.sh") { return .baseScript(rel: "test.sh") }
        // 3. structural auto-detect — ONLY a base-trusted (agent-unmodified) manifest; the manifest is
        //    executable code the toolchain runs, so an agent-modified one is arbitrary code exec ⇒ refused.
        //    (realRunTests additionally POISON-checks every toolchain input a manifest could pull in.)
        if baseTrusted.contains("Package.swift") { return .structural(launch: "/usr/bin/env", args: ["swift", "test"]) }
        if baseTrusted.contains("package.json") { return .structural(launch: "/usr/bin/env", args: ["npm", "test", "--silent"]) }
        // 4. no trusted runner ⇒ fail closed.
        return nil
    }

    /// The verifier's resolved test source. A harness case carries only the DECISION (which base-trusted
    /// path); its bytes are frozen from the base git object at execution time, never read from the mutable
    /// worktree, so nothing the agent can do to the worktree after the trust check redirects the run.
    enum ResolvedTest: Equatable {
        case operatorInline(String)                       // host operator command — run verbatim
        case baseCommand(rel: String)                     // a base-trusted `.kist/test-command` (frozen)
        case baseScript(rel: String)                      // a base-trusted `test.sh` (frozen)
        case structural(launch: String, args: [String])   // manifest-native; toolchain inputs poison-checked
    }

    /// Toolchain inputs a verifier can transitively EXECUTE (a trusted `test.sh` may call `swift test` /
    /// `make` / `npm test`, each of which runs the corresponding manifest/lockfile/Makefile as code). If
    /// any such input is PRESENT (on disk OR tracked) but NOT base-trusted (agent-added or -modified), the
    /// verifier could run agent-authored code regardless of which harness was selected ⇒ POISON, fail
    /// closed. This closes the transitive-execution bypass (Codex CRITICAL) at its root.
    static func toolchainPoisoned(_ wt: GitWorktree) -> Bool {
        let inputs = ["Package.swift", "Package.resolved", "package.json", "package-lock.json",
                      "yarn.lock", "pnpm-lock.yaml", "Makefile", "makefile", "GNUmakefile"]
        let trusted = GitIsolation.baseTrustedFiles(wt, candidates: inputs)
        let tracked = Set(GitIsolation.trackedFiles(repo: wt.path))
        let fm = FileManager.default
        for name in inputs {
            let present = fm.fileExists(atPath: (wt.path as NSString).appendingPathComponent(name))
                || tracked.contains(name)
            if present && !trusted.contains(name) { return true }
        }
        return false
    }

    /// Run the resolved test command in the worktree, KERNEL-SANDBOXED (deny network egress + confine
    /// writes to the worktree), with a hard timeout. Returns its exit code, or nil (⇒ the caller maps to a
    /// FAILING code — never a silent green) on: no trusted runner, sandbox unavailable, launch error, or
    /// timeout. The verifier executes UNTRUSTED agent code (the compiled tests), so it must never run on
    /// the bare host — this closes the "verifier runs agent code unsandboxed" hole. Sandbox unavailable
    /// (e.g. no bubblewrap tier on Linux) ⇒ fail closed, never a silent unsandboxed run.
    private static func realRunTests(_ wt: GitWorktree, timeoutSeconds: Double = 300,
                                     allowWorktreeHarness: Bool = false) async -> Int32? {
        // TRUST-BY-ALLOWLIST: only a harness/manifest PROVEN base-trusted (present at base, unchanged,
        // tracked, non-symlink) may source the command — an agent cannot add/modify/ignore-plant/symlink/
        // case-fold into this set (GitIsolation.baseTrustedFiles closes all four bypass classes).
        let trusted = GitIsolation.baseTrustedFiles(
            wt, candidates: [".kist/test-command", "test.sh", "Package.swift", "package.json"])
        guard let resolved = resolveTestCommand(root: wt.path, baseTrusted: trusted,
                                                allowWorktreeHarness: allowWorktreeHarness) else { return nil }
        // Materialize the decision into a concrete command. The held-out OPERATOR oracle is trusted as-is
        // (operator-owned, agent-inaccessible) and is NOT poison-gated — what it chooses to run is the
        // operator's call. The IN-REPO tiers (frozen harness / structural) run agent-adjacent code, so they
        // are poison-gated (a present-but-not-base-trusted toolchain input ⇒ refuse) AND their content is
        // taken from the base git OBJECT and passed as an argv string (never a temp file or the worktree
        // path), so there is no on-disk artifact a watcher can swap between check and exec (TOCTOU-closed).
        let cmd: (launch: String, args: [String])
        switch resolved {
        case .operatorInline(let line):
            cmd = ("/bin/sh", ["-c", line])
        case .baseCommand(let rel), .baseScript(let rel):
            if toolchainPoisoned(wt) { return nil }
            guard let content = GitIsolation.baseFileContent(wt, rel: rel) else { return nil }
            cmd = ("/bin/sh", ["-c", content])   // frozen base bytes as argv — no swappable file
        case .structural(let l, let a):
            if toolchainPoisoned(wt) { return nil }
            cmd = (l, a)
        }
        let launch: String, args: [String]
        switch SeatbeltSandbox.wrap(launchPath: cmd.launch, args: cmd.args, root: wt.path,
                                    policy: .confined(denyNetwork: true, confineWrites: true)) {
        case .passthrough: launch = cmd.launch; args = cmd.args     // policy disabled — not our default here
        case .wrapped(let p, let a): launch = p; args = a
        case .unavailable: return nil                                // sandbox required but unavailable ⇒ fail closed
        }
        // Run in its OWN process group with a SCRUBBED environment (allow-list only — no DYLD_*/LD_*, so a
        // dylib-injection into the sandbox launcher is impossible, and no host secret leaks via env). The
        // group teardown (SIGTERM→SIGKILL over the whole PGID) reaps a forked/trapping test that a plain
        // `terminate()` on the outer process would orphan. ProcessGroupRunner.run BLOCKS — hop off the actor.
        let outcome: ProcessGroupRunner.Outcome = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let o = ProcessGroupRunner.run(
                    launchPath: launch, launchArgs: args, cwd: wt.path,
                    env: RunCommandTool.scrubbedEnvironment(),
                    timeoutSeconds: Int(timeoutSeconds.rounded()), capPerStream: 1_048_576)
                cont.resume(returning: o)
            }
        }
        // A timeout is a FAILURE, never a silent green (124 = the shell/`timeout` convention for timed-out).
        if outcome.timedOut { return 124 }
        return outcome.exitCode
    }

    @discardableResult
    private static func shell(_ argv: [String], cwd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch { return "" }
    }
}
