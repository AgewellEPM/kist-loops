import XCTest
@testable import AgentCore

final class SMLPluginExecutionAttestationTests: XCTestCase {
    func testSandboxedAndTrustedProcessAttestationsRouteToDistinctDrivers() async throws {
        for scenario in [
            Scenario(
                prefix: "sml-plugin-sandboxed",
                trustLevel: .contracted,
                isolation: .sandboxed,
                expectedDriverID: "sandbox-driver",
                expectedMode: "sandboxed"
            ),
            Scenario(
                prefix: "sml-plugin-trusted",
                trustLevel: .verified,
                isolation: .trustedProcess,
                expectedDriverID: "trusted-driver",
                expectedMode: "trusted_process"
            ),
        ] {
            let fixture = try await makeFixture(
                prefix: scenario.prefix,
                workflowVersions: ["1.0.0"],
                trustLevel: scenario.trustLevel,
                isolation: scenario.isolation
            )
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let taskID = "TASK-\(scenario.expectedMode.uppercased())"
            try await start(fixture, taskID: taskID, workflowVersion: "1.0.0")

            let coordinator = coordinator(
                fixture,
                drivers: [
                    IsolationDriver(
                        id: "sandbox-driver",
                        isolation: .sandboxed,
                        mode: "sandboxed"
                    ),
                    IsolationDriver(
                        id: "trusted-driver",
                        isolation: .trustedProcess,
                        mode: "trusted_process"
                    ),
                ],
                commandSuffix: scenario.expectedMode
            )
            let result = try await coordinator.executeNext(taskID: taskID)

            XCTAssertEqual(result.task?.state["mode"], .string(scenario.expectedMode))
            let scenarioSnapshot = try await fixture.store.load()
            let claimedReceipt = try XCTUnwrap(
                scenarioSnapshot.receipts.values.first {
                    $0.kind == .capabilityClaimed
                }
            )
            XCTAssertEqual(
                claimedReceipt.payload["driver_id"],
                .string(scenario.expectedDriverID)
            )
        }
    }

    func testExactWorkflowRevisionIsBoundIntoPluginAttestationAndDurableClaim() async throws {
        let fixture = try await makeFixture(
            prefix: "sml-plugin-revision",
            workflowVersions: ["1.0.0", "1.0.1"],
            trustLevel: .contracted,
            isolation: .sandboxed
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-PLUGIN-V1", workflowVersion: "1.0.0")
        try await start(fixture, taskID: "TASK-PLUGIN-V2", workflowVersion: "1.0.1")

        let first = try await fixture.runtime.pendingCapability(taskID: "TASK-PLUGIN-V1")
        let second = try await fixture.runtime.pendingCapability(taskID: "TASK-PLUGIN-V2")
        let firstAttestation = try XCTUnwrap(first.pluginExecutionAttestation)
        let secondAttestation = try XCTUnwrap(second.pluginExecutionAttestation)

        XCTAssertEqual(firstAttestation.workflowVersion, "1.0.0")
        XCTAssertEqual(secondAttestation.workflowVersion, "1.0.1")
        XCTAssertEqual(firstAttestation.pluginID, "invoice.plugin")
        XCTAssertEqual(firstAttestation.instructionID, "plugin")
        XCTAssertEqual(firstAttestation.bindingDigest.count, 64)
        XCTAssertEqual(secondAttestation.bindingDigest.count, 64)
        XCTAssertNotEqual(firstAttestation.bindingDigest, secondAttestation.bindingDigest)
        XCTAssertNotEqual(first.stateDigest, second.stateDigest)

        let firstClaim = try await claim(
            first,
            fixture: fixture,
            commandID: "claim-plugin-v1",
            dispatchID: "dispatch-plugin-v1"
        )
        let secondClaim = try await claim(
            second,
            fixture: fixture,
            commandID: "claim-plugin-v2",
            dispatchID: "dispatch-plugin-v2"
        )
        let snapshot = try await fixture.store.load()

        XCTAssertEqual(
            snapshot.tasks["TASK-PLUGIN-V1"]?.capabilityClaim?.stateDigest,
            firstClaim.request.stateDigest
        )
        XCTAssertEqual(
            snapshot.tasks["TASK-PLUGIN-V2"]?.capabilityClaim?.stateDigest,
            secondClaim.request.stateDigest
        )
        XCTAssertEqual(
            firstClaim.request.pluginExecutionAttestation?.bindingDigest,
            firstAttestation.bindingDigest
        )
        XCTAssertEqual(
            secondClaim.request.pluginExecutionAttestation?.bindingDigest,
            secondAttestation.bindingDigest
        )
        XCTAssertNotEqual(firstClaim.request.stateDigest, secondClaim.request.stateDigest)
    }

    func testChangingHostIsolationAfterClaimCannotCompleteOldPluginDispatch() async throws {
        let fixture = try await makeFixture(
            prefix: "sml-plugin-reattest",
            workflowVersions: ["1.0.0"],
            trustLevel: .contracted,
            isolation: .sandboxed
        )
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await start(fixture, taskID: "TASK-PLUGIN-REATTEST", workflowVersion: "1.0.0")

        let request = try await fixture.runtime.pendingCapability(
            taskID: "TASK-PLUGIN-REATTEST"
        )
        let claimed = try await claim(
            request,
            fixture: fixture,
            commandID: "claim-plugin-reattest",
            dispatchID: "dispatch-plugin-reattest"
        )
        let router = SMLCapabilityRouter(drivers: [
            IsolationDriver(
                id: "sandbox-driver",
                isolation: .sandboxed,
                mode: "sandboxed"
            ),
        ])
        let routed = try await router.execute(claimed)

        let trustedAdmission = try admittedWorkflow(
            version: "1.0.0",
            trustLevel: .verified,
            isolation: .trustedProcess
        )
        _ = try await fixture.runtime.installWorkflow(trustedAdmission, role: "plugin-role")

        let completion = try SMLCapabilityCompletionCompiler(
            actor: "operator.luke",
            commandID: { "complete-plugin-reattest" }
        ).compile(claimed: claimed, routed: routed, issuedAtEpoch: 1_000)
        do {
            _ = try await fixture.gateway.completeCapability(
                completion,
                claimed: claimed,
                routed: routed,
                authority: Self.authority(for: completion),
                nowEpoch: 1_000
            )
            XCTFail("a changed host isolation attestation must invalidate the old claim")
        } catch let error as SMLRuntimeError {
            XCTAssertEqual(error, .capabilityClaimMismatch)
        }

        let snapshot = try await fixture.store.load()
        XCTAssertEqual(
            snapshot.tasks["TASK-PLUGIN-REATTEST"]?.capabilityClaim?.stateDigest,
            claimed.request.stateDigest
        )
        XCTAssertFalse(snapshot.receipts.values.contains { $0.kind == .stepRecorded })
    }

    private struct Scenario {
        let prefix: String
        let trustLevel: SMLPluginTrustLevel
        let isolation: SMLPluginIsolation
        let expectedDriverID: String
        let expectedMode: String
    }

    private struct Fixture {
        let directory: URL
        let store: SMLRuntimeStore
        let runtime: SMLRuntime
        let gateway: SMLCommandGateway
    }

    private struct IsolationDriver: SMLInstructionDriver {
        let id: String
        let isolation: SMLPluginIsolation
        let mode: String

        func supports(_ request: SMLCapabilityRequest) -> Bool {
            request.operation == .runPlugin
                && request.reference == "invoice.plugin"
                && request.pluginExecutionAttestation?.isolation == isolation
        }

        func execute(
            _ invocation: SMLCapabilityInvocation
        ) async throws -> SMLCapabilityOutcome {
            guard let attestation = invocation.request.pluginExecutionAttestation,
                  attestation.isolation == isolation,
                  attestation.pluginID == invocation.request.plugin?.id,
                  attestation.workflowID == invocation.request.workflowID,
                  attestation.workflowVersion == invocation.request.workflowVersion,
                  attestation.instructionID == invocation.request.instructionID else {
                throw SMLRuntimeError.capabilityClaimMismatch
            }
            return SMLCapabilityOutcome(
                dispatchID: invocation.dispatchID,
                instructionID: invocation.request.instructionID,
                requestStateDigest: invocation.request.stateDigest,
                status: .passed,
                statePatch: ["mode": .string(mode)],
                evidence: SMLCapabilityEvidence(
                    receiptID: "plugin.receipt",
                    source: id,
                    digest: String(repeating: "a", count: 64),
                    observedAtEpoch: 1_000
                )
            )
        }
    }

    private func makeFixture(
        prefix: String,
        workflowVersions: [String],
        trustLevel: SMLPluginTrustLevel,
        isolation: SMLPluginIsolation
    ) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 1_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 1_000 })
        for version in workflowVersions {
            _ = try await runtime.installWorkflow(
                admittedWorkflow(
                    version: version,
                    trustLevel: trustLevel,
                    isolation: isolation
                ),
                role: "plugin-role"
            )
        }
        return Fixture(
            directory: directory,
            store: store,
            runtime: runtime,
            gateway: SMLCommandGateway(runtime: runtime, replayGuard: store)
        )
    }

    private func admittedWorkflow(
        version: String,
        trustLevel: SMLPluginTrustLevel,
        isolation: SMLPluginIsolation
    ) throws -> SMLAdmittedWorkflow {
        let workflow = pluginWorkflow(version: version)
        let contract = try XCTUnwrap(workflow.instructions.first?.plugin)
        return try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: SMLExecutionAdmissionCatalog(plugins: [
                contract.id: SMLPluginAttestation(
                    contract: contract,
                    trustLevel: trustLevel,
                    isolation: isolation,
                    attestedBy: "host.registry"
                ),
            ])
        )
    }

    private func pluginWorkflow(version: String) -> SMLWorkflow {
        let contract = SMLPluginContract(
            id: "invoice.plugin",
            reads: ["invoice"],
            sideEffectLevel: .readOnly
        )
        return SMLWorkflow(
            id: "plugin.workflow",
            version: version,
            name: "Plugin workflow",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "mode", type: .string, required: false),
            ],
            interface: .init(outputFields: ["mode"]),
            entrypoint: "plugin",
            instructions: [
                .init(id: "plugin", op: .runPlugin, plugin: contract, next: "receipt"),
                .init(id: "receipt", op: .emitReceipt, receiptFields: ["mode"]),
            ]
        )
    }

    private func start(
        _ fixture: Fixture,
        taskID: String,
        workflowVersion: String
    ) async throws {
        let command = SMLCommandEnvelope(
            commandID: "start-\(taskID.lowercased())",
            actor: "operator.luke",
            role: "plugin-role",
            task: taskID,
            op: SMLRuntimeCommandOperation.workflowRun,
            arguments: [
                "workflow_id": .string("plugin.workflow"),
                "workflow_version": .string(workflowVersion),
            ],
            issuedAtEpoch: 1_000
        )
        _ = try await fixture.gateway.submit(
            command,
            authority: Self.authority(for: command),
            nowEpoch: 1_000
        )
    }

    private func claim(
        _ request: SMLCapabilityRequest,
        fixture: Fixture,
        commandID: String,
        dispatchID: String
    ) async throws -> SMLClaimedCapability {
        let command = try SMLCapabilityClaimCompiler(
            actor: "operator.luke",
            commandID: { commandID },
            dispatchID: { dispatchID }
        ).compile(request: request, driverID: "sandbox-driver", issuedAtEpoch: 1_000)
        return try await fixture.gateway.claimCapability(
            command,
            authority: Self.authority(for: command),
            nowEpoch: 1_000
        )
    }

    private func coordinator(
        _ fixture: Fixture,
        drivers: [any SMLInstructionDriver],
        commandSuffix: String
    ) -> SMLCapabilityCoordinator {
        SMLCapabilityCoordinator(
            runtime: fixture.runtime,
            router: SMLCapabilityRouter(drivers: drivers),
            claimCompiler: SMLCapabilityClaimCompiler(
                actor: "operator.luke",
                commandID: { "claim-\(commandSuffix)" },
                dispatchID: { "dispatch-\(commandSuffix)" }
            ),
            completionCompiler: SMLCapabilityCompletionCompiler(
                actor: "operator.luke",
                commandID: { "complete-\(commandSuffix)" }
            ),
            gateway: fixture.gateway,
            authorityResolver: { command in Self.authority(for: command) },
            clock: { 1_000 }
        )
    }

    private static func authority(for command: SMLCommandEnvelope) -> SMLCommandAuthority {
        SMLCommandAuthority(
            authenticatedActor: "operator.luke",
            leaseID: "lease-1",
            roles: ["plugin-role"],
            tasks: [command.task],
            operations: SMLRuntimeCommandOperation.all,
            scope: [:]
        )
    }
}
