import Foundation

/// THE TOOL CONTRACT — what every model reads before planning so it stops INVENTING APIs. The live failure
/// this fixes: a model called `computer_control(move_file)`, `(run_script)`, `(help)` — none exist — and
/// hammered `run_command` while shell was disabled, because nothing told it what's actually callable.
///
/// A tool can declare its exact action vocabulary and the actions models commonly HALLUCINATE for it. The
/// contract is GENERATED FROM THE LIVE REGISTRY (+ session policy), so swapping/adding an MCP server updates
/// it automatically — it's a live reflection of real capability, never a hand-maintained file that drifts.
public extension AgentTool {
    /// The ONLY valid values for this tool's `action` parameter (action-dispatch tools like
    /// computer_control). Empty = the tool has no action vocabulary.
    var supportedActions: [String] { [] }
    /// Actions models commonly INVENT for this tool that do NOT exist — listed explicitly so the planner
    /// stops guessing (e.g. computer_control: move_file, run_script, help).
    var unsupportedActions: [String] { [] }
    /// A free-form steer, e.g. "Does NOT move arbitrary files — use run_command for that."
    var capabilityNote: String? { nil }
    /// One or two concrete example calls.
    var usageExamples: [String] { [] }
}

public enum ToolContractBook {

    /// Render the contract for a live registry. `disabled` maps a tool name → the reason it's currently
    /// UNAVAILABLE (e.g. run_command when shell is off), so the model plans around it instead of retrying.
    public static func render(tools: ToolRegistry, disabled: [String: String] = [:]) -> String {
        var out = """
        \(CapabilityRegistry.render(tools: tools, disabled: disabled))

        TOOL CONTRACT — these are the ONLY tools and action names that exist in this session. If a tool,
        action, or capability is NOT listed here, it does NOT exist — do not call it or invent it. When a
        task needs a small project-local parser, converter, analyzer, validator, or data helper, use
        `custom_tool` to create and run it through the sandbox instead of asking the user to babysit. If
        the task is too large for one model context, use `context_brain` coverage/search/get to hot-load
        exact repo shards across chained turns. For deep research/planning, use `research_run` to gather
        evidence into a durable dossier before council/plan-execute. If the missing capability needs new
        external privileges or global installs, say so and ask.

        """
        for tool in tools.all().sorted(by: { $0.name < $1.name }) {
            let safeName = safeInline(tool.name)
            out += "\n## \(safeName)"
            if let reason = disabled[tool.name] {
                out += "  ⚠ UNAVAILABLE this session — \(safeInline(reason)). Do NOT call it."
            }
            out += "\n" + safeBlock(tool.description.trimmingCharacters(in: .whitespacesAndNewlines)) + "\n"
            let params = tool.parameters.map { "\(safeInline($0.name)): \(safeInline($0.type))\($0.required ? "" : "?")" }.joined(separator: ", ")
            if !params.isEmpty { out += "params: \(params)\n" }
            if !tool.supportedActions.isEmpty {
                out += "actions (the ONLY valid `action` values): " + tool.supportedActions.map(safeInline).joined(separator: ", ") + "\n"
            }
            if !tool.unsupportedActions.isEmpty {
                out += "NOT supported (these do NOT exist — never call them): " + tool.unsupportedActions.map(safeInline).joined(separator: ", ") + "\n"
            }
            if let note = tool.capabilityNote { out += "note: " + safeBlock(note) + "\n" }
            for ex in tool.usageExamples { out += "example: " + safeBlock(ex) + "\n" }
        }
        return out
    }

    static func safeInline(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "<", with: "(")
            .replacingOccurrences(of: ">", with: ")")
    }

    static func safeBlock(_ s: String) -> String {
        safeInline(s).replacingOccurrences(of: "```", with: "'''")
    }

    /// The standard `disabled` map for a session: run_command is unavailable when shell is off.
    public static func disabledMap(shellEnabled: Bool) -> [String: String] {
        shellEnabled ? [:] : ["run_command": "shell is off — start kist with --allow-shell to enable it"]
    }
}

/// Compact capability negotiation layer. The full tool contract below is exact but long; this gives the
/// planner the quick "what kind of work is possible here?" map before it commits to a plan.
public enum CapabilityRegistry {
    private static let domains: [(name: String, tools: [String])] = [
        ("Filesystem", ["list_files", "glob_files", "read_file", "write_file", "edit_file", "move_file", "make_dir"]),
        ("Context/RAG", ["context_brain", "search_code", "read_file", "remember", "recall"]),
        ("Code Search", ["search_code"]),
        ("Shell/Git", ["run_command"]),
        ("Tool Forge", ["custom_tool"]),
        ("Research/Web", ["research_run", "web_search", "fetch_url", "browse", "grounded_answer"]),
        ("Computer/Browser", ["computer_control", "browse"]),
        ("Visual Verification", ["visual_verify", "view_image", "browse", "edit_file", "write_file"]),
        ("Vision/Media/Data", ["view_image", "generate_image", "edit_image", "generate_audio", "generate_video", "watch_video", "live_screen_watch",
                               "analyze_media", "translate_document", "extract_clip", "read_spreadsheet", "query_data"]),
        // Perslis = Luke's legacy-software system (win98/DOS VM + era toolchains). Naming these here
        // lifts them out of the anonymous "MCP/Other" blob on BOTH prompt surfaces (planner + chat),
        // so legacy goals route onto the VM instead of brew-installing emulators on the host.
        ("Legacy DOS/Win9x VM (Perslis)", ["perslis__vm_launch", "perslis__vm_write_file", "perslis__win98_run_command",
                                           "perslis__win98_run_commands", "perslis__win98_run_command_recipe",
                                           "perslis__legacy_launch", "perslis__vm_control", "perslis__vm_ocr",
                                           "perslis__vm_finalize_poweroff"]),
        ("Planning/Coordination", ["tasks", "ask_user", "spawn_agent", "generate"]),
    ]

    public static func render(tools: ToolRegistry, disabled: [String: String] = [:]) -> String {
        let names = Set(tools.names)
        var used = Set<String>()
        var lines: [String] = [
            "CAPABILITY NEGOTIATION — build plans only from these available capabilities. If a capability",
            "is missing or marked unavailable, do not invent it. If it can be implemented as a small",
            "project-local helper, use Tool Forge/custom_tool; otherwise ask how to enable it or choose",
            "a different available route.",
            "",
        ]

        for domain in domains {
            let present = domain.tools.filter { names.contains($0) }
            guard !present.isEmpty else { continue }
            used.formUnion(present)
            let usable = present.filter { disabled[$0] == nil }
            let marker = usable.isEmpty ? "✗" : "✓"
            let rendered = present.map { tool -> String in
                if let reason = disabled[tool] { return "\(tool) (off: \(reason))" }
                return tool
            }.joined(separator: ", ")
            lines.append("\(marker) \(domain.name): \(rendered)")
        }

        let other = tools.names.filter { !used.contains($0) }
        if !other.isEmpty {
            lines.append("✓ MCP/Other: " + other.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
