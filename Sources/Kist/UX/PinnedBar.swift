import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// R2b (2026-07-29): the always-visible input bar "glued to the bottom". A DECSTBM scroll region
/// pins the transcript to the top band; the input panel (status line + prompt box + hint) lives in
/// a fixed strip on the bottom `panelRows` rows and never scrolls away while a turn streams above it.
///
/// Design contract — SAFE FALLBACK: when the bar is disabled (not a TTY, `--no-pinned-bar`, a
/// terminal too short, or `TERM=dumb`), `panelLead`/`transcriptLead` return exactly what the old
/// inline REPL emitted ("\n" before the panel, "" before the turn), so the render path is
/// byte-identical to pre-R2b. The scroll region is the ONLY behavioral change, and it only exists
/// while `active`. All screen math is in the pure `PinnedBarLayout` so it is unit-tested without a
/// terminal; this class is the thin I/O + lifecycle shell.
final class PinnedBar {
    /// Rows reserved for the input panel, sized to the TALLEST panel: a 2-line status (active task
    /// board) + top border + input + bottom border + hint = 6. A 1-line status draws 5 and is
    /// bottom-anchored with one pad row (see `panelLead(statusRows:)`), so the box is always flush
    /// to the screen bottom. Reserving the max is what stops the box overflowing the region and
    /// corrupting the panel mid-plan (the exact state R2b exists to keep pinned).
    static let panelRows = 6
    /// Fixed rows the box occupies BELOW the status line: top border · input · bottom border · hint.
    static let boxRows = 4
    /// Below this many rows a pinned strip would starve the transcript — fall back to inline.
    static let minTerminalRows = 12

    private let enabled: Bool
    private let raw = RawMode()
    private(set) var active = false
    private(set) var suspended = false
    private var layout: PinnedBarLayout?

    /// `enabled` gates the whole feature; the initializer also refuses non-TTY / dumb terminals so a
    /// piped or CI run never emits scroll-region escapes into a log.
    init(enabled: Bool) {
        let isTTY = isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0
        let dumb = (ProcessInfo.processInfo.environment["TERM"] ?? "").lowercased() == "dumb"
        self.enabled = enabled && isTTY && !dumb
    }

    /// Pin the bar: set the scroll region and drop the cursor to the bottom of the band so the first
    /// panel renders at the bottom and subsequent transcript scrolls up from there (Claude-Code feel:
    /// box at the bottom, conversation filling in above). No-op when disabled or the terminal is too short.
    func activate() {
        guard enabled, !active else { return }
        let size = raw.size()
        guard size.rows >= Self.minTerminalRows else { return }
        let l = PinnedBarLayout(rows: size.rows, cols: size.cols, panelRows: Self.panelRows)
        layout = l
        write(l.activateSequence)
        active = true
        // A killed kist must not leave the shell with a frozen bottom strip: the RawMode signal
        // handler releases the region when this flag is set (async-signal-safe write).
        RawMode.scrollRegionActiveOnSignal = true
    }

    /// Release the region and restore a normal full-screen cursor. Idempotent; MUST run on every REPL
    /// exit path (wire via `defer`) or the user's shell is left with a stuck scroll region.
    func deactivate() {
        guard active, let l = layout else { return }
        RawMode.scrollRegionActiveOnSignal = false
        write(l.deactivateSequence)
        active = false
    }

    /// Drop the scroll region for the duration of a TURN. The pinned strip only earns its keep while
    /// idle at the prompt; during a turn a persistent DECSTBM region + a scroll-region-UNAWARE event
    /// sink dumping a plan/long output is where terminals (esp. Terminal.app) mis-scroll and blank the
    /// band. So on submit we reset the region and clear the old panel — turn output then flows in plain
    /// full-screen mode (byte-identical to the inline path that never had this bug). `resume()` re-pins
    /// at the next prompt. Type-ahead still shows in the live spinner tail, so nothing is lost.
    func suspend() {
        guard active, !suspended, let l = layout else { return }
        suspended = true
        RawMode.scrollRegionActiveOnSignal = false
        write(l.suspendSequence)
    }

    /// Re-pin after a turn (idempotent; no-op if never suspended). Restores the scroll region and parks
    /// the cursor at the band bottom so the next prompt renders in the pinned strip again.
    func resume() {
        guard active, suspended, let l = layout else { return }
        suspended = false
        RawMode.scrollRegionActiveOnSignal = true
        write(l.activateSequence)
    }

    /// Re-pin when the terminal was resized between prompts (polled — no async-signal-unsafe handler).
    /// A resize that shrinks the terminal below the floor tears the bar down to inline for safety.
    func refreshSizeIfNeeded() {
        guard active, let current = layout else { return }
        let size = raw.size()
        guard size.rows != current.rows || size.cols != current.cols else { return }
        guard size.rows >= Self.minTerminalRows else { deactivate(); return }
        let l = PinnedBarLayout(rows: size.rows, cols: size.cols, panelRows: Self.panelRows)
        // A GROW leaves the old panel stranded mid-band (emulators keep prior rows anchored) — wipe
        // from the higher of the two panel tops down before re-pinning so no ghost box lingers. The
        // transcript above that row is preserved; the next panelLead repaints the real panel.
        let clearFrom = min(current.panelTop, l.panelTop)
        write(TerminalANSI.moveTo(row: max(1, clearFrom), col: 1) + TerminalANSI.clearBelow)
        layout = l
        write(l.activateSequence)
    }

    /// Prefix emitted right before the status line + prompt box are drawn. `statusRows` is how many
    /// physical rows the status line will occupy (1, or 2 when a task board is active) so the box is
    /// bottom-anchored inside the reserved strip. Pinned: jump to the panel top, clear it, pad so the
    /// box sits flush to the bottom. Inline (fallback): a bare "\n", exactly as the pre-R2b loop wrote.
    func panelLead(statusRows: Int = 1) -> String {
        guard active, let l = layout else { return "\n" }
        let contentRows = min(Self.panelRows, max(1, statusRows) + Self.boxRows)
        let pad = max(0, l.panelRows - contentRows)
        return l.panelLeadSequence + String(repeating: "\n", count: pad)
    }

    /// Prefix emitted right before a turn's transcript output begins. Pinned: park the cursor on the
    /// last band row so streamed output scrolls the band (not the pinned panel). Inline: "" (no-op).
    func transcriptLead() -> String { active ? (layout?.transcriptLeadSequence ?? "") : "" }

    private func write(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
}

/// Pure screen arithmetic for the pinned bar (unit-tested; no I/O). The transcript band is rows
/// `[1, transcriptBottom]`; the input panel is the bottom `panelRows` rows. All sequences are plain
/// ANSI built from `TerminalANSI`.
struct PinnedBarLayout: Equatable {
    let rows: Int
    let cols: Int
    let panelRows: Int

    init(rows: Int, cols: Int, panelRows: Int) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        // Always keep at least one transcript row; clamp the panel so it can't eat the screen.
        self.panelRows = min(max(1, panelRows), max(1, self.rows - 1))
    }

    /// Last row of the scrolling transcript band (1-based).
    var transcriptBottom: Int { rows - panelRows }
    /// First row of the fixed input panel (1-based).
    var panelTop: Int { transcriptBottom + 1 }

    /// Set the transcript scroll region and park the cursor at the bottom of the band.
    var activateSequence: String {
        TerminalANSI.setScrollRegion(top: 1, bottom: max(1, transcriptBottom))
            + TerminalANSI.moveTo(row: transcriptBottom, col: 1)
    }

    /// Release the region, drop to the real last row, show the cursor, and newline off the panel.
    var deactivateSequence: String {
        TerminalANSI.resetScrollRegion
            + TerminalANSI.moveTo(row: rows, col: 1)
            + TerminalANSI.showCursor + "\r\n"
    }

    /// Jump to the panel strip and clear it (cursor-to-end-of-display erases the whole bottom panel,
    /// even though scrolling is confined to the band above).
    var panelLeadSequence: String {
        TerminalANSI.moveTo(row: panelTop, col: 1) + TerminalANSI.clearBelow
    }

    /// Park on the last band row so a turn's output scrolls the band, leaving the panel pinned.
    var transcriptLeadSequence: String {
        TerminalANSI.moveTo(row: transcriptBottom, col: 1)
    }

    /// Suspend for a turn: release the scroll region, drop to the panel row, and clear the old panel so
    /// the freed bottom rows are blank before turn output flows into full-screen scrolling from there.
    var suspendSequence: String {
        TerminalANSI.resetScrollRegion
            + TerminalANSI.moveTo(row: panelTop, col: 1)
            + TerminalANSI.clearBelow
    }
}
