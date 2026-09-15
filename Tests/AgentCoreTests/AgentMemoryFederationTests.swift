import XCTest
@testable import AgentCore

final class AgentMemoryFederationTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "memory-federation-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    private func project(_ name: String) throws -> String {
        let path = root + "/" + name
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    private func seed(_ path: String, detail: String, at: Date = Date()) throws -> AgentHistoryEvent {
        let access = try AgentMemoryAccess(projectRoot: path)
        let identity = AgentRunIdentity(runID: "fixture", parentRunID: nil, rootRunID: "fixture",
            sessionID: "original-session", role: "fixture", project: access.project, executionRoot: path)
        return try access.history.append(agent: identity, kind: "tool_finished", detail: detail, at: at)
    }

    func testDefaultRecallSpansGrantedProjectsAndRetainsOriginalSources() throws {
        let current = try project("current"), allowed = try project("allowed"), denied = try project("denied")
        let at = Date().addingTimeInterval(-60)
        let first = try seed(current, detail: "federatedOrchid current", at: at)
        let second = try seed(allowed, detail: "federatedOrchid allowed", at: at.addingTimeInterval(-60))
        try seed(denied, detail: "federatedOrchid private", at: at)
        let originals = try [first, second].map { try Data(contentsOf: URL(fileURLWithPath: $0.locator)) }
        let access = try AgentMemoryAccess(projectRoot: current, authorizedReadRoots: [allowed, allowed])
        let recall = try access.recall(query: "federatedOrchid")
        XCTAssertEqual(Set(recall.entries.map(\.locator)), Set([first.locator, second.locator]))
        XCTAssertTrue(recall.entries.contains { $0.title.contains(second.at.ISO8601Format()) })
        XCTAssertTrue(recall.historySearchComplete, recall.issues.joined(separator: "; "))
        XCTAssertEqual(try [first, second].map { try Data(contentsOf: URL(fileURLWithPath: $0.locator)) }, originals)
        XCTAssertEqual(try access.recall(query: "federatedOrchid", project: allowed).entries.map(\.locator), [second.locator])
        XCTAssertEqual(try access.narrowed(to: "project").recall(query: "federatedOrchid").entries.map(\.locator), [first.locator])
        XCTAssertThrowsError(try access.selectedProject(denied))
    }

    func testCatalogSurvivesRestartAndNeverGrantsAccessOrRejuvenatesHistory() throws {
        let current = try project("current"), foreign = try project("granted/known")
        let denied = try project("granted-private"), catalog = try project("catalog")
        let old = Date().addingTimeInterval(-86_400 * 5_000)
        let event = try seed(foreign, detail: "catalogOrchid ancient", at: old)
        try seed(denied, detail: "catalogOrchid excluded", at: old)
        _ = try AgentMemoryAccess(projectRoot: foreign, projectCatalogRoot: catalog)
        _ = try AgentMemoryAccess(projectRoot: denied, projectCatalogRoot: catalog)
        let original = try Data(contentsOf: URL(fileURLWithPath: event.locator))
        for _ in 0..<2 {
            let access = try AgentMemoryAccess(projectRoot: current,
                authorizedReadRoots: [root + "/granted"], projectCatalogRoot: catalog)
            let raw = try access.searchHistory(query: "catalogOrchid")
            XCTAssertEqual(raw.page.events.map(\.locator), [event.locator])
            XCTAssertEqual(raw.page.events.first?.at, event.at)
            XCTAssertTrue(try access.recall(query: "catalogOrchid").entries.isEmpty)
        }
        let closed = try AgentMemoryAccess(projectRoot: current, projectCatalogRoot: catalog)
        XCTAssertTrue(try closed.searchHistory(query: "catalogOrchid").page.events.isEmpty)
        XCTAssertThrowsError(try closed.selectedProject(foreign))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: event.locator)), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: foreign + "/.kist/cache"), "foreign projects remain read-only")
    }

    func testSameEventIDInTwoProjectsKeepsBothProvenancesAndToolJSONFits() async throws {
        let first = try project("first"), second = try project("second")
        let a = try seed(first, detail: "collisionOrchid first")
        let b = try seed(second, detail: "collisionOrchid second", at: a.at)
        let event = AgentHistoryEvent(id: a.id, at: a.at, agent: b.agent, kind: b.kind,
            detail: b.detail, originalBytes: b.originalBytes, detailSHA256: b.detailSHA256, clipped: b.clipped)
        try FileManager.default.removeItem(atPath: b.locator)
        _ = try ConfinedRoot(root: second).createDataIfMissing(event.relativePath,
            JSONEncoder().encode(event), createParents: false)
        let access = try AgentMemoryAccess(projectRoot: first, authorizedReadRoots: [second])
        let result = try await SharedAgentMemoryTool().execute(arguments: ["mode": "history_search", "query": "collisionOrchid"],
            context: ToolContext(projectRoot: first, agentMemory: access))
        XCTAssertTrue(result.success, result.output)
        XCTAssertLessThanOrEqual(result.output.utf8.count, SharedAgentMemoryTool.resultByteLimit)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(json["results"] as? [[String: String]])
        XCTAssertEqual(Set(rows.compactMap { $0["source"] }), Set([a.locator, event.locator]))
        XCTAssertEqual(Set(rows.compactMap { $0["project"] }), Set([first, second]))
        XCTAssertEqual(json["authorized_project_count"] as? Int, 2)
        let local = try AgentExecutionScope.$current.withValue(a.agent) {
            try access.narrowed(to: "local").searchHistory(query: "collisionOrchid")
        }
        XCTAssertEqual(local.page.events.map(\.locator), [a.locator])
    }

    func testBoundedProjectPagesReachEveryGrantedArchiveAndBindTheirQuery() throws {
        let current = try project("current")
        var paths: [String] = [], expected = Set<String>()
        for index in 0..<10 {
            let path = try project(String(format: "allowed-%02d", index))
            paths.append(path)
            expected.insert(try seed(path, detail: "pagingOrchid \(index)").locator)
        }
        let access = try AgentMemoryAccess(projectRoot: current, authorizedReadRoots: paths)
        var cursor: String?, seen = Set<String>(), count = 0
        repeat {
            let result = try access.searchHistory(query: "pagingOrchid", before: cursor)
            XCTAssertLessThanOrEqual(result.projects.count, AgentMemoryAccess.projectsPerSearch)
            seen.formUnion(result.page.events.map(\.locator))
            cursor = result.page.nextCursor
            count += 1
            if let cursor {
                XCTAssertFalse(result.complete)
                XCTAssertFalse(result.issues.isEmpty)
                XCTAssertThrowsError(try access.searchHistory(query: "differentOrchid", before: cursor))
                XCTAssertThrowsError(try access.narrowed(to: "project").searchHistory(query: "pagingOrchid", before: cursor))
            }
            XCTAssertLessThan(count, 20)
            if count >= 20 { break }
        } while cursor != nil
        XCTAssertGreaterThan(count, 1)
        XCTAssertEqual(seen, expected)
    }

    func testReplacedAuthorizedRootCannotImportReplacementHistory() throws {
        let current = try project("current"), foreign = try project("granted/known")
        let catalog = try project("catalog")
        _ = try AgentMemoryAccess(projectRoot: foreign, projectCatalogRoot: catalog)
        let access = try AgentMemoryAccess(projectRoot: current, authorizedReadRoots: [root + "/granted"],
                                          projectCatalogRoot: catalog)
        try FileManager.default.moveItem(atPath: root + "/granted", toPath: root + "/old-granted")
        let replacement = try project("granted/known")
        try seed(replacement, detail: "replacementOrchid must stay excluded")
        let result = try access.searchHistory(query: "replacementOrchid")
        XCTAssertTrue(result.page.events.isEmpty)
        XCTAssertFalse(result.complete)
        XCTAssertTrue(result.issues.contains { $0.contains("identity changed") })
        XCTAssertThrowsError(try access.selectedProject(replacement))
    }

    func testSymlinkedCatalogDegradesWithoutWritingThroughIt() throws {
        let current = try project("current"), catalog = try project("catalog"), target = try project("outside")
        try FileManager.default.createSymbolicLink(atPath: catalog + "/agent-memory-projects", withDestinationPath: target)
        let access = try AgentMemoryAccess(projectRoot: current, projectCatalogRoot: catalog)
        let result = try access.searchHistory(query: "missingOrchid")
        XCTAssertFalse(result.complete)
        XCTAssertTrue(result.issues.contains { $0.contains("discovery unavailable") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target), [])
    }

    func testCrossProjectEpisodesNeverFollowSymlinksOutsideGrant() throws {
        let current = try project("current"), foreign = try project("foreign"), denied = try project("denied")
        ProjectMemory(root: denied).recordEpisode(Episode(goal: "escapedOrchid", success: false,
            summary: "private fixture", at: Date()))
        XCTAssertEqual(ProjectMemory(root: denied).recentEpisodes().count, 1, "fixture has an eligible episode")
        try FileManager.default.createSymbolicLink(atPath: foreign + "/.mythos", withDestinationPath: denied + "/.mythos")
        let access = try AgentMemoryAccess(projectRoot: current, authorizedReadRoots: [foreign])
        let recall = try access.recall(query: "escapedOrchid")
        XCTAssertTrue(recall.entries.isEmpty)
        XCTAssertTrue(recall.issues.contains { $0.contains("episode recall unavailable") })
    }

    func testConfinedCrossProjectEpisodeRetainsClockAndOriginalBytes() throws {
        let current = try project("current"), foreign = try project("foreign")
        let at = Date().addingTimeInterval(-120)
        ProjectMemory(root: foreign).recordEpisode(Episode(goal: "episodeOrchid", success: false,
            summary: "original observation", at: at))
        let source = foreign + "/.mythos/memory/episodes.jsonl"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: source))
        let access = try AgentMemoryAccess(projectRoot: current, authorizedReadRoots: [foreign])
        let recall = try access.recall(query: "episodeOrchid")
        XCTAssertEqual(recall.entries.count, 1)
        XCTAssertEqual(recall.entries.first?.locator, source)
        XCTAssertTrue(recall.entries.first?.title.contains(at.ISO8601Format()) == true)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source)), bytes)
    }

    func testRankedOmissionsStayVisibleOnLaterProjectPages() throws {
        let current = try project("current")
        var paths: [String] = []
        for index in 0..<8 {
            let path = try project("ranked-\(index)")
            paths.append(path)
            try seed(path, detail: "rankedOrchid \(index)")
        }
        let access = try AgentMemoryAccess(projectRoot: current, authorizedReadRoots: paths)
        let first = try access.searchHistory(query: "rankedOrchid", limit: 1)
        let cursor = try XCTUnwrap(first.page.nextCursor)
        XCTAssertTrue(first.issues.contains { $0.contains("ranked result window") })
        let last = try access.searchHistory(query: "rankedOrchid", before: cursor, limit: 1)
        XCTAssertNil(last.page.nextCursor)
        XCTAssertEqual(last.page.events.count, 1)
        XCTAssertFalse(last.complete, "a later complete project cannot erase earlier omitted matches")
        XCTAssertTrue(last.issues.contains { $0.contains("completion is not exhaustive") })
    }
}
