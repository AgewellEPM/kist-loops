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
