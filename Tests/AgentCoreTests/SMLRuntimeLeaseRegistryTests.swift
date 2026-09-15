import XCTest
@testable import AgentCore

/// Pins lease-scoped task authority for durable hosts: a lease owns exactly the tasks it created
/// (plus the synthetic runtime-metadata task), a second lease is denied on a foreign task at the
/// admission gate, and adoption is explicit — never automatic.
final class SMLRuntimeLeaseRegistryTests: XCTestCase {
    private func envelope(
        task: String,
        op: String,
        actor: String = "operator-alice",
        role: String = "workflow-agent"
    ) -> SMLCommandEnvelope {
        SMLCommandEnvelope(
            commandID: "cmd-\(UUID().uuidString.lowercased())",
            actor: actor,
            role: role,
            task: task,
            op: op,
            arguments: [:],
            scope: [:],
            expectedState: [:],
            issuedAtEpoch: 1_000
        )
    }

    private func authority(
        tasks: Set<String>,
        lease: SMLRuntimeLeaseRegistry.Session
    ) -> SMLCommandAuthority {
        SMLCommandAuthority(
            authenticatedActor: "operator-alice",
            leaseID: lease.leaseID,
            roles: ["workflow-agent"],
            tasks: tasks,
            operations: SMLRuntimeCommandOperation.all,
            scope: [:],
            taskLease: lease
        )
    }

    func testCreatingOperationOnlyGrantsItsTaskForThatCommand() async {
        let lease = SMLRuntimeLeaseRegistry.Session()
        let run = envelope(task: "TASK-NEW", op: SMLRuntimeCommandOperation.workflowRun)
        let tasks = await lease.authorizedTasks(for: run)
        XCTAssertTrue(tasks.contains("TASK-NEW"))
        let owns = await lease.ownsTask("TASK-NEW")
        XCTAssertFalse(owns, "only successful creation may bind the task to the lease")
        let watch = envelope(task: "TASK-NEW", op: SMLRuntimeCommandOperation.taskWatch)
        let followingTasks = await lease.authorizedTasks(for: watch)
        XCTAssertFalse(followingTasks.contains("TASK-NEW"))
    }

    func testGatewayBindsOnlyAfterSuccessfulCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sml-lease-create-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(fileURL: directory.appendingPathComponent("runtime.json"), clock: { 1_000 })
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let workflow = SMLWorkflow(
            id: "lease.test", version: "1.0.0", name: "Lease test",
            source: .init(kind: .native, reference: "tests://lease"), trigger: .init(kind: .manual),
            stateSchema: [], interface: .init(), entrypoint: "done",
            instructions: [.init(id: "done", op: .complete)]
        )
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow), catalog: SMLExecutionAdmissionCatalog())
        _ = try await runtime.installWorkflow(admitted, role: "workflow-agent")
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        let creator = SMLRuntimeLeaseRegistry.Session()
        let other = SMLRuntimeLeaseRegistry.Session()
        for (index, lease) in [creator, other].enumerated() {
            let command = SMLCommandEnvelope(
                commandID: "create-\(index)", actor: "operator-alice", role: "workflow-agent",
                task: "TASK-EXISTS", op: SMLRuntimeCommandOperation.workflowRun,
                arguments: ["workflow_id": .string(workflow.id), "workflow_version": .string(workflow.version)],
                issuedAtEpoch: 1_000)
            let tasks = await lease.authorizedTasks(for: command)
            do {
                _ = try await gateway.submit(command, authority: authority(tasks: tasks, lease: lease), nowEpoch: 1_000)
                XCTAssertEqual(index, 0, "duplicate creation must fail")
            } catch {
                XCTAssertEqual(index, 1, "first creation must succeed: \(error)")
            }
        }
        let creatorOwns = await creator.ownsTask("TASK-EXISTS")
        let otherOwns = await other.ownsTask("TASK-EXISTS")
        XCTAssertTrue(creatorOwns)
        XCTAssertFalse(otherOwns, "failed duplicate creation cannot change the lease")
    }

    func testNonCreatingOperationDoesNotAdoptForeignTasks() async {
        let lease = SMLRuntimeLeaseRegistry.Session()
        let watch = envelope(task: "TASK-FOREIGN", op: SMLRuntimeCommandOperation.taskWatch)
        let tasks = await lease.authorizedTasks(for: watch)
        XCTAssertFalse(tasks.contains("TASK-FOREIGN"),
                       "watch must never grant a task the lease did not create or adopt")
        let owns = await lease.ownsTask("TASK-FOREIGN")
        XCTAssertFalse(owns)
    }

    func testRuntimeMetadataTaskIsAlwaysAuthorized() async {
        let lease = SMLRuntimeLeaseRegistry.Session()
        let inspect = envelope(
            task: SMLRuntimeLeaseRegistry.runtimeMetadataTask,
            op: SMLRuntimeCommandOperation.workflowInspect
        )
        let tasks = await lease.authorizedTasks(for: inspect)
        XCTAssertTrue(tasks.contains(SMLRuntimeLeaseRegistry.runtimeMetadataTask))
    }

    func testSecondLeaseIsDeniedOnForeignTaskAtTheAdmissionGate() async {
        let creator = SMLRuntimeLeaseRegistry.Session()
        let intruder = SMLRuntimeLeaseRegistry.Session()

        let run = envelope(task: "TASK-OWNED", op: SMLRuntimeCommandOperation.workflowRun)
        _ = await creator.authorizedTasks(for: run)
        await creator.adopt(taskID: "TASK-OWNED") // Represents a successfully created task.

        let foreignApprove = envelope(
            task: "TASK-OWNED",
            op: SMLRuntimeCommandOperation.taskApprove
        )
        let intruderTasks = await intruder.authorizedTasks(for: foreignApprove)
        XCTAssertThrowsError(
            try SMLCommandAdmission.preflight(
                foreignApprove,
                authority: authority(tasks: intruderTasks, lease: intruder),
                nowEpoch: 1_000
            )
        ) { error in
            XCTAssertEqual(error as? SMLCommandAdmissionError, .taskDenied)
        }

        // The creator's lease admits the same command.
        let creatorTasks = await creator.authorizedTasks(for: foreignApprove)
        XCTAssertNoThrow(
            try SMLCommandAdmission.preflight(
                foreignApprove,
                authority: authority(tasks: creatorTasks, lease: creator),
                nowEpoch: 1_000
            )
        )
    }

    func testExplicitAdoptionGrantsAndIsPerLease() async {
        let first = SMLRuntimeLeaseRegistry.Session()
        let second = SMLRuntimeLeaseRegistry.Session()
        await first.adopt(taskID: "TASK-RESUMED")
        let firstOwns = await first.ownsTask("TASK-RESUMED")
        let secondOwns = await second.ownsTask("TASK-RESUMED")
        XCTAssertTrue(firstOwns)
        XCTAssertFalse(secondOwns, "adoption must never leak across leases")
    }

    func testMintedLeaseIDsAreValidIdentifiersAndUnique() {
        let a = SMLRuntimeLeaseRegistry.Session()
        let b = SMLRuntimeLeaseRegistry.Session()
        XCTAssertNotEqual(a.leaseID, b.leaseID)
        XCTAssertTrue(SMLValidationSupport.identifierIsValid(a.leaseID))
    }
}
