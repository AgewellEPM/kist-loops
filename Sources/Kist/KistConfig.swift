import Foundation

/// Optional defaults from `~/.config/kist/config.json` (XDG). Precedence: CLI flags > config >
/// built-in defaults. Keeps the common case ("always use my model") out of every invocation.
///
/// Example:
///   { "provider": "openai", "model": "gpt-5.5" }
struct KistConfig {
    var provider: String?
    var model: String?
    var fetchAllowedHosts: [String] = []

    static func path() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        return base + "/kist/config.json"
    }

    static func load() -> KistConfig {
        guard let data = FileManager.default.contents(atPath: path()),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return KistConfig() }
        return KistConfig(provider: obj["provider"] as? String,
                          model: obj["model"] as? String,
                          fetchAllowedHosts: obj["fetchAllowedHosts"] as? [String] ?? [])
    }
}
