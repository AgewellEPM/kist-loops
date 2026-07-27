import XCTest
@testable import AgentCore

/// End-to-end: `verify` produces + stores a sealed receipt for a change; `guard` then admits THAT change and
/// rejects anything else. This is the full proof-carrying-patch loop the git-guard runs.
final class ReceiptCLITests: XCTestCase {
    private func tempRoot() -> String {
        let r = NSTemporaryDirectory() + "kist_cli_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: r, withIntermediateDirectories: true)
        return r
    }
    private let key: (Data, String) = (Data("cli-key".utf8), "test")

    func testCleanChangeVerifiesPassAndGuardAdmits() {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let diff = "diff --git a/a.swift b/a.swift\n+let total = items.reduce(0, +)\n"
        let build = [CommandCheck(name: "build", command: "swift build").evaluate { _ in (0, "ok") }]
        let (sealed, saved) = ReceiptCLI.verify(projectRoot: root, baseSHA: "b", changedFiles: ["a.swift"],
                                                diff: diff, commandChecks: build, key: key, now: 1, issuer: "kist/test")
        XCTAssertTrue(saved)
        XCTAssertEqual(sealed.receipt.verdict, .pass)
        // guard admits the exact change that was verified
        XCTAssertEqual(ReceiptCLI.guardDecision(projectRoot: root, diff: diff, key: key.0), .admit)
        // guard rejects any OTHER change (no receipt for it)
        XCTAssertFalse(ReceiptCLI.guardDecision(projectRoot: root, diff: diff + "x", key: key.0).isAdmitted)
    }

    func testSecretIntroducingChangeVerifiesFailAndGuardRejects() {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let diff = "diff --git a/c.swift b/c.swift\n+let api_key = \"AKIAIOSFODNN7EXAMPLE1234\"\n"
        let (sealed, _) = ReceiptCLI.verify(projectRoot: root, baseSHA: "b", changedFiles: ["c.swift"],
                                            diff: diff, commandChecks: [], key: key, now: 1, issuer: "kist/test")
        XCTAssertEqual(sealed.receipt.verdict, .fail, "a secret-introducing change fails the deterministic scan")
        // even though a (failing) receipt exists, guard rejects a non-pass verdict → the change can't merge
        XCTAssertFalse(ReceiptCLI.guardDecision(projectRoot: root, diff: diff, key: key.0).isAdmitted)
    }

    func testFailingBuildBlocksTheReceipt() {
        let root = tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let diff = "+let a = 1"
        let build = [CommandCheck(name: "build", command: "swift build").evaluate { _ in (1, "compile error") }]
        let (sealed, _) = ReceiptCLI.verify(projectRoot: root, baseSHA: "b", changedFiles: ["a"], diff: diff,
                                            commandChecks: build, key: key, now: 1, issuer: "kist/test")
        XCTAssertEqual(sealed.receipt.verdict, .fail)
        XCTAssertFalse(ReceiptCLI.guardDecision(projectRoot: root, diff: diff, key: key.0).isAdmitted)
    }

    func testKeyEnvOverride() {
        setenv("KIST_RECEIPT_KEY", "shared-org-secret", 1); defer { unsetenv("KIST_RECEIPT_KEY") }
        let (k, id) = ReceiptKey.load()
        XCTAssertEqual(k, Data("shared-org-secret".utf8)); XCTAssertEqual(id, "env")
    }

    /// Codex gate hygiene: a trivially-weak env key (< minEnvKeyBytes) is IGNORED — it does not become the
    /// sealing key. (Falls through to a per-install key in a temp HOME so the test never touches the real one.)
    func testWeakEnvKeyIsIgnored() {
        setenv("KIST_RECEIPT_KEY", "x", 1); defer { unsetenv("KIST_RECEIPT_KEY") }
        let home = tempRoot(); defer { try? FileManager.default.removeItem(atPath: home) }
        let (k, id) = ReceiptKey.load(home: home)
        XCTAssertNotEqual(k, Data("x".utf8), "a 1-byte env key must not be used as the seal key")
        XCTAssertEqual(id, "install")
    }

    /// Codex round 2: a freshly generated per-install key is created 0600 and re-reads STABLY (same bytes twice).
    func testInstallKeyCreated0600AndStable() {
        unsetenv("KIST_RECEIPT_KEY")
        let home = tempRoot(); defer { try? FileManager.default.removeItem(atPath: home) }
        let (k1, id1) = ReceiptKey.load(home: home)
        XCTAssertEqual(id1, "install")
        let path = (home as NSString).appendingPathComponent(".kist/receipt-key")
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs?[.posixPermissions] as? NSNumber)?.intValue, 0o600, "key must be created 0600")
        let (k2, _) = ReceiptKey.load(home: home)
        XCTAssertEqual(k1, k2, "an existing valid key must re-read stably, not rotate")
    }

    /// Codex round 2: a key file with insecure mode (world-readable) is NOT trusted → ephemeral (fail-closed).
    func testWorldReadableKeyIsRejectedAsEphemeral() {
        unsetenv("KIST_RECEIPT_KEY")
        let home = tempRoot(); defer { try? FileManager.default.removeItem(atPath: home) }
        let dir = (home as NSString).appendingPathComponent(".kist")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("receipt-key")
        FileManager.default.createFile(atPath: path, contents: Data("some-key-bytes-here".utf8),
                                       attributes: [.posixPermissions: 0o644])
        let (_, id) = ReceiptKey.load(home: home)
        XCTAssertEqual(id, "ephemeral", "a 0644 key file must be ignored (fail-closed), not trusted")
    }
}
