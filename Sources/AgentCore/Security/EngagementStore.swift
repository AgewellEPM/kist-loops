import Foundation

/// Durable, on-disk home for SecurityEngagements. Authorization is EVIDENCE, not a prompt claim — it has
/// to outlive a session and be auditable. Engagements live as one JSON file per id under
/// `~/.kist/engagements/` (override via init for tests). Reads/writes are fail-soft on IO but fail-CLOSED
/// on trust: a file that won't decode is skipped (never silently treated as an empty/permissive scope),
/// and ids are sanitized to a safe filename component so an id can't traverse the filesystem.
public struct EngagementStore {
    public let root: String

    public init(root: String = EngagementStore.defaultRoot()) { self.root = root }

    public static func defaultRoot() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.kist")
        return base + "/engagements"
    }

    /// Persist (create or overwrite) an engagement. Atomic write so a crash mid-save can't leave a
    /// half-written authorization file that later decodes to a partial scope.
    @discardableResult
    public func save(_ engagement: SecurityEngagement) throws -> String {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(engagement)
        let path = filePath(engagement.id)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    /// Load one engagement by id. Returns nil if absent; THROWS if present-but-corrupt (a corrupt
    /// authorization file must surface loudly, never be swallowed into "no scope").
    public func load(id: String) throws -> SecurityEngagement? {
        let path = filePath(id)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(SecurityEngagement.self, from: data)
    }

    /// All engagements that decode cleanly, sorted by id. A file that fails to decode is SKIPPED (so one
    /// bad file doesn't hide every valid engagement) — but it is never coerced into a permissive default.
    public func list() -> [SecurityEngagement] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [SecurityEngagement] = []
        for name in names where name.hasSuffix(".json") {
            let path = root + "/" + name
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let e = try? JSONDecoder().decode(SecurityEngagement.self, from: data) else { continue }
            out.append(e)
        }
        return out.sorted { $0.id < $1.id }
    }

    /// Remove an engagement (revoke an authorization). No-op if absent.
    public func delete(id: String) throws {
        let path = filePath(id)
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }

    func filePath(_ id: String) -> String { root + "/" + EngagementStore.safe(id) + ".json" }

    /// id → safe filename component (no path traversal). Fail-closed: only ASCII letters/digits/`-`/`_`.
    static func safe(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(s.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}
