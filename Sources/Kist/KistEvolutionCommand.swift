import Foundation
import AgentCore

/// The `--evolve` command — a boxed, open-ended DGM self-improvement loop. Extracted from KistRunner
/// (RED-zone) into its own file: it runs GENERATIONS of candidate batches, each candidate bred from an
/// archive-sampled parent (open-ended, not greedy), benchmarked in an isolated worktree, and appended to
/// the archive so the NEXT generation breeds from the grown archive. NEVER auto-promotes a winner —
/// humans review the kept branches/worktrees.
extension KistRunner {

    /// Deliberate execution gate. Same-host macOS cannot yet prove hard CPU/memory/process-count
    /// containment for a daemonizing adversary, and the archive lacks an external monotonic rollback anchor.
    /// The paired held-out referee is connected to benchmark authority, but private-suite execution remains
    /// unavailable. Neither manual nor unattended candidate execution may spend model budget and discover
    /// those facts only at benchmark time.
    static var unattendedEvolutionSafetyBlocker: String {
        EvolutionAutonomyReadinessAssessment.current.blockerSummary
    }
    static var unattendedEvolutionReady: Bool {
        EvolutionAutonomyReadinessAssessment.current.ready
    }

    /// Positive capability ceiling for uncommitted evolution candidates. Every member is implemented
    /// in-process on `ConfinedRoot`; no shell, custom code, MCP, research bridge, background-job,
    /// browser, git, search-binary, or composite tool is reachable before the durable commit boundary.
    /// Candidate-authored code executes only later, in the separately attested benchmark sandbox.
    static let evolutionGenerationToolAllowlist: Set<String> = [
        "read_file", "write_file", "edit_file", "notebook_edit", "apply_patch",
        "move_file", "make_dir", "list_files", "glob_files",
    ]

    /// Construct from concrete trusted builtin types. Never filter an ambient registry by name: an MCP
    /// tool can legally collide with a builtin name and ToolRegistry is last-wins.
    static func evolutionGenerationTools() -> ToolRegistry {
        ToolRegistry([
            ReadFileTool(), WriteFileTool(), EditFileTool(), NotebookEditTool(), ApplyPatchTool(),
            MoveFileTool(), MakeDirTool(), ListFilesTool(), GlobFilesTool(),
        ])
    }

    /// `--evolve-status`: render the evolution archive (best, blocked-conscience count, and the open-ended
    /// frontier of who the DGM would breed next) so a human can review the isolated candidate branches.
    /// Then the self-upgrade readiness checklist: each live-authority gate with its state and honest
    /// reason, plus the held-out corpus probe — the visible answer to "what is blocking self-evolution".
    /// Read-only; never touches git or spawns anything. Exit 0 (informational).
    static func runEvolutionStatus(root: String) -> Int32 {
        let archive = EvolutionArchiveStore(root: root)
        let snapshot = archive.snapshot()
        print(EvolutionStatusReport.render(records: snapshot.records,
                                           authoritativeRecords: snapshot.authoritativeRecords,
                                           authorityState: snapshot.state))
        // Informational corpus probe. Location is operator-owned (env override, else co-located with the
        // archive under .mythos, where the candidate sandbox cannot read it). Presence is necessary, not
        // sufficient — the backend re-checks candidate-visibility against exact worktrees at run time.
        let corpusPath = ProcessInfo.processInfo.environment["KIST_EVOLUTION_HELDOUT_CORPUS"]
            ?? (root as NSString).appendingPathComponent(".mythos/evolution/heldout-corpus")
        print("")
        print(EvolutionReadinessReport.render(
            readiness: EvolutionAutonomyReadinessAssessment.current,
            corpus: EvolutionHeldOutCorpus.availability(directory: corpusPath)))
        return 0
    }

    /// `--evolve-tree`: render the ancestry forest + best-score-per-generation trajectory (is the lineage
    /// climbing?). Read-only; dispatched early like --evolve-status. Exit 0.
    static func runEvolutionTree(root: String) -> Int32 {
        let archive = EvolutionArchiveStore(root: root)
        let snapshot = archive.snapshot()
        print(EvolutionLineage.render(records: snapshot.records,
                                      authoritativeRecords: snapshot.authoritativeRecords,
                                      authorityState: snapshot.state))
        return 0
    }

    // MARK: - Cross-session autopilot (armed by a human, run by cron; fail-closed)

    /// `--evolve-arm --budget <tokens> --max-sessions N [--arm-hours H] [--generations G] "<objective>"`:
    /// the EXPLICIT human authorization for autonomous evolution. Writes bounded arming; nothing runs yet.
    static func runEvolveArm(_ opts: KistOptions, root: String) -> Int32 {
        guard unattendedEvolutionReady else {
            err("error: \(unattendedEvolutionSafetyBlocker)")
            return 2
        }
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
        guard unattendedEvolutionReady else {
            err("evolve-session · refused · \(unattendedEvolutionSafetyBlocker)")
            return 2
        }
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
        let archiveBest = EvolutionRunProgress.bestPassingScore(
            EvolutionArchiveStore(root: root).authoritativeRecords())
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
        let requiredManualGates: Set<EvolutionAutonomyGate> = [
            .parentRelativeCapabilityFitness,
            .externalRollbackWitness,
            .hardProcessContainment,
        ]
        let safetyBlockers = EvolutionAutonomyReadinessAssessment.current.blockers.filter {
            requiredManualGates.contains($0.gate)
        }
        guard safetyBlockers.isEmpty else {
            let reason = safetyBlockers
                .map { "\($0.gate.rawValue): \($0.reason)" }
                .joined(separator: "; ")
            err("error: evolution execution is fail-closed: \(reason). Nothing launched.")
            return 2
        }
        guard GitIsolation.isGitRepo(root) else {
            err("error: --evolve needs a git repo at \(root) (isolated candidate branches). Nothing launched."); return 2
        }
        guard let roles = resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        let rootSeedCommit = EvolutionLab.headSHA(worktreePath: root)
        guard !rootSeedCommit.isEmpty else {
            err("error: --evolve could not resolve the repository HEAD commit. Nothing launched."); return 2
        }

        let objective = opts.goal ?? ""
        let variantCount = min(max(1, opts.variants), 10)
        let generations = min(max(1, opts.generations), 20)
        let patience = opts.evolvePatience
        let benchmarkCommands = opts.evolveBenchmarkCommands.isEmpty
            ? EvolutionBenchmarkRunner.defaultCommands(repoRoot: root)
            : opts.evolveBenchmarkCommands
        let policy = EvolutionPolicy(requiredBenchmarkCommands: benchmarkCommands)
        let archive = EvolutionArchiveStore(root: root)
        let initialArchive = archive.snapshot()
        if case .invalid(let reason) = initialArchive.state {
            err("error: evolution archive authority is invalid; refusing to evolve or root-seed: \(reason)")
            return 2
        }
        let runID = String(UUID().uuidString.prefix(8))
        _ = tools // ambient registry is intentionally not an authority source for evolution candidates
        let safeTools = evolutionGenerationTools()
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

        func discardFailedCandidate(_ worktree: GitWorktree, _ candidateID: String) -> Bool {
            guard GitIsolation.discard(worktree) else {
                err("candidate \(candidateID): CRITICAL cleanup failed; quarantined worktree may remain at \(worktree.path)")
                return false
            }
            return true
        }

        var allRecords: [EvolutionCandidateRecord] = []
        var bestPassing = EvolutionRunProgress.bestPassingScore(initialArchive.authoritativeRecords)
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

                // OPEN-ENDED DGM SELECTION: breed from an archive-SAMPLED parent (favouring under-explored
                // stepping-stones), not the single greedy best. The seed is stable for the repo base,
                // objective, generation, and candidate slot; earlier candidates are already appended so
                // later generations build on the grown archive.
                let parentSeed = EvolutionParentSelector.selectionSeed(baseSHA: rootSeedCommit, objective: objective,
                                                                       variantIndex: index, variantCount: variantCount,
                                                                       generation: generation)
                let selectedParent: EvolutionCandidateRecord?
                switch archive.selectParentDecision(seed: parentSeed) {
                case .rootSeed:
                    selectedParent = nil
                case .selected(let parent):
                    selectedParent = parent
                case .refused(let reason):
                    err("candidate \(candidateID): refused authoritative parent selection: \(reason)")
                    return 2
                }
                let lineageChild: EvolutionLineageWorkspace.Child
                do {
                    lineageChild = try EvolutionLineageWorkspace.createChild(
                        repo: root,
                        label: worktreeLabel,
                        nowEpoch: Date().timeIntervalSince1970,
                        rootCommitSHA: rootSeedCommit,
                        selectedParent: selectedParent
                    )
                } catch {
                    let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    err("candidate \(candidateID): refused evolution lineage: \(reason)")
                    continue
                }
                let wt = lineageChild.worktree
                let parentID = lineageChild.parentID
                let candidateLabel = singleGeneration ? "candidate \(index)/\(variantCount)" : "g\(generation)·v\(index)"
                if let selectedParent {
                    note("\(candidateLabel) · \(candidateID) · \(wt.branch) · parent \(selectedParent.candidateID) (score \(selectedParent.score))")
                } else {
                    note("\(candidateLabel) · \(candidateID) · \(wt.branch) · root (no eligible parent yet)")
                }

                let prompt = EvolutionLab.candidatePrompt(
                    objective: objective, variantIndex: index, variantCount: variantCount,
                    archiveContext: archive.context(selectedParent: selectedParent, limit: 5), policy: policy)
                // PRE-COMMIT candidates receive only the positive in-process capability ceiling above.
                // There is deliberately no executable/MCP/research path here: a same-user setsid child cannot
                // be proved dead by ProcessGroupRunner on macOS, so arbitrary candidate code is postponed to
                // the exact-commit, one-use Builder verifier. The strict policy remains bound to the context
                // as defense in depth for any future executable tool accidentally admitted by a code change.
                let wtContext = ToolContext(projectRoot: wt.path,
                                            shell: .denied,
                                            sandbox: .strictAutonomous(forbiddenReadPaths: [root]),
                                            externalReadRoots: [], allowMediaDropInbox: false)
                let memory = opts.noMemory ? nil : ProjectMemory(root: wt.path)
                let recorder = TraceRecorder(traceId: TraceID.make())
                let pxl = PlanExecuteLoop(providers: registry, roles: roles, tools: safeTools, context: wtContext,
                                          sink: TerminalEventSink(),
                                          interactor: opts.yolo ? AutoApproveInteractor() : terminalInteractor(for: opts),
                                          requireApproval: !opts.yolo, recorder: recorder, budget: evolveBudget, memory: memory)

                let outcome = await pxl.run(goal: prompt)
                for line in await recorder.summary().terminalLines() { note(line) }
                note("candidate \(candidateID) agent · \(outcome.message)")

                let durable: GitIsolation.EvolutionCommitSnapshot
                do {
                    durable = try GitIsolation.commitEvolutionCandidate(
                        wt, message: "evolution candidate \(candidateID)")
                } catch {
                    err("candidate \(candidateID): refused non-durable candidate bytes: \(error.localizedDescription)")
                    guard discardFailedCandidate(wt, candidateID) else { return 2 }
                    continue
                }

                let changed = durable.changedFiles
                // CONSCIENCE on the evolution path: reject a candidate that gamed its own tests — the same
                // fail-closed integrity guard the fleet Foreman uses, before a candidate can score a "pass".
                let integrityViolations = CIIntegrityGuard.inspect(committedFiles: changed,
                                                                   committedDiff: durable.committedDiff)
                    .map { "\($0.kind): \($0.claim)" }
                let hostState: EvolutionBenchmarkRunner.ProtectedHostState
                do {
                    hostState = try EvolutionBenchmarkRunner.captureProtectedHostState(repoRoot: root)
                } catch {
                    err("candidate \(candidateID): could not attest protected host state: \(error.localizedDescription)")
                    _ = discardFailedCandidate(wt, candidateID)
                    return 2
                }
                let benchmarkResults: [EvolutionBenchmarkResult]
                let benchmarkAuthority: EvolutionBenchmarkAuthorityReceipt?
                let capabilityFitness: EvolutionCapabilityFitnessReceiptInput?
                if !policy.protectedFiles(in: changed).isEmpty || !integrityViolations.isEmpty {
                    // Never execute a candidate-authored verifier after it touched its own gate. The
                    // exact durable commit remains reviewable and may be sealed only as BLOCKED.
                    benchmarkResults = []
                    benchmarkAuthority = nil
                    capabilityFitness = nil
                } else {
                    do {
                        let batch = try await EvolutionBenchmarkRunner.run(
                            commands: benchmarkCommands,
                            candidate: durable,
                            worktree: wt,
                            hostRoot: root,
                            expectedHostState: hostState,
                            timeoutSeconds: opts.evolveTimeout)
                        benchmarkResults = batch.results
                        benchmarkAuthority = batch.authorityReceipt
                        capabilityFitness = batch.capabilityFitness
                    } catch {
                        err("candidate \(candidateID): secure benchmark refused: \(error.localizedDescription)")
                        _ = discardFailedCandidate(wt, candidateID)
                        return 2
                    }
                }
                do {
                    try GitIsolation.validateEvolutionCandidate(wt, expected: durable)
                    try EvolutionBenchmarkRunner.validateProtectedHostState(hostState)
                } catch {
                    err("candidate \(candidateID): post-evaluation attestation failed; refusing archive seal: \(error.localizedDescription)")
                    _ = discardFailedCandidate(wt, candidateID)
                    return 2
                }
                let benchmarks = [EvolutionBenchmarkResult(command: "agent_loop",
                                                           exitCode: outcome.success ? 0 : 1,
                                                           timedOut: false, output: outcome.message)] + benchmarkResults
                let record = EvolutionEvaluator.evaluate(
                    runID: runID, candidateID: candidateID, parentID: parentID, objective: objective,
                    branch: wt.branch, worktreePath: wt.path, baseSHA: wt.base,
                    commitSHA: durable.commitSHA,
                    treeSHA: durable.treeSHA,
                    gitControlDigest: durable.gitControlDigest,
                    hostStateDigest: hostState.evidenceDigest,
                    committedDiff: durable.committedDiff,
                    benchmarkAuthority: benchmarkAuthority,
                    capabilityFitness: capabilityFitness,
                    changedFiles: changed, benchmarks: benchmarks, policy: policy,
                    integrityViolations: integrityViolations, createdAtEpoch: Date().timeIntervalSince1970)
                let persisted: EvolutionCandidateRecord
                do { persisted = try archive.append(record) }
                catch {
                    err("candidate \(candidateID): failed to append authoritative evolution archive: \(error)")
                    _ = discardFailedCandidate(wt, candidateID)
                    return 2
                }
                allRecords.append(persisted)
                note("candidate \(candidateID) · \(persisted.status.rawValue) · score \(persisted.score) · \(persisted.summary)")
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
            let newBest = EvolutionRunProgress.bestPassingScore(archive.authoritativeRecords())
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
