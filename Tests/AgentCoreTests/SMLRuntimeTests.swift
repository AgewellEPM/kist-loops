import XCTest
@testable import AgentCore

final class SMLRuntimeTests: XCTestCase {
    func testCommandBusCreatesWatchesApprovesAndPersistsTask() async throws {
        let directory = temporaryDirectory("sml-runtime-approval")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })

        try await install(approvalWorkflow(), role: "digital-presence-manager", runtime: runtime)

        let run = try await runtime.submit(try await admitted(
            commandID: "command-run",
            task: "TASK-1842",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("website.publish")],
            store: store
        ))
        XCTAssertEqual(run.task?.status, .waitingApproval)
        XCTAssertEqual(run.task?.currentInstructionID, "approval")
        XCTAssertEqual(run.task?.waitingApprovalOwner, "production_approver")

        let watch = try await runtime.submit(try await admitted(
            commandID: "command-watch",
            task: "TASK-1842",
            op: SMLRuntimeCommandOperation.taskWatch,
            store: store
        ))
        XCTAssertEqual(watch.task, run.task)

        do {
            _ = try await runtime.submit(try await admitted(
                commandID: "command-record-approval",
                task: "TASK-1842",
                op: SMLRuntimeCommandOperation.taskRecordStep,
                store: store
            ))
            XCTFail("record_step must not advance an approval gate")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .currentInstructionCannotBeAdvanced("approval"))
        }

        let approve = try await runtime.submit(try await admitted(
            commandID: "command-approve",
            task: "TASK-1842",
            op: SMLRuntimeCommandOperation.taskApprove,
            store: store
        ))
        XCTAssertEqual(approve.task?.status, .completed)
        XCTAssertEqual(approve.task?.currentOperation, .emitReceipt)

        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.tasks["TASK-1842"]?.status, .completed)
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .taskCreated })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .checkpoint })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .approvalRequested })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .approved })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .receiptEmitted })

        do {
            _ = try await admitted(
                commandID: "command-run",
                task: "TASK-9999",
                op: SMLRuntimeCommandOperation.workflowRun,
                arguments: ["workflow_id": .string("website.publish")],
                store: store
            )
            XCTFail("replay claims must survive through the durable runtime store")
        } catch {
            XCTAssertEqual(error as? SMLCommandAdmissionError, .replayedCommand)
        }
    }

    func testRecordStepAdvancesExternalInstructionsAndRejectsBadStatePatch() async throws {
        let directory = temporaryDirectory("sml-runtime-steps")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 2_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 2_000 })

        try await install(repairWorkflow(), role: "digital-presence-manager", runtime: runtime)

        let run = try await runtime.submit(try await admitted(
            commandID: "repair-run",
            task: "TASK-200",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("website.repair")],
            store: store
        ))
        XCTAssertEqual(run.task?.status, .waitingCapability)
        XCTAssertEqual(run.task?.currentInstructionID, "patch")

        let patched = try await runtime.submit(try await admitted(
            commandID: "repair-patch",
            task: "TASK-200",
            op: SMLRuntimeCommandOperation.taskRecordStep,
            arguments: [
                "outcome": .string("passed"),
                "state_patch": .object(["verification_status": .string("patched")]),
            ],
            store: store
        ))
        XCTAssertEqual(patched.task?.status, .waitingCapability)
        XCTAssertEqual(patched.task?.currentInstructionID, "verify")
        XCTAssertEqual(patched.task?.state["verification_status"], .string("patched"))

        let failed = try await runtime.submit(try await admitted(
            commandID: "repair-verify",
            task: "TASK-200",
            op: SMLRuntimeCommandOperation.taskRecordStep,
            arguments: ["outcome": .string("failed")],
            store: store
        ))
        XCTAssertEqual(failed.task?.status, .escalated)
        let snapshot = try await store.load()
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .rollback })
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .escalated })

        _ = try await runtime.submit(try await admitted(
            commandID: "bad-run",
            task: "TASK-201",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("website.repair")],
            store: store
        ))
        do {
            _ = try await runtime.submit(try await admitted(
                commandID: "bad-patch",
                task: "TASK-201",
                op: SMLRuntimeCommandOperation.taskRecordStep,
                arguments: ["state_patch": .object(["undeclared": .string("nope")])],
                store: store
            ))
            XCTFail("state patches must stay inside the workflow state schema")
        } catch let error as SMLRuntimeError {
            guard case .statePatchRejected = error else {
                return XCTFail("expected statePatchRejected, got \(error)")
            }
        }
    }

    func testRunMatchingUsesTypedFiltersAndFailsClosedOnAmbiguity() async throws {
        let directory = temporaryDirectory("sml-runtime-matching")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 3_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 3_000 })

        try await install(simpleWorkflow(id: "website.health"), role: "digital-presence-manager", runtime: runtime)
        try await install(simpleWorkflow(id: "seo.audit"), role: "digital-presence-manager", runtime: runtime)

        let matched = try await runtime.submit(try await admitted(
            commandID: "match-one",
            task: "TASK-MATCH-1",
            op: SMLRuntimeCommandOperation.workflowRunMatching,
            arguments: ["filters": .object(["category": .string("website")])],
            store: store
        ))
        XCTAssertEqual(matched.task?.workflowID, "website.health")

        try await install(simpleWorkflow(id: "website.performance"), role: "digital-presence-manager", runtime: runtime)
        do {
            _ = try await runtime.submit(try await admitted(
                commandID: "match-many",
                task: "TASK-MATCH-2",
                op: SMLRuntimeCommandOperation.workflowRunMatching,
                arguments: ["filters": .object(["category": .string("website")])],
                store: store
            ))
            XCTFail("ambiguous workflow filters must fail closed")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .ambiguousWorkflowMatch(["website.health", "website.performance"])
            )
        }
    }

    func testREPLCompilerAndRendererMapShellCommandsToTypedEnvelopes() throws {
        let compiler = SMLREPLCompiler(
            actor: "operator.luke",
            role: "digital-presence-manager",
            commandID: { "command-fixed" },
            taskID: { "TASK-1842" }
        )

        let run = try compiler.compile("run website.performance_repair", issuedAtEpoch: 4_000)
        XCTAssertEqual(run.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(run.task, "TASK-1842")
        XCTAssertEqual(run.arguments["workflow_id"], .string("website.performance_repair"))

        let approve = try compiler.compile("approve TASK-1842", issuedAtEpoch: 4_001)
        XCTAssertEqual(approve.op, SMLRuntimeCommandOperation.taskApprove)
        XCTAssertEqual(approve.task, "TASK-1842")

        let output = SMLREPLRenderer.render(SMLCommandResult(
            kind: .status,
            message: "status",
            status: .init(
                workflowCount: 2,
                roleCount: 1,
                taskCount: 3,
                activeTaskCount: 1,
                receiptCount: 5
            )
        ))
        XCTAssertTrue(output.contains("workflows: 2"))
        XCTAssertTrue(output.contains("tasks: 3 active: 1"))
    }

    func testOperatorRollbackLeavesTerminalRolledBackTask() async throws {
        let directory = temporaryDirectory("sml-runtime-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 5_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 5_000 })

        try await install(repairWorkflow(), role: "digital-presence-manager", runtime: runtime)
        _ = try await runtime.submit(try await admitted(
            commandID: "rollback-run",
            task: "TASK-ROLLBACK",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("website.repair")],
            store: store
        ))

        let rolledBack = try await runtime.submit(try await admitted(
            commandID: "rollback-now",
            task: "TASK-ROLLBACK",
            op: SMLRuntimeCommandOperation.taskRollback,
            store: store
        ))
        XCTAssertEqual(rolledBack.task?.status, .rolledBack)

        let status = try await runtime.status()
        XCTAssertEqual(status.status?.activeTaskCount, 0)
    }

    private func admitted(
        commandID: String,
        task: String,
        op: String,
        role: String = "digital-presence-manager",
        arguments: SMLObject = [:],
        store: SMLRuntimeStore
    ) async throws -> SMLAdmittedCommand {
        let command = SMLCommandEnvelope(
            commandID: commandID,
            actor: "operator.luke",
            role: role,
            task: task,
            op: op,
            arguments: arguments,
            issuedAtEpoch: 1_000
        )
        return try await SMLCommandAdmission.admit(
            SMLCommandCandidate(command: command, validationReport: command.validate()),
            authority: SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "lease-1",
                roles: [role],
                tasks: [task],
                operations: SMLRuntimeCommandOperation.all,
                scope: [:]
            ),
            nowEpoch: 1_000,
            replayGuard: store
        )
    }

    private func install(
        _ workflow: SMLWorkflow,
        role: String,
        runtime: SMLRuntime
    ) async throws {
        let candidate = try SMLWorkflowValidator.requireValidForImport(workflow)
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            candidate,
            catalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["repository.apply_patch"],
                verifiers: ["build_passed"],
                approvalAuthorities: ["production_approver"]
            )
        )
        _ = try await runtime.installWorkflow(admitted, role: role)
    }

    private func approvalWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "website.publish",
            version: "1.0.0",
            name: "Website publish",
            source: .init(kind: .jobDescription, reference: "digital-presence-manager"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "approved", type: .boolean, required: false)],
            entrypoint: "checkpoint",
            instructions: [
                .init(id: "checkpoint", op: .checkpoint, next: "approval"),
                .init(id: "approval", op: .waitApproval,
                      reason: "production_deployment", owner: "production_approver",
                      next: "receipt", onFailure: "refused"),
                .init(id: "receipt", op: .emitReceipt,
                      receiptFields: ["actor", "task", "workflow_id", "approved"]),
                .init(id: "refused", op: .escalate,
                      reason: "approval_refused", owner: "production_approver"),
            ]
        )
    }

    private func repairWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "website.repair",
            version: "1.0.0",
            name: "Website repair",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "verification_status", type: .string)],
            entrypoint: "patch",
            instructions: [
                .init(id: "patch", op: .callTool,
                      capability: "repository.apply_patch", next: "verify"),
                .init(id: "verify", op: .verify, verifier: "build_passed",
                      onPass: "receipt", onFailure: "rollback"),
                .init(id: "rollback", op: .rollback,
                      reason: "verification_failed", next: "escalated"),
                .init(id: "receipt", op: .emitReceipt,
                      receiptFields: ["task", "verification_status"]),
                .init(id: "escalated", op: .escalate,
                      reason: "repair_failed", owner: "production_approver"),
            ]
        )
    }

    private func simpleWorkflow(id: String) -> SMLWorkflow {
        SMLWorkflow(
            id: id,
            version: "1.0.0",
            name: id,
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "done",
            instructions: [.init(id: "done", op: .complete)]
        )
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
