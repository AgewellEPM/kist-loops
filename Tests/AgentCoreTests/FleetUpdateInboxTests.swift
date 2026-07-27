import XCTest
@testable import AgentCore

/// The inbox is the producer boundary: agents DROP CellUpdate JSON files; the captain DRAINs (parse +
/// remove, exactly-once). Pins: parsed in filename order; malformed drops are consumed not retried;
/// a second drain is empty; and the drain→fold loop reaches the board.
final class FleetUpdateInboxTests: XCTestCase {

    private var dir: URL!
    private let fleetID = UUID()
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Simulate a detached agent (a different process) dropping an update file with its own code.
    private func drop(_ name: String, _ update: CellUpdate, into inbox: FleetUpdateInbox) throws {
        let data = try JSONEncoder().encode(update)
        try data.write(to: inbox.inboxURL.appendingPathComponent(name))
    }

    func testDrainParsesInFilenameOrderAndRemoves() throws {
        let inbox = FleetUpdateInbox(fleetID: fleetID, baseDir: dir)
        let a = UUID(), b = UUID()
        try drop("02.json", CellUpdate(agentID: b, atEpoch: 2, status: .working), into: inbox)
        try drop("01.json", CellUpdate(agentID: a, atEpoch: 1, status: .working), into: inbox)

        let drained = inbox.drain()
        XCTAssertEqual(drained.map(\.agentID), [a, b], "parsed in stable filename order (01 before 02)")
        // Files are consumed exactly once.
        XCTAssertTrue(inbox.drain().isEmpty, "a second drain finds nothing — exactly-once intake")
    }

    func testMalformedDropIsConsumedNotRetried() throws {
        let inbox = FleetUpdateInbox(fleetID: fleetID, baseDir: dir)
        try drop("good.json", CellUpdate(agentID: UUID(), atEpoch: 1, status: .working), into: inbox)
        try "}{ not json".write(to: inbox.inboxURL.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)

        let drained = inbox.drain()
        XCTAssertEqual(drained.count, 1, "only the valid drop is returned")
        XCTAssertTrue(inbox.drain().isEmpty, "the garbage file was removed too — not retried forever")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: inbox.inboxURL.path)
        XCTAssertTrue(remaining.isEmpty, "the inbox is empty after draining")
    }

    func testReadPendingKeepsValidDropUntilAcknowledged() throws {
        let inbox = FleetUpdateInbox(fleetID: fleetID, baseDir: dir)
        let agent = UUID()
        try drop("good.json", CellUpdate(agentID: agent, atEpoch: 1, status: .working), into: inbox)
        try "}{ not json".write(to: inbox.inboxURL.appendingPathComponent("bad.json"),
                                atomically: true,
                                encoding: .utf8)

        let pending = inbox.readPending()

        XCTAssertEqual(pending.map(\.update.agentID), [agent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.inboxURL.appendingPathComponent("good.json").path),
                      "valid drops remain until the blackboard fold persists")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.inboxURL.appendingPathComponent("bad.json").path),
                       "malformed drops are still consumed")
        XCTAssertEqual(inbox.readPending().count, 1, "unacknowledged valid drops are retried")
        XCTAssertTrue(inbox.acknowledge(pending[0]))
        XCTAssertTrue(inbox.readPending().isEmpty)
    }

    func testValidDropIsNotAcknowledgedWhenBlackboardHasNoLoadedBoard() throws {
        let inbox = FleetUpdateInbox(fleetID: fleetID, baseDir: dir)
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)
        let agent = UUID()
        try drop("good.json", CellUpdate(agentID: agent, atEpoch: 1, status: .working), into: inbox)

        let pending = try XCTUnwrap(inbox.readPending().first)
        if store.foldUpdate(pending.update) {
            _ = inbox.acknowledge(pending)
        }

        XCTAssertEqual(inbox.readPending().map(\.update.agentID), [agent],
                       "a valid update remains retryable when the board fold fails")
        XCTAssertTrue(store.lastSaveError()?.contains("No fleet blackboard loaded") ?? false)
    }

    func testNonJsonFilesIgnored() throws {
        let inbox = FleetUpdateInbox(fleetID: fleetID, baseDir: dir)
        try "ignore me".write(to: inbox.inboxURL.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try drop("u.json", CellUpdate(agentID: UUID(), atEpoch: 1, status: .working), into: inbox)
        XCTAssertEqual(inbox.drain().count, 1, "non-.json files are not intake")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.inboxURL.appendingPathComponent("note.txt").path),
                      "a non-json file is left untouched")
    }

    func testDrainThenFoldReachesTheBoard() throws {
        // The full producer→reducer loop: an agent drops, the captain drains + folds into its store.
        let agent = UUID()
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)
        store.seed(FleetBlackboard(id: fleetID, goal: "g", plan: [], integrationBranch: "i", repo: "/r",
                                   startedAt: Date(timeIntervalSince1970: 1),
                                   cells: [AgentCell(id: agent, title: "t", branch: "b", worktreePath: "/w")]))
        let inbox = FleetUpdateInbox(fleetID: fleetID, baseDir: dir)
        try drop("01.json", CellUpdate(agentID: agent, atEpoch: 5, status: .working,
                                       keyDecisions: ["picked approach X"]), into: inbox)

        for update in inbox.drain() { store.foldUpdate(update) }

        let cell = store.currentBoard()!.cells.first { $0.id == agent }!
        XCTAssertEqual(cell.status, .working, "the drained update reached the board")
        XCTAssertEqual(cell.keyDecisions.map(\.text), ["picked approach X"])
    }
}
