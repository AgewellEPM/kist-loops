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
    ///  • every assistant call id is consumed at most once in the whole transcript;
    ///  • each call is answered exactly once in the immediately-following `.tool` block;
    ///  • late/orphan/duplicate results are rewritten as `.user` notes, while a complete exchange can
    ///    still be retained after rejecting only its duplicate/foreign result rows;
    ///  • an assistant `toolCalls` message missing any immediate result is rewritten as a `.user` note,
    ///    preventing OpenAI-compatible 400s like "assistant message with tool_calls must be followed by
    ///    tool messages";
    ///  • everything else is passed through unchanged, in order.
    /// Idempotent: repairing an already-valid transcript returns it intact.
    public static func repairForNativeTools(_ messages: [ChatMessage]) -> [ChatMessage] {
        var consumedCallIds = Set<String>()
        var out: [ChatMessage] = []
        out.reserveCapacity(messages.count)

        var index = 0
        while index < messages.count {
            let message = messages[index]
            switch message.role {
            case .assistant:
                if let calls = message.toolCalls, !calls.isEmpty {
                    var lookahead = index + 1
                    while lookahead < messages.count, messages[lookahead].role == .tool { lookahead += 1 }
                    let results = Array(messages[(index + 1)..<lookahead])
                    let analysis = analyze(calls: calls, results: results,
                                           consumedCallIds: consumedCallIds)
                    if analysis.complete {
                        out.append(message)
                        // Preserve one immediate result for every requested id, in original result order.
                        // Any duplicate/foreign rows remain visible as plain notes, but cannot reach a
                        // strict provider as native protocol messages.
                        for (offset, result) in results.enumerated()
                            where analysis.acceptedResultOffsets.contains(offset) {
                            out.append(result)
                        }
                        for (offset, result) in results.enumerated()
                            where !analysis.acceptedResultOffsets.contains(offset) {
                            out.append(rejectedResultNote(result))
                        }
                        consumedCallIds.formUnion(calls.map(\.id))
                    } else {
                        let names = calls.map(\.name).joined(separator: ", ")
                        out.append(ChatMessage(role: .user, content:
                            "(note: an assistant native tool-call turn was incomplete or invalid and was converted to text; \(analysis.reason); attempted tool(s): \(names))\n\(message.content)"))
                        results.forEach { out.append(rejectedResultNote($0)) }
                    }
                    index = lookahead
                    continue
                } else {
                    out.append(message)
                }
            case .tool:
                // Every valid result is consumed together with its immediately preceding assistant call.
                // Reaching this branch means the result is orphaned, late, or duplicated.
                out.append(rejectedResultNote(message))
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
        var consumedCallIds = Set<String>()
        var index = 0
        while index < messages.count {
            let message = messages[index]
            switch message.role {
            case .assistant:
                if let calls = message.toolCalls, !calls.isEmpty {
                    var lookahead = index + 1
                    while lookahead < messages.count, messages[lookahead].role == .tool { lookahead += 1 }
                    let results = Array(messages[(index + 1)..<lookahead])
                    let analysis = analyze(calls: calls, results: results,
                                           consumedCallIds: consumedCallIds)
                    if !analysis.complete || analysis.acceptedResultOffsets.count != results.count {
                        return true
                    }
                    consumedCallIds.formUnion(calls.map(\.id))
                    index = lookahead
                    continue
                }
            case .tool:
                return true
            default: break
            }
            index += 1
        }
        return false
    }

    private struct ExchangeAnalysis {
        let complete: Bool
        let acceptedResultOffsets: Set<Int>
        let reason: String
    }

    /// Select exactly one adjacent result for each fresh call id. Extra rows are rejected separately so
    /// a recoverable exchange remains native, but duplicate call ids or missing results invalidate the
    /// assistant turn itself.
    private static func analyze(calls: [ToolCallRef], results: [ChatMessage],
                                consumedCallIds: Set<String>) -> ExchangeAnalysis {
        let callIds = calls.map(\.id)
        let required = Set(callIds)
        guard required.count == callIds.count, !required.contains("") else {
            return ExchangeAnalysis(complete: false, acceptedResultOffsets: [],
                                    reason: "duplicate or empty tool-call id")
        }
        let reused = required.intersection(consumedCallIds)
        guard reused.isEmpty else {
            return ExchangeAnalysis(complete: false, acceptedResultOffsets: [],
                                    reason: "tool-call id(s) were reused: \(reused.sorted().joined(separator: ", "))")
        }

        var selectedById: [String: Int] = [:]
        for (offset, result) in results.enumerated() {
            guard let id = result.toolCallId, required.contains(id), selectedById[id] == nil else {
                continue
            }
            selectedById[id] = offset
        }
        let missing = required.subtracting(selectedById.keys)
        guard missing.isEmpty else {
            return ExchangeAnalysis(complete: false, acceptedResultOffsets: [],
                                    reason: "missing immediate result id(s): \(missing.sorted().joined(separator: ", "))")
        }
        return ExchangeAnalysis(complete: true,
                                acceptedResultOffsets: Set(selectedById.values),
                                reason: "complete")
    }

    private static func rejectedResultNote(_ message: ChatMessage) -> ChatMessage {
        ChatMessage(role: .user, content:
            "(note: a prior tool result was orphaned, late, duplicated, or otherwise had no immediately adjacent unconsumed call)\n\(message.content)")
    }
}
