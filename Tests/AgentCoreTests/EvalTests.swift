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

    func testFlagsNearIterationBudgetWithoutCallingReadOnlyWorkNoProgress() {
        let reads = (0..<10).map { step("read_file", "\($0)") }
        let report = TrajectoryAnalyzer.analyze(reads, maxIterations: 12)
        XCTAssertTrue(report.issues.contains { $0.kind == .nearIterationBudget })
        XCTAssertFalse(report.issues.contains { $0.kind == .noToolProgress })
    }

    func testOnlyBuildIntentFlagsReadOnlySpin() {
        let reads = (0..<6).map { step("read_file", "\($0)") }
        let requests = [
            "Explain how this module works",
            "Research current consensus techniques",
            "Review this implementation for bugs",
        ]
        for request in requests {
            let intent = PromptCompiler.compile(request).intent
            XCTAssertFalse(intent.expectsMutation, request)
            let report = TrajectoryAnalyzer.analyze(reads, taskIntent: intent)
            XCTAssertFalse(report.issues.contains { $0.kind == .noToolProgress }, request)
        }

        let buildIntent = PromptCompiler.compile("Implement the requested feature").intent
        XCTAssertTrue(buildIntent.expectsMutation)
        let buildReport = TrajectoryAnalyzer.analyze(reads, taskIntent: buildIntent)
        XCTAssertTrue(buildReport.issues.contains { $0.kind == .noToolProgress })

        let repairIntent = PromptCompiler.compile("fix this regression").intent
        XCTAssertEqual(repairIntent, .build)
        XCTAssertTrue(TrajectoryAnalyzer.analyze(reads, taskIntent: repairIntent).issues
            .contains { $0.kind == .noToolProgress })
    }

    func testAllBuildMutationPathsPreventNoProgressWarning() {
        let confirmedMutationTools: [(String, [String: Any])] = [
            ("write_file", ["path": "Sources/App.swift"]),
            ("edit_file", ["path": "Sources/App.swift"]),
            ("apply_patch", ["patch": "*** Begin Patch\n*** Update File: Sources/App.swift\n*** End Patch"]),
            ("notebook_edit", ["path": "Notebook.ipynb"]),
            ("move_file", ["from": "Sources/A.swift", "to": "Sources/B.swift"]),
            ("make_dir", ["path": "Generated"]),
            ("create_directory", ["path": "Generated"]),
        ]
        for (tool, arguments) in confirmedMutationTools {
            let mutation = ActionRecord(
                tool: tool, argsFingerprint: "target", success: true,
                effectObservation: ToolEffectCatalog.observe(
                    tool: tool, arguments: arguments, outcomeMetadata: ["changed": "true"])
            )
            let steps = (0..<6).map { step("read_file", "\($0)") } + [mutation]
            let report = TrajectoryAnalyzer.analyze(steps, taskIntent: .build)
            XCTAssertFalse(report.issues.contains { $0.kind == .noToolProgress }, tool)
        }

        let possibleAstRewrite = (0..<6).map { step("read_file", "\($0)") }
            + [step("ast_grep_apply", "path=.")]
        XCTAssertTrue(TrajectoryAnalyzer.analyze(possibleAstRewrite, taskIntent: .build).issues
            .contains { $0.kind == .noToolProgress }, "possible mutation is not observed progress")

        let failedPatch = (0..<6).map { step("read_file", "\($0)") }
            + [step("apply_patch", "target", success: false)]
        XCTAssertTrue(TrajectoryAnalyzer.analyze(failedPatch, taskIntent: .build).issues
            .contains { $0.kind == .noToolProgress })
    }

    func testSuccessfulInspectionCommandIsNotBuildProgress() {
        let steps = (0..<6).map { step("read_file", "\($0)") } + [step("run_command", "command=ls -la")]
        let report = TrajectoryAnalyzer.analyze(steps, taskIntent: .build)
        XCTAssertTrue(report.issues.contains { $0.kind == .noToolProgress })
    }

    func testSuccessfulBuildOrTestCommandIsBuildProgress() {
        let steps = (0..<6).map { step("read_file", "\($0)") } + [step("run_command", "command=swift test")]
        let report = TrajectoryAnalyzer.analyze(steps, taskIntent: .build)
        XCTAssertFalse(report.issues.contains { $0.kind == .noToolProgress })
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
