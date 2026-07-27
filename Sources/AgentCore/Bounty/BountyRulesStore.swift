import Foundation

/// Durable home for `BountyProgramRules`, keyed by program id — the rules companion to `EngagementStore`
/// (which holds the attested scope). One JSON file per id under `~/.kist/bounty-rules/`. Mirrors the
/// engagement store's discipline: atomic writes, path-safe ids, and fail-CLOSED on trust — a file that
/// won't decode is skipped in `list` and throws in `load`, never coerced into a permissive default.
public struct BountyRulesStore {
    public let root: String
    public init(root: String = BountyRulesStore.defaultRoot()) { self.root = root }

    public static func defaultRoot() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.kist")
        return base + "/bounty-rules"
    }

    @discardableResult
    public func save(id: String, rules: BountyProgramRules) throws -> String {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(rules)
        let path = filePath(id)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    public func load(id: String) throws -> BountyProgramRules? {
        let path = filePath(id)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BountyProgramRules.self, from: data)
    }

    public func delete(id: String) throws {
        let path = filePath(id)
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }

    func filePath(_ id: String) -> String { root + "/" + BountyRulesStore.safe(id) + ".json" }

    static func safe(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(s.map { allowed.contains($0) ? $0 : "-" })
        return cleaned.isEmpty ? "untitled" : cleaned
    }
}
