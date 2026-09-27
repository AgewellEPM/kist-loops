import Foundation

/// Injectable registry of agent tools.
///
/// Unlike the GUI app's `ToolRegistry.shared` singleton, this is a plain value you
/// construct with exactly the tools a given runtime should have — the GUI gets its
/// macOS desktop tools, Kist/mcp-server get the headless set, tests get a stub set.
/// `Sendable` so it can be handed to concurrent tool calls.
public struct ToolRegistry: Sendable {
    private let tools: [String: AgentTool]

    /// Build a registry from a list of tools. Later entries win on name collision.
    public init(_ tools: [AgentTool]) {
        self.init(tools, installDelegationControls: true)
    }

    private init(_ tools: [AgentTool], installDelegationControls: Bool) {
        var expanded = tools
        if installDelegationControls {
            for source in tools.compactMap({ $0 as? any AsyncDelegationRegistryProviding }) {
                expanded.append(contentsOf: source.delegationRegistry.controlTools())
            }
        }
        var map: [String: AgentTool] = [:]
        for tool in expanded { map[tool.name] = tool }
        self.tools = map
    }

    /// Build an exact capability projection without auto-installing sibling/control tools. Callers must
    /// have already selected trusted implementations; this constructor preserves that ceiling verbatim.
    init(capabilityScoped tools: [AgentTool]) {
        self.init(tools, installDelegationControls: false)
    }

    /// The portable, Foundation-only tool set shared by Kist and mcp-server. Pure
    /// filesystem + search + (policy-gated) shell — NO AppKit/desktop-automation tools.
    /// Those stay in the GUI app because they cannot exist on Linux headless.
    public static func headless() -> ToolRegistry {
        ToolRegistry([
            ReadFileTool(),
            ReadFilesTool(),
            WriteFileTool(),
            EditFileTool(),
            NotebookEditTool(),
            ApplyPatchTool(),
            MoveFileTool(),
            MakeDirTool(),
            ListFilesTool(),
            GlobFilesTool(),
            SearchCodeTool(),
            AstGrepTool(),
            AstGrepApplyTool(),
            GitTool(),
            SymbolsTool(),
            ContextBrainTool(),
            CustomTool(),
            ResearchRunTool(),
            JeevesResearchTool(),   // R6: symbolic link-wheel grounding, reachable by every loop
            RunCommandTool(),
            ManageJobsTool(),
        ])
    }

    /// Narrow this registry to a specialist's tool allowlist — the NO-PRIVILEGE-ESCALATION gate (P2).
    /// The result is the INTERSECTION of the requested names with the tools this registry actually has:
    /// a requested tool that ISN'T in this ceiling is DROPPED, never granted. A forged/authored allowlist
    /// can therefore only ever REMOVE tools, never add one the spawner lacks.
    ///
    /// - `nil` allowlist ⇒ inherit the ceiling (returns self unchanged).
    /// - empty / all-unknown allowlist ⇒ EMPTY registry (fail-closed: a specialist that names only tools
    ///   it can't have gets nothing, not everything).
    ///
    /// Because the narrowed registry literally does not contain the dropped tools, `execute(name:)` on it
    /// returns "unknown tool" for anything outside the allowlist — execution-time enforcement is automatic
    /// (belt + suspenders with this construction-time narrowing).
    public func scoped(to allowlist: [String]?) -> ToolRegistry {
        guard let allowlist else { return self }
        let allowed = Set(allowlist)
        return ToolRegistry(all().filter { allowed.contains($0.name) }, installDelegationControls: false)
    }

    /// A copy of this registry with one more tool (later wins on a name collision). Used to inject a
    /// per-loop tool that needs runtime state the static registry can't hold (e.g. `ask_user` + interactor).
    public func adding(_ tool: AgentTool) -> ToolRegistry {
        ToolRegistry(all() + [tool],
                     installDelegationControls: tool is any AsyncDelegationRegistryProviding)
    }

    public func tool(named name: String) -> AgentTool? { tools[name] }

    public func all() -> [AgentTool] { Array(tools.values) }

    public var names: [String] { tools.keys.sorted() }

    /// Record a host authority denial without invoking the denied implementation. Ordinary unknown and
    /// ToolGate denials are audited by `execute`; pre-dispatch effect-contract blocks use this companion
    /// seam so invented writes remain visible in receipts while remaining impossible to execute.
    func policyDenied(name: String, arguments: [String: Any], reason: String,
                      context: ToolContext) async -> ToolResult {
        let (keys, digest) = AuditLog.digest(arguments)
        let activeAllowlist = await context.skillTracker?.activeToolAllowlist()
        await context.auditLog?.record(AuditEntry(
            at: Self.now(), tool: name, argKeys: keys, argsDigest: digest,
            outcome: "blocked_auth", success: false,
            scope: activeAllowlist.map { $0.sorted() },
            correlationID: context.correlationID))
        return .failure(reason)
    }

    /// Build-relevant effects for one invocation, classified from the complete arguments at the same
    /// registry seam every loop executes through. The result is recorded with the trajectory so later
    /// consumers do not guess independently from a truncated fingerprint.
    public func effectObservation(name: String, arguments: [String: Any],
                                  result: ToolResult? = nil) -> ToolEffectObservation {
        if name == "run_command", let result,
           BuilderVerificationCommandAuthority.consume(arguments: arguments, result: result) {
            return ToolEffectObservation(mutation: .none, verification: .buildOrTest)
        }
        return ToolEffectCatalog.observe(
            tool: name, arguments: arguments, outcomeMetadata: result?.metadata)
    }

    /// Neutral tool definitions for NATIVE tool-calling (providers translate to their schema).
    public func toolSpecs() -> [ToolSpec] {
        all().sorted { $0.name < $1.name }
            .map { ToolSpec(name: $0.name, description: $0.description, parameters: $0.parameters) }
    }

    /// Human-readable one-line-per-tool listing for a system prompt.
    public func descriptions() -> String {
        all().sorted { $0.name < $1.name }.map { tool in
            let params = tool.parameters.map { "\($0.name): \($0.type)\($0.required ? "" : "?")" }
                .joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }.joined(separator: "\n")
    }

    /// OpenAI-style `tools` JSON array for function-calling requests.
    public func asJSON() -> [[String: Any]] {
        all().sorted { $0.name < $1.name }.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": Dictionary(uniqueKeysWithValues: tool.parameters.map { p in
                            (p.name, ["type": p.type, "description": p.description])
                        }),
                        "required": tool.parameters.filter { $0.required }.map { $0.name },
                    ],
                ],
            ]
        }
    }

    /// Builtin skill locations, cached once — consulted only on the unknown-tool path to teach
    /// interface misuse (a skill called as if it were a tool). Discovery reads the resource
    /// bundle; failure there yields an empty map and the plain unknown-tool refusal stands.
    private static let builtinSkillLocations: [String: String] = {
        let (skills, _) = SkillDiscovery.discoverBuiltins()
        return Dictionary(skills.map { ($0.name, $0.skillFilePath) }, uniquingKeysWith: { a, _ in a })
    }()

    /// Execute a tool by name, never throwing — unknown tools and thrown errors are
    /// normalized into a failed `ToolResult` so the agent loop can observe and recover.
    public func execute(name: String, arguments: [String: Any], context: ToolContext) async -> ToolResult {
        await executeImpl(name: name, arguments: arguments, hostArguments: [:], context: context)
    }

    /// Execute with additional host-owned arguments that are deliberately absent from the advertised
    /// model schema. The caller-supplied arguments are still validated against that public schema before
    /// the trusted additions reach the implementation, so a model cannot forge an internal authority
    /// field. This is module-internal because only host orchestration code may bind those values.
    func executeHostBound(name: String, arguments: [String: Any],
                          hostArguments: [String: Any], context: ToolContext) async -> ToolResult {
        await executeImpl(name: name, arguments: arguments,
                          hostArguments: hostArguments, context: context)
    }

    private func executeImpl(name: String, arguments: [String: Any],
                             hostArguments: [String: Any], context: ToolContext) async -> ToolResult {
        let spanStartedAt = Date()
        let telemetryStarted = DispatchTime.now().uptimeNanoseconds
        // Audit at THE choke point (council #1): one immutable record per invocation, capturing the
        // tool + an arg DIGEST (values hashed, never logged raw) + the enforcement OUTCOME. Records
        // BLOCKED attempts too — a denied call is exactly what forensics needs to see. Best-effort.
        let (rawArgKeys, rawArgsDigest) = AuditLog.digest(arguments)
        // Read the active scope ONCE — same value drives the audit field AND the block decision, so a
        // concurrent skill-load can't make them disagree (Codex LOW).
        let activeAllowlist = await context.skillTracker?.activeToolAllowlist()
        let activeScope = activeAllowlist.map { $0.sorted() }
        func audit(_ outcome: String, _ success: Bool) async {
            await context.auditLog?.record(AuditEntry(at: Self.now(), tool: name, argKeys: rawArgKeys,
                                                      argsDigest: rawArgsDigest, outcome: outcome,
                                                      success: success, scope: activeScope,
                                                      correlationID: context.correlationID))
        }

        func traced(_ result: ToolResult, argumentKeys: [String],
                    argumentsDigest: String) async -> ToolResult {
            guard let recorder = context.traceRecorder else { return result }
            let metadataCanonical = result.metadata.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1f}")
            let resultDigest = AuditLog.digest([
                "success": result.success, "output": result.output,
                "error": result.error ?? "", "metadata": metadataCanonical,
            ]).digest
            let metadataDigest = AuditLog.digest(["metadata": metadataCanonical]).digest
            await recorder.record(AgentSpan(
                id: TraceID.make(), traceId: recorder.traceId, kind: .toolCall,
                toolName: name,
                attributes: [
                    "arguments.digest": argumentsDigest,
                    "arguments.key_count": String(argumentKeys.count),
                    "result.digest": resultDigest,
                    "result.output_bytes": String(result.output.utf8.count),
                    "result.error_bytes": String((result.error ?? "").utf8.count),
                    "result.metadata_count": String(result.metadata.count),
                    "result.metadata_digest": metadataDigest,
                ],
                startedAt: spanStartedAt, endedAt: Date(),
                status: result.success ? .ok : .error))
            return result
        }

        guard let tool = tools[name] else {
            // Interface-misuse teaching (autopsy 2026-08-25): a weak model called the ADVERTISED
            // skill `code-investigation` as if it were a tool; the bare "unknown tool" refusal was
            // then classified as a capability gap (toolLimit) and spawned a ghost "extend the tool"
            // self-heal mission — the first domino in the autonomy flatline. When the name matches
            // a known builtin skill, teach the real interface so the model's NEXT step is the
            // correct read — and the failure classifier sees guidance, not absence.
            if let skillLocation = Self.builtinSkillLocations[name] {
                await audit("skill_called_as_tool", false)
                return await traced(
                    .failure("'\(name)' is a skill, not a tool. Read \(skillLocation) with read_file, then follow its instructions using the tools it names."),
                    argumentKeys: rawArgKeys, argumentsDigest: rawArgsDigest)
            }
            await audit("unknown_tool", false)
            BuilderTrustedTelemetry.recordTool(
                name: "unknown-tool", argumentsDigest: rawArgsDigest, success: false,
                elapsedMilliseconds: 1,
                workspaceRootIdentity: try? BuilderWorkspaceRootIdentity.capture(
                    rootPath: context.projectRoot))
            return await traced(.failure("unknown tool: \(name)"),
                                argumentKeys: rawArgKeys, argumentsDigest: rawArgsDigest)
        }
        let callerArguments = canonicalArguments(name: name, arguments: arguments)
        var effectiveArguments = callerArguments
        for (key, value) in hostArguments { effectiveArguments[key] = value }
        let (effectiveArgKeys, argsDigest) = AuditLog.digest(effectiveArguments)
        // Authorization scope (plan-only / needs-approval), skill capability scope, audit, secret-mask,
        // and the run are ALL the SHARED gate (ToolGate) now — the one enforcement site that composite
        // sub-actions also route through, so a research_run sub-action can't skip the action-class gate
        // (Codex HIGH). execute only owns the unknown-tool audit above. Forward the allow-list we ALREADY
        // read so the gate doesn't re-read it (one read drives both audits + the decision; DeepSeek LOW).
        let result = await ToolGate.run(name: name, arguments: effectiveArguments, context: context,
                                  precomputedAllowlist: .some(activeAllowlist), parameters: tool.parameters,
                                  validationArguments: callerArguments) {
            try await tool.execute(arguments: effectiveArguments, context: context)
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds &- telemetryStarted
        BuilderTrustedTelemetry.recordTool(
            name: name, argumentsDigest: argsDigest, success: result.success,
            elapsedMilliseconds: max(1, Int(elapsed / 1_000_000)),
            workspaceRootIdentity: try? BuilderWorkspaceRootIdentity.capture(
                rootPath: context.projectRoot))
        return await traced(result, argumentKeys: effectiveArgKeys, argumentsDigest: argsDigest)
    }

    /// The arguments a tool will ACTUALLY run for `arguments` (its `ToolArgumentCanonicalizing`
    /// view, else the input unchanged). Executors record these so fingerprints, durable receipts,
    /// replay recipes, and the gate digest all describe the same invocation (0.17.63: a sealed
    /// verifier substituted at execution time left the recipe holding the model's near miss, so the
    /// host replay's gate digest never matched and no final receipt could be minted).
    public func canonicalArguments(name: String, arguments: [String: Any]) -> [String: Any] {
        guard let tool = tool(named: name) as? any ToolArgumentCanonicalizing else { return arguments }
        return tool.canonicalizeToolArguments(arguments)
    }

    /// Epoch seconds without `Date()` ambiguity (kept simple + Sendable).
    private static func now() -> Double { Date().timeIntervalSince1970 }
}
