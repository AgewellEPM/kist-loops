import Foundation

// Universal structured-text protocol, including bounded downgrade from native tools.
extension HeadlessAgentLoop {
    func driveText(_ initial: LoopCheckpoint,
                           requestBudget: ProviderRequestBudget) async -> (Outcome, LoopCheckpoint) {
        var cp = initial
        _ = await synchronizeProviderRequests(&cp, budget: requestBudget)

        reconcile(&cp)   // interrupted-action reconciliation (shared with the native loop)
        let scopeSource = cp.rawRequest ?? Self.scopeRequestSource(for: cp.goal)
        let scopedContext = context.withAuthorizationScope(
            AuthorizationScopeEngine.evaluate(scopeSource))
        // Interactive chat/review turns don't get the recursive spawn vector (runaway-research guard) —
        // applies to BOTH the standard prompt and the weak-model primer below (MiMo takes the weak path).
        let authorizedTools = Self.conversationalToolset(tools, intent: cp.intent, request: cp.rawRequest)
        let turnTools = surfaceRelevantSelfTools(authorizedTools, goal: cp.goal)   // P2: task-targeted self__ advertisement (fail-open, no-op unless toggled)
        var system = Self.systemPrompt(tools: turnTools, projectRoot: scopedContext.projectRoot, planMode: planMode,
                                       shellEnabled: scopedContext.shell.enabled, skillsXML: skillsXML,
                                       readableRoots: scopedContext.externalReadRoots)
        if ["claude-cli", "codex-cli"].contains(providerId.lowercased()) {
            system += "\n\n" + Self.subscriptionCLICompletionBackendRules
        }
        // Item #4: small local models stall on the strict JSON protocol. Lead with a gentle, example-
        // driven "simple mode" primer for the weak tier. Only the text path reaches here (frontier API
        // models use the native path), so this targets exactly the local/small models that need it.
        let tierModel = providers.provider(id: providerId)?.resolvedModel(model) ?? model
        if ModelTier.of(providerId: providerId, model: tierModel) == .weak {
            system = Self.weakModelTextPrimer(tools: turnTools, shellEnabled: scopedContext.shell.enabled) + "\n\n" + system
        }
        system += await recalledLessonsSuffix(goal: cp.goal)   // P1 recall→plan read-back (no-op unless warm)
        var settings = ModelSettings(temperature: 0.2, maxTokens: 4096, systemPrompt: system,
                                     disableThinking: providerReasoningEffort == .none,
                                     reasoningEffort: providerReasoningEffort)
        if providerId.lowercased() == "codex-cli" {
            settings.jsonSchema = Self.subscriptionCLIActionSchema(
                tools: turnTools, shellEnabled: scopedContext.shell.enabled)
            settings.jsonOutput = settings.jsonSchema != nil
            settings.systemPrompt += "\nFor this response schema, wrap the selected action in `action` "
                + "and encode tool `parameters` as a JSON object string. Kist decodes and executes it."
        }
        applyProviderReasoningEffort(&settings, checkpoint: &cp)
        let profileStopsApplied = applyModelProfileStops(&settings)
        var parseFailures = 0
        var consecutiveFailures = 0
        var replansUsed = 0
        var gatheringProgress = HeadlessGatheringProgress()
        var lastSynthesisNudge = -100
        var verificationNudges = 0         // verify-before-done: re-nudge up to a bound, then finish honestly
        var subscriptionCLIToolBlockNudges = 0 // bound recovery from false subscription tool blockers
        var lastVerify: VerificationReplay? = nil   // last PASSING build/test of this run — re-verify replay candidate
        var replayAttempted = false                 // one deterministic replay per fresh candidate, never a loop
        var recoveryAttempted = false      // stuck-recovery: one hard reset before giving up
        var recoveryMark = 0               // trajectory length at recovery — judge only actions since
        var steeredSpiral: String? = nil   // last tool-error spiral we corrected — steer ONCE per signature

        sink.emit(.stateChanged(.analyzing))

        let start = cp.iteration + 1
        guard start <= maxIterations else {
            return await finishProviderRequestBudgetFailure(
                &cp, budget: requestBudget,
                error: .exhausted(limit: maxIterations, consumed: cp.iteration))
        }

        for _ in start...maxIterations {
            if Task.isCancelled { return finishInterrupted(&cp) }   // esc-to-interrupt
            if let halt = await budgetHalt(&cp) { return halt }
            if let blocked = await requestBudget.blockingError() {
                return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget,
                                                                error: blocked)
            }
            sink.emit(.stateChanged(.executing))
            let outboundMessages = await prepareForProviderCall(&cp, mode: .text,
                                                                settings: settings,
                                                                    requestBudget: requestBudget)
            _ = await synchronizeProviderRequests(&cp, budget: requestBudget)
            if let blocked = await requestBudget.blockingError() {
                return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget,
                                                                error: blocked)
            }

            // 1) Ask the model for the next action.
            let completion: CompletionStreamResult
            do {
                completion = try await streamCompletion(messages: outboundMessages, settings: settings,
                                                        allowFallback: !profileStopsApplied,
                                                        routePolicy: providerRoutePolicy(
                                                            allowFallback: !profileStopsApplied),
                                                        requestBudget: requestBudget)
            } catch is BudgetDeniedError {
                return await budgetDeniedHalt(&cp)                       // atomic reserve denied this call
            } catch let requestError as ProviderRequestBudgetError {
                return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget,
                                                                error: requestError)
            } catch {
                _ = await synchronizeProviderRequests(&cp, budget: requestBudget)
                if Task.isCancelled { return finishInterrupted(&cp) }   // ESC mid-stream
                return finishFailed(&cp, "provider error: \(error)", ProviderRouteFailure.describe(error, requested: providerId),
                                    providerFault: ProviderFault.isProviderFault(error))
            }
            let iteration = await synchronizeProviderRequests(&cp, budget: requestBudget)
            let text = completion.text
            recordProviderMetadata(completion, checkpoint: &cp)

            // 2) Parse the action; nudge (bounded) when the model wanders off-protocol.
            guard let action = ActionParser.parse(text) else {
                parseFailures += 1
                cp.messages.append(ChatMessage(role: .assistant, content: text,
                                               providerReasoningHandles: completion.reasoningHandles))
                if parseFailures >= 3 {
                    if let final = await attemptTextFinalSynthesis(&cp, requestBudget: requestBudget) {
                        return final
                    }
                    return finishFailed(&cp, "no parseable action",
                                        "model did not emit a valid action after 3 attempts")
                }
                cp.messages.append(ChatMessage(role: .user, content:
                    Self.jsonProtocolRecoverySteering(tools: turnTools, shellEnabled: scopedContext.shell.enabled,
                                                      attempt: parseFailures)))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            parseFailures = 0
            cp.messages.append(ChatMessage(role: .assistant, content: text,
                                           providerReasoningHandles: completion.reasoningHandles))

            // 3) Done?
            if action.done {
                let summary = action.summary ?? action.message ?? "done"
                // Subscription CLIs are deliberately stripped of THEIR native tools and used as pure
                // completion backends. The outer Kist loop still advertises and executes its JSON tools.
                // Some backends conflate those two layers and immediately claim repository access is
                // unavailable, even after successful Kist reads. Reject that unsupported blocker while
                // grounding tools are present; after a small bound, fail honestly instead of looping.
                if let blockerDecision = subscriptionCLIPrematureToolBlocker(
                    summary: summary, tools: turnTools, nudges: subscriptionCLIToolBlockNudges
                ) {
                    switch blockerDecision {
                    case .nudge(let why):
                        subscriptionCLIToolBlockNudges += 1
                        cp.messages.append(ChatMessage(role: .user, content: why
                            + "\n" + Self.subscriptionCLICompletionBackendRules))
                        cp.iteration = iteration; persist(&cp)
                        continue
                    case .failUnverified(let why):
                        let honest = "unverified — \(why)"
                        cp.status = .failed; cp.summary = honest; cp.iteration = iteration; persist(&cp)
                        await fireStopHook(summary: honest, success: false)
                        sink.emit(.stateChanged(.failed)); sink.emit(.failed(honest))
                        return (Outcome(
                            success: false, summary: honest, iterations: iteration,
                            checkpointId: cp.id, terminalStatus: .stoppedUnverified), cp)
                    case .accept:
                        break
                    }
                }
                // VERIFY-BEFORE-DONE (R7): a code change that was never built/tested is NOT done. Nudge
                // up to N times; if it's STILL unverified, finish HONESTLY as a failure — never launder
                // an unbuilt change into success (the LLM's "done" doesn't outrank a real build/test).
                var doneDecision = verifyBeforeDone(canRunCommands: scopedContext.shell.enabled,
                                                    expectedOutcome: cp.expectedOutcome,
                                                    taskIntent: cp.intent,
                                                    nudges: verificationNudges)
                // SYMBOLIC RE-VERIFY (dogfood 2026-08-06): a done-claim with an unverified source edit
                // doesn't go back to the model first — if THIS run already produced a passing build/test,
                // the loop replays that exact approved command and re-judges on the real result. Only
                // when no replay exists (or it fails) do we spend a nudge asking the model.
                if case .nudge = doneDecision, let replay = lastVerify, !replayAttempted {
                    replayAttempted = true
                    if await replayVerification(replay, cp: &cp, iteration: iteration) {
                        doneDecision = verifyBeforeDone(canRunCommands: scopedContext.shell.enabled,
                                                        expectedOutcome: cp.expectedOutcome,
                                                        taskIntent: cp.intent,
                                                        nudges: verificationNudges)
                    }
                }
                switch doneDecision {
                case .nudge(let why):
                    verificationNudges += 1
                    cp.messages.append(ChatMessage(role: .user, content: CompletionVerifier.steering(reason: why)))
                    cp.iteration = iteration; persist(&cp)
                    continue
                case .failUnverified(let why):
                    let honest = "unverified — \(why)"
                    cp.status = .failed; cp.summary = honest; cp.iteration = iteration; persist(&cp)
                    await fireStopHook(summary: honest, success: false)
                    sink.emit(.stateChanged(.failed)); sink.emit(.failed(honest))
                    return (Outcome(
                        success: false, summary: honest, iterations: iteration,
                        checkpointId: cp.id, terminalStatus: .stoppedUnverified), cp)
                case .accept:
                    break
                }
                cp.status = .completed; cp.summary = summary; cp.iteration = iteration; persist(&cp)
                await fireStopHook(summary: summary, success: true)
                sink.emit(.stateChanged(.completed)); sink.emit(.completed(summary: summary))
                return (Outcome(success: true, summary: summary, iterations: iteration, checkpointId: cp.id), cp)
            }

            // 4) Run the chosen tool.
            guard let tool = action.tool, !tool.isEmpty else {
                cp.messages.append(ChatMessage(role: .user, content:
                    "No tool specified and done was not set. Choose a tool or set \"done\": true."))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            let invocation = Self.delegationBoundInvocation(
                registry: authorizedTools, intent: cp.intent, grant: cp.delegationGrant,
                tool: tool, arguments: action.parameters)
            let args = invocation.arguments
            if let block = effectContractBlock(registry: authorizedTools, intent: cp.intent,
                                               delegationGrant: cp.delegationGrant,
                                               ownedDelegationHandles: Set(cp.delegationHandles ?? []),
                                               tool: tool, args: args) {
                let denied = await authorizedTools.policyDenied(
                    name: tool, arguments: args, reason: block, context: scopedContext)
                sink.emit(.actionStarted(index: iteration, tool: tool,
                                         description: Self.toolDisplayDescription(
                                            tool: tool, args: args,
                                            thinking: action.thinking)))
                sink.emit(.actionFinished(index: iteration, success: false,
                                          output: "", error: planMode
                                            ? "blocked by plan mode" : (denied.error ?? block)))
                cp.messages.append(ChatMessage(role: .user, content: block))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            // 4b) Human-in-the-loop: sensitive tools require approval (shared with the native loop).
            let approvedForScope = await approve(tool: tool, args: args, context: scopedContext)
            if !approvedForScope {
                cp.messages.append(ChatMessage(role: .user, content:
                    "The user DECLINED to run \(tool). Do not retry it — choose a different approach or finish with done."))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            // 4c) PreToolUse hooks may veto the action (user-configured guard).
            if let block = await preHookBlock(tool: tool, args: args) {
                sink.emit(.actionFinished(index: iteration, success: false, output: "", error: "blocked by PreToolUse hook"))
                cp.messages.append(ChatMessage(role: .user, content: block))
                cp.iteration = iteration; persist(&cp)
                continue
            }
            // Bracket the side effect: persist the action as PENDING BEFORE running it, so a crash
            // mid-tool is reconciled (not replayed) on resume.
            cp.pendingAction = PendingAction(
                tool: tool, argsSummary: Self.compactArgs(args), iteration: iteration,
                predictedEffects: authorizedTools.effectObservation(name: tool, arguments: args))
            persist(&cp)
            let displayDescription = Self.toolDisplayDescription(tool: tool,
                                                                 args: args,
                                                                 thinking: action.thinking)
            sink.emit(.actionStarted(index: iteration, tool: tool, description: displayDescription))
            let executionContext = scopedContext.withScopeOverrideApproved(approvedForScope)
            let result = await authorizedTools.executeHostBound(
                name: tool, arguments: args,
                hostArguments: invocation.hostArguments, context: executionContext)
            Self.recordOwnedDelegationHandle(
                registry: authorizedTools, tool: tool, result: result, checkpoint: &cp)
            sink.emit(.actionFinished(index: iteration, success: result.success, output: result.output, error: result.error))
            let observed = authorizedTools.effectObservation(name: tool, arguments: args, result: result)
            recorder.record(tool: tool, argsFingerprint: TrajectoryAnalyzer.fingerprint(args), success: result.success,
                             failureDetail: result.success ? nil : String(Self.failureAwareRaw(result).prefix(1500)),
                             effectObservation: observed)
            if let cand = Self.replayCandidate(tool: tool, args: args, context: executionContext,
                                               succeeded: result.success, observed: observed) {
                lastVerify = cand; replayAttempted = false
            }

            // 5) Feed the observation back, wrapped in an envelope marked as untrusted DATA
            // (prompt-injection defense: file/shell/MCP output must never be obeyed as instructions).
            let raw = Self.failureAwareRaw(result)
            let body = Self.toolObservationBody(raw: raw, metadata: result.metadata,
                                                maxBytes: maxObservationBytes)
            let observation = Self.toolOutputEnvelope(tool: tool, success: result.success, body: body)
            cp.messages.append(ChatMessage(role: .user, content: observation,
                                           attachments: result.attachments))
            cp.pendingAction = nil   // the action completed; clear the bracket
            await firePostHook(tool: tool, args: args, success: result.success, output: body)

            if let reason = Self.projectScopeStop(result) {
                cp.iteration = iteration
                return finishFailed(&cp, reason, reason)
            }

            // 5a) CAPABILITY-DENIAL fast recovery: when a tool is denied because it's unavailable (shell
            // off) or the action/tool doesn't exist, steer the model IMMEDIATELY to the real tools instead
            // of letting it burn turns retrying the same dead end (the desktop-cleanup death-spiral).
            if !result.success, let steer = Self.capabilityDenialSteer(error: result.error ?? body,
                                                                       tools: turnTools, shellEnabled: scopedContext.shell.enabled,
                                                                       readableRoots: scopedContext.externalReadRoots) {
                cp.messages.append(ChatMessage(role: .user, content: steer))
            }

            // 5b) Live re-plan: after a streak of failures, steer the model to revise its approach
            // (instead of looping on a doomed one), bounded by a re-plan budget.
            if result.success {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                if consecutiveFailures >= replanThreshold && replansUsed < maxReplans {
                    replansUsed += 1; consecutiveFailures = 0
                    let tv = Self.validToolNames(turnTools, shellEnabled: scopedContext.shell.enabled)
                    // Escalate: soft "revise" on the first re-plan, EXPLICIT diagnose→alternatives→pick once
                    // that didn't work (replansUsed >= 2).
                    let structured = replansUsed >= 2
                    sink.emit(.replanStarted(reason: structured
                        ? "structured re-plan (failures continued)"
                        : "\(replanThreshold) consecutive tool failures"))
                    let steer = structured
                        ? Self.structuredReplanSteering(recentFailure: body, validTools: tv)
                        : Self.replanSteering(recentFailure: body, validTools: tv)
                    cp.messages.append(ChatMessage(role: .user, content: steer))
                }
            }

            // 5b') TOOL-ERROR SPIRAL: the SAME tool + SAME args failing repeatedly (sharper + earlier than
            // the generic consecutive-failure replan above). Inject a targeted "stop repeating THIS exact
            // call, do X instead" steer to BREAK it — ONCE per distinct spiral signature, so we don't spam
            // (and if it keeps spiraling past the steer, the governor stops the run cleanly).
            if let spiral = ToolSpiralDetector.detect(recorder.snapshot()),
               spiral.signature != steeredSpiral {
                steeredSpiral = spiral.signature
                sink.emit(.replanStarted(reason: "breaking a tool-error spiral (\(spiral.tool) ×\(spiral.count))"))
                cp.messages.append(ChatMessage(role: .user, content: ToolSpiralDetector.steer(
                    tool: spiral.tool, count: spiral.count, error: result.error ?? body,
                    validTools: Self.validToolNames(turnTools, shellEnabled: scopedContext.shell.enabled))))
            }

            // New observations remain useful work, including required file windows and diffs.
            gatheringProgress.observe(tool: tool, args: args, result: result, visibleBody: body,
                                      readOnly: Self.readOnlyTools.contains(tool))
            if gatheringProgress.exhausted {
                cp.iteration = iteration
                return finishFailed(&cp, Self.gatheringStop, Self.gatheringStop)
            }
            if Self.shouldForceSynthesis(consecutiveGathering: gatheringProgress.stalledCalls, iteration: iteration,
                                         lastNudge: lastSynthesisNudge, maxIterations: maxIterations) {
                lastSynthesisNudge = iteration; gatheringProgress.didNudge()
                cp.messages.append(ChatMessage(role: .user,
                                               content: Self.synthesisSteering(
                                                validTools: Self.validToolNames(turnTools,
                                                                               shellEnabled: scopedContext.shell.enabled))))
            }
            cp.iteration = iteration; persist(&cp)
            // Reliability governor: stop EARLY (cleanly, with an honest summary) on a genuine loop the
            // re-plan nudges couldn't break — so the larger budget is spent FINISHING work, not spinning.
            let govTrajectory = recorder.snapshot()
            if case .stopStuck(let reason) = ProgressGovernor(hardCeiling: maxIterations)
                .decide(iteration: iteration, trajectory: govTrajectory,
                        analyzeFrom: recoveryAttempted ? recoveryMark : 0,
                        taskIntent: cp.intent) {
                if !recoveryAttempted {
                    // One HARD reset before giving up: abandon the failing approach, try a different one.
                    // Mark the trajectory position so the next stuck-check judges only POST-reset actions
                    // (else the stale stuck-pattern re-stops the run before recovery gets a chance).
                    recoveryAttempted = true
                    recoveryMark = govTrajectory.count
                    cp.messages.append(ChatMessage(role: .user, content: ProgressGovernor.recoverySteering(reason: reason)))
                    cp.iteration = iteration; persist(&cp)
                    continue
                }
                if let final = await attemptTextFinalSynthesis(&cp, requestBudget: requestBudget) {
                    return final
                }
                return finishFailed(&cp, "stopped early — \(reason)", "stopped early (stuck after recovery): \(reason)")
            }
        }

        return await finishProviderRequestBudgetFailure(
            &cp, budget: requestBudget,
            error: .exhausted(limit: maxIterations,
                              consumed: await requestBudget.consumedCount()))
    }

}
