import XCTest
@testable import AgentCore

final class SMLRuntimeStoreCacheTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-store-cache-\(UUID().uuidString)")
    }

    func testCachedReaderSeesAnotherStoreAtomicReplacementAndMergesItsUpdate() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("runtime.json")
        let reader = SMLRuntimeStore(fileURL: url)
        let writer = SMLRuntimeStore(fileURL: url)
        try await reader.save(SMLRuntimeSnapshot(replayClaims: ["first": 2_000]))
        _ = try await reader.load()
        let replacement = SMLRuntimeSnapshot(replayClaims: ["other": 3_000])
        try await writer.save(replacement)

        let loaded = try await reader.load()
        XCTAssertEqual(loaded, replacement)
        try await reader.update { $0.replayClaims["third"] = 4_000 }
        let observed = try await writer.load()
        XCTAssertEqual(observed.replayClaims, ["other": 3_000, "third": 4_000])
    }

    func testSameLengthInPlaceEditWithRestoredModificationDateInvalidatesCache() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("runtime.json")
        let store = SMLRuntimeStore(fileURL: url)
        try await store.save(SMLRuntimeSnapshot(replayClaims: ["first": 2_000]))
        _ = try await store.load()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let original = try String(contentsOf: url, encoding: .utf8)
        let replacement = Data(original.replacingOccurrences(of: "first", with: "other").utf8)
        XCTAssertEqual(replacement.count, original.utf8.count)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: replacement)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: try XCTUnwrap(attributes[.modificationDate])], ofItemAtPath: url.path
        )

        let loaded = try await store.load()
        XCTAssertEqual(loaded.replayClaims, ["other": 2_000])
        try await store.update { $0.replayClaims["third"] = 4_000 }
        let persisted = try JSONDecoder().decode(SMLRuntimeSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(persisted.replayClaims, ["other": 2_000, "third": 4_000])
    }

    func testMalformedReplacementIsNeverMaskedOrOverwrittenByCachedSnapshot() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("runtime.json")
        let store = SMLRuntimeStore(fileURL: url)
        let snapshot = SMLRuntimeSnapshot(replayClaims: ["first": 2_000])
        try await store.save(snapshot)
        _ = try await store.load()
        let malformed = Data("{\"schema_version\":3,\"tasks\":".utf8)
        try malformed.write(to: url, options: .atomic)

        do {
            _ = try await store.load()
            XCTFail("cached snapshot concealed malformed current bytes")
        } catch let error as SMLRuntimeStoreError {
            guard case .decoding = error else { return XCTFail("unexpected error: \(error)") }
        }
        do {
            try await store.save(snapshot)
            XCTFail("cached schema bypassed current snapshot validation before replacement")
        } catch let error as SMLRuntimeStoreError {
            guard case .decoding = error else { return XCTFail("unexpected error: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }

    func testCachedLoadStillRejectsSymlinkAndSeesMissingFile() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("runtime.json")
        let external = root.appendingPathComponent("external.json")
        let store = SMLRuntimeStore(fileURL: url)
        try await store.save(SMLRuntimeSnapshot(replayClaims: ["first": 2_000]))
        let bytes = try Data(contentsOf: url)
        _ = try await store.load()
        try bytes.write(to: external)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
        do {
            _ = try await store.load()
            XCTFail("cache bypassed descriptor validation")
        } catch let error as SMLRuntimeStoreError {
            guard case .io = error else { return XCTFail("unexpected error: \(error)") }
        }
        try FileManager.default.removeItem(at: url)
        let missing = try await store.load()
        XCTAssertEqual(missing, SMLRuntimeSnapshot())
        XCTAssertEqual(try Data(contentsOf: external), bytes)
    }
}
