import XCTest
@testable import AgentCore

final class EvalTests: XCTestCase {

    private func step(_ tool: String, _ args: String = "", success: Bool = true) -> ActionRecord {
        ActionRecord(tool: tool, argsFingerprint: args, success: success)
    }

    // MARK: TrajectoryAnalyzer — the proven incident causes

    func testDetectsRunawayLoop() {
        let steps = [step("read_file", "a"), step("edit_file", "x"), step("edit_file", "x"), step("edit_file", "x")]
        let report = TrajectoryAnalyzer.analyze(steps)
        XCTAssertFalse(report.healthy)
        XCTAssertEqual(report.issues.first?.kind, .runawayLoop)
        XCTAssertEqual(report.issues.first?.stepIndices, [1, 2, 3])
    }

    func testDetectsFailureSpike() {
        let steps = [step("run_command", "a", success: false), step("run_command", "b", success: false),
                     step("run_command", "c", success: false), step("read_file", "d", success: true)]
        let report = TrajectoryAnalyzer.analyze(steps)
        XCTAssertTrue(report.issues.contains { $0.kind == .failureSpike })
        XCTAssertEqual(report.failures, 3)
    }

    func testFlagsNearIterationBudgetAndReadOnlySpin() {
        let reads = (0..<10).map { step("read_file", "\($0)") }
        let report = TrajectoryAnalyzer.analyze(reads, maxIterations: 12)
        XCTAssertTrue(report.issues.contains { $0.kind == .nearIterationBudget })
        XCTAssertTrue(report.issues.contains { $0.kind == .noToolProgress })
    }

    func testHealthyTrajectoryHasNoIssues() {
        let steps = [step("read_file", "a"), step("edit_file", "b"), step("run_command", "test")]
        XCTAssertTrue(TrajectoryAnalyzer.analyze(steps, maxIterations: 12).healthy)
    }

    func testFingerprintStableAcrossKeyOrder() {
        let a = TrajectoryAnalyzer.fingerprint(["path": "x", "mode": "r"])
        let b = TrajectoryAnalyzer.fingerprint(["mode": "r", "path": "x"])
        XCTAssertEqual(a, b)
    }

    // MARK: assertions

    func testAssertionsCheckOutputAndTrajectory() {
        let traj = [step("write_file", "a"), step("run_command", "test", success: false)]
        XCTAssertTrue(EvalAssertion.outputContains("done").check(output: "all DONE", trajectory: traj, maxIterations: 12).0)
        XCTAssertTrue(EvalAssertion.toolCalled("write_file").check(output: "", trajectory: traj, maxIterations: 12).0)
        XCTAssertFalse(EvalAssertion.toolCalled("deploy").check(output: "", trajectory: traj, maxIterations: 12).0)
        XCTAssertFalse(EvalAssertion.noToolFailures.check(output: "", trajectory: traj, maxIterations: 12).0)
        XCTAssertTrue(EvalAssertion.maxSteps(5).check(output: "", trajectory: traj, maxIterations: 12).0)
        XCTAssertTrue(EvalAssertion.outputMatches(#"\d+ files"#).check(output: "3 files", trajectory: traj, maxIterations: 12).0)
    }

    func testAssertionsCanRequireResearchToolPathOrder() {
        let traj = [
            step("research_run", "start"),
            step("web_search", "query"),
            step("fetch_url", "source"),
            step("research_run", "synthesize"),
        ]
        XCTAssertTrue(EvalAssertion.toolsInOrder(["research_run", "web_search", "fetch_url", "research_run"])
            .check(output: "", trajectory: traj, maxIterations: 12).0)
        XCTAssertFalse(EvalAssertion.toolsInOrder(["fetch_url", "web_search"])
            .check(output: "", trajectory: traj, maxIterations: 12).0)
    }

    // MARK: runner

    func testRunnerScoresCasesWithInjectedAgent() async {
        let cases = [
            EvalCase(name: "greets", prompt: "say hi", assertions: [.outputContains("hi"), .noToolFailures]),
            EvalCase(name: "builds", prompt: "make x", assertions: [.toolCalled("write_file")]),
        ]
        let agent: EvalRunner.Agent = { prompt in
            if prompt == "say hi" { return .init(output: "hi there", trajectory: []) }
            return .init(output: "done", trajectory: [ActionRecord(tool: "read_file", argsFingerprint: "x", success: true)])
        }
        let report = await EvalRunner().run(cases, agent: agent)
        XCTAssertEqual(report.passed, 1)            // greets passes; builds fails (no write_file)
        XCTAssertFalse(report.allPassed)
        XCTAssertEqual(report.results.first { $0.name == "builds" }?.failures.count, 1)
    }

    func testRunnerAttachesJudgeScore() async {
        let cases = [EvalCase(name: "q", prompt: "p", assertions: [])]
        let report = await EvalRunner().run(cases, agent: { _ in .init(output: "ok", trajectory: []) },
                                            judge: { _, _ in 0.9 })
        XCTAssertEqual(report.results.first?.judgeScore, 0.9)
    }

    // MARK: judge parsing

    func testJudgeParsesScore() {
        XCTAssertEqual(LLMJudge.parseScore("0.8"), 0.8)
        XCTAssertEqual(LLMJudge.parseScore("Score: 0.42 out of 1"), 0.42)
        XCTAssertEqual(LLMJudge.parseScore("85"), 0.85)        // tolerate 0-100
        XCTAssertNil(LLMJudge.parseScore("no number"))
    }
}
