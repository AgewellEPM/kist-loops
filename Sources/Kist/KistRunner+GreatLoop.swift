import Foundation
import AgentCore

/// The great-loop route, extracted from KistRunner (RED-zone modular split, behavior-preserving):
/// the long-horizon runner that self-assesses effort per cycle, learns from history, escalates the
/// model when hard, has a second mind team-review the diff, and keeps working until done-and-verified
/// or a SAFETY CAP stops it.
extension KistRunner {

    /// Threads a cycle's team-review feedback into the next cycle (locked — the runCycle closure is @Sendable).
    final class FeedbackBox: @unchecked Sendable {
        private let lock = NSLock(); private var v = ""
        var value: String { lock.lock(); defer { lock.unlock() }; return v }
        func set(_ s: String) { lock.lock(); v = s; lock.unlock() }
    }

    /// Providers that server-faulted — the escalator routes around them (fault tolerance). COOLDOWN, not
    /// permanent: a provider is excluded only for `cooldown` seconds after its last fault, so a transient
    /// blip on cycle 2 of a 20h run doesn't narrow the escalation pool for the remaining 18 hours — the
    /// next cycle after the window IS the half-open probe (a 5-model review flagged permanent exclusion).
    final class ProviderErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tracker = ProviderCooldownTracker()   // pure cooldown logic (unit-tested in AgentCore)
        func insert(_ p: String, at now: Double) { lock.lock(); tracker.recordFault(p, at: now); lock.unlock() }
        func active(now: Double) -> Set<String> { lock.lock(); defer { lock.unlock() }; return tracker.active(now: now) }
    }

    static func runGreatLoop(_ opts: KistOptions, goal: String, registry: ProviderRegistry, root: String,
                                     tools: ToolRegistry, context: ToolContext, checkpoints: LoopCheckpointStore,
                                     toolMode: ToolMode, roles: RoleBindings, providerId: String, model: String?) async -> Int32 {
        // LEAN TOOL SET: the full registry can be ~70 tools / ~25k schema chars (~6.5k tokens) — sent on
        // EVERY model call. On a coding loop that's dead weight (media, app-UI-testing, desktop control,
        // pentest, enterprise reporting) that ate ~half a cycle's budget, so cycles couldn't converge.
        // Drop the coding-irrelevant tools; file/shell/lsp/memory/web/research stay.
        let loopTools = ToolRegistry(tools.all().filter { !Self.isLoopIrrelevantTool($0.name) })
        if loopTools.all().count < tools.all().count {
            note("  · lean tool set: \(loopTools.all().count)/\(tools.all().count) tools (dropped coding-irrelevant schemas)")
        }
        let deadline: Double? = opts.loopHours.map { Date().timeIntervalSince1970 + $0 * 3600 }
        // SAFETY: an unattended --loop must ALWAYS have a token/$ ceiling. If --budget wasn't given, default
        // to a bounded cap (panel finding: model escalation with no cap could burn unbounded $ over 20h).
        let defaultTokenCap = 2_000_000
        let caps = GreatLoopCaps(maxCycles: opts.maxCycles ?? 20, maxTokens: opts.budgetTokens ?? defaultTokenCap,
                                 deadlineEpoch: deadline, noProgressLimit: 3,
                                 noDestructive: !opts.yolo, noAutoMerge: true)
        if opts.budgetTokens == nil { note("  · no --budget given → default token ceiling \(defaultTokenCap) (pass --budget to change)") }
        note("kist · great-loop · \(providerId)\(model.map { " (\($0))" } ?? "") · \(root) · caps[cycles:\(caps.maxCycles)"
             + (caps.maxTokens.map { ", tokens:\($0)" } ?? "") + (opts.loopHours.map { ", \($0)h" } ?? "") + "]")
        let memory = EffortMemory(projectRoot: root)
        let traceRecorder = TraceRecorder(traceId: TraceID.make())
        let delegationDepth = opts.delegationDepth
        // Provider ids that actually have a usable key — candidates for model escalation.
        let keyed = registry.providers.filter { registry.hasKey(for: $0) }.map { $0.id }
        let feedback = FeedbackBox()
        // Fault tolerance: providers that server-errored this run get routed around by the escalator, so a
        // single flaky provider (e.g. a 500-storm) can't tank every cycle of a 20h loop (live dogfood: an
        // escalated model 500'd on all 4 cycles and the loop never completed).
        let erroredProviders = ProviderErrorBox()
        // Durable, verification-gated learning across cycles AND runs (Phase 1).
        let lessons: LessonStore? = opts.noMemory ? nil : LessonStore()
        // GEPA-style evolving policy hints, best-per-signature Pareto frontier (Phase 2).
        let policy: PolicyStore? = opts.noMemory ? nil : PolicyStore(projectRoot: root)
        // Gated DGM bridge: proven hints → reviewable promotion queue, NEVER auto-applied (Phase 2.2).
        let promotions: PromotionCandidateStore? = opts.noMemory ? nil : PromotionCandidateStore(projectRoot: root)

        // ONE work cycle: escalate the model when the task is hard, size the budget so it can't starve the
        // loop, run the goal (carrying any prior team-review feedback), then — if not done but progressing and
        // the effort calls for a team — have a SECOND mind review the diff and thread that into the next cycle.
        let runCycle: @Sendable (String, EffortController.Assessment, Int, Int?) async -> CycleResult = { baseGoal, effort, cycleIndex, budgetRemaining in
            let nowEpoch = Date().timeIntervalSince1970
            let cycleProvider = ModelEscalator.pick(tier: effort.modelTier, keyed: keyed, preferred: providerId,
                                                    exclude: erroredProviders.active(now: nowEpoch))
            let cycleModel: String? = cycleProvider == providerId ? model : nil
            if cycleProvider != providerId { note("  ↑ escalating this cycle → \(cycleProvider) (tier \(effort.modelTier.rawValue))") }
            // Snapshot the provider's retry tally so we can measure FLAKINESS over this cycle: a provider
            // whose 5xx are absorbed by catalog retries never surfaces a terminal fault, but if it needed
            // many retries AND the cycle still failed, it's degrading — route around it like a hard fault.
            let retriesBefore = registry.retryCount(providerId: cycleProvider)
            // Per-cycle budget: an even share of what REMAINS among the cycles LEFT — not a rigid
            // total/maxCycles. Cycle 0 still gets ~remaining/maxCycles (so no single early cycle eats
            // everything — the captain over-spend guard), but early cheap cycles leave more for later, and
            // the LAST cycle can spend everything still unspent. The old fixed fair-share STARVED a cycle:
            // it died mid-work (create files, then no budget left to build/test) and the next cycle restarted
            // from scratch — a trivial task never converged. (dogfood: 200k/2-cycle died pre-build every time.)
            let perCycle = budgetRemaining.map { Self.perCycleBudget(remaining: $0, cycleIndex: cycleIndex,
                                                                     maxCycles: caps.maxCycles) }
            // Inject durable lessons (past cycles + past runs) + the evolved policy hint for this task type.
            let sig = EffortController.signature(for: baseGoal)
            let primer = lessons?.primer(forGoal: baseGoal)
            let policyHint = policy?.bestHint(forSignature: sig)
            let repoMap = RepoMap.build(projectRoot: root, goal: baseGoal)   // orientation: files → symbols
            let sessionMem = Self.sessionMemory(root: root, opts: opts)       // cortex + project memory
            let fb = feedback.value
            // FENCE the user's task in the scope-source markers so AuthorizationScopeEngine classifies ONLY
            // the task — NOT the injected memory/repo-map below. (Live-run bug: cortex memory containing
            // "Production" made a plain create-task misfire as read-only serverDiagnostics, blocking all writes.)
            var cycleGoal = PromptCompiler.scopeSourceStart + "\n" + baseGoal + "\n" + PromptCompiler.scopeSourceEnd
            // CONTINUITY across cycles: each cycle is a fresh conversation, so without this the model has
            // amnesia — it re-creates work a prior cycle already did (live dogfood: it built the package at
            // ./ in one cycle, then RE-created it under ./MathKit/ in the next → duplication, never converged).
            // Show the files prior cycles already changed and tell it to CONTINUE, not restart.
            let priorFiles = KistREPL.workingTreeChangedFiles(projectRoot: root)
            if let note = Self.continuityNote(cycleIndex: cycleIndex, changedFiles: priorFiles) {
                cycleGoal += "\n\n" + note
            }
            if let sessionMem, !sessionMem.isEmpty { cycleGoal += "\n\nMEMORY — what kist knows about you & this project:\n" + sessionMem }
            if !repoMap.isEmpty { cycleGoal += "\n\n" + repoMap }
            if let primer, !primer.isEmpty { cycleGoal += "\n\n" + primer }
            if let policyHint, !policyHint.isEmpty { cycleGoal += "\n\nLEARNED POLICY — " + policyHint }
            if !fb.isEmpty { cycleGoal += "\n\nPRIOR CYCLE — fix these before finishing:\n" + fb }

            let recorder = TrajectoryRecorder()
            let think = effort.thinking != .none
            let before = await traceRecorder.all()

            // BEST-OF-N (Phase 3.1 exec): on a HARD cycle with a CLEAN tree, try N independent attempts in
            // ISOLATED worktrees and apply the first VERIFIED winner to the live tree. WorktreeBestOfN never
            // touches the live tree except a clean winner-apply (dry-run --check'd); any failure / no-winner /
            // dirty-tree leaves it untouched → fall through to a normal in-tree cycle.
            if effort.searchWidth > 1, WorktreeBestOfN.isCleanTree(root) {
                note("  ⑃ best-of-\(effort.searchWidth) · isolated worktrees")
                let attemptBudget = perCycle.map { max(20_000, $0 / effort.searchWidth) }
                let won = await WorktreeBestOfN.run(root: root, width: effort.searchWidth, nowEpoch: Date().timeIntervalSince1970) { wtPath, _ in
                    let wtCtx = ToolContext(projectRoot: wtPath, shell: context.shell, sandbox: context.sandbox,
                                            externalReadRoots: context.externalReadRoots)
                    let rec = TrajectoryRecorder()
                    let wtLoop = makeLoop(registry: registry, providerId: cycleProvider, model: cycleModel, context: wtCtx,
                                          tools: loopTools, checkpoints: checkpoints, maxIterations: effort.iterationBudget,
                                          // --max-cost in --loop: SAFE fixed fair-share USD subdivision per
                                          // attempt (maxCostUSD / (maxCycles × searchWidth)) — the total across
                                          // all cycles×attempts can never exceed the cap (Codex: was ignored here).
                                          budget: attemptBudget.map { BudgetLedger(maxTokens: $0, maxUSD: opts.maxCostUSD.map { $0 / Double(max(1, caps.maxCycles * effort.searchWidth)) }) },
                                          interactor: caps.noDestructive ? NonDestructiveInteractor() : AutoApproveInteractor(),
                                          planMode: false, extendedThinking: think, toolMode: toolMode, roles: roles,
                                          delegationDepth: delegationDepth, showReasoning: false,
                                          sinkOverride: TerminalEventSink(showReasoning: false, style: .calm),
                                          recorder: rec, traceRecorder: traceRecorder)
                    let oc = await wtLoop.run(goal: cycleGoal)
                    let traj = rec.snapshot()
                    let v = GreatLoopVerifier.verify(trajectory: traj, canRunCommands: context.shell.enabled,
                                                     changedFiles: KistREPL.workingTreeChangedFiles(projectRoot: wtPath),
                                                     diff: KistREPL.workingTreeDiff(projectRoot: wtPath))
                    let g = GroundedReviewValidator.audit(oc.summary, projectRoot: wtPath).isGrounded
                    return (verified: oc.success && g && v.isVerified,
                            quality: EffortScorer.quality(success: true, verified: true, failureRate: 0,
                                                          iterationsUsed: traj.count, iterationBudget: effort.iterationBudget))
                }
                if won {
                    note("  ✓ best-of-N: a verified independent attempt was applied to the tree")
                    let delta = (await traceRecorder.all()).filter { s in !before.contains(where: { $0.id == s.id }) }
                    lessons?.record(CycleReflection.lesson(goal: baseGoal, done: true, verdictReason: "verified",
                                                           reviewGist: nil, summary: "best-of-N: a verified independent attempt was applied",
                                                           failureRate: 0, at: Date().timeIntervalSince1970))
                    return CycleResult(doneAndVerified: true, tokensSpent: UsageCost.summarize(spans: delta).tokens,
                                       madeProgress: true, signals: EffortController.Signals(),
                                       summary: "best-of-N verified winner applied")
                }
                note("  · no best-of-N winner — running a normal in-tree cycle")
            }

            let loop = makeLoop(registry: registry, providerId: cycleProvider, model: cycleModel, context: context,
                                tools: loopTools, checkpoints: checkpoints, maxIterations: effort.iterationBudget,
                                // --max-cost in --loop: SAFE per-cycle USD fair share (maxCostUSD / maxCycles);
                                // sum across cycles ≤ the cap (Codex: was ignored here).
                                budget: perCycle.map { BudgetLedger(maxTokens: $0, maxUSD: opts.maxCostUSD.map { $0 / Double(max(1, caps.maxCycles)) }) },
                                // ENFORCE noDestructive: an unattended --loop (no --yolo) refuses irreversible
                                // ops (rm -rf/force-push/deploy) while still running build/test/edit.
                                interactor: caps.noDestructive ? NonDestructiveInteractor() : AutoApproveInteractor(),
                                planMode: false, extendedThinking: think, toolMode: toolMode, roles: roles,
                                delegationDepth: delegationDepth, showReasoning: false,
                                sinkOverride: TerminalEventSink(showReasoning: false, style: .calm),
                                recorder: recorder, traceRecorder: traceRecorder)
            let outcome = await loop.run(goal: cycleGoal)
            // Fault detection: if the cycle failed because the PROVIDER faulted server-side, mark it so the
            // escalator routes around it (within the cooldown window). PRIMARY signal is the STRUCTURED flag
            // the loop set from the typed error. FALLBACK (only on a FAILED cycle, where the summary IS the
            // provider error reason — not agent content): the string classifier, for error shapes that don't
            // reach the loop as a typed AIProviderError (live dogfood: a gemini 5xx surfaced this way and the
            // structured flag missed it). No provider==default guard: if the DEFAULT is broken, record it too
            // — pick() falls back to it only when there's no healthy alternative (single-provider not stranded).
            // FLAKINESS: retries this cycle that the catalog absorbed. If the provider needed several AND the
            // cycle didn't complete, treat it as a fault (the live gemini case: intermittent 5xx recovered by
            // retries burned the budget without ever surfacing a terminal fault, so route-around never fired).
            let retriesThisCycle = registry.retryCount(providerId: cycleProvider) - retriesBefore
            let flaky = retriesThisCycle >= 3
            let faulted = outcome.providerFault
                || (!outcome.success && ProviderFault.fromSummary(outcome.summary))
                || (!outcome.success && flaky)
            if faulted {
                erroredProviders.insert(cycleProvider, at: nowEpoch)
                let why = outcome.providerFault ? "server-faulted"
                    : (retriesThisCycle >= 3 ? "flaky (\(retriesThisCycle) retries)" : "server-faulted")
                note("  ⚠ \(cycleProvider) \(why) — routing around it (cooldown)")
            }
            let trajectory = recorder.snapshot()
            let intent = PromptCompiler.compile(baseGoal).intent
            let report = TrajectoryAnalyzer.analyze(trajectory,
                                                    taskIntent: intent)
            let failures = trajectory.filter { !$0.success }.count
            let failureRate = trajectory.isEmpty ? 0 : Double(failures) / Double(trajectory.count)
            let after = await traceRecorder.all()
            let delta = after.filter { s in !before.contains(where: { $0.id == s.id }) }
            let grounded = GroundedReviewValidator.audit(outcome.summary, projectRoot: root).isGrounded
            let workDiff = KistREPL.workingTreeDiff(projectRoot: root)
            let workChanged = KistREPL.workingTreeChangedFiles(projectRoot: root)
            // PHASE 0 — anti-Goodhart done-gate: a claimed done is only real if it's execution-grounded
            // (a real build/test passed after the edits) AND didn't game the verifier (no deleted/skipped
            // tests, no `|| true`). Model say-so is never enough over a 20h run.
            let verdict = GreatLoopVerifier.verify(trajectory: trajectory, canRunCommands: context.shell.enabled,
                                                   changedFiles: workChanged, diff: workDiff)
            let done = outcome.success && grounded && verdict.isVerified
            if outcome.success, !verdict.isVerified { note("  ⨯ done REJECTED by verifier · \(verdict.reason)") }
            let progressed = trajectory.contains { $0.success }

            // Thread forward what the NEXT cycle must fix: the verifier's rejection (if any) + a second-mind
            // team review of the diff. Cleared once the goal is genuinely done+verified.
            var reviewText: String? = nil
            if done {
                feedback.set("")
            } else {
                var notes: [String] = []
                if outcome.success, !verdict.isVerified {
                    notes.append("Your 'done' was REJECTED: \(verdict.reason). A REAL build/test must pass after your edits, and you may NOT weaken/skip/delete tests to make it green.")
                }
                // Carry the LAST build/test error forward so the next cycle fixes THIS error instead of
                // rediscovering it (dogfood: a test naming-collision compile error was lost each cycle).
                if let failure = Self.lastCommandFailure(in: trajectory) {
                    notes.append("The last build/test command FAILED with this error — fix it directly (do NOT "
                        + "assume the tool is broken; run_command works — you ran commands successfully this run):\n" + failure)
                }
                if progressed, effort.team != .solo,
                   !workDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let reviewer = ModelEscalator.pick(tier: .frontier, keyed: keyed, preferred: cycleProvider,
                                                       exclude: erroredProviders.active(now: nowEpoch))
                    note("  ⎇ team review · \(reviewer)")
                    if let review = try? await registry.complete(
                        providerId: reviewer, model: nil,
                        messages: [ChatMessage(role: .system, content: Copilot.reviewSystemPrompt),
                                   ChatMessage(role: .user, content: Copilot.reviewPrompt(task: baseGoal, diff: workDiff))],
                        settings: ModelSettings(temperature: 0.0, maxTokens: 700)),
                       !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reviewText = review
                        notes.append("Team review of your changes:\n" + review)
                    }
                }
                feedback.set(notes.joined(separator: "\n\n"))
            }

            // LEARN durably: a verification-gated structured lesson (PROVEN only if done+verified).
            let now = Date().timeIntervalSince1970
            lessons?.record(CycleReflection.lesson(goal: baseGoal, done: done, verdictReason: verdict.reason,
                                                   reviewGist: reviewText, summary: outcome.summary,
                                                   failureRate: failureRate, at: now))
            // EVOLVE the policy: score the hint we ran under (win = verified done, grounded by Phase 0) and
            // let this cycle's review seed the next candidate hint for this signature.
            policy?.record(signature: sig, activeHint: policyHint, won: done, review: reviewText, at: now)
            // GATED DGM bridge: once a hint proves itself (enough verified wins at a high rate), QUEUE it for
            // human/DGM review — NEVER auto-applied to Mythos's own prompts (the self-modification line).
            if let best = policy?.bestCandidate(forSignature: sig),
               PromotionGate.qualifies(wins: best.wins, trials: best.trials),
               promotions?.export(PromotionCandidate(signature: sig, hint: best.hint, wins: best.wins,
                                                      trials: best.trials, at: now)) == true {
                note("  ⤴ policy proven (\(best.wins)/\(best.trials)) — queued for review (never auto-applied)")
            }

            return CycleResult(doneAndVerified: done, tokensSpent: UsageCost.summarize(spans: delta).tokens,
                               madeProgress: progressed,
                               signals: .init(failureRate: failureRate, iterationsUsed: trajectory.count, isStuck: !report.healthy),
                               summary: outcome.summary, providerFault: outcome.providerFault)
        }

        let runner = GreatLoopRunner(goal: goal, caps: caps, memory: memory,
                                     clock: { Date().timeIntervalSince1970 },
                                     runCycle: runCycle, emit: { note($0) })
        let decision = await runner.run()
        printUsageDelta(from: [], to: await traceRecorder.all(), label: "great-loop usage", projectRoot: root)
        return decision.succeeded ? 0 : 1
    }
}
