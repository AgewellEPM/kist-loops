import Foundation
import XCTest
@testable import AgentCore

final class AcceptedRunPersistenceBuilderIntegrationTests: XCTestCase {
    private enum FixtureError: Error {
        case missingCommandEvidence
        case missingFinalBinding
        case objectiveCollapsedIntoChildContract
    }

    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()
    }

    override func tearDown() {
        ForgeSeal.resetCacheForTesting()
        super.tearDown()
    }

    func testActualBuilderRunAuthorityHookPersistsRealisticDistinctChildContract()
        async throws {
        let fixture = BuilderRunTestFixtures.makeStore("accepted-builder-hook")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let mission = String(repeating: "7", count: 64)
        let contractID = "plan-execute.accepted.integration"
        let goal = "verify the exact PlanExecute result"
        let producerIdentity = "producer:model"
        let reviewerIdentity = "reviewer:model"
        let childContractFingerprint = BuilderEvidenceDigest.sha256(
            "sealed-child-execution-contract")
        let objectiveFingerprint = try AcceptedRunReceipt.computeObjectiveFingerprint(
            contractID: contractID, exactGoal: goal)
        XCTAssertNotEqual(childContractFingerprint, objectiveFingerprint)

        let contract = BuilderContract(
            id: contractID, objective: goal,
            constraints: ["read-only verification"],
            capabilities: ["read"], doneWhen: ["final command passes"],
            routeHint: .init(preferred: .planned),
            checkpointIdentity: mission, completionMode: .verificationOnly,
            producerIdentities: [producerIdentity], reviewPolicy: .independent)
        let graph = try BuilderGraph(nodes: [
            BuilderNode(
                id: "verify-result", objective: "inspect exact result",
                resources: [.init(path: ".", access: .read)],
                isolation: .shared, role: .verifier, retryLimit: 0),
        ])

        let rootPath = fixture.root.path
        let acceptanceCommit: BuilderFinalAcceptanceCommit = { authority in
            guard authority.objectiveFingerprint != childContractFingerprint else {
                throw FixtureError.objectiveCollapsedIntoChildContract
            }
            let final = authority.finalReceipt
            guard let subject = final.verification.verificationSubject,
                  let digest = final.verification.subjectDigest else {
                throw FixtureError.missingFinalBinding
            }
            let run = RunRecord(
                id: mission, at: final.completedAt.timeIntervalSince1970,
                goal: goal, signature: "plan-execute.accepted.integration",
                orgVersion: "test", route: final.route.rawValue,
                complexity: 80, thinking: "deep", planning: "graph",
                team: "builder", modelTier: "frontier",
                decisionReason: "actual opaque BuilderRun final-acceptance hook",
                specialists: ["producer", "independent-reviewer"],
                provider: "producer", model: "model",
                success: final.accepted, verified: true, failureRate: 0,
                iterationsUsed: 1, iterationBudget: 3, replansUsed: 0,
                wasStuck: false, toolCalls: 1, durationMs: 1, totalTokens: 2,
                projectIdentity: try AcceptedRunReceipt.computeProjectIdentity(
                    projectRoot: rootPath),
                contractID: final.contractID,
                objectiveFingerprint: authority.objectiveFingerprint,
                verificationSubject: subject, verificationDigest: digest)
            _ = try AcceptedRunPersistence(projectRoot: rootPath)
                .persistPlanExecuteAccepted(run, authorizing: authority)
        }

        let runner = try BuilderRun(
            contract: contract, graph: graph, store: fixture.store,
            finalAcceptanceCommit: acceptanceCommit,
            execute: { request in
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "producer", modelID: "model",
                    inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                    outputDigest: BuilderEvidenceDigest.sha256("worker-output"))
                return BuilderWorkerReceipt(
                    nodeID: request.node.id, provider: "producer", model: "model",
                    checks: [.init(name: "worker inspected result", passed: true)],
                    missionInstanceID: mission)
            },
            verify: { request in
                switch request {
                case .node(_, let node, _, _):
                    return BuilderVerifierReceipt(
                        scope: .node(node.id), provider: "kist", model: "deterministic",
                        deterministic: true, passed: true,
                        checks: [.init(name: "node verified", passed: true)])
                case .final(let finalContract, _, _):
                    return try await Self.finalProof(
                        contract: finalContract, mission: mission,
                        projectRoot: rootPath,
                        childContractFingerprint: childContractFingerprint)
                }
            },
            review: { _ in
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "reviewer", modelID: "model",
                    inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                    outputDigest: BuilderEvidenceDigest.sha256("review-output"))
                let lenses = ["Correctness", "Security", "Worth", "Completeness"]
                let votes = lenses.enumerated().map { index, lens in
                    BuilderReviewVoteReceipt(
                        lens: lens, accepted: index < 3,
                        reason: index < 3 ? "SHIP" : "review invocation failed",
                        failed: index == 3,
                        provider: "reviewer", model: "model",
                        invocationID: index < 3 ? "actual-review-\(index)" : nil,
                        freshConversation: index < 3 ? true : nil)
                }
                return BuilderReviewReceipt(
                    provider: "reviewer", model: "model", accepted: true,
                    checks: [.init(name: "3-of-4 zero-veto council", passed: true)],
                    evidencePacketDigest: BuilderEvidenceDigest.sha256(
                        "actual-review-packet"),
                    votes: votes, reviewThreshold: 3)
            })

        let final = try await runner.run()
        XCTAssertTrue(final.accepted)
        XCTAssertTrue(final.hasValidBuilderFinalAuthority)
        XCTAssertEqual(final.route, .planned)
        XCTAssertEqual(final.verification.contractFingerprint, childContractFingerprint)
        XCTAssertEqual(final.review.reviewGrade, .independent)
        XCTAssertEqual(final.review.independent, true)
        XCTAssertEqual(final.review.reviewThreshold, 3)
        XCTAssertEqual(final.review.workerIdentities, [producerIdentity])
        XCTAssertEqual(final.review.reviewerIdentity, reviewerIdentity)

        let records = RunLedger(projectRoot: rootPath).load()
        let record = try XCTUnwrap(records.only)
        XCTAssertEqual(record.id, mission)
        XCTAssertEqual(record.objectiveFingerprint, objectiveFingerprint)
        XCTAssertEqual(record.route, BuilderRoute.planned.rawValue)
        XCTAssertEqual(record.at, final.completedAt.timeIntervalSince1970)
        let receipts = try AcceptedRunReceiptStore(projectRoot: rootPath).allReceipts()
        let receipt = try XCTUnwrap(receipts.only)
        XCTAssertEqual(receipt.runID, mission)
        XCTAssertEqual(receipt.objectiveFingerprint, objectiveFingerprint)
        XCTAssertEqual(receipt.ledgerRecordDigest,
                       try RunLedger.canonicalRecordDigest(record))
    }

    private static func finalProof(
        contract: BuilderContract,
        mission: String,
        projectRoot: String,
        childContractFingerprint: String
    ) async throws -> BuilderVerifierReceipt {
        let subjectDigest = BuilderEvidenceDigest.sha256("actual-governed-subject")
        let request = BuilderSandboxAttestationRequest(
            contractFingerprint: childContractFingerprint,
            builderContractID: contract.id, nodeID: "final-verification", attempt: 1,
            stagedRoot: projectRoot,
            governedRootDigest: BuilderEvidenceDigest.sha256(projectRoot),
            challenge: UUID().uuidString, stage: .verification)
        let attestation = try await BuilderOSProcessSandboxAttestor().attest(request)
        let workspace = BuilderExecutionWorkspace(
            rootPath: projectRoot,
            rootIdentity: try BuilderWorkspaceRootIdentity.capture(rootPath: projectRoot),
            attestation: attestation)
        let result = try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
            workspace: workspace, builderContractID: contract.id) {
                await ToolRegistry([RunCommandTool()]).execute(
                    name: "run_command",
                    arguments: [
                        "executable": "/usr/bin/printf",
                        "args": ["%s", "actual-plan-final-verified"],
                    ],
                    context: ToolContext(
                        projectRoot: projectRoot,
                        shell: ShellPolicy(
                            enabled: true, autoApprove: true, allow: ["printf"]),
                        sandbox: .disabled))
            }
        guard result.success, let reference = result.trustedCommandReference else {
            throw FixtureError.missingCommandEvidence
        }
        let command = BuilderCommandEvidenceReceipt.boundPrehashed(
            tool: "run_command", verifierStatus: .passed,
            exitCode: reference.exitCode, allowedExitCodes: "0",
            semanticStatus: "clean_exit",
            argsFingerprint: reference.gateArgumentsDigest,
            // This intentionally differs from PlanFinal's full-stream digest.
            outputDigest: reference.stdoutDigest,
            boundedRedactedOutputExcerpt: result.output,
            subjectDigestAfter: subjectDigest,
            contractFingerprint: childContractFingerprint,
            trustedCommandReference: reference)
        let planReceipt = PlanFinalVerificationReceipt(
            missionInstanceID: mission, contractID: contract.id,
            stepID: "actual-final", tool: "run_command",
            invocation: PlanFinalVerificationInvocation(
                executable: "/usr/bin/printf",
                argv: ["%s", "actual-plan-final-verified"],
                hasStandardInput: false),
            commandFingerprint: BuilderEvidenceDigest.sha256("actual-command"),
            expectedExitCode: 0, actualExitCode: reference.exitCode,
            outputDigest: reference.fullStreamDigest,
            boundedRedactedOutputExcerpt: result.output,
            governedWorkspaceDigest: subjectDigest,
            completionContractFingerprint: BuilderEvidenceDigest.sha256("actual-completion"),
            executionPolicyFingerprint: BuilderEvidenceDigest.sha256("actual-policy"),
            verifiedAt: Date(), freshAfterMutationFrontier: true,
            captureOrdinal: 2, mutationFrontierOrdinal: 1,
            obligationsFingerprint: BuilderEvidenceDigest.sha256("actual-obligations"),
            workspaceManifestDigest: BuilderEvidenceDigest.sha256("actual-manifest"),
            trustedCommandReference: reference)
        return BuilderVerifierReceipt(
            scope: .final, provider: "kist", model: "deterministic",
            deterministic: true, passed: true,
            checks: [.init(name: "actual host final command", passed: true)],
            verificationSubject: projectRoot, baselineDigest: subjectDigest,
            subjectDigest: subjectDigest,
            contractFingerprint: childContractFingerprint,
            completionMode: .verificationOnly, commandEvidence: [command],
            verifiedAt: Date(), planFinalVerificationReceipt: planReceipt,
            missionInstanceID: mission)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
