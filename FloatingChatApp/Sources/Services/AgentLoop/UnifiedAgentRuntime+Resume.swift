import Foundation
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "UnifiedRuntime.Resume")

/// Resumable iterative loop.
///
/// The loop body lives here (extracted out of `UnifiedAgentRuntime.process`)
/// so a run can be driven both fresh and resumed-from-disk through ONE code
/// path. State lives in `activeRun` (an `AgentCheckpoint`) which is persisted
/// after every iteration, so a crash/quit can be resumed at the exact step.
extension UnifiedAgentRuntime {

    // MARK: - Loop core (used by both fresh runs and resume)

    /// Run the iterative loop against the current `activeRun`. The checkpoint is
    /// persisted after each iteration and at every terminal state.
    func runIterativeLoop() async -> ExecutionResult {
        guard activeRun != nil else { return .failed("No active run to execute") }

        // Local working mirror of the conversation (the LLM call takes tuples).
        var history: [(role: String, content: String)] = activeRun!.conversation.map {
            ($0.role.rawValue, $0.content)
        }
        var lastResult: ActionExecutionResult? = activeRun!.actionResults.last?.live
        let maxIterations = activeRun!.maxIterations

        // Live re-plan bookkeeping (see ReplanEngine). Both counters are seeded
        // from the checkpoint so resumed runs keep their re-plan budget AND
        // their in-progress failure streak (Codex HIGH-2).
        var consecutiveFailures = activeRun!.consecutiveFailures ?? 0
        var replansUsed = activeRun!.replanCount ?? 0

        logger.info("Iterative loop start: iter=\(self.activeRun!.iterationCount) max=\(maxIterations)")

        // NOTE: single-flight. The runtime is a shared singleton and runs one
        // loop at a time; starting a new run (process/resume) replaces
        // `activeRun`. The optional-chained condition + guard below mean a
        // reset can only stop this loop cleanly, never crash it.
        while (activeRun?.iterationCount ?? Int.max) < maxIterations {
            guard activeRun != nil else { break }

            // Honor cancellation requested between iterations (Codex MED-2).
            if cancelRequested {
                finishRun(status: .cancelled, state: .cancelled, error: nil)
                return .cancelled
            }

            activeRun!.iterationCount += 1
            let iteration = activeRun!.iterationCount

            postUpdate { [self] in
                executionState = .executing
                currentActionIndex = iteration - 1
            }

            // Step 1: prompt — first turn uses the user message, later turns
            // feed back the previous action's result.
            let prompt: String
            if let result = lastResult {
                prompt = AgentPrompts.continuationPrompt(
                    previousAction: result.action.description,
                    result: result.output,
                    success: result.success
                )
            } else {
                prompt = activeRun!.userMessage
            }

            let llmResponse = await callLLMForNextAction(prompt, history: history)

            // Step 2: parse
            guard let iterativeResponse = parseIterativeResponse(llmResponse) else {
                logger.error("Failed to parse iterative response; continuing")
                continue
            }

            if let message = iterativeResponse.message {
                postUpdate { [self, message] in
                    if currentPlan != nil { currentPlan?.summary = message }
                }
            }

            // Step 3: done?
            if iterativeResponse.nextAction.type == .done {
                let summary = iterativeResponse.nextAction.parameters["summary"] as? String ?? "Task completed"
                if summary.hasPrefix("API Error:") || summary.hasPrefix("Error:") {
                    logger.error("Agent failed with API error: \(summary)")
                    finishRun(status: .failed, state: .failed, error: summary)
                    return .failed(summary)
                }
                logger.info("Agent signaled DONE")
                finishRun(status: .completed, state: .completed, error: nil)
                return .success(summary)
            }

            // Step 4: execute.
            let action = iterativeResponse.nextAction

            // Bracket the side effect (Codex HIGH-1): record the action we are
            // ABOUT to run before running it. If we crash mid-execution, resume
            // sees a pendingAction and verifies state instead of replaying.
            activeRun!.pendingAction = CheckpointAction(action)
            activeRun!.executionState = ExecutionStateCodec.string(.executing)

            // If that bracket did NOT durably land, refuse to execute — running
            // an un-checkpointed side effect is exactly the duplicate-on-resume
            // hazard. Pause (resumable) so it can retry once disk recovers.
            if !persistActiveRun() {
                logger.error("Pre-execution checkpoint failed; pausing before side effect")
                finishRun(status: .paused, state: .failed, error: lastCheckpointError ?? "Checkpoint write failed")
                return .failed("Halted before action to avoid an un-checkpointed side effect: \(lastCheckpointError ?? "checkpoint write failed")")
            }

            // Cancellation may have been requested during the LLM call.
            if cancelRequested {
                activeRun!.pendingAction = nil
                finishRun(status: .cancelled, state: .cancelled, error: nil)
                return .cancelled
            }

            let result = await executeAction(action)
            lastResult = result

            // Cancellation requested during the action: record the result we
            // already have, then stop before any further work.
            if cancelRequested {
                activeRun!.pendingAction = nil
                finishRun(status: .cancelled, state: .cancelled, error: nil)
                return .cancelled
            }

            // Failure classification (Codex MED-1): only strategy-relevant
            // failures advance the re-plan streak. Environment failures (e.g.
            // invalid project path) neither advance nor reset it, so they don't
            // burn the limited re-plan budget.
            if result.success {
                consecutiveFailures = 0
            } else if !isEnvironmentalFailure(result) {
                consecutiveFailures += 1
            }

            postUpdate { [self, result] in
                actionResults.append(result)
            }

            // Step 5: extend working context
            history.append(("assistant", llmResponse))
            history.append(("system", """
                Action: \(action.description)
                Result: \(result.success ? "SUCCESS" : "FAILED")
                Output: \(result.output.prefix(1000))
                \(result.error.map { "Error: \($0)" } ?? "")
                """))

            // Step 6: checkpoint the exact cursor + working state, then persist.
            // The action completed, so clear the pending bracket.
            activeRun!.pendingAction = nil
            activeRun!.conversation = history.map { ConversationTurn(rawRole: $0.role, content: $0.content) }
            activeRun!.actionResults.append(CheckpointActionResult(result))
            activeRun!.currentActionIndex = iteration - 1
            activeRun!.retryAttempt = retryAttempt
            activeRun!.consecutiveFailures = consecutiveFailures
            activeRun!.executionState = ExecutionStateCodec.string(.executing)
            persistActiveRun()

            // Step 7: live re-plan. If actions keep failing, step back and ask
            // for a revised strategy rather than grinding to the iteration cap.
            if consecutiveFailures >= replanFailureThreshold && replansUsed < maxReplanAttempts {
                replansUsed += 1  // consume budget for the attempt (success or not)
                activeRun!.replanCount = replansUsed
                if let revised = await requestReplan(history: history) {
                    history.append(("user", ReplanEngine.steeringMessage(for: revised)))
                    consecutiveFailures = 0
                    activeRun!.consecutiveFailures = 0
                    activeRun!.conversation = history.map { ConversationTurn(rawRole: $0.role, content: $0.content) }
                    logger.info("Live re-plan #\(replansUsed) injected after repeated failures")
                }
                persistActiveRun()
            }

            // Cancellation may have been requested during re-plan.
            if cancelRequested {
                finishRun(status: .cancelled, state: .cancelled, error: nil)
                return .cancelled
            }

            // Small delay to prevent runaway loops (matches original behavior).
            // (Post-sleep cancellation is caught by the loop-top check.)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        logger.warning("Max iterations (\(maxIterations)) reached")
        finishRun(status: .failed, state: .failed, error: "Task did not complete within \(maxIterations) iterations")
        return .failed("Task did not complete within \(maxIterations) iterations")
    }

    /// Build re-plan context from the current run and ask the model for a
    /// revised strategy. `history` is accepted for symmetry/future use; the
    /// context is derived from the durable action results.
    private func requestReplan(history: [(role: String, content: String)]) async -> String? {
        let succeeded = activeRun?.actionResults.filter { $0.success }.map { $0.action.description } ?? []
        let failures = activeRun?.actionResults
            .filter { !$0.success }
            .compactMap { $0.error ?? ($0.output.isEmpty ? nil : $0.output) } ?? []

        let context = ReplanContext(
            goal: activeRun?.userMessage ?? "",
            completedSummary: succeeded.isEmpty ? "" : succeeded.map { "• \($0)" }.joined(separator: "\n"),
            recentFailures: failures
        )
        return await ReplanEngine.reviseStrategy(context, provider: ProviderManager.shared.currentProvider)
    }

    // MARK: - Resume

    /// Resume a previously-checkpointed iterative run from disk, picking up at
    /// the exact iteration/cursor it stopped on.
    func resume(checkpointId: String) async -> ExecutionResult {
        guard !isProcessing else {
            return .failed("A run is already in progress. Cancel it before resuming another.")
        }
        isProcessing = true
        defer { isProcessing = false }

        let checkpoint: AgentCheckpoint
        do {
            checkpoint = try checkpointStore.load(id: checkpointId)
        } catch {
            logger.error("Could not load checkpoint \(checkpointId): \(error.localizedDescription)")
            return .failed("Could not load checkpoint: \(error.localizedDescription)")
        }

        guard checkpoint.mode == .iterative else {
            return .failed("Resume is supported for iterative runs only")
        }
        guard checkpoint.isResumable else {
            return .failed("Checkpoint is not resumable (status: \(checkpoint.status.rawValue))")
        }
        guard checkpoint.iterationCount < checkpoint.maxIterations else {
            return .failed("Checkpoint already reached its iteration limit")
        }

        logger.info("Resuming \(checkpointId) at iteration \(checkpoint.iterationCount)/\(checkpoint.maxIterations)")

        // Restore configuration + published UI state.
        reset()
        projectPath = checkpoint.projectPath
        maxIterations = checkpoint.maxIterations

        var run = checkpoint
        run.status = .running

        // Reconcile an interrupted action (Codex HIGH-1): if a side effect was
        // in flight when we stopped, do NOT replay it. Inject a verify-state
        // instruction so the model checks the world before continuing.
        if let pending = run.pendingAction {
            let note = """
            ⚠️ The previous action was interrupted and may or may not have completed:
            "\(pending.live.description)"
            Before doing anything else, OBSERVE and verify the current state
            (filesystem, build status, etc.). Do NOT blindly repeat that action if
            it already took effect — only redo work that is actually missing.
            """
            run.conversation.append(ConversationTurn(role: .user, content: note))
            run.pendingAction = nil
            logger.info("Resume reconciliation: injected verify-state for interrupted action")
        }

        activeRun = run
        activeCheckpointID = run.id
        // Persist the reconciled state (cleared pendingAction) NOW, fail-closed:
        // if this write fails we must not proceed — a re-crash would replay the
        // verify-note and we'd be running on an unreliable store (Codex LOW).
        if !persistActiveRun() {
            logger.error("Resume reconciliation checkpoint failed; aborting resume")
            return .failed("Could not persist resumed state: \(lastCheckpointError ?? "checkpoint write failed")")
        }

        let restoredResults = checkpoint.actionResults.map(\.live)
        let restoredPlan = checkpoint.plan?.live
        let restoredIndex = checkpoint.currentActionIndex
        let restoredRetry = checkpoint.retryAttempt
        postUpdate { [self] in
            if let restoredPlan {
                currentPlan = restoredPlan
                currentIntent = restoredPlan.intent
            }
            actionResults = restoredResults
            currentActionIndex = restoredIndex
            retryAttempt = restoredRetry
            executionState = .executing
        }

        return await runIterativeLoop()
    }

    // MARK: - Persistence helpers

    /// Persist `activeRun` (bumping its timestamp). Returns whether the write
    /// durably landed. Callers that are about to cause an irreversible side
    /// effect MUST check the result and refuse to proceed on `false` — this is
    /// what makes resume safe (Codex re-review root cause).
    ///
    /// Returns `true` when checkpointing is disabled or there is no active run
    /// (nothing to guarantee), so non-critical callers can ignore the result.
    @discardableResult
    func persistActiveRun() -> Bool {
        guard persistCheckpoints, var run = activeRun else { return true }
        run.updatedAt = Date()
        activeRun = run
        do {
            try checkpointStore.save(run)
            if lastCheckpointError != nil { lastCheckpointError = nil }
            return true
        } catch {
            // Surface the failure (Codex MED-2) so callers/UI don't trust this
            // run as resumable when its latest state isn't actually on disk.
            let message = "Checkpoint save failed: \(error.localizedDescription)"
            logger.error("\(message)")
            lastCheckpointError = message
            return false
        }
    }

    /// Conservative classifier: which failures are environmental (transient /
    /// config) rather than strategy-relevant. Only clear environment errors are
    /// excluded from the re-plan streak; everything else counts (Codex MED-1).
    func isEnvironmentalFailure(_ result: ActionExecutionResult) -> Bool {
        let haystack = ((result.error ?? "") + " " + result.output).lowercased()
        return haystack.contains("project path not set")
            || haystack.contains("project path not set or invalid")
    }

    /// Move the active run to a terminal state, persist it, and reflect the
    /// execution state in the UI.
    func finishRun(status: AgentCheckpoint.Status, state: ExecutionState, error: String?) {
        if activeRun != nil {
            activeRun!.status = status
            activeRun!.executionState = ExecutionStateCodec.string(state)
            activeRun!.lastError = error
            persistActiveRun()
        }
        postUpdate { [self] in
            executionState = state
        }
    }
}
