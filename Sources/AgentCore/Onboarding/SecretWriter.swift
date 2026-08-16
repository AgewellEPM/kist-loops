import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// File-scope shim so the POSIX `write(2)` isn't shadowed by `SecretWriter.write`.
@inline(__always) private func posixWrite(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
    write(fd, buf, n)
}

/// Writes API keys to the same owner-only file `FileKeyStore` reads:
/// `~/.config/agentcore/keys.json` ({account: key}). CRITICAL: `FileKeyStore`
/// SILENTLY IGNORES a key file that isn't 0600 (`isOwnerOnlySecretFile`), so a
/// key written at the wrong perms would make a model "mysteriously not work".
/// This writer enforces 0700 dir + 0600 file every time, after the atomic write.
public enum SecretWriter {
    public static func defaultPath() -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + "/.config/agentcore/keys.json"
    }

    public enum SecretError: Error, Equatable {
        case emptyKey
        case writeFailed(String)
        case permsFailed(String)
    }

    /// Persist `key` under `account` (e.g. `custom_foo_api_key`), merging with any existing keys.
    /// Idempotent. Enforces owner-only perms so `FileKeyStore` will actually read it back.
    public static func write(account: String, key: String, path: String = defaultPath()) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SecretError.emptyKey }
        try withLockedEnvelope(path: path) { envelope in
            let previous = envelope.keys[account]?.updatedAtMilliseconds ?? Int64.min
            let now = SecretVersioning.milliseconds()
            let next = previous == Int64.max ? previous : max(now, previous + 1)
            envelope.keys[account] = .make(value: trimmed, updatedAtMilliseconds: next)
        }
    }

    /// Preserve a selected logical record while synchronizing an existing stale backend. A record that is
    /// already newer is never overwritten, and a same-version/different-value ambiguity stays untouched.
    static func writeVersioned(account: String, record: VersionedSecretRecord, path: String) throws {
        guard record.isValid else { throw SecretError.writeFailed("refused invalid versioned secret record") }
        try withLockedEnvelope(path: path) { envelope in
            if let existing = envelope.keys[account] {
                if existing.updatedAtMilliseconds > record.updatedAtMilliseconds { return }
                if existing.updatedAtMilliseconds == record.updatedAtMilliseconds,
                   existing.digest != record.digest { return }
            }
            envelope.keys[account] = record
        }
    }

    private static func withLockedEnvelope(path: String,
                                           mutate: (inout SecretFileEnvelope) throws -> Void) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Fail-fast if the secret directory can't be made owner-only — never drop a key into a
        // dir others can traverse/replace files in.
        chmod(dir, 0o700)
        if let dperms = (try? FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions]) as? NSNumber,
           dperms.intValue & 0o077 != 0 {
            throw SecretError.permsFailed("secret dir \(dir) is not owner-only (0700)")
        }

        // A stable sidecar lock serializes the read/merge/rename transaction across threads and processes.
        // Locking the destination inode would be ineffective because the atomic rename replaces that inode.
        let lockPath = path + ".lock"
        let lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw SecretError.writeFailed("could not securely open key-file lock") }
        defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
        guard fchmod(lockFD, 0o600) == 0, flock(lockFD, LOCK_EX) == 0 else {
            throw SecretError.writeFailed("could not acquire owner-only key-file lock")
        }

        var envelope = try loadEnvelope(path: path)
        try mutate(&envelope)
        try persist(envelope: envelope, path: path, dir: dir)
    }

    private static func loadEnvelope(path: String) throws -> SecretFileEnvelope {
        guard FileManager.default.fileExists(atPath: path) else {
            return SecretFileEnvelope(formatVersion: SecretFileEnvelope.currentFormat, keys: [:])
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            throw SecretError.writeFailed("could not read existing key file")
        }
        if let envelope = try? JSONDecoder().decode(SecretFileEnvelope.self, from: data),
           envelope.formatVersion == SecretFileEnvelope.currentFormat,
           envelope.keys.values.allSatisfy(\.isValid) {
            return envelope
        }
        if let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           legacy.values.allSatisfy({ !$0.isEmpty }) {
            let modified = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)
                .map(SecretVersioning.milliseconds) ?? 0
            return SecretFileEnvelope(formatVersion: SecretFileEnvelope.currentFormat,
                                      keys: legacy.mapValues { .make(value: $0, updatedAtMilliseconds: modified) })
        }
        throw SecretError.writeFailed("existing key file is corrupt or uses an unsupported format")
    }

    private static func persist(envelope: SecretFileEnvelope, path: String, dir: String) throws {

        // FAIL-CLOSED secure write. O_CREAT|O_EXCL|O_NOFOLLOW: the temp is brand-new and never a
        // symlink (defeats a pre-planted-symlink TOCTOU), created at 0600 so it's owner-only the
        // instant it exists. Then atomic rename (keeps the 0600 inode) + exact-perm verify.
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(envelope)
        }
        catch { throw SecretError.writeFailed("\(error)") }

        let tmpPath = dir + "/.keys-\(ProcessInfo.processInfo.globallyUniqueString).tmp"
        let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SecretError.writeFailed("could not securely create temp key file") }
        let wrote: Bool = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return raw.count == 0 }
            var off = 0
            while off < raw.count {
                let n = posixWrite(fd, base.advanced(by: off), raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        close(fd)
        guard wrote else { unlink(tmpPath); throw SecretError.writeFailed("write to temp key file failed") }
        guard rename(tmpPath, path) == 0 else {
            unlink(tmpPath); throw SecretError.writeFailed("atomic rename into place failed")
        }
        // Verify EXACT 0600; anything else (incl. setuid/setgid bits) → remove rather than leak.
        if let perms = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? NSNumber,
           (perms.intValue & 0o7777) == 0o600 {
            return
        }
        try? FileManager.default.removeItem(atPath: path)
        throw SecretError.permsFailed("final key file is not exactly 0600; removed to avoid leaking the key")
    }

    /// Derive the conventional key account for a custom provider id.
    /// `foo` -> `custom_foo_api_key` (env override: `CUSTOM_FOO_API_KEY`).
    public static func keyAccount(forCustomId id: String) -> String {
        "custom_\(id)_api_key"
    }
}
