import XCTest
@testable import AgentCore

/// The recovery decision is pure: retry within budget; on a stall, RE-PLAN when there's a diagnostic to
/// decompose around, else ESCALATE. It only RECOMMENDS — never auto-acts.
final class FleetRecoveryPlannerTests: XCTestCase {

    func testWithinBudgetRetries() {
        XCTAssertEqual(FleetRecoveryPlanner.decide(rejectCount: 1, maxRejects: 3, timedOut: false, blockers: ["x"]).action,
                       .retry)
        XCTAssertEqual(FleetRecoveryPlanner.decide(rejectCount: 3, maxRejects: 3, timedOut: false, blockers: []).action,
                       .retry, "at the budget boundary is still a retry")
    }

    func testRetriesExhaustedWithBlockersReplans() {
        let d = FleetRecoveryPlanner.decide(rejectCount: 4, maxRejects: 3, timedOut: false,
                                            blockers: ["done_needs_tests", "monolith_limit"])
        guard case let .replan(reason) = d.action else { return XCTFail("expected replan") }
        XCTAssertTrue(reason.contains("done_needs_tests"), "the re-plan is guided by the recorded blockers")
        XCTAssertTrue(d.summary.hasPrefix("RE-PLAN"))
    }

    func testRetriesExhaustedWithNoBlockerEscalates() {
        let d = FleetRecoveryPlanner.decide(rejectCount: 4, maxRejects: 3, timedOut: false, blockers: ["  "])
        guard case let .escalate(reason) = d.action else { return XCTFail("expected escalate") }
        XCTAssertTrue(reason.contains("no recorded blocker"), "blind re-planning would just burn agents")
    }

    func testTimedOutWithBlockersReplansAsTooLarge() {
        let d = FleetRecoveryPlanner.decide(rejectCount: 0, maxRejects: 3, timedOut: true, blockers: ["slow_io"])
        guard case let .replan(reason) = d.action else { return XCTFail("expected replan") }
        XCTAssertTrue(reason.contains("too large"), "a timeout suggests the subtask was too big")
    }

    func testTimedOutWithNoSignalEscalates() {
        let d = FleetRecoveryPlanner.decide(rejectCount: 0, maxRejects: 3, timedOut: true, blockers: [])
        guard case let .escalate(reason) = d.action else { return XCTFail("expected escalate") }
        XCTAssertTrue(reason.contains("timed out"))
    }
}
