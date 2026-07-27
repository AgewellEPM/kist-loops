import Foundation

/// Drives the flywheel end to end. The core new logic is the CONSENSUS-REPAIR LOOP: build → test → review
/// → consensus, and on reject ACCUMULATE the blocking findings and feed them into the next build (improve,
/// don't restart blind, and don't lose an earlier blocker when a later round fails to build) until it's
/// accepted or the repair budget is exhausted. Nothing merges without passing tests AND a QUORUM of
/// completed independent reviewers clearing every blocking finding — fail-closed toward reject.
public struct FlywheelOrchestrator: Sendable {
    public let stages: FlywheelStages
    /// Repair budget: how many build→test→review→consensus cycles run before giving up. NOTE: this counts
    /// TOTAL cycles including the first (fresh) build, not just repairs.
    public let maxRounds: Int
    /// Minimum number of COMPLETED independent reviewers required to accept. Fail-closed default of 1 means
    /// zero-reviewer (timed-out / unconfigured / dropped) review results can NEVER accept. (Panel review.)
    public let minReviewers: Int

    public init(stages: FlywheelStages, maxRounds: Int = 3, minReviewers: Int = 1) {
        self.stages = stages
        self.maxRounds = max(1, maxRounds)
        self.minReviewers = max(1, minReviewers)
    }

    public func run(goal: String) async -> FlywheelResult {
        let research = await stages.research(goal: goal)
        let plan = await stages.plan(goal: goal, research: research)

        var openFindings: [ReviewFinding] = []   // accumulated, deduped — the true set still to fix
        var rounds: [FlywheelRound] = []

        for round in 1...maxRounds {
            let build = await stages.build(goal: goal, plan: plan, feedback: openFindings)
            let tests = await stages.test(build)
            // Only spend reviewers on a reviewable build; a broken build/red tests is an automatic reject
            // (its own synthetic blocker) — don't waste a review round on it.
            let reports = (build.ok && tests.passed) ? await stages.review(build, tests: tests) : []
            let verdict = consensus(build: build, tests: tests, reports: reports)
            rounds.append(FlywheelRound(round: round, build: build, tests: tests, reviews: reports, verdict: verdict))

            switch verdict {
            case .accept:
                let merge = await stages.merge(build)
                await stages.remember(FlywheelMemory(
                    goal: goal, accepted: merge.merged, rounds: round,
                    note: merge.merged ? "accepted + merged after \(round) round(s)"
                                       : "consensus accepted but merge gate refused: \(merge.note)"))
                // A merge-gate refusal is a NON-merge outcome — surface it honestly as rejected, never accepted.
                return merge.merged ? .accepted(merge, rounds: rounds)
                                    : .rejected(rounds: rounds, reason: "merge gate refused: \(merge.note)")
            case .reject(let mustFix):
                // ACCUMULATE (dedup by reviewer+issue) so a build/test failure in a later round doesn't drop
                // an earlier review blocker. Latest first, then any prior blocker not superseded.
                let carried = openFindings.filter { prior in
                    !mustFix.contains { $0.reviewer == prior.reviewer && $0.issue == prior.issue }
                }
                openFindings = mustFix + carried
            }
        }

        await stages.remember(FlywheelMemory(
            goal: goal, accepted: false, rounds: maxRounds,
            note: "gave up after \(maxRounds) repair round(s); unresolved: \(openFindings.map(\.issue).prefix(3).joined(separator: "; "))"))
        return .rejected(rounds: rounds, reason: "not accepted within \(maxRounds) repair round(s)")
    }

    /// The consensus policy — deterministic and fail-closed. A build is accepted ONLY if it built, tests
    /// pass, a QUORUM of independent reviewers COMPLETED, and NO reviewer raised a blocking finding. Anything
    /// else is a reject carrying the exact findings to fix next round. Empty/partial review ⇒ reject (a
    /// silent reviewer failure must never read as "clean").
    public func consensus(build: BuildResult, tests: TestResult, reports: [ReviewReport]) -> ConsensusVerdict {
        Self.consensus(build: build, tests: tests, reports: reports, minReviewers: minReviewers)
    }

    public static func consensus(build: BuildResult, tests: TestResult,
                                 reports: [ReviewReport], minReviewers: Int) -> ConsensusVerdict {
        if !build.ok {
            return .reject(mustFix: [ReviewFinding(reviewer: "build", severity: .critical,
                                                   issue: "build did not complete: \(build.note)", mustFix: true)])
        }
        if !tests.passed {
            return .reject(mustFix: [ReviewFinding(reviewer: "tests", severity: .critical,
                                                   issue: "tests failed: \(tests.summary)", mustFix: true)])
        }
        // QUORUM — an empty/short/incomplete review set fails CLOSED. This is the fix for "empty reviews =
        // accept": zero completed reviewers can never be read as a clean review.
        let completed = reports.filter(\.completed)
        if completed.count < max(1, minReviewers) {
            return .reject(mustFix: [ReviewFinding(reviewer: "consensus", severity: .critical,
                issue: "review quorum not met: \(completed.count)/\(max(1, minReviewers)) reviewers completed", mustFix: true)])
        }
        if reports.contains(where: { !$0.completed }) {
            let who = reports.filter { !$0.completed }.map(\.reviewer).joined(separator: ", ")
            return .reject(mustFix: [ReviewFinding(reviewer: "consensus", severity: .critical,
                issue: "reviewer(s) did not complete: \(who)", mustFix: true)])
        }
        let blocking = completed.flatMap(\.blockingFindings)
        if !blocking.isEmpty { return .reject(mustFix: blocking) }
        return .accept(reason: "built, tests green, \(completed.count) reviewer(s) completed with no blocking findings")
    }
}
