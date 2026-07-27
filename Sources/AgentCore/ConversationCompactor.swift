import Foundation

/// Summarizing context compaction for long autonomous runs — kist's answer to Claude Code's auto-compact.
///
/// The loop already TRIMS (drops the middle messages with a bare "[N omitted]" notice) at each provider
/// call so it stays within the context window. But dropping the middle means the agent LOSES what it did
/// and decided there — on a long task it then repeats work, re-reads files it already read, or forgets a
/// choice. This folds the middle band into ONE dense summary message instead of discarding it, so the
/// agent keeps a distilled memory of the whole run. It mutates the checkpoint's message history (compact
/// once, carry the summary forward); `ContextWindowManager.trim` remains the final hard safety net.
///
/// Pure over its inputs (the split + assembly + trigger) so it's unit-tested without a model; the summary
/// text itself comes from an injected async `summarize` closure (the loop supplies a cheap completion).
public struct ConversationCompactor: Sendable {
    /// Compact once the running history's character cost exceeds this.
    public let triggerCharacters: Int
    /// Verbatim head kept (the system framing + original task) — never summarized away.
    public let keepFirst: Int
    /// Verbatim tail kept (the recent steps the agent is actively working from).
    public let keepRecent: Int
    /// Don't bother compacting a middle smaller than this (not worth an LLM call).
    public let minMiddle: Int

    public init(triggerCharacters: Int = 48_000, keepFirst: Int = 2, keepRecent: Int = 8, minMiddle: Int = 6) {
        self.triggerCharacters = max(2_000, triggerCharacters)
        self.keepFirst = max(0, keepFirst)
        self.keepRecent = max(1, keepRecent)
        self.minMiddle = max(2, minMiddle)
    }

    public static let `default` = ConversationCompactor()

    /// How many messages sit in the compactible middle band.
    public func middleCount(_ messages: [ChatMessage]) -> Int {
        max(0, messages.count - keepFirst - keepRecent)
    }

    /// True when the history is both over the size trigger AND has enough middle to be worth folding.
    public func needsCompaction(_ messages: [ChatMessage]) -> Bool {
        totalCost(messages) > triggerCharacters && middleCount(messages) >= minMiddle
    }

    /// Fold the middle band into a single summary message. Returns the new history + how many messages
    /// were folded (0 ⇒ unchanged). If `summarize` yields nil/empty (model error, cancel), falls back to a
    /// factual "[N compacted]" notice — so the history still SHRINKS safely, never worse than the old trim.
    public func compact(_ messages: [ChatMessage],
                        summarize: ([ChatMessage]) async -> String?) async -> (messages: [ChatMessage], omitted: Int) {
        guard needsCompaction(messages) else { return (messages, 0) }
        let prefix = Array(messages.prefix(keepFirst))
        let recent = Array(messages.suffix(keepRecent))
        let middle = Array(messages.dropFirst(keepFirst).dropLast(keepRecent))
        guard middle.count >= minMiddle else { return (messages, 0) }

        let summary = await summarize(middle)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note: ChatMessage
        if let s = summary, !s.isEmpty {
            note = ChatMessage(role: .user, content:
                "[COMPACTED CONTEXT — a summary of \(middle.count) earlier steps. This is the record of what was already done and decided; if it conflicts with the CURRENT files or tool output, the live files/tools are the source of truth.]\n\(s)")
        } else {
            note = ChatMessage(role: .user, content:
                "[\(middle.count) earlier steps were compacted out of context to stay within the window. Use the current files/tools as the source of truth.]")
        }
        return (prefix + [note] + recent, middle.count)
    }

    // MARK: cost model — mirrors ContextWindowManager so the two agree on "how big is this history".
    func totalCost(_ messages: [ChatMessage]) -> Int { messages.reduce(0) { $0 + cost($1) } }
    private func cost(_ m: ChatMessage) -> Int {
        var n = m.content.count
        n += m.toolCalls?.reduce(0) { $0 + $1.name.count + $1.argumentsJSON.count + $1.id.count } ?? 0
        n += m.toolCallId?.count ?? 0
        if m.imageData != nil { n += 2_000 }
        return n + 32
    }
}
