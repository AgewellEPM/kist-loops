import Foundation

// Extracted from HeadlessAgentLoop; shared Completion behavior for both protocols.
extension HeadlessAgentLoop {
    func finishFailed(_ cp: inout LoopCheckpoint, _ summary: String, _ reason: String,
                              providerFault: Bool = false) -> (Outcome, LoopCheckpoint) {
        cp.status = .failed; cp.summary = summary; persist(&cp)
        sink.emit(.failed(reason))
        return (Outcome(success: false, summary: summary, iterations: cp.iteration, checkpointId: cp.id,
                        providerFault: providerFault), cp)
    }

    /// R7: the verify-before-done decision, shared by BOTH done sites (native tool-call path + text
    /// path). `.accept` = finish; `.nudge` = steer once more (budget remains); `.failUnverified` =
    /// nudges exhausted AND the code change is STILL unbuilt/untested → finish HONESTLY as a failure
    /// instead of laundering an unverified change into success (symbolic-first: the LLM's "done" is
    /// not trusted over a real build/test). A source mutation with shell unavailable fails unverified
    /// immediately: repeatedly nudging the model to run a command it cannot run would only waste turns.
    enum DoneDecision: Equatable { case accept, nudge(String), failUnverified(String) }

    /// A completion-only subscription backend can mistake its intentionally disabled native shell for
    /// absence of the outer Kist tool protocol, including after earlier successful reads. Only recover
    /// when no tool has failed and grounding is either unattempted or already succeeded. A real tool
    /// failure or permission denial must keep its own diagnosis; ordinary direct answers are untouched.
    func subscriptionCLIPrematureToolBlocker(summary: String, tools: ToolRegistry,
                                              nudges: Int) -> DoneDecision? {
        guard ["claude-cli", "codex-cli"].contains(providerId.lowercased()) else { return nil }

        let lower = summary.lowercased()
        let names = Set(tools.names)
        let groundingOrder = ["read_file", "search_code", "list_files", "glob_files", "git", "git_status", "git_diff"]
        let offered = groundingOrder.filter { names.contains($0) }
        let observations = recorder.snapshot()
        let successfulGrounding = observations.filter { $0.success && offered.contains($0.tool) }.count
        guard observations.allSatisfy({ $0.success }),
              observations.isEmpty || successfulGrounding > 0 else { return nil }
        let mentionsOfferedTool = offered.contains {
            lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: $0) + "\\b",
                        options: .regularExpression) != nil
        }
        // Completion backends do not always echo the advertised JSON name. Codex has also described
        // the same false blocker as "no Kist filesystem or git tools". Keep these phrases narrow and
        // behind the successful-or-unattempted observation and subscription-provider guards above
        // so a real tool failure is not forced into an unrelated repository call.
        let mentionsGroundingSurface = mentionsOfferedTool || [
            "kist filesystem", "kist file tools", "kist tools", "git tools",
            "filesystem tools", "file-system tools", "repository tools"
        ].contains { lower.contains($0) }
        let availabilityNegation = [
            "unavailable", "not available", "not callable", "cannot call", "can't call", "unable to call",
            "exposes no", "exposes neither", "does not expose", "doesn't expose", "no kist", "no repository access",
            "no filesystem access", "no file-system access", "do not have access", "don't have access",
            "cannot access", "can't access", "no filesystem-reading", "no file-reading",
            "no file-writing", "no command-execution", "no command runner", "read-only sandbox",
            "filesystem is read-only", "workspace is read-only", "workspace remains read-only",
            "enable writable workspace access"
        ].contains { lower.contains($0) }
        let unattemptedSandboxClaim = observations.isEmpty
            && (lower.hasPrefix("blocked") || lower.contains("cannot") || lower.contains("can't")) && [
            "filesystem is read-only", "workspace is read-only", "workspace remains read-only",
            "read-only sandbox", "enable writable workspace access",
            "no filesystem-reading", "no file-reading", "no command-execution"
        ].contains { lower.contains($0) }
        guard !offered.isEmpty, (mentionsGroundingSurface || unattemptedSandboxClaim),
              availabilityNegation else { return nil }

        // After a read, "read_file says the dependency is unavailable" is an ordinary finding.
        // Require a direct denial of a tool/interface, not separated mentions of tools and absence.
        if !observations.isEmpty {
            let subjects = offered + ["kist tools", "kist filesystem tools", "filesystem tools",
                                      "file-system tools", "repository tools", "git tools"]
            let subject = "\\b(?:" + subjects.map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|") + ")(?: tools?)?\\b"
            let denials = [
                subject + #"\s+(?:is|are|remains?)\s+(?:currently\s+)?(?:unavailable|not available|not callable|not exposed)"#,
                #"(?:does not expose|doesn't expose|exposes no|exposes neither|cannot call|can't call|unable to call)\s+(?:(?:the|required|any|kist)\s+)*"# + subject,
            ]
            guard denials.contains(where: { lower.range(of: $0, options: .regularExpression) != nil })
            else { return nil }
        }

        let stage = observations.isEmpty ? "before making any call"
            : "after \(successfulGrounding) successful grounding call(s) with no tool error"
        let why = "the subscription CLI claimed repository/file tools were unavailable \(stage), "
            + "but Kist advertised \(offered.joined(separator: ", ")). Its native CLI tools are disabled; "
            + "Kist executes the JSON tool action. Request one advertised grounding tool now"
        return nudges < 2 ? .nudge(why) : .failUnverified(why)
    }

    func verifyBeforeDone(canRunCommands: Bool,
                          expectedOutcome: TaskBrief.ExpectedOutcome? = nil,
                          taskIntent: TaskBrief.Intent? = nil,
                          nudges: Int) -> DoneDecision {
        let trajectory = recorder.snapshot()
        guard case .needsVerification(let why) = CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: canRunCommands,
            expectedOutcome: expectedOutcome, taskIntent: taskIntent) else { return .accept }
        // Missing promised work can still be repaired by its own tools when shell execution is disabled:
        // filesystem tools for mutation, research/read tools for evidence, and desktop/control tools for
        // external actuation. Only a source-verification failure is impossible without a shell and should
        // therefore fail immediately instead of spending the nudge budget on an unavailable command.
        let missingToolReachableOutcome: Bool
        switch expectedOutcome {
        case .mutation:
            missingToolReachableOutcome = !trajectory.contains {
                $0.success && ($0.observedEffects.confirmsMutation
                    || $0.observedEffects.progress == .delegatedMutation)
            }
        case .delegation:
            missingToolReachableOutcome = !trajectory.contains {
                $0.success && ($0.observedEffects.progress == .delegation
                    || $0.observedEffects.progress == .delegatedMutation)
            }
        case .evidence:
            missingToolReachableOutcome = !trajectory.contains {
                $0.success && ($0.observedEffects.progress == .research
                    || $0.observedEffects.progress == .evidence)
            }
        case .externalAction:
            missingToolReachableOutcome = !trajectory.contains {
                $0.success && $0.observedEffects.progress == .externalState
            }
        case .answer, .plan, .none:
            missingToolReachableOutcome = false
        }
        if !canRunCommands && !missingToolReachableOutcome { return .failUnverified(why) }
        return nudges < Self.maxVerificationNudges ? .nudge(why) : .failUnverified(why)
    }

    /// User pressed ESC (esc-to-interrupt). The driving Task is cancelled; we end the turn cleanly at the
    /// next iteration boundary and persist the checkpoint as PAUSED so the run can be resumed, not lost.
    func finishInterrupted(_ cp: inout LoopCheckpoint) -> (Outcome, LoopCheckpoint) {
        cp.status = .paused; cp.summary = "interrupted"; persist(&cp)
        sink.emit(.stateChanged(.cancelled))
        return (Outcome(success: false, summary: "interrupted", iterations: cp.iteration, checkpointId: cp.id), cp)
    }

    /// Convert a relative resume allowance into an absolute request limit without overflow.
    static func iterationLimit(from cursor: Int, budget: Int) -> Int? {
        guard cursor >= 0, budget > 0 else { return nil }
        let (limit, overflow) = cursor.addingReportingOverflow(budget)
        return overflow ? nil : limit
    }

    @discardableResult
    func synchronizeProviderRequests(_ cp: inout LoopCheckpoint,
                                             budget: ProviderRequestBudget) async -> Int {
        let consumed = await budget.consumedCount()
        cp.providerRequestsConsumed = consumed
        cp.iteration = consumed
        return consumed
    }

    func finishProviderRequestBudgetFailure(
        _ cp: inout LoopCheckpoint,
        budget: ProviderRequestBudget,
        error: ProviderRequestBudgetError
    ) async -> (Outcome, LoopCheckpoint) {
        let consumed = await synchronizeProviderRequests(&cp, budget: budget)
        let summary: String
        switch error {
        case .exhausted:
            summary = "provider request limit reached (\(consumed)/\(maxIterations))"
        case .persistence(let detail):
            summary = "provider request admission failed closed: \(detail)"
        }
        return finishFailed(&cp, summary, summary)
    }

    /// Final synthesis is a real provider call and therefore consumes the next iteration slot.
    /// No spare slot means no hidden call beyond the advertised ceiling.
    static func synthesisIteration(after iteration: Int, limit: Int) -> Int? {
        guard iteration >= 0, iteration < limit else { return nil }
        return iteration + 1
    }

    /// If the token ceiling is reached, finish the run as a budget failure (checked at the top of
    /// each iteration, BEFORE the next model call — so a resumed run that's already over halts at
    /// once and never spends past the cap). Returns nil when uncapped or still under budget.
    func budgetHalt(_ cp: inout LoopCheckpoint) async -> (Outcome, LoopCheckpoint)? {
        guard let budget, let reason = await budget.exceededReason() else { return nil }
        sink.emit(.stateChanged(.failed))
        return finishFailed(&cp, reason, "\(reason) — inspect /usage; reduce context or split the remaining work before retrying")
    }

    /// Last-chance answer pass. Research models can spend the whole action budget gathering; this
    /// converts "I gathered a lot and then failed" into a final synthesis without granting more tools.
    func attemptTextFinalSynthesis(
        _ cp: inout LoopCheckpoint,
        requestBudget: ProviderRequestBudget
    ) async -> (Outcome, LoopCheckpoint)? {
        // Don't spend another model call on synthesis once the budget is already blown (this pass
        // runs after the loop, so the top-of-iteration check can't guard it).
        if let budget, await budget.isExceeded() { return nil }
        if let blocked = await requestBudget.blockingError() {
            return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget, error: blocked)
        }
        cp.messages.append(ChatMessage(role: .user, content: Self.finalSynthesisSteering(textProtocol: true)))
        persist(&cp)
        var settings = ModelSettings(temperature: 0.2, maxTokens: 4096,
                                     systemPrompt: Self.finalOnlySystemPrompt(textProtocol: true),
                                     disableThinking: providerReasoningEffort == .none,
                                     reasoningEffort: providerReasoningEffort)
        applyProviderReasoningEffort(&settings, checkpoint: &cp)
        let profileStopsApplied = applyModelProfileStops(&settings)
        let completion: CompletionStreamResult
        do {
            let outboundMessages = await prepareForProviderCall(&cp, mode: .text,
                                                                settings: settings,
                                                                reassertObjective: false,
                                                                requestBudget: requestBudget)
            _ = await synchronizeProviderRequests(&cp, budget: requestBudget)
            if let blocked = await requestBudget.blockingError() {
                return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget, error: blocked)
            }
            completion = try await streamCompletion(messages: outboundMessages, settings: settings,
                                                    allowFallback: !profileStopsApplied,
                                                    routePolicy: providerRoutePolicy(
                                                        allowFallback: !profileStopsApplied),
                                                    requestBudget: requestBudget)
        } catch let requestError as ProviderRequestBudgetError {
            return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget,
                                                            error: requestError)
        } catch {
            _ = await synchronizeProviderRequests(&cp, budget: requestBudget)
            return nil
        }
        let iteration = await synchronizeProviderRequests(&cp, budget: requestBudget)
        recordProviderMetadata(completion, checkpoint: &cp)
        let text = completion.text
        cp.messages.append(ChatMessage(role: .assistant, content: text,
                                       providerReasoningHandles: completion.reasoningHandles))

        if let action = ActionParser.parse(text), action.done {
            let summary = action.summary ?? action.message ?? "done"
            return await finishCompleted(&cp, summary: summary, iteration: iteration)
        }
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty, ActionParser.parse(text)?.tool == nil else { return nil }
        return await finishCompleted(&cp, summary: plain, iteration: iteration)
    }

    /// Native equivalent of the last-chance answer pass. It deliberately uses the plain completion
    /// route (no tool specs) so the provider has one job: write the answer from gathered context.
    func attemptNativeFinalSynthesis(
        _ cp: inout LoopCheckpoint,
        requestBudget: ProviderRequestBudget
    ) async -> (Outcome, LoopCheckpoint)? {
        // Don't spend another model call on synthesis once the budget is already blown (this pass
        // runs after the loop, so the top-of-iteration check can't guard it).
        if let budget, await budget.isExceeded() { return nil }
        if let blocked = await requestBudget.blockingError() {
            return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget, error: blocked)
        }
        cp.messages.append(ChatMessage(role: .user, content: Self.finalSynthesisSteering(textProtocol: false)))
        persist(&cp)
        var settings = ModelSettings(temperature: 0.2, maxTokens: 4096,
                                     systemPrompt: Self.finalOnlySystemPrompt(textProtocol: false),
                                     disableThinking: providerReasoningEffort == .none,
                                     reasoningEffort: providerReasoningEffort)
        applyProviderReasoningEffort(&settings, checkpoint: &cp)
        _ = applyModelProfileStops(&settings)
        let completion: CompletionStreamResult
        do {
            let outboundMessages = await prepareForProviderCall(&cp, mode: .native,
                                                                settings: settings,
                                                                reassertObjective: false,
                                                                requestBudget: requestBudget)
            _ = await synchronizeProviderRequests(&cp, budget: requestBudget)
            if let blocked = await requestBudget.blockingError() {
                return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget, error: blocked)
            }
            completion = try await streamCompletion(messages: outboundMessages, settings: settings,
                                                    allowFallback: false,
                                                    routePolicy: providerRoutePolicy(),
                                                    requestBudget: requestBudget)
        } catch let requestError as ProviderRequestBudgetError {
            return await finishProviderRequestBudgetFailure(&cp, budget: requestBudget,
                                                            error: requestError)
        } catch {
            _ = await synchronizeProviderRequests(&cp, budget: requestBudget)
            return nil
        }
        let iteration = await synchronizeProviderRequests(&cp, budget: requestBudget)
        recordProviderMetadata(completion, checkpoint: &cp)
        let text = completion.text
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        cp.messages.append(ChatMessage(role: .assistant, content: plain,
                                       providerReasoningHandles: completion.reasoningHandles))
        sink.emit(.tokenDelta(plain))
        return await finishCompleted(&cp, summary: plain, iteration: iteration)
    }

    func finishCompleted(_ cp: inout LoopCheckpoint, summary: String,
                                 iteration: Int) async -> (Outcome, LoopCheckpoint) {
        // Final synthesis is still only a model claim. It must pass the same durable external-evidence
        // gate as the ordinary text/native done paths; otherwise exhausting the loop after a paused,
        // unverified edit could launder that edit into success through this fallback.
        if case .needsVerification(let why) = CompletionVerifier().check(
            trajectory: recorder.snapshot(), canRunCommands: context.shell.enabled,
            expectedOutcome: cp.expectedOutcome, taskIntent: cp.intent) {
            cp.iteration = iteration
            let honest = "unverified — \(why)"
            await fireStopHook(summary: honest, success: false)
            return finishFailed(&cp, honest, honest)
        }
        cp.status = .completed; cp.summary = summary; cp.iteration = iteration; persist(&cp)
        await fireStopHook(summary: summary, success: true)
        sink.emit(.stateChanged(.completed)); sink.emit(.completed(summary: summary))
        return (Outcome(success: true, summary: summary, iterations: iteration, checkpointId: cp.id), cp)
    }


}
