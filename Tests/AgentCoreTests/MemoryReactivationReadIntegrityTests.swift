import XCTest
@testable import AgentCore

final class MemoryReactivationReadIntegrityTests: XCTestCase {
    private var root = ""
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "reactivation-read-integrity-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
    }

    private func fixture(failureAgeDays: Double) throws -> AgentMemoryAccess {
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "repair orchidRegistry mirror", success: true,
            summary: "ORCHID_CACHE_DRIFT resolved by rebuilding the mirror index",
            at: now.addingTimeInterval(-86_400 * 1_000)))
        let access = try AgentMemoryAccess(projectRoot: root)
        let identity = AgentRunIdentity(runID: "original-failure", parentRunID: nil,
            rootRunID: "original-failure", sessionID: "original-session", role: "fixture",
            project: access.project, executionRoot: root)
        try access.history.append(agent: identity, kind: "failed",
            detail: "orchidRegistry ORCHID_CACHE_DRIFT", at: now.addingTimeInterval(-86_400 * failureAgeDays))
        return access
    }

    private func overlays() throws -> [String] {
        let folder = root + "/" + MemoryReactivationStore.directory
        guard FileManager.default.fileExists(atPath: folder) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
    }

    func testReadingAnAgedFailureDoesNotEstablishANewRecurrence() throws {
        let access = try fixture(failureAgeDays: 1_000)
        let result = try access.recall(query: "unrelated documentation", at: now)
        XCTAssertEqual(result.reactivatedCandidates, 0,
                       "the age of a failure must not be replaced by the time it was read")
        XCTAssertTrue(try overlays().isEmpty, "an old failure is not fresh reactivation evidence")
    }

    func testRepeatedRecallDoesNotRepublishTheSameFailureAsNewEvidence() throws {
        let access = try fixture(failureAgeDays: 0)
        _ = try access.recall(query: "first question", at: now)
        let first = try overlays()
        XCTAssertFalse(first.isEmpty, "fixture must exercise a real first reactivation")
        let result = try access.recall(query: "second question", at: now.addingTimeInterval(1))
        XCTAssertEqual(result.reactivatedCandidates, 0,
                       "the same immutable failure cannot become a new recurrence on another read")
        XCTAssertEqual(try overlays(), first, "ordinary reads must not refresh the reactivation overlay")
    }

    func testReactivationOfOneEpisodeDoesNotBoostAnotherEpisodeInTheSameFile() throws {
        let age = now.addingTimeInterval(-86_400 * 400)
        let memory = ProjectMemory(root: root)
        memory.recordEpisode(Episode(goal: "orchidRegistry ORCHID_CACHE_DRIFT", success: true,
                                     summary: "repair mirror", at: age))
        memory.recordEpisode(Episode(goal: "unrelatedJournalOther", success: true,
                                     summary: "unrelated dormant observation", at: age))
        let access = try AgentMemoryAccess(projectRoot: root)
        let identity = AgentRunIdentity(runID: "current-failure", parentRunID: nil,
            rootRunID: "current-failure", sessionID: "current-session", role: "fixture",
            project: access.project, executionRoot: root)
        try access.history.append(agent: identity, kind: "failed",
                                  detail: "orchidRegistry ORCHID_CACHE_DRIFT", at: now)
        let first = try access.recall(query: "first question", at: now)
        XCTAssertEqual(first.reactivatedCandidates, 1, "fixture must reactivate only the matching episode")
        let second = try access.recall(query: "unrelatedJournalOther", at: now.addingTimeInterval(1))
        XCTAssertFalse(second.entries.contains { $0.text.contains("unrelatedJournalOther") },
                       "a shared JSONL path does not make two episodes the same memory")
    }

    func testRereadingDoesNotGraduallyConsumeAnExistingSetOfFailures() throws {
        let access = try fixture(failureAgeDays: 0)
        let identity = AgentRunIdentity(runID: "earlier-failure", parentRunID: nil,
            rootRunID: "earlier-failure", sessionID: "earlier-session", role: "fixture",
            project: access.project, executionRoot: root)
        try access.history.append(agent: identity, kind: "failed",
            detail: "orchidRegistry ORCHID_CACHE_DRIFT", at: now.addingTimeInterval(-60))
        _ = try access.recall(query: "first question", at: now)
        let first = try overlays()
        XCTAssertFalse(first.isEmpty)
        let again = try access.recall(query: "second question", at: now.addingTimeInterval(1))
        XCTAssertEqual(again.reactivatedCandidates, 0)
        XCTAssertEqual(try overlays(), first, "all evidence existed before the first read")
    }

    func testReactivationRecordPreservesTheOriginalFailureClockAndLocator() throws {
        let access = try fixture(failureAgeDays: 1.0 / 24)
        let failure = try XCTUnwrap(access.history.page(limit: 1).events.first)
        _ = try access.recall(query: "later question", at: now)
        let name = try XCTUnwrap(overlays().first)
        let data = try Data(contentsOf: URL(fileURLWithPath:
            root + "/" + MemoryReactivationStore.directory + "/" + name))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(record["failureAt"] as? Double, failure.at.timeIntervalSince1970)
        XCTAssertEqual(record["failureLocator"] as? String, failure.locator)
        XCTAssertEqual(record["failureDetailSHA256"] as? String, failure.detailSHA256)
    }
}
