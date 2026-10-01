import Foundation

// Extracted from HeadlessAgentLoop; shared ToolAuthority behavior for both protocols.
extension HeadlessAgentLoop {
    // MARK: - Shared helpers

    /// In plan mode, block any tool that isn't read-only and return the steering message to feed
    /// back (nil = allowed). Keeps the agent investigating + proposing rather than executing.
    /// Read-only `tasks` subactions (viewing/validating the board) never mutate plan.json, so they are
    /// safe in plan mode even though the `tasks` tool as a whole is a writer. Kept in sync with
    /// ManageTasksTool: `list`, `validate`, `check`, and the default (no action == list).
    static let readOnlyTaskActions: Set<String> = ["list", "map", "validate", "check"]

    /// Pure, testable: a `tasks` call that only READS the board (safe in plan mode). A plan-mode agent
    /// must be able to READ the shared board to ground its proposal; only board WRITES (add/start/done/
    /// block/update/evidence/clear) stay blocked. Default (no action) is `list` — a read. Mirrors
    /// ManageTasksTool.execute's action normalization exactly.
    static func isReadOnlyTasksCall(tool: String, args: [String: Any]) -> Bool {
        guard tool == "tasks" else { return false }
        let action = (args["action"] as? String ?? "list").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return readOnlyTaskActions.contains(action)
    }

    static func isReadOnlyBrowserCall(tool: String, args: [String: Any]) -> Bool {
        guard tool == "browse" else { return false }
        guard let actions = args["actions"] else { return true }
        return (actions as? [Any])?.isEmpty == true
    }

    static func isTrustedReadOnlyCall(registry: ToolRegistry, tool: String,
                                      args: [String: Any]) -> Bool {
        guard let implementation = registry.tool(named: tool) else { return false }
        if implementation is any ReadOnlyAgentTool { return true }
        // Owner-declared read-only remote MCP tools (per-server `toolEffects` config): the registry
        // filter admits them into inspect-only turns, so the call-time effect contract must agree —
        // otherwise the tool is visible but every call is denied (bio-scientist audit, 2026-09-18).
        if Self.hostDeclaredReadOnly(implementation) { return true }
        if implementation is ManageTasksTool {
            return isReadOnlyTasksCall(tool: tool, args: args)
        }
        if implementation is DecisionTool {
            return ["list", "get", "run"].contains(args["action"] as? String ?? "")
        }
        if implementation is BrowserTool {
            return isReadOnlyBrowserCall(tool: tool, args: args)
        }
        return false
    }

    static func isTrustedDelegationCall(registry: ToolRegistry, tool: String) -> Bool {
        registry.tool(named: tool) is any DelegationAgentTool
    }

    /// On a delegation turn, the host-owned grant replaces the model-authored child task and pins the
    /// child intent. The model may still select a role/provider/specialist, but it cannot rewrite scope.
    static func delegationBoundInvocation(registry: ToolRegistry,
                                                  intent: TaskBrief.Intent?,
                                                  grant: DelegationGrant?,
                                                  tool: String,
                                                  arguments: [String: Any])
        -> (arguments: [String: Any], hostArguments: [String: Any]) {
        guard intent == .delegate,
              let grant,
              let implementation = registry.tool(named: tool),
              implementation is SpawnAgentTool || implementation is SpawnSpecialistTool else {
            return (arguments, [:])
        }
        var bounded = arguments
        bounded["task"] = grant.task
        var hostArguments: [String: Any] = [
            DelegationGrant.childIntentArgument: grant.childIntent.rawValue,
        ]
        if let summary = grant.priorResultContext?.substantiveSummary {
            hostArguments[DelegationGrant.priorSummaryArgument] = summary
        }
        if let artifacts = grant.priorResultContext?.artifactReferences, !artifacts.isEmpty {
            hostArguments[DelegationGrant.priorArtifactsArgument] = artifacts
        }
        return (bounded, hostArguments)
    }

    func effectContractBlock(registry: ToolRegistry, intent: TaskBrief.Intent?,
                                     delegationGrant: DelegationGrant? = nil,
                                     ownedDelegationHandles: Set<String> = [],
                                     tool: String, args: [String: Any]) -> String? {
        let safeRead = Self.isTrustedReadOnlyCall(registry: registry, tool: tool, args: args)
        if intent == .delegate {
            let delegation = Self.isTrustedDelegationCall(registry: registry, tool: tool)
            if delegation,
               (registry.tool(named: tool) is SpawnAgentTool
                    || registry.tool(named: tool) is SpawnSpecialistTool),
               delegationGrant == nil {
                return "Policy denied \(tool): this delegation turn has no host-bound child grant. Ask for a self-contained delegated task."
            }
            if registry.tool(named: tool) is JoinDelegationTool
                || registry.tool(named: tool) is CancelDelegationTool
                || registry.tool(named: tool) is SteerDelegationTool {
                guard let handle = args["handle"] as? String,
                      ownedDelegationHandles.contains(handle) else {
                    return "Policy denied \(tool): the handle was not created by this delegation turn."
                }
            }
            if registry.tool(named: tool) is SteerDelegationTool {
                return "Policy denied \(tool): a host-bound delegated task cannot be rewritten by model-authored steering. Cancel and request a new explicit delegation instead."
            }
            if !safeRead && !delegation {
                return "Policy denied \(tool): delegation authority permits inspection and trusted spawn/join controls, not parent-local mutation."
            }
        } else if let intent, !intent.expectsMutation, intent != .desktop, !safeRead {
            return "Policy denied \(tool): this is a read-only \(intent.rawValue) turn. "
                + "Choose an inspection tool or finish without mutation."
        }
        return planModeBlock(registry: registry, tool: tool, args: args)
    }

    static func recordOwnedDelegationHandle(registry: ToolRegistry, tool: String,
                                                     result: ToolResult,
                                                     checkpoint: inout LoopCheckpoint) {
        guard result.success,
              result.metadata["delegation_status"] == "running",
              let handle = result.metadata["delegation_handle"], !handle.isEmpty,
              let implementation = registry.tool(named: tool),
              implementation is SpawnAgentTool || implementation is SpawnSpecialistTool else { return }
        var handles = Set(checkpoint.delegationHandles ?? [])
        handles.insert(handle)
        checkpoint.delegationHandles = handles.sorted()
    }

    func planModeBlock(registry: ToolRegistry, tool: String,
                               args: [String: Any] = [:]) -> String? {
        guard planMode, !Self.isTrustedReadOnlyCall(
            registry: registry, tool: tool, args: args) else { return nil }
        return "PLAN MODE is ON — \"\(tool)\" would modify state, so it was NOT run. Only read/search " +
            "tools are allowed (\(Self.conversationalReadOnlyTools.sorted().joined(separator: ", "))). Investigate further, " +
            "using read_file, context_brain, search_code, list_files, or glob_files; do NOT retry blocked " +
            "tools in plan mode. Or finish with done:true and present your step-by-step PLAN as the summary. " +
            "The user reviews the plan and turns plan mode off before anything is executed."
    }

    /// Fire PreToolUse hooks; returns a steering message if a hook BLOCKED the action (nil = allowed).
    func preHookBlock(tool: String, args: [String: Any]) async -> String? {
        guard let hooks else { return nil }
        let decision = await hooks.firePreToolUse(tool: tool, arguments: args)
        guard decision.blocked else { return nil }
        return "A PreToolUse hook BLOCKED \"\(tool)\": \(decision.reason ?? "no reason given"). " +
            "Do NOT retry it — choose a different approach or finish with done."
    }

    /// Fire PostToolUse hooks (observe only — the side effect already happened).
    func firePostHook(tool: String, args: [String: Any], success: Bool, output: String) async {
        guard let hooks else { return }
        await hooks.firePostToolUse(tool: tool, arguments: args, success: success, output: output)
    }

    /// Fire Stop hooks when the run reaches a terminal state.
    func fireStopHook(summary: String, success: Bool) async {
        guard let hooks else { return }
        await hooks.fireStop(summary: summary, success: success)
    }

    /// Ask for approval if the tool is sensitive (both loops).
    func approve(tool: String, args: [String: Any], context: ToolContext) async -> Bool {
        if let reason = context.authorizationScope?.requiresExplicitApproval(tool: tool, arguments: args) {
            let desc = "AUTHORIZATION SCOPE — \(tool)(\(Self.compactArgs(args))): \(reason)"
            sink.emit(.awaitingApproval(planSummary: desc))
            return await interactor.requestApproval(planSummary: desc, dangerous: true)
        }
        // ACT-vs-ASK: classify the action's reversibility. `.safe` never prompts; `.dangerous`
        // (irreversible/high-blast-radius) ALWAYS prompts — even when the tool isn't in the configured
        // approval set and even past a session "allow all"; `.mutating` follows the normal approval set.
        let risk = ReversibilityClassifier.assess(
            tool: tool, args: args, projectRoot: context.projectRoot,
            hostDeclaredReadOnly: Self.hostDeclaredReadOnly(tools.tool(named: tool)))
        if risk == .safe { return true }
        guard risk == .dangerous || approvalTools.contains(tool) else { return true }
        let desc = (risk == .dangerous ? "⚠ IRREVERSIBLE — " : "") + "\(tool)(\(Self.compactArgs(args)))"
        sink.emit(.awaitingApproval(planSummary: desc))
        return await interactor.requestApproval(planSummary: desc, dangerous: risk == .dangerous)
    }


}
