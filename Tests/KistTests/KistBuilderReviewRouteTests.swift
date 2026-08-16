import XCTest
@testable import AgentCore
@testable import Kist

final class KistBuilderReviewRouteTests: XCTestCase {
    func testAuthoritativeRouteUsesActualResolvedModel() throws {
        let decision = ShipPipeline.Decision(
            verdict: CouncilPromotionVerdict(
                votes: ["Correctness", "Security", "Worth", "Completeness"].map {
                    PromotionMindVote(
                        name: $0, shipWorthy: true, reason: "reviewed",
                        providerID: "qwen", modelID: "qwen-live")
                },
                isShipWorthy: true, threshold: 3, summary: "approved"),
            canDeploy: true, reason: "approved", evidencePacketDigest: nil)

        let route = try XCTUnwrap(KistRunner.builderAuthoritativeReviewRoute(
            decision, expectedProviderID: "qwen",
            producingIdentities: ["builder:worker-model"]))
        XCTAssertEqual(route.provider, "qwen")
        XCTAssertEqual(route.model, "qwen-live")
        XCTAssertEqual(route.identity, "qwen:qwen-live")
    }

    func testAuthoritativeRouteRejectsMissingOrMixedLensRoutes() {
        func decision(_ votes: [PromotionMindVote]) -> ShipPipeline.Decision {
            ShipPipeline.Decision(
                verdict: CouncilPromotionVerdict(
                    votes: votes, isShipWorthy: true, threshold: 1, summary: "test"),
                canDeploy: true, reason: "test", evidencePacketDigest: nil)
        }
        XCTAssertNil(KistRunner.builderAuthoritativeReviewRoute(
            decision([PromotionMindVote(
                name: "missing", shipWorthy: true, reason: "no route")]),
            expectedProviderID: "qwen", producingIdentities: ["builder:model"]))
        XCTAssertNil(KistRunner.builderAuthoritativeReviewRoute(
            decision([
                PromotionMindVote(
                    name: "one", shipWorthy: true, reason: "one",
                    providerID: "qwen", modelID: "model-a"),
                PromotionMindVote(
                    name: "two", shipWorthy: true, reason: "two",
                    providerID: "qwen", modelID: "model-b"),
            ]),
            expectedProviderID: "qwen", producingIdentities: ["builder:model"]))
    }

    func testRouteFailureFindingsPreserveEveryFailedLensReason() {
        let votes = ["Correctness", "Security"].map {
            PromotionMindVote(
                name: $0, shipWorthy: false,
                reason: "FAILED: qwen unavailable for \($0)", failed: true)
        }
        let decision = ShipPipeline.Decision(
            verdict: CouncilPromotionVerdict(
                votes: votes, isShipWorthy: false, threshold: 3,
                summary: "short of quorum"),
            canDeploy: false, reason: "short of quorum", evidencePacketDigest: nil)

        let findings = KistRunner.builderReviewRouteFailureFindings(decision)
        XCTAssertEqual(findings.count, 3)
        XCTAssertTrue(findings.contains { $0.contains("Correctness") && $0.contains("qwen unavailable") })
        XCTAssertTrue(findings.contains { $0.contains("Security") && $0.contains("qwen unavailable") })
    }
}
