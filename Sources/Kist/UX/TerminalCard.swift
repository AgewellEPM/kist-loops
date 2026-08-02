import Foundation

/// A bordered terminal card — the Codex `/status` / Claude `/usage` look: a rounded box with the title
/// carried in the top border and every row padded to the SAME visible cell width (emoji + ANSI aware
/// via TerminalCellText). The box math lives here once so `/version`, `/usage`, and future panels stay
/// square without each re-deriving border arithmetic.
enum TerminalCard {
    /// Accumulates padded rows; `build` frames them with the border. A class so section helpers can
    /// append without inout ceremony.
    final class Builder {
        let width: Int
        let inner: Int          // content cells between the "│ " and " │"
        let color: Bool
        private(set) var rows: [String] = []

        init(width: Int, color: Bool) {
            self.width = max(48, width)
            self.inner = self.width - 4
            self.color = color
        }

        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }

        /// One content row, padded (or clipped-safe) to the inner width.
        func row(_ content: String) {
            let w = TerminalCellText.width(content)
            let padded = w >= inner ? content : content + String(repeating: " ", count: inner - w)
            rows.append(c("2", "│ ") + padded + c("2", " │"))
        }
        func blank() { row("") }
        func heading(_ text: String, _ code: String = "95;1") { row(c(code, text)) }

        /// A dim, fixed-width key followed by its value (value assumed to fit one line).
        func kv(_ key: String, _ value: String, keyWidth: Int = 18) {
            let k = key.count >= keyWidth ? key : key + String(repeating: " ", count: keyWidth - key.count)
            row(c("2", k) + value)
        }

        /// A bulleted, WRAPPED block: colored glyph on line 0, continuations aligned under the text.
        func bullet(_ glyph: String, glyphCode: String, _ text: String, textCode: String = "37") {
            let lead = glyph + " "
            let leadCells = TerminalCellText.width(lead)
            let wrapped = Self.wrap(text, inner - leadCells)
            row(c(glyphCode, lead) + c(textCode, wrapped[0]))
            for cont in wrapped.dropFirst() {
                row(String(repeating: " ", count: leadCells) + c(textCode, cont))
            }
        }

        /// Cell-aware word wrap of PLAIN text (color is applied by the caller per line).
        static func wrap(_ text: String, _ w: Int) -> [String] {
            guard w > 4 else { return [text] }
            var out: [String] = []
            var cur = ""
            for word in text.split(separator: " ").map(String.init) {
                let cand = cur.isEmpty ? word : cur + " " + word
                if TerminalCellText.width(cand) <= w { cur = cand }
                else { if !cur.isEmpty { out.append(cur) }; cur = word }
            }
            if !cur.isEmpty { out.append(cur) }
            return out.isEmpty ? [""] : out
        }
    }

    /// Frame `body`'s rows with a titled rounded border. Leading + trailing newline, so it drops into
    /// a `print(...)` cleanly.
    static func build(title: String, titleCode: String = "96;1", color: Bool, width: Int = 76,
                      _ body: (Builder) -> Void) -> String {
        let W = max(48, width)
        let builder = Builder(width: W, color: color)
        body(builder)
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let titleCells = TerminalCellText.width(title)
        let dashes = max(0, W - 5 - titleCells)   // ╭ + "─ " + title + " " + dashes + ╮
        var out = "\n" + c("2", "╭─ ") + c(titleCode, title) + c("2", " " + String(repeating: "─", count: dashes) + "╮") + "\n"
        out += builder.rows.joined(separator: "\n") + "\n"
        out += c("2", "╰" + String(repeating: "─", count: W - 2) + "╯") + "\n"
        return out
    }
}
