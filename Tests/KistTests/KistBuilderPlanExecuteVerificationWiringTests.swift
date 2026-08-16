import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

private final class PlanExecuteCommandCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTimeouts: [Int?] = []

    func record(_ arguments: [String: Any]) {
        lock.lock()
        recordedTimeouts.append(arguments["timeout"] as? Int)
        lock.unlock()
    }

    var timeouts: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTimeouts
    }
}

private struct PlanExecuteCommandStub: AgentTool {
    let name = "run_command"
    let description = "record an authorized verifier"
    let parameters: [ToolParameter] = []
    let capture: PlanExecuteCommandCapture

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        capture.record(arguments)
        return ToolResult(success: true, output: "verified")
    }
}

final class KistBuilderPlanExecuteVerificationWiringTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPlanExecuteUsesFrozenVerificationOnlyRegistry() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/Kist/KistRunner+BuilderAdapters.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains("static func builderScopedPlanExecuteTools("))
        XCTAssertTrue(source.contains("guard tool.name == \"run_command\" else { return tool }"))
        XCTAssertTrue(source.contains("verificationCommands: sealedPlan.verificationCommands"))
        XCTAssertTrue(source.contains("let planExecuteTools = builderScopedPlanExecuteTools("))
        XCTAssertTrue(source.contains("root: adapterRoot, tools: planExecuteTools, context: adapterContext"))
    }

    func testOmittedTimeoutIsBoundToUniqueFrozenVerifierBeforeExecution() async throws {
        let capture = PlanExecuteCommandCapture()
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [.init(
                executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 60)])

        let result = await ToolRegistry([tool]).execute(
            name: "run_command", arguments: try verifierArguments(),
            context: ToolContext(projectRoot: NSTemporaryDirectory()))

        XCTAssertTrue(result.success)
        XCTAssertEqual(capture.timeouts.map { $0 ?? -1 }, [60])
    }

    func testExplicitTimeoutMismatchIsDeniedWithoutExecution() async throws {
        let capture = PlanExecuteCommandCapture()
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [.init(
                executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 60)])
        var arguments = try verifierArguments()
        arguments["timeout"] = 61

        let result = try await tool.execute(
            arguments: arguments,
            context: ToolContext(projectRoot: NSTemporaryDirectory()))

        XCTAssertFalse(result.success)
        XCTAssertTrue(capture.timeouts.isEmpty)
    }

    func testAmbiguousOmittedTimeoutIsDeniedWithoutExecution() async throws {
        let capture = PlanExecuteCommandCapture()
        let tool = BuilderContractScopedMutationTool(
            base: PlanExecuteCommandStub(capture: capture), authority: [:],
            verificationCommands: [
                .init(executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 60),
                .init(executable: "python3", arguments: ["test_plan.py"], timeoutSeconds: 90),
            ])

        let result = try await tool.execute(
            arguments: try verifierArguments(),
            context: ToolContext(projectRoot: NSTemporaryDirectory()))

        XCTAssertFalse(result.success)
        XCTAssertTrue(capture.timeouts.isEmpty)
    }

    func testGovernedNodeUsesHostReceiptInsteadOfWorkerSelfVerdict() {
        let worker = BuilderWorkerReceipt(
            nodeID: "fleet-alpha", provider: "claude-cli", model: "sonnet",
            checks: [.init(name: "worker self verdict", passed: false,
                           details: "unverified — worker did not run the global oracle")])
        let host = BuilderVerifierReceipt(
            scope: .node("fleet-alpha"), provider: "host", model: "deterministic",
            deterministic: true, passed: true,
            checks: [.init(name: "partition path", passed: true,
                           details: "sealed child path exists")])

        let disposition = KistRunner.builderGovernedNodeVerificationDisposition(
            worker: worker, commandReceipt: host)

        XCTAssertTrue(disposition.passed)
        XCTAssertEqual(disposition.checks, host.checks)
        XCTAssertFalse(disposition.checks.contains { $0.name == "worker self verdict" })
    }

    func testGovernedFinalSourceVerdictIsAdvisoryButLegacyStillFailsClosed() {
        let worker = BuilderWorkerReceipt(
            nodeID: "fleet-alpha", provider: "claude-cli", model: "sonnet",
            checks: [.init(name: "worker self verdict", passed: false,
                           details: "unverified")])

        let governed = KistRunner.builderAdapterSourceEvidence(
            workers: [worker], governedByPreflight: true)
        let legacy = KistRunner.builderAdapterSourceEvidence(
            workers: [worker], governedByPreflight: false)

        XCTAssertTrue(governed.passed)
        XCTAssertTrue(governed.check.passed)
        XCTAssertTrue(governed.check.details.contains("sealed host verification"))
        XCTAssertFalse(legacy.passed)
        XCTAssertFalse(legacy.check.passed)
    }

    private func verifierArguments() throws -> [String: Any] {
        let data = Data(
            #"{"executable":"python3","args":["test_plan.py"],"cwd":".","allowed_exit_codes":[0]}"#.utf8)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
