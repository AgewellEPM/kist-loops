import Foundation
import AgentCore

/// Turns a council run from a wall of prose into a legible primitive — findings #6 and #7. Shows each
/// mind's ONE-LINE opinion, then the decision and the next tasks, with the full board kept in the saved
/// artifact (the "proof drawer", #8). Pure + testable; the runner prints this and keeps the markdown on disk.
enum CouncilCard {

    static func render(_ result: CouncilRunResult, artifactPath: String?, color: Bool) -> String {
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let bar = c("35", "│ ")
        var out = c("35;1", "╭ Council") + c("2", " · " + gist(result.goal, max: 80)) + "\n"

        // Each mind: name · role → one-line opinion (skip the deterministic memory mind unless it has signal).
        for m in result.minds where !(m.role == "memory" && m.output.hasPrefix("No project memory")) {
            let who = TeamLanguage.displayName(m.binding?.providerId ?? m.name)
            let head = c("36", m.name) + c("2", " · " + m.role) + (m.failed ? c("31", " (failed)") : "")
            out += bar + head + c("2", "  — ") + gist(m.output) + "\n"
            _ = who
        }

        // Decision (the point of the whole thing).
        if let decision = section(result.finalPlan, heading: "Decision") {
            out += bar + "\n" + bar + c("32;1", "Decision: ") + gist(decision, max: 220) + "\n"
        }
        // Next tasks — the Ready rows of the kanban, capped at 5 (#6: "Next 5 Tasks").
        let tasks = readyTasks(result.finalPlan)
        if !tasks.isEmpty {
            out += bar + c("32", "Next tasks:") + "\n"
            for (i, t) in tasks.prefix(5).enumerated() { out += bar + "  \(i + 1). " + t + "\n" }
        }
        // Test plan if the board named one.
        if let tp = section(result.finalPlan, heading: "Test plan"), !tp.isEmpty {
            out += bar + c("32", "Test plan: ") + gist(tp, max: 200) + "\n"
        }
        if let artifactPath {
            out += c("35;1", "╰ ") + c("2", "full board saved · \(artifactPath) · /details for the wall of prose")
        } else {
            out += c("35;1", "╰")
        }
        return out
    }

    /// First meaningful line of a block: skip blanks, markdown headings/bullets markers, table pipes.
    static func gist(_ text: String, max: Int = 120) -> String {
        for raw in text.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            // SKIP heading lines, table rows, and fences entirely (don't return them as content).
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("|") || trimmed.hasPrefix("```") { continue }
            var line = trimmed
            while line.first == "-" || line.first == "*" || line.first == ">" {   // strip bullet markers only
                line.removeFirst(); line = line.trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty { continue }
            return line.count > max ? String(line.prefix(max - 1)) + "…" : line
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max).description
    }

    /// Extract the body of a `Heading:` section up to the next `Word:`-style heading or a markdown table.
    static func section(_ text: String, heading: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(heading.lowercased() + ":")
                || $0.trimmingCharacters(in: .whitespaces).lowercased() == heading.lowercased()
        }) else { return nil }
        // Same-line content after the colon counts.
        var body: [String] = []
        let firstLine = lines[start]
        if let colon = firstLine.firstIndex(of: ":") {
            let after = String(firstLine[firstLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !after.isEmpty { body.append(after) }
        }
        var i = start + 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            // stop at the next "Heading:" (a short capitalized label) or a table.
            if t.hasPrefix("|") { break }
            if let colon = t.firstIndex(of: ":"), t.distance(from: t.startIndex, to: colon) <= 24,
               !t.hasPrefix("-"), !t.hasPrefix("*"), t.prefix(upTo: colon).allSatisfy({ $0.isLetter || $0 == " " }) {
                break
            }
            if !t.isEmpty { body.append(t) }
            i += 1
        }
        let joined = body.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }

    /// Pull the Task column of kanban rows whose Status column is "Ready".
    static func readyTasks(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else { continue }
            let cols = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard cols.count >= 2, cols[0].lowercased() == "ready" else { continue }
            if cols[1].lowercased() == "task" || cols[1].contains("---") { continue }   // header/sep
            out.append(cols[1])
        }
        return out
    }
}
