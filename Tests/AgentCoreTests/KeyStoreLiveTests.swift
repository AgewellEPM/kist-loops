import XCTest
@testable import AgentCore

/// FileKeyStore must re-read the secret file on each lookup (not cache at init) so a key added
/// mid-session resolves without a restart — the mechanism behind "add a key to a red model → it works now".
final class KeyStoreLiveTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "keys-live-\(UUID().uuidString).json"
    }

    func testFileKeyStoreSeesAKeyWrittenAfterConstruction() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = FileKeyStore(path: path)                    // constructed BEFORE the file exists
        XCTAssertNil(store.key(forAccount: "custom_foo_api_key"), "no file yet ⇒ nil")

        // Add the key mid-session, exactly as the picker's add-key flow does.
        try SecretWriter.write(account: "custom_foo_api_key", key: "sk-live-123", path: path)

        // SAME store instance now resolves it — no reconstruction, no restart.
        XCTAssertEqual(store.key(forAccount: "custom_foo_api_key"), "sk-live-123")
    }

    func testFileKeyStoreReflectsAnUpdatedKey() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try SecretWriter.write(account: "custom_bar_api_key", key: "old", path: path)
        let store = FileKeyStore(path: path)
        XCTAssertEqual(store.key(forAccount: "custom_bar_api_key"), "old")
        try SecretWriter.write(account: "custom_bar_api_key", key: "new", path: path)
        XCTAssertEqual(store.key(forAccount: "custom_bar_api_key"), "new", "live re-read picks up the update")
    }

    func testNewestFallbackRecordBeatsStalePrimary() {
        let primary = VersionedSecretRecord.make(value: "stale-primary", updatedAtMilliseconds: 10)
        let fallback = VersionedSecretRecord.make(value: "rotated-fallback", updatedAtMilliseconds: 11)
        let selected = SecretVersioning.newest(primary: primary, fallback: fallback)
        XCTAssertEqual(selected?.record.value, "rotated-fallback")
        XCTAssertEqual(selected?.source, .fallback)
    }

    func testNewestPrimaryRecordBeatsStaleFallback() {
        let primary = VersionedSecretRecord.make(value: "rotated-primary", updatedAtMilliseconds: 21)
        let fallback = VersionedSecretRecord.make(value: "stale-fallback", updatedAtMilliseconds: 20)
        let selected = SecretVersioning.newest(primary: primary, fallback: fallback)
        XCTAssertEqual(selected?.record.value, "rotated-primary")
        XCTAssertEqual(selected?.source, .primary)
    }

    func testLegacyFlatFileRemainsReadableAndMigratesWithoutDroppingOtherKeys() throws {
        let path = tempPath()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let legacy = #"{"first":"old","second":"preserved"}"#
        try legacy.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertEqual(FileKeyStore(path: path).key(forAccount: "second"), "preserved")

        try SecretWriter.write(account: "first", key: "rotated", path: path)
        let store = FileKeyStore(path: path)
        XCTAssertEqual(store.key(forAccount: "first"), "rotated")
        XCTAssertEqual(store.key(forAccount: "second"), "preserved")
    }

    func testStaleSynchronizationCannotOverwriteNewerRecord() throws {
        let path = tempPath()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let newer = VersionedSecretRecord.make(value: "new", updatedAtMilliseconds: 200)
        let stale = VersionedSecretRecord.make(value: "old", updatedAtMilliseconds: 100)
        try SecretWriter.writeVersioned(account: "account", record: newer, path: path)
        try SecretWriter.writeVersioned(account: "account", record: stale, path: path)
        XCTAssertEqual(FileKeyStore(path: path).key(forAccount: "account"), "new")
    }

    func testFileKeyStoreStillRejectsGroupReadableFile() throws {
        // The owner-only perms gate must still run PER READ, not just at init.
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try #"{"custom_baz_api_key":"leak"}"#.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)  // group/other readable
        let store = FileKeyStore(path: path)
        XCTAssertNil(store.key(forAccount: "custom_baz_api_key"), "a non-owner-only file must not be read")
    }
}
