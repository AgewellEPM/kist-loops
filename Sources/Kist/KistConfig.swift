import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Optional defaults from `~/.config/kist/config.json` (XDG). Precedence: CLI flags > config >
/// built-in defaults. Keeps the common case ("always use my model") out of every invocation.
///
/// Example:
///   { "provider": "openai", "model": "gpt-5.5" }
struct KistConfig {
    private static let maxConfigBytes = 1_048_576
    private static let maxWriteAttempts = 4
    private static let inProcessWriteLock = NSLock()

    private enum ConfigFileState: Equatable {
        case missing
        case bytes(Data)
    }

    var provider: String?
    var model: String?
    /// `"autoRouting": true` keeps Captain per-turn model choice ON even when `provider` sets a
    /// default (the provider is then only the STARTING model). Absent = legacy behaviour, where
    /// a configured provider pins the session.
    var autoRouting: Bool? = nil
    /// How the DEFAULT model is chosen when nothing is pinned: "power" (strongest) or "cost" (cheapest).
    /// Absent = power. Set by `/cost` · `/power` in the REPL or `--by-cost` · `--by-power`.
    var selectBy: ProviderSelectionPolicy? = nil
    var fetchAllowedHosts: [String] = []

    static func path() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        return base + "/kist/config.json"
    }

    /// Persist ONLY the selection policy, merging into the existing config JSON so hand-set fields
    /// (provider/model/hosts) are preserved. Used by the `/cost` · `/power` REPL toggles so the choice
    /// sticks across launches. Returns false (never throws) if the file can't be written.
    @discardableResult
    static func writeSelectBy(_ policy: ProviderSelectionPolicy) -> Bool {
        writeSelectBy(policy, atPath: path())
    }

    /// The stable sidecar lock serializes Kist processes even though the config itself is atomically
    /// replaced. The content comparison also detects a non-cooperating editor that changes policy
    /// after our read; we then re-merge from its new bytes instead of overwriting them.
    @discardableResult
    static func writeSelectBy(
        _ policy: ProviderSelectionPolicy,
        atPath p: String,
        beforeCompareAndSwap: (() -> Void)? = nil
    ) -> Bool {
        inProcessWriteLock.lock()
        defer { inProcessWriteLock.unlock() }

        let directory = (p as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch { return false }

        guard let lockFD = openConfigLock(at: p + ".lock") else { return false }
        defer {
            _ = flock(lockFD, LOCK_UN)
            _ = close(lockFD)
        }

        var interleave = beforeCompareAndSwap
        for _ in 0..<maxWriteAttempts {
            guard let snapshot = configFileState(at: p) else { return false }
            var obj: [String: Any] = [:]
            if case .bytes(let existing) = snapshot {
                guard isValidConfigObjectData(existing),
                      let parsed = (try? JSONSerialization.jsonObject(with: existing))
                        as? [String: Any] else { return false }
                obj = parsed
            }
            obj["selectBy"] = policy.rawValue
            guard let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  data.count <= maxConfigBytes else { return false }

            interleave?()
            interleave = nil
            guard configFileState(at: p) == snapshot else { continue }
            do {
                try data.write(to: URL(fileURLWithPath: p), options: .atomic)
                return true
            } catch { return false }
        }
        return false
    }

    private static func openConfigLock(at lockPath: String) -> Int32? {
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0 else {
            _ = close(fd)
            return nil
        }
        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            _ = close(fd)
            return nil
        }
        return fd
    }

    private static func configFileState(at path: String) -> ConfigFileState? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .missing : nil
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_mode & mode_t(0o022) == 0,
              info.st_size >= 0,
              UInt64(info.st_size) <= UInt64(maxConfigBytes),
              let data = FileManager.default.contents(atPath: path),
              data.count == Int(info.st_size) else { return nil }
        return .bytes(data)
    }

    static func load() -> KistConfig {
        let p = path()
        guard FileManager.default.fileExists(atPath: p) else { return KistConfig() }
        guard let data = FileManager.default.contents(atPath: p) else { return invalidPublicWebConfig() }
        return parseData(data)
    }

    static func parseData(_ data: Data) -> KistConfig {
        guard isValidConfigObjectData(data),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return invalidPublicWebConfig() }
        return parse(obj)
    }

    static func isValidConfigObjectData(_ data: Data) -> Bool {
        !containsTrailingComma(data)
            && ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil
    }

    /// Foundation accepts trailing commas on some platforms. Config is a security policy,
    /// so reject that non-JSON extension consistently before permissive platform decoding.
    private static func containsTrailingComma(_ data: Data) -> Bool {
        let bytes = Array(data)
        var inString = false
        var escaped = false
        for index in bytes.indices {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
                continue
            }
            if byte == 0x22 { inString = true; continue }
            guard byte == 0x7d || byte == 0x5d else { continue }
            var previous = index
            while previous > bytes.startIndex {
                previous -= 1
                if ![0x20, 0x09, 0x0a, 0x0d].contains(bytes[previous]) {
                    if bytes[previous] == 0x2c { return true }
                    break
                }
            }
        }
        return false
    }

    private static func invalidPublicWebConfig() -> KistConfig {
        KistConfig(fetchAllowedHosts: ["\0invalid-kist-config-json"])
    }

    /// Split from load() so parsing is testable without touching the real config path.
    static func parse(_ obj: [String: Any]) -> KistConfig {
        // Empty means intentionally unrestricted public hosts. Preserve a present wrong JSON
        // type as an invalid sentinel rather than collapsing it to empty/unrestricted.
        let fetchAllowedHosts: [String]
        if let raw = obj["fetchAllowedHosts"] {
            fetchAllowedHosts = raw as? [String] ?? ["\0invalid-fetchAllowedHosts-json-shape"]
        } else {
            fetchAllowedHosts = []
        }
        return KistConfig(provider: obj["provider"] as? String,
                   model: obj["model"] as? String,
                   autoRouting: obj["autoRouting"] as? Bool,
                   selectBy: (obj["selectBy"] as? String).flatMap(ProviderSelectionPolicy.init(loose:)),
                   fetchAllowedHosts: fetchAllowedHosts)
    }
}
