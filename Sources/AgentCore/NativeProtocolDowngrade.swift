import Foundation

/// FLAWLESS-LOOPS SAFETY NET #2: native → text auto-downgrade.
///
/// Some models advertise native function-calling but reject a *tool-laden request* mid-run — most often
/// a provider 400/422 once the tool history grows or when built-in tools collide with function
/// declarations (the exact Gemini failure we hit live). The loop used to DIE on that. Instead, when the
/// tool mode is `.auto` (capability-routed, not user-forced), we classify the error and, if it's a
/// native-tool-protocol rejection, transparently re-drive the SAME run in the universal text protocol —
/// which needs no provider-side tool support. Forced `--tools native` is never silently downgraded.
public enum NativeProtocolDowngrade {
    public enum Decision: Sendable, Equatable {
        /// Continue this checkpoint in text mode, but probe native again on a fresh turn.
        case currentRunOnly
        /// Deterministic first-request schema/support mismatch safe to quarantine by exact schema.
        case cacheableCapabilityMismatch
    }

    /// Is this error a native tool-calling protocol rejection we can recover from by switching to text?
    ///
    /// `initialToolCall` means this turn has not completed a native assistant→tool-result round-trip yet.
    /// It permits a run-local fallback for deterministic first-request 400/422/404 failures. A fallback is
    /// cacheable only when `hasToolProtocolHistory` is also false for the repaired transcript actually sent:
    /// a later REPL turn can have zero round-trips of its own while still carrying old native exchanges, and
    /// a rejection of that accumulated history is not proof that the exact tool schema is unsupported.
    ///
    /// Mid-run (default, `initialToolCall == false`): deliberately NARROW — only a 4xx/5xx whose body NAMES
    /// tools/functions, since a mid-run 5xx is more likely a real transient that text mode can't fix.
    /// Auth (401/403), quota (429), transport, and content errors that don't mention tools are never
    /// downgrade-worthy. Fail-closed: when unsure, return false (no downgrade).
    public static func decision(from error: Error,
                                initialToolCall: Bool = false,
                                hasToolProtocolHistory: Bool = false,
                                capabilityAlreadyProven: Bool = false) -> Decision? {
        guard let provider = error as? AIProviderError else { return nil }
        switch provider {
        case .http(let status, let body):
            // Server faults are never evidence of a missing tool capability, regardless of wording.
            // A generic client error can describe context, model, endpoint, or policy failures; only a
            // bounded, explicit tool/function/schema rejection may switch protocols.
            guard status == 400 || status == 404 || status == 422,
                  explicitlyRejectsToolProtocol(body) else { return nil }
            if initialToolCall, !hasToolProtocolHistory, !capabilityAlreadyProven {
                return .cacheableCapabilityMismatch
            }
            return .currentRunOnly
        default:
            return nil   // missingAPIKey / invalidAPIKey / rateLimited / transport / configuration
        }
    }

    public static func shouldDowngrade(from error: Error, initialToolCall: Bool = false,
                                       hasToolProtocolHistory: Bool = false,
                                       capabilityAlreadyProven: Bool = false) -> Bool {
        decision(from: error, initialToolCall: initialToolCall,
                 hasToolProtocolHistory: hasToolProtocolHistory,
                 capabilityAlreadyProven: capabilityAlreadyProven) != nil
    }

    /// Require either a provider capability code or rejection grammar whose subject is the native
    /// tool/function/schema surface. Merely mentioning `tools parameter` in a context/model error is
    /// not evidence that switching protocols will help and must never seed a negative capability cache.
    static func explicitlyRejectsToolProtocol(_ body: String) -> Bool {
        if hasStructuredCapabilityCode(body) { return true }
        let normalized = body.lowercased()
            .replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9' ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        let surface = "(?:function (?:calling|declarations?|schemas?|definitions?|parameters?)|"
            + "tool (?:calling|use|calls?|schemas?|config)|toolconfig|tools(?: parameter)?)"
        let forwardRejection = "(?:is |are |was |were |has been |have been )?"
            + "(?:unsupported|not supported|not allowed|invalid|rejected|unknown|unrecognized|disabled|unavailable|error)"
        let patterns = [
            "\\b\(surface)(?: [a-z0-9']+){0,3} \(forwardRejection)\\b",
            "\\b(?:unsupported|unknown|unrecognized|invalid|disabled) \(surface)\\b",
            "\\b(?:does not|doesn't|cannot|can't) support(?: [a-z0-9']+){0,2} \(surface)\\b",
        ]
        return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    private static func hasStructuredCapabilityCode(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return false }
        let accepted: Set<String> = [
            "function calling unsupported", "function calling not supported",
            "tool calling unsupported", "tool calling not supported",
            "tool use unsupported", "tools not supported", "tools not allowed",
            "unsupported tool schema", "unknown tool schema", "invalid tool schema",
        ]
        func normalizedCode(_ value: String) -> String {
            value.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        func visit(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if ["code", "type", "reason"].contains(key.lowercased()),
                       let string = child as? String,
                       accepted.contains(normalizedCode(string)) { return true }
                    if visit(child) { return true }
                }
            } else if let array = value as? [Any] {
                return array.contains(where: visit)
            }
            return false
        }
        return visit(json)
    }

    /// Native protocol structures present in the effective provider transcript. Callers should pass the
    /// transcript through `TranscriptRepair` first so incomplete crash-resume fragments that are converted
    /// to plain notes do not masquerade as a completed native history exchange.
    static func hasToolProtocolHistory(_ messages: [ChatMessage]) -> Bool {
        messages.contains { message in
            message.role == .tool || !(message.toolCalls?.isEmpty ?? true)
        }
    }

    /// Flatten a native-form transcript into one the text/`complete` path can consume safely: drop the
    /// `toolCalls` arrays and `.tool` role messages (provider-specific structures that themselves can
    /// trip the rejection) while PRESERVING the work as readable context, so the downgraded text run
    /// continues from where native left off instead of restarting blind.
    public static func flattenForText(_ messages: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        out.reserveCapacity(messages.count)
        for m in messages {
            switch m.role {
            case .system, .user:
                out.append(m)
            case .assistant:
                if let calls = m.toolCalls, !calls.isEmpty {
                    let rendered = calls.map { "→ called \($0.name)(\(compact($0.argumentsJSON)))" }.joined(separator: "\n")
                    let content = m.content.isEmpty ? rendered : (m.content + "\n" + rendered)
                    out.append(ChatMessage(role: .assistant, content: content))
                } else {
                    out.append(ChatMessage(role: .assistant, content: m.content))   // strip any nil toolCalls/ids
                }
            case .tool:
                // A tool observation → fold it back in as a user-visible result line.
                out.append(ChatMessage(role: .user, content: "Observation:\n\(m.content)"))
            }
        }
        return out
    }

    private static func compact(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 160 ? String(trimmed.prefix(157)) + "…" : trimmed
    }
}
