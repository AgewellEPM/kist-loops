import XCTest
import AgentCore
@testable import Kist

final class TasksCommandTests: XCTestCase {

    func testTasksCommandAddDoneAndShow() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        _ = KistREPL.handleTasks("add wire the parser", projectRoot: dir)
        _ = KistREPL.handleTasks("add ship it", projectRoot: dir)
        let started = KistREPL.handleTasks("start", projectRoot: dir)
        XCTAssertTrue(started.contains("started [1]"))
        let done = KistREPL.handleTasks("done 1", projectRoot: dir)
        XCTAssertTrue(done.contains("done [1]"))
        // Self-advance: completing task 1 auto-promotes task 2 to ACTIVE (the "go to the next request" loop),
        // so it's announced on done and shown as the active task — not merely queued as "next".
        XCTAssertTrue(done.contains("▶ advanced to [2] ship it"))
        let show = KistREPL.handleTasks("", projectRoot: dir)
        XCTAssertTrue(show.contains("1/2 done"))
        XCTAssertTrue(show.contains("active task: [2] ship it"))
    }

    func testTasksDoneDistinguishesExistingActiveAndBlockedQueue() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        _ = KistREPL.handleTasks("add first", projectRoot: dir)
        _ = KistREPL.handleTasks("add already running", projectRoot: dir)
        _ = KistREPL.handleTasks("start 2", projectRoot: dir)
        let existing = KistREPL.handleTasks("done 1", projectRoot: dir)
        XCTAssertTrue(existing.contains("▶ active remains [2] already running"))
        XCTAssertFalse(existing.contains("advanced to [2]"))

        _ = KistREPL.handleTasks("block 2 waiting", projectRoot: dir)
        let retry = KistREPL.handleTasks("done 1", projectRoot: dir)
        XCTAssertTrue(retry.contains("⚠ no actionable task — blocked work remains"))
    }

    func testBareTaskNumberSelectsBoardTaskForExecution() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = KistREPL.handleTasks("add ACTION: create resolve-aliases.sh | acceptance: script detects alias collision | verify: ./resolve-aliases.sh", projectRoot: dir)

        let task = KistREPL.taskSelectedByUser("1", projectRoot: dir)
        let brief = task.map { KistREPL.executionBrief(for: $0, userInput: "1") } ?? ""

        XCTAssertEqual(task?.id, 1)
        XCTAssertTrue(brief.contains("Execute shared task [1] ACTION: create resolve-aliases.sh"))
        XCTAssertTrue(brief.contains("Acceptance: script detects alias collision"))
        XCTAssertTrue(brief.contains("Verification: ./resolve-aliases.sh"))
    }

    func testTeamBuildThisExpandsToNextBoardTask() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = KistREPL.handleTasks("add ACTION: fix approval prompt routing", projectRoot: dir)

        let expanded = KistREPL.expandBoardReference("build this all now", projectRoot: dir)

        XCTAssertTrue(expanded.contains("Execute shared task [1] ACTION: fix approval prompt routing"))
        XCTAssertEqual(PlanStore(projectRoot: dir).load().tasks.first?.status, .inProgress)
    }

    func testTasksBlockAndClear() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = KistREPL.handleTasks("add do thing", projectRoot: dir)
        let blocked = KistREPL.handleTasks("block 1 waiting on key", projectRoot: dir)
        XCTAssertTrue(blocked.contains("⊘"))
        XCTAssertTrue(KistREPL.handleTasks("clear", projectRoot: dir).contains("cleared"))
        XCTAssertTrue(KistREPL.handleTasks("", projectRoot: dir).contains("no tasks yet"))
    }

    func testTasksCommandParsesHumanContractSyntax() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let out = KistREPL.handleTasks("""
        add ACTION: build router | acceptance: stale Grok model falls back | verify: swift test --filter ProviderHealthTests | evidence: Sources/Kist/KistRunner.swift
        """, projectRoot: dir)
        _ = KistREPL.handleTasks("evidence 1 terminal-smoke.log", projectRoot: dir)

        let task = PlanStore(projectRoot: dir).load().tasks[0]

        XCTAssertTrue(out.contains("acceptance: stale Grok model falls back"))
        XCTAssertEqual(task.kind, .action)
        XCTAssertEqual(task.acceptance, "stale Grok model falls back")
        XCTAssertEqual(task.verification, "swift test --filter ProviderHealthTests")
        XCTAssertEqual(task.evidence, ["Sources/Kist/KistRunner.swift", "terminal-smoke.log"])
    }

    func testReviewCommandAddsReviewKind() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        _ = KistREPL.handleTasks("add REVIEW: attack prompt-injection guard | acceptance: attack rejected", projectRoot: dir)

        XCTAssertEqual(PlanStore(projectRoot: dir).load().tasks[0].kind, .review)
    }

    func testTasksValidateCommandShowsContractWarnings() {
        let dir = NSTemporaryDirectory() + "replplan_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        _ = KistREPL.handleTasks("add REVIEW: attack the router", projectRoot: dir)
        let out = KistREPL.handleTasks("validate", projectRoot: dir)

        XCTAssertTrue(out.contains("contract check:"))
        XCTAssertTrue(out.contains("acceptance"))
        XCTAssertTrue(out.contains("verification"))
    }
}
