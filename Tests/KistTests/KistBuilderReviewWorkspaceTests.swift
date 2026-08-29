import Foundation
import XCTest
@testable import AgentCore
@testable import Kist

final class KistBuilderReviewWorkspaceTests: XCTestCase {
    func testDisposableSameModelTargetRejectsNestedGitAncestor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kist-builder-same-model-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Nested/Sources/.git", isDirectory: true),
            withIntermediateDirectories: true)

        XCTAssertTrue(KistRunner.builderDisposableReviewRootEligible(root.path))
        XCTAssertFalse(KistRunner.builderDisposableReviewTargetsEligible(
            root: root.path, paths: ["Nested/Sources/New.swift"]))
        XCTAssertTrue(KistRunner.builderDisposableReviewTargetsEligible(
            root: root.path, paths: ["Isolated/New.swift"]))
    }

    func testNonFleetReviewUsesOnlyVerifiedStagedSubject() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "kist-builder-review-workspace-\(UUID().uuidString)", isDirectory: true)
        let source = base.appendingPathComponent("source", isDirectory: true)
        let staged = base.appendingPathComponent("staged", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let outputText = "HEADLESS_OK\n"
        let output = Data(outputText.utf8)
        try output.write(to: staged.appendingPathComponent("headless.ok"), options: .atomic)
        let sourceDigest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: source.path)
        let stagedDigest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: staged.path)
        XCTAssertNotEqual(sourceDigest, stagedDigest)

        let probe = StagedReviewProviderProbe()
        let provider = StagedReviewProvider(probe: probe)
        let registry = ProviderRegistry(providers: [provider])
        let goal = "build the staged artifact"
        let contract = BuilderContract(
            id: "staged-review-contract", objective: goal,
            allowedPaths: ["headless.ok"], doneWhen: ["artifact exists"],
            completionMode: .build,
            producerIdentities: ["builder-provider:builder-model"])
        let fingerprint = KistRunner.builderObjectiveFingerprint(
            contractID: contract.id, goal: goal)
        let command = BuilderCommandEvidenceReceipt.bound(
            tool: "run_command", verifierStatus: .passed,
            exitCode: 0, allowedExitCodes: "0", semanticStatus: "clean_exit",
            argsFingerprint: "python3 verify.py", output: "passed",
            subjectDigestAfter: stagedDigest, contractFingerprint: fingerprint)
        let failedActualCommand = BuilderCommandEvidenceReceipt.bound(
            tool: "run_command", verifierStatus: .executed,
            exitCode: 17, allowedExitCodes: "0", semanticStatus: "command_failed",
            argsFingerprint: "actual failing probe", output: "ACTUAL_COMMAND_FAILURE_EXIT_17",
            subjectDigestAfter: stagedDigest, contractFingerprint: fingerprint)
        let launch = KistRunner.builderCompatibilityLaunch(
            for: KistOptions.parse(["--headless", goal]), goal: goal)
        let context = KistRunner.BuilderReviewContext(
            criticBinding: ProviderBinding(
                providerId: provider.id, model: provider.defaultModel),
            registry: registry, launch: launch, projectRoot: source.path,
            finalizedContract: contract, goal: goal,
            sharedBudget: BudgetLedger())
        let mutation = try BuilderObservedMutation(
            kind: .create, path: "headless.ok", preimageSHA256: nil,
            postimageSHA256: BuilderEvidenceDigest.sha256(outputText))
        let promotion = try BuilderTransactionPromotionReceipt(
            contractFingerprint: fingerprint, builderContractID: contract.id,
            nodeID: "build", attempt: 2, workspaceDigest: stagedDigest,
            verifierSubjectDigest: stagedDigest,
            operations: [mutation])

        func request(subject: String,
                     promotionReceipts: [BuilderTransactionPromotionReceipt]) -> BuilderReviewRequest {
            BuilderReviewRequest(
                contract: contract, route: .direct,
                workers: [BuilderWorkerReceipt(
                    nodeID: "build", provider: "builder-provider",
                    model: "builder-model", changedPaths: [],
                    checks: [.init(name: "build", passed: true)])],
                verification: BuilderVerifierReceipt(
                    scope: .final, provider: "kist", model: "deterministic",
                    deterministic: true, passed: true,
                    checks: [.init(name: "python", passed: true)],
                    verificationSubject: subject,
                    baselineDigest: sourceDigest, subjectDigest: stagedDigest,
                    contractFingerprint: fingerprint, completionMode: .build,
                    commandEvidence: [command, failedActualCommand], verifiedAt: Date()),
                promotionReceipts: promotionReceipts,
                acceptedAttempts: ["build": 2],
                selectedContractFingerprints: ["build": fingerprint])
        }

        let accepted = await KistRunner.builderReview(
            request(subject: staged.path, promotionReceipts: [promotion]), context: context)
        XCTAssertTrue(accepted.accepted, accepted.findings.joined(separator: "; "))
        let acceptedCallCount = await probe.callCount()
        XCTAssertEqual(acceptedCallCount, 4)
        let prompts = await probe.recordedPrompts()
        XCTAssertTrue(prompts.allSatisfy { $0.contains(staged.path) })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains(source.path) })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("hadChanges: true") })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("changedPaths: headless.ok") })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("kind=create; path=headless.ok") })
        XCTAssertTrue(prompts.allSatisfy { $0.contains("git advisory unavailable") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("fatal: not a git repository") })
        XCTAssertTrue(prompts.allSatisfy { !$0.contains("Permission denied") })
        XCTAssertTrue(prompts.allSatisfy {
            $0.contains("verifier=executed; exit=17; allowed=0; semantic=command_failed")
                && $0.contains("ACTUAL_COMMAND_FAILURE_EXIT_17")
        })
        XCTAssertTrue(prompts.allSatisfy {
            $0.contains("postimageSHA256=\(BuilderEvidenceDigest.sha256(outputText))")
                && $0.contains("verifierSubjectSHA256=\(stagedDigest)")
                && $0.contains("receiptSHA256=\(promotion.receiptDigest)")
        })

        let stalePromotion = try BuilderTransactionPromotionReceipt(
            contractFingerprint: fingerprint, builderContractID: contract.id,
            nodeID: "build", attempt: 1, workspaceDigest: stagedDigest,
            verifierSubjectDigest: stagedDigest, operations: [mutation])
        let staleAttemptProbe = StagedReviewProviderProbe()
        let staleAttemptReview = await KistRunner.builderReview(
            request(subject: staged.path, promotionReceipts: [stalePromotion]),
            context: KistRunner.BuilderReviewContext(
                criticBinding: ProviderBinding(
                    providerId: provider.id, model: provider.defaultModel),
                registry: ProviderRegistry(providers: [
                    StagedReviewProvider(probe: staleAttemptProbe)
                ]), launch: launch, projectRoot: source.path,
                finalizedContract: contract, goal: goal,
                sharedBudget: BudgetLedger()))
        XCTAssertFalse(staleAttemptReview.accepted)
        XCTAssertTrue(staleAttemptReview.findings.contains {
            $0.contains("stale") && $0.contains("accepted retry attempt")
        })
        let staleAttemptCallCount = await staleAttemptProbe.callCount()
        XCTAssertEqual(staleAttemptCallCount, 0)

        let missingProbe = StagedReviewProviderProbe()
        let missing = await KistRunner.builderReview(
            request(subject: staged.path, promotionReceipts: []),
            context: KistRunner.BuilderReviewContext(
                criticBinding: ProviderBinding(
                    providerId: provider.id, model: provider.defaultModel),
                registry: ProviderRegistry(providers: [
                    StagedReviewProvider(probe: missingProbe)
                ]), launch: launch, projectRoot: source.path,
                finalizedContract: contract, goal: goal,
                sharedBudget: BudgetLedger()))
        XCTAssertFalse(missing.accepted)
        XCTAssertTrue(missing.findings.contains {
            $0.contains("without sealed observed mutation details")
        })
        let missingCallCount = await missingProbe.callCount()
        XCTAssertEqual(missingCallCount, 0)

        let encoded = try JSONEncoder().encode(promotion)
        var forgedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        forgedObject["receiptDigest"] = String(repeating: "f", count: 64)
        let forged = try JSONDecoder().decode(
            BuilderTransactionPromotionReceipt.self,
            from: JSONSerialization.data(withJSONObject: forgedObject))
        XCTAssertFalse(forged.hasValidReceiptDigest)
        let forgedProbe = StagedReviewProviderProbe()
        let forgedReview = await KistRunner.builderReview(
            request(subject: staged.path, promotionReceipts: [forged]),
            context: KistRunner.BuilderReviewContext(
                criticBinding: ProviderBinding(
                    providerId: provider.id, model: provider.defaultModel),
                registry: ProviderRegistry(providers: [
                    StagedReviewProvider(probe: forgedProbe)
                ]), launch: launch, projectRoot: source.path,
                finalizedContract: contract, goal: goal,
                sharedBudget: BudgetLedger()))
        XCTAssertFalse(forgedReview.accepted)
        XCTAssertTrue(forgedReview.findings.contains { $0.contains("invalid") })
        let forgedCallCount = await forgedProbe.callCount()
        XCTAssertEqual(forgedCallCount, 0)

        let staleProbe = StagedReviewProviderProbe()
        let staleContext = KistRunner.BuilderReviewContext(
            criticBinding: ProviderBinding(
                providerId: provider.id, model: provider.defaultModel),
            registry: ProviderRegistry(providers: [
                StagedReviewProvider(probe: staleProbe)
            ]),
            launch: launch, projectRoot: staged.path,
            finalizedContract: contract, goal: goal,
            sharedBudget: BudgetLedger())
        let rejected = await KistRunner.builderReview(
            request(subject: source.path, promotionReceipts: [promotion]), context: staleContext)
        XCTAssertFalse(rejected.accepted)
        XCTAssertTrue(rejected.findings.contains {
            $0.contains("verification evidence is stale at review entry")
        })
        let rejectedCallCount = await staleProbe.callCount()
        XCTAssertEqual(rejectedCallCount, 0)
    }
}

private actor StagedReviewProviderProbe {
    private var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
    func callCount() -> Int { prompts.count }
    func recordedPrompts() -> [String] { prompts }
}

private struct StagedReviewProvider: ChatProvider {
    let id = "staged-reviewer"
    let name = "staged-reviewer"
    let iconName = "checkmark.seal"
    let requiresAPIKey = false
    let keyAccount = "staged-reviewer"
    let defaultModel = "review-model"
    let availableModels = [AIModel(id: "review-model")]
    let supportsNativeTools = false
    let modelsListEndpoint: String? = nil
    let probe: StagedReviewProviderProbe

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        await probe.record(messages.map(\.content).joined(separator: "\n"))
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta("VERDICT: SHIP\nREASON: staged subject verified"))
            continuation.yield(.usage(promptTokens: 10, completionTokens: 5))
            continuation.finish()
        }
    }
}
