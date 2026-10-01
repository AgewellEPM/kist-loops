import XCTest
@testable import AgentCore

final class PlanGoalMapTests: XCTestCase {
    private func workspace() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("goalmap-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    func testMapShowsBlockerStaleWorkAndEvidenceGapsWithoutCertifyingDone() {
        let plan = Plan(title: "Ship parser", tasks: [
            PlanTask(id: 1, title: "old active", status: .inProgress, startedAt: 1),
            PlanTask(id: 2, title: "research", kind: .research),
            PlanTask(id: 3, title: "build", acceptance: "Parses inputs", verification: "swift test"),
            PlanTask(id: 4, title: "deploy", detail: "volume access denied", status: .blocked),
            PlanTask(id: 5, title: "claimed done", status: .done),
        ])
        let text = PlanGoalMap.render(plan, projectRoot: "/project", sessionStartedAt: Date(timeIntervalSince1970: 10))
        XCTAssertTrue(text.contains("Next execution: [3] build"), text)
        XCTAssertTrue(text.contains("Acceptance: Parses inputs"))
        XCTAssertTrue(text.contains("volume access denied"))
        XCTAssertTrue(text.contains("Earlier session"))
        XCTAssertTrue(text.contains("Marked done without evidence references (1)"))
        XCTAssertTrue(text.contains("Board status is not verified completion"))
        XCTAssertEqual(plan.tasks[0].startedAt, 1)
    }

    func testBoundedOutputEvenWhenEveryTaskHasHugeFields() {
        let giant = String(repeating: "x", count: 10_000)
        let plan = Plan(tasks: (1...1000).map {
            PlanTask(id: $0, title: giant, detail: giant, status: .blocked, evidence: [giant])
        })
        let text = PlanGoalMap.render(plan, projectRoot: "/project", taskID: 999)
        XCTAssertLessThan(text.count, 6000)
        XCTAssertTrue(text.contains("996 more"))
        XCTAssertTrue(text.contains("Task [999]"))
        XCTAssertFalse(text.contains(giant))
    }

    func testControlCharactersCannotRewriteTerminalOutput() {
        let text = PlanGoalMap.render(Plan(title: "\u{1B}[2Jgoal\r\nspoof", tasks: [
            PlanTask(id: 1, title: "real\u{1B}]0;window\u{7}")
        ]), projectRoot: "/project")
        XCTAssertFalse(text.contains("\u{1B}"))
        XCTAssertFalse(text.contains("\u{7}"))
        XCTAssertTrue(text.contains("goal spoof"))
    }

    func testAbsentBoardDoesNotCreateFiles() throws {
        let root = try workspace()
        XCTAssertTrue(try PlanGoalMap.load(projectRoot: root).tasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.kist"))
    }

    func testReadLeavesBoardBytesAndTimestampUnchanged() throws {
        let root = try workspace()
        let store = PlanStore(projectRoot: root)
        store.add(title: "work")
        let file = URL(fileURLWithPath: root + "/.kist/plan.json")
        let before = try Data(contentsOf: file)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file.path)
        _ = try PlanGoalMap.load(projectRoot: root)
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(store.modifiedAt(), stamp)
    }

    func testMalformedOversizedAndDuplicateBoardsAreNotReportedAsEmpty() throws {
        let root = try workspace()
        let store = PlanStore(projectRoot: root)
        store.add(title: "work")
        let file = URL(fileURLWithPath: root + "/.kist/plan.json")
        for bytes in [Data("{".utf8), Data(repeating: 32, count: PlanGoalMap.maxPlanBytes + 1),
                      try JSONEncoder().encode(Plan(tasks: [PlanTask(id: 1, title: "a"), PlanTask(id: 1, title: "b")]))] {
            try bytes.write(to: file)
            XCTAssertThrowsError(try PlanGoalMap.load(projectRoot: root))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testSymlinkBoardRefused() throws {
        let root = try workspace()
        let outside = try workspace()
        PlanStore(projectRoot: outside).add(title: "private")
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist", withDestinationPath: outside + "/.kist")
        XCTAssertThrowsError(try PlanGoalMap.load(projectRoot: root))
    }

    func testToolMapIsReadOnlyAcrossAllClassifiersAndExecution() async throws {
        let root = try workspace()
        PlanStore(projectRoot: root).add(title: "build")
        let args: [String: Any] = ["action": "  MAP\n"]
        XCTAssertTrue(HeadlessAgentLoop.isReadOnlyTasksCall(tool: "tasks", args: args))
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "tasks", args: args, projectRoot: root), .safe)
        XCTAssertEqual(ToolEffectCatalog.observe(tool: "tasks", arguments: args).progress, .none)
        for gate in [ScopeGate.planOnly, .needsScope] {
            let scope = ScopeDecision(kind: .normal, gate: gate, reason: "test read-only scope",
                                      allowedActions: [], blockedActions: [], requiredEvidence: [])
            XCTAssertNil(scope.toolBlockReason(tool: "tasks", arguments: args))
            XCTAssertNotNil(scope.toolBlockReason(tool: "tasks", arguments: ["action": "start"]))
        }
        let result = try await ManageTasksTool().execute(arguments: args, context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.output)
        XCTAssertTrue(result.output.contains("Goal map"))
        XCTAssertEqual(PlanStore(projectRoot: root).load().tasks[0].status, .todo)
    }

    func testExplicitInvalidIDsNeverStartAnUnrelatedTask() async throws {
        let root = try workspace()
        let store = PlanStore(projectRoot: root)
        store.add(title: "must remain queued")
        let file = URL(fileURLWithPath: root + "/.kist/plan.json")
        let before = try Data(contentsOf: file)
        let invalid: [Any] = [999, "unknown", 0, -1, true, 1.5, Double.infinity, Double.nan, NSNull(), "9999999999999999999999"]
        for id in invalid {
            let result = try await ManageTasksTool().execute(arguments: ["action": "start", "id": id], context: ToolContext(projectRoot: root))
            XCTAssertFalse(result.success, "\(id): \(result.output)")
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
        let started = try await ManageTasksTool().execute(arguments: ["action": " START ", "id": "1"], context: ToolContext(projectRoot: root))
        XCTAssertTrue(started.success)
        XCTAssertEqual(store.load().tasks[0].status, .inProgress)
    }

    func testStartNextPrioritizesActionAndFallsBackToResearch() throws {
        let root = try workspace()
        let store = PlanStore(projectRoot: root)
        store.add(title: "research", kind: .research)
        store.add(title: "build")
        XCTAssertEqual(store.load().nextForExecution()?.id, 2)
        XCTAssertTrue(store.load().render().contains("next step: [2] build"))
        XCTAssertEqual(store.startNext()?.id, 2)
        _ = store.update(id: 2, status: .done)
        XCTAssertEqual(store.startNext()?.id, 1)
    }

    func testAllDoneIsNotMistakenForBlockedWorkOrVerifiedCompletion() {
        let text = PlanGoalMap.render(Plan(tasks: [PlanTask(id: 1, title: "work", status: .done)]),
                                      projectRoot: "/project")
        XCTAssertTrue(text.contains("all tasks marked done; verification still requires evidence"))
        XCTAssertFalse(text.contains("blocked or stale work needs attention"))
    }
}
