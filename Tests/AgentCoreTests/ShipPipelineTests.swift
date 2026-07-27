import XCTest
@testable import AgentCore

final class ShipPipelineTests: XCTestCase {

    private struct StubCouncil: PromotionCouncil {
        let ship: Bool
        func judge(_ ctx: PromotionContext, threshold: Int) async -> CouncilPromotionVerdict {
            CouncilPromotionVerdict(votes: [], isShipWorthy: ship, threshold: threshold,
                                    summary: ship ? "all minds blessed" : "a mind held")
        }
    }

    private func build(_ changes: Bool) -> ShipPipeline.BuildResult {
        .init(hadChanges: changes, diffSummary: "2 files changed", testsPassed: true,
              testSummary: "10 tests, 0 failures", signoffSummary: "built in sandbox")
    }

    func testNothingBuiltIsNeverDeployEligible() async {
        let d = await ShipPipeline(council: StubCouncil(ship: true)).review(goal: "x", build: build(false))
        XCTAssertFalse(d.canDeploy)
        XCTAssertNil(d.verdict)
        XCTAssertTrue(d.reason.contains("nothing was built"))
    }

    func testCouncilBlessingMakesItDeployEligible() async {
        let d = await ShipPipeline(council: StubCouncil(ship: true)).review(goal: "x", build: build(true))
        XCTAssertTrue(d.canDeploy)
        XCTAssertEqual(d.verdict?.isShipWorthy, true)
    }

    func testCouncilHoldVetoesDeploy() async {
        let d = await ShipPipeline(council: StubCouncil(ship: false)).review(goal: "x", build: build(true))
        XCTAssertFalse(d.canDeploy, "a council HOLD must veto deploy")
        XCTAssertEqual(d.verdict?.isShipWorthy, false)
        XCTAssertTrue(d.reason.contains("held"))
    }
}
