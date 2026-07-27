import XCTest
@testable import AgentCore

final class CouncilBoardCompilerTests: XCTestCase {

    func testCompilesCouncilKanbanIntoSharedPlanTasks() {
        let finalPlan = """
        Decision:
        - Build the task manager bridge.

        Kanban Board:
        | Status | Task | Owner | Acceptance |
        | --- | --- | --- | --- |
        | Ready | Forced synthesize after long read-only loops | builder | Budget exhaustion still returns a final answer |
        | Backlog | Semantic prompt-injection classifier | critic | Tool output attacks are classified before reuse |
        | Blocked | DNS-rebinding proxy layer | security | Needs network proxy design |

        Test plan:
        - swift test --filter CouncilBoardCompilerTests
        """

        let plan = CouncilBoardCompiler.compile(goal: "make council consensus actionable",
                                                finalPlan: finalPlan,
                                                artifactPath: "/tmp/council.md")

        XCTAssertTrue(plan.title.contains("AI Council"))
        XCTAssertEqual(plan.tasks.count, 4)
        XCTAssertEqual(plan.tasks[0].title, "ACTION: Forced synthesize after long read-only loops")
        XCTAssertEqual(plan.tasks[0].owner, "builder")
        XCTAssertEqual(plan.tasks[0].status, .todo)
        XCTAssertEqual(plan.tasks[0].kind, .action)
        XCTAssertEqual(plan.tasks[0].acceptance, "Budget exhaustion still returns a final answer")
        XCTAssertEqual(plan.tasks[0].verification, "Budget exhaustion still returns a final answer")
        XCTAssertEqual(plan.tasks[0].evidence, ["/tmp/council.md"])
        XCTAssertTrue(plan.tasks[0].detail.contains("Budget exhaustion still returns a final answer"))
        XCTAssertEqual(plan.tasks[1].title, "BACKLOG: Semantic prompt-injection classifier")
        XCTAssertEqual(plan.tasks[1].kind, .plan)
        XCTAssertEqual(plan.tasks[2].status, .blocked)
        XCTAssertEqual(plan.tasks[3].title, "TEST: swift test --filter CouncilBoardCompilerTests")
        XCTAssertEqual(plan.tasks[3].kind, .test)
        XCTAssertEqual(plan.tasks[3].verification, "swift test --filter CouncilBoardCompilerTests")
        XCTAssertEqual(plan.tasks[3].owner, "critic")
        XCTAssertEqual(plan.nextId, 5)
    }

    func testMessyCouncilOutputStillCreatesSafeProjectManagerBoard() {
        let plan = CouncilBoardCompiler.compile(goal: "audit the system",
                                                finalPlan: "The minds talked, but no table came back.",
                                                artifactPath: "/tmp/council.md")

        XCTAssertEqual(plan.tasks.count, 3)
        XCTAssertTrue(plan.tasks[0].title.hasPrefix("ACTION:"))
        XCTAssertTrue(plan.tasks[1].title.hasPrefix("ACTION:"))
        XCTAssertTrue(plan.tasks[2].title.hasPrefix("TEST:"))
        XCTAssertEqual(plan.tasks[0].kind, .review)
        XCTAssertFalse(plan.tasks[0].acceptance.isEmpty)
        XCTAssertFalse(plan.tasks[0].verification.isEmpty)
        XCTAssertTrue(plan.tasks.allSatisfy { $0.link == "/tmp/council.md" })
    }

    func testPlanStoreCanPersistCompiledCouncilBoard() {
        let path = NSTemporaryDirectory() + "council-plan-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = PlanStore(path: path)
        let plan = CouncilBoardCompiler.compile(goal: "persist board", finalPlan: """
        Kanban Board:
        | Status | Task | Owner | Acceptance |
        | --- | --- | --- | --- |
        | Ready | Ship visible council board | builder | /goals shows it |
        """)

        store.replace(title: plan.title, tasks: plan.tasks)
        let reloaded = store.load()

        XCTAssertEqual(reloaded.title, plan.title)
        XCTAssertEqual(reloaded.tasks.count, 2, "compiler adds a default test task when none was supplied")
        XCTAssertTrue(reloaded.render().contains("current goal: AI Council"))
        XCTAssertTrue(reloaded.render().contains("ACTION: Ship visible council board"))
    }
}
