import Foundation

/// HARD delegation to a named specialist — kist's match for Claude Code's subagent spawn. Where the
/// soft path (`TaskPersonaMatcher.promptContext`) merely injects a specialist's instructions into the
/// MAIN turn, this runs the specialist in its OWN `HeadlessAgentLoop`: its own context window, its
/// `resolvedTools` (scoped, fail-closed), its `resolvedModel` (alias/inherit resolved), its `maxTurns`
/// cap, and its `permissionMode` (mapped to planMode + approval set by the caller). Only the final
/// summary returns — exactly the Claude subagent contract.
///
/// The SPAWN PLAN (which model/tools/turns/goal) is a pure value so it's unit-tested without a provider;
/// `run` is the thin shell that builds the loop from it.
public struct SpecialistSpawner: Sendable {

    /// The resolved, ready-to-run configuration for one specialist spawn. Pure over its inputs.
    public struct Plan: Equatable, Sendable {
        public let binding: ProviderBinding      // resolved model
        public let toolNames: [String]           // resolvedTools ∩ ceiling − denylist
        public let maxIterations: Int            // maxTurns or the default
        public let goal: String                  // persona-injected task
        public let planMode: Bool                // permissionMode plan ⇒ read-only
    }

    /// Compose the spawn plan. `ceiling` is the parent's tool universe; `aliasTable`/`roleDefault` resolve
    /// the model; `planMode` comes from the caller's permissionMode mapping. PURE + testable.
    public static func plan(specialist def: SpecialistDefinition, task: String, ceiling: [String],
                            aliasTable: [String: ProviderBinding], roleDefault: ProviderBinding?,
                            defaultMaxIterations: Int, planMode: Bool,
                            preloadedSkills: [(name: String, instructions: String)] = []) -> Plan {
        let binding = def.resolvedModel(aliasTable: aliasTable, roleDefault: roleDefault)
            ?? roleDefault ?? ProviderBinding(providerId: "")
        // `initialPrompt` is the specialist's opening instruction, prepended before the task (Claude parity).
        let opening = (def.initialPrompt?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : "\n\($0)\n" } ?? ""
        // `skills` preload: the full skill instructions are injected into context (Claude subagent parity).
        let skillsBlock = preloadedSkills.isEmpty ? "" :
            "\n\nPreloaded skills — follow these:\n" +
            preloadedSkills.map { "### \($0.name)\n\($0.instructions)" }.joined(separator: "\n\n")
        let goal = """
        You are the "\(def.name)" specialist. Follow these instructions for this task:
        \(def.systemPrompt)
        \(opening)\(skillsBlock)
        TASK:
        \(task)
        """
        return Plan(binding: binding,
                    toolNames: def.resolvedTools(ceiling: ceiling),
                    maxIterations: def.maxTurns ?? defaultMaxIterations,
                    goal: goal,
                    planMode: planMode)
    }

    /// `mcpServers` scoping (pure): when set, keep only MCP tools (`<server>__<tool>`) whose server is
    /// listed; non-MCP tools (no `__`) always pass; nil ⇒ inherit every tool. Narrows the ceiling so
    /// resolvedTools/scoping enforce it downstream.
    public static func mcpScopedCeiling(_ ceiling: [String], mcpServers: [String]?) -> [String] {
        guard let servers = mcpServers else { return ceiling }
        let allowed = Set(servers.map { $0.lowercased() })
        return ceiling.filter { name in
            guard ReversibilityClassifier.isMCPTool(name),
                  let server = name.components(separatedBy: MCPClientManager.namespaceSeparator).first
            else { return true }
            return allowed.contains(server.lowercased())
        }
    }

    // MARK: - run (impure shell)

    let providers: ProviderRegistry
    let baseTools: ToolRegistry
    let context: ToolContext
    let sink: RuntimeEventSink
    let interactor: RuntimeInteractor
    let aliasTable: [String: ProviderBinding]
    let roleDefault: ProviderBinding?
    let defaultMaxIterations: Int
    let extendedThinking: Bool
    let budget: BudgetLedger?

    public init(providers: ProviderRegistry, baseTools: ToolRegistry, context: ToolContext,
                sink: RuntimeEventSink = NullEventSink(),
                interactor: RuntimeInteractor = AutoApproveInteractor(),
                aliasTable: [String: ProviderBinding] = [:], roleDefault: ProviderBinding? = nil,
                defaultMaxIterations: Int = 50, extendedThinking: Bool = false, budget: BudgetLedger? = nil) {
        self.providers = providers
        self.baseTools = baseTools
        self.context = context
        self.sink = sink
        self.interactor = interactor
        self.aliasTable = aliasTable
        self.roleDefault = roleDefault
        self.defaultMaxIterations = defaultMaxIterations
        self.extendedThinking = extendedThinking
        self.budget = budget
    }

    /// Run a specialist as a subagent. `approvalTools` is the caller's permission set for this spawn
    /// (derived from the specialist's `permissionMode`); `planMode` likewise. `now` is the timestamp for the
    /// isolation-worktree label (injected for deterministic tests). Returns the loop outcome, with an
    /// isolation footer appended when `isolation: worktree` was requested.
    public func run(specialist def: SpecialistDefinition, task: String,
                    approvalTools: Set<String> = [], planMode: Bool = false,
                    now: Double = Date().timeIntervalSince1970) async -> HeadlessAgentLoop.Outcome {
        // `ask_user` is a communication primitive the loop can inject; put it IN the ceiling so the
        // specialist's allowlist/denylist governs it too. A `tools: []` specialist is then truly hermetic
        // (no ask_user); a nil allowlist inherits it; an author can allow/deny it explicitly.
        let ceiling = Self.mcpScopedCeiling(baseTools.all().map { $0.name } + ["ask_user"],
                                            mcpServers: def.mcpServers)
        // `skills` preload: fetch the named skills' full instructions to inject into the specialist's context.
        var preloaded: [(name: String, instructions: String)] = []
        if let want = def.skills, !want.isEmpty {
            let mgr = SkillManager.discover(projectRoot: context.projectRoot)
            // Bound the preload so a long skills list (or a huge skill) can't blow the opening context: cap
            // the count and the aggregate characters; clip an over-budget skill rather than drop it silently.
            let maxSkills = 8, maxTotalChars = 40_000
            var budget = maxTotalChars
            for n in want.prefix(maxSkills) {
                guard budget > 0, let s = mgr.allSkills.first(where: { $0.name == n }) else { continue }
                let body = s.instructions.count > budget ? String(s.instructions.prefix(budget)) + "\n… [skill clipped]" : s.instructions
                preloaded.append((n, body))
                budget -= min(s.instructions.count, budget)
            }
        }
        let p = Self.plan(specialist: def, task: task, ceiling: ceiling,
                          aliasTable: aliasTable, roleDefault: roleDefault,
                          defaultMaxIterations: defaultMaxIterations, planMode: planMode,
                          preloadedSkills: preloaded)
        let injectAskUser = p.toolNames.contains("ask_user")
        // The specialist NEVER gets spawn_specialist/spawn_agent (no recursive fan-out from a named agent)
        // and is scoped to its resolved tools — fail-closed: an empty list yields no tools. `ask_user` is a
        // loop-injected primitive (not in baseTools), so filter it out of the concrete scoping set.
        let scoped = baseTools.scoped(to: p.toolNames.filter { $0 != "ask_user" })

        // isolation: worktree — the specialist's edits land on an isolated branch, never the main tree.
        let wantsIsolation = def.isolation?.lowercased() == "worktree"
        var runContext = context
        var worktree: GitWorktree? = nil
        if wantsIsolation {
            worktree = GitIsolation.makeWorktree(repo: context.projectRoot, label: def.name, nowEpoch: now)
            // FAIL CLOSED (Codex CRITICAL): if isolation was requested but a worktree can't be created (not
            // a git repo, or `git worktree add` failed), REFUSE — do NOT silently run a write-capable
            // specialist against the main tree while the caller believes it was sandboxed.
            guard let wt = worktree else {
                return HeadlessAgentLoop.Outcome(
                    success: false,
                    summary: "isolation:worktree requested but no worktree could be created (not a git repo, or git failed). Refusing to run against the main tree.",
                    iterations: 0, checkpointId: "")
            }
            // Confine writes to the worktree root: without this, `run_command` absolute paths and main-rooted
            // service tools (memory/vectors) could still write OUTSIDE the worktree, defeating isolation. If
            // the caller already confines writes, keep theirs; else force a write-confining sandbox rooted at
            // the worktree. (Enforcement is Seatbelt on macOS; a platform without it is a known limitation.)
            let isoSandbox = context.sandbox.confineWrites ? context.sandbox
                                                           : SandboxPolicy.confined(denyNetwork: false, confineWrites: true)
            runContext = ToolContext(projectRoot: wt.path, shell: context.shell, sandbox: isoSandbox,
                                     externalReadRoots: context.externalReadRoots)
        }

        let loop = HeadlessAgentLoop(
            providers: providers, providerId: p.binding.providerId, model: p.binding.model,
            tools: scoped, context: runContext, sink: sink,
            interactor: interactor, approvalTools: approvalTools,
            planMode: p.planMode, injectAskUser: injectAskUser, maxIterations: p.maxIterations,
            extendedThinking: extendedThinking, budget: budget,
            contextWindow: ContextWindowManager.forModel(
                capabilities: providers.capabilities(providerId: p.binding.providerId, model: p.binding.model)))
        let outcome = await loop.run(goal: p.goal)

        guard let wt = worktree else { return outcome }
        let committed = GitIsolation.commit(wt, message: "specialist/\(def.name): \(task.prefix(60))")
        let changed = GitIsolation.committedChangedPaths(wt)
        if changed.isEmpty {
            GitIsolation.discard(wt)   // no changes ⇒ clean up the empty worktree + branch
            return withSummary(outcome, "\(outcome.summary)\n\n[isolated run made no changes — worktree discarded]")
        }
        let shown = changed.prefix(8).joined(separator: ", ") + (changed.count > 8 ? " …" : "")
        // Only advertise `git merge` when there's a real commit to merge; otherwise the work is uncommitted
        // in the worktree and merging the (empty) branch would be a no-op / confusing.
        let mergeHint = committed
            ? "  merge: git merge \(wt.branch)  ·  discard: git worktree remove --force \(wt.path) && git branch -D \(wt.branch)"
            : "  (changes are UNCOMMITTED in \(wt.path) — commit there before merging; or discard the worktree)"
        let footer = "[isolated in branch \(wt.branch) · \(changed.count) file(s) changed: \(shown)]\n\(mergeHint)"
        return withSummary(outcome, "\(outcome.summary)\n\n\(footer)")
    }

    private func withSummary(_ o: HeadlessAgentLoop.Outcome, _ s: String) -> HeadlessAgentLoop.Outcome {
        HeadlessAgentLoop.Outcome(success: o.success, summary: s, iterations: o.iterations, checkpointId: o.checkpointId)
    }
}
