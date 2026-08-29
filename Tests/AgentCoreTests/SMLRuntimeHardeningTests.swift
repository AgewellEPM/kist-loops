import XCTest
@testable import AgentCore

final class SMLRuntimeHardeningTests: XCTestCase {
    func testRuntimeEnforcesExplicitRequiredInputBoundary() async throws {
        let fixture = try await makeFixture("sml-input-boundary")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admitted = try admitted(capabilityWorkflow(version: "1.0.0", instructionID: "work-v1"))
        _ = try await fixture.runtime.installWorkflow(admitted, role: "operator-role")

        do {
            _ = try await submit(
                fixture, id: "missing-input", task: "TASK-MISSING",
                op: SMLRuntimeCommandOperation.workflowRun,
                arguments: ["workflow_id": .string("bounded.workflow")]
            )
            XCTFail("required interface input must be present")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .missingRequiredInput("value"))
        }

        do {
            _ = try await submit(
                fixture, id: "hidden-input", task: "TASK-HIDDEN",
                op: SMLRuntimeCommandOperation.workflowRun,
                arguments: [
                    "workflow_id": .string("bounded.workflow"),
                    "initial_state": .object([
                        "value": .string("ok"),
                        "result": .string("caller-must-not-preseed-output"),
                    ]),
                ]
            )
            XCTFail("output-only fields must not be accepted as caller input")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .inputFieldDenied("result"))
        }
    }

    func testExpectedStatePreventsStaleApproval() async throws {
        let fixture = try await makeFixture("sml-expected-state")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admitted = try admitted(approvalWorkflow())
        _ = try await fixture.runtime.installWorkflow(admitted, role: "operator-role")
        let run = try await submit(
            fixture, id: "run-approval", task: "TASK-APPROVAL",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("approval.workflow")]
        )

        do {
            _ = try await submit(
                fixture, id: "stale-approval", task: "TASK-APPROVAL",
                op: SMLRuntimeCommandOperation.taskApprove,
                expectedState: [
                    "task_revision": .number(
                        Decimal(try XCTUnwrap(run.task?.taskRevision))
                    ),
                    "instruction_id": .string("old-gate"),
                ]
            )
            XCTFail("stale expected state must fail before mutation")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .expectedStateMismatch("expected_state.instruction_id")
            )
        }

        let approved = try await submit(
            fixture, id: "fresh-approval", task: "TASK-APPROVAL",
            op: SMLRuntimeCommandOperation.taskApprove,
            expectedState: [
                "task_revision": .number(
                    Decimal(try XCTUnwrap(run.task?.taskRevision))
                ),
                "instruction_id": .string("approval"),
                "task_status": .string("waiting_approval"),
                "workflow_version": .string("1.0.0"),
            ]
        )
        XCTAssertEqual(approved.task?.status, .completed)
    }

    func testApprovalRequiresCurrentRevisionAndExactOwnerGrant() async throws {
        let fixture = try await makeFixture("sml-approval-owner")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.runtime.installWorkflow(
            try admitted(approvalWorkflow()), role: "operator-role"
        )
        let run = try await submit(
            fixture, id: "owner-run", task: "TASK-OWNER",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("approval.workflow")]
        )
        let revision = try XCTUnwrap(run.task?.taskRevision)
        let before = try await fixture.store.load().tasks["TASK-OWNER"]

        do {
            _ = try await submit(
                fixture, id: "owner-missing-revision", task: "TASK-OWNER",
                op: SMLRuntimeCommandOperation.taskApprove
            )
            XCTFail("approval without the watch revision must fail")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .expectedStateMismatch("expected_state.task_revision")
            )
        }
        do {
            _ = try await submit(
                fixture, id: "owner-denied", task: "TASK-OWNER",
                op: SMLRuntimeCommandOperation.taskApprove,
                expectedState: ["task_revision": .number(Decimal(revision))],
                approvalAuthorities: []
            )
            XCTFail("task role alone must not grant a workflow approval owner")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .approvalAuthorityDenied("human"))
        }

        let afterDenials = try await fixture.store.load().tasks["TASK-OWNER"]
        XCTAssertEqual(afterDenials?.revision, before?.revision)
        XCTAssertEqual(afterDenials?.receiptIDs, before?.receiptIDs)

        let approved = try await submit(
            fixture, id: "owner-approved", task: "TASK-OWNER",
            op: SMLRuntimeCommandOperation.taskApprove,
            expectedState: ["task_revision": .number(Decimal(revision))]
        )
        XCTAssertEqual(approved.task?.status, .completed)
        XCTAssertEqual(approved.task?.taskRevision, revision + 1)
    }

    func testTaskRevisionClosesSameInstructionABARace() async throws {
        let fixture = try await makeFixture("sml-approval-aba")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.runtime.installWorkflow(
            try admitted(repeatingApprovalWorkflow()), role: "operator-role"
        )
        let first = try await submit(
            fixture, id: "aba-run", task: "TASK-ABA",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("approval.aba")]
        )
        let firstRevision = try XCTUnwrap(first.task?.taskRevision)
        let repeated = try await submit(
            fixture, id: "aba-first-approval", task: "TASK-ABA",
            op: SMLRuntimeCommandOperation.taskApprove,
            expectedState: ["task_revision": .number(Decimal(firstRevision))]
        )
        XCTAssertEqual(repeated.task?.status, .waitingApproval)
        XCTAssertEqual(repeated.task?.currentInstructionID, "approval")
        XCTAssertEqual(repeated.task?.taskRevision, firstRevision + 1)

        do {
            _ = try await submit(
                fixture, id: "aba-delayed-approval", task: "TASK-ABA",
                op: SMLRuntimeCommandOperation.taskApprove,
                expectedState: ["task_revision": .number(Decimal(firstRevision))]
            )
            XCTFail("an old approval must not match a later recurrence of the same gate")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .expectedStateMismatch("expected_state.task_revision")
            )
        }

        let final = try await submit(
            fixture, id: "aba-current-approval", task: "TASK-ABA",
            op: SMLRuntimeCommandOperation.taskApprove,
            expectedState: [
                "task_revision": .number(Decimal(firstRevision + 1)),
            ]
        )
        XCTAssertEqual(final.task?.status, .completed)
    }

    func testConcurrentApprovalsWithSameRevisionMutateExactlyOnce() async throws {
        let fixture = try await makeFixture("sml-approval-concurrent")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.runtime.installWorkflow(
            try admitted(approvalWorkflow()), role: "operator-role"
        )
        let run = try await submit(
            fixture, id: "concurrent-run", task: "TASK-CONCURRENT-APPROVAL",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("approval.workflow")]
        )
        let revision = try XCTUnwrap(run.task?.taskRevision)
        let expected: SMLObject = ["task_revision": .number(Decimal(revision))]

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for id in ["concurrent-approve-a", "concurrent-approve-b"] {
                group.addTask {
                    do {
                        _ = try await self.submit(
                            fixture, id: id, task: "TASK-CONCURRENT-APPROVAL",
                            op: SMLRuntimeCommandOperation.taskApprove,
                            expectedState: expected
                        )
                        return true
                    } catch { return false }
                }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 1)
        let snapshot = try await fixture.store.load()
        XCTAssertEqual(snapshot.tasks["TASK-CONCURRENT-APPROVAL"]?.revision, revision + 1)
        XCTAssertEqual(snapshot.receipts.values.filter { $0.kind == .approved }.count, 1)
    }

    func testTasksRemainPinnedAcrossWorkflowUpgrade() async throws {
        let fixture = try await makeFixture("sml-version-pin")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let v1 = try admitted(capabilityWorkflow(version: "1.0.0", instructionID: "work-v1"))
        let v2 = try admitted(capabilityWorkflow(version: "2.0.0", instructionID: "work-v2"))
        _ = try await fixture.runtime.installWorkflow(v1, role: "operator-role")
        let oldTask = try await submit(
            fixture, id: "run-v1", task: "TASK-V1",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("bounded.workflow"),
                "initial_state": .object(["value": .string("old")]),
            ]
        )
        XCTAssertEqual(oldTask.task?.currentInstructionID, "work-v1")

        _ = try await fixture.runtime.installWorkflow(v2, role: "operator-role")
        let pinnedOld = try await fixture.runtime.pendingCapability(taskID: "TASK-V1")
        XCTAssertEqual(pinnedOld.workflowVersion, "1.0.0")
        XCTAssertEqual(pinnedOld.instructionID, "work-v1")

        let explicitOld = try await submit(
            fixture, id: "run-explicit-v1", task: "TASK-EXPLICIT-V1",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("bounded.workflow"),
                "workflow_version": .string("1.0.0"),
                "initial_state": .object(["value": .string("old-again")]),
            ]
        )
        XCTAssertEqual(explicitOld.task?.workflowVersion, "1.0.0")
        XCTAssertEqual(explicitOld.task?.currentInstructionID, "work-v1")

        let newTask = try await submit(
            fixture, id: "run-v2", task: "TASK-V2",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("bounded.workflow"),
                "initial_state": .object(["value": .string("new")]),
            ]
        )
        XCTAssertEqual(newTask.task?.workflowVersion, "2.0.0")
        XCTAssertEqual(newTask.task?.currentInstructionID, "work-v2")

        let snapshot = try await fixture.store.load()
        XCTAssertEqual(snapshot.workflows.count, 2)
        XCTAssertEqual(snapshot.activeWorkflowVersions["bounded.workflow"], "2.0.0")
    }

    func testRestartRequiresFreshHostAdmissionBindingBeforeCapabilityAdvance() async throws {
        let fixture = try await makeFixture("sml-rebind")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admittedWorkflow = try admitted(
            capabilityWorkflow(version: "1.0.0", instructionID: "work-v1")
        )
        _ = try await fixture.runtime.installWorkflow(admittedWorkflow, role: "operator-role")
        _ = try await submit(
            fixture, id: "run-before-restart", task: "TASK-RESTART",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("bounded.workflow"),
                "initial_state": .object(["value": .string("x")]),
            ]
        )

        let restarted = SMLRuntime(store: fixture.store, clock: { 1_000 })
        do {
            _ = try await restarted.pendingCapability(taskID: "TASK-RESTART")
            XCTFail("durable bytes must not stand in for live host admission")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .workflowAdmissionNotBound(id: "bounded.workflow", version: "1.0.0")
            )
        }

        _ = try await restarted.installWorkflow(admittedWorkflow, role: "operator-role")
        let rebound = try await restarted.pendingCapability(taskID: "TASK-RESTART")
        XCTAssertEqual(rebound.workflowVersion, "1.0.0")
        XCTAssertEqual(rebound.instructionID, "work-v1")
    }

    func testSameSemanticVersionCannotOverwriteDifferentGraph() async throws {
        let fixture = try await makeFixture("sml-version-conflict")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try admitted(capabilityWorkflow(version: "1.0.0", instructionID: "work-v1"))
        let conflicting = try admitted(capabilityWorkflow(version: "1.0.0", instructionID: "work-other"))
        _ = try await fixture.runtime.installWorkflow(first, role: "operator-role")
        do {
            _ = try await fixture.runtime.installWorkflow(conflicting, role: "operator-role")
            XCTFail("one id/version must identify one exact graph")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .workflowVersionConflict(id: "bounded.workflow", version: "1.0.0")
            )
        }
    }

    func testWorkflowScopedCommandsCannotReadOrMutateAnotherWorkflowTask() async throws {
        let fixture = try await makeFixture("sml-workflow-binding")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.runtime.installWorkflow(
            try admitted(approvalWorkflow()), role: "operator-role"
        )
        _ = try await submit(
            fixture, id: "run-bound", task: "TASK-BOUND",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("approval.workflow"),
                "workflow_version": .string("1.0.0"),
            ]
        )

        for (id, op) in [
            ("cross-watch", SMLRuntimeCommandOperation.taskWatch),
            ("cross-rollback", SMLRuntimeCommandOperation.taskRollback),
            ("cross-receipts", SMLRuntimeCommandOperation.receiptsList),
        ] {
            do {
                _ = try await submit(
                    fixture, id: id, task: "TASK-BOUND", op: op,
                    arguments: [
                        "workflow_id": .string("other.workflow"),
                        "workflow_version": .string("1.0.0"),
                    ]
                )
                XCTFail("workflow-scoped command must not cross task ownership")
            } catch let error as SMLRuntimeError {
                XCTAssertEqual(error, .workflowBindingMismatch("workflow_id"))
            }
        }
    }

    func testApprovalAfterRestartRequiresExactLiveAdmission() async throws {
        let fixture = try await makeFixture("sml-approval-rebind")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let admittedWorkflow = try admitted(approvalWorkflow())
        _ = try await fixture.runtime.installWorkflow(admittedWorkflow, role: "operator-role")
        _ = try await submit(
            fixture, id: "run-approval-rebind", task: "TASK-APPROVAL-REBIND",
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: ["workflow_id": .string("approval.workflow")]
        )

        let restarted = SMLRuntime(store: fixture.store, clock: { 1_000 })
        do {
            _ = try await submit(
                fixture.with(runtime: restarted),
                id: "approve-without-rebind", task: "TASK-APPROVAL-REBIND",
                op: SMLRuntimeCommandOperation.taskApprove
            )
            XCTFail("durable workflow bytes cannot authorize an approval transition")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .workflowAdmissionNotBound(id: "approval.workflow", version: "1.0.0")
            )
        }
    }

    func testReceiptIDsPreserveCaseAndCannotOverwriteAnotherTask() async throws {
        let fixture = try await makeFixture("sml-receipt-case")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.runtime.installWorkflow(
            try admitted(approvalWorkflow()), role: "operator-role"
        )
        for (id, task) in [("run-upper", "TASK-A"), ("run-lower", "task-a")] {
            _ = try await submit(
                fixture, id: id, task: task,
                op: SMLRuntimeCommandOperation.workflowRun,
                arguments: ["workflow_id": .string("approval.workflow")]
            )
        }

        let snapshot = try await fixture.store.load()
        XCTAssertNotNil(snapshot.receipts["TASK-A.receipt-1"])
        XCTAssertNotNil(snapshot.receipts["task-a.receipt-1"])
        XCTAssertEqual(snapshot.tasks["TASK-A"]?.receiptIDs.count, 2)
        XCTAssertEqual(snapshot.tasks["task-a"]?.receiptIDs.count, 2)
        XCTAssertEqual(snapshot.receipts.count, 4)
    }

    func testDurableWorkflowBytesMustEqualLiveAdmittedRevision() async throws {
        let fixture = try await makeFixture("sml-admission-equality")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try admitted(
            capabilityWorkflow(version: "1.0.0", instructionID: "work-v1")
        )
        _ = try await fixture.runtime.installWorkflow(original, role: "operator-role")
        try await fixture.store.update { snapshot in
            let altered = capabilityWorkflow(version: "1.0.0", instructionID: "work-altered")
            snapshot.workflows[
                SMLRuntimeSnapshot.workflowStorageKey(
                    id: altered.id, version: altered.version
                )
            ] = SMLRuntimeWorkflowRecord(
                role: "operator-role", workflow: altered, installedAtEpoch: 1_000
            )
        }

        do {
            _ = try await submit(
                fixture, id: "run-altered", task: "TASK-ALTERED",
                op: SMLRuntimeCommandOperation.workflowRun,
                arguments: [
                    "workflow_id": .string("bounded.workflow"),
                    "initial_state": .object(["value": .string("x")]),
                ]
            )
            XCTFail("matching id/version is not enough; admitted bytes must match exactly")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .workflowAdmissionNotBound(id: "bounded.workflow", version: "1.0.0")
            )
        }
    }

    func testRuntimeReadCommandsAreBoundToAuthenticatedCommandRole() async throws {
        let fixture = try await makeFixture("sml-read-role-binding")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.runtime.installWorkflow(
            try admitted(terminalWorkflow(id: "visible.workflow")),
            role: "operator-role"
        )
        _ = try await fixture.runtime.installWorkflow(
            try admitted(terminalWorkflow(id: "hidden.workflow")),
            role: "other-role"
        )

        let workflows = try await submit(
            fixture, id: "read-workflows", task: "runtime",
            op: SMLRuntimeCommandOperation.workflowsList
        )
        XCTAssertEqual(workflows.workflows.map(\.id), ["visible.workflow"])

        let roles = try await submit(
            fixture, id: "read-roles", task: "runtime",
            op: SMLRuntimeCommandOperation.rolesList
        )
        XCTAssertEqual(roles.roles.map(\.role), ["operator-role"])

        let status = try await submit(
            fixture, id: "read-status", task: "runtime",
            op: SMLRuntimeCommandOperation.status
        )
        XCTAssertEqual(status.status?.workflowCount, 1)
        XCTAssertEqual(status.status?.roleCount, 1)

        let visible = try await submit(
            fixture, id: "read-visible", task: "runtime",
            op: SMLRuntimeCommandOperation.workflowInspect,
            arguments: ["workflow_id": .string("visible.workflow")]
        )
        XCTAssertEqual(visible.workflow?.workflow.id, "visible.workflow")

        do {
            _ = try await submit(
                fixture, id: "read-other-role-list", task: "runtime",
                op: SMLRuntimeCommandOperation.workflowsList,
                arguments: ["role_id": .string("other-role")]
            )
            XCTFail("a command must not select another role's workflow catalog")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(
                error,
                .invalidArgument("role_id must match the command role")
            )
        }
        do {
            _ = try await submit(
                fixture, id: "read-hidden-inspect", task: "runtime",
                op: SMLRuntimeCommandOperation.workflowInspect,
                arguments: ["workflow_id": .string("hidden.workflow")]
            )
            XCTFail("inspect must not reveal another role's workflow")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .workflowNotInstalled("hidden.workflow"))
        }
    }

    func testLegacyTaskAndProjectionDecodeWithRevisionZeroButRejectNegativeRevision() throws {
        let task = SMLRuntimeTask(
            taskID: "TASK-LEGACY",
            role: "operator-role",
            workflowID: "legacy.workflow",
            workflowVersion: "1.0.0",
            currentInstructionID: "done",
            status: .completed,
            createdAtEpoch: 1,
            updatedAtEpoch: 1
        )
        var taskObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(task))
                as? [String: Any]
        )
        taskObject.removeValue(forKey: "task_revision")
        let legacyTask = try JSONDecoder().decode(
            SMLRuntimeTask.self,
            from: JSONSerialization.data(withJSONObject: taskObject)
        )
        XCTAssertEqual(legacyTask.revision, 0)

        let projection = SMLTaskProjection(
            taskID: "TASK-LEGACY",
            role: "operator-role",
            workflowID: "legacy.workflow",
            workflowVersion: "1.0.0",
            status: .completed,
            currentInstructionID: "done",
            currentOperation: .complete,
            waitingApprovalOwner: nil,
            state: [:],
            receiptIDs: []
        )
        var projectionObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(projection))
                as? [String: Any]
        )
        projectionObject.removeValue(forKey: "task_revision")
        let legacyProjection = try JSONDecoder().decode(
            SMLTaskProjection.self,
            from: JSONSerialization.data(withJSONObject: projectionObject)
        )
        XCTAssertEqual(legacyProjection.taskRevision, 0)

        taskObject["task_revision"] = -1
        XCTAssertThrowsError(try JSONDecoder().decode(
            SMLRuntimeTask.self,
            from: JSONSerialization.data(withJSONObject: taskObject)
        ))
    }

    private struct Fixture {
        let directory: URL
        let store: SMLRuntimeStore
        let runtime: SMLRuntime

        func with(runtime: SMLRuntime) -> Fixture {
            Fixture(directory: directory, store: store, runtime: runtime)
        }
    }

    private func makeFixture(_ prefix: String) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        return Fixture(
            directory: directory,
            store: store,
            runtime: SMLRuntime(store: store, clock: { 1_000 })
        )
    }

    private func submit(
        _ fixture: Fixture,
        id: String,
        task: String,
        op: String,
        arguments: SMLObject = [:],
        expectedState: SMLObject = [:],
        role: String = "operator-role",
        approvalAuthorities: Set<String> = ["human"]
    ) async throws -> SMLCommandResult {
        let command = SMLCommandEnvelope(
            commandID: id,
            actor: "operator.luke",
            role: role,
            task: task,
            op: op,
            arguments: arguments,
            expectedState: expectedState,
            issuedAtEpoch: 1_000
        )
        let admitted = try await SMLCommandAdmission.admit(
            command,
            authority: SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "lease-1",
                roles: [role],
                tasks: [task],
                operations: SMLRuntimeCommandOperation.all,
                approvalAuthorities: approvalAuthorities,
                scope: [:]
            ),
            nowEpoch: 1_000,
            replayGuard: fixture.store
        )
        return try await fixture.runtime.submit(admitted)
    }

    private func admitted(_ workflow: SMLWorkflow) throws -> SMLAdmittedWorkflow {
        try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["tool.v1", "tool.v2"],
                approvalAuthorities: ["human"]
            )
        )
    }

    private func capabilityWorkflow(version: String, instructionID: String) -> SMLWorkflow {
        let capability = version.hasPrefix("2") ? "tool.v2" : "tool.v1"
        return SMLWorkflow(
            id: "bounded.workflow",
            version: version,
            name: "Bounded \(instructionID)",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "value", type: .string),
                .init(name: "result", type: .string, required: false),
            ],
            interface: .init(inputFields: ["value"], outputFields: ["result"]),
            entrypoint: instructionID,
            instructions: [
                .init(id: instructionID, op: .callTool, capability: capability, next: "receipt"),
                .init(id: "receipt", op: .emitReceipt, receiptFields: ["result"]),
            ]
        )
    }

    private func approvalWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "approval.workflow",
            version: "1.0.0",
            name: "Approval",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "approval",
            instructions: [
                .init(id: "approval", op: .waitApproval, reason: "release",
                      owner: "human", next: "done", onFailure: "refused"),
                .init(id: "done", op: .complete),
                .init(id: "refused", op: .escalate, reason: "refused", owner: "human"),
            ]
        )
    }

    private func repeatingApprovalWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "approval.aba",
            version: "1.0.0",
            name: "Repeating approval",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "approval",
            instructions: [
                .init(id: "approval", op: .waitApproval, reason: "release",
                      owner: "human", next: "retry", onFailure: "refused"),
                .init(id: "retry", op: .retry,
                      retryPolicy: .init(target: "approval", maximumAttempts: 1),
                      onFailure: "done"),
                .init(id: "done", op: .complete),
                .init(id: "refused", op: .escalate, reason: "refused", owner: "human"),
            ]
        )
    }

    private func terminalWorkflow(id: String) -> SMLWorkflow {
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
}
