import Foundation

/// Lightweight live input coloring for the terminal prompt. It is intentionally lexical, not a parser:
/// command/flag/path/code-keyword cues help the user see what they typed without changing semantics.
enum InputHighlighter {
    static let codeKeywords: Set<String> = [
        "func", "struct", "class", "enum", "protocol", "let", "var", "if", "else", "guard", "return",
        "import", "public", "private", "async", "await", "throws", "try", "for", "while",
        "function", "const", "interface", "type", "def", "class", "fn", "impl"
    ]

    /// - commands: known command names (without the leading "/", lowercased). When the line starts with a
    ///   slash, its FIRST token is colored by whether it will actually trigger an action:
    ///     • exact match  → glowing purple (bold magenta) — "this runs something"
    ///     • valid prefix → cyan — "keep typing, it's on its way to a command"
    ///     • no match     → dim — "this won't trigger anything"
    ///   Empty `commands` preserves the old behavior (any /token → cyan), so nothing regresses.
    static func highlight(_ line: String, commands: Set<String> = [], color: Bool = true) -> String {
        guard color, !line.isEmpty else { return line }
        if line.hasPrefix("/") {
            if let sp = line.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                return colorCommandToken(String(line[..<sp]), commands: commands)
                    + highlightBody(String(line[sp...]))
            }
            return colorCommandToken(line, commands: commands)
        }
        return highlightBody(line)
    }

    /// Color a leading slash-command token by whether it maps to a real action (see `highlight`).
    static func colorCommandToken(_ token: String, commands: Set<String>) -> String {
        if commands.isEmpty { return c("36;1", token) }   // no catalog wired → old cyan behavior
        let name = (token.hasPrefix("/") ? String(token.dropFirst()) : token).lowercased()
        if commands.contains(name) { return c("35;1", token) }                        // GLOW — triggers an action
        if !name.isEmpty, commands.contains(where: { $0.hasPrefix(name) }) {
            return c("36;1", token)                                                   // valid prefix — in progress
        }
        return c("2", token)                                                          // unknown — won't trigger
    }

    private static func highlightBody(_ line: String) -> String {
        guard !line.isEmpty else { return line }
        var out = ""
        var token = ""
        var inQuote = false
        var quoteChar: Character?

        func flush() {
            guard !token.isEmpty else { return }
            out += colorToken(token)
            token.removeAll(keepingCapacity: true)
        }

        for ch in line {
            if inQuote {
                token.append(ch)
                if ch == quoteChar {
                    out += c("32", token)
                    token.removeAll(keepingCapacity: true)
                    inQuote = false
                    quoteChar = nil
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                flush()
                inQuote = true
                quoteChar = ch
                token.append(ch)
                continue
            }
            if ch == " " || ch == "\t" {
                flush()
                out.append(ch)
            } else {
                token.append(ch)
            }
        }
        if inQuote {
            out += c("32", token)
        } else {
            flush()
        }
        return out
    }

    private static func colorToken(_ token: String) -> String {
        let lower = token.lowercased()
        if token.hasPrefix("/") { return c("36;1", token) }
        if token.hasPrefix("--") { return c("33", token) }
        if token.hasPrefix("-") { return c("33", token) }
        if token.hasPrefix("/") || token.hasPrefix("./") || token.hasPrefix("../") || token.contains("/") {
            return c("34", token)
        }
        if codeKeywords.contains(lower) { return c("35;1", token) }
        if lower == "true" || lower == "false" || Int(lower) != nil { return c("33", token) }
        return token
    }

    private static func c(_ code: String, _ s: String) -> String { "\u{001B}[\(code)m\(s)\u{001B}[0m" }

    /// The sorted command names matching `typed` (prefix). Shared by the menu renderer and the reader's
    /// browse-navigation so the index the arrow keys move through lines up with what's drawn.
    static func commandMatches(typed: String, commands: Set<String>) -> [String] {
        commands.filter { typed.isEmpty || $0.hasPrefix(typed) }.sorted()
    }

    /// The live slash-command menu shown on the box hint line while you type `/…`. Pure so the exact-match
    /// glow, the candidate list, the scrolling window and the width budget are unit-tested without a terminal.
    /// - typed: what's after the slash, lowercased ("" when the line is just "/").
    /// - commands: known command names (no slash, lowercased).
    /// - width: the box width; the menu is budgeted to stay a SINGLE line (the box assumes one hint row).
    /// - selected: when non-nil, the index (into the sorted matches) the user is BROWSING with ←/→. The
    ///   window scrolls to keep it visible, it's drawn reversed, and the hint shows position + ⏎. When nil,
    ///   the menu is static (first window + a "↓ browse" affordance).
    static func commandMenu(typed: String, commands: Set<String>, width: Int, selected: Int? = nil) -> String {
        let matches = commandMatches(typed: typed, commands: commands)
        guard !matches.isEmpty else { return c("2", "no command matches /\(typed)") }
        let budget = max(16, width - 16)          // leave room for the position / affordance indicator

        // Greedily pack matches (starting at `from`) into a single-line window within the width budget.
        func pack(from start: Int) -> [Int] {
            var w: [Int] = []; var used = 0; var i = start
            while i < matches.count {
                let cells = matches[i].count + 3   // "/" + name + 2-space separator
                if used + cells > budget, !w.isEmpty { break }
                w.append(i); used += cells; i += 1
            }
            return w
        }
        // Show a little context before the selection, but GUARANTEE the selected index is visible: if the
        // budget is too tight to include it from the context start, repack starting AT the selection.
        var window = pack(from: selected.map { max(0, $0 - 2) } ?? 0)
        if let sel = selected, !window.contains(sel) { window = pack(from: sel) }

        let shown = window.map { idx -> String in
            let label = "/" + matches[idx]
            if idx == selected { return c("7", label) }             // browsing cursor → reverse video
            if matches[idx] == typed { return c("35;1", label) }    // exact match → glow purple
            return c("36", label)                                   // candidate → cyan
        }

        let indicator: String
        if let sel = selected {
            indicator = "  " + c("2", "\(sel + 1)/\(matches.count) ←→  ⏎ pick")
        } else if matches.count > window.count {
            indicator = "  " + c("2", "+\(matches.count - window.count)  ↓ browse")
        } else {
            indicator = ""
        }
        return shown.joined(separator: "  ") + indicator
    }
}
