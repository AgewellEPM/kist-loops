import Foundation
import AgentCore

/// The great-loop route, extracted from KistRunner (RED-zone modular split, behavior-preserving):
/// the long-horizon runner that self-assesses effort per cycle, learns from history, escalates the
/// model when hard, has a second mind team-review the diff, and keeps working until done-and-verified
/// or a SAFETY CAP stops it.
extension KistRunner {

    struct GreatLoopCycleEnvelope: Sendable {
        let result: CycleResult
        let progress: [ReasoningProgressReceipt]
        let evidence: [ReasoningEvidenceReference]
        let checkpointID: String?
        let providerEffortRecords: [ProviderEffortRecord]
    }

    static func providerReasoningEffort(_ thinking: EffortController.Thinking) -> ProviderReasoningEffort {
        switch thinking {
        case .none: return .none
        case .light: return .light
        case .deep: return .deep
        }
    }

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
                                     toolMode: ToolMode, roles: RoleBindings, providerId: String, model: String?,
                                     budgetOverride: BudgetLedger? = nil) async -> Int32 {
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
        // Per-model scorecard: finally WRITE the (previously dead-wired) CaptainLearningStore every cycle so
        // the Captain builds durable, cross-session memory of which models succeed / fail / loop.
        let scorecard: CaptainLearningStore? = opts.noMemory ? nil : CaptainLearningStore(projectRoot: root)
        // CROSS-RUN model track record read ONCE at run start: the escalator uses it to prefer proven
        // models and route around chronic failers/loopers. This-run transient faults stay the live
        // cooldown's job (erroredProviders); the scorecard is the durable, cross-run half.
        let historyVerdicts: [String: ModelVerdict] = scorecard?.modelVerdicts() ?? [:]

        // ONE work cycle: escalate the model when the task is hard, size the budget so it can't starve the
        // loop, run the goal (carrying any prior team-review feedback), then — if not done but progressing and
        // the effort calls for a team — have a SECOND mind review the diff and thread that into the next cycle.
        let runCycle: @Sendable (String, EffortController.Assessment, Int, Int?, String?) async -> GreatLoopCycleEnvelope = { baseGoal, effort, cycleIndex, budgetRemaining, checkpointID in
            let nowEpoch = Date().timeIntervalSince1970
            let cycleProvider = ModelEscalator.pick(tier: effort.modelTier, keyed: keyed, preferred: providerId,
                                                    exclude: erroredProviders.active(now: nowEpoch),
                                                    verdicts: historyVerdicts)
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
            let sessionMem = Self.sessionMemory(root: root, opts: opts)
            let fb = feedback.value
            // FENCE the user's task in the scope-source markers so AuthorizationScopeEngine classifies ONLY
            // the task — NOT the injected project memory/repo-map below.
            var cycleGoal = PromptCompiler.scopeSourceStart + "\n" + baseGoal + "\n" + PromptCompiler.scopeSourceEnd
            // CONTINUITY across cycles: each cycle is a fresh conversation, so without this the model has
            // amnesia — it re-creates work a prior cycle already did (live dogfood: it built the package at
            // ./ in one cycle, then RE-created it under ./MathKit/ in the next → duplication, never converged).
            // Show the files prior cycles already changed and tell it to CONTINUE, not restart.
            let priorFiles = KistREPL.workingTreeChangedFiles(projectRoot: root)
            let priorDiff = KistREPL.workingTreeDiff(projectRoot: root)
            if let note = Self.continuityNote(cycleIndex: cycleIndex, changedFiles: priorFiles) {
                cycleGoal += "\n\n" + note
            }
            if let sessionMem, !sessionMem.isEmpty { cycleGoal += "\n\nMEMORY — what kist knows about you & this project:\n" + sessionMem }
            if !repoMap.isEmpty { cycleGoal += "\n\n" + repoMap }
            if let primer, !primer.isEmpty { cycleGoal += "\n\n" + primer }
            if let policyHint, !policyHint.isEmpty { cycleGoal += "\n\nLEARNED POLICY — " + policyHint }
            if !fb.isEmpty { cycleGoal += "\n\nPRIOR CYCLE — fix these before finishing:\n" + fb }
            cycleGoal += "\n\n" + Self.builderEffortContext(effort)

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
                let bestOfNGoal = cycleGoal
                let won = await WorktreeBestOfN.run(root: root, width: effort.searchWidth, nowEpoch: Date().timeIntervalSince1970) { wtPath, _ in
                    let wtCtx = ToolContext(projectRoot: wtPath, shell: context.shell, sandbox: context.sandbox,
                                            externalReadRoots: context.externalReadRoots,
                                            correlationID: context.correlationID,
                                            traceRecorder: context.traceRecorder)
                    let rec = TrajectoryRecorder()
                    let wtLoop = makeLoop(registry: registry, providerId: cycleProvider, model: cycleModel, context: wtCtx,
                                          tools: loopTools, checkpoints: checkpoints, maxIterations: effort.iterationBudget,
                                          // --max-cost in --loop: SAFE fixed fair-share USD subdivision per
                                          // attempt (maxCostUSD / (maxCycles × searchWidth)) — the total across
                                          // all cycles×attempts can never exceed the cap (Codex: was ignored here).
                                          budget: budgetOverride ?? attemptBudget.map { BudgetLedger(maxTokens: $0, maxUSD: opts.maxCostUSD.map { $0 / Double(max(1, caps.maxCycles * effort.searchWidth)) }) },
                                          interactor: caps.noDestructive ? NonDestructiveInteractor() : AutoApproveInteractor(),
                                          planMode: false, extendedThinking: think, toolMode: toolMode, roles: roles,
                                          delegationDepth: delegationDepth, showReasoning: false,
                                          sinkOverride: TerminalEventSink(showReasoning: false, style: .calm),
                                          recorder: rec, traceRecorder: traceRecorder)
                    let oc = await wtLoop.run(goal: bestOfNGoal)
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
                    let changed = KistREPL.workingTreeChangedFiles(projectRoot: root).sorted()
                    let diff = KistREPL.workingTreeDiff(projectRoot: root)
                    let digest = Self.builderCompatibilityContractID(
                        root: root, goal: diff, adapter: .greatLoop
                    )
                    let nodeID = "great-loop-cycle-\(cycleIndex)"
                    var typedProgress = changed.map { path in
                        ReasoningProgressReceipt(
                            nodeID: nodeID,
                            evidence: .artifact(ReasoningArtifactReference(
                                id: "great-loop-artifact:\(path)", path: path,
                                revision: digest, nodeID: nodeID
                            ))
                        )
                    }
                    if typedProgress.isEmpty {
                        typedProgress.append(ReasoningProgressReceipt(
                            nodeID: nodeID,
                            evidence: .workspaceMutation(effectID: digest, paths: [root])
                        ))
                    }
                    let proof = ReasoningEvidenceReference(
                        id: "great-loop-best-of-n:\(digest)", kind: .check,
                        nodeID: nodeID, locator: root, digest: digest,
                        summary: "best-of-N produced and applied a verified winner"
                    )
                    typedProgress.append(ReasoningProgressReceipt(
                        nodeID: nodeID,
                        evidence: .checkTransition(ReasoningCheckReceipt(
                            id: "great-loop-verification", name: "Great Loop deterministic verification",
                            state: .passed, evidenceID: proof.id, nodeID: nodeID
                        ))
                    ))
                    return GreatLoopCycleEnvelope(
                        result: CycleResult(
                            doneAndVerified: true,
                            tokensSpent: UsageCost.summarize(spans: delta).tokens,
                            madeProgress: true, signals: EffortController.Signals(),
                            summary: "best-of-N verified winner applied"
                        ),
                        progress: typedProgress, evidence: [proof], checkpointID: nil,
                        providerEffortRecords: []
                    )
                }
                note("  · no best-of-N winner — running a normal in-tree cycle")
            }

            let loop = makeLoop(registry: registry, providerId: cycleProvider, model: cycleModel, context: context,
                                tools: loopTools, checkpoints: checkpoints, maxIterations: effort.iterationBudget,
                                // --max-cost in --loop: SAFE per-cycle USD fair share (maxCostUSD / maxCycles);
                                // sum across cycles ≤ the cap (Codex: was ignored here).
                                budget: budgetOverride ?? perCycle.map { BudgetLedger(maxTokens: $0, maxUSD: opts.maxCostUSD.map { $0 / Double(max(1, caps.maxCycles)) }) },
                                // ENFORCE noDestructive: an unattended --loop (no --yolo) refuses irreversible
                                // ops (rm -rf/force-push/deploy) while still running build/test/edit.
                                interactor: caps.noDestructive ? NonDestructiveInteractor() : AutoApproveInteractor(),
                                planMode: false, extendedThinking: think, toolMode: toolMode, roles: roles,
                                delegationDepth: delegationDepth, showReasoning: false,
                                sinkOverride: TerminalEventSink(showReasoning: false, style: .calm),
                                recorder: recorder, traceRecorder: traceRecorder)
            let outcome: HeadlessAgentLoop.Outcome
            if let checkpointID,
               let checkpoint = try? checkpoints.load(id: checkpointID),
               checkpoint.status != .completed,
               checkpoint.status != .abandoned {
                outcome = await loop.resume(from: checkpoint)
            } else {
                outcome = await loop.run(goal: cycleGoal)
            }
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
            var progressArtifacts = workChanged
                .filter { !priorFiles.contains($0) }
                .map { BuilderArtifact(path: $0, kind: "changed-path") }
            if workDiff != priorDiff, progressArtifacts.isEmpty {
                progressArtifacts.append(BuilderArtifact(path: root, kind: "working-tree-diff"))
            }
            let passingChecks = verdict.isVerified
                ? [BuilderCheckReceipt(name: "great-loop deterministic verification", passed: true,
                                       details: verdict.reason)] : []
            let completedBuilderNodes = done ? ["great-loop-cycle-\(cycleIndex)"] : []
            let progressed = !progressArtifacts.isEmpty || !passingChecks.isEmpty
                || !completedBuilderNodes.isEmpty
            let reasoningNodeID = "great-loop-cycle-\(cycleIndex)"
            let reasoningDigest = Self.builderCompatibilityContractID(
                root: root,
                goal: workDiff + "\u{0}" + verdict.reason,
                adapter: .greatLoop
            )
            let verificationEvidence = ReasoningEvidenceReference(
                id: "great-loop-verification:\(reasoningDigest)", kind: .check,
                nodeID: reasoningNodeID, locator: root, digest: reasoningDigest,
                summary: verdict.reason
            )
            var typedProgress = workChanged.map { path in
                ReasoningProgressReceipt(
                    nodeID: reasoningNodeID,
                    evidence: .artifact(ReasoningArtifactReference(
                        id: "great-loop-artifact:\(path)", path: path,
                        revision: reasoningDigest, nodeID: reasoningNodeID
                    ))
                )
            }
            if workDiff != priorDiff, typedProgress.isEmpty {
                typedProgress.append(ReasoningProgressReceipt(
                    nodeID: reasoningNodeID,
                    evidence: .workspaceMutation(effectID: reasoningDigest, paths: [root])
                ))
            }
            typedProgress.append(ReasoningProgressReceipt(
                nodeID: reasoningNodeID,
                evidence: .checkTransition(ReasoningCheckReceipt(
                    id: "great-loop-verification", name: "Great Loop deterministic verification",
                    state: verdict.isVerified ? .passed : .failed,
                    evidenceID: verificationEvidence.id, nodeID: reasoningNodeID
                ))
            ))

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
                    let producingModel = registry.provider(id: cycleProvider)?.resolvedModel(cycleModel)
                        ?? cycleModel ?? "default"
                    let producingIdentity = providerModelIdentity(
                        provider: cycleProvider, model: producingModel)
                    let selection = producingIdentity.flatMap {
                        independentReviewerSelection(
                            preferred: roles.binding(for: .critic),
                            producingIdentities: Set([$0]), registry: registry)
                    }
                    if let selection {
                        note("  ⎇ team review · \(selection.identity)")
                        if let review = try? await registry.complete(
                        providerId: selection.binding.providerId, model: selection.binding.model,
                        messages: [ChatMessage(role: .system, content: Copilot.reviewSystemPrompt),
                                   ChatMessage(role: .user, content: Copilot.reviewPrompt(task: baseGoal, diff: workDiff))],
                        settings: ModelSettings(temperature: 0.0, maxTokens: 700)),
                       !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            reviewText = review
                            notes.append("Independent team review (\(selection.identity)):\n" + review)
                        }
                    } else {
                        let reason = "Independent team review unavailable: configure another provider:model distinct from \(producingIdentity ?? "the producing worker")"
                        note("  ⚠ \(reason)")
                        notes.append(reason)
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
            // PER-MODEL SCORECARD: record THIS model's outcome — success is the REFEREE-measured `done`
            // (grounded + verifier-passed), NEVER the model's self-report, so a model that lies its way to
            // "done" can't score as strong. `failureReason`/`loopKinds`/`wasStuck`/`failureRate` capture the
            // WHY/WHAT/WHEN the audit asked for, reusing the `faulted`/`report` decisions already made above.
            let scorecardReason: String? = done ? nil
                : CaptainLearningSample.scorecardReason(
                    providerFault: outcome.providerFault, flaky: flaky,
                    verificationRejected: outcome.success && !verdict.isVerified,
                    loopKind: report.issues.first?.kind.rawValue, failureRate: failureRate, ungrounded: false)
            scorecard?.record(CaptainLearningSample(
                taskSignature: sig, taskTags: CaptainLearningSample.inferTaskTags(from: baseGoal),
                language: nil, role: "loop-cycle", providerId: cycleProvider, model: cycleModel,
                source: .liveEval, success: done,
                tokens: UsageCost.summarize(spans: delta).tokens, toolFailures: failures, atEpoch: now,
                failureReason: scorecardReason,
                failedAt: done ? nil : ((outcome.success && !verdict.isVerified) ? "verify" : "act"),
                loopKinds: report.issues.map { $0.kind.rawValue },
                wasStuck: !report.healthy, failureRate: failureRate))
            let actualEffortRecords: [ProviderEffortRecord] = {
                let checkpointID = outcome.checkpointId
                guard let checkpoint = try? checkpoints.load(id: checkpointID) else { return [] }
                return Array((checkpoint.providerEffortRecords ?? []).suffix(1))
            }()
            // GATED DGM bridge: once a hint proves itself (enough verified wins at a high rate), QUEUE it for
            // human/DGM review — NEVER auto-applied to Mythos's own prompts (the self-modification line).
            if let best = policy?.bestCandidate(forSignature: sig),
               PromotionGate.qualifies(wins: best.wins, trials: best.trials),
               promotions?.export(PromotionCandidate(signature: sig, hint: best.hint, wins: best.wins,
                                                      trials: best.trials, at: now)) == true {
                note("  ⤴ policy proven (\(best.wins)/\(best.trials)) — queued for review (never auto-applied)")
            }

            return GreatLoopCycleEnvelope(
                result: CycleResult(
                    doneAndVerified: done,
                    tokensSpent: UsageCost.summarize(spans: delta).tokens,
                    madeProgress: progressed,
                    signals: .init(failureRate: failureRate,
                                   iterationsUsed: trajectory.count,
                                   isStuck: !report.healthy),
                    summary: outcome.summary,
                    providerFault: outcome.providerFault
                ),
                progress: typedProgress,
                evidence: [verificationEvidence],
                checkpointID: outcome.checkpointId,
                providerEffortRecords: actualEffortRecords
            )
        }

        let calibration = memory.calibration(forGoal: goal)
        let assess: @Sendable (ReasoningControlState) -> EffortController.Assessment = { state in
            let struggling = state.consecutiveNoProgress > 0
            return EffortController.assess(
                goal: goal,
                signals: .init(
                    failureRate: struggling ? 1.0 : 0.0,
                    iterationsUsed: state.cycle,
                    isStuck: struggling
                ),
                calibration: calibration
            )
        }
        let goalFingerprint = builderCompatibilityContractID(
            root: root, goal: goal, adapter: .greatLoop
        )
        let reasoningStore = AtomicReasoningControlStore(projectRoot: root)
        let runner = ResumableGreatLoopRunner(
            runID: goalFingerprint + "-reasoning",
            route: .planned,
            goalFingerprint: goalFingerprint,
            caps: caps,
            store: reasoningStore,
            effort: { state in Self.providerReasoningEffort(assess(state).thinking) },
            runCycle: { request in
                let effort = assess(request.control)
                note("↻ cycle \(request.control.cycle + 1)/\(caps.maxCycles) · \(effort.rationale)"
                     + (calibration.samples > 0
                        ? " · learned±\(calibration.bias) from \(calibration.samples)" : ""))
                let cycle = await runCycle(
                    goal, effort, request.control.cycle, request.remainingTokens,
                    request.control.childCheckpointIDs["great-loop"]
                )
                return ResumableGreatLoopCycleResult(
                    doneAndVerified: cycle.result.doneAndVerified,
                    tokensSpent: cycle.result.tokensSpent,
                    progress: cycle.progress,
                    summary: cycle.result.summary,
                    evidence: cycle.evidence,
                    childCheckpointIDs: cycle.checkpointID.map { ["great-loop": $0] } ?? [:],
                    reasoningSummary: cycle.result.summary,
                    providerEffortRecords: cycle.providerEffortRecords
                )
            }
        )
        let decision: GreatLoopDecision
        do {
            decision = try await runner.run()
        } catch {
            err("great-loop durable state failed: \(error.localizedDescription)")
            printUsageDelta(from: [], to: await traceRecorder.all(), label: "great-loop usage", projectRoot: root)
            return 1
        }
        switch decision {
        case .stopDone(let reason): note("✓ great-loop done — \(reason)")
        case .stopBudget(let reason), .stopDeadline(let reason),
             .stopCycles(let reason), .stopNoProgress(let reason):
            note("■ great-loop stopped — \(reason)")
        case .keepGoing(let reason): note(reason)
        }
        printUsageDelta(from: [], to: await traceRecorder.all(), label: "great-loop usage", projectRoot: root)
        return decision.succeeded ? 0 : 1
    }
}
