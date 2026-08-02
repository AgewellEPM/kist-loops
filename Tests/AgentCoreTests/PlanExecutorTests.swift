import XCTest
import Foundation
@testable import AgentCore

/// The plan executor running real DAGs against the real headless tools in a temp project:
/// topological execution, ${id} output chaining, stop-on-failure, invalid-plan fast-fail.
final class PlanExecutorTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "plan-exec-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    private func executor() -> PlanExecutor {
        PlanExecutor(tools: .headless(), context: ToolContext(projectRoot: root))
    }

    func testLinearPlanExecutesInOrderAndCapturesOutputs() async {
        let plan = ExecutablePlan(goal: "write then read", steps: [
            PlanStep(id: "E1", intent: "write", tool: "write_file", argumentsJSON: #"{"path":"a.txt","content":"hello"}"#),
            PlanStep(id: "E2", intent: "read", tool: "read_file", argumentsJSON: #"{"path":"a.txt"}"#, dependsOn: ["E1"]),
        ])
        let exec = await executor().execute(plan)
        XCTAssertTrue(exec.success, exec.summary)
        XCTAssertEqual(exec.stepResults.map(\.stepId), ["E1", "E2"])
        XCTAssertTrue(exec.outputs["E2"]?.contains("hello") ?? false)   // read step captured the content
        XCTAssertEqual(try? String(contentsOfFile: root + "/a.txt", encoding: .utf8), "hello")
    }

    func testOutputOfOneStepFlowsIntoNextViaRef() async {
        // E1 reads a seeded file; E2 writes E1's output into a new file via ${E1}.
        try? "PAYLOAD-123".write(toFile: root + "/src.txt", atomically: true, encoding: .utf8)
        let plan = ExecutablePlan(goal: "pipe output", steps: [
            PlanStep(id: "E1", intent: "read src", tool: "read_file", argumentsJSON: #"{"path":"src.txt"}"#),
            PlanStep(id: "E2", intent: "echo into out", tool: "write_file",
                     argumentsJSON: #"{"path":"out.txt","content":"${E1}"}"#, dependsOn: ["E1"]),
        ])
        let exec = await executor().execute(plan)
        XCTAssertTrue(exec.success, exec.summary)
        // out.txt now contains whatever read_file emitted for src.txt — must include the payload.
        let written = (try? String(contentsOfFile: root + "/out.txt", encoding: .utf8)) ?? ""
        XCTAssertTrue(written.contains("PAYLOAD-123"), "ref ${E1} did not flow into E2: \(written)")
    }

    func testStopsOnFirstFailureAndSkipsRest() async {
        let plan = ExecutablePlan(goal: "fail early", steps: [
            PlanStep(id: "E1", intent: "read missing", tool: "read_file", argumentsJSON: #"{"path":"nope.txt"}"#),
            PlanStep(id: "E2", intent: "should not run", tool: "write_file",
                     argumentsJSON: #"{"path":"should-not-exist.txt","content":"x"}"#, dependsOn: ["E1"]),
        ])
        let exec = await executor().execute(plan)
        XCTAssertFalse(exec.success)
        XCTAssertEqual(exec.failedStepId, "E1")
        XCTAssertEqual(exec.stepResults.count, 1)   // E2 never ran
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/should-not-exist.txt"))
    }

    func testInvalidPlanFailsFastWithNoSideEffects() async {
        // A cycle → orderedSteps throws → executor refuses to run anything.
        let plan = ExecutablePlan(goal: "cyclic", steps: [
            PlanStep(id: "A", intent: "a", tool: "write_file", argumentsJSON: #"{"path":"a.txt","content":"x"}"#, dependsOn: ["B"]),
            PlanStep(id: "B", intent: "b", tool: "write_file", argumentsJSON: #"{"path":"b.txt","content":"x"}"#, dependsOn: ["A"]),
        ])
        let exec = await executor().execute(plan)
        XCTAssertFalse(exec.success)
        XCTAssertTrue(exec.stepResults.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/a.txt"))   // nothing ran
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    func testDiamondPlanRunsAllNodes() async {
        // A → (B, C) → D; all four create files, D depends on both.
        let plan = ExecutablePlan(goal: "diamond", steps: [
            PlanStep(id: "A", intent: "a", tool: "write_file", argumentsJSON: #"{"path":"A.txt","content":"a"}"#),
            PlanStep(id: "B", intent: "b", tool: "write_file", argumentsJSON: #"{"path":"B.txt","content":"b"}"#, dependsOn: ["A"]),
            PlanStep(id: "C", intent: "c", tool: "write_file", argumentsJSON: #"{"path":"C.txt","content":"c"}"#, dependsOn: ["A"]),
            PlanStep(id: "D", intent: "d", tool: "write_file", argumentsJSON: #"{"path":"D.txt","content":"d"}"#, dependsOn: ["B", "C"]),
        ])
        let exec = await executor().execute(plan)
        XCTAssertTrue(exec.success, exec.summary)
        for f in ["A", "B", "C", "D"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/\(f).txt"), "\(f) did not run")
        }
        // A must be first, D must be last in execution order.
        XCTAssertEqual(exec.stepResults.first?.stepId, "A")
        XCTAssertEqual(exec.stepResults.last?.stepId, "D")
    }

    func testRepairedPlanStepCarriesTheArgumentsThatActuallyRanIntoVerification() async throws {
        let plan = ExecutablePlan(goal: "edit then verify", steps: [
            PlanStep(id: "E1", intent: "edit source", tool: "write_file",
                     argumentsJSON: #"{"path":"Sources/App.swift","content":"let value = 1\n"}"#),
            PlanStep(id: "E2", intent: "verify", tool: "run_command",
                     argumentsJSON: #"{"command":"swift test"}"#, dependsOn: ["E1"]),
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([WriteFileTool(), RepairableRunCommandTool()]),
            context: ToolContext(projectRoot: root),
            repairStep: { step, _, _ in
                step.id == "E2" ? ["executable": "true", "args": [String]()] : nil
            }
        ).execute(plan)

        XCTAssertTrue(exec.success)
        let trajectory = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertEqual(trajectory.last?.observedEffects.verification, .nonVerifyingCommand,
                       "a successful repaired `true` retry must not inherit the failed original `swift test`")
        guard case .needsVerification = CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: true,
            expectedOutcome: .mutation, taskIntent: .build
        ) else {
            return XCTFail("a repaired non-verifier must not satisfy verify-after-edit")
        }
    }

    func testFailedPartialMutationSurvivesHarmlessRepairInAttemptLedger() async throws {
        let plan = ExecutablePlan(goal: "recover without hiding a partial write", steps: [
            PlanStep(id: "E1", intent: "write source then fail", tool: "run_command",
                     argumentsJSON: #"{"command":"printf broken > Sources/Partial.swift"}"#),
            PlanStep(id: "E2", intent: "write release note", tool: "write_file",
                     argumentsJSON: #"{"path":"README.md","content":"done"}"#, dependsOn: ["E1"]),
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([PartialFailureRunCommandTool(), WriteFileTool()]),
            context: ToolContext(projectRoot: root),
            repairStep: { step, _, _ in
                step.id == "E1" ? ["executable": "true", "args": [String]()] : nil
            }
        ).execute(plan)

        XCTAssertTrue(exec.success, exec.summary)
        XCTAssertEqual(exec.stepResults.count, 2, "final per-step compatibility view stays collapsed")
        XCTAssertEqual(exec.attemptResults.map(\.success), [false, true, true],
                       "initial failure, repaired retry, and dependent write must all remain in order")
        XCTAssertEqual(exec.attemptResults.map(\.executionPhase), [1, 2, 3])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/Sources/Partial.swift"),
                      "the failing attempt really left a partial source side effect")

        let trajectory = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        guard case .needsVerification(let reason) = CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: true,
            expectedOutcome: .mutation, taskIntent: .build
        ) else { return XCTFail("a harmless repaired retry must not erase its failed source side effect") }
        XCTAssertTrue(reason.contains("source mutation failed"), reason)
    }

    func testSameWaveVerifierCannotProveConcurrentSourceMutation() async {
        let plan = ExecutablePlan(goal: "edit and verify", steps: [
            PlanStep(id: "E1", intent: "edit source", tool: "write_file",
                     argumentsJSON: #"{"path":"Sources/App.swift","content":"let x = 1"}"#),
            PlanStep(id: "E2", intent: "verify", tool: "run_command",
                     argumentsJSON: #"{"command":"swift test"}"#),
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([WriteFileTool(), PassingRunCommandTool()]),
            context: ToolContext(projectRoot: root)
        ).execute(plan)

        XCTAssertTrue(exec.success, exec.summary)
        XCTAssertEqual(exec.attemptResults.map(\.executionPhase), [1, 1],
                       "independent ready steps must be represented as one overlapping phase")
        let trajectory = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertEqual(trajectory.last?.observedEffects.verification, .nonVerifyingCommand,
                       "same-phase test has no happens-before edge to the source edit")
        XCTAssertFalse(CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: true,
            expectedOutcome: .mutation, taskIntent: .build
        ).isAccept)
    }

    func testSameWaveVerifierCannotPrecedeARepairedMutationThenMoveAfterItBySorting() async {
        // Both initial attempts are phase 1. The verifier finishes before repair is even attempted;
        // replacing E1 in stable plan order must not manufacture [repaired edit, old passing test].
        let plan = ExecutablePlan(goal: "repair edit and verify", steps: [
            PlanStep(id: "E1", intent: "edit source", tool: "write_file",
                     argumentsJSON: #"{"path":"Sources/App.swift","content":"broken"}"#),
            PlanStep(id: "E2", intent: "verify", tool: "run_command",
                     argumentsJSON: #"{"command":"swift test"}"#),
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([RepairingWriteFileTool(), PassingRunCommandTool()]),
            context: ToolContext(projectRoot: root),
            repairStep: { step, _, _ in
                step.id == "E1" ? ["path": "Sources/App.swift", "content": "repaired"] : nil
            }
        ).execute(plan)

        XCTAssertTrue(exec.success, exec.summary)
        XCTAssertEqual(exec.attemptResults.map(\.executionPhase), [1, 1, 2])
        XCTAssertEqual(exec.attemptResults.map(\.stepId), ["E1", "E2", "E1"])
        let trajectory = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertFalse(CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: true,
            expectedOutcome: .mutation, taskIntent: .build
        ).isAccept, "phase-1 test cannot verify the repaired phase-2 edit")
    }

    func testDependentVerifierInLaterWaveStillProvesMutation() async {
        let plan = ExecutablePlan(goal: "edit then verify", steps: [
            PlanStep(id: "E1", intent: "edit source", tool: "write_file",
                     argumentsJSON: #"{"path":"Sources/App.swift","content":"let x = 1"}"#),
            PlanStep(id: "E2", intent: "verify", tool: "run_command",
                     argumentsJSON: #"{"command":"swift test"}"#, dependsOn: ["E1"]),
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([WriteFileTool(), PassingRunCommandTool()]),
            context: ToolContext(projectRoot: root)
        ).execute(plan)

        XCTAssertEqual(exec.attemptResults.map(\.executionPhase), [1, 2])
        XCTAssertTrue(CompletionVerifier().check(
            trajectory: PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec), canRunCommands: true,
            expectedOutcome: .mutation, taskIntent: .build
        ).isAccept, "an explicit dependency establishes verifier-after-mutation")
    }

    func testIndependentReadyStepsRunInParallelButReportDeterministically() async {
        let sleeper = SleepTool(delayMilliseconds: 500)
        let exec = PlanExecutor(tools: ToolRegistry([sleeper]), context: ToolContext(projectRoot: root))
        let plan = ExecutablePlan(goal: "parallel sleeps", steps: [
            PlanStep(id: "A", intent: "sleep a", tool: "sleep_tool", argumentsJSON: #"{"id":"A"}"#),
            PlanStep(id: "B", intent: "sleep b", tool: "sleep_tool", argumentsJSON: #"{"id":"B"}"#),
            PlanStep(id: "C", intent: "sleep c", tool: "sleep_tool", argumentsJSON: #"{"id":"C"}"#, dependsOn: ["A", "B"]),
        ])

        let started = Date()
        let result = await exec.execute(plan)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(result.success, result.summary)
        XCTAssertEqual(result.stepResults.map(\.stepId), ["A", "B", "C"])
        XCTAssertLessThan(elapsed, 1.25, "A and B should overlap; sequential would take ~1.5s")
        let starts = sleeper.starts
        XCTAssertNotNil(starts["A"])
        XCTAssertNotNil(starts["B"])
        XCTAssertLessThan(abs(starts["A"]!.timeIntervalSince(starts["B"]!)), 0.25)
    }

    // MARK: - dangerous-step approval gate (the DAG must not bypass approval — Codex HIGH)

    private func dangerousPlan() -> ExecutablePlan {
        ExecutablePlan(goal: "gated", steps: [
            PlanStep(id: "E1", intent: "external delete", tool: "probe__delete_row", argumentsJSON: "{}"),
        ])
    }

    func testDangerousStepDeclinedAtGateIsNotExecuted() async {
        let deny: @Sendable (String, [String: Any]) async -> Bool = { _, _ in false }
        let px = PlanExecutor(tools: .headless(), context: ToolContext(projectRoot: root), approveDangerous: deny)
        let exec = await px.execute(dangerousPlan())
        XCTAssertFalse(exec.success)
        let e1 = exec.stepResults.first { $0.stepId == "E1" }
        XCTAssertEqual(e1?.error?.contains("declined at approval gate"), true,
                       "a declined dangerous step must be blocked, never handed to tools.execute")
    }

    func testDangerousStepApprovedReachesExecution() async {
        let allow: @Sendable (String, [String: Any]) async -> Bool = { _, _ in true }
        let px = PlanExecutor(tools: .headless(), context: ToolContext(projectRoot: root), approveDangerous: allow)
        let exec = await px.execute(dangerousPlan())
        let e1 = exec.stepResults.first { $0.stepId == "E1" }
        // Approved → passed the gate → reached execute → unknown-tool failure (NOT a gate decline).
        XCTAssertEqual(e1?.error?.contains("declined at approval gate"), false)
        XCTAssertEqual(e1?.error?.lowercased().contains("unknown"), true)
    }

    func testNoHookMeansAutonomousNoGate() async {
        // nil hook (fleet/--yolo): a dangerous step runs without a gate.
        let exec = await executor().execute(dangerousPlan())
        let e1 = exec.stepResults.first { $0.stepId == "E1" }
        XCTAssertEqual(e1?.error?.contains("declined at approval gate"), false, "no hook = no gate")
    }

    func testSafeStepBypassesGateEvenWithDenier() async {
        try? "hi".write(toFile: root + "/r.txt", atomically: true, encoding: .utf8)
        let plan = ExecutablePlan(goal: "read", steps: [
            PlanStep(id: "E1", intent: "read", tool: "read_file", argumentsJSON: #"{"path":"r.txt"}"#),
        ])
        let deny: @Sendable (String, [String: Any]) async -> Bool = { _, _ in false }
        let px = PlanExecutor(tools: .headless(), context: ToolContext(projectRoot: root), approveDangerous: deny)
        let exec = await px.execute(plan)
        XCTAssertTrue(exec.success, "a safe read step must never be sent through the dangerous gate")
    }
}

private final class SleepTool: AgentTool, @unchecked Sendable {
    let name = "sleep_tool"
    let description = "Sleep for test timing."
    let parameters = [ToolParameter(name: "id", type: "string", description: "step id")]
    private let delayNanoseconds: UInt64
    private let queue = DispatchQueue(label: "sleep-tool-test")
    private var _starts: [String: Date] = [:]

    init(delayMilliseconds: UInt64) {
        self.delayNanoseconds = delayMilliseconds * 1_000_000
    }

    var starts: [String: Date] {
        queue.sync { _starts }
    }

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let id = try requireString("id", from: arguments)
        queue.sync { _starts[id] = Date() }
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return ToolResult(success: true, output: "slept \(id)")
    }
}

private struct RepairableRunCommandTool: AgentTool {
    let name = "run_command"
    let description = "test double"
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        if arguments["command"] as? String == "swift test" {
            return .failure("simulated failing tests")
        }
        if arguments["executable"] as? String == "true" {
            return ToolResult(success: true, output: "(no output)")
        }
        return .failure("unexpected arguments")
    }
}

private struct PassingRunCommandTool: AgentTool {
    let name = "run_command"
    let description = "always-passing verifier test double"
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        ToolResult(success: true, output: "tests passed")
    }
}

private struct PartialFailureRunCommandTool: AgentTool {
    let name = "run_command"
    let description = "leaves a source write before its first failure"
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        if arguments["command"] as? String != nil {
            try FileManager.default.createDirectory(atPath: context.projectRoot + "/Sources",
                                                    withIntermediateDirectories: true)
            try "broken".write(toFile: context.projectRoot + "/Sources/Partial.swift",
                               atomically: true, encoding: .utf8)
            return .failure("failed after partial source write")
        }
        if arguments["executable"] as? String == "true" {
            return ToolResult(success: true, output: "(no output)")
        }
        return .failure("unexpected arguments")
    }
}

private struct RepairingWriteFileTool: AgentTool {
    let name = "write_file"
    let description = "fails after first source write, succeeds on repaired content"
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        try FileManager.default.createDirectory(atPath: context.projectRoot + "/Sources",
                                                withIntermediateDirectories: true)
        let content = (arguments["content"] as? String) ?? ""
        try content.write(toFile: context.projectRoot + "/Sources/App.swift",
                          atomically: true, encoding: .utf8)
        return content == "repaired"
            ? ToolResult(success: true, output: "wrote", metadata: ["changed": "true"])
            : ToolResult(success: false, output: "", error: "failed after write",
                         metadata: ["changed": "true"])
    }
}
