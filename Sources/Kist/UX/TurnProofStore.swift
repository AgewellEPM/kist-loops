import Foundation
import AgentCore

/// Per-turn proof drawer for the calm terminal UX. The live sink writes detailed events here while
/// the default terminal view stays compact; `/logs` and `/details` render this store on demand.
final class TurnProofStore: @unchecked Sendable {
    struct Entry: Equatable {
        enum Kind: String {
            case assistant, reasoning, actionStarted, actionFinished, replan, awaitingApproval, awaitingInput, completed, failed
        }
        let kind: Kind
        let tool: String?
        let success: Bool?
        let text: String
    }

    private let lock = NSLock()
    private var currentGoal: String?
    private var current: [Entry] = []
    private var previousGoal: String?
    private var previous: [Entry] = []
    private let replayStore: RunReplayStore?

    init(replayStore: RunReplayStore? = nil) {
        self.replayStore = replayStore
    }

    func startTurn(goal: String) {
        lock.lock()
        previousGoal = currentGoal
        previous = current
        currentGoal = goal
        current = []
        lock.unlock()
        replayStore?.startTurn(goal: goal)
    }

    func record(_ entry: Entry) {
        lock.lock()
        current.append(entry)
        lock.unlock()
        replayStore?.record(entry)
    }

    func lastEntries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return current.isEmpty ? previous : current
    }

    func renderLast(limit: Int = 80) -> String {
        lock.lock()
        let goal = current.isEmpty ? previousGoal : currentGoal
        let entries = current.isEmpty ? previous : current
        lock.unlock()
        guard !entries.isEmpty else { return "No proof log yet. Run a turn first." }

        var lines: [String] = []
        lines.append("Details")
        if let goal, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Goal: \(String(goal.prefix(160)))")
        }
        for entry in entries.prefix(limit) {
            switch entry.kind {
            case .assistant:
                lines.append("assistant: \(Self.oneLine(entry.text, max: 500))")
            case .reasoning:
                lines.append("reasoning: \(Self.oneLine(entry.text, max: 240))")
            case .actionStarted:
                lines.append("tool started: \(entry.tool ?? "action")" + (entry.text.isEmpty ? "" : " - \(Self.oneLine(entry.text, max: 180))"))
            case .actionFinished:
                let mark = (entry.success ?? false) ? "ok" : "failed"
                lines.append("tool \(mark): \(entry.tool ?? "action") - \(Self.oneLine(entry.text, max: 700))")
            case .replan:
                lines.append("replan: \(Self.oneLine(entry.text, max: 240))")
            case .awaitingApproval:
                lines.append("waiting for approval: \(Self.oneLine(entry.text, max: 240))")
            case .awaitingInput:
                lines.append("waiting for answer: \(Self.oneLine(entry.text, max: 240))")
            case .completed:
                lines.append("completed: \(Self.oneLine(entry.text, max: 500))")
            case .failed:
                lines.append("failed: \(Self.oneLine(entry.text, max: 500))")
            }
        }
        if entries.count > limit { lines.append("... \(entries.count - limit) more event(s)") }
        return lines.joined(separator: "\n")
    }

    private static func oneLine(_ text: String, max: Int) -> String {
        let redacted = SecretScanner.redactSecrets(in: text)
        let compact = redacted
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > max else { return compact.isEmpty ? "(empty)" : compact }
        return String(compact.prefix(max - 1)) + "..."
    }
}
