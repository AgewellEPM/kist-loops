import Foundation

/// A directed message from one agent to another.
struct BusMessage: Identifiable, Equatable, Codable {
    let id: String
    let from: String
    let to: String
    let content: String
    let timestamp: Date

    init(id: String = UUID().uuidString, from: String, to: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.from = from
        self.to = to
        self.content = content
        self.timestamp = timestamp
    }
}

/// Per-engine bus enabling true bidirectional agent↔agent messaging: an agent
/// addresses a message to another agent's inbox; the recipient drains its inbox
/// when it next runs and can reply. This is richer than one-directional handoffs
/// (lead → specialist) — any agent can message any other, back and forth.
///
/// One bus per `AgentLoopEngine` instance, so a spawned sub-team has its own
/// isolated bus (no cross-team message leakage).
@MainActor
final class AgentMessageBus {
    private var inboxes: [String: [BusMessage]] = [:]
    /// Full delivery log (newest last) for UI / debugging.
    private(set) var log: [BusMessage] = []

    /// Deliver a message to `to`'s inbox.
    func send(from: String, to: String, content: String, id: String = UUID().uuidString, timestamp: Date = Date()) {
        let message = BusMessage(id: id, from: from, to: to, content: content, timestamp: timestamp)
        inboxes[to, default: []].append(message)
        log.append(message)
    }

    /// Messages waiting for `agentId` (without removing them).
    func pending(for agentId: String) -> [BusMessage] {
        inboxes[agentId] ?? []
    }

    func pendingCount(for agentId: String) -> Int {
        inboxes[agentId]?.count ?? 0
    }

    /// Return and CLEAR `agentId`'s inbox.
    func drain(for agentId: String) -> [BusMessage] {
        let messages = inboxes[agentId] ?? []
        inboxes[agentId] = []
        return messages
    }

    func clear() {
        inboxes.removeAll()
        log.removeAll()
    }
}
