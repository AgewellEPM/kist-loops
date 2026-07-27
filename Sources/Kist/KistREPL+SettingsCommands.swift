import Foundation
import AgentCore

/// Handlers for the settings/inspector commands (`/config`, `/context`, `/theme`). Extracted from the
/// KistREPL switch so the dispatcher stays a thin router and the reusable logic lives in one place. Each
/// handler is a static function over its explicit inputs (projectRoot, transcript, args) — no run()-local
/// state — so it's testable in isolation and the REPL case body is 1–3 lines.
extension KistREPL {

    /// Result of `/config`: the text to print, plus any live hot-apply the REPL must perform (only
    /// `reasoning` can change mid-session cheaply; the rest are read by their subsystem).
    struct ConfigOutcome {
        let output: String
        let reasoning: Bool?   // non-nil ⇒ REPL should set showReasoning + rebuild the loop
    }

    /// `/config` (`/settings`): bare shows the panel, `key=value` sets + persists, `--help` lists keys.
    static func handleConfigCommand(_ args: String, projectRoot: String) -> ConfigOutcome {
        let store = KistSettingsStore(projectRoot: projectRoot)
        switch ConfigPanel.classify(args) {
        case .show:
            // Show the EFFECTIVE (merged user+project) values — that's what the session actually uses.
            let effective = store.load()
            let theme = Theme.resolve(effective.theme)
            let scope = ".kist/settings.json (project over ~/.kist)"
            return ConfigOutcome(output: ConfigPanel.render(effective, scopeNote: scope, theme: theme),
                                 reasoning: nil)
        case .help:
            return ConfigOutcome(output: ConfigPanel.help(theme: Theme.resolve(store.load().theme)), reasoning: nil)
        case .assign(let assignments):
            // Edit ONLY the project scope so writing one key can't flatten user-scope values into the
            // project file. Theme for the status glyphs is resolved from the EFFECTIVE settings.
            let theme = Theme.resolve(store.load().theme)
            var project = store.loadScope(.project)
            let result = ConfigPanel.applyAll(project, assignments, theme: theme)
            project = result.settings
            var lines = result.lines
            if !store.save(project, to: .project) {
                lines.insert(theme.error("✗ could not write .kist/settings.json"), at: 0)
            }
            let deferred = result.changedKeys.filter { ["model", "effort", "sandbox", "editor"].contains($0) }
            if !deferred.isEmpty {
                lines.append(theme.dim("  \(deferred.joined(separator: ", ")) apply next session (or /model, /think now)"))
            }
            let reasoning = result.changedKeys.contains("reasoning") ? project.reasoning : nil
            return ConfigOutcome(output: lines.joined(separator: "\n"), reasoning: reasoning)
        }
    }

    /// `/context` (`/ctx`): estimated window breakdown over memory + the transcript, in the active theme.
    static func handleContextCommand(transcript: [ChatMessage], projectRoot: String) -> String {
        let memory = ProjectMemory(root: projectRoot).planningContext()
        let sources = ContextReport.build(transcript: transcript, memory: memory, systemPrompt: nil)
        let theme = Theme.resolve(KistSettingsStore(projectRoot: projectRoot).load().theme)
        return ContextReport.render(sources: sources, windowTokens: nil, theme: theme)
    }

    /// `/theme`: bare lists palettes with swatches + marks the active one; `<name>` sets + persists + previews.
    static func handleThemeCommand(_ args: String, projectRoot: String) -> String {
        let store = KistSettingsStore(projectRoot: projectRoot)
        var settings = store.load()
        let arg = args.trimmingCharacters(in: .whitespaces)
        let current = Theme.resolve(settings.theme)
        guard !arg.isEmpty else {
            // Under mono (screen reader / NO_COLOR) list every palette WITHOUT color so the listing itself
            // stays escape-free — the swatch words still convey each palette's roles.
            let colorized = current.name != "mono"
            var out = "theme · \(current.name)\n"
            for t in Theme.all {
                let mark = t.name == current.name ? "●" : "○"
                out += "  \(mark) \(t.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(t.swatch(colorized: colorized))\n"
            }
            // Honor the ACTIVE theme's dim (mono/NO_COLOR ⇒ no escapes on this hint line either).
            out += current.dim("  set with: /theme <name>  ·  also /config theme=<name>")
            return out
        }
        switch KistSettings.apply(settings, key: "theme", value: arg) {
        case let .updated(next, _, value):
            settings = next
            _ = store.save(settings, to: .project)
            let t = Theme.resolve(value)
            return "theme · \(t.name)\n  \(t.swatch())"
        case let .invalidValue(_, value, allowed):
            return "unknown theme '\(value)' — try: \(allowed.joined(separator: ", "))"
        case .unknownKey:
            return "unknown theme"
        }
    }
}
