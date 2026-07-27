import Foundation
import AgentCore

/// Read-only inspector panels over the config kist ALREADY persists — the "surface what's on disk" half of
/// Claude-Code parity (`/skills`, `/mcp`, `/hooks`, `/permissions`). Each is a PURE render over its inputs
/// (the REPL loads the state and picks the theme) so the formatting is unit-tested without a terminal, and
/// each honors the active Theme (mono/high-contrast/daltonized stay consistent with the rest of the UI).
enum InspectorPanels {

    /// `/skills` — the discovered skills, with an estimated token cost (what each adds to context when loaded).
    static func skills(_ skills: [Skill], theme: Theme) -> String {
        guard !skills.isEmpty else {
            return theme.accent("✦ skills") + " " + theme.dim("· none (add SKILL.md under .kist/skills/)")
        }
        var out = theme.accent("✦ skills") + " " + theme.dim("· \(skills.count) available") + "\n"
        let w = skills.map { $0.name.count }.max() ?? 8
        for s in skills.sorted(by: { $0.name < $1.name }) {
            let tok = ContextReport.estimateTokens(s.instructions)
            let name = s.name.padding(toLength: w, withPad: " ", startingAt: 0)
            out += "  \(theme.accent(name))  \(theme.dim("~\(ContextReport.fmt(tok)) tok"))  \(oneLine(s.description))\n"
        }
        return out + theme.dim("  loaded on demand — a skill costs nothing until the agent reads it")
    }

    /// `/mcp` — configured MCP servers (what agents can reach), plus any rejected/invalid entries.
    static func mcp(servers: [MCPServerConfig], issues: [MCPConfigIssue], theme: Theme) -> String {
        var out = theme.accent("⚿ mcp servers") + " " + theme.dim("· \(servers.count) configured") + "\n"
        if servers.isEmpty { out += theme.dim("  none (add servers to .mcp.json / ~/.kist/mcp.json)\n") }
        let w = servers.map { $0.name.count }.max() ?? 8
        for s in servers.sorted(by: { $0.name < $1.name }) {
            let name = s.name.padding(toLength: w, withPad: " ", startingAt: 0)
            let cmd = ([s.command] + s.args).joined(separator: " ")
            out += "  \(theme.accent(name))  \(theme.dim(oneLine(cmd)))\n"
        }
        if !issues.isEmpty {
            out += theme.warning("  \(issues.count) rejected:") + "\n"
            for i in issues { out += "  " + theme.error("✗ \(i.server)") + " " + theme.dim(oneLine(i.reason)) + "\n" }
        }
        return String(out.dropLast())
    }

    /// `/hooks` — the lifecycle hooks configured in .kist/hooks.json (event → matcher → command).
    static func hooks(_ specs: [HookSpec], theme: Theme) -> String {
        guard !specs.isEmpty else {
            return theme.accent("⎇ hooks") + " " + theme.dim("· none (.kist/hooks.json)")
        }
        var out = theme.accent("⎇ hooks") + " " + theme.dim("· \(specs.count) configured") + "\n"
        for h in specs {
            let match = h.matcher.map { " " + theme.dim("[\($0)]") } ?? ""
            out += "  \(theme.accent(h.event.rawValue))\(match)  \(theme.dim("→ " + oneLine(h.command)))\n"
        }
        return String(out.dropLast())
    }

    /// `/permissions` — the current tier + exactly which tools still prompt for approval in it.
    static func permissions(mode: PermissionMode, sensitive: Set<String>, editTools: Set<String>, theme: Theme) -> String {
        let approvals = mode.approvalTools(sensitive: sensitive, editTools: editTools).sorted()
        var out = theme.accent("⛨ permissions") + " " + theme.dim("· tier: ") + theme.accent(mode.rawValue) + "\n"
        let banner: String
        switch mode {
        case .normal:      banner = "every sensitive tool prompts (shift+tab to change)"
        case .acceptEdits: banner = "file edits auto-approve; shell + others still prompt"
        case .plan:        banner = "read-only — the agent proposes, executes nothing"
        case .bypass:      banner = "GUARDS OFF — nothing prompts (armed via confirm)"
        }
        out += theme.dim("  \(banner)") + "\n"
        if approvals.isEmpty {
            out += theme.warning("  approval required for: (nothing — guards off)")
        } else {
            out += theme.dim("  still prompts for: ") + approvals.joined(separator: ", ")
        }
        let autoEdit = mode == .acceptEdits ? "\n" + theme.dim("  auto-approved edits: " + editTools.sorted().joined(separator: ", ")) : ""
        return out + autoEdit
    }

    /// Collapse a value to a single line (frontmatter/commands may be multi-word but never multi-line here).
    private static func oneLine(_ s: String, max: Int = 80) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}
