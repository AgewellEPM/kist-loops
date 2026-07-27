import XCTest
@testable import AgentCore

/// The baton store is single-writer, insert-or-update-by-id, atomic-persist. Pins: save upserts, the
/// fleet/id lookups, latestUnfinished skips terminal batons, and the chain survives a reload.
final class FleetBatonStoreTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("batonstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func baton(_ fleet: UUID, _ state: BatonState = .created) -> Baton {
        Baton(fleetID: fleet, missionGoal: "ship", repo: "/r", state: state)
    }

    func testSaveUpsertsById() {
        let store = FleetBatonStore(baseDir: dir)
        let fleet = UUID()
        let b = baton(fleet, .created)
        store.save(b)
        XCTAssertEqual(store.all().count, 1)
        // Advance the SAME baton id → updates in place, not a second row.
        let held = b.advanced(to: .held, from: "captain", to: "a", atEpoch: 1)!
        store.save(held)
        XCTAssertEqual(store.all().count, 1, "same id updates in place")
        XCTAssertEqual(store.baton(id: b.id)?.state, .held)
    }

    func testFleetScopedLookups() {
        let store = FleetBatonStore(baseDir: dir)
        let f1 = UUID(), f2 = UUID()
        store.save(baton(f1, .held))
        store.save(baton(f1, .passed))
        store.save(baton(f2, .held))
        XCTAssertEqual(store.batons(forFleet: f1).count, 2)
        XCTAssertEqual(store.batons(forFleet: f2).count, 1)
    }

    func testLatestUnfinishedSkipsTerminal() {
        let store = FleetBatonStore(baseDir: dir)
        let f = UUID()
        store.save(baton(f, .passed))   // terminal
        store.save(baton(f, .failed))   // terminal
        XCTAssertNil(store.latestUnfinished(forFleet: f), "all terminal → nothing to resume")
        let live = baton(f, .held)
        store.save(live)
        XCTAssertEqual(store.latestUnfinished(forFleet: f)?.id, live.id, "a mid-flight baton is the resume candidate")
    }

    func testPersistenceSurvivesReload() {
        let f = UUID()
        let id: UUID
        do {
            let store = FleetBatonStore(baseDir: dir)
            let b = baton(f, .submitted)
            id = b.id
            store.save(b)
            XCTAssertNil(store.lastSaveError())
        }
        let reloaded = FleetBatonStore(baseDir: dir)
        XCTAssertEqual(reloaded.baton(id: id)?.state, .submitted, "the baton survives a reload")
    }

    func testBatonSaveFailureDoesNotPublishInMemoryBaton() throws {
        let blockedBase = dir.appendingPathComponent("not-a-directory")
        try "file, not directory".write(to: blockedBase, atomically: true, encoding: .utf8)
        let store = FleetBatonStore(baseDir: blockedBase)

        let ok = store.save(baton(UUID(), .held))

        XCTAssertFalse(ok)
        XCTAssertTrue(store.all().isEmpty, "a failed durable write must not publish an in-memory-only baton")
        XCTAssertNotNil(store.lastSaveError())
    }
}
