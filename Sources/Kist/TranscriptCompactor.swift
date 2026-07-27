import Foundation
import AgentCore

/// `/compact` — free context by summarizing the older part of the conversation while keeping the most
/// recent turns verbatim. kist is provider-agnostic, so compaction is a normal model call (the session
/// model summarizes) wired through a seam; everything HERE is pure (planning the split, building the
/// summarization prompt, folding the result back) so the behavior is unit-tested without a model or a
/// terminal. The REPL owns the model call and swaps the transcript.
enum TranscriptCompactor {

    /// Split the transcript into the part to summarize (older) and the part to keep verbatim (the last
    /// `keepRecent` messages). Keeping recent turns intact preserves the working thread while the long tail
    /// collapses. If there's nothing meaningful to summarize, `summarize` is empty and the caller no-ops.
    static func plan(_ transcript: [ChatMessage], keepRecent: Int)
        -> (summarize: [ChatMessage], keep: [ChatMessage]) {
        let keep = max(0, keepRecent)
        guard transcript.count > keep else { return ([], transcript) }
        let cut = transcript.count - keep
        return (Array(transcript[..<cut]), Array(transcript[cut...]))
    }

    /// Whether compaction is worth doing: there must be enough older messages that summarizing them
    /// actually frees room. `minToSummarize` guards against compacting a tiny conversation.
    static func worthCompacting(_ transcript: [ChatMessage], keepRecent: Int, minToSummarize: Int = 4) -> Bool {
        plan(transcript, keepRecent: keepRecent).summarize.count >= minToSummarize
    }

    /// Build the user prompt handed to the summarizer: the older messages rendered as a labeled log, plus
    /// optional focus instructions. Bounded so a giant history can't blow the summarizer's own context.
    static func summarizationPrompt(_ messages: [ChatMessage], focus: String?, maxChars: Int = 24_000) -> String {
        var log = ""
        for m in messages {
            let who: String
            switch m.role {
            case .user: who = "USER"; case .assistant: who = "ASSISTANT"
            case .tool: who = "TOOL"; case .system: who = "SYSTEM"
            }
            log += "\(who): \(m.content)\n"
        }
        if log.count > maxChars { log = String(log.prefix(maxChars)) + "\n… [history truncated]" }
        let focusLine = (focus?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
            .map { "\nFocus the summary on: \($0)\n" } ?? ""
        return """
        Summarize the conversation below so it can REPLACE the original history while losing nothing the \
        assistant needs to keep working: the user's goals, decisions made, files/APIs touched, current \
        state, and any open threads or constraints. Be concise and factual — no preamble, no restating this \
        instruction. Write it as durable notes the assistant can rely on.
        \(focusLine)
        --- CONVERSATION ---
        \(log)
        """
    }

    static let summarizationSystemPrompt =
        "You compress a coding assistant's conversation history into durable, factual notes. Preserve goals, " +
        "decisions, file/API names, and open threads. Drop chit-chat and redundancy. Output only the notes."

    /// Fold a produced summary back into a new transcript: a single message carrying the summary, followed
    /// by the kept-verbatim recent messages. The marker makes it obvious in `/context` and replay.
    ///
    /// Folded as `.user`, NOT `.system`: the non-Gemini encoders (Anthropic/OpenAI/Ollama) strip
    /// mid-transcript `.system` messages and hoist only the real system prompt, so a `.system` summary would
    /// be SILENTLY DROPPED at the model call. `.user` survives every encoder; consecutive user-role messages
    /// already occur normally (a `.tool` result also encodes as "user"), so this introduces no alternation
    /// problem.
    static func fold(summary: String, keep: [ChatMessage]) -> [ChatMessage] {
        let note = "[Summary of the earlier conversation, provided as context so it can continue]\n" +
            summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return [ChatMessage(role: .user, content: note)] + keep
    }

    /// Estimated tokens freed by replacing `summarize` with `summary` (reuses the /context estimator).
    static func tokensFreed(summarize: [ChatMessage], summary: String) -> Int {
        let before = summarize.reduce(0) { $0 + ContextReport.estimateTokens($1.content) }
        let after = ContextReport.estimateTokens(summary)
        return max(0, before - after)
    }
}
