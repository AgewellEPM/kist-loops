import XCTest
import AgentCore
@testable import Kist

final class KistBuilderPipelineV2Tests: XCTestCase {
    func testBuilderResearchLineageDigestUsesSHA256OfSealedDossierBytes() {
        let dossier = KistRunner.AutonomyMissionDossier(
            text: "exact sealed research dossier",
            paths: ["evidence/report.md"],
            researchRunID: "research-1",
            reportDigest: "a1b2c3d4")

        let digest = KistRunner.builderResearchDossierDigest(dossier)

        XCTAssertEqual(
            digest,
            BuilderEvidenceDigest.sha256("exact sealed research dossier"))
        XCTAssertEqual(digest.count, 64)
        XCTAssertNotEqual(digest, dossier.reportDigest)
    }

    func testDurableStageArtifactRehydratesAcrossStoreInstancesAndRejectsGraphDrift() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-builder-artifacts-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dossier = KistRunner.AutonomyMissionDossier(
            text: "durable dossier", paths: ["evidence/report.md"],
            researchRunID: "research-1",
            reportDigest: BuilderEvidenceDigest.sha256("report"))
        let first = try KistRunner.BuilderCompositionArtifactStore(
            rootURL: root, builderContractID: "builder",
            graphFingerprint: BuilderEvidenceDigest.sha256("graph-a"))
        _ = try await first.saveStage(
            nodeID: "research", attempt: 1, dependencies: [],
            dossier: dossier, advisoryTaskBoard: nil)

        let restarted = try KistRunner.BuilderCompositionArtifactStore(
            rootURL: root, builderContractID: "builder",
            graphFingerprint: BuilderEvidenceDigest.sha256("graph-a"))
        let loaded = try await restarted.loadStage(nodeID: "research", attempt: 1)
        XCTAssertEqual(loaded.payload.dossier.value, dossier)

        let drifted = try KistRunner.BuilderCompositionArtifactStore(
            rootURL: root, builderContractID: "builder",
            graphFingerprint: BuilderEvidenceDigest.sha256("graph-b"))
        do {
            _ = try await drifted.loadStage(nodeID: "research", attempt: 1)
            XCTFail("graph drift must reject durable stage artifacts")
        } catch let error as BuilderRunError {
            guard case .persistedStateMismatch = error else {
                return XCTFail("expected persistedStateMismatch, got \(error)")
            }
        }
    }

    func testDurableStateRootIsOutsideProjectAndStableAcrossRestart() {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-\(UUID().uuidString)", isDirectory: true)
        let first = KistRunner.builderDurableStateDirectory(
            projectRoot: project.path, contractID: "builder")
        let second = KistRunner.builderDurableStateDirectory(
            projectRoot: project.path, contractID: "builder")
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.standardizedFileURL.path.hasPrefix(
            project.standardizedFileURL.path + "/"))
    }

    func testCoboloGovernanceAdmissionBindsPolicyGraphAndProvider() throws {
        let graph = try KistRunner.coboloBuilderGraph(
            root: "/tmp/project", goal: "build payroll",
            target: "src/payroll.cbl")
        let policy = KistRunner.builderCoboloGraphPolicy()
        let identity = try BuilderNodeContractProviderIdentity(
            providerID: "kist-cobolo-contract",
            implementationFingerprint: BuilderEvidenceDigest.sha256(
                "kist.cobolo.dynamic-contract.v2"))
        let admission = try BuilderGraphGovernanceAdmission.make(
            graph: graph, policy: policy, providerIdentity: identity)
        XCTAssertEqual(admission.schemaVersion,
                       BuilderGraphGovernanceAdmission.currentSchemaVersion)
        XCTAssertEqual(admission.governedNodeIDs, ["cobolo-execution"])
        XCTAssertNotNil(admission.providerFingerprint)
    }
}
