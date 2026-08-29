import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Fleet (parallel worktree agents) entry point — extracted from KistRunner.swift to keep the core orchestration file under the
// size limit. Part of `enum KistRunner`.
extension KistRunner {
    /// Decompose the goal → disjoint subtasks → launch one agent per subtask in its own worktree →
    /// supervise to a forge-proof signoff → join the signed in-lease branches onto a fresh integration
    /// branch (NEVER main). Running this IS the explicit arming; it is bounded and confined.
    static func runFleet(_ opts: KistOptions, registry: ProviderRegistry, root: String,
                                 tools: ToolRegistry, providerId: String, model: String?,
                                 rolesOverride: RoleBindings? = nil) async -> Int32 {
        guard GitIsolation.isGitRepo(root) else {
            err("error: --fleet needs a git repo at \(root) (isolated branches). Nothing launched."); return 2
        }
        // Build the role team (planner/coder/critic = different vendors), reusing the provider catalog.
        guard let roles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }

        let goal = opts.goal ?? ""
        let agents = max(1, opts.agents)
        note("kist · fleet · \(roles.summary) · \(root)\(roles.isHeterogeneous ? " · team" : "") · ≤\(agents) agents")

        // CAPTAIN SAFETY GATES (preserved across the origin/main merge): the domain-learning gate then the
        // simulation gate must BOTH accept the plan before any side effect. Pinned by KistRunnerSafetyTests
        // (preflight-before-side-effects). Fail-closed — a gate that doesn't accept refuses the launch.
        let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .fleet,
                                                                      objective: goal,
                                                                      projectRoot: root,
                                                                      evidenceMode: opts.noMemory ? .redacted : .full)
        for line in domainPreflight.terminalLines { note(line) }
        guard domainPreflight.canExecute else {
            err("captain refused to launch: domain-learning gate did not accept this fleet plan.")
            return 1
        }
        let preflight = CaptainSimulationEnforcer.preflight(mode: .fleet,
                                                            objective: goal,
                                                            projectRoot: root,
                                                            evidenceMode: opts.noMemory ? .redacted : .full,
                                                            noMemory: opts.noMemory)
        for line in preflight.terminalLines { note(line) }
        guard preflight.canExecute else {
            err("captain refused to launch: simulation gate did not accept this fleet plan.")
            return 1
        }

        // ONE ledger shared by the planner AND every fleet agent → a single global cap across the
        // whole parallel fleet, planning included (the fleet path doesn't go through makeLoop, so this
        // is where --budget reaches it). Created BEFORE planning so the planner call counts too.
        let fleetBudget = opts.makeBudget()

        // 1. DECOMPOSE — the planner vendor proposes disjoint subtasks from the repo's real dir tree.
        let scopeContext = CaptainOrchestrator.deriveScopeContext(fromFiles: GitIsolation.trackedFiles(repo: root)).snapshot
        let subtasks = await FleetPlanner(providers: registry, binding: roles.binding(for: .planner))
            .plan(goal: goal, scopeContext: scopeContext, maxAgents: agents, budget: fleetBudget)
        guard !subtasks.isEmpty else { err("the planner returned no subtasks for that goal."); return 1 }
        note("planned \(subtasks.count) subtask(s): " + subtasks.map(\.title).joined(separator: ", "))

        // 2. LAUNCH — one heterogeneous in-process agent per subtask, each in its own worktree.
        let fleetRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mythos/fleet", isDirectory: true)
        let spawner = PlanExecuteFleetSpawner.make(providers: registry, roles: roles, tools: tools,
                                                   budget: fleetBudget,
                                                   externalReadRoots: opts.allowReadPaths)
        let orch = CaptainOrchestrator(spawner: spawner)
        let launch = await orch.launchFleet(goal: goal, repo: root, subtasks: subtasks, maxAgents: agents,
                                            baseDir: fleetRoot, nowEpoch: Date().timeIntervalSince1970)
        for issue in launch.scopeIssues { note("scope · \(issue)") }
        note(launch.summary)
        guard launch.launchedCount > 0 else { return 1 }

        // 3. SUPERVISE — verify each agent's REAL committed work + seal a forge-proof signoff.
        let goalID = launch.fleetID.uuidString
        let board = FleetBlackboardStore(fleetID: launch.fleetID, baseDir: fleetRoot)
        let inbox = FleetUpdateInbox(fleetID: launch.fleetID, baseDir: fleetRoot)
        let ledger = FleetSignoffLedger(baseDir: launch.fleetDir.appendingPathComponent("signoff"))
        let batons = FleetBatonStore(baseDir: launch.fleetDir)
        // MANDATORY LEASE for a multi-agent fleet (Codex HIGH): when >1 agent runs in parallel, an empty
        // lease means the planner's scope was cleared (a collision/hallucination the validator dropped) —
        // such an agent can't be proven disjoint from its crew, so the Foreman REFUSES to sign it
        // (done_needs_lease) rather than laundering it as "no lease ⇒ no escapes ⇒ auto-mergeable". A
        // single-agent fleet has nothing to be disjoint from, so a lease isn't required there.
        // Verifier trust: default OFF ⇒ only a held-out operator oracle (~/.kist/test-command) verifies;
        // a fleet with no oracle fails closed (never a false green). --trust-worktree-tests opts into the
        // in-repo harness tier for your OWN honest agents (a shell harness can transitively run agent code).
        let foreman = Foreman(ledger: ledger, leaseRequired: subtasks.count > 1,
                              claimsRequired: true, acceptanceTestRequired: true,
                              allowWorktreeHarness: opts.trustWorktreeTests)
        let supervisor = FleetSupervisor(board: board, inbox: inbox, ledger: ledger, batons: batons, foreman: foreman)
        let result = await supervisor.supervise(goalID: goalID)
        note(result.summary)

        // COCKPIT (Terminal Captain integration): the whole-picture view — per-agent status, lease,
        // signoff, and HONEST merge-fate (derived from the same trustworthy ledger + rule as the merge
        // gate, so it can never show "merges" for a branch the gate would refuse).
        if let snapshot = board.currentBoard() {
            let chainIntact = ledger.all().isEmpty || !ledger.entries.isEmpty
            note(FleetCockpitModel.picture(goal: snapshot.goal, cells: snapshot.cells,
                                           trustworthyEntries: ledger.entries, chainIntact: chainIntact).render())
        }

        guard result.allSigned else {
            note("merge · skipped — fleet was partial; signed branches remain isolated for review.")
            note("No integration branch was created. Mythos never writes main.")
            return 1
        }

        // 4. MERGE GATE — join ONLY the signed, in-lease branches onto a fresh integration branch (never main).
        let merge = supervisor.joinSignedBranches(goalID: goalID, base: "HEAD")
        note("merge · \(String(describing: merge))")
        switch merge {
        case .merged:
            note("Review the integration branch, then promote it yourself — Mythos never writes main.")
            // The strongest verification we have: every branch reached a forge-proof signoff and joined.
            // Record a PROVEN lesson sourced to the fleet's signoff ledger.
            if !opts.noMemory {
                LessonStore().record(Lesson(kind: .proven,
                    text: "fleet built + verified (\(subtasks.count) agents): \(goal.prefix(110))",
                    source: "fleet-signoff:\(goalID)", at: Date().timeIntervalSince1970))
            }
            return 0
        case .alreadyIntegrated:
            // With a fleetID-unique integration branch this should be unreachable; if it ever fires, the
            // fresh fleet's branches were NOT joined — report honestly, never as success (Codex HIGH).
            note("merge · an integration branch unexpectedly already existed — this fleet's branches were NOT joined. Review manually.")
            return 1
        case .nothingToMerge:
            note("No integration branch was created because no signed in-lease branches were mergeable.")
            return 1
        case .conflict, .failed:
            note("No successful integration branch was created. Mythos never writes main.")
            return 1
        }
    }

    // MARK: - Plan→execute (typed DAG built by the role team)

    static func briefContext(memoryContext: String?, roles: RoleBindings,
                                     lessons: String? = nil, specialists: String? = nil,
                                     reviewTargets: String? = nil) -> String? {
        var parts = ["CURRENT AI TEAM: \(roles.summary)"]
        // Operator-owned project memory FIRST — it is the highest-value durable context and must NOT
        // be truncated off the end by the projectContext length cap (that bug dropped it in real runs
        // where persona+lessons filled the budget). Legacy Cortex Markdown never reaches this seam.
        if let memoryContext, !memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(memoryContext)
        }
        if let specialists, !specialists.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(specialists)                    // task-matched professional persona(s), advisory
        }
        if let reviewTargets, !reviewTargets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(reviewTargets)                  // deterministic changed-file manifest for reviews
        }
        if let lessons, !lessons.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(lessons)                         // advisory lessons from past runs (P3 memory)
        }
        return parts.joined(separator: "\n\n")
    }

}
