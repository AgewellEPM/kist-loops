import Foundation
import AgentCore

/// Owns the interactive permission tier (shift+tab bar) for the REPL: the current `PermissionMode`, the
/// project's sensitive/edit tool classification, and whether guards-off has been confirmed this session.
/// Keeps this logic out of the (already large) REPL and makes the cycle / arm / confirm rules testable.
///
/// SAFETY: cycling the indicator is free and instant (you can shuffle onto `bypass`), but `arm(_:)` only
/// drops approvals to guards-off AFTER `confirmBypass()` has been called — the REPL gates that behind a
/// typed y/N at the moment a turn is about to run in bypass. A stray keystroke can never arm guards-off.
struct PermissionController {
    private(set) var mode: PermissionMode
    private let sensitive: Set<String>
    private let edit: Set<String>
    /// Set once the user confirms guards-off this session. Cleared if they leave bypass.
    private(set) var bypassConfirmed = false

    init(mode: PermissionMode, sensitive: Set<String>, edit: Set<String>) {
        self.mode = mode
        self.sensitive = sensitive
        self.edit = edit
        self.bypassConfirmed = (mode == .bypass)   // launched with --yolo/--auto ⇒ already armed
    }

    /// shift+tab — advance the indicator (wraps). Leaving bypass disarms it, so re-entering re-confirms.
    mutating func cycle() {
        mode = mode.next()
        if mode != .bypass { bypassConfirmed = false }
    }

    /// Jump directly to a mode (e.g. the `/plan` command). Same disarm-on-leave-bypass rule.
    mutating func set(_ m: PermissionMode) {
        mode = m
        if mode != .bypass { bypassConfirmed = false }
    }

    /// The hint line under the prompt for the current mode. `includeInterrupt` is wired on once the
    /// esc-to-interrupt path exists, so the bar never advertises an unimplemented capability.
    func barHint(includeInterrupt: Bool) -> String {
        PromptBar.hint(mode: mode, includeInterrupt: includeInterrupt)
    }

    /// True when a turn is about to run in bypass but the user hasn't confirmed guards-off yet.
    var needsBypassConfirm: Bool { mode.armsGuardsOff && !bypassConfirmed }

    mutating func confirmBypass() { bypassConfirmed = true }

    /// User declined guards-off — fall back to the safe default for this turn and the indicator.
    mutating func declineBypass() { mode = .normal; bypassConfirmed = false }

    /// The EFFECTIVE tier right now, honoring the unconfirmed-bypass fail-safe: an indicator sitting on
    /// bypass that the user hasn't confirmed is treated as `.normal` (guards on). This is the single source
    /// of truth for "what approvals is the session actually enforcing" — used both by `arm` and by anything
    /// that must not read a looser floor than the session is really applying (e.g. capping a spawned agent).
    var effectiveMode: PermissionMode { (mode == .bypass && !bypassConfirmed) ? .normal : mode }
    /// The approval-tool set the session is actually enforcing (NOT the raw indicator — see `effectiveMode`).
    func effectiveApproval() -> Set<String> { effectiveMode.approvalTools(sensitive: sensitive, editTools: edit) }
    var effectivePlan: Bool { effectiveMode.isPlan }

    /// Apply the active tier to a held loop: plan mode on/off + the approval-tool set for the tier.
    /// If bypass isn't confirmed yet, we deliberately arm the NORMAL set (never guards-off) — the REPL
    /// is expected to run the confirm first; this is the fail-safe if it doesn't.
    func arm(_ loop: HeadlessAgentLoop) -> HeadlessAgentLoop {
        loop.planModeEnabled(effectiveMode.isPlan)
            .approving(effectiveMode.approvalTools(sensitive: sensitive, editTools: edit))
    }
}
