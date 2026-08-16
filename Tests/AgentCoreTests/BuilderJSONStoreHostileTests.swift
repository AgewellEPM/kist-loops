import XCTest
@testable import AgentCore

final class BuilderJSONStoreHostileTests: XCTestCase {
    private func fixture(_ name: String) throws -> (URL, BuilderJSONStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "builder-store-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("run.json")
        return (file, BuilderJSONStore(fileURL: file))
    }

    private func snapshot(sequence: Int = 0) -> BuilderRunSnapshot {
        var value = BuilderRunSnapshot(
            contractID: "store-test", route: .direct,
            nodeStates: ["node": BuilderNodeState()],
            finalReceipt: nil, updatedAt: Date())
        value.schemaVersion = 2
        value.parentContractFingerprint = String(repeating: "a", count: 64)
        value.graphFingerprint = String(repeating: "b", count: 64)
        value.sequence = sequence
        return value
    }

    func testCrossActorLeaseIsExclusiveUntilReleased() async throws {
        let (file, firstStore) = try fixture("lease")
        let secondStore = BuilderJSONStore(fileURL: file)
        let first = try await firstStore.acquireLease()
        do {
            _ = try await secondStore.acquireLease()
            XCTFail("a second process/actor acquired the same run lease")
        } catch {}
        first.release()
        let second = try await secondStore.acquireLease()
        second.release()
    }

    func testStaleSaveAndSnapshotReplayAreRejectedByHighWater() async throws {
        let (file, store) = try fixture("replay")
        try await store.create(snapshot())
        let sequenceZeroBytes = try Data(contentsOf: file)
        let loaded = try await store.load()
        var next = try XCTUnwrap(loaded)
        next.sequence = 1
        next.updatedAt = Date()
        try await store.save(next)

        await XCTAssertStoreThrows {
            try await store.save(next)
        }

        try sequenceZeroBytes.write(to: file, options: .atomic)
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        await XCTAssertStoreThrows {
            try await store.load()
        }
    }

    func testSnapshotAheadByOneRepairsInterruptedHighWaterAppend() async throws {
        let (file, store) = try fixture("repair")
        try await store.create(snapshot())
        let journal = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).high-water")
        let sequenceZeroJournal = try Data(contentsOf: journal)
        let loaded = try await store.load()
        var next = try XCTUnwrap(loaded)
        next.sequence = 1
        next.updatedAt = Date()
        try await store.save(next)

        // Simulate power loss after atomic snapshot publication but before the journal append.
        try sequenceZeroJournal.write(to: journal, options: .atomic)
        XCTAssertEqual(chmod(journal.path, 0o600), 0)
        let repaired = try await store.load()
        XCTAssertEqual(repaired?.sequence, 1)
        let reopened = try await store.load()
        XCTAssertEqual(reopened?.sequence, 1,
                       "the repaired record must be stable on the next open")
    }
}

private func XCTAssertStoreThrows<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}
