import XCTest
import AgentCore
@testable import Kist

final class GoalMapCommandTests: XCTestCase {
    private func workspace() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goalmap-cli-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testUnknownTaskStartAndClearArgumentsPreserveBoard() throws {
        let root = try workspace()
        _ = KistREPL.handleTasks("add important work", projectRoot: root)
        let file = URL(fileURLWithPath: root + "/.kist/plan.json")
        let before = try Data(contentsOf: file)
        for argument in ["start 999", "start banana", "start 1.5", "start 0", "clear completed", "strat 1"] {
            let result = KistREPL.handleTasks(argument, projectRoot: root)
            XCTAssertFalse(result.contains("started ["), result)
            XCTAssertEqual(try Data(contentsOf: file), before, argument)
        }
    }

    func testTaskMapAliasFocusDoesNotStartTask() throws {
        let root = try workspace()
        PlanStore(projectRoot: root).add(title: "specific work")
        let result = KistREPL.handleTasks("map\t1", projectRoot: root)
        XCTAssertTrue(result.contains("Task [1] specific work"), result)
        XCTAssertEqual(PlanStore(projectRoot: root).load().tasks[0].status, .todo)
        XCTAssertTrue(KistREPL.handleGoalMap("fix", projectRoot: root).contains("usage:"))
    }

    func testMapAndNextSelectionAgreeAcrossSessionBoundary() throws {
        let root = try workspace()
        let store = PlanStore(projectRoot: root)
        store.replace(title: "work", tasks: [
            PlanTask(id: 1, title: "stale", status: .inProgress, startedAt: 1),
            PlanTask(id: 2, title: "research", kind: .research),
            PlanTask(id: 3, title: "build"),
        ])
        let start = Date(timeIntervalSince1970: 10)
        XCTAssertEqual(KistREPL.taskSelectedByUser("next", projectRoot: root, sessionStartedAt: start)?.id, 3)
        XCTAssertTrue(KistREPL.handleGoalMap("", projectRoot: root, sessionStartedAt: start).contains("Next execution: [3] build"))
        XCTAssertTrue(store.load().render(sessionStartedAt: start).contains("next step: [3] build"))
    }

    func testCorruptMapReportsFailureWithoutOverwritingData() throws {
        let root = try workspace()
        PlanStore(projectRoot: root).add(title: "work")
        let file = URL(fileURLWithPath: root + "/.kist/plan.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: file)
        let text = KistREPL.handleGoalMap("", projectRoot: root)
        XCTAssertTrue(text.contains("Goal map unavailable"), text)
        XCTAssertFalse(text.contains("No tasks yet"))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testWhitespaceCommandsParseWithoutTurningPathsIntoCommands() {
        for input in ["/goals\tmap", "/goals\nmap", "/goals\u{a0}map"] {
            XCTAssertTrue(KistREPL.isSlashCommand(input), input)
            XCTAssertEqual(KistREPL.splitSlashCommand(input).name, "goals")
            XCTAssertEqual(KistREPL.splitSlashCommand(input).args, "map")
        }
        XCTAssertFalse(KistREPL.isSlashCommand("/Users/luke/work\tinspect this"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/goalmap"))
    }
}
