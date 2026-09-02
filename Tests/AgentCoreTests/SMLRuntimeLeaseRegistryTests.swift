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
            scope: [:]
        )
    }

    func testCreatingOperationBindsTheCommandsOwnTask() async {
        let lease = SMLRuntimeLeaseRegistry.Session()
        let run = envelope(task: "TASK-NEW", op: SMLRuntimeCommandOperation.workflowRun)
        let tasks = await lease.authorizedTasks(for: run)
        XCTAssertTrue(tasks.contains("TASK-NEW"))
        let owns = await lease.ownsTask("TASK-NEW")
        XCTAssertTrue(owns, "creating op must durably bind the task to the lease")
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
