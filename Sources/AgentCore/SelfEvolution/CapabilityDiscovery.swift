import Foundation

/// Phase 2 auto-recovery: when a tool refuses because the model used the WRONG form (a knowledgeGap), find
/// how to discover the tool's REAL capabilities and retry — instead of giving up. This is exactly what the
/// perslis run needed: the tool said "(search: win98_run_commands)"; the recovery is to call that sibling,
/// read the real command list, and retry with a cataloged command.
public struct DiscoveryStep: Sendable, Equatable {
    /// A tool that lists the culprit's real capabilities, if we can name one that actually exists.
    public let listTool: String?
    /// An argument/query for the list tool, lifted from the tool's own hint when present.
    public let query: String?
    /// The instruction handed to the loop: discover, then retry the ORIGINAL request with a valid form.
    public let brief: String
}

public enum CapabilityDiscovery {

    /// Propose a discovery step for a knowledge-gap failure.
    /// - `tool`: the culprit tool that refused.
    /// - `hint`: the tool's own guidance (e.g. "search: win98_run_commands", "Use e.g. ret, esc, tab").
    /// - `availableTools`: the tools actually callable this turn (so we only point at ones that exist).
    public static func step(tool: String, hint: String?, availableTools: [String]) -> DiscoveryStep {
        let available = Set(availableTools)

        // 1) The hint may NAME the discovery action ("search: win98_run_commands"). Prefer a real tool it
        //    names — matched against the culprit's own MCP server namespace so we don't jump repos.
        if let hint, let named = namedListTool(in: hint, culprit: tool, available: available) {
            return DiscoveryStep(
                listTool: named, query: queryFromHint(hint),
                brief: "DISCOVER then RETRY — `\(tool)` refused the form you used. Call `\(named)`"
                    + (queryFromHint(hint).map { " (query: \($0))" } ?? "")
                    + " to list its real, supported inputs, then retry the ORIGINAL request with a valid one. "
                    + "Do NOT edit code; this is a usage gap, not a bug.")
        }

        // 2) The plural sibling ("perslis__win98_run_command" → "perslis__win98_run_commands") is the common
        //    "list" convention — use it only if it actually exists as a callable tool.
        if let sib = pluralSibling(of: tool), available.contains(sib) {
            return DiscoveryStep(
                listTool: sib, query: nil,
                brief: "DISCOVER then RETRY — call `\(sib)` to enumerate what `\(tool)` actually supports, "
                    + "then retry the original request with a supported value. No code edits.")
        }

        // 3) The hint itself sometimes IS the answer (a qcode list: "Use e.g. ret, esc, tab…"). Retry
        //    straight from it — no discovery call needed.
        if let hint, listsValuesInline(hint) {
            return DiscoveryStep(
                listTool: nil, query: nil,
                brief: "RETRY from the tool's own guidance — `\(tool)` told you the valid inputs: “\(hint)”. "
                    + "Retry the original request using ONE of those, not free-form text. No code edits.")
        }

        // 4) Nothing to enumerate — re-read the tool's contract and retry conservatively.
        return DiscoveryStep(
            listTool: nil, query: nil,
            brief: "RE-READ then RETRY — re-read `\(tool)`'s tool contract (its parameters/allowed values) "
                + "and retry with a valid form. If no valid form exists, THIS is a real tool-limit.")
    }

    // MARK: - Helpers

    /// "perslis__win98_run_command" → "perslis__win98_run_commands" (the list convention).
    static func pluralSibling(of tool: String) -> String? {
        guard !tool.hasSuffix("s") else { return nil }
        return tool + "s"
    }

    /// Find a tool NAME inside a hint, restricted to the culprit's own server namespace (never cross repos).
    static func namedListTool(in hint: String, culprit: String, available: Set<String>) -> String? {
        let server = ToolOwnershipResolver.foreignServer(of: culprit)   // nil for native kist tools
        // Tokens that look like tool/action ids (letters, digits, _). Match the longest that resolves to a
        // real available tool — trying both the bare token and the server-qualified form.
        let tokens = hint.split { !($0.isLetter || $0.isNumber || $0 == "_") }.map(String.init)
        for token in tokens.sorted(by: { $0.count > $1.count }) where token.count >= 4 {
            if available.contains(token) { return token }
            if let server, available.contains("\(server)__\(token)") { return "\(server)__\(token)" }
        }
        return nil
    }

    static func queryFromHint(_ hint: String) -> String? {
        guard let r = hint.lowercased().range(of: "search:") else { return nil }
        let start = hint.index(hint.startIndex, offsetBy: hint.lowercased().distance(from: hint.lowercased().startIndex, to: r.upperBound))
        let tail = String(hint[start...]).trimmingCharacters(in: CharacterSet(charactersIn: " )'\"…"))
        return tail.isEmpty ? nil : String(tail.prefix(60))
    }

    /// A hint that inlines the valid values ("Use e.g. ret, esc, tab, up/down") — a comma/slash list.
    static func listsValuesInline(_ hint: String) -> Bool {
        let l = hint.lowercased()
        let listy = l.contains(",") || l.contains("/")
        return listy && (l.contains("use e.g.") || l.contains("one of") || l.contains("valid") || l.contains("qcode"))
    }
}
