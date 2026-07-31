import XCTest
@testable import AgentCore

final class PlanBoardAdvanceTests: XCTestCase {
    private func task(
        _ id: Int,
        _ title: String,
        _ status: PlanTask.Status,
        _ kind: PlanTask.Kind = .action
    ) -> PlanTask {
        PlanTask(id: id, title: title, status: status, kind: kind)
    }

    func testBuildQueueExcludesDoneAndResearch() {
        let plan = Plan(tasks: [
            task(1, "Create AGENTS/ dir", .done),
            task(2, "Implement load_agent_config", .done),
            task(3, "Add unit tests", .done),
            task(4, "Wire dashboard", .todo),
            task(5, "Ship it", .todo),
            task(6, "Study fleet scheduling", .todo, .research),
        ])
        XCTAssertEqual(
            plan.buildQueue().map(\.boardTitle),
            ["Wire dashboard", "Ship it"])
    }

    func testNextAdvancesPastResearchToBuildTask() {
        let plan = Plan(tasks: [
            task(1, "Create AGENTS/ dir", .done),
            task(2, "Study fleet scheduling", .todo, .research),
            task(3, "Wire dashboard", .todo),
        ])
        XCTAssertEqual(plan.nextActionable?.boardTitle, "Wire dashboard")
    }

    func testAllBuildTasksDoneClearsQueue() {
        let plan = Plan(tasks: [
            task(1, "a", .done),
            task(2, "b", .done),
            task(3, "Study X", .todo, .research),
        ])
        XCTAssertTrue(plan.buildQueue().isEmpty)
        XCTAssertNil(plan.nextActionable)
    }

    func testActiveIsPreferredAndInProgressStaysInQueue() {
        let plan = Plan(tasks: [
            task(1, "done thing", .done),
            task(2, "in flight", .inProgress),
            task(3, "later", .todo),
        ])
        XCTAssertEqual(plan.active?.boardTitle, "in flight")
        XCTAssertEqual(
            plan.buildQueue().map(\.boardTitle),
            ["in flight", "later"])
    }

    func testBuildQueueHonorsZeroAndPositiveLimits() {
        let plan = Plan(tasks: [
            task(1, "one", .todo),
            task(2, "two", .blocked),
        ])
        XCTAssertTrue(plan.buildQueue(limit: -1).isEmpty)
        XCTAssertEqual(plan.buildQueue(limit: 1).map(\.boardTitle), ["one"])
    }
}
