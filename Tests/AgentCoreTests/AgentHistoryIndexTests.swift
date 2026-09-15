import Foundation
import XCTest
@testable import AgentCore

final class AgentHistoryIndexTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("history-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func access(_ child: String = "project") throws -> AgentMemoryAccess {
        let path = root.appendingPathComponent(child)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return try AgentMemoryAccess(projectRoot: path.path)
    }
    private func agent(_ access: AgentMemoryAccess) throws -> AgentRunIdentity {
        try access.identity(runID: "original-run", role: "worker", executionRoot: access.project.canonicalPath)
    }
    private func cacheFiles(_ access: AgentMemoryAccess) -> [URL] {
        let directory = URL(fileURLWithPath: access.project.canonicalPath).appendingPathComponent(".kist/cache/agent-history-index")
        return (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "json" }
    }

    func testThousandsOfEventsFindOldestBeyondRecentWindowAndReuseIndexAfterReopen() throws {
        let access = try access(), identity = try agent(access)
        let now = Date()
        let oldest = try access.history.append(agent: identity, kind: "tool_finished",
            detail: "orchidHistoricalNeedle at the original location", at: now.addingTimeInterval(-4_000))
        let original = try Data(contentsOf: URL(fileURLWithPath: oldest.locator))
        for index in 0..<3_005 {
            try access.history.append(agent: identity, kind: "tool_finished", detail: "unrelated event \(index)",
                                      at: now.addingTimeInterval(Double(index - 3_500)))
        }
        let first = try access.searchHistory(query: "orchidHistoricalNeedle")
        XCTAssertEqual(first.page.events.map(\.id), [oldest.id])
        XCTAssertEqual(first.indexedRecords, 3_006, first.issues.joined(separator: "; "))
        XCTAssertTrue(first.complete, first.issues.joined(separator: "; "))
        let reopened = try AgentMemoryAccess(projectRoot: access.project.canonicalPath)
        let second = try reopened.searchHistory(query: "orchidHistoricalNeedle")
        XCTAssertEqual(second.page.scanned, 1, "reopened index should read only the matching raw source")
        XCTAssertEqual(second.page.events.first?.at, oldest.at)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: oldest.locator)), original)
        XCTAssertEqual(try reopened.recall(query: "orchidHistoricalNeedle", at: now).entries.first?.locator, oldest.locator)
        let late = try reopened.history.append(agent: identity, kind: "tool_finished",
            detail: "backfilledCanary", at: now.addingTimeInterval(-5_000))
        let backfilled = try reopened.searchHistory(query: "backfilledCanary")
        XCTAssertEqual(backfilled.page.events.first?.id, late.id)
        XCTAssertLessThan(backfilled.page.scanned, 150, "one appended event should rebuild only its affected shard")
    }

    func testOldRawEventStaysOldAfterIndexingAndCacheRepair() throws {
        let access = try access(), identity = try agent(access)
        let now = Date(), old = now.addingTimeInterval(-86_400 * 5_000)
        let event = try access.history.append(agent: identity, kind: "tool_finished", detail: "ancientIndexCanary", at: old)
        XCTAssertEqual(try access.searchHistory(query: "ancientIndexCanary").page.events.first?.at, old)
        XCTAssertTrue(try access.recall(query: "ancientIndexCanary", at: now).entries.isEmpty)
        for path in cacheFiles(access) { try Data("broken cache".utf8).write(to: path) }
        let repaired = try access.searchHistory(query: "ancientIndexCanary")
        XCTAssertEqual(repaired.page.events.first?.id, event.id)
        XCTAssertFalse(repaired.issues.isEmpty)
        XCTAssertTrue(try access.recall(query: "ancientIndexCanary", at: now).entries.isEmpty)
    }

    func testBoundedBuildReportsIncompleteAndCanRecover() throws {
        let access = try access(), identity = try agent(access)
        try access.history.append(agent: identity, kind: "tool_finished", detail: "pendingIndexCanary")
        var limited = AgentHistoryIndex(source: access.history, cacheProject: access.project)
        limited.maximumBuildReads = 0
        let partial = try limited.search(query: "pendingIndexCanary")
        XCTAssertFalse(partial.complete)
        XCTAssertTrue(partial.issues.contains { $0.contains("incomplete") })
        XCTAssertTrue(partial.page.events.isEmpty)
        XCTAssertEqual(try access.searchHistory(query: "pendingIndexCanary").page.events.count, 1)
    }

    func testAuthorizedForeignArchiveCachesOnlyInsideOriginalProject() throws {
        let home = try access(), foreign = try access("foreign"), identity = try agent(foreign)
        let event = try foreign.history.append(agent: identity, kind: "tool_finished", detail: "foreignIndexCanary")
        let allowed = try AgentMemoryAccess(projectRoot: home.project.canonicalPath,
                                            authorizedReadRoots: [foreign.project.canonicalPath])
        XCTAssertEqual(try allowed.searchHistory(query: "foreignIndexCanary", project: foreign.project.canonicalPath).page.events.first?.locator,
                       event.locator)
        XCTAssertFalse(cacheFiles(home).isEmpty)
        XCTAssertTrue(cacheFiles(foreign).isEmpty)
        XCTAssertThrowsError(try home.searchHistory(query: "foreignIndexCanary", project: foreign.project.canonicalPath))
    }

    func testModifiedSourceWithRestoredMtimeCannotReuseStaleTerms() throws {
        let access = try access(), identity = try agent(access)
        let event = try access.history.append(agent: identity, kind: "tool_finished", detail: "firstIndexCanary")
        XCTAssertEqual(try access.searchHistory(query: "firstIndexCanary").page.events.count, 1)
        let path = URL(fileURLWithPath: event.locator)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate])
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        value["detail"] = "laterIndexCanary"
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path.path)
        let found = try access.searchHistory(query: "laterIndexCanary")
        XCTAssertEqual(found.page.events.first?.detail, "laterIndexCanary")
        XCTAssertTrue(try access.searchHistory(query: "firstIndexCanary").page.events.isEmpty)
    }

    func testUnsafeCacheUsesExplicitlyDegradedRawFallbackWithoutFollowingLink() throws {
        let access = try access(), identity = try agent(access)
        try access.history.append(agent: identity, kind: "tool_finished", detail: "rawFallbackCanary")
        let outside = root.appendingPathComponent("untouched")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: access.project.canonicalPath + "/.kist/cache",
                                                   withDestinationPath: outside.path)
        let result = try access.searchHistory(query: "rawFallbackCanary")
        XCTAssertEqual(result.page.events.count, 1)
        XCTAssertFalse(result.complete)
        XCTAssertTrue(result.issues.contains { $0.contains("index unavailable") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
}
