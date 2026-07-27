import XCTest
@testable import AgentCore

/// The blackboard store is the captain's sole-writer fold + persist. Pins: fold applies advisory status
/// but clamps self-`.signedOff`; append-only facts; filesTouched union; revision bumps on a trusted fold
/// but NOT on an advisory progress heartbeat; the stale-read guard; the peer digest; atomic reload.
final class FleetBlackboardStoreTests: XCTestCase {

    private var dir: URL!
    private let fleetID = UUID()
    private let a = UUID(), b = UUID()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bbstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func seededStore() -> FleetBlackboardStore {
        let board = FleetBlackboard(
            id: fleetID, goal: "ship the fleet", plan: [], integrationBranch: "mythos/integration",
            repo: "/r", startedAt: Date(timeIntervalSince1970: 1),
            cells: [AgentCell(id: a, title: "parser", branch: "mythos/a", worktreePath: "/wt/a", scopeGlobs: ["Core/*"]),
                    AgentCell(id: b, title: "lexer", branch: "mythos/b", worktreePath: "/wt/b", scopeGlobs: ["Lex/*"])])
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)
        store.seed(board)
        return store
    }

    private func boardFixture(cells: [AgentCell]? = nil) -> FleetBlackboard {
        FleetBlackboard(
            id: fleetID, goal: "ship the fleet", plan: [], integrationBranch: "mythos/integration",
            repo: "/r", startedAt: Date(timeIntervalSince1970: 1),
            cells: cells ?? [
                AgentCell(id: a, title: "parser", branch: "mythos/a", worktreePath: "/wt/a", scopeGlobs: ["Core/*"]),
                AgentCell(id: b, title: "lexer", branch: "mythos/b", worktreePath: "/wt/b", scopeGlobs: ["Lex/*"])
            ])
    }

    func testSeedPersistsAndReloads() {
        _ = seededStore()
        let reloaded = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)
        XCTAssertEqual(reloaded.currentBoard()?.cells.count, 2, "the seeded board survives a reload")
        XCTAssertEqual(reloaded.currentBoard()?.schemaVersion, FleetBlackboard.currentSchemaVersion)
        XCTAssertNil(reloaded.lastSaveError())
        XCTAssertNil(reloaded.lastLoadError())
    }

    func testCorruptBoardLoadIsReported() throws {
        let boardDir = dir.appendingPathComponent(fleetID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: boardDir, withIntermediateDirectories: true)
        try "{ not json".write(to: boardDir.appendingPathComponent("blackboard.json"),
                               atomically: true, encoding: .utf8)

        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)

        XCTAssertNil(store.currentBoard())
        XCTAssertNil(store.lastSaveError())
        XCTAssertTrue(store.lastLoadError()?.contains("Couldn't load fleet blackboard") ?? false)
    }

    func testSeedFailureDoesNotPublishInMemoryBoard() throws {
        let blockedBase = dir.appendingPathComponent("not-a-directory")
        try "file, not directory".write(to: blockedBase, atomically: true, encoding: .utf8)
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: blockedBase)

        let ok = store.seed(boardFixture())

        XCTAssertFalse(ok)
        XCTAssertNil(store.currentBoard(), "a failed initial persist must not publish a resume-unsafe memory board")
        XCTAssertNotNil(store.lastSaveError())
    }

    func testFoldUpdateWithoutLoadedBoardFailsSoInboxCanRetry() {
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)

        let ok = store.foldUpdate(CellUpdate(agentID: a, atEpoch: 5, status: .working))

        XCTAssertFalse(ok)
        XCTAssertNil(store.currentBoard())
        XCTAssertTrue(store.lastSaveError()?.contains("No fleet blackboard loaded") ?? false)
    }

    func testFoldProgressWithoutLoadedBoardFails() {
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)

        let ok = store.foldProgress(agentID: a, liveStep: 1, lastAction: "still alive", atEpoch: 5)

        XCTAssertFalse(ok)
        XCTAssertNil(store.currentBoard())
        XCTAssertTrue(store.lastSaveError()?.contains("No fleet blackboard loaded") ?? false)
    }

    func testFoldUpdateFailureDoesNotPublishInMemoryOnlyMutation() throws {
        let store = seededStore()
        let before = store.currentBoard()!
        let boardDir = dir.appendingPathComponent(fleetID.uuidString)
        try FileManager.default.removeItem(at: boardDir)
        try "file, not directory".write(to: boardDir, atomically: true, encoding: .utf8)

        let ok = store.foldUpdate(CellUpdate(agentID: a, atEpoch: 5, status: .working,
                                             keyDecisions: ["would be memory-only"]))

        XCTAssertFalse(ok)
        XCTAssertNotNil(store.lastSaveError())
        let after = store.currentBoard()
        XCTAssertEqual(after?.revision, before.revision, "memory must stay at the last durable board")
        XCTAssertEqual(after?.cells.first { $0.id == a }?.status,
                       before.cells.first { $0.id == a }?.status)
        XCTAssertFalse(after?.cells.first { $0.id == a }?.keyDecisions.contains { $0.text == "would be memory-only" } ?? true)
        let reloaded = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)
        XCTAssertNil(reloaded.currentBoard(), "the old durable board was intentionally removed for this test")
    }

    func testFoldAppliesStatusAppendsFactsUnionsFilesAndBumpsRevision() {
        let store = seededStore()
        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 5, status: .working,
                                    keyDecisions: ["chose recursive descent"], filesTouched: ["Core/Parser.swift"]))
        let cell = store.currentBoard()!.cells.first { $0.id == a }!
        XCTAssertEqual(cell.status, .working)
        XCTAssertEqual(cell.keyDecisions.map(\.text), ["chose recursive descent"])
        XCTAssertEqual(cell.filesTouched, ["Core/Parser.swift"])
        XCTAssertEqual(store.currentBoard()?.revision, 1, "a trusted fold bumps the revision")
    }

    func testAgentCannotSelfReportSignedOff() {
        let store = seededStore()
        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 5, status: .signedOff))
        XCTAssertEqual(store.currentBoard()!.cells.first { $0.id == a }!.status, .pending,
                       "an agent may NOT promote itself to signedOff — only the foreman can")
    }

    func testUnknownAgentUpdateIsDropped() {
        let store = seededStore()
        let before = store.currentBoard()!.revision
        store.foldUpdate(CellUpdate(agentID: UUID(), atEpoch: 5, status: .working))
        XCTAssertEqual(store.currentBoard()!.revision, before, "an update for an unknown agent can't fabricate a cell")
    }

    func testProgressFoldDoesNotBumpRevision() {
        let store = seededStore()
        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 5, status: .working))   // rev → 1
        let revAfterTrustedFold = store.currentBoard()!.revision
        store.foldProgress(agentID: a, liveStep: 3, lastAction: "writing Parser.swift", atEpoch: 6)
        let cell = store.currentBoard()!.cells.first { $0.id == a }!
        XCTAssertEqual(cell.liveStep, 3)
        XCTAssertEqual(cell.lastAction, "writing Parser.swift")
        XCTAssertEqual(store.currentBoard()!.revision, revAfterTrustedFold,
                       "an ADVISORY progress heartbeat must NOT bump the trusted-mutation revision (else it drops legit stale-checked status pushes)")
    }

    func testStaleUpdateMergesFactsButSkipsStatusAndFlags() {
        let store = seededStore()
        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 5, status: .working))   // rev → 1
        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 6, status: .blocked))   // rev → 2
        // A STALE update composed against rev 1 (now the board is at rev 2).
        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 7, status: .working,
                                    keyDecisions: ["late but real note"], baseRevision: 1))
        let cell = store.currentBoard()!.cells.first { $0.id == a }!
        XCTAssertEqual(cell.status, .blocked, "a stale status must NOT regress the newer one")
        XCTAssertTrue(cell.keyDecisions.contains { $0.text == "late but real note" }, "append-only facts still merge")
        XCTAssertTrue(cell.openQuestions.contains { $0.text.contains("Stale update") }, "staleness is surfaced for reconciliation")
    }

    func testFutureWorkerUpdateTimestampIsClampedToCaptainReceiveTime() {
        let store = seededStore()

        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 99_999, status: .working,
                                    keyDecisions: ["future note"]),
                         receivedAtEpoch: 100)

        let cell = store.currentBoard()!.cells.first { $0.id == a }!
        XCTAssertEqual(cell.lastHeartbeatEpoch, 100)
        XCTAssertEqual(cell.keyDecisions.first?.atEpoch, 100)
        XCTAssertTrue(cell.openQuestions.contains { $0.text.contains("timestamp was in the future") })
    }

    func testSupervisorBlockedStatusIgnoresWorkerWorkingUpdate() {
        let store = seededStore()
        var board = store.currentBoard()!
        var cell = board.cells[board.cells.firstIndex { $0.id == a }!]
        cell.status = .blocked
        cell.supervisorInterventions = [
            SupervisorInterventionRecord(kind: "stale", atEpoch: 10,
                                         summary: "no heartbeat", evidence: ["last heartbeat"])
        ]
        board.cells[board.cells.firstIndex { $0.id == a }!] = cell
        store.seed(board)

        store.foldUpdate(CellUpdate(agentID: a, atEpoch: 11, status: .working,
                                    keyDecisions: ["I am working now"]),
                         receivedAtEpoch: 11)

        let updated = store.currentBoard()!.cells.first { $0.id == a }!
        XCTAssertEqual(updated.status, .blocked)
        XCTAssertTrue(updated.keyDecisions.contains { $0.text == "I am working now" })
        XCTAssertTrue(updated.openQuestions.contains { $0.text.contains("Supervisor block remains active") })
    }

    func testDigestShowsPeersOnlyAndSignedOffMarker() {
        let store = seededStore()
        // mark b signed off via a non-advisory path: simulate the foreman by re-seeding with b signedOff.
        var board = store.currentBoard()!
        board.cells[board.cells.firstIndex { $0.id == b }!].status = .signedOff
        store.seed(board)

        let digest = store.digest(forAgent: a)
        XCTAssertTrue(digest.contains("FLEET SHARED CONTEXT"))
        XCTAssertTrue(digest.contains("lexer"), "peer b is shown")
        XCTAssertFalse(digest.contains("parser"), "the requesting agent a is NOT shown to itself")
        XCTAssertTrue(digest.contains("[SIGNED OFF]"), "a proven peer is marked")
    }

    func testDigestEmptyWhenNoPeers() {
        let board = FleetBlackboard(id: fleetID, goal: "g", plan: [], integrationBranch: "i", repo: "/r",
                                    startedAt: Date(timeIntervalSince1970: 1),
                                    cells: [AgentCell(id: a, title: "solo", branch: "x", worktreePath: "/x")])
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)
        store.seed(board)
        XCTAssertEqual(store.digest(forAgent: a), "", "a one-agent fleet has no peer context")
    }

    func testClampTruncatesWithMarker() {
        let big = String(repeating: "x", count: 4000)
        let out = FleetBlackboardStore.clamp(big, to: 1500)
        XCTAssertLessThanOrEqual(out.count, 1500)
        XCTAssertTrue(out.contains("truncated"))
        XCTAssertEqual(FleetBlackboardStore.clamp("short", to: 1500), "short", "under the cap is untouched")
    }

    func testSeedCapsUnboundedAppendOnlyLedgers() {
        var noisy = AgentCell(id: a, title: "noisy", branch: "mythos/noisy", worktreePath: "/wt/noisy")
        noisy.keyDecisions = (0..<250).map { Note(atEpoch: Double($0), text: "decision-\($0)") }
        noisy.openQuestions = (0..<250).map { Note(atEpoch: Double($0), text: "question-\($0)") }
        noisy.blockers = (0..<250).map { Note(atEpoch: Double($0), text: "blocker-\($0)") }
        noisy.supervisorInterventions = (0..<60).map {
            SupervisorInterventionRecord(kind: "stale", atEpoch: Double($0),
                                         summary: "intervention-\($0)", evidence: [])
        }
        noisy.supervisorEscalations = (0..<60).map {
            SupervisorEscalationRecord(kind: "blocked", atEpoch: Double($0),
                                       summary: "escalation-\($0)", evidence: [],
                                       assignment: "rescue-\($0)")
        }
        let store = FleetBlackboardStore(fleetID: fleetID, baseDir: dir)

        XCTAssertTrue(store.seed(boardFixture(cells: [noisy])))

        let cell = store.currentBoard()!.cells[0]
        XCTAssertEqual(cell.keyDecisions.count, 200)
        XCTAssertEqual(cell.keyDecisions.first?.text, "decision-50")
        XCTAssertEqual(cell.openQuestions.count, 200)
        XCTAssertEqual(cell.openQuestions.first?.text, "question-50")
        XCTAssertEqual(cell.blockers.count, 200)
        XCTAssertEqual(cell.blockers.first?.text, "blocker-50")
        XCTAssertEqual(cell.supervisorInterventions.count, 50)
        XCTAssertEqual(cell.supervisorInterventions.first?.summary, "intervention-10")
        XCTAssertEqual(cell.supervisorEscalations.count, 50)
        XCTAssertEqual(cell.supervisorEscalations.first?.summary, "escalation-10")
    }
}
