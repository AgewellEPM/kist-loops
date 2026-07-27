import Foundation
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "AgentLoopEngine.SubTeams")

/// Recursive sub-teams: an agent can spawn a whole TEAM to handle a sub-problem.
/// The sub-team runs its own orchestration on a SEPARATE engine instance (so its
/// conversation + single-flight state never collide with the parent) and returns
/// a synthesized result that's fed back into the parent agent's context.
extension AgentLoopEngine {

    /// Whether this engine may spawn a child (one level deeper).
    func canSpawnSubTeam() -> Bool {
        depth + 1 <= maxTeamDepth
    }

    /// Run a sub-team for `request` and return its synthesized result text.
    /// Refuses (returns a note) past the nesting cap instead of recursing forever.
    func spawnSubTeam(_ request: AgentLoopEngine.SpawnTeamRequest, parentAgent: AgentConfig) async -> String {
        guard canSpawnSubTeam() else {
            logger.error("Sub-team refused at depth \(self.depth): max nesting \(self.maxTeamDepth) reached")
            return "[sub-team refused: maximum nesting depth (\(maxTeamDepth)) reached]"
        }

        let team = AgentTeam.allPresets.first { $0.id == request.teamId } ?? .soloAgent
        logger.info("Spawning sub-team '\(team.id)' at depth \(self.depth + 1) for task: \(request.task.prefix(60))")

        // Child runs on its OWN engine instance, one level deeper.
        let child = AgentLoopEngine(depth: depth + 1)
        child.maxTeamDepth = maxTeamDepth
        child.persistOrchestrationCheckpoints = false   // ephemeral within the parent run
        child.setupTeam(team, projectPath: projectPath)

        // Isolate the shared build/retry runtime state so the child's build
        // errors / retry budget don't bleed into the parent's next tool step
        // (Codex HIGH). Snapshot before, restore after.
        let runtimeSnapshot = AgentRuntimeService.shared.captureSnapshot()
        await child.processMessageWithTeam(request.task, team: team)
        AgentRuntimeService.shared.restoreSnapshot(runtimeSnapshot)

        // Prefer the explicitly-captured final result (taken before any
        // ChangeLog summary append), then fall back to the last assistant msg.
        if let result = child.lastSynthesizedResult, !result.isEmpty {
            return result
        }
        let fallback = child.conversationHistory.reversed().compactMap { message -> String? in
            if case .assistant(_, let content, _, _) = message { return content }
            return nil
        }.first
        return fallback ?? "(sub-team produced no result)"
    }
}
