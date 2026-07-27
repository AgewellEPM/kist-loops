import Foundation

/// A pure line-editor state machine for the TUI input box: buffer + cursor + history, driven by
/// decoded `TerminalKey`s. No I/O — it returns an `Outcome` the renderer acts on. This is the part
/// that has to be exactly right (cursor math, history browsing, word-delete), so it's fully unit-tested
/// in isolation from any terminal.
struct LineEditor {
    private(set) var buffer: [Character] = []
    private(set) var cursor: Int = 0
    private var history: [String] = []
    private var browse: Int? = nil      // index into history while browsing (nil = editing live line)
    private var stash: [Character] = []  // the live line, stashed while browsing history

    enum Outcome: Equatable {
        case redraw                 // visible state changed; re-render the input line
        case submit(String)         // user pressed Enter
        case interrupt              // Ctrl-C
        case eof                    // Ctrl-D on an empty line
        case paste                  // Ctrl-V — host should pull the clipboard
        case ignored                // nothing changed
    }

    var line: String { String(buffer) }

    mutating func handle(_ key: TerminalKey) -> Outcome {
        switch key {
        case .char(let c):
            buffer.insert(c, at: cursor); cursor += 1; return .redraw
        case .backspace:
            guard cursor > 0 else { return .ignored }
            buffer.remove(at: cursor - 1); cursor -= 1; return .redraw
        case .delete:
            guard cursor < buffer.count else { return .ignored }
            buffer.remove(at: cursor); return .redraw
        case .left:
            guard cursor > 0 else { return .ignored }
            cursor -= 1; return .redraw
        case .right:
            guard cursor < buffer.count else { return .ignored }
            cursor += 1; return .redraw
        case .home:
            guard cursor != 0 else { return .ignored }
            cursor = 0; return .redraw
        case .end:
            guard cursor != buffer.count else { return .ignored }
            cursor = buffer.count; return .redraw
        case .ctrlU:
            guard !buffer.isEmpty else { return .ignored }
            buffer.removeAll(); cursor = 0; return .redraw
        case .ctrlW:
            return deleteWordBack()
        case .up:
            return browseHistory(-1)
        case .down:
            return browseHistory(1)
        case .enter:
            let result = line
            if !result.trimmingCharacters(in: .whitespaces).isEmpty { history.append(result) }
            buffer.removeAll(); cursor = 0; browse = nil; stash = []
            return .submit(result)
        case .ctrlC:
            buffer.removeAll(); cursor = 0; browse = nil
            return .interrupt
        case .ctrlD:
            return buffer.isEmpty ? .eof : .ignored
        case .ctrlV:
            return .paste
        case .ctrlL, .tab, .backTab, .escape:
            return .ignored        // .tab/.backTab are intercepted by the reader before reaching here
        }
    }

    /// Insert text at the cursor (used by the host after a Ctrl-V clipboard read of plain text).
    mutating func insert(_ text: String) {
        for c in text { buffer.insert(c, at: cursor); cursor += 1 }
    }

    /// Replace a character range in the editable buffer and place the cursor after the inserted text.
    /// Used by tab completion. Bounds are clamped so a stale completion range cannot crash raw input.
    mutating func replace(range: Range<Int>, with text: String) {
        let lower = max(0, min(range.lowerBound, buffer.count))
        let upper = max(lower, min(range.upperBound, buffer.count))
        buffer.replaceSubrange(lower..<upper, with: Array(text))
        cursor = lower + text.count
        browse = nil
    }

    private mutating func deleteWordBack() -> Outcome {
        guard cursor > 0 else { return .ignored }
        var i = cursor
        while i > 0 && buffer[i - 1] == " " { i -= 1 }       // skip trailing spaces
        while i > 0 && buffer[i - 1] != " " { i -= 1 }       // delete the word
        buffer.removeSubrange(i..<cursor); cursor = i
        return .redraw
    }

    private mutating func browseHistory(_ direction: Int) -> Outcome {
        guard !history.isEmpty else { return .ignored }
        switch (browse, direction) {
        case (nil, -1):                              // enter history from the live line
            stash = buffer
            browse = history.count - 1
        case (let idx?, -1):                          // older
            guard idx > 0 else { return .ignored }
            browse = idx - 1
        case (let idx?, 1):                           // newer
            if idx + 1 < history.count { browse = idx + 1 }
            else { browse = nil; buffer = stash; cursor = buffer.count; return .redraw }  // back to live line
        default:
            return .ignored
        }
        if let idx = browse { buffer = Array(history[idx]); cursor = buffer.count }
        return .redraw
    }
}
