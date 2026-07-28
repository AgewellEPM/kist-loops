import Foundation

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
    var fetchAllowedHosts: [String] = []

    static func path() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        return base + "/kist/config.json"
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
                   fetchAllowedHosts: obj["fetchAllowedHosts"] as? [String] ?? [])
    }
}
