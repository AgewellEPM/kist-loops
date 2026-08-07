import Foundation

/// Who owns a tool — decides whether kist may AUTO-EVOLVE it or must only write a spec. This is the
/// mechanical enforcement of the "never blend kist / perslis / jeeves source" rule: only a NATIVE kist tool
/// is a legal auto-evolve target; an MCP/foreign tool gets a capability spec handed to its owning repo.
public enum ToolOwnership: String, Sendable, Equatable {
    case kist          // a native kist tool (bare name) — auto-evolvable inside this repo
    case foreign       // an MCP/external tool (namespaced "<server>__<tool>") — SPEC ONLY, never edit its repo
    case selfAuthored  // a tool kist WROTE for itself in the `self__` namespace — a legal auto-evolve target
                       // that is runtime-loadable (Phase 0 fork: no recompile). Distinct from `kist` so
                       // activation stays explicit and the never-blend invariant holds: foreign stays
                       // spec-only; `self__` is ours to register.
}

/// The reserved namespace for capabilities kist authors for itself. `self__<name>` is the ONLY namespace the
/// evolution loop may register a new tool into — a mechanical boundary on what self-evolution can create.
public let kistSelfAuthoredPrefix = "self__"

public enum ToolOwnershipResolver {
    /// MCP tools are namespaced `<server>__<tool>` (e.g. `perslis__win98_run_command`, `lsp-swift__hover`,
    /// `isolated-tester__click`). Native kist tools are bare (`read_file`). A `self__`-prefixed tool is
    /// kist's own self-authored capability.
    public static func owner(of tool: String) -> ToolOwnership {
        if tool.hasPrefix(kistSelfAuthoredPrefix) { return .selfAuthored }
        return tool.contains("__") ? .foreign : .kist
    }

    /// The MCP server that owns a foreign tool, so its spec goes to the right place
    /// (`perslis__win98_run_command` → `perslis`). nil for a native or self-authored tool.
    public static func foreignServer(of tool: String) -> String? {
        guard owner(of: tool) == .foreign, let r = tool.range(of: "__") else { return nil }
        let server = String(tool[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return server.isEmpty ? nil : server
    }
}
