import Foundation

/// `/chain` — a sequential task pipeline. You give kist an ordered list of tasks and it runs each one as
/// its own turn, in order, feeding the same conversation forward: `/chain "scaffold the parser" | "add
/// tests" | "wire it into main"`. Pure parsing here (string → ordered steps) so the exact splitting rules
/// are unit-tested without a terminal; the REPL runs each step through the normal armed turn helper.
enum ChainParser {
    /// Split a `/chain` argument string into ordered, non-empty task steps.
    ///
    /// - Primary separator is `|` (and newlines, so a pasted list works).
    /// - Quotes (single or double) protect a separator inside a task, and are stripped from the step:
    ///   `/chain "delete the | pipe char" | ship` → ["delete the | pipe char", "ship"].
    /// - Surrounding whitespace on each step is trimmed; empty steps are dropped.
    static func parse(_ raw: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character? = nil
        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }   // close quote / accumulate
            } else if ch == "\"" || ch == "'" {
                quote = ch                                                // open quote (char itself dropped)
            } else if ch == "|" || ch == "\n" {
                segments.append(current); current = ""                    // step boundary
            } else {
                current.append(ch)
            }
        }
        segments.append(current)
        return segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
