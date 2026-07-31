import XCTest
@testable import AgentCore

/// The dashboard "Build Queue" + "Next" must ADVANCE as work lands — not freeze on completed items or
/// park "Next" on a never-closing research task (the stuck board Luke hit 2026-07-31, where the 3 done
/// AGENTS tasks kept showing and Next stayed on "Research …" forever).
final class PlanBoardAdvanceTests: XCTestCase {
    private func task(_ id: Int, _ title: String, _ status: PlanTask.Status, _ kind: PlanTask.Kind = .action) -> PlanTask {
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
        let titles = plan.buildQueue().map { $0.boardTitle }
        XCTAssertEqual(titles, ["Wire dashboard", "Ship it"], "done + research drop off; only actionable remain")
    }

    func testNextAdvancesPastDoneToNextBuildTaskNotResearch() {
        let plan = Plan(tasks: [
            task(1, "Create AGENTS/ dir", .done),
            task(2, "Implement load_agent_config", .done),
            task(3, "Study fleet scheduling", .todo, .research),   // lower id, but research
            task(4, "Wire dashboard", .todo),                       // the real next build task
        ])
        XCTAssertEqual(plan.nextActionable?.boardTitle, "Wire dashboard",
                       "Next skips the research todo and points at the next actionable build task")
    }

    func testAllBuildTasksDoneClearsQueue() {
        let plan = Plan(tasks: [
            task(1, "a", .done), task(2, "b", .done),
            task(3, "Study X", .todo, .research),
        ])
        XCTAssertTrue(plan.buildQueue().isEmpty, "when the build work is done the queue clears (visible progress)")
        XCTAssertNil(plan.nextActionable, "no actionable build task left")
    }

    func testActiveIsPreferredAndInProgressStaysInQueue() {
        let plan = Plan(tasks: [
            task(1, "done thing", .done),
            task(2, "in flight", .inProgress),
            task(3, "later", .todo),
        ])
        XCTAssertEqual(plan.active?.boardTitle, "in flight")
        XCTAssertEqual(plan.buildQueue().map { $0.boardTitle }, ["in flight", "later"])
    }
}
