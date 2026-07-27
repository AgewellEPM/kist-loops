import Foundation

/// Custom slash-commands: reusable prompt templates in `.kist/commands/<name>.md` (project) or
/// `~/.config/kist/commands/<name>.md` (user). `$ARGUMENTS` in the template is replaced with the
/// invocation args. In the REPL, `/<name> [args]` expands the template and runs it as a turn.
/// (Claude Code's custom-command pattern.)
struct KistCommands {
    /// name -> template text. Project definitions override user ones.
    let templates: [String: String]

    static func load(projectRoot: String) -> KistCommands {
        var t: [String: String] = [:]
        let cfg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        // User dir first, then project — project wins on name collision.
        for dir in [cfg + "/kist/commands", projectRoot + "/.kist/commands"] {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".md") {
                let name = String(f.dropLast(3))
                if let body = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) {
                    t[name] = body
                }
            }
        }
        return KistCommands(templates: t)
    }

    /// Expand a command template with its args (nil if no such command).
    func expand(_ name: String, args: String) -> String? {
        guard let body = templates[name] else { return nil }
        return body.replacingOccurrences(of: "$ARGUMENTS", with: args)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var names: [String] { templates.keys.sorted() }
}
