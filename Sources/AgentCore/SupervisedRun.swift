import Foundation

/// One SUPERVISED agent pass — where the Stage 1 trust spine BITES on a real run. An agent executes in
/// its OWN git worktree, the supervisor commits the deliverable, and the Foreman inspects the REAL
/// artifacts (committed `base...HEAD` diff + the worktree's `test.sh` exit code) → seals a forge-proof
/// signoff on a measured green, or returns an honest block.
///
/// SPAWN-AGNOSTIC by design (the same seam the whole port preserves): `work` is the agent — a
/// `PlanExecuteLoop` rooted at the worktree in production, a file-writing closure in tests — so this
/// orchestrator never couples to the loop's internals. The supervisor owns isolation + commit + verify;
/// the agent owns only "leave your deliverable in this worktree."
///
/// Stage 1.6b. LABEL: PROTOTYPE.
public struct SupervisedOutcome: Sendable {
    /// The agent's worktree. nil iff isolation could not be created (not a git repo / git absent).
    public let worktree: GitWorktree?
    /// What the agent's `work` closure returned (its own success signal — ADVISORY; the Foreman, not
    /// this flag, decides whether the work is trustworthy).
    public let workSucceeded: Bool
    /// Whether the deliverable committed (false ⇒ no real change ⇒ the Foreman blocks on diff).
    public let committed: Bool
    /// The verify-and-sign verdict + measured evidence. nil iff no worktree.
    public let report: ForemanReport?

    public init(worktree: GitWorktree?, workSucceeded: Bool, committed: Bool, report: ForemanReport?) {
        self.worktree = worktree; self.workSucceeded = workSucceeded
        self.committed = committed; self.report = report
    }

    /// True only on a sealed, measured green (the agent's branch is mergeable).
    public var isGreen: Bool { report?.isGreen ?? false }
}

public enum SupervisedRun {

    /// Isolate → run the agent → commit → VERIFY-AND-SIGN.
    ///
    /// - Parameters:
    ///   - repo:          the source repo to branch a worktree from.
    ///   - goalID:        the fleet goal / baton identity this signoff certifies.
    ///   - subjectID:     the agent identity the signoff covers.
    ///   - title:         human label (worktree slug + signoff summary).
    ///   - scopeGlobs:    the agent's declared file lease (record-only unless the Foreman is lease-required).
    ///   - commitMessage: the supervisor's commit message for the deliverable.
    ///   - nowEpoch:      caller-supplied clock (deterministic; never Date() here).
    ///   - foreman:       the verify-and-sign engine (holds the ledger). Inject a fake-seam Foreman in
    ///                    unit tests; a default `Foreman(ledger:)` uses the REAL git/test seams.
    ///   - keepWorktree:  keep the worktree on disk (a green branch must survive for the merge gate).
    ///                    Pass false to discard immediately (e.g. tests, or a rejected throwaway).
    ///   - work:          THE AGENT. Receives its worktree; leaves its deliverable there; returns its own
    ///                    success signal (advisory). In production this builds + runs a PlanExecuteLoop
    ///                    rooted at `wt.path`.
    @discardableResult
    public static func run(
        repo: String,
        goalID: String,
        subjectID: UUID = UUID(),
        title: String = "agent",
        scopeGlobs: [String] = [],
        commitMessage: String = "fleet: agent deliverable",
        nowEpoch: Double,
        foreman: Foreman,
        keepWorktree: Bool = true,
        work: (GitWorktree) async -> Bool
    ) async -> SupervisedOutcome {
        guard let wt = GitIsolation.makeWorktree(repo: repo, label: title, nowEpoch: nowEpoch) else {
            return SupervisedOutcome(worktree: nil, workSucceeded: false, committed: false, report: nil)
        }
        let ok = await work(wt)
        // The supervisor commits the agent's deliverable. No change ⇒ commit fails ⇒ the Foreman sees no
        // diff and blocks honestly (never a false green for a no-op run).
        let committed = GitIsolation.commit(wt, message: commitMessage)
        let subject = ForemanSubject(agentID: subjectID, branch: wt.branch, worktreePath: wt.path,
                                     baseSHA: wt.base, scopeGlobs: scopeGlobs, title: title)
        let report = await foreman.inspect(subject: subject, goalID: goalID, nowEpoch: nowEpoch)
        if !keepWorktree { GitIsolation.discard(wt) }
        return SupervisedOutcome(worktree: wt, workSucceeded: ok, committed: committed, report: report)
    }
}
