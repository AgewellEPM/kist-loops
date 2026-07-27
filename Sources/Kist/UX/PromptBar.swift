import Foundation

/// Renders Claude-Code's bottom hint bar: a dim line drawn directly under the prompt input showing the
/// current permission mode + the shortcuts that act on it. Pure (inputs → escape string) so the exact
/// wording, color, and cursor math are unit-tested without a terminal.
enum PromptBar {
    /// The hint text for a mode. `includeInterrupt` appends "· esc to interrupt" — only true once the
    /// turn-cancellation path is wired, so the bar never advertises a capability that doesn't work.
    ///
    /// - normal:      dim "shift+tab to cycle permissions" (no mode banner — nothing is elevated)
    /// - elevated:    "⏵⏵ accept edits on (shift+tab to cycle)" / "⏸ plan mode on …" / "⏵⏵ bypass permissions on …"
    static func hint(mode: PermissionMode, includeInterrupt: Bool, color: Bool = true) -> String {
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let interrupt = includeInterrupt ? c("2", " · esc to interrupt") : ""
        guard let banner = mode.bannerText else {
            return c("2", "shift+tab to cycle permissions") + interrupt
        }
        return c(mode.ansiColor, "\(mode.glyph) \(banner)") + c("2", " (shift+tab to cycle)") + interrupt
    }

    /// The Claude-Code rounded input box. The TOP border is drawn once (topBorder, above the input line);
    /// this redraws the three lines that change on each keystroke — the input line, the bottom border, and
    /// the hint — then parks the cursor back on the input line at the edit column.
    ///
    ///   \r ESC[2K │ <promptAndInput>    ── input line (cursor is here between renders)
    ///   \n ESC[2K ╰──────╯              ── bottom border
    ///   \n ESC[2K <hint>                ── hint line
    ///   ESC[2A ESC[<col>G              ── cursor up 2 to the input line, at the edit column
    static func frame(promptAndInput: String, hint: String, cursorCol: Int, width: Int = 60) -> String {
        let col = max(1, cursorCol)
        return "\r\u{001B}[J" + promptAndInput
            + "\n\u{001B}[2K" + bottomBorder(width: width)
            + "\n\u{001B}[2K" + hint
            + "\u{001B}[2A" + "\u{001B}[\(col)G"
    }

    /// Leave a small right margin so terminal width drift (for example a stale COLUMNS=80 in a 79-column
    /// window) cannot auto-wrap the box border or input line and corrupt the prompt area.
    static func safeWidth(columns: Int) -> Int {
        max(10, max(1, columns) - 2)
    }

    static func topBorder(width: Int = 60, color: Bool = true) -> String {
        border("╭", "╮", width: width, color: color)
    }
    static func bottomBorder(width: Int = 60, color: Bool = true) -> String {
        border("╰", "╯", width: width, color: color)
    }
    private static func border(_ l: String, _ r: String, width: Int, color: Bool) -> String {
        let inner = max(2, width - 2)
        let bar = l + String(repeating: "─", count: inner) + r
        return color ? "\u{001B}[2m\(bar)\u{001B}[0m" : bar
    }
}
