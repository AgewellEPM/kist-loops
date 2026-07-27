import XCTest
@testable import AgentCore

/// The GO/NO-GO fusion: FAIL-CLOSED, both gates required, neither authorizes alone. These pin the core
/// trust invariant — a blessed council with no captain sign-off is NO-GO, and a captain sign-off the
/// council vetoed is NO-GO.
final class CaptainGateTests: XCTestCase {

    private func shipWorthy() -> CouncilPromotionVerdict {
        CouncilPromotionVerdict.tally([
            PromotionMindVote(name: "a", shipWorthy: true, reason: "r"),
            PromotionMindVote(name: "b", shipWorthy: true, reason: "r"),
            PromotionMindVote(name: "c", shipWorthy: true, reason: "r"),
        ], threshold: 3)
    }
    private func held() -> CouncilPromotionVerdict {
        CouncilPromotionVerdict.tally([PromotionMindVote(name: "a", shipWorthy: false, reason: "no")], threshold: 1)
    }

    func testBothPassPromotesAndCarriesBuildID() {
        let d = CaptainGate.decide(council: shipWorthy(),
                                   promotion: .init(verdict: .promote(buildID: "deadbeef")))
        XCTAssertTrue(d.isGo)
        XCTAssertEqual(d.buildID, "deadbeef")        // build id threads through from the captain decision
    }

    func testCouncilVetoBlocksEvenWithCaptainPromote() {
        let d = CaptainGate.decide(council: held(),
                                   promotion: .init(verdict: .promote(buildID: "deadbeef")))
        XCTAssertFalse(d.isGo)
        XCTAssertEqual(d.buildID, nil)
        XCTAssertTrue(d.refusalReason!.contains("council"))
    }

    func testCaptainRefuseBlocksEvenWithCouncilBless() {
        let d = CaptainGate.decide(council: shipWorthy(),
                                   promotion: .init(verdict: .refuse(reason: "no attestation")))
        XCTAssertFalse(d.isGo)
        XCTAssertTrue(d.refusalReason!.contains("captain"))
        XCTAssertTrue(d.refusalReason!.contains("no attestation"))
    }

    func testBothFailIsNoGo() {
        let d = CaptainGate.decide(council: held(),
                                   promotion: .init(verdict: .refuse(reason: "x")))
        XCTAssertFalse(d.isGo)                        // council checked first → council reason surfaces
        XCTAssertTrue(d.refusalReason!.contains("council"))
    }
}
