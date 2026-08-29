import XCTest
@testable import AgentCore

final class SMLCapabilityDriverTests: XCTestCase {
    func testCoordinatorClaimsBeforeDriverAndPersistsBoundEvidence() async throws {
        let fixture = try await makeFixture("sml-capability-success", workflow: toolWorkflow())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-CAPABILITY")
        let counter = InvocationCounter()
        let coordinator = makeCoordinator(
            fixture,
            driver: StubDriver(
                id: "tool-driver",
                reference: "tool.v1",
                patch: ["result": .string("done")],
                counter: counter
            )
        )

        let result = try await coordinator.executeNext(taskID: "TASK-CAPABILITY")

        XCTAssertEqual(result.task?.status, .completed)
        XCTAssertEqual(result.task?.state["result"], .string("done"))
        XCTAssertNil(result.task?.capabilityDispatchID)
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 1)

        let snapshot = try await fixture.store.load()
        XCTAssertNil(snapshot.tasks["TASK-CAPABILITY"]?.capabilityClaim)
        XCTAssertEqual(snapshot.tasks["TASK-CAPABILITY"]?.revision, 3)
        let claimed = try XCTUnwrap(snapshot.receipts.values.first {
            $0.kind == .capabilityClaimed
        })
        let completed = try XCTUnwrap(snapshot.receipts.values.first {
            $0.kind == .stepRecorded
        })
        XCTAssertEqual(claimed.workflowVersion, "1.0.0")
        XCTAssertEqual(completed.workflowVersion, "1.0.0")
        XCTAssertEqual(completed.payload["dispatch_id"], .string("dispatch-fixed"))
        guard case .object(let evidence)? = completed.payload["evidence"] else {
            return XCTFail("step receipt must retain typed driver evidence")
        }
        XCTAssertEqual(evidence["source"], .string("tool-driver"))
        XCTAssertEqual(evidence["authority"], .string("observed"))
        guard case .string(let completedDigest)? = evidence["request_state_digest"],
              case .string(let preclaimDigest)? = claimed.payload["request_state_digest"] else {
            return XCTFail("dispatch and completion receipts must retain state digests")
        }
        XCTAssertEqual(completedDigest.count, 64)
        XCTAssertEqual(preclaimDigest.count, 64)
        XCTAssertNotEqual(completedDigest, preclaimDigest)
    }

    func testDeniedClaimAuthorityPreventsDriverInvocation() async throws {
        let fixture = try await makeFixture("sml-capability-denied", workflow: toolWorkflow())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-DENIED")
        let counter = InvocationCounter()
        let coordinator = makeCoordinator(
            fixture,
            driver: StubDriver(
                id: "tool-driver", reference: "tool.v1", counter: counter
            ),
            authorityResolver: { command in
                if command.op == SMLRuntimeCommandOperation.taskClaimCapability {
                    throw TestFailure.denied
                }
                return Self.authority(for: command)
            }
        )

        do {
            _ = try await coordinator.executeNext(taskID: "TASK-DENIED")
            XCTFail("denied dispatch authority must stop before driver actuation")
        } catch {
            XCTAssertEqual(error as? TestFailure, .denied)
        }
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 0)
        let snapshot = try await fixture.store.load()
        XCTAssertNil(snapshot.tasks["TASK-DENIED"]?.capabilityClaim)
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .capabilityClaimed })
    }

    func testDeniedCompletionAuthorityAlsoPreventsClaimAndDriverInvocation() async throws {
        let fixture = try await makeFixture(
            "sml-completion-authority-denied", workflow: toolWorkflow()
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-COMPLETION-DENIED")
        let counter = InvocationCounter()
        let coordinator = makeCoordinator(
            fixture,
            driver: StubDriver(
                id: "tool-driver", reference: "tool.v1", counter: counter
            ),
            authorityResolver: { command in
                if command.op == SMLRuntimeCommandOperation.taskRecordStep {
                    throw TestFailure.denied
                }
                return Self.authority(for: command)
            }
        )

        do {
            _ = try await coordinator.executeNext(taskID: "TASK-COMPLETION-DENIED")
            XCTFail("completion authority must be resolved before durable claim or actuation")
        } catch {
            XCTAssertEqual(error as? TestFailure, .denied)
        }
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 0)
        let snapshot = try await fixture.store.load()
        XCTAssertNil(snapshot.tasks["TASK-COMPLETION-DENIED"]?.capabilityClaim)
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .capabilityClaimed })
    }

    func testExactCompletionAuthorityIsResolvedAfterDriverBeforeMutation() async throws {
        let fixture = try await makeFixture(
            "sml-exact-completion-authority", workflow: toolWorkflow()
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-EXACT-AUTHORITY")
        let counter = InvocationCounter()
        let coordinator = makeCoordinator(
            fixture,
            driver: StubDriver(
                id: "tool-driver", reference: "tool.v1", counter: counter
            ),
            authorityResolver: { command in
                if command.op == SMLRuntimeCommandOperation.taskRecordStep,
                   command.arguments["outcome"] != nil {
                    throw TestFailure.denied
                }
                return Self.authority(for: command)
            }
        )

        do {
            _ = try await coordinator.executeNext(taskID: "TASK-EXACT-AUTHORITY")
            XCTFail("argument-sensitive policy must inspect the exact completion envelope")
        } catch {
            XCTAssertEqual(error as? TestFailure, .denied)
        }

        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 1)
        let snapshot = try await fixture.store.load()
        XCTAssertEqual(snapshot.tasks["TASK-EXACT-AUTHORITY"]?.revision, 2)
        XCTAssertNotNil(snapshot.tasks["TASK-EXACT-AUTHORITY"]?.capabilityClaim)
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .stepRecorded })
    }

    func testConcurrentCoordinatorsInvokeDriverExactlyOnce() async throws {
        let fixture = try await makeFixture("sml-capability-concurrent", workflow: toolWorkflow())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-CONCURRENT")
        let counter = InvocationCounter()
        let driver = StubDriver(
            id: "tool-driver",
            reference: "tool.v1",
            patch: ["result": .string("once")],
            delayNanoseconds: 30_000_000,
            counter: counter
        )
        let first = makeCoordinator(fixture, driver: driver)
        let second = makeCoordinator(fixture, driver: driver)

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask {
                do {
                    _ = try await first.executeNext(taskID: "TASK-CONCURRENT")
                    return true
                } catch { return false }
            }
            group.addTask {
                do {
                    _ = try await second.executeNext(taskID: "TASK-CONCURRENT")
                    return true
                } catch { return false }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 1)
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 1)
        let snapshot = try await fixture.store.load()
        XCTAssertEqual(snapshot.tasks["TASK-CONCURRENT"]?.status, .completed)
        XCTAssertEqual(snapshot.receipts.values.filter {
            $0.kind == .capabilityClaimed
        }.count, 1)
    }

    func testIndependentStoreAndRuntimeInstancesInvokeDriverExactlyOnce() async throws {
        let fixture = try await makeFixture(
            "sml-capability-cross-store", workflow: toolWorkflow()
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let secondStore = SMLRuntimeStore(
            fileURL: fixture.directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let secondRuntime = SMLRuntime(store: secondStore, clock: { 1_000 })
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(toolWorkflow()),
            catalog: SMLExecutionAdmissionCatalog(toolCapabilities: ["tool.v1"])
        )
        _ = try await secondRuntime.installWorkflow(admitted, role: "operator-role")
        let secondFixture = Fixture(
            directory: fixture.directory,
            store: secondStore,
            runtime: secondRuntime,
            gateway: SMLCommandGateway(runtime: secondRuntime, replayGuard: secondStore)
        )
        try await start(fixture, taskID: "TASK-CROSS-STORE")

        let counter = InvocationCounter()
        let driver = StubDriver(
            id: "tool-driver",
            reference: "tool.v1",
            patch: ["result": .string("once")],
            delayNanoseconds: 30_000_000,
            counter: counter
        )
        let gate = PairGate()
        let resolver: SMLCapabilityCoordinator.AuthorityResolver = { command in
            if command.op == SMLRuntimeCommandOperation.taskClaimCapability {
                await gate.waitForPair()
            }
            return Self.authority(for: command)
        }
        let first = makeCoordinator(
            fixture,
            driver: driver,
            authorityResolver: resolver,
            claimCommandID: "claim-first",
            dispatchID: "dispatch-first",
            completionCommandID: "complete-first"
        )
        let second = makeCoordinator(
            secondFixture,
            driver: driver,
            authorityResolver: resolver,
            claimCommandID: "claim-second",
            dispatchID: "dispatch-second",
            completionCommandID: "complete-second"
        )

        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask {
                do {
                    _ = try await first.executeNext(taskID: "TASK-CROSS-STORE")
                    return true
                } catch { return false }
            }
            group.addTask {
                do {
                    _ = try await second.executeNext(taskID: "TASK-CROSS-STORE")
                    return true
                } catch { return false }
            }
            var count = 0
            for await succeeded in group where succeeded { count += 1 }
            return count
        }

        XCTAssertEqual(successes, 1)
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 1)
        let snapshot = try await fixture.store.load()
        XCTAssertEqual(snapshot.tasks["TASK-CROSS-STORE"]?.status, .completed)
        XCTAssertEqual(snapshot.receipts.values.filter {
            $0.kind == .capabilityClaimed
        }.count, 1)
        XCTAssertEqual(snapshot.receipts.values.filter {
            $0.kind == .stepRecorded
        }.count, 1)
    }

    func testDriverFailureLeavesDurableClaimAndRetryDoesNotReexecute() async throws {
        let fixture = try await makeFixture("sml-capability-uncertain", workflow: toolWorkflow())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-UNCERTAIN")
        let counter = InvocationCounter()
        let coordinator = makeCoordinator(
            fixture,
            driver: ThrowingDriver(id: "tool-driver", reference: "tool.v1", counter: counter)
        )

        do {
            _ = try await coordinator.executeNext(taskID: "TASK-UNCERTAIN")
            XCTFail("driver failure should surface")
        } catch {
            XCTAssertEqual(error as? TestFailure, .driverFailed)
        }
        do {
            _ = try await coordinator.executeNext(taskID: "TASK-UNCERTAIN")
            XCTFail("an uncertain dispatch must never auto-reexecute")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .capabilityAlreadyClaimed("dispatch-fixed"))
        }
        let invocationCount = await counter.count()
        XCTAssertEqual(invocationCount, 1)
        let snapshot = try await fixture.store.load()
        XCTAssertEqual(
            snapshot.tasks["TASK-UNCERTAIN"]?.capabilityClaim?.dispatchID,
            "dispatch-fixed"
        )
        XCTAssertEqual(snapshot.tasks["TASK-UNCERTAIN"]?.status, .waitingCapability)
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .stepRecorded })
    }

    func testVerifyRejectsObservationOnlyEvidenceAndKeepsClaim() async throws {
        let fixture = try await makeFixture("sml-capability-verify", workflow: verifyWorkflow())
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-VERIFY")
        let counter = InvocationCounter()
        let coordinator = makeCoordinator(
            fixture,
            driver: StubDriver(
                id: "verify-driver",
                reference: "build.passed",
                counter: counter
            )
        )

        do {
            _ = try await coordinator.executeNext(taskID: "TASK-VERIFY")
            XCTFail("VERIFY must require a host-accepted receipt")
        } catch let error as SMLCapabilityRouterError {
            XCTAssertEqual(error, .insufficientEvidence(operation: "VERIFY"))
        }
        let snapshot = try await fixture.store.load()
        XCTAssertNotNil(snapshot.tasks["TASK-VERIFY"]?.capabilityClaim)
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .stepRecorded })
    }

    func testDriverEvidenceConstructionIsObservationOnly() {
        let evidence = SMLCapabilityEvidence(
            receiptID: "driver.receipt",
            source: "tool-driver",
            digest: String(repeating: "a", count: 64),
            observedAtEpoch: 1_000
        )

        XCTAssertEqual(evidence.authority, .observed)
    }

    private struct Fixture {
        let directory: URL
        let store: SMLRuntimeStore
        let runtime: SMLRuntime
        let gateway: SMLCommandGateway
    }

    private enum TestFailure: Error, Equatable {
        case denied
        case driverFailed
    }

    private actor InvocationCounter {
        private var value = 0

        func increment() { value += 1 }
        func count() -> Int { value }
    }

    private actor PairGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false

        func waitForPair() async {
            if released { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                guard waiters.count == 2 else { return }
                released = true
                let pending = waiters
                waiters.removeAll()
                pending.forEach { $0.resume() }
            }
        }
    }

    private struct StubDriver: SMLInstructionDriver {
        let id: String
        let reference: String
        var status: SMLCapabilityOutcomeStatus = .passed
        var patch: SMLObject = [:]
        var delayNanoseconds: UInt64 = 0
        let counter: InvocationCounter

        func supports(_ request: SMLCapabilityRequest) -> Bool {
            request.reference == reference
        }

        func execute(
            _ invocation: SMLCapabilityInvocation
        ) async throws -> SMLCapabilityOutcome {
            await counter.increment()
            if delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return SMLCapabilityOutcome(
                dispatchID: invocation.dispatchID,
                instructionID: invocation.request.instructionID,
                requestStateDigest: invocation.request.stateDigest,
                status: status,
                statePatch: patch,
                evidence: SMLCapabilityEvidence(
                    receiptID: "driver.receipt",
                    source: id,
                    digest: String(repeating: "a", count: 64),
                    observedAtEpoch: 1_000
                )
            )
        }
    }

    private struct ThrowingDriver: SMLInstructionDriver {
        let id: String
        let reference: String
        let counter: InvocationCounter

        func supports(_ request: SMLCapabilityRequest) -> Bool {
            request.reference == reference
        }

        func execute(
            _ invocation: SMLCapabilityInvocation
        ) async throws -> SMLCapabilityOutcome {
            _ = invocation
            await counter.increment()
            throw TestFailure.driverFailed
        }
    }

    private func makeFixture(_ prefix: String, workflow: SMLWorkflow) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["tool.v1"],
                verifiers: ["build.passed"]
            )
        )
        _ = try await runtime.installWorkflow(admitted, role: "operator-role")
        return Fixture(
            directory: directory,
            store: store,
            runtime: runtime,
            gateway: SMLCommandGateway(runtime: runtime, replayGuard: store)
        )
    }

    private func start(_ fixture: Fixture, taskID: String) async throws {
        let command = SMLCommandEnvelope(
            commandID: "start-\(taskID.lowercased())",
            actor: "operator.luke",
            role: "operator-role",
            task: taskID,
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("capability.workflow"),
                "workflow_version": .string("1.0.0"),
                "initial_state": .object(["input": .string("go")]),
            ],
            issuedAtEpoch: 1_000
        )
        _ = try await fixture.gateway.submit(
            command,
            authority: Self.authority(for: command),
            nowEpoch: 1_000
        )
    }

    private func makeCoordinator(
        _ fixture: Fixture,
        driver: any SMLInstructionDriver,
        authorityResolver: SMLCapabilityCoordinator.AuthorityResolver? = nil,
        claimCommandID: String = "claim-fixed",
        dispatchID: String = "dispatch-fixed",
        completionCommandID: String = "complete-fixed"
    ) -> SMLCapabilityCoordinator {
        SMLCapabilityCoordinator(
            runtime: fixture.runtime,
            router: SMLCapabilityRouter(drivers: [driver]),
            claimCompiler: SMLCapabilityClaimCompiler(
                actor: "operator.luke",
                commandID: { claimCommandID },
                dispatchID: { dispatchID }
            ),
            completionCompiler: SMLCapabilityCompletionCompiler(
                actor: "operator.luke",
                commandID: { completionCommandID }
            ),
            gateway: fixture.gateway,
            authorityResolver: authorityResolver ?? { command in
                Self.authority(for: command)
            },
            clock: { 1_000 }
        )
    }

    private static func authority(for command: SMLCommandEnvelope) -> SMLCommandAuthority {
        SMLCommandAuthority(
            authenticatedActor: "operator.luke",
            leaseID: "lease-1",
            roles: ["operator-role"],
            tasks: [command.task],
            operations: SMLRuntimeCommandOperation.all,
            scope: [:]
        )
    }

    private func toolWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "capability.workflow",
            version: "1.0.0",
            name: "Capability tool",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "input", type: .string),
                .init(name: "result", type: .string, required: false),
            ],
            interface: .init(inputFields: ["input"], outputFields: ["result"]),
            entrypoint: "tool",
            instructions: [
                .init(id: "tool", op: .callTool, capability: "tool.v1", next: "receipt"),
                .init(id: "receipt", op: .emitReceipt, receiptFields: ["result"]),
            ]
        )
    }

    private func verifyWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "capability.workflow",
            version: "1.0.0",
            name: "Capability verify",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "input", type: .string)],
            interface: .init(inputFields: ["input"]),
            entrypoint: "verify",
            instructions: [
                .init(id: "verify", op: .verify, verifier: "build.passed",
                      onPass: "receipt", onFailure: "failed"),
                .init(id: "receipt", op: .emitReceipt, receiptFields: ["task"]),
                .init(id: "failed", op: .escalate, reason: "failed", owner: "operator-role"),
            ]
        )
    }
}
