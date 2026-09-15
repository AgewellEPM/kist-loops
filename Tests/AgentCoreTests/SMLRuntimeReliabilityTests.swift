import XCTest
@testable import AgentCore

/// Local end-to-end runtime regressions. Every capability is an in-memory fake driver.
final class SMLRuntimeReliabilityTests: XCTestCase {
    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private struct FakeDriver: SMLInstructionDriver {
        enum Result: Sendable { case passed, failed, cancelled }
        let id = "reliability-driver"
        let result: Result
        let counter: Counter

        func supports(_ request: SMLCapabilityRequest) -> Bool {
            request.reference == "fake.step"
        }

        func execute(_ invocation: SMLCapabilityInvocation) async throws -> SMLCapabilityOutcome {
            await counter.increment()
            if result == .cancelled {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return SMLCapabilityOutcome(
                dispatchID: invocation.dispatchID,
                instructionID: invocation.request.instructionID,
                requestStateDigest: invocation.request.stateDigest,
                status: result == .failed ? .failed : .passed,
                statePatch: ["result": .string("driver output")],
                evidence: SMLCapabilityEvidence(
                    receiptID: "fake.receipt", source: id,
                    digest: String(repeating: "a", count: 64), observedAtEpoch: 1_000
                )
            )
        }
    }

    private struct Fixture {
        let directory: URL
        let workflow: SMLWorkflow
        let store: SMLRuntimeStore
        let runtime: SMLRuntime
        let gateway: SMLCommandGateway
        let coordinator: SMLCapabilityCoordinator
        let gated: SMLApprovalGatedCoordinator
        let counter: Counter
    }

    private func makeFixture(
        workflow: SMLWorkflow,
        policy: SMLApprovalPolicy = SMLApprovalPolicy(),
        applyGates: Bool = true,
        result: FakeDriver.Result = .passed
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-reliability-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(fileURL: directory.appendingPathComponent("runtime.json"), clock: { 1_000 })
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let effective = applyGates ? try SMLWorkflowApprovalGating.gate(workflow, policy: policy) : workflow
        let admission = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(effective),
            catalog: SMLExecutionAdmissionCatalog(
                observationSources: ["fake.step"], retrievalSources: ["fake.step"],
                toolCapabilities: ["fake.step"], modelPurposes: ["fake.step"],
                modelOutputSchemas: ["fake.schema"], approvalAuthorities: ["host-operator"]
            )
        )
        _ = try await runtime.installWorkflow(admission, role: "operator-role")
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        let counter = Counter()
        let coordinator = SMLCapabilityCoordinator(
            runtime: runtime,
            router: SMLCapabilityRouter(drivers: [FakeDriver(result: result, counter: counter)]),
            claimCompiler: SMLCapabilityClaimCompiler(actor: "operator.luke"),
            completionCompiler: SMLCapabilityCompletionCompiler(actor: "operator.luke"),
            gateway: gateway,
            authorityResolver: { Self.authority(for: $0) },
            clock: { 1_000 }
        )
        return Fixture(
            directory: directory, workflow: effective, store: store, runtime: runtime,
            gateway: gateway, coordinator: coordinator,
            gated: SMLApprovalGatedCoordinator(coordinator: coordinator, store: store, policy: policy),
            counter: counter
        )
    }

    private static func authority(for command: SMLCommandEnvelope) -> SMLCommandAuthority {
        SMLCommandAuthority(
            authenticatedActor: "operator.luke", leaseID: "reliability-lease",
            roles: ["operator-role"], tasks: [command.task], operations: SMLRuntimeCommandOperation.all,
            approvalAuthorities: ["host-operator"], scope: [:]
        )
    }

    private func submit(
        _ fixture: Fixture,
        operation: String,
        arguments: SMLObject = [:],
        expectedState: SMLObject = [:]
    ) async throws -> SMLCommandResult {
        let command = SMLCommandEnvelope(
            actor: "operator.luke", role: "operator-role", task: "TASK-RELIABILITY", op: operation,
            arguments: arguments, expectedState: expectedState, issuedAtEpoch: 1_000
        )
        return try await fixture.gateway.submit(command, authority: Self.authority(for: command), nowEpoch: 1_000)
    }

    private func start(_ fixture: Fixture, initialState: SMLObject = [:]) async throws {
        _ = try await submit(fixture, operation: SMLRuntimeCommandOperation.workflowRun, arguments: [
            "workflow_id": .string(fixture.workflow.id),
            "workflow_version": .string(fixture.workflow.version),
            "initial_state": .object(initialState),
        ])
    }

    private func approve(_ fixture: Fixture) async throws {
        let snapshot = try await fixture.store.load()
        let task = try XCTUnwrap(snapshot.tasks["TASK-RELIABILITY"])
        _ = try await submit(
            fixture, operation: SMLRuntimeCommandOperation.taskApprove,
            expectedState: ["task_revision": .number(Decimal(task.revision))]
        )
    }

    private func workflow(operation: SMLInstructionOperation = .callTool) -> SMLWorkflow {
        SMLWorkflow(
            id: "reliability.workflow", version: "1.0.0", name: "Reliability",
            source: .init(kind: .native, reference: "tests://reliability"), trigger: .init(kind: .manual),
            stateSchema: [.init(name: "result", type: .string, required: false)],
            interface: .init(outputFields: ["result"]), entrypoint: "work",
            instructions: [
                .init(
                    id: "work", op: operation,
                    source: [.observe, .retrieve].contains(operation) ? "fake.step" : nil,
                    purpose: operation == .callModel ? "fake.step" : nil,
                    capability: operation == .callTool ? "fake.step" : nil,
                    outputSchema: operation == .callModel ? "fake.schema" : nil, next: "done"
                ),
                .init(id: "done", op: .emitReceipt, receiptFields: ["result"]),
            ]
        )
    }

    func testDefiniteFailuresFinishWithDurableEvidenceAndNoPendingClaim() async throws {
        for operation in [SMLInstructionOperation.callTool, .callModel, .observe, .retrieve] {
            let fixture = try await makeFixture(workflow: workflow(operation: operation), applyGates: false, result: .failed)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try await start(fixture)
            let result = try await fixture.coordinator.executeNext(taskID: "TASK-RELIABILITY")
            XCTAssertEqual(result.task?.status, .failed, operation.rawValue)
            XCTAssertNil(result.task?.capabilityDispatchID)
            XCTAssertNil(result.task?.state["result"], "failed output must not become successful workflow state")
            let snapshot = try await fixture.store.load()
            let task = try XCTUnwrap(snapshot.tasks["TASK-RELIABILITY"])
            XCTAssertEqual(task.status, .failed)
            XCTAssertEqual(task.revision, 3)
            XCTAssertNil(task.capabilityClaim)
            let step = try XCTUnwrap(snapshot.receipts.values.first { $0.kind == .stepRecorded })
            XCTAssertEqual(step.payload["outcome"], .string("failed"))
            XCTAssertNotNil(step.payload["dispatch_id"])
            XCTAssertNotNil(step.payload["evidence"])
            XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .completed || $0.kind == .receiptEmitted })
            XCTAssertTrue(SMLRuntimePendingView.build(from: snapshot).isEmpty)
            let status = try await fixture.runtime.status()
            XCTAssertEqual(status.status?.activeTaskCount, 0)
            do {
                _ = try await fixture.coordinator.executeNext(taskID: "TASK-RELIABILITY")
                XCTFail("a terminal failed task must not dispatch again")
            } catch is SMLRuntimeError { }
            let count = await fixture.counter.count
            XCTAssertEqual(count, 1)
        }
    }

    func testFreeRunAndExactReferenceOverrideDispatchWithoutInjectedGate() async throws {
        for policy in [SMLApprovalPolicy(defaultMode: .freeRun), SMLApprovalPolicy(overrides: ["CALL_TOOL:fake.step": .freeRun])] {
            let fixture = try await makeFixture(workflow: workflow(), policy: policy)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try await start(fixture)
            let result = try await fixture.gated.executeNext(taskID: "TASK-RELIABILITY")
            XCTAssertEqual(result.task?.status, .completed)
            let count = await fixture.counter.count
            XCTAssertEqual(count, 1)
        }
    }

    func testApproveSideEffectsRunsReadStepsAndKeepsToolApproval() async throws {
        let policy = SMLApprovalPolicy(defaultMode: .approveSideEffects)
        for operation in [SMLInstructionOperation.observe, .retrieve] {
            let fixture = try await makeFixture(workflow: workflow(operation: operation), policy: policy)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            try await start(fixture)
            let result = try await fixture.gated.executeNext(taskID: "TASK-RELIABILITY")
            XCTAssertEqual(result.task?.status, .completed)
        }
        let fixture = try await makeFixture(workflow: workflow(), policy: policy)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture)
        do {
            _ = try await fixture.gated.executeNext(taskID: "TASK-RELIABILITY")
            XCTFail("CALL_TOOL still requires approval")
        } catch { }
        let before = await fixture.counter.count
        XCTAssertEqual(before, 0)
        try await approve(fixture)
        let result = try await fixture.gated.executeNext(taskID: "TASK-RELIABILITY")
        XCTAssertEqual(result.task?.status, .completed)
    }

    func testBranchSpecificAuthorGatesDispatchAfterEitherActualApproval() async throws {
        let branched = SMLWorkflow(
            id: "reliability.branches", version: "1.0.0", name: "Branch approvals",
            source: .init(kind: .native, reference: "tests://branches"), trigger: .init(kind: .manual),
            stateSchema: [.init(name: "route", type: .boolean), .init(name: "result", type: .string, required: false)],
            interface: .init(inputFields: ["route"], outputFields: ["result"]), entrypoint: "choose",
            instructions: [
                .init(id: "choose", op: .branch,
                      condition: .init(clauses: [.init(field: "route", op: .equals, value: .bool(true))]),
                      trueTarget: "first-gate", falseTarget: "second-gate"),
                .init(id: "first-gate", op: .waitApproval, reason: "first branch", owner: "host-operator", next: "work", onFailure: "refused"),
                .init(id: "second-gate", op: .waitApproval, reason: "second branch", owner: "host-operator", next: "work", onFailure: "refused"),
                .init(id: "work", op: .callTool, capability: "fake.step", next: "done"),
                .init(id: "done", op: .emitReceipt, receiptFields: ["result"]),
                .init(id: "refused", op: .escalate, reason: "refused", owner: "host-operator"),
            ]
        )
        for route in [true, false] {
            let fixture = try await makeFixture(workflow: branched)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            XCTAssertEqual(fixture.workflow.instructions.filter { $0.op == .waitApproval && $0.next == "work" }.count, 2)
            try await start(fixture, initialState: ["route": .bool(route)])
            try await approve(fixture)
            let result = try await fixture.gated.executeNext(taskID: "TASK-RELIABILITY")
            XCTAssertEqual(result.task?.status, .completed)
        }
    }

    func testChangedTaskRevisionRejectsDispatchBeforeDriver() async throws {
        let fixture = try await makeFixture(workflow: workflow(), applyGates: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture)
        do {
            _ = try await fixture.coordinator.executeNext(taskID: "TASK-RELIABILITY", expectedTaskRevision: 0)
            XCTFail("stale task revision must be rejected")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .expectedStateMismatch("expected_state.task_revision"))
        }
        let count = await fixture.counter.count
        XCTAssertEqual(count, 0)
        let snapshot = try await fixture.store.load()
        XCTAssertNil(snapshot.tasks["TASK-RELIABILITY"]?.capabilityClaim)
    }

    func testCancelledDriverReturningSuccessKeepsClaimWithoutCompletion() async throws {
        let fixture = try await makeFixture(workflow: workflow(), applyGates: false, result: .cancelled)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture)
        let execution = Task { try await fixture.coordinator.executeNext(taskID: "TASK-RELIABILITY") }
        do {
            _ = try await execution.value
            XCTFail("cancelled execution must not publish a completion")
        } catch is CancellationError { }
        let snapshot = try await fixture.store.load()
        XCTAssertEqual(snapshot.tasks["TASK-RELIABILITY"]?.status, .waitingCapability)
        XCTAssertNotNil(snapshot.tasks["TASK-RELIABILITY"]?.capabilityClaim)
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .stepRecorded })
    }

    private func interruptedFixture() async throws -> (Fixture, SMLRuntimeTask) {
        let fixture = try await makeFixture(workflow: workflow(), applyGates: false, result: .cancelled)
        try await start(fixture)
        let execution = Task { try await fixture.coordinator.executeNext(taskID: "TASK-RELIABILITY") }
        do {
            _ = try await execution.value
            XCTFail("fixture must leave an interrupted claim")
        } catch is CancellationError { }
        let snapshot = try await fixture.store.load()
        return (fixture, try XCTUnwrap(snapshot.tasks["TASK-RELIABILITY"]))
    }

    private static func recoveryAuthority(
        for command: SMLCommandEnvelope,
        leaseID: String = "restarted-lease",
        operations: Set<String> = SMLRuntimeCommandOperation.all
    ) -> SMLCommandAuthority {
        SMLCommandAuthority(
            authenticatedActor: "operator.luke", leaseID: leaseID,
            roles: ["operator-role"], tasks: [command.task], operations: operations,
            scope: [:]
        )
    }

    private func recoverySurface(_ fixture: Fixture) throws -> SMLWorkflowSurface {
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(fixture.workflow),
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["fake.step"])
        )
        return try SMLWorkflowSurface.compile(admitted: admitted, role: "operator-role")
    }

    func testReconciliationREPLAndAPIBindTheSameDispatchAndRevision() async throws {
        let fixture = try await makeFixture(workflow: workflow(), applyGates: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let surface = try recoverySurface(fixture)
        let repl = SMLWorkflowREPLCompiler(surface: surface, actor: "operator.luke")
        let line = #"reconcile TASK-RELIABILITY {"task_revision":2,"dispatch_id":"dispatch-old","note":"Previous host stopped"}"#
        guard case .command(let replCommand) = try repl.compile(line, issuedAtEpoch: 1_000) else {
            return XCTFail("reconcile must compile to a runtime command")
        }
        let api = try SMLWorkflowAPICompiler(surface: surface, actor: "operator.luke")
        let apiCommand = try api.compile(.init(
            method: .post,
            path: "/v1/workflows/reliability.workflow/tasks/TASK-RELIABILITY/reconcile",
            body: ["task_revision": .number(2), "dispatch_id": .string("dispatch-old"), "note": .string("Previous host stopped")]
        ), issuedAtEpoch: 1_000)
        XCTAssertEqual(replCommand.op, SMLRuntimeCommandOperation.taskReconcile)
        XCTAssertEqual(replCommand.arguments, apiCommand.arguments)
        XCTAssertEqual(replCommand.expectedState, ["task_revision": .number(2)])
        XCTAssertEqual(apiCommand.expectedState, replCommand.expectedState)
        XCTAssertTrue(surface.grammar().contains("reconcile TASK_ID"))
        XCTAssertTrue(api.catalog.endpoints.contains { $0.action == .reconcile })
        XCTAssertFalse(SMLWorkflowSurface.modelDefaultActions.contains(.reconcile))
        XCTAssertThrowsError(try repl.compile(
            #"reconcile TASK-RELIABILITY {"task_revision":2,"dispatch_id":"dispatch-old","note":"   "}"#,
            issuedAtEpoch: 1_000
        ))
    }

    func testPriorSessionReconciliationRetiresUnknownClaimWithoutRepeatingDriver() async throws {
        let (fixture, task) = try await interruptedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let claim = try XCTUnwrap(task.capabilityClaim)
        let api = SMLWorkflowAPI(
            compiler: try SMLWorkflowAPICompiler(surface: recoverySurface(fixture), actor: "operator.luke"),
            gateway: fixture.gateway,
            authorityResolver: { Self.recoveryAuthority(for: $0) },
            clock: { 1_000 }
        )
        let response = try await api.handle(.init(
            method: .post,
            path: "/v1/workflows/reliability.workflow/tasks/TASK-RELIABILITY/reconcile",
            body: [
                "task_revision": .number(Decimal(task.revision)),
                "dispatch_id": .string(claim.dispatchID),
                "note": .string("Previous host stopped; retiring this task"),
            ]
        ))
        XCTAssertEqual(response.result.task?.status, .failed)
        XCTAssertNil(response.result.task?.capabilityDispatchID)
        let snapshot = try await fixture.store.load()
        let reconciled = try XCTUnwrap(snapshot.receipts.values.first { $0.kind == .reconciled })
        XCTAssertEqual(reconciled.payload["external_outcome"], .string("unknown"))
        XCTAssertEqual(reconciled.payload["outcome"], .string("abandoned"))
        XCTAssertEqual(reconciled.payload["dispatch_id"], .string(claim.dispatchID))
        XCTAssertEqual(reconciled.payload["original_lease_id"], .string(claim.leaseID))
        XCTAssertEqual(reconciled.payload["note"], .string("Previous host stopped; retiring this task"))
        XCTAssertEqual(snapshot.tasks[task.taskID]?.revision, task.revision + 1)
        XCTAssertNil(snapshot.tasks[task.taskID]?.capabilityClaim)
        XCTAssertTrue(snapshot.receipts.values.contains { $0.kind == .capabilityClaimed })
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .stepRecorded || $0.kind == .completed })
        XCTAssertTrue(SMLRuntimePendingView.build(from: snapshot).isEmpty)
        do {
            _ = try await fixture.coordinator.executeNext(taskID: task.taskID)
            XCTFail("reconciliation must never replay the original dispatch")
        } catch is SMLRuntimeError { }
        let count = await fixture.counter.count
        XCTAssertEqual(count, 1)
    }

    func testReconciliationRequiresPriorSessionExactClaimAndOperatorNote() async throws {
        let (fixture, task) = try await interruptedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let claim = try XCTUnwrap(task.capabilityClaim)
        let attempts: [(String, Int, String, String, SMLRuntimeError)] = [
            (claim.leaseID, task.revision, claim.dispatchID, "note", .invalidTaskState("stop and restart this host before reconciling a claim from its current session")),
            ("restarted-lease", task.revision - 1, claim.dispatchID, "note", .expectedStateMismatch("expected_state.task_revision")),
            ("restarted-lease", task.revision, "different-dispatch", "note", .capabilityClaimMismatch),
            ("restarted-lease", task.revision, claim.dispatchID, "   ", .invalidArgument("reconciliation note must contain 1...4096 UTF-8 bytes")),
        ]
        for (leaseID, revision, dispatchID, note, expectedError) in attempts {
            let command = SMLCommandEnvelope(
                actor: "operator.luke", role: "operator-role", task: task.taskID,
                op: SMLRuntimeCommandOperation.taskReconcile,
                arguments: ["dispatch_id": .string(dispatchID), "note": .string(note)],
                expectedState: ["task_revision": .number(Decimal(revision))], issuedAtEpoch: 1_000
            )
            do {
                _ = try await fixture.gateway.submit(
                    command, authority: Self.recoveryAuthority(for: command, leaseID: leaseID), nowEpoch: 1_000
                )
                XCTFail("incomplete or stale reconciliation must not mutate the task")
            } catch let error as SMLRuntimeError {
                XCTAssertEqual(error, expectedError)
            }
        }
        let denied = SMLCommandEnvelope(
            actor: "operator.luke", role: "operator-role", task: task.taskID,
            op: SMLRuntimeCommandOperation.taskReconcile,
            arguments: ["dispatch_id": .string(claim.dispatchID), "note": .string("note")],
            expectedState: ["task_revision": .number(Decimal(task.revision))], issuedAtEpoch: 1_000
        )
        do {
            _ = try await fixture.gateway.submit(
                denied, authority: Self.recoveryAuthority(for: denied, operations: [SMLRuntimeCommandOperation.taskWatch]), nowEpoch: 1_000
            )
            XCTFail("reconciliation needs an explicit operation grant")
        } catch let error as SMLCommandAdmissionError {
            XCTAssertEqual(error, .operationDenied)
        }
        let snapshot = try await fixture.store.load()
        XCTAssertEqual(snapshot.tasks[task.taskID], task)
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .reconciled })
    }
}
