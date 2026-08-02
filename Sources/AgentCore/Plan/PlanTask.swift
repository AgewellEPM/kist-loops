import Foundation

/// One task in a kist Plan/Action/Test/Review board — the native runbook unit. Both the human
/// (via `/tasks`) and the agent (via the `tasks` tool) read and update these, so a long multi-step
/// effort has one shared, persisted source of truth instead of living only in the conversation.
public struct PlanTask: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        case todo, inProgress, done, blocked
        public var marker: String {
            switch self { case .todo: return "☐"; case .inProgress: return "◐"; case .done: return "☑"; case .blocked: return "⊘" }
        }
    }

    /// What kind of board item this is. This is the contract layer that keeps the shared task tool
    /// from degrading into a generic checklist: planning, doing, testing, reviewing, researching,
    /// deciding, and handing off are different work units with different proof expectations.
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case plan, action, test, review, research, decision, handoff

        public var label: String { rawValue.uppercased() }

        public static func infer(from title: String) -> Kind {
            let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("plan:") { return .plan }
            if lower.hasPrefix("test:") { return .test }
            if lower.hasPrefix("review:") { return .review }
            if lower.hasPrefix("research:") { return .research }
            if lower.hasPrefix("decision:") { return .decision }
            if lower.hasPrefix("handoff:") { return .handoff }
            return .action
        }
    }

    public let id: Int
    public var title: String
    public var detail: String
    public var status: Status
    public var kind: Kind
    public var acceptance: String      // what must be true before this can be called done
    public var verification: String    // command/check/review method that proves acceptance
    public var evidence: [String]      // paths, URLs, test names, logs, PRs, screenshots
    public var owner: String?     // who owns it, e.g. "agent" / "luke"
    public var link: String?      // optional reference (a doc, a path)
    /// Wall-clock time when this task most recently entered `inProgress`. Optional so every
    /// pre-trustworthy-core plan keeps decoding. The REPL uses it only to distinguish work claimed
    /// by the live session from a zombie task left active by an older/crashed session; it is not a
    /// lease and never changes task status automatically.
    public var startedAt: Double?

    public init(id: Int, title: String, detail: String = "", status: Status = .todo,
                kind: Kind? = nil, acceptance: String = "", verification: String = "",
                evidence: [String] = [], owner: String? = nil, link: String? = nil,
                startedAt: Double? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.status = status
        self.kind = kind ?? Kind.infer(from: title)
        self.acceptance = acceptance; self.verification = verification; self.evidence = evidence
        self.owner = owner; self.link = link
        self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, title, detail, status, kind, acceptance, verification, evidence, owner, link, startedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .todo
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? Kind.infer(from: title)
        acceptance = try c.decodeIfPresent(String.self, forKey: .acceptance) ?? ""
        verification = try c.decodeIfPresent(String.self, forKey: .verification) ?? ""
        evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        owner = try c.decodeIfPresent(String.self, forKey: .owner)
        link = try c.decodeIfPresent(String.self, forKey: .link)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt)
    }

    public var boardTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["PLAN:", "ACTION:", "TEST:", "REVIEW:", "RESEARCH:", "DECISION:", "HANDOFF:", "BACKLOG:"] {
            if trimmed.uppercased().hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).description
            }
        }
        return trimmed
    }

    public var verificationText: String {
        let trimmed = verification.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("verify:") {
            return String(trimmed.dropFirst("verify:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// An active task belongs to this REPL session only when it was explicitly started after the
    /// session began. Legacy tasks have no timestamp and are deliberately treated as stale.
    public func isActive(since sessionStart: Date) -> Bool {
        status == .inProgress && (startedAt.map { $0 >= sessionStart.timeIntervalSince1970 } ?? false)
    }
}

/// A named, ordered list of tasks. Persisted per project so it survives across sessions.
public struct Plan: Sendable, Codable, Equatable {
    public var title: String
    public var tasks: [PlanTask]
    public var nextId: Int

    public init(title: String = "Plan", tasks: [PlanTask] = [], nextId: Int = 1) {
        self.title = title; self.tasks = tasks; self.nextId = nextId
    }

    public var done: Int { tasks.filter { $0.status == .done }.count }

    /// The lowest-id task that's still actionable (todo) — what "the next task" resolves to.
    public var next: PlanTask? { tasks.filter { $0.status == .todo }.min { $0.id < $1.id } }
    public var active: PlanTask? { tasks.filter { $0.status == .inProgress }.min { $0.id < $1.id } }
    public func active(since sessionStart: Date) -> PlanTask? {
        tasks.filter { $0.isActive(since: sessionStart) }.min { $0.id < $1.id }
    }

    /// The next actionable build task. Research remains visible in its own dashboard
    /// section instead of parking "Next" while implementation work is available.
    public var nextActionable: PlanTask? {
        tasks.filter { $0.status == .todo && $0.kind != .research }
            .min { $0.id < $1.id }
    }

    /// Actionable, non-research work for the dashboard's Build Queue. Completed
    /// tasks leave the queue so visible state advances as work lands.
    public func buildQueue(limit: Int = 6) -> [PlanTask] {
        Array(tasks.filter { $0.kind != .research && $0.status != .done }
            .sorted { $0.id < $1.id }
            .prefix(max(0, limit)))
    }

    public var testPlan: [PlanTask] { tasks.filter { $0.kind == .test } }

    public func render(sessionStartedAt: Date? = nil) -> String {
        guard !tasks.isEmpty else { return "\(title): (no tasks yet — add one with `tasks add`)" }
        var s = "\(title) · \(done)/\(tasks.count) done\n"
        s += "current goal: \(title)\n"
        let renderedActive: String
        if let sessionStartedAt, let current = active(since: sessionStartedAt) {
            renderedActive = "[\(current.id)] \(current.title)"
        } else if let active, sessionStartedAt != nil {
            renderedActive = "[\(active.id)] \(active.title) (stale from an earlier session; select it explicitly to resume)"
        } else {
            renderedActive = active.map { "[\($0.id)] \($0.title)" } ?? "none"
        }
        s += "active task: " + renderedActive + "\n"
        s += "completed: \(done)/\(tasks.count)\n"
        s += "next step: " + (next.map { "[\($0.id)] \($0.title)" } ?? "none") + "\n"
        if testPlan.isEmpty {
            s += "test plan: none\n"
        } else {
            s += "test plan: " + testPlan.map { "[\($0.id)] \($0.boardTitle)" }.joined(separator: "; ") + "\n"
        }
        for t in tasks.sorted(by: { $0.id < $1.id }) {
            s += "  \(t.status.marker) [\(t.id)] \(t.kind.label): \(t.boardTitle)"
            if let owner = t.owner { s += "  \u{001B}[2m(\(owner))\u{001B}[0m" }
            if t.status == .blocked, !t.detail.isEmpty { s += "  \u{001B}[2m— \(t.detail)\u{001B}[0m" }
            s += "\n"
            if !t.acceptance.isEmpty { s += "      acceptance: \(t.acceptance)\n" }
            if !t.verificationText.isEmpty { s += "      verify: \(t.verificationText)\n" }
            if !t.evidence.isEmpty { s += "      evidence: \(t.evidence.joined(separator: "; "))\n" }
        }
        if let n = next { s += "→ next: [\(n.id)] \(n.title)\n" }
        return s
    }
}
