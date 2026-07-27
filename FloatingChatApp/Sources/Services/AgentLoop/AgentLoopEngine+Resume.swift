import Foundation
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "AgentLoopEngine.Resume")

/// Orchestration resume + live re-plan for the multi-agent engine.
///
/// Resume is PHASE-granular and is only offered for modes with a clean phase
/// cursor (sequential, debate). Parallel/collaborative are intentionally NOT
/// resumed — re-running them would duplicate side effects (the same hazard the
/// single-agent loop guards against). We fail loudly rather than duplicate.
extension AgentLoopEngine {

    // MARK: - Live re-plan (shared by all modes via runAgentLoop)

    /// Conservative environmental-failure classifier (mirrors the single-agent
    /// runtime): such failures don't advance the re-plan streak.
    func isEnvironmentalFailure(_ result: ToolResult) -> Bool {
        let haystack = ((result.error ?? "") + " " + result.output).lowercased()
        return haystack.contains("project path not set")
            || haystack.contains("no project path")
    }

    /// Ask the agent's provider for a revised strategy after repeated failures.
    func requestAgentReplan(agent: AgentConfig, goal: String) async -> String? {
        let failures = conversationHistory.compactMap { message -> String? in
            if case .toolResult(_, _, let result, _, _) = message, !result.success {
                return result.error ?? (result.output.isEmpty ? nil : result.output)
            }
            return nil
        }
        let completed = conversationHistory.compactMap { message -> String? in
            if case .toolResult(_, let name, let result, _, _) = message, result.success {
                return name
            }
            return nil
        }
        let context = ReplanContext(
            goal: goal,
            completedSummary: completed.isEmpty ? "" : completed.map { "• \($0)" }.joined(separator: "\n"),
            recentFailures: failures
        )
        return await ReplanEngine.reviseStrategy(context, provider: getProvider(for: agent))
    }

    // MARK: - Orchestration persistence

    /// Persist the active orchestration checkpoint. Returns whether the write
    /// landed (callers about to do irreversible work should check it).
    @discardableResult
    func persistOrchestration() -> Bool {
        guard persistOrchestrationCheckpoints, var checkpoint = activeOrchestration else { return true }
        checkpoint.updatedAt = Date()
        activeOrchestration = checkpoint
        do {
            try orchestrationStore.save(checkpoint)
            return true
        } catch {
            logger.error("Orchestration checkpoint save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Mark the active orchestration complete (unless it was cancelled).
    func finalizeOrchestration() {
        guard activeOrchestration != nil else { return }
        if activeOrchestration!.status == .cancelled { return }
        activeOrchestration!.status = .completed
        activeOrchestration!.phase = .done
        activeOrchestration!.conversationHistory = conversationHistory
        persistOrchestration()
    }

    // MARK: - Resume

    /// Resume a previously-checkpointed orchestration from its last phase.
    /// Supported for `.sequential` and `.debate`; returns an error for modes
    /// whose resume would duplicate side effects.
    @discardableResult
    func resumeOrchestration(checkpointId: String) async -> Bool {
        guard !isProcessing else {
            logger.error("Cannot resume: a run is already in progress")
            return false
        }
        isProcessing = true
        defer { isProcessing = false }

        let checkpoint: OrchestrationCheckpoint
        do {
            checkpoint = try orchestrationStore.load(id: checkpointId)
        } catch {
            logger.error("Could not load orchestration \(checkpointId): \(error.localizedDescription)")
            return false
        }

        guard checkpoint.isResumable else {
            logger.error("Orchestration \(checkpointId) is not resumable (status \(checkpoint.status.rawValue), phase \(checkpoint.phase.rawValue))")
            return false
        }
        guard checkpoint.mode == .sequential || checkpoint.mode == .debate else {
            logger.error("Resume not supported for \(checkpoint.mode.rawValue) (would duplicate side effects)")
            return false
        }

        // Restore engine state.
        reset()
        orchestrationCancelRequested = false
        projectPath = checkpoint.projectPath
        agents = checkpoint.agents
        for agent in checkpoint.agents { agentStates[agent.id] = AgentState(id: agent.id) }
        currentSession = MultiAgentSession(agents: checkpoint.agents, projectPath: checkpoint.projectPath)
        conversationHistory = checkpoint.conversationHistory

        // Resume reconciliation (Codex HIGH): the most recent phase may have
        // only partially completed before the interruption. Tell the team to
        // verify state and redo ONLY missing work, instead of blindly replaying
        // a phase that already had side effects.
        conversationHistory.append(.user("""
            ⚠️ This team run was interrupted and is being resumed. The most recent \
            phase may have only partially completed. Before redoing anything, verify \
            the current state (files on disk, build status) and redo ONLY work that \
            is actually missing — do not repeat actions that already took effect.
            """))

        var run = checkpoint
        run.status = .running
        run.conversationHistory = conversationHistory
        run.pendingTool = nil   // interrupted tool is covered by the note above
        activeOrchestration = run
        // Fail-closed: don't resume onto an unreliable store.
        if !persistOrchestration() {
            logger.error("Resume reconciliation checkpoint failed; aborting resume")
            isRunning = false
            return false
        }

        isRunning = true
        switch checkpoint.mode {
        case .sequential:
            await runSequentialOrchestration(
                message: checkpoint.userMessage,
                startIndex: checkpoint.sequentialIndex ?? 0
            )
        case .debate:
            if checkpoint.phase == .synthesis {
                // Skip straight to synthesis: startRound == maxRounds short-
                // circuits the round loop.
                await runDebateOrchestration(
                    message: checkpoint.userMessage,
                    startRound: debateMaxRounds,
                    skipInitialPositions: true
                )
            } else {
                await runDebateOrchestration(
                    message: checkpoint.userMessage,
                    startRound: checkpoint.debateRound ?? 0,
                    skipInitialPositions: checkpoint.phase != .started
                )
            }
        default:
            break
        }

        finalizeOrchestration()
        isRunning = false
        return true
    }
}
