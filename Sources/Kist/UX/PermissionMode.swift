import Foundation

/// The interactive permission tier, cycled with shift+tab exactly like Claude Code's bottom bar.
/// A pure value that maps a human-facing mode to the loop's approval configuration; the REPL applies
/// it to the live `HeadlessAgentLoop` before each turn. Kept here (not in the REPL) so the cycle order,
/// the tier→approval mapping, and the bar text are all unit-testable without a terminal.
///
/// kist's real capability ladder (mirrors Claude Code normal → accept-edits → plan → bypass):
///   • normal      — prompt before every state-mutating / code-running tool (the default)
///   • acceptEdits — auto-approve file writes/edits; still prompt for shell + other dangerous tools
///   • plan        — read-only: the agent proposes a plan, executes nothing
///   • bypass      — GUARDS OFF: skip ALL approval prompts (== `--yolo`). Arming requires a confirm.
enum PermissionMode: String, CaseIterable, Equatable {
    case normal, acceptEdits, plan, bypass

    /// shift+tab order — repeated presses shuffle through these and wrap back to the start.
    static let cycle: [PermissionMode] = [.normal, .acceptEdits, .plan, .bypass]

    /// The next tier under shift+tab (wraps). Cycling is free + instant; arming `.bypass` is what the
    /// REPL gates behind a confirm — moving the indicator never arms guards-off by itself.
    func next() -> PermissionMode {
        let order = Self.cycle
        let i = order.firstIndex(of: self) ?? 0
        return order[(i + 1) % order.count]
    }

    var isPlan: Bool { self == .plan }

    /// True only for the guards-off tier — the REPL confirms before it actually takes effect.
    var armsGuardsOff: Bool { self == .bypass }

    /// Map a Claude subagent `permissionMode` frontmatter value onto kist's tier ladder. kist has four
    /// tiers; Claude has six, so two collapse: `auto` (classifier auto-approve) → `acceptEdits` (kist's
    /// nearest auto-approve tier), and `dontAsk` → `bypass` (skip prompts). Unknown/absent ⇒ nil so the
    /// caller keeps the session default rather than guessing. Whitespace/case tolerant.
    static func fromClaudeFrontmatter(_ raw: String) -> PermissionMode? {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "default":          return .normal
        case "acceptedits":      return .acceptEdits
        case "plan":             return .plan
        case "bypasspermissions": return .bypass
        case "dontask":          return .bypass       // don't ask ⇒ guards off
        case "auto":             return .acceptEdits   // classifier auto-approve ⇒ nearest kist tier
        default:                 return nil
        }
    }

    /// The set of tools that still require a human y/n in this tier, derived from the project's
    /// sensitive-tool baseline. `editTools` is the file-mutation subset auto-approved at `.acceptEdits`.
    /// - normal: every sensitive tool prompts.
    /// - acceptEdits: file edits auto-approve; the rest (shell, browse, computer_control…) still prompt.
    /// - plan: read-only is enforced by plan mode itself; keep the full prompt set as defense-in-depth.
    /// - bypass: nothing prompts.
    func approvalTools(sensitive: Set<String>, editTools: Set<String>) -> Set<String> {
        switch self {
        case .normal:      return sensitive
        case .acceptEdits: return sensitive.subtracting(editTools)
        case .plan:        return sensitive
        case .bypass:      return []
        }
    }

    // MARK: Bar rendering (Claude-Code-style bottom hint line)

    /// The mode banner shown in the bar, or nil for `.normal` (which shows only the shortcut hint).
    /// Matches Claude Code's wording: "accept edits on", "plan mode on", "bypass permissions on".
    var bannerText: String? {
        switch self {
        case .normal:      return nil
        case .acceptEdits: return "accept edits on"
        case .plan:        return "plan mode on"
        case .bypass:      return "bypass permissions on"
        }
    }

    /// The leading glyph Claude Code uses: ⏵⏵ for the permissive tiers, ⏸ for plan.
    var glyph: String { self == .plan ? "⏸" : "⏵⏵" }

    /// SGR color code for the banner — orange/yellow for accept-edits & plan, bold red for guards-off.
    var ansiColor: String {
        switch self {
        case .normal:      return "2"      // dim (only the shortcut hint shows)
        case .acceptEdits: return "33"     // yellow
        case .plan:        return "36"     // cyan
        case .bypass:      return "31;1"   // bold red — guards off, unmissable
        }
    }
}
