import Foundation

/// The HELD-OUT suite for the reward-hacking gap check — the IO half the RewardHackingGuard's doc called
/// "Foreman wiring". CI-integrity catches a DELETED/skipped/`.only` test; it does NOT catch an agent that
/// WEAKENS an existing test's assertion (edits it to be vacuously true) while breaking real behavior. The
/// held-out signal: run the BASE versions of the test files the agent CHANGED, against the agent's CODE.
/// If the agent weakened a test, the BASE (stronger) test fails on the agent's code while the agent's own
/// (weakened) suite passed → the visible-green/held-out-red reward-hacking signature.
///
/// SAFETY (Codex constraint on the Foreman seam): this NEVER mutates the agent's worktree — it does all
/// its work in a THROWAWAY DETACHED copy at the agent's HEAD, reverts the changed test files to base THERE,
/// runs, and discards the copy. FAIL-SAFE: a missing base, no changed tests, or ANY git hiccup ⇒ nil ⇒ the
/// guard ABSTAINS (`.noHeldOut`) — a git problem can NEVER manufacture a reward-hacking BLOCK.
///
/// Pure decision core over INJECTED git ops (real git in prod via `realGit`, stubs in tests).
public struct FleetHeldOutRunner: Sendable {
    /// The COMMITTED test files the agent changed (relative paths). Empty ⇒ no test edits ⇒ abstain.
    public let changedTestFiles: @Sendable (GitWorktree) -> [String]
    /// A throwaway DETACHED worktree at the agent's current HEAD (its committed code + tests). nil ⇒ abstain.
    /// Called once for a copied-HEAD preflight, then again for the actual base-test run so preflight side
    /// effects cannot pollute the held-out copy.
    public let makeCopyAtAgentHead: @Sendable (GitWorktree) -> GitWorktree?
    /// Revert `paths` to their version at `baseSHA` IN THE COPY (so base tests run against agent code). false ⇒ abstain.
    public let revertPathsToBase: @Sendable (GitWorktree, [String], String) -> Bool
    /// Run the suite at a worktree path → exit code (0 = pass). nil ⇒ couldn't run ⇒ abstain.
    public let runTests: @Sendable (String) async -> Int32?
    /// Remove the throwaway copy — ALWAYS called (defer), even on every abstain-after-copy path.
    public let discard: @Sendable (GitWorktree) -> Void

    public init(changedTestFiles: @escaping @Sendable (GitWorktree) -> [String],
                makeCopyAtAgentHead: @escaping @Sendable (GitWorktree) -> GitWorktree?,
                revertPathsToBase: @escaping @Sendable (GitWorktree, [String], String) -> Bool,
                runTests: @escaping @Sendable (String) async -> Int32?,
                discard: @escaping @Sendable (GitWorktree) -> Void) {
        self.changedTestFiles = changedTestFiles
        self.makeCopyAtAgentHead = makeCopyAtAgentHead
        self.revertPathsToBase = revertPathsToBase
        self.runTests = runTests
        self.discard = discard
    }

    /// The held-out exit code for `wt`, or nil = ABSTAIN (the guard then returns `.noHeldOut`, never blocks).
    public func heldOut(_ wt: GitWorktree) async -> Int32? {
        let base = wt.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }                    // no base ⇒ can't hold out ⇒ abstain
        let tests = changedTestFiles(wt)
        guard !tests.isEmpty else { return nil }                   // agent touched no tests ⇒ no test-edit gaming ⇒ abstain
        guard let probe = makeCopyAtAgentHead(wt) else { return nil } // couldn't make a safe copy ⇒ abstain
        defer { discard(probe) }
        guard let probeExit = await runTests(probe.path), probeExit == 0 else { return nil } // copied HEAD must reproduce visible green
        guard let copy = makeCopyAtAgentHead(wt) else { return nil } // couldn't make a clean held-out copy ⇒ abstain
        defer { discard(copy) }                                    // ALWAYS clean up the throwaway
        guard revertPathsToBase(copy, tests, base) else { return nil } // couldn't revert ⇒ abstain (don't run a bogus state)
        return await runTests(copy.path)                           // BASE tests vs AGENT code, in the COPY
    }

    /// A path is a test file if it lives under a `Tests`/`test` dir or its name marks it a test. Heuristic,
    /// intentionally broad — over-including a non-test file only adds it to the (read-only) held-out run.
    public static func isTestFile(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("tests/") || p.contains("/test/") || p.hasSuffix("tests.swift")
            || p.hasSuffix("test.swift") || p.hasSuffix("_test.go") || p.hasSuffix(".test.ts")
            || p.hasSuffix(".test.js") || p.hasSuffix("_test.py") || p.hasPrefix("test_")
    }

    /// Real-git implementation: throwaway detached copy + base-test checkout + ./test.sh (reusing the
    /// drained-pipe runner from FleetIntegrationVerifier). PROTOTYPE — fail-safe (abstains on any hiccup),
    /// but unproven against a LIVE fleet; keep it advisory (the Foreman's reward-hacking gate stays the
    /// only consumer) until a real fleet validates it.
    public static func realGit() -> FleetHeldOutRunner {
        FleetHeldOutRunner(
            changedTestFiles: { wt in GitIsolation.committedChangedPaths(wt).filter(isTestFile) },
            makeCopyAtAgentHead: { wt in GitIsolation.detachedWorktreeAtHead(of: wt) },
            revertPathsToBase: { copy, paths, base in GitIsolation.checkoutPaths(copy, ref: base, paths: paths) },
            runTests: { path in await FleetIntegrationVerifier.realRunTests(path) },
            discard: { copy in GitIsolation.removeWorktree(copy) }
        )
    }
}
