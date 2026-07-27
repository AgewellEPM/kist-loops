import XCTest
@testable import AgentCore

final class PlanStoreTests: XCTestCase {

    private func tempStore() -> (PlanStore, String) {
        let path = NSTemporaryDirectory() + "plan_\(UUID().uuidString).json"
        return (PlanStore(path: path), path)
    }

    func testAddAssignsMonotonicIdsAndPersists() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let a = store.add(title: "first")
        let b = store.add(title: "second")
        XCTAssertEqual(a.id, 1); XCTAssertEqual(b.id, 2)
        XCTAssertEqual(PlanStore(path: path).load().tasks.count, 2)   // survives a reopen
    }

    func testUpdateStatusAndDoneCount() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        store.add(title: "a"); store.add(title: "b")
        XCTAssertEqual(store.update(id: 1, status: .done)?.status, .done)
        XCTAssertNil(store.update(id: 99, status: .done))            // unknown id
        XCTAssertEqual(store.load().done, 1)
    }

    func testModifiedAtIsNilWhenAbsentAndReflectsPinnedTimestamp() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(store.modifiedAt())                              // no file yet
        store.add(title: "a")                                        // first write creates the file
        // Pin a known mtime and assert modifiedAt() reports exactly it (the timestamp contract).
        let known = Date(timeIntervalSince1970: 1_700_000_000)
        try? FileManager.default.setAttributes([.modificationDate: known], ofItemAtPath: path)
        guard let m = store.modifiedAt() else { return XCTFail("expected a modification date after write") }
        XCTAssertEqual(m.timeIntervalSince1970, known.timeIntervalSince1970, accuracy: 1.0)
    }

    func testNextAndStartNext() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        store.add(title: "a"); store.add(title: "b")
        store.update(id: 1, status: .done)
        XCTAssertEqual(store.load().next?.id, 2)                     // lowest remaining todo
        XCTAssertEqual(store.startNext()?.id, 2)
        XCTAssertEqual(store.load().tasks.first(where: { $0.id == 2 })?.status, .inProgress)
        // no todos left → startNext returns nil
        store.update(id: 2, status: .done)
        XCTAssertNil(store.startNext())
    }

    func testRenderShowsMarkersAndNext() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        store.add(title: "build it"); store.update(id: 1, status: .done)
        store.add(title: "ship it")
        let r = store.load().render()
        XCTAssertTrue(r.contains("☑"))           // done marker
        XCTAssertTrue(r.contains("current goal: Plan"))
        XCTAssertTrue(r.contains("completed: 1/2"))
        XCTAssertTrue(r.contains("→ next: [2] ship it"))
    }

    func testRenderShowsActiveTaskAndTestPlan() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        store.add(title: "ACTION: build the parser")
        store.add(title: "TEST: swift test --filter ParserTests")
        store.update(id: 1, status: .inProgress)

        let r = store.load().render()

        XCTAssertTrue(r.contains("active task: [1] ACTION: build the parser"))
        XCTAssertTrue(r.contains("test plan: [2] swift test --filter ParserTests"))
    }

    func testRichContractFieldsPersistAndRender() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let task = store.add(title: "Build provider router",
                             owner: "coder",
                             kind: .action,
                             acceptance: "Grok 404 falls back automatically",
                             verification: "swift test --filter ProviderHealthTests",
                             evidence: ["Tests/AgentCoreTests/ProviderHealthTests.swift"])

        let reloaded = PlanStore(path: path).load().tasks.first

        XCTAssertEqual(task.kind, .action)
        XCTAssertEqual(reloaded?.acceptance, "Grok 404 falls back automatically")
        XCTAssertEqual(reloaded?.verification, "swift test --filter ProviderHealthTests")
        XCTAssertEqual(reloaded?.evidence, ["Tests/AgentCoreTests/ProviderHealthTests.swift"])
        let rendered = store.load().render()
        XCTAssertTrue(rendered.contains("acceptance: Grok 404 falls back automatically"))
        XCTAssertTrue(rendered.contains("verify: swift test --filter ProviderHealthTests"))
        XCTAssertTrue(rendered.contains("evidence: Tests/AgentCoreTests/ProviderHealthTests.swift"))
    }

    func testRenderNormalizesLegacyVerifyPrefix() {
        let plan = Plan(tasks: [PlanTask(id: 1,
                                         title: "ACTION: migrate old board",
                                         verification: "Verify: focused tests pass")])

        let rendered = plan.render()

        XCTAssertTrue(rendered.contains("verify: focused tests pass"))
        XCTAssertFalse(rendered.contains("verify: Verify:"))
    }

    func testContractValidatorFlagsDoneWithoutEvidence() {
        let plan = Plan(tasks: [PlanTask(id: 1,
                                         title: "ACTION: ship change",
                                         status: .done,
                                         acceptance: "feature works",
                                         verification: "swift test")])

        let issues = PlanContractValidator.validate(plan)

        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].field, "evidence")
        XCTAssertTrue(PlanContractValidator.render(issues).contains("done task has no attached proof"))
    }

    func testContractValidatorAcceptsProvenTask() {
        let plan = Plan(tasks: [PlanTask(id: 1,
                                         title: "TEST: run regression",
                                         status: .done,
                                         acceptance: "regression passes",
                                         verification: "swift test --filter PlanStoreTests",
                                         evidence: ["test-output.log"])])

        XCTAssertTrue(PlanContractValidator.validate(plan).isEmpty)
    }

    func testOldPlanJsonDecodesWithContractDefaults() throws {
        let (_, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        let oldJSON = """
        {"title":"Legacy","tasks":[{"id":1,"title":"TEST: old regression","detail":"","status":"todo","owner":"critic"}],"nextId":2}
        """
        try oldJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))

        let task = PlanStore(path: path).load().tasks[0]

        XCTAssertEqual(task.kind, .test)
        XCTAssertEqual(task.acceptance, "")
        XCTAssertEqual(task.verification, "")
        XCTAssertEqual(task.evidence, [])
    }

    func testReplaceRebasesNextId() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        store.replace(title: "Runbook", tasks: [PlanTask(id: 5, title: "x"), PlanTask(id: 9, title: "y")])
        let added = store.add(title: "z")
        XCTAssertEqual(added.id, 10)             // past the max seeded id
    }

    func testSaveRepairsStaleNextIdBeforeFutureAdds() {
        let (store, path) = tempStore(); defer { try? FileManager.default.removeItem(atPath: path) }
        store.save(Plan(title: "Manual", tasks: [PlanTask(id: 7, title: "existing")], nextId: 1))

        let added = store.add(title: "new")

        XCTAssertEqual(added.id, 8)
        XCTAssertEqual(store.load().nextId, 9)
    }

    // MARK: tool surface

    func testToolAddListStartDone() async throws {
        let dir = NSTemporaryDirectory() + "plantool_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = ToolContext(projectRoot: dir)
        let tool = ManageTasksTool()

        _ = try await tool.execute(arguments: ["action": "add", "title": "parse csv"], context: ctx)
        let started = try await tool.execute(arguments: ["action": "start"], context: ctx)
        XCTAssertTrue(started.output.contains("started [1]"))
        let done = try await tool.execute(arguments: ["action": "done", "id": 1], context: ctx)
        XCTAssertTrue(done.output.contains("☑"))
        let list = try await tool.execute(arguments: ["action": "list"], context: ctx)
        XCTAssertTrue(list.output.contains("1/1 done"))
    }

    func testToolValidateReportsContractIssues() async throws {
        let dir = NSTemporaryDirectory() + "plantool_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = ToolContext(projectRoot: dir)
        let tool = ManageTasksTool()

        _ = try await tool.execute(arguments: ["action": "add", "kind": "review", "title": "Audit router"], context: ctx)
        let result = try await tool.execute(arguments: ["action": "validate"], context: ctx)

        XCTAssertTrue(result.output.contains("contract check:"))
        XCTAssertTrue(result.output.contains("acceptance"))
        XCTAssertTrue(result.output.contains("verification"))
    }

    func testToolCapturesPlanActionTestReviewContractFields() async throws {
        let dir = NSTemporaryDirectory() + "plantool_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = ToolContext(projectRoot: dir)
        let tool = ManageTasksTool()

        _ = try await tool.execute(arguments: [
            "action": "add",
            "kind": "review",
            "title": "Attack the provider router",
            "acceptance": "Known 404/429/network paths recover",
            "verification": "swift test --filter ProviderRetryTests",
            "evidence": ["Tests/AgentCoreTests/ProviderRetryTests.swift"],
            "owner": "critic",
        ], context: ctx)
        _ = try await tool.execute(arguments: ["action": "evidence", "id": 1, "evidence": "review-notes.md"], context: ctx)

        let task = PlanStore(projectRoot: dir).load().tasks[0]

        XCTAssertEqual(task.kind, .review)
        XCTAssertEqual(task.acceptance, "Known 404/429/network paths recover")
        XCTAssertEqual(task.verification, "swift test --filter ProviderRetryTests")
        XCTAssertEqual(task.evidence, ["Tests/AgentCoreTests/ProviderRetryTests.swift", "review-notes.md"])
    }
}
