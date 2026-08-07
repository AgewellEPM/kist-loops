import Foundation

/// Who owns a tool — decides whether kist may AUTO-EVOLVE it or must only write a spec. This is the
/// mechanical enforcement of the "never blend kist / perslis / jeeves source" rule: only a NATIVE kist tool
/// is a legal auto-evolve target; an MCP/foreign tool gets a capability spec handed to its owning repo.
public enum ToolOwnership: String, Sendable, Equatable {
    case kist       // a native kist tool (bare name) — auto-evolvable inside this repo
    case foreign    // an MCP/external tool (namespaced "<server>__<tool>") — SPEC ONLY, never edit its repo
}

public enum ToolOwnershipResolver {
    /// MCP tools are namespaced `<server>__<tool>` (e.g. `perslis__win98_run_command`, `lsp-swift__hover`,
    /// `isolated-tester__click`). Native kist tools are bare (`read_file`, `run_command`, `research_run`).
    public static func owner(of tool: String) -> ToolOwnership {
        tool.contains("__") ? .foreign : .kist
    }

    /// The MCP server that owns a foreign tool, so its spec goes to the right place
    /// (`perslis__win98_run_command` → `perslis`). nil for a native tool.
    public static func foreignServer(of tool: String) -> String? {
        guard let r = tool.range(of: "__") else { return nil }
        let server = String(tool[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return server.isEmpty ? nil : server
    }
}
