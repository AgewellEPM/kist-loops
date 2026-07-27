import Foundation
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "AgentLoopEngine.Messaging")

/// Message-bus settling: after the main orchestration finishes, deliver any
/// outstanding inbox messages so true back-and-forth (A→B→A) actually completes
/// instead of stranding a reply addressed to an agent that already had its turn
/// (Codex MEDIUM). Bounded by `maxRounds` so a chatty pair can't loop forever.
extension AgentLoopEngine {

    func settleMessages(maxRounds: Int = 3) async {
        for round in 0..<maxRounds {
            if orchestrationCancelRequested { return }

            // Only agents on this team that currently have mail.
            let recipients = agents.filter { messageBus.pendingCount(for: $0.id) > 0 }
            // break (not return) so undelivered/unknown-recipient mail is still
            // surfaced below (Codex).
            if recipients.isEmpty { break }

            logger.info("Message settle round \(round + 1): \(recipients.count) recipient(s) with mail")
            for agent in recipients {
                if orchestrationCancelRequested { return }
                // The inbox is drained into context at the top of runAgentLoop;
                // the agent reads its mail and may reply (which re-enqueues).
                await runAgentLoop(agent: agent, initialMessage: "You have new messages from teammates.")
            }
        }

        surfaceUndeliveredMessages()
    }

    /// Make any messages that could not be delivered VISIBLE rather than
    /// silently lost — e.g. addressed to an unknown agent id, or a recipient
    /// that never ran again within the settle budget.
    private func surfaceUndeliveredMessages() {
        let teamIds = Set(agents.map { $0.id })
        var undelivered: [BusMessage] = []
        // Pending for known agents that still didn't drain.
        for id in teamIds { undelivered.append(contentsOf: messageBus.pending(for: id)) }
        // Pending for unknown recipients (typo / non-team target): scan the log
        // for any message whose recipient still has it queued.
        for message in messageBus.log where !teamIds.contains(message.to) {
            if messageBus.pending(for: message.to).contains(where: { $0.id == message.id }) {
                undelivered.append(message)
            }
        }

        guard !undelivered.isEmpty else { return }
        let summary = undelivered.map { "\($0.from)→\($0.to)" }.joined(separator: ", ")
        conversationHistory.append(.error(
            agentId: "system",
            message: "⚠️ \(undelivered.count) agent message(s) undelivered (recipient didn't take another turn or is unknown): \(summary)"
        ))
    }
}
