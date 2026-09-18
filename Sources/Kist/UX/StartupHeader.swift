import Foundation

/// The minimal, Claude-Code-style startup line shown under the animated KIST logo. No boxed
/// "operator panel" — just what model state you're in, where you are, and how to start.
enum StartupHeader {
    /// `mode` is "auto-routing" (kist picks per request) or a pinned model id.
    /// `science` = the science-loops profile (Luke 2026-09-18): identical layout, but the brand
    /// is the green `science` wordmark and the hint line teaches the science words (peel/lois)
    /// instead of leading with coding surfaces.
    static func render(mode: String, projectRoot: String, planMode: Bool, color: Bool = true,
                       science: Bool = false) -> String {
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let pin = mode == "auto-routing" ? "/model to pin" : "/model to change"
        let plan = planMode ? c("33", " · plan mode (read-only)") : ""
        let brand = science ? c("32;1", "science") : c("36;1", "kist")
        let hint = science
            ? "↳ just type · peel = science status · lois = arm the PEEL gate · " + pin + " · /help"
            : "↳ just type · " + pin + " · /help"
        // Product version is immutable source metadata; deployment identity lives in the
        // authenticated installed manifest rather than a self-rewriting source stamp.
        return """
        \(brand) \(c("2", "·")) \(c("32", KistBuildInfo.startupLabel)) \(c("2", "·")) \(c("35", mode)) \(c("2", "·")) \(c("2", abbreviate(projectRoot)))\(plan)
        \(c("2", hint))
        """
    }

    /// `/Users/lukekist/Downloads/mythos-stage2-mm` → `~/…/mythos-stage2-mm`. Tilde-collapses the
    /// home dir and elides middle segments, always keeping the leading anchor and the final component.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { p = "~/" + String(p.dropFirst(home.count + 1)) }
        let parts = p.split(separator: "/").map(String.init)
        guard let last = parts.last else { return p }
        let anchor = p.hasPrefix("~") ? "~" : (p.hasPrefix("/") ? "/" + (parts.first ?? "") : (parts.first ?? ""))
        if parts.count <= 1 { return p }                        // just an anchor or single segment
        if (p.hasPrefix("~") && parts.count <= 2) { return p }  // ~/<last> — already short
        return "\(anchor)/…/\(last)"
    }
}
