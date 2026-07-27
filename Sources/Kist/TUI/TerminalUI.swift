import Foundation

/// The raw-mode terminal surface: a scrolling transcript band on top, a pinned input box on the
/// bottom. It composes the tested pieces (RawMode, ScreenLayout, KeyDecoder, LineEditor) into the
/// Claude-Code feel — a persistent input box, single-keypress approvals, line history, and agent
/// output that streams into the band above without disturbing what you're typing.
///
/// PROTOTYPE: turn-based (you type, it runs, output streams in, you get the box back). It does NOT
/// yet accept typing WHILE the agent streams — that concurrency is the remaining Phase-4 work. The
/// surface restores the terminal on every exit path (teardown, deinit, signal) so a crash can't leave
/// a broken shell.
final class TerminalUI {
    private let raw = RawMode()
    private var layout: ScreenLayout
    private var editor = LineEditor()
    private var promptPlain: String
    private var active = false
    private var barHint: (() -> String)?    // Claude-Code permission bar under the input (nil = none)

    init(promptPlain: String = "you ❯ ") {
        self.promptPlain = promptPlain
        let size = RawMode().size()
        self.layout = ScreenLayout(rows: size.rows, cols: size.cols, inputRows: Self.inputRows(barShown: false))
    }

    /// Enable the permission bar: reserves a row under the input for the mode/shortcut hint. Call BEFORE
    /// setup() so the layout reserves the row. `hint` is re-evaluated on every render (reflects the mode).
    func setBar(_ hint: @escaping () -> String) { barHint = hint }

    private static func inputRows(barShown: Bool) -> Int { barShown ? 3 : 2 }   // rule + input (+ bar)

    // MARK: lifecycle

    func setup() {
        guard !active else { return }
        let size = raw.size()
        layout = ScreenLayout(rows: size.rows, cols: size.cols, inputRows: Self.inputRows(barShown: barHint != nil))
        raw.enable()
        write(layout.scrollRegion)                              // pin the transcript band
        write(TerminalANSI.moveTo(row: layout.transcriptBottom, col: 1))
        active = true
        renderInput()
    }

    func teardown() {
        guard active else { return }
        write(TerminalANSI.resetScrollRegion)
        write(TerminalANSI.moveTo(row: layout.rows, col: 1))
        write(TerminalANSI.showCursor + "\r\n")
        raw.disable()
        active = false
    }

    deinit { teardown() }

    // MARK: transcript (agent output streams here)

    /// Append raw text into the scrolling band. Streaming-safe: many small calls just keep writing at
    /// the band's cursor, scrolling only the band (the input box below is outside the scroll region).
    func appendTranscript(_ s: String) {
        guard active else { FileHandle.standardOutput.write(Data(s.utf8)); return }
        write(s)
    }

    /// Park the cursor at the bottom of the band so a turn's output streams there (scrolling only the
    /// band). Call right before running an agent turn.
    func beginTurn() {
        guard active else { return }
        write(TerminalANSI.moveTo(row: layout.transcriptBottom, col: 1) + TerminalANSI.clearLine)
    }

    /// Finish a transcript block and re-pin the input box (call when the agent turn ends).
    func endTranscriptBlock() {
        guard active else { return }
        write("\r\n")
        renderInput()
    }

    // MARK: input

    enum Outcome: Equatable { case line(String), interrupt, eof }

    /// Read one line interactively, rendering edits live. Blocks (reads stdin) until the user submits,
    /// interrupts (Ctrl-C), or sends EOF (Ctrl-D on empty). `onPaste` supplies clipboard text for Ctrl-V.
    func readLine(onPaste: () -> String? = { nil }, onCycle: (() -> Void)? = nil) -> Outcome {
        guard active else {       // not a TTY / not set up — fall back to cooked readLine
            if let l = Swift.readLine(strippingNewline: true) { return .line(l) }
            return .eof
        }
        renderInput()
        while true {
            let bytes = raw.readBytes()
            if bytes.isEmpty { return .eof }
            for key in KeyDecoder.decode(bytes) {
                if key == .backTab {                    // shift+tab: cycle the permission mode, redraw the bar
                    onCycle?(); renderInput(); continue
                }
                switch editor.handle(key) {
                case .redraw: renderInput()
                case .submit(let s): write("\r\n"); return .line(s)
                case .interrupt: write("\r\n"); return .interrupt
                case .eof: return .eof
                case .paste:
                    if let text = onPaste() { editor.insert(text.replacingOccurrences(of: "\n", with: " ")); renderInput() }
                case .ignored: break
                }
            }
        }
    }

    enum Approval: Equatable { case yes, no, all }

    /// Single-keypress approval inside the band: Enter/y = run, n = skip, a = allow all. No line typing.
    func readApproval(summary: String) -> Approval {
        let detail = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        appendTranscript("\r\n" + TerminalANSI.color("33;1", "  ⚠ permission needed") + "\r\n")
        appendTranscript(TerminalANSI.color("2", "  └ ") + detail + "\r\n")
        appendTranscript("  " + TerminalANSI.color("32;1", "[Enter] run") + "  "
                         + TerminalANSI.color("31", "[n] skip") + "  "
                         + TerminalANSI.color("36", "[a] allow all") + "  ")
        guard active else { return .no }
        while true {
            for key in KeyDecoder.decode(raw.readBytes()) {
                switch key {
                case .enter, .char("y"), .char("Y"): appendTranscript("\r\n"); return .yes
                case .char("a"), .char("A"): appendTranscript("\r\n"); return .all
                case .char("n"), .char("N"), .ctrlC: appendTranscript("\r\n"); return .no
                default: break
                }
            }
        }
    }

    // MARK: rendering

    /// Draw the input box: a dim rule + the prompt + the current buffer, cursor at the edit position.
    private func renderInput() {
        guard active else { return }
        let ruleRow = layout.inputTop
        let inputRow = layout.inputTop + (layout.inputRows > 1 ? 1 : 0)
        var out = TerminalANSI.moveTo(row: ruleRow, col: 1) + TerminalANSI.clearLine
        out += TerminalANSI.color("2", String(repeating: "─", count: max(1, min(layout.cols, 60))))
        out += TerminalANSI.moveTo(row: inputRow, col: 1) + TerminalANSI.clearLine
        out += TerminalANSI.color("36;1", promptPlain) + editor.line
        // The permission bar (mode + shortcuts) on the reserved row below the input — ONLY when the
        // layout actually allocated that row (short terminals clamp inputRows, so guard against drawing
        // off-screen or into the scroll region; Codex MED).
        if let barHint, inputRow + 1 <= layout.rows, layout.inputRows >= 3 {
            out += TerminalANSI.moveTo(row: inputRow + 1, col: 1) + TerminalANSI.clearLine + barHint()
        }
        // Place the cursor at the edit column (prompt width + cursor offset) and leave it in the box.
        let col = displayWidth(promptPlain) + editor.cursor + 1
        out += TerminalANSI.moveTo(row: inputRow, col: min(col, layout.cols))
        write(out)
    }

    func setPrompt(_ plain: String) { promptPlain = plain; renderInput() }

    private func displayWidth(_ s: String) -> Int { s.count }
    private func write(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }
}
