import Foundation
import AgentCore

/// `/context` — a glanceable breakdown of what's filling the model's context window right now: system
/// prompt, project memory, the conversation transcript (split by role), tool output, and loaded skills.
/// Token counts are ESTIMATES (~4 chars/token) — kist is provider-agnostic and can't call a specific
/// tokenizer, so this is a good-enough map to spot bloat, not an exact meter. Pure over its inputs so the
/// arithmetic is unit-tested; the REPL feeds it live session state.
enum ContextReport {

    struct Source: Equatable {
        let label: String
        let tokens: Int
        let items: Int      // messages / files contributing (0 ⇒ not shown as a count)
    }

    /// Rough token estimate: ~4 characters per token. Whitespace-heavy code skews low, prose high; close
    /// enough to rank sources and warn on capacity. Never negative.
    static func estimateTokens(_ text: String) -> Int { max(0, (text.count + 3) / 4) }

    /// Build the ordered source list from live state. `systemPrompt`/`memory` are optional; the transcript
    /// is split by role so a runaway tool-output or assistant history is visible on its own line.
    static func build(transcript: [ChatMessage],
                      memory: String?,
                      systemPrompt: String?,
                      skills: [String] = []) -> [Source] {
        var sources: [Source] = []
        if let sp = systemPrompt, !sp.isEmpty {
            sources.append(Source(label: "system prompt", tokens: estimateTokens(sp), items: 0))
        }
        if let mem = memory, !mem.isEmpty {
            sources.append(Source(label: "project memory", tokens: estimateTokens(mem), items: 0))
        }
        // Transcript grouped by role. Only roles actually present are shown.
        let byRole: [(ChatMessage.Role, String)] = [
            (.user, "conversation · you"),
            (.assistant, "conversation · assistant"),
            (.tool, "tool output"),
            (.system, "transcript system msgs"),
        ]
        for (role, label) in byRole {
            let msgs = transcript.filter { $0.role == role }
            guard !msgs.isEmpty else { continue }
            let tokens = msgs.reduce(0) { $0 + estimateTokens($1.content) }
            sources.append(Source(label: label, tokens: tokens, items: msgs.count))
        }
        if !skills.isEmpty {
            let tokens = skills.reduce(0) { $0 + estimateTokens($1) }
            sources.append(Source(label: "skills loaded", tokens: tokens, items: skills.count))
        }
        return sources
    }

    static func total(_ sources: [Source]) -> Int { sources.reduce(0) { $0 + $1.tokens } }

    /// Render the breakdown with a proportional bar per source and, when a model window is known, an
    /// overall usage line with a capacity warning. `windowTokens` nil ⇒ omit the percentage.
    static func render(sources: [Source], windowTokens: Int?, theme: Theme = .standard) -> String {
        func dim(_ s: String) -> String { theme.dim(s) }
        func accent(_ s: String) -> String { theme.accent(s) }
        let sum = total(sources)
        guard sum > 0 else { return accent("◱ context") + " " + dim("· empty (fresh session)") }

        var out = accent("◱ context") + " " + dim("· estimated tokens (~4 chars/token)") + "\n"
        let labelW = sources.map { $0.label.count }.max() ?? 12
        let maxTok = sources.map { $0.tokens }.max() ?? 1
        for s in sources.sorted(by: { $0.tokens > $1.tokens }) {
            let bars = maxTok > 0 ? Int((Double(s.tokens) / Double(maxTok) * 18).rounded()) : 0
            let bar = String(repeating: "█", count: max(0, bars)) + String(repeating: " ", count: 18 - max(0, bars))
            let padLabel = s.label.padding(toLength: labelW, withPad: " ", startingAt: 0)
            let count = s.items > 0 ? dim(" (\(s.items))") : ""
            out += "  \(padLabel)  \(accent(bar))  \(fmt(s.tokens)) tok\(count)\n"
        }
        out += "  " + String(repeating: "─", count: labelW + 30) + "\n"
        if let window = windowTokens, window > 0 {
            // Clamp before the Int conversion: an over-capacity ratio could otherwise trap on the cast.
            let pct = Int(min(9_999, max(0, (Double(sum) / Double(window) * 100).rounded())))
            let warn = pct >= 80 ? "  " + theme.error("⚠ near capacity — /compact to free room")
                     : pct >= 60 ? "  " + theme.warning("· getting full") : ""
            out += "  total  \(accent(fmt(sum))) / \(fmt(window)) tok  (\(pct)%)\(warn)"
        } else {
            out += "  total  \(accent(fmt(sum))) tok  " + dim("(set the model to show window usage)")
        }
        return out
    }

    /// Thousands-grouped integer for readability (12345 → "12,345").
    static func fmt(_ n: Int) -> String {
        let s = String(n); guard s.count > 3 else { return s }
        var out = ""; var c = 0
        for ch in s.reversed() { if c > 0 && c % 3 == 0 { out.append(",") }; out.append(ch); c += 1 }
        return String(out.reversed())
    }
}
