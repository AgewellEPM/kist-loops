import XCTest
import Foundation
@testable import AgentCore

/// The council's consensus #1 — an immutable per-call audit trail at the tool choke point. Records
/// every invocation (incl. BLOCKED ones) with the tool + an arg DIGEST (values hashed, never logged
/// raw) + the enforcement outcome.
final class AuditLogTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() + "audit-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(dir) ?? dir
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    // MARK: digest — values never appear, keys only; stable + order-independent

    func testDigestIsValueBlindAndStable() {
        let a = AuditLog.digest(["path": "/etc/secret", "token": "SECRET-123"])
        let b = AuditLog.digest(["token": "SECRET-123", "path": "/etc/secret"])   // different insertion order
        XCTAssertEqual(a.keys, ["path", "token"], "keys only, sorted")
        XCTAssertEqual(a.digest, b.digest, "digest is order-independent")
        XCTAssertFalse(a.keys.contains { $0.contains("SECRET") }, "no values in keys")
        XCTAssertFalse(a.digest.contains("SECRET"), "no raw value in the digest")
        XCTAssertNotEqual(a.digest, AuditLog.digest(["path": "/etc/secret", "token": "different"]).digest)
    }

    // Codex MED: an intermediate symlink (`.kist` → elsewhere) must NOT redirect the audit trail out
    // of the worktree. O_NOFOLLOW guards only the final file; ensureDir now lstat-checks the parent too.
    func testIntermediateSymlinkOnAuditDirIsRefused() async throws {
        let evil = root + "/evil"
        try FileManager.default.createDirectory(atPath: evil, withIntermediateDirectories: true)
        // Plant `.kist` as a symlink to the attacker dir BEFORE any audit write.
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist", withDestinationPath: evil)
        let log = AuditLog.forProject(root: root)
        await log.record(AuditEntry(at: 1, tool: "run_command", argKeys: ["cmd"], argsDigest: "x",
                                    outcome: "ok", success: true, scope: nil))
        // Nothing is written through the symlink — the trail is NOT redirected into the attacker dir.
        XCTAssertFalse(FileManager.default.fileExists(atPath: evil + "/audit/tools.jsonl"),
                       "audit must not be written through an intermediate symlink")
        // AND no mkdir/chmod side effect through the symlinked parent — the lstat check precedes any
        // filesystem mutation, so the attacker dir gains no `audit` subdir at all (Codex MED round 2).
        XCTAssertFalse(FileManager.default.fileExists(atPath: evil + "/audit"),
                       "ensureDir must reject the symlinked parent BEFORE creating any directory")
        let entryCount = await log.entries().count
        XCTAssertEqual(entryCount, 0, "a redirected audit dir yields no readable trail")
    }

    // MARK: append-only round-trip

    func testRecordAppendsAndReadsBack() async {
        let log = AuditLog(path: root + "/audit/tools.jsonl")
        await log.record(AuditEntry(at: 1, tool: "read_file", argKeys: ["path"], argsDigest: "abc",
                                    outcome: "ok", success: true, scope: nil))
        await log.record(AuditEntry(at: 2, tool: "write_file", argKeys: ["path", "content"], argsDigest: "def",
                                    outcome: "blocked_scope", success: false, scope: ["read_file"]))
        let entries = await log.entries()
        XCTAssertEqual(entries.count, 2, "append-only — two records, two lines")
        XCTAssertEqual(entries[0].tool, "read_file")
        XCTAssertEqual(entries[1].outcome, "blocked_scope")
        XCTAssertEqual(entries[1].scope, ["read_file"])
        // owner-only file
        let attrs = try? FileManager.default.attributesOfItem(atPath: root + "/audit/tools.jsonl")
        XCTAssertEqual(((attrs?[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777) & 0o077, 0)
    }

    // MARK: wired at ToolRegistry.execute — every outcome is recorded

    func testExecuteRecordsOkBlockedAndUnknown() async {
        let log = AuditLog(path: root + "/audit/tools.jsonl")
        let registry = ToolRegistry.headless()

        // 1) ok — a read-only tool that succeeds.
        _ = await registry.execute(name: "list_files", arguments: ["path": "."],
                                   context: ToolContext(projectRoot: root).withAuditLog(log))
        // 2) unknown tool.
        _ = await registry.execute(name: "does_not_exist", arguments: [:],
                                   context: ToolContext(projectRoot: root).withAuditLog(log))
        // 3) blocked by skill capability scope (untrusted-loaded restrictive skill → write blocked).
        let evil = Skill(name: "evil", description: "d", allowedTools: ["read_file"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [evil]); await tracker.markLoaded("evil", trusted: false)
        let scopedCtx = ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true))
            .withSkills(locations: [:], tracker: tracker).withAuditLog(log)
        _ = await registry.execute(name: "write_file", arguments: ["path": "x", "content": "y"], context: scopedCtx)

        let entries = await log.entries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].tool, "list_files"); XCTAssertEqual(entries[0].outcome, "ok")
        XCTAssertEqual(entries[1].outcome, "unknown_tool"); XCTAssertFalse(entries[1].success)
        XCTAssertEqual(entries[2].tool, "write_file"); XCTAssertEqual(entries[2].outcome, "blocked_scope")
        // the blocked write's secret-ish content value is NOT in the log — only the digest.
        XCTAssertFalse(entries[2].argKeys.contains("y"))
    }

    // Codex CRITICAL: a pre-planted SYMLINK at the audit path must NOT be written through (a cloned
    // repo could point it at a secret/world target to exfiltrate the trail).
    func testSymlinkAuditFileRefused() async throws {
        let auditDir = root + "/.kist/audit"
        try FileManager.default.createDirectory(atPath: auditDir, withIntermediateDirectories: true)
        let secret = root + "/secret.txt"
        try "untouched".write(toFile: secret, atomically: true, encoding: .utf8)
        // Plant tools.jsonl as a symlink to the secret file.
        try FileManager.default.createSymbolicLink(atPath: auditDir + "/tools.jsonl", withDestinationPath: secret)

        let log = AuditLog.forProject(root: root)
        await log.record(AuditEntry(at: 1, tool: "x", argKeys: [], argsDigest: "d", outcome: "ok", success: true, scope: nil))
        // The symlink target must be UNCHANGED (no append written through the symlink).
        XCTAssertEqual(try String(contentsOfFile: secret, encoding: .utf8), "untouched",
                       "O_NOFOLLOW must refuse to append through a symlinked audit file")
    }

    // Codex MED: the args digest is HMAC-keyed (or sha256 fallback) — not a trivially-reversible
    // structure; the canonical key=value string is never persisted, only its hex digest.
    func testDigestIsOpaqueHex() {
        let (_, d) = AuditLog.digest(["pin": "1234"])
        XCTAssertEqual(d.count % 2, 0)
        XCTAssertTrue(d.allSatisfy { $0.isHexDigit }, "digest is hex")
        XCTAssertFalse(d.contains("1234"), "value not embedded")
    }

    func testNilAuditLogIsNoOp() async {
        let registry = ToolRegistry.headless()
        // No auditLog on the context → no crash, normal behavior.
        let r = await registry.execute(name: "list_files", arguments: ["path": "."],
                                       context: ToolContext(projectRoot: root))
        XCTAssertNotNil(r)
    }
}
