import XCTest
import AgentCore
@testable import Kist

final class InteractiveBuildRouteTests: XCTestCase {
    func testOrdinaryBuildKeepsTypedDirectPolicyAndExplicitPlanStaysPlanned() throws {
        let goal = "Fix add in sum_numbers.py so it returns the sum of its two inputs. Keep test_sum_numbers.py unchanged and run python3 -m unittest -v to verify the fix."
        let opts = KistOptions(project: "/tmp/fixture")
        let automatic = KistRunner.interactiveBuildOptions(opts, goal: goal, missionID: nil, forcePlanned: false)
        XCTAssertFalse(automatic.planExecute)
        XCTAssertEqual(KistRunner.builderCompatibilityLaunch(for: automatic, goal: goal).adapter, .headless)
        let explicit = KistRunner.interactiveBuildOptions(opts, goal: goal, missionID: nil, forcePlanned: true)
        XCTAssertTrue(explicit.planExecute)
        XCTAssertEqual(KistRunner.builderCompatibilityLaunch(for: explicit, goal: goal).adapter, .planExecute)
        let mission = PlanExecuteMissionID.fresh()
        let resumed = KistRunner.interactiveBuildOptions(opts, goal: goal, missionID: mission, forcePlanned: false)
        XCTAssertTrue(resumed.planExecute)
        XCTAssertEqual(resumed.planExecuteResumeID, mission)
        var pinned = opts; pinned.planExecute = true
        XCTAssertTrue(KistRunner.interactiveBuildOptions(pinned, goal: goal, missionID: nil, forcePlanned: false).planExecute)
    }
}
