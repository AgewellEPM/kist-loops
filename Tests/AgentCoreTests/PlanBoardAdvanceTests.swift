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

    // MARK: - LOOP FIX (2026-08-01): "research loops on the same topic forever"

    /// The REPL 'next'/'continue' selector is `plan.active ?? plan.nextActionable ?? plan.next`. With no
    /// active task, a research todo at the head must NOT be selected while build work remains — else it is
    /// promoted to .inProgress and (never being auto-closed elsewhere) re-served on every turn.
    func testSelectorChainSkipsResearchTodoWhenActionableRemains() {
        let plan = Plan(tasks: [
            task(1, "Research: verify orchestration", .todo, .research),
            task(2, "Implement kist do", .todo, .action),
        ])
        let selected = plan.active ?? plan.nextActionable ?? plan.next
        XCTAssertEqual(selected?.id, 2, "actionable build task wins over a bare research todo")
        XCTAssertEqual(selected?.kind, .action)
    }

    /// Defense-in-depth must not STARVE research: when the only todo IS research, it stays selectable.
    func testSelectorChainStillReachesResearchWhenNothingActionableRemains() {
        let plan = Plan(tasks: [
            task(1, "prior", .done, .action),
            task(2, "Research: verify orchestration", .todo, .research),
        ])
        XCTAssertEqual((plan.active ?? plan.nextActionable ?? plan.next)?.id, 2,
                       "research is still reachable when nothing actionable remains")
    }

    /// A genuinely in-flight task (any kind) still wins — the fix only re-orders TODO resolution.
    func testSelectorChainKeepsGenuineActiveTask() {
        let plan = Plan(tasks: [
            task(1, "in flight", .inProgress, .action),
            task(2, "later", .todo, .action),
        ])
        XCTAssertEqual((plan.active ?? plan.nextActionable ?? plan.next)?.id, 1, "a real active task still wins")
    }

    /// LINCHPIN (Edit 0): a research task pinned .inProgress — the exact stuck state that re-served
    /// "Research: …" every turn — must, when the turn succeeds, close to .done AND advance to the next
    /// actionable todo. This is the behavior the REPL turn-dispatch now triggers via completeAndAdvance.
    func testClosingStuckInProgressResearchAdvancesToActionable() {
        let path = NSTemporaryDirectory() + "plan_\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PlanStore(path: path)
        store.add(title: "Research: verify orchestration", kind: .research)  // id 1
        store.add(title: "Implement kist do", kind: .action)                 // id 2
        _ = store.update(id: 1, status: .inProgress)                         // pinned/stuck research
        let r = store.completeAndAdvance(id: 1)
        XCTAssertEqual(r.completed?.status, .done, "the stuck research task is closed")
        XCTAssertEqual(r.nowActive?.id, 2, "board advances to the actionable todo, not back to research")
        XCTAssertTrue(r.didAdvance)
        XCTAssertEqual(store.load().tasks.first { $0.id == 1 }?.status, .done)
        XCTAssertNotEqual(store.load().active?.kind, .research, "no research task remains active after the fix")
    }
}
