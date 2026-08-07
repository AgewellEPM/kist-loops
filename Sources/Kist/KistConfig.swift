import Foundation
import AgentCore

/// Optional defaults from `~/.config/kist/config.json` (XDG). Precedence: CLI flags > config >
/// built-in defaults. Keeps the common case ("always use my model") out of every invocation.
///
/// Example:
///   { "provider": "openai", "model": "gpt-5.5" }
struct KistConfig {
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
        let p = path()
        var obj: [String: Any] = (FileManager.default.contents(atPath: p)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        obj["selectBy"] = policy.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: p), options: .atomic)
            return true
        } catch { return false }
    }

    static func load() -> KistConfig {
        guard let data = FileManager.default.contents(atPath: path()),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return KistConfig() }
        return parse(obj)
    }

    /// Split from load() so parsing is testable without touching the real config path.
    static func parse(_ obj: [String: Any]) -> KistConfig {
        KistConfig(provider: obj["provider"] as? String,
                   model: obj["model"] as? String,
                   autoRouting: obj["autoRouting"] as? Bool,
                   selectBy: (obj["selectBy"] as? String).flatMap(ProviderSelectionPolicy.init(loose:)),
                   fetchAllowedHosts: obj["fetchAllowedHosts"] as? [String] ?? [])
    }
}
