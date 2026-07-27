import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// CLOSES THE DROP-A-KEY/DROP-A-DOC LOOP: a durable, kist-owned record of a verified model's chat
/// template + stop sequences, keyed by (providerId, model). Onboarding WRITES it after a clean verify;
/// the agent loop READS it when building generation settings so a local model actually halts at its real
/// turn boundary. This is the "configure the runtime" half — the reader (`--inspect-model`) detects the
/// stops; this store makes the live loop USE them. Fail-soft: any I/O error degrades to "no profile"
/// (the loop falls back to provider/server-side stops), never a crash.
public struct LocalModelProfileStore: Sendable {

    public struct Entry: Codable, Sendable, Equatable {
        public var providerId: String
        public var model: String?
        public var family: String            // ChatTemplateFamily.rawValue
        public var stopSequences: [String]
        public var source: String            // where the template was read from
        public var verifiedReady: Bool        // did the loop probe pass when this was recorded?

        public init(providerId: String, model: String?, family: String, stopSequences: [String],
                    source: String, verifiedReady: Bool) {
            self.providerId = providerId; self.model = model; self.family = family
            self.stopSequences = stopSequences; self.source = source; self.verifiedReady = verifiedReady
        }
    }

    public let path: String
    public init(path: String) { self.path = path }

    /// User-global default: `~/.kist/model-profiles.json` (model profiles are user-wide, not per-project).
    public static func defaultPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".kist/model-profiles.json")
    }
    public static func `default`() -> LocalModelProfileStore { LocalModelProfileStore(path: defaultPath()) }

    private struct EntryKey: Codable {
        var providerId: String
        var model: String?
    }

    static func key(_ providerId: String, _ model: String?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = EntryKey(providerId: providerId, model: model)
        if let data = try? encoder.encode(payload) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(providerId.utf8.count):\(providerId):\(model.map { "\($0.utf8.count):\($0)" } ?? "nil")"
    }

    /// All stored profiles, keyed by an opaque, collision-free (providerId, model) key.
    /// Empty on any read/parse failure (fail-soft).
    public func all() -> [String: Entry] {
        withFileLock { readAllUnlocked() }
    }

    private func readAllUnlocked() -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: path),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        var map: [String: Entry] = [:]
        for e in entries { map[Self.key(e.providerId, e.model)] = e }
        return map
    }

    /// Stop sequences for (providerId, model): exact match first, then a provider-wide default entry.
    /// nil ⇒ no profile (caller uses provider/server-side stops).
    public func stops(providerId: String, model: String?) -> [String]? {
        withFileLock {
            let map = readAllUnlocked()
            if let exact = map[Self.key(providerId, model)], !exact.stopSequences.isEmpty { return exact.stopSequences }
            if let wide = map[Self.key(providerId, nil)], !wide.stopSequences.isEmpty { return wide.stopSequences }
            return nil
        }
    }

    /// Upsert a verified model's profile. Returns false (no throw) if persistence failed.
    @discardableResult
    public func record(providerId: String, model: String?, template: LocalModelTemplate,
                       verifiedReady: Bool) -> Bool {
        let entry = Entry(providerId: providerId, model: model, family: template.family.rawValue,
                          stopSequences: template.stopSequences, source: template.source,
                          verifiedReady: verifiedReady)
        return withFileLock {
            var map = readAllUnlocked()
            map[Self.key(providerId, model)] = entry
            return writeUnlocked(Array(map.values))
        }
    }

    private func writeUnlocked(_ entries: [Entry]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries.sorted { Self.key($0.providerId, $0.model) < Self.key($1.providerId, $1.model) }) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path), options: .atomic); return true }
        catch { return false }
    }

    private func withFileLock<T>(_ body: () -> T) -> T {
        #if canImport(Darwin) || canImport(Glibc)
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return body() }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)
        return body()
        #else
        return body()
        #endif
    }
}
