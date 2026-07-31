import Foundation

/// The minimal, Claude-Code-style startup line shown under the animated KIST logo. No boxed
/// "operator panel" — just what model state you're in, where you are, and how to start.
enum StartupHeader {
    /// `mode` is "auto-routing" (kist picks per request) or a pinned model id.
    static func render(mode: String, projectRoot: String, planMode: Bool, color: Bool = true) -> String {
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let pin = mode == "auto-routing" ? "/model to pin" : "/model to change"
        let plan = planMode ? c("33", " · plan mode (read-only)") : ""
        // Version label so you always know which build is live (Luke 2026-07-31).
        return """
        \(c("36;1", "kist")) \(c("2", "·")) \(c("32", KistBuild.label)) \(c("2", "·")) \(c("35", mode)) \(c("2", "·")) \(c("2", abbreviate(projectRoot)))\(plan)
        \(c("2", "↳ just type · " + pin + " · /help"))
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
