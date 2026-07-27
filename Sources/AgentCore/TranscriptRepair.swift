import Foundation

/// History-repair pass for the NATIVE tool-calling path — the cross-provider robustness the plan
/// calls out for Gemini (and that Anthropic also enforces): a `tool`/`functionResponse` turn is
/// only valid when it answers a tool call the model actually made earlier. A malformed transcript
/// (an ORPHAN tool result — no matching preceding assistant tool-call id) makes Gemini/Anthropic
/// reject the WHOLE request with a 400. The loop builds well-formed transcripts by construction,
/// but resumed/edited/externally-supplied histories may not — so we normalize at the encode
/// boundary instead of trusting the input.
///
/// The repair is conservative and LOSSLESS: invalid native protocol turns are not dropped; they are
/// converted to plain `user` notes (keeping their text) so no information is lost and every adapter
/// accepts the transcript.
public enum TranscriptRepair {

    /// Return a transcript safe to encode for native tool-calling:
    ///  • a `.tool` result whose `toolCallId` matches NO preceding assistant tool-call id is
    ///    rewritten as a `.user` message (orphan / out-of-order result);
    ///  • an assistant `toolCalls` message whose calls are not all answered by immediately-following
    ///    `.tool` messages is rewritten as a `.user` note, preventing OpenAI-compatible 400s like
    ///    "assistant message with tool_calls must be followed by tool messages";
    ///  • everything else is passed through unchanged, in order.
    /// Idempotent: repairing an already-valid transcript returns it intact.
    public static func repairForNativeTools(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seenCallIds = Set<String>()
        var out: [ChatMessage] = []
        out.reserveCapacity(messages.count)

        var index = 0
        while index < messages.count {
            let message = messages[index]
            switch message.role {
            case .assistant:
                if let calls = message.toolCalls, !calls.isEmpty {
                    let required = Set(calls.map(\.id))
                    var answered = Set<String>()
                    var lookahead = index + 1
                    while lookahead < messages.count, messages[lookahead].role == .tool {
                        if let id = messages[lookahead].toolCallId { answered.insert(id) }
                        lookahead += 1
                    }
                    if required.isSubset(of: answered) {
                        for c in calls { seenCallIds.insert(c.id) }
                        out.append(message)
                    } else {
                        let missing = required.subtracting(answered).sorted().joined(separator: ", ")
                        let names = calls.map(\.name).joined(separator: ", ")
                        out.append(ChatMessage(role: .user, content:
                            "(note: an assistant native tool-call turn was incomplete and was converted to text; missing result id(s): \(missing); attempted tool(s): \(names))\n\(message.content)"))
                    }
                } else {
                    out.append(message)
                }
            case .tool:
                if let id = message.toolCallId, seenCallIds.contains(id) {
                    out.append(message)                       // valid: answers a known call
                } else {
                    // Orphan / out-of-order result → keep the content as a user note (valid everywhere).
                    out.append(ChatMessage(role: .user, content:
                        "(note: a prior tool result with no matching call)\n\(message.content)"))
                }
            default:
                out.append(message)
            }
            index += 1
        }
        return out
    }

    /// True if the transcript is already valid for native tool-calling (no orphan tool results and
    /// no assistant tool-call turn with missing immediate results).
    /// Exposed for tests + callers that want to assert/measure rather than rewrite.
    public static func hasOrphanToolResults(_ messages: [ChatMessage]) -> Bool {
        var seen = Set<String>()
        for (index, m) in messages.enumerated() {
            switch m.role {
            case .assistant:
                if let calls = m.toolCalls, !calls.isEmpty {
                    let required = Set(calls.map(\.id))
                    var answered = Set<String>()
                    var lookahead = index + 1
                    while lookahead < messages.count, messages[lookahead].role == .tool {
                        if let id = messages[lookahead].toolCallId { answered.insert(id) }
                        lookahead += 1
                    }
                    if !required.isSubset(of: answered) { return true }
                    calls.forEach { seen.insert($0.id) }
                }
            case .tool: if let id = m.toolCallId, !seen.contains(id) { return true }
            default: break
            }
        }
        return false
    }
}
