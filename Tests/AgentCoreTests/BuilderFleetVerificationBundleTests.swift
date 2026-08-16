import Foundation
import XCTest
@testable import AgentCore

final class BuilderFleetVerificationBundleTests: XCTestCase {
    private struct Fixture {
        let observations: [BuilderTrustedTelemetryObservation]
        let identity: BuilderModelIdentity
        let first: BuilderFleetChildVerificationBundle
        let second: BuilderFleetChildVerificationBundle
        let parentFingerprint: String
        let graphFingerprint: String
    }

    private var root = ""

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-fleet-proof-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private static func runSandboxedCommand(
        label: String, baseRoot: String, parentFingerprint: String
    ) async throws -> ToolResult {
        let stagedRoot = URL(fileURLWithPath: baseRoot, isDirectory: true)
            .appendingPathComponent("scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagedRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagedRoot) }
        let contractID = "fleet-contract"
        let request = BuilderSandboxAttestationRequest(
            contractFingerprint: parentFingerprint,
            builderContractID: contractID,
            nodeID: "final-verification", attempt: 1,
            stagedRoot: stagedRoot.path,
            governedRootDigest: BuilderEvidenceDigest.sha256(stagedRoot.path),
            challenge: UUID().uuidString, stage: .verification)
        let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
        return try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
            workspace: BuilderExecutionWorkspace(
                rootPath: stagedRoot.path,
                rootIdentity: try BuilderWorkspaceRootIdentity.capture(
                    rootPath: stagedRoot.path),
                attestation: attestation),
            builderContractID: contractID
        ) {
            await ToolRegistry([RunCommandTool()]).execute(
                name: "run_command",
                arguments: [
                    "executable": "/usr/bin/printf", "args": ["%s", label],
                ],
                context: ToolContext(
                    projectRoot: stagedRoot.path,
                    shell: ShellPolicy(
                        enabled: true, autoApprove: true, allow: ["printf"]),
                    sandbox: .disabled))
        }
    }

    private func makeFixture() async throws -> Fixture {
        let parent = BuilderEvidenceDigest.sha256("fleet-parent")
        let graph = BuilderEvidenceDigest.sha256("fleet-graph")
        let firstFingerprint = BuilderEvidenceDigest.sha256("fleet-child-a")
        let secondFingerprint = BuilderEvidenceDigest.sha256("fleet-child-b")
        let aggregateSubject = "builder-aggregate://fleet-test"
        let aggregateSubjectDigest = BuilderEvidenceDigest.sha256("aggregate-staged-bytes")
        let baseRoot = root
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: try BuilderTrustedTelemetryBinding(
                contractFingerprint: parent, nodeID: "final-verification",
                attempt: 1, stage: .verification),
            registerBudgetAuthority: false) {
                let first = try await Self.runSandboxedCommand(
                    label: "first", baseRoot: baseRoot, parentFingerprint: parent)
                let second = try await Self.runSandboxedCommand(
                    label: "second", baseRoot: baseRoot, parentFingerprint: parent)
                return [first, second]
            }
        let results = try captured.0.get()
        let firstReference = try XCTUnwrap(results[0].trustedCommandReference)
        let secondReference = try XCTUnwrap(results[1].trustedCommandReference)
        let identity = try BuilderModelIdentity(providerID: "host", modelID: "deterministic")
        func evidence(_ reference: BuilderTrustedCommandReference,
                      fingerprint: String, subject: String) -> BuilderCommandEvidenceReceipt {
            BuilderCommandEvidenceReceipt.boundPrehashed(
                tool: "run_command", verifierStatus: .passed,
                exitCode: 0, allowedExitCodes: "0", semanticStatus: "clean_exit",
                argsFingerprint: reference.gateArgumentsDigest,
                outputDigest: reference.fullStreamDigest,
                boundedRedactedOutputExcerpt: "verified",
                subjectDigestAfter: subject, contractFingerprint: fingerprint,
                trustedCommandReference: reference,
                completedAt: Date(timeIntervalSince1970: 10))
        }
        return try Fixture(
            observations: captured.1, identity: identity,
            first: BuilderFleetChildVerificationBundle(
                nodeID: "fleet-a", attempt: 1,
                partitionPaths: ["Sources/A.swift"],
                contractFingerprint: firstFingerprint, verifierIdentity: identity,
                verificationSubject: aggregateSubject,
                baselineDigest: BuilderEvidenceDigest.sha256("baseline-a"),
                subjectDigest: aggregateSubjectDigest,
                commandEvidence: [evidence(
                    firstReference, fingerprint: firstFingerprint,
                    subject: aggregateSubjectDigest)],
                verifiedAt: Date(timeIntervalSince1970: 10)),
            second: BuilderFleetChildVerificationBundle(
                nodeID: "fleet-b", attempt: 1,
                partitionPaths: ["Sources/B.swift"],
                contractFingerprint: secondFingerprint, verifierIdentity: identity,
                verificationSubject: aggregateSubject,
                baselineDigest: BuilderEvidenceDigest.sha256("baseline-b"),
                subjectDigest: aggregateSubjectDigest,
                commandEvidence: [evidence(
                    secondReference, fingerprint: secondFingerprint,
                    subject: aggregateSubjectDigest)],
                verifiedAt: Date(timeIntervalSince1970: 10)),
            parentFingerprint: parent, graphFingerprint: graph)
    }

    private func expectations(_ fixture: Fixture) throws
        -> [BuilderFleetChildVerificationExpectation] {
        try [fixture.first, fixture.second].map {
            try BuilderFleetChildVerificationExpectation(
                nodeID: $0.nodeID, attempt: $0.attempt,
                partitionPaths: $0.partitionPaths,
                contractFingerprint: $0.contractFingerprint)
        }
    }

    func testCompleteOrderedChildrenValidateAgainstExactTelemetry() async throws {
        let fixture = try await makeFixture()
        let bundle = try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.second, fixture.first])

        try bundle.validate(
            expectedChildren: expectations(fixture), verifierIdentity: fixture.identity,
            observations: fixture.observations)
        XCTAssertEqual(bundle.children.map(\.nodeID), ["fleet-a", "fleet-b"])
    }

    func testMissingChildIsRejectedAgainstParentGraphExpectation() async throws {
        let fixture = try await makeFixture()
        let bundle = try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.first])

        XCTAssertThrowsError(try bundle.validate(
            expectedChildren: expectations(fixture), verifierIdentity: fixture.identity,
            observations: fixture.observations))
    }

    func testDuplicateChildIsRejectedAtConstruction() async throws {
        let fixture = try await makeFixture()
        XCTAssertThrowsError(try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.first, fixture.first]))
    }

    func testCollidingPartitionPathsAreRejected() async throws {
        let fixture = try await makeFixture()
        let colliding = try BuilderFleetChildVerificationBundle(
            nodeID: fixture.second.nodeID, attempt: fixture.second.attempt,
            partitionPaths: fixture.first.partitionPaths,
            contractFingerprint: fixture.second.contractFingerprint,
            verifierIdentity: fixture.second.verifierIdentity,
            verificationSubject: fixture.second.verificationSubject,
            baselineDigest: fixture.second.baselineDigest,
            subjectDigest: fixture.second.subjectDigest,
            commandEvidence: fixture.second.commandEvidence,
            verifiedAt: fixture.second.verifiedAt)
        XCTAssertThrowsError(try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.first, colliding]))
    }

    func testStaleAttemptIsRejected() async throws {
        let fixture = try await makeFixture()
        let bundle = try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.first, fixture.second])
        var stale = try expectations(fixture)
        stale[0] = try BuilderFleetChildVerificationExpectation(
            nodeID: stale[0].nodeID, attempt: 2,
            partitionPaths: stale[0].partitionPaths,
            contractFingerprint: stale[0].contractFingerprint)

        XCTAssertThrowsError(try bundle.validate(
            expectedChildren: stale, verifierIdentity: fixture.identity,
            observations: fixture.observations))
    }

    func testChildrenMustShareExactAggregateSubject() async throws {
        let fixture = try await makeFixture()
        let mismatched = try BuilderFleetChildVerificationBundle(
            nodeID: fixture.second.nodeID, attempt: fixture.second.attempt,
            partitionPaths: fixture.second.partitionPaths,
            contractFingerprint: fixture.second.contractFingerprint,
            verifierIdentity: fixture.second.verifierIdentity,
            verificationSubject: "builder-aggregate://other",
            baselineDigest: fixture.second.baselineDigest,
            subjectDigest: fixture.second.subjectDigest,
            commandEvidence: fixture.second.commandEvidence,
            verifiedAt: fixture.second.verifiedAt)

        XCTAssertThrowsError(try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.first, mismatched]))
    }

    func testFreshEvidenceChangesAggregateDigestButPreservesWorkspaceIdentity() async throws {
        let fixture = try await makeFixture()
        let initial = try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.first, fixture.second])
        func refreshed(_ child: BuilderFleetChildVerificationBundle)
            throws -> BuilderFleetChildVerificationBundle {
            try BuilderFleetChildVerificationBundle(
                nodeID: child.nodeID, attempt: child.attempt,
                partitionPaths: child.partitionPaths,
                contractFingerprint: child.contractFingerprint,
                verifierIdentity: child.verifierIdentity,
                verificationSubject: child.verificationSubject,
                baselineDigest: child.baselineDigest,
                subjectDigest: child.subjectDigest,
                commandEvidence: child.commandEvidence,
                verifiedAt: Date(timeIntervalSince1970: 11))
        }
        let fresh = try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [try refreshed(fixture.first), try refreshed(fixture.second)])

        XCTAssertNotEqual(initial.aggregateDigest, fresh.aggregateDigest)
        XCTAssertEqual(initial.verificationSubject, fresh.verificationSubject)
        XCTAssertEqual(initial.subjectDigest, fresh.subjectDigest)
    }

    func testFleetPromotionEvidenceRequiresDistinctAggregateCommandReceipt() async throws {
        let fixture = try await makeFixture()
        let initial = try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [fixture.first, fixture.second])
        func refreshed(_ child: BuilderFleetChildVerificationBundle)
            throws -> BuilderFleetChildVerificationBundle {
            try BuilderFleetChildVerificationBundle(
                nodeID: child.nodeID, attempt: child.attempt,
                partitionPaths: child.partitionPaths,
                contractFingerprint: child.contractFingerprint,
                verifierIdentity: child.verifierIdentity,
                verificationSubject: child.verificationSubject,
                baselineDigest: child.baselineDigest,
                subjectDigest: child.subjectDigest,
                commandEvidence: child.commandEvidence,
                verifiedAt: Date(timeIntervalSince1970: 11))
        }
        let fresh = try BuilderFleetVerificationBundle(
            parentContractFingerprint: fixture.parentFingerprint,
            graphFingerprint: fixture.graphFingerprint,
            children: [try refreshed(fixture.first), try refreshed(fixture.second)])
        func aggregateCommand(
            _ bundle: BuilderFleetVerificationBundle
        ) throws -> BuilderCommandEvidenceReceipt {
            let reference = try BuilderTrustedCommandReference(
                observationID: "aggregate-observation",
                invocationID: "aggregate-invocation",
                gateArgumentsDigest: BuilderEvidenceDigest.sha256("aggregate-gate"),
                requestedArgumentsDigest: BuilderEvidenceDigest.sha256("aggregate-request"),
                effectiveLauncherDigest: BuilderEvidenceDigest.sha256("aggregate-launcher"),
                stdoutDigest: BuilderEvidenceDigest.sha256("aggregate-stdout"),
                stderrDigest: BuilderEvidenceDigest.sha256("aggregate-stderr"),
                stdoutByteCount: 16, stderrByteCount: 0, exitCode: 0,
                timedOut: false, wasSignalled: false, wallTimeMilliseconds: 5)
            return BuilderCommandEvidenceReceipt.boundPrehashed(
                tool: "run_command", verifierStatus: .passed,
                exitCode: 0, allowedExitCodes: "0", semanticStatus: "clean_exit",
                argsFingerprint: reference.gateArgumentsDigest,
                outputDigest: reference.fullStreamDigest,
                boundedRedactedOutputExcerpt: "aggregate oracle passed",
                subjectDigestAfter: bundle.subjectDigest,
                contractFingerprint: fixture.parentFingerprint,
                trustedCommandReference: reference,
                completedAt: Date(timeIntervalSince1970: 20))
        }
        func evidence(_ bundle: BuilderFleetVerificationBundle,
                      objective: String? = nil,
                      outerCommands: [BuilderCommandEvidenceReceipt]? = nil)
            throws -> PromotionCompletionEvidence {
            let acceptedSubjects = Dictionary(uniqueKeysWithValues:
                bundle.children.map { child in
                    (child.nodeID, BuilderEvidenceDigest.sha256(
                        "accepted-child-subject:\(child.nodeID)"))
                })
            let mutationReceipts = try bundle.children.map { child in
                try BuilderTransactionPromotionReceipt(
                    contractFingerprint: child.contractFingerprint,
                    builderContractID: "fleet-contract", nodeID: child.nodeID,
                    attempt: child.attempt, workspaceDigest: child.subjectDigest,
                    verifierSubjectDigest: acceptedSubjects[child.nodeID],
                    operations: try child.partitionPaths.map {
                        try BuilderObservedMutation(
                            kind: .create, path: $0, preimageSHA256: nil,
                            postimageSHA256: child.subjectDigest)
                    })
            }
            return PromotionCompletionEvidence(
                schemaVersion: 4, contractID: "fleet-contract",
                objectiveFingerprint: objective ?? fixture.parentFingerprint,
                completionMode: .build,
                verificationSubject: bundle.verificationSubject,
                baselineDigest: BuilderEvidenceDigest.sha256("aggregate-baseline"),
                verifiedDigest: bundle.subjectDigest,
                reviewEntryDigest: bundle.subjectDigest,
                verifiedAt: Date(timeIntervalSince1970: 20),
                commandReceipts: try outerCommands ?? [aggregateCommand(bundle)],
                hostChecks: [BuilderCheckReceipt(
                    name: "fleet", passed: true, details: "aggregate verified")],
                producerIdentities: ["host:builder"],
                reviewerIdentity: "independent:reviewer",
                hadChanges: true,
                changedPaths: bundle.children.flatMap(\.partitionPaths),
                mutationReceipts: mutationReceipts,
                fleetVerification: bundle,
                acceptedVerificationSubjectDigests: acceptedSubjects)
        }

        let initialEvidence = try evidence(initial)
        let freshEvidence = try evidence(fresh)
        XCTAssertNil(initialEvidence.validationFailure)
        XCTAssertNil(freshEvidence.validationFailure)
        XCTAssertNotEqual(initialEvidence.packetDigest, freshEvidence.packetDigest)
        let reviewPrompt = CouncilPromotionJudge.completionEvidencePrompt(initialEvidence)
        for (nodeID, digest) in initialEvidence.acceptedVerificationSubjectDigests {
            XCTAssertTrue(reviewPrompt.contains("node=\(nodeID); verifierSubjectSHA256=\(digest)"))
        }
        XCTAssertNotNil(try evidence(
            initial, objective: BuilderEvidenceDigest.sha256("other-parent")).validationFailure)
        XCTAssertNotNil(try evidence(initial, outerCommands: []).validationFailure)
        XCTAssertNotNil(try evidence(
            initial, outerCommands: fixture.first.commandEvidence).validationFailure)
    }
}
