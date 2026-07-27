import XCTest
@testable import AgentCore

/// The pipeline threads the council verdict into the captain gate. A stub council makes the fusion
/// deterministic (no live model): proves the council's veto and the captain's veto BOTH block, end to end.
final class PromotionPipelineTests: XCTestCase {

    private struct StubCouncil: PromotionCouncil {
        let ship: Bool
        func judge(_ ctx: PromotionContext, threshold: Int) async -> CouncilPromotionVerdict {
            let vote = PromotionMindVote(name: "stub", shipWorthy: ship, reason: "stub")
            return CouncilPromotionVerdict.tally([vote], threshold: 1)
        }
    }

    private let ctx = PromotionContext(goal: "g", diffSummary: "d", testsPassed: true,
                                       testSummary: "100 tests, 0 failures", signoffSummary: "verified")

    func testCouncilHoldBlocksRegardlessOfCaptain() async {
        let pipeline = PromotionPipeline(council: StubCouncil(ship: false))
        // internallyReady true but council holds → NO-GO from the council.
        let d = await pipeline.evaluate(context: ctx, integrationBuildID: "b", internallyReady: true,
                                        attestation: nil, verifier: AttestationVerifier(trusted: []),
                                        consumedApprovals: [])
        XCTAssertFalse(d.isGo)
        XCTAssertTrue(d.refusalReason!.contains("council"))
    }

    func testCouncilBlessButCaptainNotReadyBlocks() async {
        let pipeline = PromotionPipeline(council: StubCouncil(ship: true))
        // Council blesses, but the captain isn't internally ready → NO-GO from the captain. (Gate A in
        // FleetPromotionGate fails before the verifier is touched, so an empty verifier is fine here.)
        let d = await pipeline.evaluate(context: ctx, integrationBuildID: "b", internallyReady: false,
                                        attestation: nil, verifier: AttestationVerifier(trusted: []),
                                        consumedApprovals: [])
        XCTAssertFalse(d.isGo)
        XCTAssertTrue(d.refusalReason!.contains("captain"))
    }

    func testCouncilBlessButNoAttestationBlocks() async {
        let pipeline = PromotionPipeline(council: StubCouncil(ship: true))
        // Internally ready + council blessed, but no external attestation → captain refuses. Proves the
        // pipeline never promotes on council + internal readiness alone.
        let d = await pipeline.evaluate(context: ctx, integrationBuildID: "b", internallyReady: true,
                                        attestation: nil, verifier: AttestationVerifier(trusted: []),
                                        consumedApprovals: [])
        XCTAssertFalse(d.isGo)
        XCTAssertTrue(d.refusalReason!.contains("captain"))
    }
}
