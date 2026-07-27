import XCTest
import Foundation
@testable import AgentCore

final class LoopCheckpointStoreTests: XCTestCase {
    private var dir: String!
    private var store: LoopCheckpointStore!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "ckpt-\(UUID().uuidString)"
        store = LoopCheckpointStore(directory: dir)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func make(_ status: LoopCheckpoint.Status, iter: Int = 1) -> LoopCheckpoint {
        LoopCheckpoint(goal: "g", providerId: "openai", model: "gpt-4o", projectRoot: "/tmp",
                       messages: [ChatMessage(role: .user, content: "g")], iteration: iter, status: status)
    }

    func testSaveLoadRoundTrip() throws {
        let cp = make(.running)
        try store.save(cp)
        let back = try store.load(id: cp.id)
        XCTAssertEqual(back.id, cp.id)
        XCTAssertEqual(back.goal, "g")
        XCTAssertEqual(back.providerId, "openai")
        XCTAssertEqual(back.iteration, 1)
        XCTAssertEqual(back.messages.count, 1)
    }

    func testResumableExcludesCompleted() throws {
        try store.save(make(.running))
        try store.save(make(.paused))
        try store.save(make(.failed))
        try store.save(make(.completed))
        let r = store.resumable()
        XCTAssertEqual(r.count, 3)   // running + paused + failed; not completed
        XCTAssertFalse(r.contains { $0.status == .completed })
    }

    func testDeleteRemoves() throws {
        let cp = make(.failed)
        try store.save(cp)
        XCTAssertNoThrow(try store.load(id: cp.id))
        store.delete(id: cp.id)
        XCTAssertThrowsError(try store.load(id: cp.id))
    }

    func testRejectsUnsafeIdOnLoadAndSave() {
        // Codex HIGH-2: a user-supplied --resume id must not traverse out of the checkpoint dir.
        XCTAssertThrowsError(try store.load(id: "../../etc/passwd"))
        XCTAssertThrowsError(try store.load(id: "a/b"))
        XCTAssertThrowsError(try store.load(id: ".."))
        let bad = LoopCheckpoint(id: "../evil", goal: "g", providerId: "x", model: nil,
                                 projectRoot: "/tmp", messages: [])
        XCTAssertThrowsError(try store.save(bad))
    }

    func testAllSortedNewestFirst() throws {
        var a = make(.running); a.updatedAt = Date(timeIntervalSince1970: 1000)
        var b = make(.running); b.updatedAt = Date(timeIntervalSince1970: 2000)
        try store.save(a); try store.save(b)
        XCTAssertEqual(store.all().first?.id, b.id)   // newest first
    }
}
