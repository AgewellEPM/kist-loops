import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// run()'s helper methods, promoted out of the giant method now that KistREPL is a class and its
// session state lives on self. Behavior-identical; just relocated. (run() decomposition)
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

        func rememberHumanTurn(user: String, assistantSummary: String) {
            humanTranscript.append(ChatMessage(role: .user, content: user))
            if !assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                humanTranscript.append(ChatMessage(role: .assistant, content: assistantSummary))
            }
            if humanTranscript.count > 20 { humanTranscript = Array(humanTranscript.suffix(20)) }
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
                                  resolvedIntent: TaskBrief.Intent? = nil) async -> HeadlessAgentLoop.Outcome {
            let preTurnTranscript = transcript
            let tBox = MutableBox(transcript)
            lastTurnInterrupted = false   // fresh turn; post-turn guards read it, next turn resets it
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
                let outcome = await l.turn(transcript: &t, userInput: userInput,
                                           attachments: attachments,
                                           rawRequest: rawRequest,
                                           resolvedIntent: resolvedIntent)
                tBox.value = t
                return outcome
            }
            // "Dropping this turn" must MEAN dropped: on cancel the cancelled turn's user message +
            // partial output must not keep colouring future context (review catch).
            transcript = (reasonBox.value == .cancel) ? preTurnTranscript : tBox.value
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
            You are Kist: an autonomous coding + research Captain that orchestrates models, tools, a \
            research/discovery loop, an AI council of specialists, durable memory, and a worker fleet. \
            You are NOT a generic chat assistant. Your OWN source code (Swift) lives at \
            /Volumes/PRO-G40/kist-loops. Right now you are operating in the project: \(projectRoot).
            When the operator says "this system", "yourself", "you", "your code", "the captain", or \
            "kist", they mean YOU — Kist. Never answer a question about yourself with "what system do \
            you mean". To assess or improve yourself, READ your own source under /Volumes/PRO-G40/kist-loops \
            (list_files / read_file), take stock of your capabilities (/code, /research, /council, \
            /fleet, /model, local Qwen + cloud models, memory/retrieval), then give a concrete grounded \
            verdict — real strengths, honest gaps, and the single highest-value next move. Operator TASKS \
            (build/fix/edit) still act on the current project above; only questions about YOURSELF read \
            your own source.
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
            let mediaIntent = PromptCompiler.inferIntent(text, mode: mediaMode)
            proofStore?.record(.init(kind: .routeSelected, tool: nil, success: nil,
                                     text: "intent=\(mediaIntent.rawValue) outcome=\(PromptCompiler.expectedOutcome(intent: mediaIntent, mode: mediaMode).rawValue) execution=inline-media"))
            let mediaInstruction = mediaIntent.expectsMutation
                ? "The media is ATTACHED directly to this message. Inspect it as evidence, then carry out the requested workspace change with the available tools and verify it. Do not call view_image/read_file merely to locate the attachment and do not ask for its path—it is already here."
                : "The media is ATTACHED directly to this message — look at it and answer from what you actually see/hear. It is ALREADY provided to you; do NOT call view_image, read_file, run_command, or any tool to find, open, load, or fetch it, and do NOT ask for a file path. Answer directly and finish."
            let compiled = text + "\n\n" + mediaInstruction
            let reviewBaseline = reviewBaselineIfArmed(intent: mediaIntent)
            let mustUseGemini = atts.contains { $0.kind != .image || $0.fileURI != nil }
            // Vision capability is a property of the model the loop is ACTUALLY running (activeBinding),
            // NOT the default — after an auto-route switch these differ, and keying off the default could
            // send media to a non-vision model (Codex, 2026-07-03). Single-source-of-truth invariant.
            let activeIsBorrow = activeBinding.providerId == visionProviderId
            let activeHandles = activeIsBorrow || (!mustUseGemini && (providerSupportsVision?(activeBinding) ?? false))
            let oc: HeadlessAgentLoop.Outcome
            var turnAuthor = activeBinding
            if activeHandles {
                oc = await runTurnInterruptible(loop: loop, userInput: compiled, attachments: atts,
                                                rawRequest: text, resolvedIntent: mediaIntent)
            } else if let vid = visionProviderId, let loopFactory {
                print("\u{001B}[37m↳ \(activeBinding.providerId) can't see this media — routing this turn to \(vid), back to \(activeBinding.providerId) after\u{001B}[0m")
                turnAuthor = ProviderBinding(providerId: vid)
                let visionLoop = perm.arm(loopFactory(turnAuthor, roleSelection.bindings, perm.mode.isPlan, showReasoning, extendedThinking))
                oc = await runTurnInterruptible(loop: visionLoop, userInput: compiled, attachments: atts,
                                                rawRequest: text, resolvedIntent: mediaIntent)
            } else {
                print("\u{001B}[31m↳ no vision-capable provider configured (add a Gemini key) — sending text only\u{001B}[0m")
                oc = await runTurnInterruptible(loop: loop, userInput: compiled,
                                                rawRequest: text, resolvedIntent: mediaIntent)
            }
            rememberHumanTurn(user: text, assistantSummary: oc.summary)
            await runCopilotReview(task: text, answer: oc.summary, allowAdvisory: true,
                                   authoredBy: turnAuthor, baselineDiff: reviewBaseline,
                                   turnIntent: mediaIntent, turnSucceeded: oc.success)
            // Monitoring must consume the complete submitted turn, including any reviewer-driven repair.
            // A failed repair cannot inherit the primary attempt's success in learning/telemetry.
            let completedTurn = recordVerificationAndFinal(outcome: oc, intent: mediaIntent)
            selfMonitor(goal: text, intent: mediaIntent, success: completedTurn)
            await printTurnUsage()
            recordSubmittedTurnLearning(outcomeSummary: oc.summary, success: completedTurn)
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

        /// Run one of the existing long-running REPL routes and close this submitted turn from the
        /// runner's actual result. The route remains responsible for doing the work; this boundary only
        /// prevents a successful-looking synthetic "handed off" record after a failure or ESC.
        @discardableResult
        func runHeavyRoute(goal: String,
                           intent: TaskBrief.Intent,
                           mode: PromptCompiler.Mode,
                           execution: String,
                           startProof: Bool,
                           operation: () async -> HeavyRouteResult) async -> HeavyRouteResult {
            if startProof { proofStore?.startTurn(goal: goal) }
            proofStore?.record(HeavyRouteProof.routeEntry(intent: intent, mode: mode,
                                                          execution: execution))

            let result = await operation()
            for entry in HeavyRouteProof.completionEntries(result: result, intent: intent,
                                                            mode: mode, execution: execution) {
                proofStore?.record(entry)
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
                    || (intent == .fleet && $0.observedEffects.progress == .delegation))
            }
            let fulfilledEvidenceContract = trajectory.contains {
                $0.success && [.research, .evidence].contains($0.observedEffects.progress)
            }
            let fulfilledExternalAction = trajectory.contains {
                $0.success && $0.observedEffects.progress == .externalState
            }
            if expected == .mutation, !fulfilledMutationContract {
                deterministicVerification = false
                proofStore?.record(.init(kind: .verificationAssessment, tool: nil,
                                         success: false,
                                         text: "failed — this turn promised a mutation but recorded no successful mutation or fleet delegation"))
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
                                         text: "passed — successful non-source mutation or fleet delegation recorded; no source build was required"))
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
                let status = BuildStatusReport(trajectory: trajectory)
                print(status.render(color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
            }
            return finalSuccess
        }

        // /copilot: after a turn that MUTATED files, have the assigned co-reviewer critique the actual,
        // turn-scoped working-tree change. Review is advisory evidence; when repair authority is armed,
        // findings return to the original author for a bounded repair. Build/tests remain verification.
        // Pick the reviewer: a model DIFFERENT from the one that just answered — never self-review (that's
        // the "just repeat yourself" anti-pattern Luke called out). Team mode's explicit `co` wins if it's
        // distinct; otherwise auto-pick a configured provider ≠ the answering one, cheap/reliable first.
        // nil ⇒ no distinct reviewer available (skip the review rather than let a model grade its own work).
        func autoReviewer(answeredBy: ProviderBinding) -> ProviderBinding? {
            if let co = copilot.co, Copilot.isDistinctReviewer(co, from: answeredBy) { return co }
            let configured = Set(providerAliases.values)
            let prefer = ["claude-cli", "gemini", "deepseek", "mimo", "codex-cli", "moonshot", "zhipu", "grok"]
            if let pid = prefer.first(where: { $0 != answeredBy.providerId && configured.contains($0) }) {
                return ProviderBinding(providerId: pid)
            }
            if let pid = configured.first(where: { $0 != answeredBy.providerId }) {
                return ProviderBinding(providerId: pid)
            }
            return nil
        }

        // The grounding handed to the second-opinion reviewer so it isn't context-blind. Same self-identity
        // brief the primary turn rides on (so the reviewer knows what "Kist" IS) + durable project memory
        // (AGENTS.md/CLAUDE.md/facts). Without this the reviewer answers "I've never heard of this system,
        // can't verify the claims" instead of actually reviewing — the brain-dead second opinion.
        func reviewerGrounding() -> String {
            var parts = [kistSelfContext()]
            let facts = ProjectMemory(root: projectRoot).facts()
            if !facts.isEmpty { parts.append("[PROJECT MEMORY]\n" + facts) }
            return parts.joined(separator: "\n\n")
        }

        // One advisory review pass. Reviews the working-tree DIFF for a coding turn, else the substantive
        // ANSWER text. The result distinguishes "not applicable" from a missing reviewer response so a
        // silent/failed model can never be counted as a clean vote.
        func runOneReview(task: String, answer: String = "", reviewer: ProviderBinding? = nil,
                          answeredBy: ProviderBinding? = nil,
                          baselineDiff: String? = nil) async -> Copilot.ReviewAttempt {
            guard let modelComplete else { return .incomplete("review completion is unavailable in this mode") }
            let author = answeredBy ?? activeBinding
            // `reviewer` lets ULTRA mode rotate the second opinion through a roster of minds; nil ⇒ the
            // default top-ranked distinct reviewer.
            guard let co = reviewer ?? autoReviewer(answeredBy: author) else {
                return .incomplete("no distinct reviewer is configured")
            }
            let isCoding = Copilot.shouldReview(trajectory: turnEvidenceSnapshot())
            let diff: String
            if isCoding {
                guard let baselineDiff else {
                    return .incomplete("turn-scoped review baseline is unavailable")
                }
                diff = Copilot.turnScopedReviewSubject(before: baselineDiff,
                                                       after: Self.workingTreeDiff(projectRoot: projectRoot))
                guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    // Never silently substitute a prose-summary review for an artifact review. Git cannot
                    // expose non-repository, ignored, binary, or already-committed changes; that is an
                    // incomplete review subject, not evidence that the change was clean.
                    return .incomplete("a mutation was recorded, but no turn-scoped textual git diff is available")
                }
                guard !diff.contains("Binary files "),
                      !diff.contains("[review input incomplete:"),
                      !diff.contains("[new file truncated at"),
                      !diff.contains("[turn delta truncated]") else {
                    return .incomplete("the turn's textual review subject was unavailable or truncated")
                }
            } else {
                diff = ""
            }
            // Ground the reviewer in the SAME context the primary turn had — its self-identity brief plus
            // durable project memory. Without this the second model is context-blind about the domain (it
            // has never heard of "Kist") and answers "I can't verify these claims" instead of reviewing.
            let grounding = reviewerGrounding()
            let system: String, userPrompt: String
            if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                system = Copilot.reviewSystemPrompt
                userPrompt = Copilot.reviewPrompt(task: task, diff: diff, projectContext: grounding)
            } else if Copilot.isSubstantiveAnswer(answer) {
                system = Copilot.answerReviewSystemPrompt
                userPrompt = Copilot.answerReviewPrompt(task: task, answer: answer, projectContext: grounding)
            } else {
                return .notApplicable("no reviewable diff or substantive answer")
            }
            print("\u{001B}[35m⎇ second opinion · \(TeamLanguage.displayName(co.providerId)) reviewing…\u{001B}[0m")
            let review = await InterruptibleTurn.run(onInterrupt: { reason in
                if reason == .cancel { TurnInputQueue.shared.clearAll() }
                else { TurnInputQueue.shared.commitPending() }
                print("\n\u{001B}[33m"
                      + (reason == .cancel ? "⎋⎋ review cancelled" : "⎋ review interrupted — your turn")
                      + "\u{001B}[0m")
            }) {
                await modelComplete(co.providerId, co.model, system, userPrompt)
            }
            guard let review, !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .incomplete("\(TeamLanguage.displayName(co.providerId)) returned no response")
            }
            print("\u{001B}[35m⎇ review (\(TeamLanguage.displayName(co.providerId))):\u{001B}[0m\n\(Copilot.safeReviewDisplay(review))")
            return .completed(review)
        }

        // ULTRA MODE: every reachable model independently reviews the current work. Review is advisory;
        // findings are handed back to the ORIGINAL author for a bounded repair, and executed build/tests
        // remain the separate verification authority.
        func ultraRoster(excluding answered: ProviderBinding) -> [ProviderBinding] {
            let configured = Set(providerAliases.values)
            // Capability order — Claude leads, Codex second, then the rest (matches the operator's mental model).
            let prefer = ["claude-cli", "codex-cli", "gemini", "deepseek", "mimo", "moonshot", "zhipu", "grok", "openai", "anthropic"]
            var seen = Set<String>(); var out: [ProviderBinding] = []
            for pid in prefer where configured.contains(pid) && pid != answered.providerId && seen.insert(pid).inserted {
                out.append(ProviderBinding(providerId: pid))
            }
            return out
        }

        func runUltraReview(task: String, answer: String, author: ProviderBinding,
                            turnIntent: TaskBrief.Intent,
                            baselineDiff: String?) async {
            let roster = ultraRoster(excluding: author)
            guard !roster.isEmpty else {
                let text = "incomplete — no distinct reviewers configured"
                print("\u{001B}[37m⎇ ultra · no other minds configured — add models with /model\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false, text: text))
                return
            }
            let maxRepairs = min(3, max(0, copilot.maxFixRounds))
            print("\u{001B}[35m⎇ ultra · consensus of minds: \(roster.map { TeamLanguage.displayName($0.providerId) }.joined(separator: " → "))\u{001B}[0m")
            print("\u{001B}[2m  advisory review · up to \(maxRepairs) author repair rounds\u{001B}[0m")
            var current = answer
            var repairs = 0
            while true {
                guard !lastTurnInterrupted else {
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "incomplete — review interrupted"))
                    return
                }
                let pass = repairs + 1
                var cleanCount = 0
                var findings: [Copilot.RepairFinding] = []
                var missing: [String] = []
                var notApplicableReason: String?
                for mind in roster {
                    guard !lastTurnInterrupted else {
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                                 text: "incomplete — review interrupted"))
                        return
                    }
                    let name = TeamLanguage.displayName(mind.providerId)
                    switch await runOneReview(task: task, answer: current, reviewer: mind, answeredBy: author,
                                              baselineDiff: baselineDiff) {
                    case .notApplicable(let reason):
                        notApplicableReason = reason
                    case .incomplete(let reason):
                        missing.append("\(name): \(reason)")
                    case .completed(let review):
                        switch Copilot.classifyReviewResponse(review) {
                        case .clean:
                            cleanCount += 1
                            print("\u{001B}[32m⎇ ultra · review · \(name) reported no blocking issues (pass \(pass))\u{001B}[0m")
                        case .findings(let structured):
                            findings.append(contentsOf: structured)
                        case .incomplete:
                            missing.append("\(name): malformed or non-contract response")
                        }
                    }
                }

                if let reason = notApplicableReason {
                    print("\u{001B}[37m⎇ ultra · review not run — \(reason)\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                             text: "not applicable — \(reason)"))
                    return
                }
                if findings.isEmpty {
                    if missing.isEmpty && cleanCount == roster.count {
                        print("\u{001B}[1;32m⎇ ultra · review consensus: \(cleanCount)/\(roster.count) reported no blocking issues (pass \(pass))\u{001B}[0m")
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: true,
                                                 text: "\(cleanCount)/\(roster.count) reviewers reported no blocking issues"))
                    } else {
                        print("\u{001B}[33m⎇ ultra · review incomplete: \(cleanCount)/\(roster.count) clean responses; missing \(missing.count)\u{001B}[0m")
                        for item in missing { print("\u{001B}[2m  · \(item)\u{001B}[0m") }
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                                 text: "incomplete — \(missing.count) reviewer response(s) missing"))
                    }
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    return
                }

                if !missing.isEmpty {
                    print("\u{001B}[33m⎇ ultra · review incomplete: \(missing.count) reviewer(s) returned no usable response; repairing known findings only\u{001B}[0m")
                }
                guard copilot.autoFix else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · review findings reported; automatic repair is off\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "blocking findings reported; automatic repair off"))
                    return
                }
                guard repairs < maxRepairs else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · review findings remain after \(maxRepairs) author repair rounds\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "blocking findings remain after \(maxRepairs) author repair rounds"))
                    return
                }
                guard let loopFactory else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · review findings reported; author repair is unavailable in this mode\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "blocking findings reported; author repair unavailable"))
                    return
                }

                repairs += 1
                print("\u{001B}[35m⎇ ultra · review complete → original author \(TeamLanguage.displayName(author.providerId)) repairing aggregated findings (round \(repairs)/\(maxRepairs))…\u{001B}[0m")
                armTurnLoop()
                let fixLoop = perm.arm(loopFactory(author, roleSelection.bindings, perm.mode.isPlan,
                                                    showReasoning, extendedThinking))
                archiveCurrentEvidencePhase()
                let oc = await runTurnInterruptible(loop: fixLoop,
                                                    userInput: Copilot.repairPrompt(task: task, findings: findings),
                                                    rawRequest: task, resolvedIntent: turnIntent)
                await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                if lastTurnInterrupted {
                    repairPhaseFailed = true
                    return
                }
                guard oc.success else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · repair incomplete — original author turn failed\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "repair incomplete — original author turn failed"))
                    return
                }
                current = oc.summary
            }
        }

        // R4: the coder↔reviewer partnership. The co-reviewer critiques the diff; if it flags blocking
        // issues AND auto-fix is armed (team mode), the LEAD runs a bounded fix turn to address them,
        // then the reviewer re-checks — a real team accomplishing the goal, not an advisory print.
        func runCopilotReview(task: String, answer: String = "", allowAdvisory: Bool = false,
                              authoredBy: ProviderBinding? = nil,
                              baselineDiff: String? = nil,
                              turnIntent: TaskBrief.Intent,
                              turnSucceeded: Bool) async {
            // R2a (review catch): after an interject the user's typed instruction must run NEXT —
            // not after a copilot model call they didn't ask for.
            if lastTurnInterrupted {
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                         text: "not run — turn interrupted"))
            }
            guard !lastTurnInterrupted else { return }
            // Run the review when team mode is on (enabled) OR an explicitly enabled advisory second opinion
            // applies to this DIRECT turn. Ordinary Q&A leaves autoSecondOpinion off by default.
            let advisory = allowAdvisory && copilot.autoSecondOpinion
            let automaticBuild = turnSucceeded && turnIntent.expectsMutation
                && copilot.automaticBuildReview
                && Copilot.shouldReview(trajectory: turnEvidenceSnapshot())
            guard copilot.enabled || advisory || automaticBuild else {
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                         text: "not requested"))
                return
            }
            let author = authoredBy ?? copilot.lead ?? activeBinding
            if copilot.ultra {
                await runUltraReview(task: task, answer: answer, author: author,
                                     turnIntent: turnIntent, baselineDiff: baselineDiff)
                return
            }

            var currentAnswer = answer
            let firstAttempt = await runOneReview(task: task, answer: currentAnswer, answeredBy: author,
                                                  baselineDiff: baselineDiff)
            var reviewResponse: Copilot.ReviewResponse
            switch firstAttempt {
            case .notApplicable(let reason):
                print("\u{001B}[37m⎇ review not run — \(reason)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                         text: "not applicable — \(reason)"))
                return
            case .incomplete(let reason):
                print("\u{001B}[33m⎇ review incomplete — \(reason)\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "incomplete — \(reason)"))
                return
            case .completed(let response):
                reviewResponse = Copilot.classifyReviewResponse(response)
            }
            if case .clean = reviewResponse {
                print("\u{001B}[32m⎇ review · no blocking issues reported\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: true,
                                         text: "reviewer reported no blocking issues"))
                return
            }
            guard case .findings = reviewResponse else {
                print("\u{001B}[33m⎇ review incomplete — reviewer returned malformed or non-contract output; automatic repair withheld\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "incomplete — malformed reviewer response; automatic repair withheld"))
                return
            }

            // `autoFix` is the authority: a review may print findings without silently creating another
            // mutating model turn. When armed, the ORIGINAL author—not the reviewer—owns every repair.
            guard copilot.autoFix else {
                repairPhaseFailed = true
                print("\u{001B}[33m⎇ review · findings reported; automatic repair is off\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "blocking findings reported; automatic repair off"))
                return
            }
            guard let loopFactory else {
                repairPhaseFailed = true
                print("\u{001B}[33m⎇ review · findings reported; author repair is unavailable in this mode\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "blocking findings reported; author repair unavailable"))
                return
            }
            let repairLimit = min(3, max(1, copilot.maxFixRounds))
            var round = 0
            while round < repairLimit {
                guard case .findings(let findings) = reviewResponse else { break }
                round += 1
                let fixer = author
                print("\u{001B}[35m⎇ review complete → original author \(TeamLanguage.displayName(fixer.providerId)) repairing findings (round \(round)/\(repairLimit))…\u{001B}[0m")
                armTurnLoop()
                let fixLoop = perm.arm(loopFactory(fixer, roleSelection.bindings, perm.mode.isPlan,
                                                   showReasoning, extendedThinking))
                // Start a fresh phase for the repair while archiving the original evidence. Review and
                // final verification consume the combined ledger; phase-local routing still sees only
                // the repair attempt currently executing.
                archiveCurrentEvidencePhase()
                let oc = await runTurnInterruptible(loop: fixLoop,
                                                    userInput: Copilot.repairPrompt(task: task, findings: findings),
                                                    rawRequest: task, resolvedIntent: turnIntent)
                await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                if lastTurnInterrupted {
                    repairPhaseFailed = true
                    return
                }     // user stepped in — stop the team loop
                guard oc.success else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ team · repair incomplete — original author turn failed\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "repair incomplete — original author turn failed"))
                    return
                }
                currentAnswer = oc.summary
                // Re-review the fix so the loop converges (or exhausts its bounded rounds).
                switch await runOneReview(task: task, answer: currentAnswer, answeredBy: author,
                                          baselineDiff: baselineDiff) {
                case .completed(let next):
                    reviewResponse = Copilot.classifyReviewResponse(next)
                    if case .incomplete = reviewResponse {
                        repairPhaseFailed = true
                        print("\u{001B}[33m⎇ team · review incomplete after repair — malformed or non-contract output; further automatic repair withheld\u{001B}[0m")
                        print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                                 text: "incomplete after repair — malformed reviewer response"))
                        return
                    }
                case .notApplicable(let reason):
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ team · review incomplete after repair — \(reason)\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "incomplete after repair — \(reason)"))
                    return
                case .incomplete(let reason):
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ team · review incomplete after repair — \(reason)\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "incomplete after repair — \(reason)"))
                    return
                }
            }
            if case .clean = reviewResponse {
                print("\u{001B}[32m⎇ team · review · no blocking issues reported after \(round) repair round(s)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: true,
                                         text: "no blocking issues reported after \(round) author repair round(s)"))
            } else {
                repairPhaseFailed = true
                print("\u{001B}[33m⎇ team · review findings remain after \(repairLimit) repair rounds\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "blocking findings remain after \(repairLimit) author repair rounds"))
            }
            print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
        }

        // R4: arm a natural-language TEAM ("gemini be the eyes for deepseek", "deepseek codes and mimo
        // reviews", "work as a team"). Binds the lead (coder) + co (reviewer) across vendors and turns on
        // the review→fix loop, so a single goal is accomplished by the AIs working together, not one model.
        func armTeam(_ team: TeamIntent) {
            func resolve(_ name: String?) -> ProviderBinding? {
                guard let name, !name.isEmpty else { return nil }
                return Self.resolveModelSpec(name, currentProvider: roleSelection.fallback.providerId,
                                             knownProviders: providerAliases, providerModels: providerModels)
            }
            if let name = team.lead, resolve(name) == nil {
                print("\u{001B}[37m↳ team: no configured model for '\(name)' — keeping current lead\u{001B}[0m")
            }
            if let name = team.co, resolve(name) == nil {
                print("\u{001B}[37m↳ team: no configured model for '\(name)' — keeping current reviewer\u{001B}[0m")
            }
            if let lead = resolve(team.lead) {
                copilot.lead = lead
                _ = roleSelection.setDefault(lead, knownProviders: providerAliases)
                _ = roleSelection.assign(.coder, to: lead, knownProviders: providerAliases)
                autoRouting = false                          // a named lead pins the coding model
                activeBinding = roleSelection.fallback
                if let loopFactory {
                    loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking)
                }
            }
            if let co = resolve(team.co) {
                copilot.co = co
                _ = roleSelection.assign(.critic, to: co, knownProviders: providerAliases)
            }
            copilot.enabled = true
            let leadB = copilot.lead ?? roleSelection.fallback
            let coB = copilot.co ?? roleSelection.fallback
            // Don't let one model review AND fix its own code (no second model resolved). Keep the
            // review (advisory) but leave auto-fix off — a self-critique-then-self-fix is a no-op that
            // just burns tokens (review catch).
            let sameModel = leadB.providerId == coB.providerId && leadB.model == coB.model
            copilot.autoFix = !sameModel
            if sameModel {
                print("\u{001B}[35m⎇ team\u{001B}[0m · only one model configured — \(TeamLanguage.displayName(coB.providerId)) will review (advisory). Name a second model to enable review→fix.")
            } else {
                print("\u{001B}[35m⎇ team armed\u{001B}[0m · \(TeamLanguage.displayName(leadB.providerId)) building · "
                    + "\(TeamLanguage.displayName(coB.providerId)) reviewing · review→fix on")
            }
        }

        func consumeTurnUsageDelta() async -> [AgentSpan] {
            guard let traceRecorder else { return [] }
            let spans = await traceRecorder.all()
            let before = Set(usageSnapshot.map(\.id))
            let delta = spans.filter { !before.contains($0.id) }
            usageSnapshot = spans
            submittedTurnSpans.append(contentsOf: delta)
            if !UsageLedger.append(projectRoot: projectRoot, spans: delta) {
                print("\u{001B}[37musage ledger warning · could not persist local usage accounting\u{001B}[0m")
            }
            return delta
        }

        func printTurnUsage() async {
            let delta = await consumeTurnUsageDelta()
            let summary = UsageCost.summarize(spans: delta)
            guard summary.tokens > 0 else { return }
            print("\u{001B}[37m\(summary.render(label: "usage"))\u{001B}[0m")
        }

        func printSessionUsage() async {
            guard let traceRecorder else { print("usage: unavailable"); return }
            let spans = await traceRecorder.all()
            if !UsageLedger.append(projectRoot: projectRoot, spans: spans) {
                print("\u{001B}[37musage ledger warning · could not persist local usage accounting\u{001B}[0m")
            }
            print(UsagePanel.render(sessionSpans: spans, projectRoot: projectRoot,
                                    color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
        }

        func dispatchSelfHealAgents(report: SelfHealMissionReport,
                                    objective: String,
                                    automatic: Bool) async {
            guard report.writeSucceeded else {
                print("\u{001B}[31mself-heal dispatch blocked: mission report was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mself-heal dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            // Automatic repair must not run while the session is in plan mode
            // (read-only proposals). The builder/critic need edit_file+run_command;
            // in plan mode those are blocked mid-run, which is exactly the useless
            // "blocked by plan mode" half-dispatch we saw. Silently forcing execute
            // would be privilege escalation, so defer with an actionable message.
            if automatic && perm.effectivePlan {
                print("\u{001B}[33mCaptain self-heal deferred: plan mode is on (read-only). Turn plan mode off to let repair specialists act.\u{001B}[0m")
                return
            }
            let store = OrganizationalLearningStore(projectRoot: projectRoot)
            var priorEvidence: [String] = []
            // The clean HANDOFF: the researcher produces a machine-readable repair spec, and the BUILDER
            // receives ONLY that (not the research transcript) so it executes instead of re-researching.
            var researcherHandoff: SelfHealHandoff?
            if automatic {
                print("\u{001B}[33mCaptain supervisor dispatch\u{001B}[0m · \(report.agentAssignments.count) repair specialist(s) · clean handoff")
            }
            for assignment in report.agentAssignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                let evidenceBrief = priorEvidence.isEmpty
                    ? ""
                    : "\n\nEvidence from earlier self-heal specialists:\n" + priorEvidence.joined(separator: "\n\n")
                // The builder gets the immutable handoff spec ONLY — no transcript, no "here's another
                // idea". Every other role keeps the chained evidence (they review/decide on the work).
                let taskForAgent: String
                if assignment.specialistName == "self-heal-builder", let h = researcherHandoff, h.isActionable {
                    taskForAgent = h.builderBrief()
                } else {
                    taskForAgent = assignment.task + evidenceBrief
                }
                print("\u{001B}[2m⇢ self-heal delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      taskForAgent,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m")
                    priorEvidence.append("## \(assignment.specialistName)\n\(summary)")
                    // Parse the researcher's handoff. ACTION-FIRST: if it didn't hand off an actionable
                    // repair, HALT — do not churn more research/review/teach tasks on an unproven cause.
                    if assignment.specialistName == "self-heal-researcher" {
                        researcherHandoff = SelfHealHandoff.parse(from: summary)
                        if let h = researcherHandoff, h.isActionable {
                            print("\u{001B}[36m⇢ handoff → builder\u{001B}[0m\u{001B}[2m · \(h.rootCause) · \(Int((h.confidence*100).rounded()))% · files: \(h.targetFiles.joined(separator: ", "))\u{001B}[0m")
                        } else {
                            _ = store.recordSelfHealSpecialistOutput(objective: objective,
                                                                     assignment: assignment, summary: summary)
                            let why = researcherHandoff?.blockedReason ?? "no actionable handoff (root cause not pinned)"
                            print("\u{001B}[33mself-heal halted after research: \(why). Escalate — not opening more research.\u{001B}[0m")
                            break
                        }
                    }
                    if let artifact = store.recordSelfHealSpecialistOutput(objective: objective,
                                                                            assignment: assignment,
                                                                            summary: summary) {
                        let memory = artifact.memoryRecorded ? "indexed" : "not indexed"
                        let ledger = artifact.evidenceLedgerRecorded ? "ledgered" : "ledger failed"
                        let taskIDs = artifact.updatedTaskIDs.isEmpty
                            ? "no task ids"
                            : "tasks " + artifact.updatedTaskIDs.map(String.init).joined(separator: ",")
                        print("\u{001B}[2mself-heal evidence: \(artifact.path) · \(memory) · \(ledger) · \(taskIDs) · task evidence updated: \(artifact.taskEvidenceUpdated)\u{001B}[0m")
                        let verificationEvidence = CaptainFailureAnalysis.extractStructuredEvidence(from: priorEvidence.joined(separator: "\n\n"))
                        if verificationEvidence.isEmpty {
                            print("\u{001B}[2mself-heal repair verification: awaiting explicit VERIFY/proof lines\u{001B}[0m")
                        } else if let verification = try? CaptainFailureAnalysis(projectRoot: projectRoot)
                            .recordRepairVerificationIfChanged(evidence: verificationEvidence) {
                                let missing = verification.missingVerification.isEmpty
                                    ? "all verification checks matched"
                                    : "\(verification.missingVerification.count) missing check(s)"
                                print("\u{001B}[2mself-heal repair verification: \(verification.status.rawValue) · \(missing)\u{001B}[0m")
                                if let evidence = verification.structuredEvidence, !evidence.isEmpty {
                                    let proof = CaptainFailureAnalysis.renderVerificationEvidenceSummary(evidence)
                                    print("\u{001B}[2mself-heal proof: \(proof)\u{001B}[0m")
                                }
                        }
                    } else {
                        print("\u{001B}[31mself-heal evidence capture failed for \(assignment.specialistName)\u{001B}[0m")
                    }
                } else {
                    print("\u{001B}[31mself-heal agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        @discardableResult
        func openFailureAnalysis(goal: String,
                                 summary: String,
                                 automaticRepair: Bool) async -> CaptainFailureAnalysisReport {
            let failure = CaptainFailureAnalysis(projectRoot: projectRoot)
                .analyze(goal: goal,
                         summary: summary,
                         trajectory: turnEvidenceSnapshot(),
                         proofEntries: proofStore?.lastEntries() ?? [])
            let persisted = failure.writeSucceeded
                ? failure.path
                : "write failed: \(failure.writeError ?? "unknown error")"
            print("\u{001B}[33mCaptain failure analysis\u{001B}[0m · \(failure.capsule.likelyLayer.rawValue) · confidence \(failure.capsule.confidence)% · \(persisted) · seeded \(failure.seededTasks) task(s)")
            guard automaticRepair,
                  failure.writeSucceeded,
                  Self.shouldAutoSuperviseFailure(goal: goal)
            else { return failure }

            let objective = Self.supervisorRepairObjective(for: failure.capsule)
            let report = Self.handleSelfHealCommand("self-heal run \(objective)",
                                                    projectRoot: projectRoot,
                                                    trajectory: turnEvidenceSnapshot())
            let mission = report.writeSucceeded ? report.path : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[33mCaptain supervisor opened repair mission\u{001B}[0m · \(mission) · seeded \(report.seededTasks) task(s)")
            await dispatchSelfHealAgents(report: report, objective: objective, automatic: true)
            return failure
        }

        func printTurnSummary(outcomeSummary: String? = nil, success: Bool = true) async {
            let trajectory = turnEvidenceSnapshot()
            // `outcomeSummary` is the MODEL'S prose — it was ALREADY shown live (streamed token-by-token
            // during the turn), so we deliberately do NOT reprint it here (that caused "every answer twice").
            // It is not thrown away: it drives the grounding check that sets the dashboard confidence.
            let grounded = outcomeSummary.map { GroundedReviewValidator.audit($0, projectRoot: projectRoot).isGrounded } ?? true
            // The deterministic four-part recap (happened / changed / failed / next) — the at-a-glance
            // operating summary, shown ABOVE the panel (Active Minds · Tasks · Next). Full detail: /summary.
            let spans = await consumeTurnUsageDelta()
            print(Self.renderSimpleSummary(projectRoot: projectRoot, spans: spans,
                                           trajectory: trajectory, sessionStartedAt: sessionStart))
            // R2a (review catch): an ESC'd turn is not a failure — auto-opening a repair mission
            // (self-heal dispatch, token spend) before the user's queued instruction is the exact
            // opposite of "your turn".
            if !success, !lastTurnInterrupted {
                let goal = humanTranscript.reversed().first { $0.role == .user }?.content ?? "unknown turn"
                await openFailureAnalysis(goal: goal,
                                          summary: outcomeSummary ?? "turn failed without a model summary",
                                          automaticRepair: true)
            }
            let dashboard = Self.buildDashboard(roles: roleSelection, projectRoot: projectRoot,
                                                trajectory: trajectory, grounded: grounded,
                                                sessionStartedAt: sessionStart)
            // Only remember the report for `/confidence` on a SUCCESSFUL turn: a provider failure after
            // one clean tool call computes a misleading ~95% that must not be inherited by the next
            // `/confidence` (Codex catch). A failed turn keeps the last successful turn's report.
            if success { lastConfidenceReport = dashboard.confidenceReport }
            let compact = !success || !Self.turnHasMutatingWork(trajectory)
            let panelColor = Self.stdoutColorEnabled(projectRoot: projectRoot)
            print(compact ? dashboard.renderCompact(color: panelColor) : dashboard.render(color: panelColor))
            let hint = "proof: /logs · cost: /usage · board: /tasks · /summary for detail"
            print(panelColor ? "\u{001B}[2m\(hint)\u{001B}[0m" : hint)
        }

        /// Persist exactly one learning capsule for the submitted turn, after review/repair and the final
        /// deterministic contract have settled. Interim phase summaries remain display-only so a primary
        /// success cannot survive as a false pass when its automatic repair later fails.
        func recordSubmittedTurnLearning(outcomeSummary: String, success: Bool) {
            let clean = outcomeSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !lastTurnInterrupted else { return }
            let trajectory = turnEvidenceSnapshot()
            let plan = PlanStore(projectRoot: projectRoot).load()
            let insights = DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                           trajectory: trajectory)
            let currentObjective = humanTranscript.reversed().first { $0.role == .user }?.content
            _ = OrganizationalLearningStore(projectRoot: projectRoot)
                .recordTurn(plan: plan, spans: submittedTurnSpans, trajectory: trajectory,
                            outcomeSummary: clean, success: success,
                            insights: insights, objective: currentObjective)
        }

        func runSelfHealCommand(_ rawArgs: String) async {
            let report = Self.handleSelfHealCommand(rawArgs,
                                                    projectRoot: projectRoot,
                                                    trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[2m\(persisted) · board meeting: \(report.boardMeetingPath) · seeded self-heal tasks: \(report.seededTasks) · created specialists: \(report.createdSpecialists)\u{001B}[0m")
            guard Self.selfHealShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to dispatch the self-heal agents\u{001B}[0m")
                return
            }
            let objective = Self.normalizedSelfHealObjective(rawArgs)
            await dispatchSelfHealAgents(report: report, objective: objective, automatic: false)
        }

        func runDomainLearningCommand(_ rawArgs: String) async {
            let report = Self.handleDomainLearningCommand(rawArgs,
                                                          projectRoot: projectRoot,
                                                          trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[2m\(persisted) · confidence: \(report.understandingConfidence)%/\(report.confidenceThreshold)% · seeded tasks: \(report.seededTasks) · knowledge debt: \(report.knowledgeDebtCreated) · created specialists: \(report.createdSpecialists)\u{001B}[0m")
            guard Self.domainLearningShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to dispatch the domain-learning specialists\u{001B}[0m")
                return
            }
            guard report.writeSucceeded else {
                print("\u{001B}[31mdomain-learning dispatch blocked: report was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mdomain-learning dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            let assignments = report.canExecute
                ? report.agentAssignments
                : report.agentAssignments.filter { assignment in
                    let name = assignment.specialistName.lowercased()
                    return name.contains("research") || name.contains("critic")
                        || name.contains("simulation") || name.contains("scout")
                        || name.contains("symbolic")
                }
            if !report.canExecute {
                print("\u{001B}[33mdomain-learning gate HOLD — dispatching research/simulation/critic specialists only\u{001B}[0m")
            }
            for assignment in assignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                print("\u{001B}[2m⇢ domain learning delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      assignment.task,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    // The specialist's output already streamed live through the
                    // spawner's own TerminalEventSink; re-printing `summary` here
                    // duplicated the whole answer (and dumped raw plan/CoT twice).
                    // Emit only a compact completion marker — the full text is still
                    // captured into evidence + the artifact below.
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m")
                    if let artifact = OrganizationalLearningStore(projectRoot: projectRoot)
                        .recordDomainLearningSpecialistOutput(objective: report.objective,
                                                              assignment: assignment,
                                                              summary: summary) {
                        let memory = artifact.memoryRecorded ? "indexed" : "not indexed"
                        let ledger = artifact.evidenceLedgerRecorded ? "ledgered" : "ledger failed"
                        let taskIDs = artifact.updatedTaskIDs.isEmpty
                            ? "no task ids"
                            : "tasks " + artifact.updatedTaskIDs.map(String.init).joined(separator: ",")
                        print("\u{001B}[2mdomain-learning evidence: \(artifact.path) · \(memory) · \(ledger) · \(taskIDs) · task evidence updated: \(artifact.taskEvidenceUpdated)\u{001B}[0m")
                    } else {
                        print("\u{001B}[31mdomain-learning evidence capture failed for \(assignment.specialistName)\u{001B}[0m")
                    }
                } else {
                    print("\u{001B}[31mdomain-learning agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        func dispatchLegalResearchAgents(report: LegalResearchReport) async {
            guard report.writeSucceeded else {
                print("\u{001B}[31mlegal research dispatch blocked: dossier was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mlegal research dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            var priorEvidence: [String] = []
            for assignment in report.agentAssignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                let evidenceBrief = priorEvidence.isEmpty
                    ? ""
                    : "\n\nEvidence from earlier legal-research specialists:\n" + priorEvidence.joined(separator: "\n\n")
                print("\u{001B}[2m⇢ legal research delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      assignment.task + evidenceBrief,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    // The specialist's output already streamed live through the
                    // spawner's own TerminalEventSink; re-printing `summary` here
                    // duplicated the whole answer (and dumped raw plan/CoT twice).
                    // Emit only a compact completion marker — the full text is still
                    // captured into evidence + the artifact below.
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m")
                    priorEvidence.append("## \(assignment.specialistName)\n\(summary)")
                } else {
                    print("\u{001B}[31mlegal research agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        func runLegalResearchCommand(_ rawArgs: String, forceResearch: Bool) async {
            let report = Self.handleLegalResearchCommand(rawArgs,
                                                         projectRoot: projectRoot,
                                                         trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            let jurisdiction = report.jurisdiction ?? "unknown jurisdiction"
            print("\u{001B}[2m\(persisted) · \(jurisdiction) · sources: \(report.extractedSourceCount)/\(report.sourceCount) extracted · seeded tasks: \(report.seededTasks) · created specialists: \(report.createdSpecialists) · memory: \(report.memoryRecords)\u{001B}[0m")

            guard report.writeSucceeded else {
                await openFailureAnalysis(goal: rawArgs,
                                          summary: "legal research workflow failed to write dossier: \(report.writeError ?? "unknown error")",
                                          automaticRepair: true)
                return
            }

            guard report.readyForResearch else {
                print("\u{001B}[33mlegal research gate HOLD\u{001B}[0m · " + report.blockers.joined(separator: "; "))
                print("\u{001B}[2manswer the blocker(s), then run \(report.dispatchCommand)\u{001B}[0m")
                return
            }

            guard forceResearch || Self.legalResearchShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to hand this into evidence-first research\u{001B}[0m")
                return
            }

            if report.extractedSourceCount > 0 && !Self.legalResearchHasExternalDocumentConsent(rawArgs) {
                print("\u{001B}[33mlegal privacy gate HOLD\u{001B}[0m · document text was extracted locally but not sent to external research/models")
                print("\u{001B}[2mrerun with --send-docs or --allow-external after confirming you want this legal document text included in model/research handoff\u{001B}[0m")
                return
            }

            if let research {
                print("\u{001B}[33mlegal research handoff\u{001B}[0m · evidence-first /research")
                await runHeavyRoute(goal: report.researchGoal, intent: .research, mode: .inline,
                                    execution: "research", startProof: true) {
                    await research(report.researchGoal, roleSelection.bindings)
                }
            } else if runSpecialist != nil {
                print("\u{001B}[33mlegal research handoff\u{001B}[0m · specialist fallback")
                await dispatchLegalResearchAgents(report: report)
            } else {
                print("\u{001B}[31mlegal research handoff unavailable: no /research runner or specialist runner in this mode\u{001B}[0m")
                print("\u{001B}[2mmanual handoff: /research \(report.researchGoal.prefix(180))...\u{001B}[0m")
            }
        }

        func compactCost(_ s: UsageCostSummary) -> String {
            guard s.tokens > 0 else { return "—" }
            let tok = s.tokens >= 1000 ? String(format: "%.1fk tok", Double(s.tokens) / 1000) : "\(s.tokens) tok"
            return (s.knownUSD > 0 ? String(format: "$%.4f · ", s.knownUSD) : "") + tok
        }

        // The always-visible status line (#3): model/team in plain words, mode, cost, active + next task.
        // The persisted plan's doing:/next: line shows ONLY when the plan belongs to THIS session (its
        // file was written at/after sessionStart). A plan left on disk by a prior session — or auto-seeded
        // by an earlier council run — must not greet a cold start as "next:" (confusing, unrelated noise);
        // it stays silent until this session advances it, and is always reachable via /tasks.
        func renderStatusLine() async -> String {
            let bindings = roleSelection.bindings
            // Non-team case shows the model the loop is ACTUALLY running (activeBinding), not the startup
            // default — so the always-visible status line never lies after an auto-route switch (invariant).
            let modelLabel = TeamLanguage.describeTeam(bindings)
                ?? (TeamLanguage.displayName(activeBinding.providerId)
                    + (activeBinding.model.map { " (\($0))" } ?? ""))
            let cost = traceRecorder == nil ? "—" : compactCost(UsageCost.summarize(spans: await traceRecorder!.all()))
            let store = PlanStore(projectRoot: projectRoot)
            let persisted = store.load()
            let currentActive = persisted.active(since: sessionStart)
            // Show doing:/next: for work THIS session is on — but never greet a cold start with a stale
            // prior-session task (see PlanStatusVisibility). The board is always on /tasks.
            let showPlan = PlanStatusVisibility.shouldShow(planModifiedAt: store.modifiedAt(),
                                                           sessionStart: sessionStart,
                                                           hasActiveTask: currentActive != nil)
            let plan = showPlan ? persisted : Plan()
            let modeLabel: String
            switch perm.mode {
            case .normal: modeLabel = "chat"
            case .acceptEdits: modeLabel = "accept-edits"
            case .plan: modeLabel = "plan"
            case .bypass: modeLabel = "bypass"
            }
            return StatusLine(modelLabel: modelLabel,
                              mode: modeLabel,
                              cost: cost,
                              activeTask: (showPlan ? currentActive : nil).map { "[\($0.id)] \($0.title)" },
                              nextStep: (showPlan ? (currentActive ?? plan.nextActionable ?? plan.next) : nil)
                                .map { "[\($0.id)] \($0.title)" }).render()
        }

        func completionCandidates() -> [String] {
            if cachedSymbols == nil {
                cachedSymbols = InputCompleter.projectSymbols(projectRoot: projectRoot)
            }
            let providers = providerLabels.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            let models = providerModels.values.flatMap { $0 }
            return InputCompleter.candidates(commands: commands.names,
                                             providers: providers,
                                             models: models,
                                             projectRoot: projectRoot,
                                             symbolCache: { cachedSymbols ?? [] })
        }
}
