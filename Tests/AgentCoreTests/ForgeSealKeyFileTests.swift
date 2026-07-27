import XCTest
@testable import AgentCore

/// Exercises the FILE-backed key path (not the ephemeral test path) against a temp dir, pinning the
/// fail-closed load behavior Codex flagged (HIGH): a pre-existing key must be a 32-byte 0600 file or the
/// seal layer refuses to operate — it is NEVER silently regenerated (which would both trust a
/// leaked/planted key and enable a forced-rekey DoS).
final class ForgeSealKeyFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeSealKeyFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ForgeSeal.resetCacheForTesting()                    // clear forceEphemeral + cache + any override
        ForgeSeal.keyDirectoryOverrideForTesting = dir.path // set AFTER reset (reset clears the override)
    }

    override func tearDownWithError() throws {
        ForgeSeal.resetCacheForTesting()   // clears the override so later suites use the real path
        try? FileManager.default.removeItem(at: dir)
    }

    private var keyFile: URL { dir.appendingPathComponent("forgeseal-v1.key") }

    /// First run with no existing key → a 32-byte 0600 file is created and seals round-trip.
    func testFirstRunCreates0600KeyAndSealsRoundTrip() throws {
        let seal = ForgeSeal.sign("canonical=x")
        XCTAssertEqual(seal.count, 64, "a key was created and used")
        XCTAssertTrue(ForgeSeal.verify("canonical=x", seal: seal))

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFile.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "key file is owner-only")
        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: keyFile.path))
        XCTAssertEqual(bytes.count, 32, "32-byte key")
    }

    /// A pre-existing key file readable by group/other is treated as compromised → fail closed (sign
    /// returns "", verify false). The seal layer refuses to mint trust from a leaked key.
    func testGroupReadableKeyFileFailsClosed() throws {
        let planted = Data(repeating: 0xAB, count: 32)
        XCTAssertTrue(FileManager.default.createFile(atPath: keyFile.path, contents: planted,
                                                     attributes: [.posixPermissions: 0o644]))
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = dir.path   // reset cleared it; re-point at the temp dir

        XCTAssertEqual(ForgeSeal.sign("x"), "", "an insecure-permission key must not be used → empty seal")
        XCTAssertFalse(ForgeSeal.verify("x", seal: "deadbeef"), "verify fails closed with no usable key")
    }

    /// A pre-existing key file of the wrong size is rejected (no silent regeneration).
    func testWrongSizeKeyFileFailsClosed() throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: keyFile.path, contents: Data([1, 2, 3]),
                                                     attributes: [.posixPermissions: 0o600]))
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = dir.path

        XCTAssertEqual(ForgeSeal.sign("x"), "", "a malformed key file must not be silently replaced")
        // And the malformed file is left intact (not clobbered by a fresh key) — no forced re-key.
        XCTAssertEqual(FileManager.default.contents(atPath: keyFile.path), Data([1, 2, 3]))
    }

    /// A secure 0600 32-byte key that already exists is loaded and used (the normal cross-run case).
    func testExistingSecureKeyIsLoadedAndUsed() throws {
        let known = Data(repeating: 0x42, count: 32)
        XCTAssertTrue(FileManager.default.createFile(atPath: keyFile.path, contents: known,
                                                     attributes: [.posixPermissions: 0o600]))
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = dir.path

        let seal = ForgeSeal.sign("y")
        XCTAssertEqual(seal.count, 64, "an existing secure key is loaded and produces a seal")
        XCTAssertTrue(ForgeSeal.verify("y", seal: seal))
        XCTAssertEqual(FileManager.default.contents(atPath: keyFile.path), known, "key untouched")
    }
}
