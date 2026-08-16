import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One immutable record of a tool invocation — the council's consensus #1 (a forensic audit trail at
/// the enforcement choke point). Logs WHAT was attempted and the enforcement OUTCOME, but never the
/// raw argument VALUES (those can carry secrets/paths): argument values are reduced to a SHA-256
/// digest so identical calls correlate without leaking content; only the argument KEYS are kept.
public struct AuditEntry: Codable, Sendable, Equatable {
    public let schemaVersion: Int? // present for run-scoped receipts; nil for legacy/project logs
    public let runID: String?      // binds the receipt to one CLI invocation when available
    public let at: Double           // epoch seconds
    public let tool: String
    public let argKeys: [String]    // sorted argument names (no values)
    public let argsDigest: String   // SHA-256 hex of the canonical args (correlate, don't leak)
    public let outcome: String      // ok | blocked_scope | blocked_auth | unknown_tool | error
    public let success: Bool
    public let scope: [String]?     // the active skill capability scope, if one was in force

    public init(at: Double, tool: String, argKeys: [String], argsDigest: String,
                outcome: String, success: Bool, scope: [String]?,
                schemaVersion: Int? = nil, runID: String? = nil) {
        self.schemaVersion = schemaVersion; self.runID = runID
        self.at = at; self.tool = tool; self.argKeys = argKeys; self.argsDigest = argsDigest
        self.outcome = outcome; self.success = success; self.scope = scope
    }
}

/// Append-only JSONL audit log. An `actor` so concurrent fleet tool calls serialize their appends
/// (no interleaved/corrupt lines). Owner-only file; one line per tool invocation. Best-effort: a
/// write failure never blocks or fails the tool call (the audit must not become a denial-of-service).
public actor AuditLog {
    public nonisolated let path: String
    public nonisolated let runID: String?
    private var ensured = false

    public init(path: String) {
        self.path = path
        self.runID = nil
    }

    private init(path: String, runID: String) {
        self.path = path
        self.runID = runID
    }

    /// Project-scoped audit log at `<root>/.kist/audit/tools.jsonl`.
    public static func forProject(root: String) -> AuditLog {
        AuditLog(path: root + "/.kist/audit/tools.jsonl")
    }

    /// One receipt stream per CLI invocation. The run identifier is reduced to a conservative filename
    /// alphabet (or an opaque digest), so even a future caller that accepts external IDs cannot escape the
    /// owner-only audit directory. The exact path is deterministic for `(root, runID)` and can be printed by
    /// the host for dogfood/CI discovery.
    public static func forRun(root: String, runID: String) -> AuditLog {
        let safeID = safeRunID(runID)
        return AuditLog(path: root + "/" + runRelativePath(runID: safeID), runID: safeID)
    }

    public static func runRelativePath(runID: String) -> String {
        ".kist/audit/tools-\(safeRunID(runID)).jsonl"
    }

    private nonisolated static func safeRunID(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !raw.isEmpty, raw.utf8.count <= 128,
           raw.unicodeScalars.allSatisfy({ allowed.contains($0) }), raw != ".", raw != ".." {
            return raw
        }
        return "opaque-" + MythosCrypto.sha256(Data(raw.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private var warned = false

    public func record(_ entry: AuditEntry) {
        guard ensureDir() else { warnOnce(); return }
        let receipt: AuditEntry
        if let runID {
            receipt = AuditEntry(
                at: entry.at, tool: entry.tool, argKeys: entry.argKeys,
                argsDigest: entry.argsDigest, outcome: entry.outcome,
                success: entry.success, scope: entry.scope,
                schemaVersion: 1, runID: runID)
        } else {
            receipt = entry
        }
        guard var line = try? JSONEncoder().encode(receipt) else { return }
        line.append(0x0A)   // newline — written in ONE write() so O_APPEND keeps small lines atomic
        // O_NOFOLLOW: refuse if the audit file is a SYMLINK (a cloned repo could plant one pointing at
        // a secret/world-writable target to exfiltrate the trail — Codex CRITICAL). O_APPEND: atomic
        // offset across processes. O_CLOEXEC: don't leak the fd to spawned tools.
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { warnOnce(); return }
        defer { close(fd) }
        // Verify the opened fd is a REGULAR file we OWN with no group/other bits — reject a pre-planted
        // non-owner / wrong-mode file rather than appending to it.
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else { warnOnce(); return }
        // Don't ignore the write result: a short write or -1 (disk-full/quota/EINTR) would silently
        // drop or truncate a forensic record. Loop to completion; warn once on any hard failure so the
        // operator knows the audit trail has a gap (Codex LOW).
        let ok = line.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            while off < raw.count {
                let n = write(fd, base.advanced(by: off), raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                off += n
            }
            return true
        }
        if !ok { warnOnce() }
    }

    private func warnOnce() {
        guard !warned else { return }
        warned = true
        FileHandle.standardError.write(Data("kist: tool audit log unavailable (\(path)) — continuing without an audit trail\n".utf8))
    }

    /// All entries (for a `/audit` view / tests). Best-effort; skips malformed lines.
    public func entries() -> [AuditEntry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(AuditEntry.self, from: d)
        }
    }

    /// Create the audit dir (idempotent) and verify it is NOT a symlink — refuse if a repo planted
    /// `.kist/audit` as a symlink to redirect appends. Returns false on any failure (caller skips).
    private func ensureDir() -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        let parent = (dir as NSString).deletingLastPathComponent
        // Reject a planted `.kist` symlink BEFORE any filesystem mutation — else createDirectory +
        // setAttributes would mkdir/chmod THROUGH the symlink into the attacker's target (the write is
        // blocked later, but the mkdir/chmod side effect already happened). If `.kist` exists it MUST
        // be a real dir we own; if it doesn't exist yet, createDirectory will make it safely (Codex MED,
        // round 2 — move the lstat check ahead of the mkdir, not after).
        var pst = stat()
        if lstat(parent, &pst) == 0 {
            guard (pst.st_mode & S_IFMT) == S_IFDIR, pst.st_uid == getuid() else { return false }
        }
        if !ensured {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        }
        // AFTER creating: lstat the FINAL audit dir AND its parent (`.kist`) again. lstat only inspects
        // the named component, so verifying just `.kist/audit` would miss a `.kist` symlink; re-checking
        // both also catches a creation race (O_NOFOLLOW guards only the final log file). Both must be
        // real dirs we own (Codex MED).
        for component in [parent, dir] {
            var st = stat()
            guard lstat(component, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
                  st.st_uid == getuid() else { return false }
        }
        ensured = true   // set only AFTER a verified-good directory (Codex: don't mark ensured on failure)
        return true
    }

    // MARK: digest helper

    /// Content-correlatable digest of an argument map WITHOUT a brute-force oracle: HMAC-SHA256 keyed
    /// by the per-install ForgeSeal key (NOT stored with the log), so an attacker holding the log
    /// can't recompute a short secret value's digest (Codex MED). Falls back to plain SHA-256 only
    /// when no install key exists. Argument VALUES feed the hash input but are NEVER persisted.
    public static func digest(_ arguments: [String: Any]) -> (keys: [String], digest: String) {
        let keys = arguments.keys.sorted()
        let canonical = keys.map { "\($0)=\(String(describing: arguments[$0] ?? ""))" }.joined(separator: "\u{1f}")
        let hmac = ForgeSeal.sign(canonical)   // keyed HMAC hex; "" if no install key
        let hex: String
        if hmac.isEmpty {
            // No install key → the digest is UNKEYED SHA-256, which an attacker holding the log could
            // brute-force for a short/low-entropy argument value. Tamper-evident only against an attacker
            // WITHOUT the log, not one with it. Warn ONCE so the operator knows integrity is degraded and
            // can provision the ForgeSeal key (DeepSeek LOW). Best-effort observability, never fatal.
            warnUnkeyedDigestOnce()
            hex = MythosCrypto.sha256(Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        } else {
            hex = hmac
        }
        return (keys, hex)
    }

    private static let unkeyedWarnLock = NSLock()
    nonisolated(unsafe) private static var warnedUnkeyedDigest = false
    private static func warnUnkeyedDigestOnce() {
        unkeyedWarnLock.lock(); defer { unkeyedWarnLock.unlock() }
        guard !warnedUnkeyedDigest else { return }
        warnedUnkeyedDigest = true
        let msg = "kist: audit digests are UNKEYED (no install HMAC key) — the trail is tamper-evident only "
            + "against an attacker WITHOUT the log; provision the ForgeSeal install key for keyed integrity\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }
}
