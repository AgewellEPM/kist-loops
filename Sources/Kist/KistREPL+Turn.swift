import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Turn lifecycle: evidence, arming, interruptible turn, context, media, verification, heavy-route (run() decomposition — behavior-identical methods relocated from KistREPL.run())
extension KistREPL {
        func resetTurnEvidence() {
            archivedTurnEvidence.removeAll(keepingCapacity: true)
            submittedTurnSpans.removeAll(keepingCapacity: true)
            repairPhaseFailed = false
            recorder?.reset()
        }
        func archiveCurrentEvidencePhase() {
            archivedTurnEvidence.append(contentsOf: recorder?.snapshot() ?? [])
            recorder?.reset()
        }
        func turnEvidenceSnapshot() -> [ActionRecord] {
            archivedTurnEvidence + (recorder?.snapshot() ?? [])
        }
        func reviewBaselineIfArmed(intent: TaskBrief.Intent? = nil) -> String? {
            let automaticBuild = intent?.expectsMutation == true && copilot.automaticBuildReview
            guard copilot.enabled || copilot.autoSecondOpinion || automaticBuild else { return nil }
            return Self.workingTreeDiff(projectRoot: projectRoot)
        }
        // Show the "this terminal can't render inline images" hint at most once per session, so a
        // user on Terminal.app (no inline-image protocol) isn't left thinking the drop silently broke.

        func rememberHumanTurn(user: String,
                               assistantSummary: String,
                               outcomeContract: OutcomeContract? = nil) {
            humanTranscript.append(ChatMessage(role: .user, content: user))
            if !assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                humanTranscript.append(ChatMessage(role: .assistant, content: assistantSummary))
            }
            if humanTranscript.count > 20 { humanTranscript = Array(humanTranscript.suffix(20)) }
            if let outcomeContract { lastOutcomeContract = outcomeContract }
        }

        /// Model-turn wrapper: a hard cancel means "drop this turn," including its authority. A single
        /// ESC interjection keeps the resumable goal and partial conversational context.
        func rememberModelTurn(user: String,
                               assistantSummary: String,
                               outcomeContract: OutcomeContract) {
            guard lastTurnInterruption != .cancel else {
                lastOutcomeContract = nil
                return
            }
            rememberHumanTurn(user: user, assistantSummary: assistantSummary,
                              outcomeContract: outcomeContract)
        }

        // Apply the active permission tier to `loop` right before a turn runs. If the user shuffled onto
        // bypass (guards off), confirm ONCE this session with a typed y/N before it takes effect — a
        // declined confirm drops to normal. Cycling the bar never arms guards-off by itself.
        func armTurnLoop() {
            if perm.needsBypassConfirm {
                FileHandle.standardOutput.write(Data("\u{001B}[31;1m⚠ Arm bypass permissions (guards OFF)? Skips ALL approval prompts this session. (y/N) \u{001B}[0m".utf8))
                let ans = StdinArbiter.shared.withStdin {
                    (Swift.readLine(strippingNewline: true) ?? "")
                        .trimmingCharacters(in: .whitespaces).lowercased()
                }
                if ans == "y" || ans == "yes" {
                    perm.confirmBypass()
                    print("\u{001B}[31;1m⚠ bypass armed — guards off for this session (shift+tab to leave)\u{001B}[0m")
                } else {
                    perm.declineBypass()
                    print("\u{001B}[37m↳ staying in normal mode (approvals on)\u{001B}[0m")
                }
            }
            loop = perm.arm(loop)
        }

        // R1: set by runTurnInterruptible when ESC stopped the turn; selfMonitor consults + resets
        // it so a user interrupt never books a false "task failed" obstacle lesson.

        // Preserve the exact report shown by the last completed turn. The recorder is reset before
        // slash-command dispatch, so rebuilding `/confidence` from it would always explain an empty turn.

        // The SINGLE safe path for every conversational turn: run it under the esc-interrupt watcher,
        // shuttling the inout transcript through a box (it can't cross the escaping work closure). The
        // caller MUST arm the loop first (armTurnLoop / perm.arm) — this is why direct `loop.turn(...)`
        // calls are forbidden: a stale guards-off loop could otherwise run a /command or task turn after
        // the user left bypass (Codex CRITICAL). Source-pinned: the only `.turn(transcript:` is here.
        func runTurnInterruptible(loop l: HeadlessAgentLoop, userInput: String,
                                  attachments: [MediaAttachment] = [],
                                  rawRequest: String? = nil,
                                  resolvedIntent: TaskBrief.Intent? = nil,
                                  delegationGrant: DelegationGrant? = nil,
                                  authoredBy: ProviderBinding? = nil) async -> HeadlessAgentLoop.Outcome {
            let facts = runtimeCapabilityReport(loop: l, binding: authoredBy ?? activeBinding).render()
            proofStore?.record(.init(kind: .runtimeFacts, tool: nil, success: nil, text: facts))
            let preTurnTranscript = transcript
            let tBox = MutableBox(transcript)
            lastTurnInterrupted = false   // fresh turn; post-turn guards read it, next turn resets it
            lastTurnInterruption = nil
            // Collection is session-wide (submit → routing → model → post-review). InterruptibleTurn
            // borrows that session's one watcher and only registers this active model task.
            // R1: single ESC = interject (take over, work stays resumable); double ESC = hard
            // cancel (transcript restored + checkpoint marked ABANDONED — kept on disk so a
            // panic ESC-hammer is never irreversible, but hidden from --list/--resume-last).
            let reasonBox = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
            let oc = await InterruptibleTurn.run(onInterrupt: { reason in
                reasonBox.value = reason
                switch reason {
                case .interject:
                    print("\n\u{001B}[33m⎋ interrupted — stopping after the current step; your turn (progress saved)\u{001B}[0m")
                case .cancel:
                    print("\n\u{001B}[33m⎋⎋ cancelled — dropping this turn\u{001B}[0m")
                }
            }) {
                var t = tBox.value
                let outcome = await l.turn(transcript: &t, userInput: facts + "\n\n" + userInput,
                                           attachments: attachments,
                                           rawRequest: rawRequest ?? userInput,
                                           resolvedIntent: resolvedIntent,
                                           delegationGrant: delegationGrant)
                tBox.value = t
                return outcome
            }
            // "Dropping this turn" must MEAN dropped: on cancel the cancelled turn's user message +
            // partial output must not keep colouring future context (review catch).
            transcript = (reasonBox.value == .cancel) ? preTurnTranscript : tBox.value
            lastTurnInterruption = reasonBox.value
            lastTurnInterrupted = reasonBox.value != nil
            // R2a: interject = what you typed IS the next instruction (queued + drained right
            // away); hard cancel = typed + queued input is dropped with the turn.
            switch reasonBox.value {
            case .interject: TurnInputQueue.shared.commitPending()
            case .cancel:    TurnInputQueue.shared.clearAll()
            case nil:        break
            }
            if reasonBox.value == .cancel, !oc.success, !oc.checkpointId.isEmpty {
                LoopCheckpointStore().abandon(id: oc.checkpointId)
            }
            if reasonBox.value == .interject, !oc.success, !oc.checkpointId.isEmpty {
                print("\u{001B}[2m· paused — resume later with: kist --resume \(oc.checkpointId)\u{001B}[0m")
            }
            return oc
        }

        func retrievalContext(for objective: String) -> CaptainRetrievalContext? {
            guard advisoryMemoryEnabled else { return nil }
            let clean = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let evidence = CaptainProjectEvidence.capture(projectRoot: projectRoot)
            let specialists = SpecialistRegistry(projectRoot: projectRoot).load()
            let strategy = CaptainStrategist.plan(objective: clean,
                                                  evidence: evidence,
                                                  specialists: specialists)
            return OrganizationalLearningStore(projectRoot: projectRoot)
                .retrievalContext(objective: clean, strategy: strategy, limit: 6)
        }

        func attachCaptainContext(to compiled: String, objective: String) -> String {
            // SELF-AWARENESS: the Captain must always know WHAT IT IS. Without this, a bare
            // "assess this system" gets a generic "what system do you mean?" — because the model has
            // no sense of self. Injected on every turn so "this system / you / yourself / kist" is never
            // ambiguous, and self-assessment reads its OWN source instead of asking clarifying questions.
            var out = kistSelfContext() + "\n\n" + compiled
            if let retrieval = retrievalContext(for: objective) {
                if Self.stdoutColorEnabled(projectRoot: projectRoot) {
                    print("\u{001B}[2m↳ \u{001B}[0m\u{001B}[96;1m🧠 Captain retrieval\u{001B}[0m\u{001B}[2m · \(retrieval.retrieved.count) memory · \(retrieval.decisionCards.count) decision cards\u{001B}[0m")
                } else {
                    print("↳ Captain retrieval · \(retrieval.retrieved.count) memory · \(retrieval.decisionCards.count) decision cards")
                }
                out = Self.attachCaptainRetrievalContext(to: out, retrieval: retrieval)
            }
            return out
        }

        /// Kist's sense of self — who it is, where its own code lives, and that self-referential words
        /// mean IT. Concise on purpose (a few sentences); it rides every turn so the Captain never loses
        /// the thread of its own identity.
        func kistSelfContext() -> String {
            """
            [WHO YOU ARE — read before answering]
            You are Kist: a coding + research Captain with bounded execution and verification gates. \
            The host supplies current Runtime capabilities for each model attempt. Use those facts \
            when describing this session; a wired feature is not a tested or independently verified result. \
            You are NOT a generic chat assistant. Your OWN source code (Swift) lives at \
            /Volumes/PRO-G40/kist-loops. Right now you are operating in the project: \(projectRoot).
            When the operator says "this system", "yourself", "you", "your code", "the captain", or \
            "kist", they mean YOU — Kist. Never answer a question about yourself with "what system do \
            you mean". To assess or improve yourself, READ your own source under /Volumes/PRO-G40/kist-loops \
            (list_files / read_file), take stock of your capabilities (/code, /research, /council, \
            /fleet, /model, memory/retrieval), then give a concrete grounded \
            verdict — real strengths, honest gaps, and the single highest-value next move. Operator TASKS \
            (build/fix/edit) still act on the current project above; only questions about YOURSELF read \
            your own source. Read AGENTS.md before proposing self-evolution changes. Do not claim \
            unattended evolution, automatic promotion, benchmark improvement, or independent review \
            without the applicable host evidence. Model providers cannot enable missing runtime authority.
            """
        }

        // Send a turn that carries media, routing to a vision model. Images go to any vision model;
        // video/audio + Gemini file refs are Gemini-only, so we borrow Gemini (disclosed) unless the
        // active model already is it. Shared by the drag-a-path and clipboard /paste flows.
        func runMediaTurn(_ atts: [MediaAttachment], prompt: String) async {
            // Inline image protocols (OSC/APC), ANSI previews, and binary/fullscreen media renderers
            // must own a normal terminal. Abandon sticky capture before emitting even the first byte.
            self.pinnedBar.suspend()
            armTurnLoop()
            if let preview = TerminalMediaRenderer.preview(attachments: atts) {
                FileHandle.standardOutput.write(Data(("\n" + preview + "\n").utf8))
            } else if !noInlinePreviewHintShown {
                // No inline preview here (e.g. Terminal.app). The model still SEES the media —
                // tell the user why nothing rendered + how to get inline previews, just once.
                noInlinePreviewHintShown = true
                print("\u{001B}[37m↳ \(TerminalMediaRenderer.status()) (the model still receives the media)\u{001B}[0m")
            }
            // Keep ordinary "describe this" media turns light, but preserve an explicit build contract when
            // the user's prompt says to fix/implement/change what the screenshot shows. The semantic intent
            // is resolved from the same raw prompt passed into AgentCore; attachment presence must not erase it.
            let text = prompt.isEmpty ? "Describe what's in the attached media and note anything important." : prompt
            let mediaMode: PromptCompiler.Mode = perm.mode.isPlan ? .plan : .inline
            let mediaOutcome = PromptCompiler.resolveOutcome(
                text, mode: mediaMode, previous: lastOutcomeContract)
            let mediaIntent = mediaOutcome.intent
            proofStore?.record(.init(kind: .routeSelected, tool: nil, success: nil,
                                     text: "intent=\(mediaIntent.rawValue) authority=\(mediaOutcome.authority.rawValue) outcome=\(mediaOutcome.expectedOutcome.rawValue) execution=inline-media"))
            if mediaIntent == .delegate {
                let blocker = "Delegating an attached media item is not supported yet because the child would not receive the attachment. Ask Kist to inspect it directly, or save it and delegate a self-contained task that names the file path."
                print("\u{001B}[33m\(blocker)\u{001B}[0m")
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: false, text: "failed — \(blocker)"))
                proofStore?.record(.init(kind: .turnFinalized, tool: nil, success: false,
                                         text: "intent=delegate expected=delegation result=failed unsupported-media-delegation"))
                rememberHumanTurn(user: text, assistantSummary: blocker,
                                  outcomeContract: mediaOutcome)
                return
            }
            let mediaInstruction = mediaIntent.expectsMutation
                ? "The media is ATTACHED directly to this message. Inspect it as evidence, then carry out the requested workspace change with the available tools and verify it. Do not call view_image/read_file merely to locate the attachment and do not ask for its path—it is already here."
                : "The media is ATTACHED directly to this message — look at it and answer from what you actually see/hear. It is ALREADY provided to you; do NOT call view_image, read_file, run_command, or any tool to find, open, load, or fetch it, and do NOT ask for a file path. Answer directly and finish."
            let taskBrief = briefCompiler?(
                text, roleSelection.bindings, mediaMode,
                humanTranscript, mediaOutcome) ?? text
            let compiled = taskBrief + "\n\n" + mediaInstruction
            let reviewBaseline = reviewBaselineIfArmed(intent: mediaIntent)
            let mustUseGemini = atts.contains { $0.kind != .image || $0.fileURI != nil }
            // Vision capability is a property of the model the loop is ACTUALLY running (activeBinding),
            // NOT the default — after an auto-route switch these differ, and keying off the default could
            // send media to a non-vision model (Codex, 2026-07-03). Single-source-of-truth invariant.
            let activeIsBorrow = activeBinding.providerId == visionProviderId
            let activeHandles = activeIsBorrow || (!mustUseGemini && (providerSupportsVision?(activeBinding) ?? false))
            // The vision lane is cooldown-aware: skip a candidate another kist process just watched
            // rate-limit, fail-open to the preferred engine when everything vision-capable is cooling.
            // (Candidates default to [visionProviderId] so minimal wirings keep the old behavior.)
            let coolingDown = providerCoolingDown ?? { _ in false }
            let visionCandidates = visionProviderCandidates.isEmpty
                ? [visionProviderId].compactMap { $0 } : visionProviderCandidates
            var oc: HeadlessAgentLoop.Outcome
            var turnAuthor = activeBinding
            if activeHandles {
                oc = await runTurnInterruptible(loop: loop, userInput: compiled, attachments: atts,
                                                rawRequest: text, resolvedIntent: mediaIntent)
            } else if let vid = Self.chooseVisionProvider(candidates: visionCandidates,
                                                          mustUseGemini: mustUseGemini,
                                                          coolingDown: coolingDown),
                      let loopFactory {
                if coolingDown(vid) {
                    print("\u{001B}[33m↳ \(vid) is cooling down after a recent rate limit, but it's the only vision option — trying anyway\u{001B}[0m")
                } else if vid != visionCandidates.first {
                    print("\u{001B}[33m↳ \(visionCandidates.first ?? "?") is cooling down (recent rate limit) — using \(vid) for this media turn\u{001B}[0m")
                }
                print("\u{001B}[37m↳ \(activeBinding.providerId) can't see this media — routing this turn to \(vid), back to \(activeBinding.providerId) after\u{001B}[0m")
                turnAuthor = ProviderBinding(providerId: vid)
                let visionLoop = perm.arm(loopFactory(turnAuthor, roleSelection.bindings, perm.mode.isPlan, showReasoning, extendedThinking))
                oc = await runTurnInterruptible(loop: visionLoop, userInput: compiled, attachments: atts,
                                                rawRequest: text, resolvedIntent: mediaIntent,
                                                authoredBy: turnAuthor)
            } else {
                print("\u{001B}[31m↳ no vision-capable provider configured (add a Gemini key) — sending text only\u{001B}[0m")
                oc = await runTurnInterruptible(loop: loop, userInput: compiled,
                                                rawRequest: text, resolvedIntent: mediaIntent)
            }
            // Media parity with the text-turn lane (2026-08-14: a gemini rateLimited media turn died
            // terminally — the ONLY REPL lane with no substitution). A transient live failure benches
            // the provider CROSS-PROCESS even when no substitute exists; if another vision candidate
            // is warm, retry the turn ONCE on it. R2a: never re-run a turn the user stopped.
            if !oc.success, !lastTurnInterrupted {
                if Self.transientProviderFailure(summary: oc.summary) {
                    recordProviderCooldown?(turnAuthor.providerId, oc.summary)
                }
                if let loopFactory,
                   let sub = Self.mediaSubstitutionDecision(success: oc.success, summary: oc.summary,
                                                            trajectory: recorder?.snapshot() ?? [],
                                                            failedProviderId: turnAuthor.providerId,
                                                            candidates: visionCandidates,
                                                            mustUseGemini: mustUseGemini,
                                                            coolingDown: coolingDown) {
                    print("\u{001B}[33m↳ model substitution\u{001B}[0m · \(turnAuthor.providerId) benched for \(sub.reason); retrying this media turn on \(sub.replacement)")
                    turnAuthor = ProviderBinding(providerId: sub.replacement)
                    let retryLoop = perm.arm(loopFactory(turnAuthor, roleSelection.bindings, perm.mode.isPlan, showReasoning, extendedThinking))
                    oc = await runTurnInterruptible(loop: retryLoop, userInput: compiled, attachments: atts,
                                                    rawRequest: text, resolvedIntent: mediaIntent,
                                                    authoredBy: turnAuthor)
                    if !oc.success, !lastTurnInterrupted, Self.transientProviderFailure(summary: oc.summary) {
                        recordProviderCooldown?(turnAuthor.providerId, oc.summary)
                    }
                }
            }
            rememberModelTurn(user: text, assistantSummary: oc.summary,
                              outcomeContract: mediaOutcome)
            await runCopilotReview(task: text, answer: oc.summary, allowAdvisory: true,
                                   authoredBy: turnAuthor, baselineDiff: reviewBaseline,
                                   turnIntent: mediaIntent, turnSucceeded: oc.success)
            // Monitoring must consume the complete submitted turn, including any reviewer-driven repair.
            // A failed repair cannot inherit the primary attempt's success in learning/telemetry.
            let completedTurn = recordVerificationAndFinal(outcome: oc, intent: mediaIntent)
            selfMonitor(goal: text, intent: mediaIntent, success: completedTurn)
            await printTurnUsage()
            await recordSubmittedTurnLearning(outcomeSummary: oc.summary, success: completedTurn,
                                              authoredBy: turnAuthor)
        }

        // SELF-MONITOR: analyze the just-finished turn's trajectory for reliability issues (runaway
        // loop / failure spike / read-only spin) and learn an obstacle from anything unhealthy or
        // failed. Surfaced dimly; recorded as advisory memory for future briefs.
        func selfMonitor(goal: String, intent: TaskBrief.Intent, success: Bool) {
            // R1: an ESC'd turn is a user decision, not a reliability signal — recording it as a
            // failure/obstacle would teach kist that interrupted goals fail. (Read-only: the flag
            // is reset at the START of the next turn so the other post-turn guards can read it too.)
            if lastTurnInterrupted { return }
            var issueLabels: [String] = []
            if recorder != nil {
                let report = TrajectoryAnalyzer.analyze(turnEvidenceSnapshot(),
                                                        taskIntent: intent)
                issueLabels = report.issues.map { $0.kind.rawValue }
                if !report.healthy {
                    print("\u{001B}[37m⚙ self-check · \(issueLabels.joined(separator: ", "))\u{001B}[0m")
                }
                if let lessonStore {
                    let at = Date().timeIntervalSince1970
                    for issue in report.issues {
                        lessonStore.record(Lesson(kind: .obstacle,
                            text: "\(issue.kind.rawValue): \(issue.detail) [goal: \(goal.prefix(80))]", source: nil, at: at))
                    }
                    if !success {
                        lessonStore.record(Lesson(kind: .obstacle, text: "task failed: \(goal.prefix(120))", source: nil, at: at))
                    }
                }
            }
        }

        func invokePlanExecute(authorityGoal: String,
                               priorResultContext: PriorResultContext?,
                               roles: RoleBindings,
                               forcePlanned: Bool = false) async -> HeavyRouteResult {
            if !forcePlanned, let automaticBuild {
                return await automaticBuild(authorityGoal, priorResultContext, roles)
            }
            if let priorResultContext, !priorResultContext.isEmpty,
               let planExecuteWithContext {
                return await planExecuteWithContext(authorityGoal, priorResultContext, roles)
            }
            if let planExecute {
                return await planExecute(authorityGoal, roles)
            }
            return HeavyRouteResult(
                exitCode: 2, interruption: nil,
                review: .notApplicable("plan-execute was unavailable in this REPL"),
                verification: .unavailable("plan-execute never started"))
        }

        /// Run one of the existing long-running REPL routes and close this submitted turn from the
        /// runner's actual result. The route remains responsible for doing the work; this boundary only
        /// prevents a successful-looking synthetic "handed off" record after a failure or ESC.
        @discardableResult
        func runHeavyRoute(goal: String,
                           intent: TaskBrief.Intent,
                           mode: PromptCompiler.Mode,
                           execution: String,
                           startProof: Bool,
                           outcomeContract: OutcomeContract? = nil,
                           rememberInConversation: Bool = false,
                           operation: () async -> HeavyRouteResult) async -> HeavyRouteResult {
            if startProof { proofStore?.startTurn(goal: goal) }
            proofStore?.record(HeavyRouteProof.routeEntry(intent: intent, mode: mode,
                                                          execution: execution))

            let result = await operation()
            for entry in HeavyRouteProof.completionEntries(result: result, intent: intent,
                                                            mode: mode, execution: execution) {
                proofStore?.record(entry)
            }
            // Mutation routes always become the active goal so a failed-result follow-up can continue
            // them. Read-only heavy commands opt in only when their result is part of conversational flow;
            // generic proof summaries must not displace a real council plan consumed by `/build`.
            if rememberInConversation || intent.expectsMutation || intent == .desktop {
                if result.interruption == .cancel {
                    lastOutcomeContract = nil
                    return result
                }
                let resultCanBecomeContext = result.satisfiesExpectedOutcome(
                    intent: intent, mode: mode)
                let rememberedContract = (outcomeContract ?? OutcomeContract(
                    desiredResult: goal,
                    intent: intent,
                    mode: mode,
                    authority: mode == .plan ? .planMode
                        : (intent.expectsMutation || intent == .desktop
                            ? .explicitRequest : .readOnly),
                    isContinuation: false))
                    .withResultContext(
                        summary: resultCanBecomeContext ? result.substantiveSummary : nil,
                        artifactReferences: resultCanBecomeContext ? result.artifactReferences : [],
                        succeeded: resultCanBecomeContext)
                rememberHumanTurn(user: goal,
                                  assistantSummary: result.transcriptSummary,
                                  outcomeContract: rememberedContract)
            }
            return result
        }

        func unavailableHeavyRoute(_ execution: String) -> HeavyRouteResult {
            HeavyRouteResult(exitCode: 2, interruption: nil,
                             review: .notApplicable("\(execution) was unavailable in this REPL"),
                             verification: .unavailable("\(execution) never started"))
        }

        /// Close the durable proof stream with one execution-grounded verification assessment and one
        /// canonical final result. Model review is recorded separately and never upgrades this verdict.
        @discardableResult
        func recordVerificationAndFinal(outcome: HeadlessAgentLoop.Outcome,
                                        intent: TaskBrief.Intent) -> Bool {
            let trajectory = turnEvidenceSnapshot()
            let expected = PromptCompiler.expectedOutcome(
                intent: intent,
                mode: perm.mode.isPlan ? .plan : .inline)
            var deterministicVerification: Bool?
            let fulfilledMutationContract = trajectory.contains {
                $0.success && ($0.observedEffects.confirmsMutation
                    || $0.observedEffects.progress == .delegatedMutation)
            }
            let fulfilledEvidenceContract = trajectory.contains {
                $0.success && [.research, .evidence].contains($0.observedEffects.progress)
            }
            let fulfilledDelegationContract = trajectory.contains {
                $0.success && [.delegation, .delegatedMutation].contains($0.observedEffects.progress)
            }
            let fulfilledExternalAction = trajectory.contains {
                $0.success && $0.observedEffects.progress == .externalState
            }
            if expected == .mutation, !fulfilledMutationContract {
                deterministicVerification = false
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: false,
                                         text: "failed — this turn promised a mutation but recorded no successful local or delegated mutation"))
            } else if expected == .delegation, !fulfilledDelegationContract {
                deterministicVerification = false
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: false,
                                         text: "failed — this turn promised delegation but recorded no completed child result"))
            } else if expected == .evidence, !fulfilledEvidenceContract {
                deterministicVerification = false
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: false,
                                         text: "failed — this turn promised research evidence but no successful evidence-gathering action was recorded"))
            } else if expected == .externalAction, !fulfilledExternalAction {
                deterministicVerification = false
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: false,
                                         text: "failed — this turn promised an external action but no successful state-changing action was recorded"))
            } else if let lastSource = trajectory.lastIndex(where: {
                $0.observedEffects.requiresBuildVerification
            }) {
                let mutation = trajectory[lastSource]
                let verified = mutation.success && trajectory.dropFirst(lastSource + 1).contains {
                    $0.success && $0.observedEffects.verification == .buildOrTest
                }
                deterministicVerification = verified
                let text: String
                if !mutation.success {
                    text = "unverified — the final source mutation failed"
                } else if verified {
                    text = "passed — an executed build/test succeeded after the final source mutation"
                } else {
                    text = "unverified — no executed build/test succeeded after the final source mutation"
                }
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: verified, text: text))
            } else if expected == .mutation {
                deterministicVerification = true
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: true,
                                         text: "passed — successful non-source or child-verified delegated mutation recorded; no parent-local source build was required"))
            } else if expected == .delegation {
                deterministicVerification = true
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: true,
                                         text: "passed — a typed child completion was recorded"))
            } else if expected == .evidence {
                deterministicVerification = true
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: true,
                                         text: "passed — successful grounded evidence gathering was recorded"))
            } else if expected == .externalAction {
                deterministicVerification = true
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: true,
                                         text: "passed — a successful external state-changing action was recorded"))
            } else {
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: nil,
                                         text: "not required — this turn recorded no source mutation"))
            }
            let finalSuccess = outcome.success && !repairPhaseFailed
                && !lastTurnInterrupted && deterministicVerification != false
            let repairSuffix = repairPhaseFailed ? " repair=failed-or-interrupted" : ""
            proofStore?.record(.init(kind: .turnFinalized, tool: nil, success: finalSuccess,
                                     text: "intent=\(intent.rawValue) expected=\(expected.rawValue) result=\(finalSuccess ? "completed" : "failed")\(repairSuffix) checkpoint=\(outcome.checkpointId)"))
            // BUILD STATUS CONTRACT: for any turn that was supposed to change code, print a hard
            // PATCH→APPLY→FILES→BUILD/TEST→BOARD checklist from the recorded trajectory. This makes
            // "I will apply the patch" vs "the patch is applied and verified" impossible to confuse —
            // the exact gap Luke hit where a plan was laundered into a done summary.
            if expected == .mutation {
                if AgentMetadataRequest.isRegistrationOnly(trajectory) {
                    print("Agent registration: \(finalSuccess ? "completed" : "failed")")
                } else if DecisionToolRequest.isDefinitionOnly(trajectory) {
                    print("Decision tool: \(finalSuccess ? "completed" : "failed")")
                } else {
                    let status = BuildStatusReport(
                        trajectory: trajectory, finalSuccess: finalSuccess)
                    print(status.render(color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
                }
            }
            return finalSuccess
        }

        // /copilot: after a turn that MUTATED files, have the assigned co-reviewer critique the actual,
        // turn-scoped working-tree change. Review is advisory evidence; when repair authority is armed,
        // findings return to the original author for a bounded repair. Build/tests remain verification.
}
