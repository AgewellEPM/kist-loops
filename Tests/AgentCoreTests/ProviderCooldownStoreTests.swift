import XCTest
@testable import AgentCore

final class ProviderCooldownStoreTests: XCTestCase {
    /// Mutable test clock that satisfies the store's @Sendable `now` closure.
    private final class Clock: @unchecked Sendable {
        var t: Date
        init(_ t: Date) { self.t = t }
    }

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooldown-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testRecordedProviderCoolsDownThenExpires() {
        let dir = tempDir()
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let store = ProviderCooldownStore(directory: dir, now: { clock.t })
        store.record("OpenAI", ttl: 300)

        XCTAssertTrue(store.coolingDown("openai"))     // case-insensitive
        XCTAssertEqual(store.activeCooldowns(), ["openai"])

        clock.t = Date(timeIntervalSince1970: 1_301)   // past the TTL
        XCTAssertFalse(store.coolingDown("openai"))
        XCTAssertEqual(store.activeCooldowns(), [])
    }

    func testCooldownsAreCrossInstance() {
        // The whole point: a SECOND process (new store instance) sees the bench.
        let dir = tempDir()
        ProviderCooldownStore(directory: dir).record("openai")
        XCTAssertTrue(ProviderCooldownStore(directory: dir).coolingDown("openai"))
    }

    func testCorruptFileFailsOpen() {
        let dir = tempDir()
        try? Data("not json{{{".utf8).write(to: dir.appendingPathComponent("provider-cooldowns.json"))
        let store = ProviderCooldownStore(directory: dir)
        XCTAssertFalse(store.coolingDown("openai"))
        XCTAssertEqual(store.activeCooldowns(), [])
        store.record("openai")                          // recovers by rewriting
        XCTAssertTrue(store.coolingDown("openai"))
    }

    func testExpiredEntriesArePrunedOnSave() throws {
        let dir = tempDir()
        let clock = Clock(Date(timeIntervalSince1970: 1_000))
        let store = ProviderCooldownStore(directory: dir, now: { clock.t })
        store.record("openai", ttl: 10)
        clock.t = Date(timeIntervalSince1970: 2_000)
        store.record("gemini", ttl: 300)                // save prunes the expired openai row

        let data = try Data(contentsOf: dir.appendingPathComponent("provider-cooldowns.json"))
        let table = try JSONDecoder().decode([String: Double].self, from: data)
        XCTAssertEqual(Array(table.keys), ["gemini"])
    }
}
