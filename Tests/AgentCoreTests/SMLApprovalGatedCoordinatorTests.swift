import XCTest
@testable import AgentCore

/// Pins the defense-in-depth dispatch gate: `SMLApprovalGatedCoordinator` refuses to run ANY
/// driver unless the task's current instruction is guarded by a WAIT_APPROVAL gate whose approval
/// is the newest approval-relevant receipt. The spy driver's invocation count is the proof — a
/// refused dispatch means ZERO driver executions, not a driver that ran and was discarded.
final class SMLApprovalGatedCoordinatorTests: XCTestCase {
    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private struct SpyDriver: SMLInstructionDriver {
        let id = "spy-driver"
        let reference = "cap.a"
        let counter: Counter

        func supports(_ request: SMLCapabilityRequest) -> Bool {
            request.reference == reference
        }

        func execute(_ invocation: SMLCapabilityInvocation) async throws -> SMLCapabilityOutcome {
            await counter.increment()
            return SMLCapabilityOutcome(
                dispatchID: invocation.dispatchID,
                instructionID: invocation.request.instructionID,
                requestStateDigest: invocation.request.stateDigest,
                status: .passed,
                statePatch: ["result": .string("done")],
                evidence: SMLCapabilityEvidence(
                    receiptID: "spy.receipt",
                    source: id,
                    digest: String(repeating: "b", count: 64),
                    observedAtEpoch: 1_000
                )
            )
        }
    }

    private struct Host {
        let store: SMLRuntimeStore
        let runtime: SMLRuntime
        let gateway: SMLCommandGateway
        let counter: Counter
        let gated: SMLApprovalGatedCoordinator
        let directory: URL
    }

    private func toolWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "gated.tool",
            version: "1.0.0",
            name: "Gated tool",
            source: .init(kind: .native, reference: "tests://gated"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "result", type: .string, required: false)],
            interface: .init(outputFields: ["result"]),
            entrypoint: "tool",
            instructions: [
                .init(id: "tool", op: .callTool, capability: "cap.a", next: "emit"),
                .init(id: "emit", op: .emitReceipt, receiptFields: ["result"]),
            ]
        )
    }

    private func makeHost(workflow: SMLWorkflow, gateWorkflow: Bool) async throws -> Host {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-gated-coordinator-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let effective = gateWorkflow
            ? try SMLWorkflowApprovalGating.gate(workflow)
            : workflow
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(effective),
            catalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["cap.a"],
                approvalAuthorities: [SMLApprovalPolicy.defaultApprovalOwner]
            )
        )
        _ = try await runtime.installWorkflow(admitted, role: "operator-role")
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        let counter = Counter()
        let coordinator = SMLCapabilityCoordinator(
            runtime: runtime,
            router: SMLCapabilityRouter(drivers: [SpyDriver(counter: counter)]),
            claimCompiler: SMLCapabilityClaimCompiler(
                actor: "operator.luke",
                commandID: { "claim-\(UUID().uuidString.lowercased())" },
                dispatchID: { "dispatch-\(UUID().uuidString.lowercased())" }
            ),
            completionCompiler: SMLCapabilityCompletionCompiler(
                actor: "operator.luke",
                commandID: { "complete-\(UUID().uuidString.lowercased())" }
            ),
            gateway: gateway,
            authorityResolver: { Self.authority(for: $0) },
            clock: { 1_000 }
        )
        return Host(
            store: store,
            runtime: runtime,
            gateway: gateway,
            counter: counter,
            gated: SMLApprovalGatedCoordinator(coordinator: coordinator, store: store),
            directory: directory
        )
    }

    private static func authority(for command: SMLCommandEnvelope) -> SMLCommandAuthority {
        SMLCommandAuthority(
            authenticatedActor: "operator.luke",
            leaseID: "lease-1",
            roles: ["operator-role"],
            tasks: [command.task],
            operations: SMLRuntimeCommandOperation.all,
            approvalAuthorities: [SMLApprovalPolicy.defaultApprovalOwner],
            scope: [:]
        )
    }

    private func submit(
        _ host: Host,
        task: String,
        op: String,
        arguments: SMLObject = [:],
        expectedState: SMLObject = [:]
    ) async throws -> SMLCommandResult {
        let command = SMLCommandEnvelope(
            commandID: "cmd-\(UUID().uuidString.lowercased())",
            actor: "operator.luke",
            role: "operator-role",
            task: task,
            op: op,
            arguments: arguments,
            expectedState: expectedState,
            issuedAtEpoch: 1_000
        )
        return try await host.gateway.submit(
            command,
            authority: Self.authority(for: command),
            nowEpoch: 1_000
        )
    }

    private func start(_ host: Host, task: String, workflowVersion: String) async throws {
        _ = try await submit(host, task: task, op: SMLRuntimeCommandOperation.workflowRun,
                             arguments: [
                                 "workflow_id": .string("gated.tool"),
                                 "workflow_version": .string(workflowVersion),
                             ])
    }

    // MARK: - The contract

    func testUnapprovedTaskNeverReachesTheDriver() async throws {
        let host = try await makeHost(workflow: toolWorkflow(), gateWorkflow: true)
        defer { try? FileManager.default.removeItem(at: host.directory) }
        let version = try SMLWorkflowApprovalGating.gate(toolWorkflow()).version
        try await start(host, task: "TASK-G1", workflowVersion: version)

        // Task is parked at the GATE (waitingApproval), not at the capability.
        do {
            _ = try await host.gated.executeNext(taskID: "TASK-G1")
            XCTFail("dispatch before approval must fail")
        } catch {
            // Either the approval check or pendingCapability may throw first; the driver count
            // below is the real assertion.
        }
        let ran = await host.counter.count
        XCTAssertEqual(ran, 0, "the spy driver must never run before approval")
    }

    func testApprovedTaskDispatchesExactlyOnce() async throws {
        let host = try await makeHost(workflow: toolWorkflow(), gateWorkflow: true)
        defer { try? FileManager.default.removeItem(at: host.directory) }
        let version = try SMLWorkflowApprovalGating.gate(toolWorkflow()).version
        try await start(host, task: "TASK-G2", workflowVersion: version)

        let approve = try await submit(
            host, task: "TASK-G2", op: SMLRuntimeCommandOperation.taskApprove,
            expectedState: ["task_revision": .number(1)]
        )
        XCTAssertEqual(approve.task?.status, .waitingCapability,
                       "approval must advance the task through the gate to the capability")

        _ = try await host.gated.executeNext(taskID: "TASK-G2")
        let ran = await host.counter.count
        XCTAssertEqual(ran, 1, "approved dispatch must run the driver exactly once")

        let snapshot = try await host.store.load()
        XCTAssertEqual(snapshot.tasks["TASK-G2"]?.status, .completed)
    }

    func testUngatedWorkflowFailsClosedEvenAtWaitingCapability() async throws {
        // Author error / policy drift: the workflow reached the store WITHOUT gates. The task
        // parks at waitingCapability directly — structurally past any gate — and the wrapper
        // must still refuse because no WAIT_APPROVAL guards the instruction.
        let host = try await makeHost(workflow: toolWorkflow(), gateWorkflow: false)
        defer { try? FileManager.default.removeItem(at: host.directory) }
        try await start(host, task: "TASK-G3", workflowVersion: "1.0.0")

        let snapshot = try await host.store.load()
        XCTAssertEqual(snapshot.tasks["TASK-G3"]?.status, .waitingCapability,
                       "fixture: the ungated task must be parked at the capability")

        do {
            _ = try await host.gated.executeNext(taskID: "TASK-G3")
            XCTFail("ungated capability instruction must never dispatch")
        } catch let error as SMLApprovalGatedCoordinator.ApprovalGateError {
            guard case .instructionNotGated(_, let instructionID) = error else {
                return XCTFail("expected .instructionNotGated, got \(error)")
            }
            XCTAssertEqual(instructionID, "tool")
        }
        let ran = await host.counter.count
        XCTAssertEqual(ran, 0, "the spy driver must never run for an ungated instruction")
    }

    func testUnknownTaskFailsClosed() async throws {
        let host = try await makeHost(workflow: toolWorkflow(), gateWorkflow: true)
        defer { try? FileManager.default.removeItem(at: host.directory) }
        do {
            _ = try await host.gated.executeNext(taskID: "TASK-ABSENT")
            XCTFail("unknown task must fail")
        } catch let error as SMLApprovalGatedCoordinator.ApprovalGateError {
            XCTAssertEqual(error, .unknownTask("TASK-ABSENT"))
        }
    }
}
