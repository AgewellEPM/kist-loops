import Foundation
import AgentCore

/// Recovery language for failures — finding #11. A user should never see "provider 400". They should see
/// what failed, what the system already did about it, what (if anything) was lost, and the next move.
enum ErrorHumanizer {

    /// Map a raw tool/provider error into one calm sentence with a recovery hint. `tool`/`provider` add
    /// specificity when known. Always returns something human — an unknown error still gets framed
    /// (what failed + retry), never a bare status code.
    static func humanize(_ raw: String, tool: String? = nil, provider: String? = nil) -> String {
        let e = raw.lowercased()
        let who = provider.map { TeamLanguage.displayName($0) } ?? "The model"

        // Auth / key problems — actionable, not a stack trace.
        if e.contains("401") || e.contains("unauthorized") || e.contains("api key") || e.contains("apikey") || e.contains("no key") {
            return "\(who) rejected the request — its API key looks missing or invalid. Set it with `/model` or your key store, then retry."
        }
        if e.contains("403") || e.contains("forbidden") {
            return "\(who) refused access (forbidden) — the key may lack permission for this model. Try a different model with `/model`."
        }
        // Rate limit / overload — wait or switch.
        if e.contains("429") || e.contains("rate limit") || e.contains("overloaded") || e.contains("quota") {
            return "\(who) is rate-limited or over quota right now. Captain will try an eligible replacement model when replay is safe; otherwise wait and retry."
        }
        // Native tool-calling not supported → the loop falls back to the text protocol.
        if e.contains("tool") && (e.contains("not support") || e.contains("unsupported") || e.contains("no tool")) {
            return "\(who)'s native tool-calling isn't available here, so I switched it to the text protocol. Nothing was lost — retry the request."
        }
        // Network.
        if e.contains("timed out") || e.contains("timeout") || e.contains("network") || e.contains("connection") || e.contains("could not connect") {
            return "The connection to \(who) timed out. Captain will try an eligible replacement model when replay is safe; otherwise check the network and retry."
        }
        // Generic bad-request / server.
        if e.contains("400") || e.contains("bad request") {
            return "\(who) rejected the request as malformed. Captain will diagnose it and try an eligible replacement model when replay is safe."
        }
        if e.contains("500") || e.contains("502") || e.contains("503") || e.contains("server error") || e.contains("internal error") {
            return "\(who) had a server error on its side. Captain will try an eligible replacement model when replay is safe; otherwise retry in a moment."
        }
        // Tool-specific: a denied/blocked action.
        if e.contains("unknown tool") {
            return "I tried a tool that isn't available here\(tool.map { " (\($0))" } ?? ""). I'll use a different approach — retry if you'd like."
        }
        // Whether this tool is *definitely* read-only (name-only, conservative — a sometimes-read tool
        // like `tasks`/`custom_tool` reports NOT read-only, which keeps the mutation framing, the safe
        // side). Source of truth is ReversibilityClassifier, so this never drifts from the tool registry.
        let readOnly = tool.map { ReversibilityClassifier.isDefinitelyReadOnly($0) } ?? false

        // Missing PATH, and only for a read-only tool. A read that finds nothing is NOT a failed mutation,
        // so it must never say "nothing was committed" (that framing alarmed a user whose read_file missed
        // a path). Guarded on `readOnly` so a mutating tool whose error merely CONTAINS "not found" is not
        // misread as a missing path — e.g. edit_file "old_text not found in <file>" (the file exists) or
        // run_command "executable not found" (a launch failure). Those fall through to the mutation framing.
        if readOnly, e.contains("not found") || e.contains("no such file") || e.contains("does not exist")
            || e.contains("doesn't exist") || e.contains("enoent") {
            let subject = tool.map { "`\($0)`" } ?? "That step"
            let gist = concise(raw).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return "\(subject) couldn't find that path: \(gist) — it doesn't exist here. Check the path or list the directory, then retry."
        }
        // Fallback: frame it honestly without dumping internals. Strip a trailing period from the gist so
        // an error that already ends in "." doesn't render a double period before the recovery suffix.
        // Only a mutating tool can leave work "uncommitted"; a read/list/search failure cannot, so the
        // commit framing is suppressed for read-only tools (unknown/absent tool → treated mutating, safer).
        let toolPart = tool.map { "\($0) " } ?? ""
        let gist = concise(raw).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let tail = readOnly
            ? "Retry, or tell me a different approach."
            : "Nothing was committed — retry, or tell me a different approach."
        return "The \(toolPart)step didn't complete: \(gist). \(tail)"
    }

    /// Trim a raw error to a short, single-line gist (no stack traces / huge blobs). REDACTS secrets first —
    /// a raw error can carry a key ("401 for sk-…"); the user-facing gist must never leak it.
    static func concise(_ raw: String) -> String {
        let safe = SecretScanner.redactSecrets(in: raw)
        let firstLine = safe.split(whereSeparator: { $0 == "\n" }).first.map(String.init) ?? safe
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(157)) + "…" : trimmed
    }
}
