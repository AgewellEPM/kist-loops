import Foundation

/// A FORGED-OR-AUTHORED SPECIALIST — kist's answer to Claude Code's `.claude/agents/<name>.md`, and a
/// drop-in match for its frontmatter. A dedicated identity (name + when-to-use + system prompt + scoped
/// tools + model + permission/turn limits) the runtime can spawn on demand, instead of a faceless generic
/// worker. Stored as a markdown file with a frontmatter block so files stay human-editable and
/// diff-friendly (a small tolerant reader — no YAML dependency; kist ships as one binary).
///
/// This is the EXACT Claude subagent system minus the Claude dependency: kist authors/forges/runs agents
/// natively against ANY BYOK provider, and can ALSO load real `.claude/agents/*.md` files unchanged.
///
/// `source` is PROVENANCE ONLY ("authored" | "forged" | a path). It is NEVER authority: a "forged" label
/// confers no trust, exactly like the signoff ledger's seal-or-drop and LessonStore's proven-coercion.
/// `toolAllowlist` is a CEILING-NARROWING request — enforcement (intersection with the spawner's ceiling)
/// lives in `resolvedTools`, applied by the tool layer at spawn.
public struct SpecialistDefinition: Sendable, Codable, Equatable {
    public let name: String              // unique id; command-shaped (letters/digits/-/_) → safe as a filename
    public let description: String       // WHEN to use it (drives selection/delegation)
    public let systemPrompt: String      // the markdown body — the specialist's instructions
    public let toolAllowlist: [String]?  // nil = inherit the spawner's tools; else REQUESTED ⊆ ceiling
    public let disallowedTools: [String]? // removed from the inherited/allowed set (Claude `disallowedTools`)
    public let model: ProviderBinding?   // an explicit provider:model binding (nil ⇒ see modelAlias)
    public let modelAlias: String?       // "sonnet"/"opus"/"haiku"/"fable"/"inherit" when not provider:model
    public let permissionMode: String?   // Claude permission mode (default/acceptEdits/auto/dontAsk/bypassPermissions/plan)
    public let maxTurns: Int?            // cap on agentic turns for this agent's run (nil = session default)
    // Claude subagent P1 fields — each wired to an existing kist subsystem at spawn time.
    public let skills: [String]?         // named skills preloaded into the specialist's context
    public let mcpServers: [String]?     // configured MCP server names scoped to this specialist
    public let memory: String?           // persistent-memory scope: user | project | local
    public let isolation: String?        // "worktree" ⇒ run in an isolated git worktree (fleet machinery)
    public let color: String?            // display color for the delegation banner
    public let initialPrompt: String?    // prepended to the task as the specialist's opening instruction
    public let source: String            // provenance, never authority

    public init(name: String, description: String, systemPrompt: String,
                toolAllowlist: [String]? = nil, disallowedTools: [String]? = nil,
                model: ProviderBinding? = nil, modelAlias: String? = nil,
                permissionMode: String? = nil, maxTurns: Int? = nil,
                skills: [String]? = nil, mcpServers: [String]? = nil, memory: String? = nil,
                isolation: String? = nil, color: String? = nil, initialPrompt: String? = nil,
                source: String = "authored") {
        self.name = name; self.description = description; self.systemPrompt = systemPrompt
        self.toolAllowlist = toolAllowlist; self.disallowedTools = disallowedTools
        self.model = model; self.modelAlias = modelAlias
        self.permissionMode = permissionMode; self.maxTurns = maxTurns
        self.skills = skills; self.mcpServers = mcpServers; self.memory = memory
        self.isolation = isolation; self.color = color; self.initialPrompt = initialPrompt
        self.source = source
    }

    /// The model aliases kist understands (Claude-compatible). Resolved to a real binding via an alias table.
    public static let knownModelAliases: Set<String> = ["sonnet", "opus", "haiku", "fable", "inherit"]
    /// The permission modes Claude frontmatter accepts. Stored as-is; mapped to kist's bar at spawn time.
    public static let knownPermissionModes: Set<String> =
        ["default", "acceptedits", "auto", "dontask", "bypasspermissions", "plan"]
    public static let knownMemoryScopes: Set<String> = ["user", "project", "local"]
    public static let knownColors: Set<String> = ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"]

    /// The SGR parameter for a named `color` (nil ⇒ no color). Used to tint the delegation banner so you
    /// can tell which specialist is running — the terminal equivalent of Claude's per-subagent color.
    public static func ansi(forColor color: String?) -> String? {
        switch color?.lowercased() {
        case "red": return "31"; case "green": return "32"; case "yellow": return "33"
        case "blue": return "34"; case "purple": return "35"; case "cyan": return "36"
        case "orange": return "38;5;208"; case "pink": return "38;5;213"
        default: return nil
        }
    }

    // MARK: - Validation (security gates — reject, never sanitize)

    /// A name is valid ONLY if it is non-empty and command-shaped — ASCII letters/digits/`-`/`_`, nothing
    /// else. This is a SECURITY gate, not cosmetics: the name becomes a filename (`<name>.md`), so a name
    /// with `/`, `.`, or whitespace could traverse out of the agents dir. ASCII-only (not `Character.isLetter`)
    /// so a Unicode confusable (Cyrillic/fullwidth lookalike) can't masquerade as a trusted specialist.
    private static let nameChars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { nameChars.contains($0) }
    }

    /// NO frontmatter scalar/list value may contain a newline — ANY of them carrying `\n---` would inject a
    /// false frontmatter close on reload, pushing the real `tools:` line into the body (allowlist → nil →
    /// inherit-all = privilege escalation). A tool entry may not contain a comma either (the round-trip
    /// splits on commas). Reject, don't sanitize. (name is ASCII-only, so it's already newline-free.)
    static func isFrontmatterSafe(_ s: String) -> Bool { !s.contains(where: { $0.isNewline || $0 == "\r" }) }

    public var isValid: Bool {
        guard Self.isValidName(name) else { return false }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.isFrontmatterSafe(description) else { return false }
        guard !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let model {
            guard Self.isFrontmatterSafe(model.providerId), Self.isFrontmatterSafe(model.model ?? "") else { return false }
        }
        if let modelAlias {
            guard Self.isFrontmatterSafe(modelAlias), Self.knownModelAliases.contains(modelAlias.lowercased()) else { return false }
        }
        if let permissionMode {
            guard Self.knownPermissionModes.contains(permissionMode.lowercased().replacingOccurrences(of: " ", with: "")) else { return false }
        }
        if let maxTurns, maxTurns <= 0 { return false }
        if let memory { guard Self.knownMemoryScopes.contains(memory.lowercased()) else { return false } }
        if let isolation { guard isolation.lowercased() == "worktree" else { return false } }
        if let color { guard Self.knownColors.contains(color.lowercased()) else { return false } }
        if let initialPrompt { guard Self.isFrontmatterSafe(initialPrompt) else { return false } }
        for list in [toolAllowlist, disallowedTools, skills, mcpServers] {
            if let list { for t in list where !Self.isFrontmatterSafe(t) || t.contains(",") { return false } }
        }
        // An MCP server name may not contain the namespace separator `__`: a tool is `<server>__<tool>`, so a
        // server whose name embeds `__` makes the server↔tool split ambiguous and lets a scoped specialist
        // reach an unintended server (Codex HIGH). Reject, don't guess.
        if let mcpServers { for s in mcpServers where s.contains("__") { return false } }
        return true
    }

    // MARK: - Resolution (spawn-time — pure, testable)

    /// The tools this agent may actually use, given the spawner's `ceiling`. Claude semantics: `tools`
    /// (allowlist) inherits the ceiling when omitted, then `disallowedTools` are removed. NEVER exceeds the
    /// ceiling (a definition can only NARROW). Order-preserving over the ceiling for determinism.
    public func resolvedTools(ceiling: [String]) -> [String] {
        let allowed: Set<String> = toolAllowlist.map(Set.init) ?? Set(ceiling)   // nil ⇒ inherit ceiling
        let denied = Set(disallowedTools ?? [])
        return ceiling.filter { allowed.contains($0) && !denied.contains($0) }
    }

    /// Resolve the model to a real binding. Order: explicit provider:model → alias table → inherit/roleDefault.
    /// `inherit`, an unknown alias, or nothing all fall through to `roleDefault` (fail-soft, never crash).
    public func resolvedModel(aliasTable: [String: ProviderBinding], roleDefault: ProviderBinding?) -> ProviderBinding? {
        if let model { return model }
        if let a = modelAlias?.lowercased(), a != "inherit", let mapped = aliasTable[a] { return mapped }
        return roleDefault
    }

    // MARK: - Markdown (frontmatter + body)

    /// Parse a `.md` file: a `---`-delimited frontmatter block (`key: value` lines) + a markdown body that
    /// becomes the system prompt. Returns nil unless the result is VALID — a malformed/partial file must
    /// never yield a half-formed specialist. Reads the Claude subagent fields, so a real `.claude/agents`
    /// file parses unchanged.
    ///
    /// Line-based + STRICT: the open fence is a line that is exactly `---`, and the close is the FIRST later
    /// line that is exactly `---`. A body containing `---` (a markdown rule) is fine — it's after the close.
    public static func parse(_ markdown: String, source: String) -> SpecialistDefinition? {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        var i = 1
        var fmLines: [String] = []
        while i < lines.count, lines[i] != "---" { fmLines.append(lines[i]); i += 1 }
        guard i < lines.count else { return nil }   // unterminated frontmatter → reject
        let body = lines[(i + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        var fields: [String: String] = [:]
        for raw in fmLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        guard let name = fields["name"], let description = fields["description"] else { return nil }

        // Distinguish ABSENT tools (nil ⇒ inherit) from PRESENT-but-empty (`[]` ⇒ fail-closed). Also strip
        // Claude's `[a, b]` YAML list brackets so an inline array parses too.
        func toolList(_ key: String) -> [String]? {
            fields[key].map { spec in
                spec.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        let tools = toolList("tools")
        let disallowed = toolList("disallowedtools")

        // model: a provider:model binding, else an alias/"inherit" string preserved for later resolution.
        var model: ProviderBinding? = nil
        var modelAlias: String? = nil
        if let raw = fields["model"], !raw.isEmpty {
            if let b = ProviderBinding.parse(raw), !Self.knownModelAliases.contains(raw.lowercased()) {
                model = b
            } else {
                modelAlias = raw
            }
        }
        // A PRESENT-but-unparseable maxTurns is a malformed definition — reject, don't silently default.
        var maxTurns: Int? = nil
        if let raw = fields["maxturns"] {
            guard let n = Int(raw) else { return nil }
            maxTurns = n
        }

        let def = SpecialistDefinition(name: name, description: description, systemPrompt: body,
                                       toolAllowlist: tools, disallowedTools: disallowed,
                                       model: model, modelAlias: modelAlias,
                                       permissionMode: fields["permissionmode"], maxTurns: maxTurns,
                                       skills: toolList("skills"), mcpServers: toolList("mcpservers"),
                                       memory: fields["memory"], isolation: fields["isolation"],
                                       color: fields["color"], initialPrompt: fields["initialprompt"],
                                       source: source)
        return def.isValid ? def : nil
    }

    /// Render back to the `.md` on-disk form (round-trips with `parse`). An EMPTY allowlist is rendered as
    /// `tools:` (present, empty) so the `[]` (fail-closed) vs `nil` (inherit) distinction survives reload.
    public func render() -> String {
        var fm = "---\nname: \(name)\ndescription: \(description)\n"
        if let toolAllowlist { fm += "tools: \(toolAllowlist.joined(separator: ", "))\n" }        // emit even if []
        if let disallowedTools { fm += "disallowedTools: \(disallowedTools.joined(separator: ", "))\n" }
        if let model { fm += "model: \(model.providerId)\(model.model.map { ":\($0)" } ?? "")\n" }
        else if let modelAlias { fm += "model: \(modelAlias)\n" }
        if let permissionMode { fm += "permissionMode: \(permissionMode)\n" }
        if let maxTurns { fm += "maxTurns: \(maxTurns)\n" }
        if let skills { fm += "skills: \(skills.joined(separator: ", "))\n" }
        if let mcpServers { fm += "mcpServers: \(mcpServers.joined(separator: ", "))\n" }
        if let memory { fm += "memory: \(memory)\n" }
        if let isolation { fm += "isolation: \(isolation)\n" }
        if let color { fm += "color: \(color)\n" }
        if let initialPrompt { fm += "initialPrompt: \(initialPrompt)\n" }
        fm += "---\n\n\(systemPrompt)\n"
        return fm
    }
}
