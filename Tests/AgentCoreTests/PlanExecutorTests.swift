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
