import Foundation
import AgentCore

/// `/config` (`/settings`) — kist's settings panel over `.kist/settings.json`. Bare `/config` renders the
/// current values; `/config key=value [key=value …]` sets them; `/config --help` lists the keys. All the
/// logic here is PURE (string → settings/status) so it's unit-tested without a terminal; the REPL owns the
/// disk save and the live hot-apply of the handful of keys that can change mid-session.
enum ConfigPanel {

    enum Intent: Equatable {
        case show
        case help
        case assign([Assignment])
    }
    struct Assignment: Equatable { let key: String; let value: String }

    /// Decide what a `/config` argument string means.
    static func classify(_ args: String) -> Intent {
        let a = args.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return .show }
        if a == "--help" || a == "-h" || a == "help" { return .help }
        return .assign(parseAssignments(a))
    }

    /// Parse `key=value` (or `key value`) pairs. Multiple pairs may be space-separated. A value itself may
    /// contain no spaces (settings values are single tokens: a model id, an enum, a bool) — good enough and
    /// unambiguous. Unparseable fragments are dropped (the REPL reports "nothing to set").
    static func parseAssignments(_ s: String) -> [Assignment] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { frag -> Assignment? in
            let piece = String(frag)
            guard let eq = piece.firstIndex(of: "=") else { return nil }
            let key = String(piece[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { return nil }
            return Assignment(key: key, value: value)
        }
    }

    /// Apply every assignment in order to `settings`, collecting human status lines and the keys that
    /// actually changed (so the REPL knows what to hot-apply). Pure.
    static func applyAll(_ settings: KistSettings, _ assignments: [Assignment], theme: Theme = .standard)
        -> (settings: KistSettings, lines: [String], changedKeys: [String]) {
        var current = settings
        var lines: [String] = []
        var changed: [String] = []
        for a in assignments {
            switch KistSettings.apply(current, key: a.key, value: a.value) {
            case let .updated(next, key, value):
                current = next
                changed.append(key)
                lines.append("\(theme.success("✓")) \(key) = \(value)")
            case let .unknownKey(k):
                lines.append("\(theme.error("✗")) unknown key '\(k)' — /config --help for the list")
            case let .invalidValue(key, value, allowed):
                lines.append("\(theme.error("✗")) \(key): '\(value)' invalid — allowed: \(allowed.joined(separator: ", "))")
            }
        }
        if assignments.isEmpty { lines.append("nothing to set — use key=value, e.g. /config theme=high-contrast") }
        return (current, lines, changed)
    }

    /// The panel: each settable key, its current value, and its allowed values. `scopeNote` describes where
    /// values are read from / written to.
    static func render(_ settings: KistSettings, scopeNote: String, theme: Theme = .standard) -> String {
        var out = theme.accent("⚙ settings") + " " + theme.dim("· \(scopeNote)") + "\n"
        let keyW = KistSettings.schema.map { $0.key.count }.max() ?? 10
        for entry in KistSettings.schema {
            let value = settings.displayValue(forKey: entry.key)
            let padKey = entry.key.padding(toLength: keyW, withPad: " ", startingAt: 0)
            let allowed = entry.values.map { " " + theme.dim("(" + $0.joined(separator: "|") + ")") } ?? " " + theme.dim("(any)")
            out += "  \(padKey)  \(theme.accent(value))\(allowed)\n"
        }
        out += theme.dim("  set with: /config <key>=<value>   ·   /config --help")
        return out
    }

    /// `/config --help` — the settable keys with their allowed values.
    static func help(theme: Theme = .standard) -> String {
        var out = theme.accent("settable keys:") + "\n"
        for entry in KistSettings.schema {
            let allowed = entry.values?.joined(separator: " | ") ?? "any value"
            out += "  \(entry.key.padding(toLength: 18, withPad: " ", startingAt: 0)) \(theme.dim(allowed))\n"
        }
        out += theme.dim("example: /config theme=high-contrast reasoning=on")
        return out
    }
}
