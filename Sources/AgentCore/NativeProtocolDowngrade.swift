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

    /// Is this error a native tool-calling protocol rejection we can recover from by switching to text?
    ///
    /// `initialToolCall` = the FIRST native model call of the run has failed with NO successful tool
    /// round-trip yet. That failure can't be caused by growing tool history — it's a tool-schema/tool-support
    /// rejection — so we downgrade on ANY non-auth/non-quota HTTP status, INCLUDING a server-side 5xx.
    /// (Live: Gemini returns a GENERIC `500 "Internal error"` for a tool schema it can't parse — no
    /// "function" in the body — and repeats it every cycle. Downgrading once is strictly safe: a genuine
    /// outage fails on the text protocol too → honest error; a bad tool payload succeeds without tools.)
    ///
    /// Mid-run (default, `initialToolCall == false`): deliberately NARROW — only a 4xx/5xx whose body NAMES
    /// tools/functions, since a mid-run 5xx is more likely a real transient that text mode can't fix.
    /// Auth (401/403), quota (429), transport, and content errors that don't mention tools are never
    /// downgrade-worthy. Fail-closed: when unsure, return false (no downgrade).
    public static func shouldDowngrade(from error: Error, initialToolCall: Bool = false) -> Bool {
        guard let provider = error as? AIProviderError else { return false }
        switch provider {
        case .http(let status, let body):
            // First-call rejection: downgrade on a tool-schema 4xx (400/422/404) regardless of body — a
            // deterministic 4xx on the very first native call is almost always the tool request itself, and
            // text mode (no tools) is a strictly safe fallback. A 5xx is treated the SAME as mid-run (below):
            // only downgrade when the body NAMES tools. A GENERIC 5xx is far more likely a TRANSIENT outage
            // (live repro: the exact escalated tool request returns 200; a "500 every cycle" run was a
            // Gemini outage window) — downgrading it would silently disable native tools for the run on a
            // blip. Generic 5xx instead flows to retry + cross-cycle provider route-around, the correct fix.
            if initialToolCall, status == 400 || status == 422 || status == 404 { return true }
            if status == 400 || status == 422 || status == 404 { return bodyNamesTools(body) }
            if (500...599).contains(status) { return bodyNamesTools(body) }
            return false
        case .invalidResponse(let body):
            return bodyNamesTools(body)
        default:
            return false   // missingAPIKey / invalidAPIKey / rateLimited / transport / configuration
        }
    }

    /// True when the error body references the tool/function-calling surface — the fingerprint of a
    /// native-protocol rejection (vs an auth/quota/content error that text mode can't fix).
    static func bodyNamesTools(_ body: String) -> Bool {
        let b = body.lowercased()
        // SPECIFIC phrases only — a bare "tool" would false-trigger on "the requested tool is not
        // available" / "toolbar", masking a genuine missing-tool/config error behind a protocol downgrade.
        let needles = ["function", "functiondeclaration", "function_call", "function calling",
                       "tool_use", "tool_call", "tool calling", "tools are", "tool-use", "toolconfig", "tool schema"]
        return needles.contains { b.contains($0) }
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
