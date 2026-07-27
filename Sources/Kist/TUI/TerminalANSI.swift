import Foundation

/// Pure ANSI escape-sequence builders for the raw-mode TUI. Kept dependency-free and side-effect-free
/// so the screen math is unit-testable: a scroll region pins the transcript to the top rows while a
/// fixed input box lives on the bottom rows, and the terminal keeps its own scrollback (unlike the
/// alternate screen). See TerminalUI for how these compose.
enum TerminalANSI {
    static let esc = "\u{001B}"

    /// Limit scrolling to rows [top, bottom] (1-based, inclusive) — DECSTBM. Output printed while the
    /// cursor sits in this band scrolls only the band, leaving the input box below untouched.
    static func setScrollRegion(top: Int, bottom: Int) -> String { "\(esc)[\(top);\(bottom)r" }
    /// Release the scroll region (whole screen scrolls again). Always emit on teardown.
    static let resetScrollRegion = "\(esc)[r"

    static func moveTo(row: Int, col: Int) -> String { "\(esc)[\(row);\(col)H" }
    static let saveCursor = "\(esc)7"            // DECSC — save cursor + attrs
    static let restoreCursor = "\(esc)8"         // DECRC
    static let clearLine = "\(esc)[2K"           // erase entire current line
    static let clearBelow = "\(esc)[0J"          // erase from cursor to end of screen
    static let hideCursor = "\(esc)[?25l"
    static let showCursor = "\(esc)[?25h"
    static let cr = "\r"

    static func color(_ code: String, _ s: String) -> String { "\(esc)[\(code)m\(s)\(esc)[0m" }
}

/// The two-region layout: a scrolling transcript band on top, a fixed input box of `inputRows` on the
/// bottom. Pure arithmetic so the boundaries are unit-tested rather than discovered at runtime.
struct ScreenLayout: Equatable {
    let rows: Int
    let cols: Int
    let inputRows: Int

    init(rows: Int, cols: Int, inputRows: Int = 2) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        // Always leave at least one transcript row; clamp the input box so it can't eat the screen.
        self.inputRows = min(max(1, inputRows), max(1, self.rows - 1))
    }

    /// Last row of the scrolling transcript band (1-based).
    var transcriptBottom: Int { rows - inputRows }
    /// First row of the fixed input box (1-based).
    var inputTop: Int { transcriptBottom + 1 }
    /// The DECSTBM region string for the transcript band.
    var scrollRegion: String { TerminalANSI.setScrollRegion(top: 1, bottom: max(1, transcriptBottom)) }
}
