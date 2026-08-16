import Foundation
import AgentCore
@testable import Kist

private final class CoboloExecutionContractFixtureCache: @unchecked Sendable {
    static let shared = CoboloExecutionContractFixtureCache()
    private let lock = NSLock()
    private var values: [String: SealedBuilderExecutionContract] = [:]

    func value(for key: String, issue: () -> SealedBuilderExecutionContract)
        -> SealedBuilderExecutionContract {
        lock.lock(); defer { lock.unlock() }
        if let value = values[key] { return value }
        let value = issue(); values[key] = value
        return value
    }
}

func coboloIdentityPlanFixture() -> CoboloIdentityPlan {
    CoboloIdentityPlan(
        driver: ProviderBinding(providerId: "driver", model: "driver-v1"),
        coder: ProviderBinding(providerId: "coder", model: "coder-v1"),
        cobol: ProviderBinding(providerId: "cobol", model: "cobol-v1"),
        critic: ProviderBinding(providerId: "critic", model: "critic-v1"),
        promotion: ProviderBinding(providerId: "promotion", model: "promotion-v1"))
}

func coboloLineageFixture(captainSeed: String = "captain") -> BuilderLineageEnvelope {
    try! BuilderLineageEnvelope(
        captainDecisionDigest: BuilderEvidenceDigest.sha256(captainSeed),
        research: BuilderResearchLineage(
            runID: "research-run", dossierDigest: BuilderEvidenceDigest.sha256("dossier")),
        peelReceiptDigest: BuilderEvidenceDigest.sha256("peel"),
        councilArtifactDigest: BuilderEvidenceDigest.sha256("council"),
        taskBoard: BuilderTaskBoardLineage(
            version: 1, taskIDs: ["task-1"],
            handoffDigest: BuilderEvidenceDigest.sha256("board")))
}

func coboloExecutionContractFixture(
    root: String,
    options: KistOptions,
    identityPlan: CoboloIdentityPlan,
    captainSeed: String = "captain",
    builderContractID: String = "test-builder"
) -> SealedBuilderExecutionContract {
    let key = [root, options.cobolTarget ?? "", captainSeed, builderContractID]
        .joined(separator: "\u{0}")
    return CoboloExecutionContractFixtureCache.shared.value(for: key) {
        try! KistRunner.coboloIssueExecutionContract(
            builderContractID: builderContractID,
            builderNodeID: "cobolo-execution",
            target: options.cobolTarget!,
            root: root,
            lineage: coboloLineageFixture(captainSeed: captainSeed),
            identityPlan: identityPlan,
            maxRevisions: options.cobolMaxRevisions,
            maxTokens: options.budgetTokens)
    }
}
