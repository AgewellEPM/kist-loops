import Foundation
#if os(macOS)
import CoreGraphics
import ApplicationServices
#endif

/// L2 runtime guardrail (council-mandated 2026-07-03). The COMPLETE host-control boundary is process-identity
/// separation — computer-use belongs in a SEPARATELY-SIGNED binary that alone holds the Accessibility /
/// Screen-Recording TCC grants; the coding `kist` binary must never hold them (children inherit the
/// responsible-parent's grant, so a granted coding binary lets an agent drive the desktop via in-language
/// APIs — python `CGEventPost`, a compiled binary — which no deny-list can stop). That split is a product
/// change (see docs/kist/HOSTCONTROL_HARD_DENY_PLAN.md).
///
/// Until the split ships, this preflight DETECTS the dangerous state: an UNARMED coding run whose own process
/// already holds a host-control grant. It warns loudly (never silently), so the operator can revoke the grant
/// or move computer-use to a dedicated binary. It is a WARNING, not containment — honestly labelled as such.
public enum HostControlPreflight {

    /// Host-control TCC grants THIS process currently holds (macOS). Read-only, non-prompting.
    public static func heldGrants() -> [String] {
        #if os(macOS)
        var grants: [String] = []
        if AXIsProcessTrusted() { grants.append("Accessibility") }
        if CGPreflightScreenCaptureAccess() { grants.append("Screen Recording") }
        return grants
        #else
        return []
        #endif
    }

    /// Pure decision (injectable grants, so it's unit-testable): a warning iff computer-use is NOT armed but
    /// the process holds host-control grants. Armed runs, or a grant-less binary, produce nil.
    public static func warning(enableComputerUse: Bool, heldGrants: [String]) -> String? {
        guard !enableComputerUse, !heldGrants.isEmpty else { return nil }
        let held = heldGrants.joined(separator: " + ")
        return "⚠ SECURITY: this kist binary holds \(held) permission(s) but computer-use is NOT armed. "
            + "An agent could drive your desktop via in-language APIs (a child process inherits this grant), "
            + "which the shell/MCP host-control deny-list cannot stop. Revoke it in System Settings ▸ Privacy "
            + "& Security (or `tccutil reset Accessibility` / `tccutil reset ScreenCapture`), or run desktop "
            + "control from a dedicated binary. Pass --enable-computer-use only when you intend desktop control."
    }

    /// Live entry point: the warning for this process's actual grant state, or nil.
    public static func warningForCurrentProcess(enableComputerUse: Bool) -> String? {
        warning(enableComputerUse: enableComputerUse, heldGrants: heldGrants())
    }
}
