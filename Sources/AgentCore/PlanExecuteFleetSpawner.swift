import Foundation

/// THE HETEROGENEOUS-FLEET SPAWN — wires Mythos's in-process cross-vendor `PlanExecuteLoop` as a fleet
/// worker. Each spawned agent runs a role-bound loop (planner/coder/critic = DIFFERENT vendors) rooted at
/// its own git worktree, executing its brief; the worker's deliverable is then committed and the
/// `.fleet-done` sentinel dropped, so the supervisor's Foreman can verify + sign it. This is the upgrade
/// over Claude-only `cu` subprocesses — the same supervised loop, now a real heterogeneous team.
///
/// Spawn-agnostic by construction: it just produces an `AgentSpawner` the orchestrator/supervisor consume
/// without knowing HOW the worker runs. The PlanExecuteLoop is built fresh per worktree (its own
/// `ToolContext` rooted at the worktree path); the tools + providers + role bindings are shared.
///
/// SAFETY: each agent is confined to its worktree (sandbox + project-root confinement); shell is enabled
/// so the agent can run its tests + commit, but only inside its worktree; the loop runs unattended
/// (auto-approve) — its output is NEVER trusted, the Foreman's signoff is. Stage 2 (last mile). PROTOTYPE.
public enum PlanExecuteFleetSpawner {

    /// Build a fleet spawner that runs a role-bound `PlanExecuteLoop` per worktree.
    ///
    /// - Parameters:
    ///   - providers: the provider registry (all vendors).
    ///   - roles:     the role→vendor bindings (planner/coder/critic) — the heterogeneous team.
    ///   - tools:     the worker's tool set (built once; context-agnostic, the loop passes per-worktree context).
    ///   - shell:     shell policy for the worker (default ENABLED so it can commit + run tests in its worktree).
    ///   - sandbox:   sandbox policy (default confined to the worktree).
    ///   - maxPlanRepairs/maxReplans/verifyGoal: passed to the loop.
    ///   - autoCommit: after the loop, commit the worktree on the agent's behalf (belt + suspenders — the
    ///                 brief also asks the agent to commit; a no-op if it already did). The Foreman needs a
    ///                 commit to verify a deliverable.
    public static func make(
        providers: ProviderRegistry,
        roles: RoleBindings,
        tools: ToolRegistry,
        // `deny` defaults to ShellPolicy.defaultDeny (= baseDeny + hostControlDeny) → host-control (osascript,
        // screencapture, …) is DENIED by default here; only the top-level ARMED KistRunner path opts out to baseDeny.
        shell: ShellPolicy = ShellPolicy(enabled: true, autoApprove: true),
        sandbox: SandboxPolicy = .confined(),
        maxPlanRepairs: Int = 2,
        maxReplans: Int = 2,
        verifyGoal: Bool = true,
        autoCommit: Bool = true,
        budget: BudgetLedger? = nil,
        audit: Bool = true,
        // The user's --allow-read grant (read-only, fail-closed) — propagated so fleet workers
        // don't silently lose read access the top-level session has, which previously made the
        // denial steer give FALSE advice ("relaunch with --allow-read" when the user already had).
        externalReadRoots: [String] = []
    ) -> InProcessAgentSpawner {
        // The SAME ledger is captured by the closure, so EVERY fleet agent draws from one global cap —
        // closing the hole the council flagged (the fleet path doesn't go through makeLoop, so without
        // this every parallel worker was uncapped — runaway spend where it matters most).
        InProcessAgentSpawner { task, worktree in
            // Per-worktree audit trail so fleet workers' tool calls are recorded too (Codex HIGH —
            // the fleet path doesn't go through the CLI context, so audit must be wired here).
            let context = ToolContext(projectRoot: worktree.path, shell: shell, sandbox: sandbox,
                                      externalReadRoots: externalReadRoots)
                .withAuditLog(audit ? AuditLog.forProject(root: worktree.path) : nil)
            let loop = PlanExecuteLoop(
                providers: providers, roles: roles, tools: tools, context: context,
                interactor: AutoApproveInteractor(), requireApproval: false,
                maxPlanRepairs: maxPlanRepairs, maxReplans: maxReplans, verifyGoal: verifyGoal,
                budget: budget)
            let outcome = await loop.run(goal: task)
            if autoCommit {
                _ = GitIsolation.commit(worktree, message: "fleet: " + String(outcome.message.prefix(60)))
            }
            // The summary the InProcessAgentSpawner writes into `.fleet-done` (advisory — the Foreman, not
            // this string, decides whether the work is real).
            return outcome.success ? "agent completed: \(outcome.message)" : "agent did not finish: \(outcome.message)"
        }
    }

    /// Build a fleet spawner that honors the Captain's per-task model assignments.
    public static func makeAssigned(
        providers: ProviderRegistry,
        defaultRoles: RoleBindings,
        tools: ToolRegistry,
        // `deny` defaults to ShellPolicy.defaultDeny (= baseDeny + hostControlDeny) → host-control (osascript,
        // screencapture, …) is DENIED by default here; only the top-level ARMED KistRunner path opts out to baseDeny.
        shell: ShellPolicy = ShellPolicy(enabled: true, autoApprove: true),
        sandbox: SandboxPolicy = .confined(),
        maxPlanRepairs: Int = 2,
        maxReplans: Int = 2,
        verifyGoal: Bool = true,
        autoCommit: Bool = true,
        budget: BudgetLedger? = nil,
        externalReadRoots: [String] = []
    ) -> AssignedPlanExecuteSpawner {
        AssignedPlanExecuteSpawner(providers: providers, defaultRoles: defaultRoles, tools: tools,
                                   shell: shell, sandbox: sandbox,
                                   maxPlanRepairs: maxPlanRepairs, maxReplans: maxReplans,
                                   verifyGoal: verifyGoal, autoCommit: autoCommit, budget: budget,
                                   externalReadRoots: externalReadRoots)
    }

    public struct AssignedPlanExecuteSpawner: AssignedAgentSpawner {
        let providers: ProviderRegistry
        let defaultRoles: RoleBindings
        let tools: ToolRegistry
        let shell: ShellPolicy
        let sandbox: SandboxPolicy
        let maxPlanRepairs: Int
        let maxReplans: Int
        let verifyGoal: Bool
        let autoCommit: Bool
        let budget: BudgetLedger?
        let externalReadRoots: [String]

        public func spawn(task: String, worktree: GitWorktree) async -> Bool {
            Task.detached(priority: .userInitiated) {
                let summary = await runWorker(task: task, worktree: worktree, providers: providers,
                                              roles: defaultRoles, tools: tools, shell: shell, sandbox: sandbox,
                                              maxPlanRepairs: maxPlanRepairs, maxReplans: maxReplans,
                                              verifyGoal: verifyGoal, autoCommit: autoCommit, budget: budget,
                                              externalReadRoots: externalReadRoots)
                FleetSentinel.markDone(inWorktree: worktree.path, summary: summary)
            }
            return true
        }

        public func spawn(task: String, worktree: GitWorktree, assignment: ModelAssignmentDecision) async -> Bool {
            Task.detached(priority: .userInitiated) {
                let summary = await runWorker(task: task, worktree: worktree, providers: providers,
                                              roles: assignment.roles, tools: tools, shell: shell, sandbox: sandbox,
                                              maxPlanRepairs: maxPlanRepairs, maxReplans: maxReplans,
                                              verifyGoal: verifyGoal, autoCommit: autoCommit, budget: budget,
                                              externalReadRoots: externalReadRoots)
                FleetSentinel.markDone(inWorktree: worktree.path, summary: summary)
            }
            return true
        }
    }

    private static func runWorker(task: String, worktree: GitWorktree,
                                  providers: ProviderRegistry, roles: RoleBindings, tools: ToolRegistry,
                                  shell: ShellPolicy, sandbox: SandboxPolicy,
                                  maxPlanRepairs: Int, maxReplans: Int, verifyGoal: Bool,
                                  autoCommit: Bool, budget: BudgetLedger?,
                                  externalReadRoots: [String] = []) async -> String {
        let context = ToolContext(projectRoot: worktree.path, shell: shell, sandbox: sandbox,
                                  externalReadRoots: externalReadRoots)
        let loop = PlanExecuteLoop(
            providers: providers, roles: roles, tools: tools, context: context,
            interactor: AutoApproveInteractor(), requireApproval: false,
            maxPlanRepairs: maxPlanRepairs, maxReplans: maxReplans, verifyGoal: verifyGoal,
            budget: budget)
        let outcome = await loop.run(goal: task)
        if autoCommit {
            _ = GitIsolation.commit(worktree, message: "fleet: " + String(outcome.message.prefix(60)))
        }
        // Advisory only: the Foreman, not this string, decides whether the work is real.
        return outcome.success ? "agent completed: \(outcome.message)" : "agent did not finish: \(outcome.message)"
    }
}
