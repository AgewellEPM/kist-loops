import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Raw-mode prompt input for the standard REPL: history, tab completion, live lexical highlighting,
/// cursor movement, and paste. It is deliberately smaller than the full `--tui` surface: one prompt
/// line at a time, no alternate screen, and cooked `readLine` fallback for pipes/tests.
final class EnhancedPromptReader {
    enum Outcome: Equatable { case line(String), interrupt, eof }
    private enum InputChunk {
        case keys([TerminalKey])
        case paste(String)
    }

    private let raw = RawMode()
    private var editor = LineEditor()
    private let enabled: Bool
    private var lastSuggestionLine = false
    private var prevRenderRows = 1          // terminal rows the last (wrap-aware) input render occupied
    private var barHint: (() -> String)?    // Claude-Code-style hint line under the input (nil = none)
    private var commandNameSet: Set<String> = []   // known command names (no slash, lowercased) for glow + menu
    private var menuSel: Int? = nil         // slash-command browse cursor (nil = not browsing; ←/→ move it)

    init(enabled: Bool = EnhancedPromptReader.stdinIsTTY()) {
        self.enabled = enabled
    }

    /// - barHint: when set, a dim mode/shortcut line is drawn directly under the input (the permission bar).
    /// - onCycle: invoked on shift+tab to advance the permission mode; the bar redraws to reflect it.
    func readLine(prompt: String,
                  promptColumns: Int,
                  completionCandidates: () -> [String],
                  commandNames: [String] = [],
                  onPaste: () -> String? = { nil },
                  barHint: (() -> String)? = nil,
                  onCycle: (() -> Void)? = nil) -> Outcome {
        guard enabled else {
            FileHandle.standardOutput.write(Data(prompt.utf8))
            if let line = Swift.readLine(strippingNewline: true) { return .line(line) }
            return .eof
        }
        self.barHint = barHint
        self.commandNameSet = Set(commandNames.map {
            ($0.hasPrefix("/") ? String($0.dropFirst()) : $0).lowercased()
        })
        defer { self.barHint = nil; self.commandNameSet = []; self.menuSel = nil }

        raw.enable()
        write("\u{001B}[?2004h")       // bracketed paste: pasted paths arrive as one chunk, not keystroke spam
        defer {
            write("\u{001B}[?2004l")
            raw.disable()
        }
        render(prompt: prompt, promptColumns: promptColumns)
        var bracketedPasteBuffer: [UInt8]? = nil
        while true {
            let bytes = raw.readBytes(max: 4096)
            if bytes.isEmpty { return .eof }
            for chunk in Self.inputChunks(from: bytes, pasteBuffer: &bracketedPasteBuffer) {
                switch chunk {
                case .paste(let text):
                    editor.insert(Self.normalizePastedText(text))
                    render(prompt: prompt, promptColumns: promptColumns)
                case .keys(let keys):
                    for key in keys {
                        switch key {
                        case .tab:
                            handleCompletion(prompt: prompt, promptColumns: promptColumns, candidates: completionCandidates())
                        case .backTab:
                            onCycle?()
                            render(prompt: prompt, promptColumns: promptColumns)   // bar reflects the new mode
                        case .down where menuBrowsable():
                            // ↓ opens the slash-command browser (or steps forward if already open).
                            let n = slashMenuMatches().count
                            menuSel = menuSel.map { min($0 + 1, n - 1) } ?? 0
                            render(prompt: prompt, promptColumns: promptColumns)
                        case .left where menuSel != nil:
                            let n = slashMenuMatches().count
                            if n > 0 { menuSel = ((menuSel! - 1) % n + n) % n }     // ← wraps
                            render(prompt: prompt, promptColumns: promptColumns)
                        case .right where menuSel != nil:
                            let n = slashMenuMatches().count
                            if n > 0 { menuSel = (menuSel! + 1) % n }               // → wraps
                            render(prompt: prompt, promptColumns: promptColumns)
                        case .enter where menuSel != nil:
                            // ⏎ picks the highlighted command: fill the line so you can add args (or press
                            // Enter again to run it). Does NOT auto-submit.
                            let m = slashMenuMatches()
                            if let sel = menuSel, m.indices.contains(sel) {
                                editor.replace(range: 0..<editor.line.count, with: "/" + m[sel])
                            }
                            menuSel = nil
                            render(prompt: prompt, promptColumns: promptColumns)
                        case .up where menuSel != nil, .escape where menuSel != nil:
                            menuSel = nil                                            // exit browse → back to editing
                            render(prompt: prompt, promptColumns: promptColumns)
                        default:
                            menuSel = nil       // any other key (typing/backspace/cursor) leaves browse mode
                            switch editor.handle(key) {
                            case .redraw:
                                render(prompt: prompt, promptColumns: promptColumns)
                            case .submit(let line):
                                endInputArea()
                                return .line(line)
                            case .interrupt:
                                write("^C")
                                endInputArea()
                                return .interrupt
                            case .eof:
                                endInputArea()
                                return .eof
                            case .paste:
                                if let text = onPaste() {
                                    editor.insert(Self.normalizePastedText(text))
                                    render(prompt: prompt, promptColumns: promptColumns)
                                }
                            case .ignored:
                                break
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleCompletion(prompt: String, promptColumns: Int, candidates: [String]) {
        guard let edit = InputCompleter.edit(line: editor.line, cursor: editor.cursor, candidates: candidates) else {
            write("\u{0007}")   // bell: no completion
            return
        }
        if edit.completed {
            editor.replace(range: edit.range, with: edit.replacement)
            render(prompt: prompt, promptColumns: promptColumns)
            return
        }
        showSuggestions(edit.suggestions)
        render(prompt: prompt, promptColumns: promptColumns)
    }

    private func render(prompt: String, promptColumns: Int) {
        let highlighted = InputHighlighter.highlight(editor.line, commands: commandNameSet, color: true)
        if let barHint {
            let boxWidth = PromptBar.safeWidth(columns: TerminalMediaRenderer.terminalColumns(default: 80))
            // Typing a slash command replaces the permission hint with a live command menu (single line,
            // width-budgeted so it never wraps and breaks the box). Otherwise show the normal bar hint.
            let hint = slashMenuHint(width: boxWidth) ?? barHint()
            // The boxed prompt has fixed physical rows: input, bottom border, hint. If the input wraps, the
            // cursor math parks on the wrong row and every keypress stacks another copy of the input. Keep
            // the editable text horizontally windowed so the box never wraps in narrow terminals.
            let window = Self.boxedPromptWindow(line: editor.line, cursor: editor.cursor,
                                                promptColumns: promptColumns, width: boxWidth)
            let visibleInput = InputHighlighter.highlight(window.text, commands: commandNameSet, color: true)
            write(PromptBar.frame(promptAndInput: prompt + visibleInput,
                                  hint: hint,
                                  cursorCol: window.cursorCol,
                                  width: boxWidth))
        } else {
            // WRAP-SAFE redraw. `\r\u{001B}[2K` only clears ONE terminal row — a long input that wraps to
            // several rows left the stale wrapped rows on screen, redrawing the whole input each keystroke
            // and stacking it into a repeated-text mess. Clear EVERY row the previous render occupied, then
            // rewrite and reposition the cursor across the wrap.
            let width = max(1, TerminalMediaRenderer.terminalColumns(default: 80))
            let visible = promptColumns + editor.line.count            // display cells (ANSI-free)
            let rows = max(1, (max(0, visible - 1)) / width + 1)
            var out = ""
            if prevRenderRows > 1 { out += "\u{001B}[\(prevRenderRows - 1)A" }   // up to the first row
            out += "\r\u{001B}[J"                                                // col 0, clear to end of screen
            out += prompt + highlighted
            prevRenderRows = rows
            // Reposition the cursor: after writing, it sits at the end (last row). Move it to the row/col of
            // the logical cursor within the wrapped input.
            let target = promptColumns + editor.cursor
            let curRow = target / width, curCol = target % width
            let up = (rows - 1) - curRow
            if up > 0 { out += "\u{001B}[\(up)A" }
            out += "\r" + (curCol > 0 ? "\u{001B}[\(curCol + 1)G" : "")
            write(out)
        }
        lastSuggestionLine = false
    }

    struct BoxedPromptWindow: Equatable {
        let text: String
        let cursorCol: Int
    }

    static func boxedPromptWindow(line: String, cursor: Int,
                                  promptColumns: Int, width: Int) -> BoxedPromptWindow {
        let chars = Array(line)
        let safeCursor = max(0, min(cursor, chars.count))
        let promptWidth = max(0, promptColumns)
        // Leave one spare terminal cell so printing the last visible input character does not trigger
        // auto-wrap before PromptBar writes the next line.
        let visibleBudget = max(1, width - promptWidth - 2)
        let start = max(0, safeCursor - visibleBudget)
        let end = min(chars.count, start + visibleBudget)
        let text = start < end ? String(chars[start..<end]) : ""
        let visibleCursor = safeCursor - start
        return BoxedPromptWindow(text: text,
                                 cursorCol: max(1, promptWidth + visibleCursor + 1))
    }

    /// When the line is a slash-command being typed (starts with "/", no space yet), return a single-line
    /// menu of matching commands for the box's hint line: the exact match glows purple, candidates are
    /// cyan. Width-budgeted so it stays ONE row (the box cursor math assumes a single hint line). Returns
    /// nil when the line isn't a slash-command-in-progress ⇒ the normal permission hint shows instead.
    private func slashMenuHint(width: Int) -> String? {
        let line = editor.line
        guard line.hasPrefix("/"), !line.contains(" "), !commandNameSet.isEmpty else { return nil }
        return InputHighlighter.commandMenu(typed: String(line.dropFirst()).lowercased(),
                                            commands: commandNameSet, width: width, selected: menuSel)
    }

    /// The commands currently matching the slash-in-progress line (sorted) — the list ←/→ move through.
    private func slashMenuMatches() -> [String] {
        let line = editor.line
        guard line.hasPrefix("/"), !line.contains(" ") else { return [] }
        return InputHighlighter.commandMatches(typed: String(line.dropFirst()).lowercased(), commands: commandNameSet)
    }

    /// True when a slash menu is on screen with something to browse (so ↓ can open it).
    private func menuBrowsable() -> Bool { !slashMenuMatches().isEmpty }

    /// Leave the input line on submit/interrupt/eof. With the bar shown, also erase the hint line below
    /// so it doesn't linger between the committed prompt and the turn's output.
    private func endInputArea() {
        // With the box, the cursor is on the input line; the bottom border is one row below and the hint
        // two below. On submit we KEEP the closed box (input + bottom border — the record of what you
        // typed) and clear the transient hint line, leaving the cursor on a fresh row for the turn output.
        write(barHint != nil ? "\r\n\n\u{001B}[2K" : "\r\n")
        prevRenderRows = 1   // next prompt starts fresh
    }

    private func showSuggestions(_ suggestions: [String]) {
        let shown = suggestions.prefix(10).joined(separator: "  ")
        let suffix = suggestions.count > 10 ? "  ... +\(suggestions.count - 10)" : ""
        write("\r\n\u{001B}[37m\(shown)\(suffix)\u{001B}[0m\r\n")
        lastSuggestionLine = true
    }

    private func write(_ s: String) { FileHandle.standardOutput.write(Data(s.utf8)) }

    static func normalizePastedText(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = MediaResolver.tokenize(flattened)
        guard tokens.count >= 3 else { return flattened }

        var output: [String] = []
        var i = 0
        while i < tokens.count {
            if let repeated = repeatedBlock(tokens, startingAt: i) {
                output.append(contentsOf: repeated.block)
                i += repeated.length * repeated.count
            } else {
                output.append(tokens[i])
                i += 1
            }
        }
        return output.map(shellQuoteIfNeeded).joined(separator: " ")
    }

    private static func inputChunks(from bytes: [UInt8], pasteBuffer: inout [UInt8]?) -> [InputChunk] {
        let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] // ESC [ 200 ~
        let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC [ 201 ~
        var chunks: [InputChunk] = []
        var pending = bytes

        while !pending.isEmpty {
            if pasteBuffer != nil {
                if let end = range(of: pasteEnd, in: pending) {
                    pasteBuffer!.append(contentsOf: pending[..<end.lowerBound])
                    chunks.append(.paste(String(decoding: pasteBuffer!, as: UTF8.self)))
                    pasteBuffer = nil
                    pending = Array(pending[end.upperBound...])
                } else {
                    pasteBuffer!.append(contentsOf: pending)
                    pending.removeAll()
                }
                continue
            }

            guard let start = range(of: pasteStart, in: pending) else {
                chunks.append(.keys(KeyDecoder.decode(pending)))
                pending.removeAll()
                continue
            }

            if start.lowerBound > 0 {
                chunks.append(.keys(KeyDecoder.decode(Array(pending[..<start.lowerBound]))))
            }
            pasteBuffer = []
            pending = Array(pending[start.upperBound...])
        }

        return chunks
    }

    private static func repeatedBlock(_ tokens: [String], startingAt i: Int) -> (block: [String], length: Int, count: Int)? {
        let remaining = tokens.count - i
        guard remaining >= 3 else { return nil }
        let maxLength = min(16, remaining / 2)
        guard maxLength >= 1 else { return nil }

        for length in 1...maxLength {
            let block = Array(tokens[i..<i + length])
            guard isCollapsiblePasteBlock(block) else { continue }
            var count = 1
            while i + ((count + 1) * length) <= tokens.count {
                let next = Array(tokens[i + count * length..<i + (count + 1) * length])
                if next != block { break }
                count += 1
            }
            if count >= 3 { return (block, length, count) }
        }
        return nil
    }

    private static func isCollapsiblePasteBlock(_ block: [String]) -> Bool {
        block.contains { token in
            token.contains("/") || token.hasPrefix("@/") || token.hasPrefix("~") || token.count > 80
        }
    }

    private static func shellQuoteIfNeeded(_ token: String) -> String {
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else { return token }
        return "'" + token.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func range(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = 0
        while i <= haystack.count - needle.count {
            if Array(haystack[i..<i + needle.count]) == needle { return i..<i + needle.count }
            i += 1
        }
        return nil
    }

    private static func stdinIsTTY() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        return isatty(STDIN_FILENO) != 0
        #else
        return false
        #endif
    }
}
