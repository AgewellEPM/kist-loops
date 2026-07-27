import XCTest
@testable import AgentCore

/// The flywheel's control flow + the panel-review hardening: accept only when built + tests green + a QUORUM
/// of completed reviewers with no blocking finding; on reject, ACCUMULATE blockers into the next build.
final class FlywheelOrchestratorTests: XCTestCase {

    final class StubStages: FlywheelStages, @unchecked Sendable {
        var buildOK = true
        var testsPass = true
        var mergeOK = true
        var blockingForBuilds = 0       // a blocking review for the first N builds, then clean
        var reviewersPerRound = 1       // how many COMPLETED reports the review returns
        var failBuildOnRound: Int?      // force build.ok=false on a specific build number
        var buildCount = 0
        var lastFeedback: [ReviewFinding] = []
        var reviewCalls = 0
        var remembered: FlywheelMemory?

        func research(goal: String) async -> ResearchNotes { ResearchNotes(summary: "r") }
        func plan(goal: String, research: ResearchNotes) async -> String { "plan" }
        func build(goal: String, plan: String, feedback: [ReviewFinding]) async -> BuildResult {
            buildCount += 1; lastFeedback = feedback
            let ok = (failBuildOnRound == buildCount) ? false : buildOK
            return BuildResult(branch: "b\(buildCount)", changedFiles: ["a.swift"], ok: ok,
                               note: ok ? "built" : "compile error")
        }
        func test(_ build: BuildResult) async -> TestResult {
            TestResult(passed: testsPass, summary: testsPass ? "green" : "3 failed")
        }
        func review(_ build: BuildResult, tests: TestResult) async -> [ReviewReport] {
            reviewCalls += 1
            let primary: [ReviewFinding] = buildCount <= blockingForBuilds
                ? [ReviewFinding(reviewer: "codex", severity: .high, issue: "bug in build \(buildCount)", mustFix: true)]
                : [ReviewFinding(reviewer: "codex", severity: .nit, issue: "style", mustFix: false)]
            return (0..<reviewersPerRound).map { i in
                ReviewReport(reviewer: i == 0 ? "codex" : "r\(i)", completed: true, findings: i == 0 ? primary : [])
            }
        }
        func merge(_ build: BuildResult) async -> MergeResult {
            MergeResult(merged: mergeOK, into: "integration", note: mergeOK ? "joined" : "off-lease")
        }
        func remember(_ memory: FlywheelMemory) async { remembered = memory }
    }

    func testCleanAcceptPathMergesAndRemembers() async {
        let s = StubStages()
        let r = await FlywheelOrchestrator(stages: s).run(goal: "g")
        XCTAssertTrue(r.didMerge)
        XCTAssertEqual(r.rounds.count, 1)
        XCTAssertEqual(s.remembered?.accepted, true)
    }

    func testRejectThenImproveThenAcceptThreadsFeedback() async {
        let s = StubStages(); s.blockingForBuilds = 1
        let r = await FlywheelOrchestrator(stages: s, maxRounds: 3).run(goal: "g")
        XCTAssertTrue(r.didMerge)
        XCTAssertEqual(r.rounds.count, 2)
        XCTAssertEqual(s.lastFeedback.count, 1)
        XCTAssertTrue(s.lastFeedback.first?.issue.contains("build 1") == true)
    }

    // The KEY panel fix: zero completed reviewers must NOT read as a clean review.
    func testZeroReviewersFailsClosed() async {
        let s = StubStages(); s.reviewersPerRound = 0     // review returns []
        let r = await FlywheelOrchestrator(stages: s, maxRounds: 1).run(goal: "g")
        XCTAssertFalse(r.didMerge)
        if case .reject(let f) = r.rounds[0].verdict {
            XCTAssertEqual(f.first?.reviewer, "consensus")
            XCTAssertTrue(f.first?.issue.contains("quorum") == true)
        } else { XCTFail("expected quorum reject") }
    }

    func testQuorumRequiresMinReviewers() async {
        let s = StubStages(); s.reviewersPerRound = 1
        let r = await FlywheelOrchestrator(stages: s, maxRounds: 1, minReviewers: 3).run(goal: "g")
        XCTAssertFalse(r.didMerge, "1 reviewer must not satisfy a quorum of 3")
    }

    func testIncompleteReviewerFailsClosed() async {
        final class Incomplete: FlywheelStages, @unchecked Sendable {
            func research(goal: String) async -> ResearchNotes { ResearchNotes(summary: "r") }
            func plan(goal: String, research: ResearchNotes) async -> String { "p" }
            func build(goal: String, plan: String, feedback: [ReviewFinding]) async -> BuildResult { BuildResult(branch: "b", ok: true) }
            func test(_ b: BuildResult) async -> TestResult { TestResult(passed: true, summary: "ok") }
            func review(_ b: BuildResult, tests: TestResult) async -> [ReviewReport] {
                [ReviewReport(reviewer: "codex", completed: false)]   // ran but did not complete
            }
            func merge(_ b: BuildResult) async -> MergeResult { MergeResult(merged: true, into: "i", note: "") }
            func remember(_ m: FlywheelMemory) async {}
        }
        let r = await FlywheelOrchestrator(stages: Incomplete(), maxRounds: 1).run(goal: "g")
        XCTAssertFalse(r.didMerge)
    }

    func testCriticalSeverityBlocksEvenIfNotMustFix() {
        let clean = BuildResult(branch: "b", ok: true); let green = TestResult(passed: true, summary: "ok")
        let sneaky = [ReviewReport(reviewer: "sec", completed: true,
            findings: [ReviewFinding(reviewer: "sec", severity: .critical, issue: "RCE", mustFix: false)])]
        XCTAssertFalse(FlywheelOrchestrator.consensus(build: clean, tests: green, reports: sneaky, minReviewers: 1).isAccept)
    }

    func testFeedbackAccumulatesAcrossBuildFailure() async {
        let s = StubStages(); s.blockingForBuilds = 1; s.failBuildOnRound = 2
        let r = await FlywheelOrchestrator(stages: s, maxRounds: 3).run(goal: "g")
        // R1 review blocks "bug in build 1"; R2 build fails (its blocker doesn't erase the R1 one);
        // R3 build must still receive the R1 review blocker.
        XCTAssertTrue(s.lastFeedback.contains { $0.issue.contains("build 1") },
                      "R1 review blocker must survive an R2 build failure")
        XCTAssertTrue(r.didMerge)
        XCTAssertEqual(r.rounds.count, 3)
    }

    func testGiveUpAfterRepairBudget() async {
        let s = StubStages(); s.blockingForBuilds = 99
        let r = await FlywheelOrchestrator(stages: s, maxRounds: 2).run(goal: "g")
        XCTAssertFalse(r.didMerge)
        XCTAssertEqual(r.rounds.count, 2)
        XCTAssertEqual(s.remembered?.accepted, false)
    }

    func testFailingTestsRejectWithoutSpendingReviewers() async {
        let s = StubStages(); s.testsPass = false
        let r = await FlywheelOrchestrator(stages: s, maxRounds: 1).run(goal: "g")
        XCTAssertFalse(r.didMerge)
        XCTAssertEqual(s.reviewCalls, 0)
    }

    func testFailingBuildRejects() async {
        let s = StubStages(); s.buildOK = false
        let r = await FlywheelOrchestrator(stages: s, maxRounds: 1).run(goal: "g")
        XCTAssertFalse(r.didMerge)
        XCTAssertEqual(s.reviewCalls, 0)
    }

    func testMergeGateRefusalIsHonestNonMerge() async {
        let s = StubStages(); s.mergeOK = false
        let r = await FlywheelOrchestrator(stages: s).run(goal: "g")
        XCTAssertFalse(r.didMerge)
        XCTAssertEqual(s.remembered?.accepted, false)
        if case .rejected(_, let reason) = r { XCTAssertTrue(reason.contains("merge gate refused")) } else { XCTFail() }
    }

    func testConsensusPolicyIsFailClosed() {
        let clean = BuildResult(branch: "b", ok: true); let green = TestResult(passed: true, summary: "ok")
        let ok1 = [ReviewReport(reviewer: "codex", completed: true, findings: [])]
        XCTAssertTrue(FlywheelOrchestrator.consensus(build: clean, tests: green, reports: ok1, minReviewers: 1).isAccept)
        XCTAssertFalse(FlywheelOrchestrator.consensus(build: BuildResult(branch: "b", ok: false), tests: green, reports: ok1, minReviewers: 1).isAccept)
        XCTAssertFalse(FlywheelOrchestrator.consensus(build: clean, tests: TestResult(passed: false, summary: "x"), reports: ok1, minReviewers: 1).isAccept)
        XCTAssertFalse(FlywheelOrchestrator.consensus(build: clean, tests: green, reports: [], minReviewers: 1).isAccept)
        let blocking = [ReviewReport(reviewer: "codex", completed: true,
            findings: [ReviewFinding(reviewer: "codex", severity: .high, issue: "x", mustFix: true)])]
        XCTAssertFalse(FlywheelOrchestrator.consensus(build: clean, tests: green, reports: blocking, minReviewers: 1).isAccept)
    }
}
