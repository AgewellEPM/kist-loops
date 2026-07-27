import Foundation
import AgentCore

/// The `--evolve` command — a boxed, open-ended DGM self-improvement loop. Extracted from KistRunner
/// (RED-zone) into its own file: it runs GENERATIONS of candidate batches, each candidate bred from an
/// archive-sampled parent (open-ended, not greedy), benchmarked in an isolated worktree, and appended to
/// the archive so the NEXT generation breeds from the grown archive. NEVER auto-promotes a winner —
/// humans review the kept branches/worktrees.
extension KistRunner {

    /// `--evolve-status`: render the evolution archive (best, blocked-conscience count, and the open-ended
    /// frontier of who the DGM would breed next) so a human can review the isolated candidate branches.
    /// Read-only; never touches git or spawns anything. Exit 0 (informational).
    static func runEvolutionStatus(root: String) -> Int32 {
        let archive = EvolutionArchiveStore(root: root)
        print(EvolutionStatusReport.render(records: archive.records()))
        return 0
    }

    /// `--evolve-tree`: render the ancestry forest + best-score-per-generation trajectory (is the lineage
    /// climbing?). Read-only; dispatched early like --evolve-status. Exit 0.
    static func runEvolutionTree(root: String) -> Int32 {
        let archive = EvolutionArchiveStore(root: root)
        print(EvolutionLineage.render(records: archive.records()))
        return 0
    }

    // MARK: - Cross-session autopilot (armed by a human, run by cron; fail-closed)

    /// `--evolve-arm --budget <tokens> --max-sessions N [--arm-hours H] [--generations G] "<objective>"`:
    /// the EXPLICIT human authorization for autonomous evolution. Writes bounded arming; nothing runs yet.
    static func runEvolveArm(_ opts: KistOptions, root: String) -> Int32 {
        guard let objective = opts.goal, !objective.trimmingCharacters(in: .whitespaces).isEmpty else {
            err("error: --evolve-arm needs an objective: kist --evolve-arm --budget <tokens> --max-sessions <N> \"<objective>\"")
            return 2
        }
        guard let budget = opts.budgetTokens, budget > 0 else {
            err("error: --evolve-arm requires a cumulative token budget (--budget <tokens>) — the hard ceiling for ALL sessions.")
            return 2
        }
        guard GitIsolation.isGitRepo(root) else {
            err("error: --evolve needs a git repo at \(root). Nothing armed."); return 2
        }
        let now = Date().timeIntervalSince1970
        let arming = EvolutionArming(objective: objective, cumulativeBudgetTokens: budget,
                                     maxSessions: opts.maxSessions, expiresAtEpoch: now + Double(opts.armHours) * 3600,
                                     armedAtEpoch: now, generationsPerSession: min(max(1, opts.generations), 20),
                                     stagnationPatience: opts.evolvePatience)
        guard EvolutionAutopilotStore(root: root).arm(arming) else {
            err("error: could not write the arming file under \(root)/.mythos/evolution"); return 2
        }
        note("✓ ARMED autonomous evolution — objective: \(objective)")
        note("  ceiling: \(budget) tokens total · \(opts.maxSessions) sessions max · \(arming.generationsPerSession) generation(s)/session")
        note("  expires in \(opts.armHours)h · stagnation patience: \(opts.evolvePatience == 0 ? "off" : String(opts.evolvePatience))")
        note("  schedule `kist --evolve-session` (e.g. hourly cron). It runs bounded rounds and STOPS itself")
        note("  at the budget/session/expiry/stagnation limits. NEVER writes main or auto-promotes. `--evolve-disarm` to stop.")
        return 0
    }

    /// `--evolve-disarm`: revoke authorization → back to the fail-closed default. Run-state is preserved.
    static func runEvolveDisarm(root: String) -> Int32 {
        guard EvolutionAutopilotStore(root: root).disarm() else {
            err("error: could not remove the arming file"); return 2
        }
        note("✓ DISARMED — autonomous evolution is off (fail-closed). Cumulative run-state preserved for review.")
        return 0
    }

    /// `--evolve-session`: the CRON entry. Runs exactly ONE bounded session IF armed & within all limits;
    /// otherwise prints the refusal reason and exits cleanly. Fail-closed: no arming ⇒ nothing spawns.
    static func runEvolveSession(_ opts: KistOptions, registry: ProviderRegistry, root: String,
                                 tools: ToolRegistry, context: ToolContext,
                                 providerId: String, model: String?) async -> Int32 {
        let store = EvolutionAutopilotStore(root: root)
        // (1) EXCLUSIVE interprocess lock for the WHOLE read-decide-run-write cycle — two overlapping cron
        // invocations must never both run (that would double-spend past the ceiling). Held until return.
        guard let lockFD = store.acquireSessionLock() else {
            note("evolve-session · declined · another session is already running (lock held)")
            return 0
        }
        defer { store.releaseSessionLock(lockFD) }

        // (2) Fail CLOSED on a corrupt state file: missing ⇒ fresh (fine); present-but-undecodable ⇒ refuse
        // (defaulting to zero would silently reset the cumulative budget).
        guard let state = store.stateOrNil() else {
            note("evolve-session · declined · run-state present but unreadable/corrupt — refusing (re-arm to reset after investigating)")
            return 0
        }
        // Decision is made UNDER the lock, on freshly-read arming+state (no TOCTTOU).
        let arming = store.arming()
        let now = Date().timeIntervalSince1970
        // Per-session cap: explicit --budget, else FAIRLY apportion the REMAINING budget over the sessions
        // LEFT (not a fixed even slice), so late sessions aren't starved. Clamped to remaining in decide().
        let perSessionCap = opts.budgetTokens ?? arming.map { a in
            let remaining = max(0, a.cumulativeBudgetTokens - state.tokensSpent)
            return max(1, remaining / max(1, a.maxSessions - state.sessionsRun))
        } ?? 0
        let decision = EvolutionRunController.decide(arming: arming, state: state, nowEpoch: now,
                                                     perSessionBudgetCap: perSessionCap)
        guard decision.shouldRun, let arming else {
            note("evolve-session · declined · \(decision.reason)")
            return 0   // clean decline — cron-friendly, not an error
        }
        note("evolve-session · \(decision.reason)")

        // Session opts: objective + generations come from the ARMING (not the CLI); budget is the injected
        // per-session ledger so we can measure spend; per-generation patience off (global stagnation is
        // tracked across SESSIONS, not within one).
        var sessionOpts = opts
        sessionOpts.goal = arming.objective
        sessionOpts.generations = arming.generationsPerSession
        sessionOpts.evolvePatience = 0
        sessionOpts.budgetTokens = decision.sessionBudgetTokens
        let ledger = BudgetLedger(maxTokens: decision.sessionBudgetTokens)
        _ = await runEvolution(sessionOpts, registry: registry, root: root, tools: tools, context: context,
                               providerId: providerId, model: model, budgetOverride: ledger)

        let spent = await ledger.spentTokens()
        let archiveBest = EvolutionRunProgress.bestPassingScore(EvolutionArchiveStore(root: root).records())
        // (3) End time (captured AFTER the run) for accurate expiry/last-session accounting.
        let endNow = Date().timeIntervalSince1970
        let newState = state.recording(tokensSpentThisSession: spent, newBestScore: archiveBest, nowEpoch: endNow)
        // (4) Persistence failure is FAIL-CLOSED: if we can't record the spend, the next cron would see
        // stale counters and overspend — so DISARM and exit non-zero to force human attention.
        guard store.save(state: newState) else {
            err("evolve-session · CRITICAL · spent \(spent) tokens but could NOT persist run-state — DISARMING to fail closed. Investigate \(root)/.mythos/evolution/")
            _ = store.disarm()
            return 2
        }
        note("evolve-session · done · spent \(spent) (cumulative \(newState.tokensSpent)/\(arming.cumulativeBudgetTokens)) · sessions \(newState.sessionsRun)/\(arming.maxSessions) · best-ever \(newState.bestEverScore.map(String.init) ?? "none")\(newState.consecutiveStagnantSessions > 0 ? " · stagnant \(newState.consecutiveStagnantSessions)" : "")")
        return 0
    }

    static func runEvolution(_ opts: KistOptions, registry: ProviderRegistry, root: String,
                             tools: ToolRegistry, context: ToolContext,
                             providerId: String, model: String?,
                             budgetOverride: BudgetLedger? = nil) async -> Int32 {
        guard GitIsolation.isGitRepo(root) else {
            err("error: --evolve needs a git repo at \(root) (isolated candidate branches). Nothing launched."); return 2
        }
        guard let roles = resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }

        let objective = opts.goal ?? ""
        let variantCount = min(max(1, opts.variants), 10)
        let generations = min(max(1, opts.generations), 20)
        let patience = opts.evolvePatience
        let benchmarkCommands = opts.evolveBenchmarkCommands.isEmpty
            ? EvolutionBenchmarkRunner.defaultCommands(repoRoot: root)
            : opts.evolveBenchmarkCommands
        let policy = EvolutionPolicy(requiredBenchmarkCommands: benchmarkCommands)
        let archive = EvolutionArchiveStore(root: root)
        let runID = String(UUID().uuidString.prefix(8))
        let blockedEvolutionTools: Set<String> = ["computer_control", "spawn_agent"]
        let safeTools = ToolRegistry(tools.all().filter { !blockedEvolutionTools.contains($0.name) })
        let singleGeneration = generations == 1 && patience == 0

        if singleGeneration {
            note("kist · evolve · \(roles.summary) · \(root) · \(variantCount) candidate(s)")
        } else {
            note("kist · evolve · \(roles.summary) · \(root)")
            note("plan · \(generations) generation(s) × \(variantCount) candidate(s)\(patience > 0 ? " · early-stop after \(patience) stagnant gen(s)" : "")")
        }
        note("benchmarks · " + benchmarkCommands.joined(separator: " && "))
        note("archive · \(archive.archiveURL.path)")

        // ONE ledger shared across ALL generations & variants — `--budget X` caps the WHOLE open-ended run,
        // not each candidate (a fresh ledger per candidate would silently allow N×X total spend).
        let evolveBudget = budgetOverride ?? opts.budgetTokens.map { BudgetLedger(maxTokens: $0) }

        var allRecords: [EvolutionCandidateRecord] = []
        var bestPassing = EvolutionRunProgress.bestPassingScore(archive.records())   // seed from prior runs
        var consecutiveStagnant = 0

        generationLoop: for generation in 1...generations {
            if let budget = evolveBudget, await budget.isExceeded() {
                note("evolve · budget exhausted before generation \(generation) — stopping"); break
            }
            if !singleGeneration {
                note("── generation \(generation)/\(generations) ──")
            }
            let recordsAtGenStart = allRecords.count

            for index in 1...variantCount {
                if let budget = evolveBudget, await budget.isExceeded() {
                    note("evolve · budget exhausted before generation \(generation) candidate \(index) — stopping")
                    break generationLoop
                }

                let candidateID = singleGeneration ? "\(runID)-v\(index)" : "\(runID)-g\(generation)-v\(index)"
                let worktreeLabel = singleGeneration ? "evolve-\(index)" : "evolve-g\(generation)-\(index)"
                guard let wt = GitIsolation.makeWorktree(repo: root, label: worktreeLabel,
                                                         nowEpoch: Date().timeIntervalSince1970) else {
                    if singleGeneration {
                        err("candidate \(index): could not create isolated worktree")
                    } else {
                        err("candidate \(candidateID): could not create isolated worktree")
                    }
                    continue
                }

                // OPEN-ENDED DGM SELECTION: breed from an archive-SAMPLED parent (favouring under-explored
                // stepping-stones), not the single greedy best. The seed is stable for the repo base,
                // objective, generation, and candidate slot; earlier candidates are already appended so
                // later generations build on the grown archive.
                let parentSeed = EvolutionParentSelector.selectionSeed(baseSHA: wt.base, objective: objective,
                                                                       variantIndex: index, variantCount: variantCount,
                                                                       generation: generation)
                let selectedParent = archive.selectParent(seed: parentSeed)
                let parentID = selectedParent?.candidateID
                let candidateLabel = singleGeneration ? "candidate \(index)/\(variantCount)" : "g\(generation)·v\(index)"
                if let selectedParent {
                    note("\(candidateLabel) · \(candidateID) · \(wt.branch) · parent \(selectedParent.candidateID) (score \(selectedParent.score))")
                } else {
                    note("\(candidateLabel) · \(candidateID) · \(wt.branch) · root (no eligible parent yet)")
                }

                let prompt = EvolutionLab.candidatePrompt(
                    objective: objective, variantIndex: index, variantCount: variantCount,
                    archiveContext: archive.context(selectedParent: selectedParent, limit: 5), policy: policy)
                // Evolve candidates are autonomous self-modifying agents in ISOLATED worktrees, so run them
                // in the BOXED self-improvement envelope: shell ENABLED + writes CONFINED to the worktree
                // (network allowed for research). This gives them the FULL sandboxed tool set — incl.
                // `custom_tool.run` (build+run generated Python helpers) — regardless of the outer
                // --auto/--yolo flags. Confinement to the isolated worktree is what makes the capability
                // safe; where the OS sandbox isn't available (Linux) the sandboxed tools fail closed at
                // execution time, exactly as before.
                // approval:{true} — raw shell strings are auto-permitted for this candidate because the
                // KERNEL sandbox (writes confined to the throwaway worktree) is the real guard here, not the
                // advisory deny-list; the deny-list still hard-blocks obviously-dangerous commands. Without
                // this, a non-interactive candidate's raw `run_command` was refused ("requires interactive
                // approval") and it couldn't run its own generated tools.
                // deny defaults to ShellPolicy.defaultDeny (= baseDeny + hostControlDeny) → host-control
                // (osascript/screencapture/…) is DENIED by default even for evolve candidates (no opt-out here).
                let wtContext = ToolContext(projectRoot: wt.path,
                                            shell: ShellPolicy(enabled: true, autoApprove: true, approval: { _ in true }),
                                            sandbox: .confined(denyNetwork: false, confineWrites: true))
                let memory = opts.noMemory ? nil : ProjectMemory(root: wt.path)
                let recorder = TraceRecorder(traceId: TraceID.make())
                let pxl = PlanExecuteLoop(providers: registry, roles: roles, tools: safeTools, context: wtContext,
                                          sink: TerminalEventSink(),
                                          interactor: opts.yolo ? AutoApproveInteractor() : terminalInteractor(for: opts),
                                          requireApproval: !opts.yolo, recorder: recorder, budget: evolveBudget, memory: memory)

                let outcome = await pxl.run(goal: prompt)
                for line in await recorder.summary().terminalLines() { note(line) }
                note("candidate \(candidateID) agent · \(outcome.message)")

                if !GitIsolation.diff(wt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = GitIsolation.commit(wt, message: "evolution candidate \(candidateID)")
                }

                let changed = GitIsolation.committedChangedPaths(wt)
                // CONSCIENCE on the evolution path: reject a candidate that gamed its own tests — the same
                // fail-closed integrity guard the fleet Foreman uses, before a candidate can score a "pass".
                let integrityViolations = CIIntegrityGuard.inspect(committedFiles: changed,
                                                                   committedDiff: GitIsolation.committedDiff(wt))
                    .map { "\($0.kind): \($0.claim)" }
                let benchmarkResults = await EvolutionBenchmarkRunner.run(commands: benchmarkCommands,
                                                                          cwd: wt.path, timeoutSeconds: opts.evolveTimeout)
                let benchmarks = [EvolutionBenchmarkResult(command: "agent_loop",
                                                           exitCode: outcome.success ? 0 : 1,
                                                           timedOut: false, output: outcome.message)] + benchmarkResults
                let record = EvolutionEvaluator.evaluate(
                    runID: runID, candidateID: candidateID, parentID: parentID, objective: objective,
                    branch: wt.branch, worktreePath: wt.path, baseSHA: wt.base,
                    commitSHA: EvolutionLab.headSHA(worktreePath: wt.path),
                    changedFiles: changed, benchmarks: benchmarks, policy: policy,
                    integrityViolations: integrityViolations, createdAtEpoch: Date().timeIntervalSince1970)
                do { try archive.append(record) }
                catch { err("candidate \(candidateID): failed to append evolution archive: \(error)") }
                allRecords.append(record)
                note("candidate \(candidateID) · \(record.status.rawValue) · score \(record.score) · \(record.summary)")
            }

            // END OF GENERATION: did the frontier move? Track stagnation; optionally early-stop.
            // A generation that produced NO candidates (e.g. every worktree creation failed = infra, not
            // lack of improvement) must NOT count as stagnation — else an infra hiccup triggers early-stop
            // prematurely (DeepSeek review).
            let producedThisGen = allRecords.count - recordsAtGenStart
            guard producedThisGen > 0 else {
                note("generation \(generation) · produced no candidates (infra failure) — not counted toward stagnation")
                continue
            }
            let newBest = EvolutionRunProgress.bestPassingScore(archive.records())
            let improved = EvolutionRunProgress.improved(from: bestPassing, to: newBest)
            consecutiveStagnant = EvolutionRunProgress.updateStagnation(consecutiveStagnant, improved: improved)
            bestPassing = newBest
            if !singleGeneration {
                note("generation \(generation) · best passing score \(newBest.map(String.init) ?? "none")\(improved ? " (improved ↑)" : " (no improvement · stagnant \(consecutiveStagnant))")")
            }
            if EvolutionRunProgress.shouldStop(consecutiveStagnant: consecutiveStagnant, patience: patience) {
                note("evolve · \(consecutiveStagnant) stagnant generation(s) ≥ patience \(patience) — stopping early")
                break generationLoop
            }
        }

        guard !allRecords.isEmpty else { err("evolve · no candidates were evaluated"); return 1 }
        // "best" is the top PASSED candidate only — never a blocked cheat or a failed attempt (MiMo review:
        // sorting ALL records by score could crown a blocked candidate as "best", inconsistent with
        // --evolve-status and against the never-reward-a-cheat principle).
        let bestPassed = allRecords.filter { $0.status == .passed }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.createdAtEpoch > rhs.createdAtEpoch
        }.first
        if let best = bestPassed {
            note("best · \(best.candidateID) · passed · score \(best.score) · branch \(best.branch)")
        } else {
            note("best · (nothing passed benchmarks this run — review the branches before trusting any)")
        }
        note("Review the candidate branch/worktree yourself. Mythos evolve never writes main or auto-promotes.")
        return bestPassed != nil ? 0 : 1
    }
}
