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

    private func build(_ changes: Bool, testsPassed: Bool = true, testsRan: Bool = true) -> ShipPipeline.BuildResult {
        .init(hadChanges: changes, diffSummary: "2 files changed", testsPassed: testsPassed,
              testSummary: testsPassed ? "10 tests, 0 failures" : "3 failing", signoffSummary: "built in sandbox",
              testsRan: testsRan)
    }

    // R7 SYMBOLIC-FIRST: a suite that RAN and FAILED vetoes deploy even when every mind blesses it —
    // the council's vote can only make the decision stricter.
    func testFailingTestsVetoDeployEvenIfCouncilBlesses() async {
        let d = await ShipPipeline(council: StubCouncil(ship: true)).review(goal: "x",
                                                                            build: build(true, testsPassed: false, testsRan: true))
        XCTAssertFalse(d.canDeploy, "failing tests must block deploy regardless of the council vote")
        XCTAssertEqual(d.verdict?.isShipWorthy, true, "the council still voted — its blessing is necessary, not sufficient")
        XCTAssertTrue(d.reason.contains("tests ran and FAILED"), d.reason)
    }

    // The FRESH-BUILD case (the real --ship path): no suite ran ⇒ NOT a failure ⇒ the council decides.
    // Regression pin — conflating "no suite" with "tests failed" bricked --ship (every run went NO-GO).
    func testNoSuiteRanLeavesTheDecisionToTheCouncil() async {
        let blessed = await ShipPipeline(council: StubCouncil(ship: true)).review(goal: "x",
                                                                                  build: build(true, testsPassed: false, testsRan: false))
        XCTAssertTrue(blessed.canDeploy, "a fresh build with no suite must be deploy-eligible on a council blessing")
        let held = await ShipPipeline(council: StubCouncil(ship: false)).review(goal: "x",
                                                                                build: build(true, testsPassed: false, testsRan: false))
        XCTAssertFalse(held.canDeploy, "…and a council HOLD still vetoes it")
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
