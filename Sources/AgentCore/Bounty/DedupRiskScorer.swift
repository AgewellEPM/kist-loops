import Foundation

/// Estimates how likely a finding is ALREADY reported (a duplicate) — the thing that wastes a hunter's
/// time and dings reputation. Deterministic + honest: it never claims certainty, only a risk in [0,1] with
/// reasons. The strongest signal is your OWN history (you literally filed this pattern before); weaker
/// signals are heuristic (low-severity, high-commonness rules that everyone's scanner also finds).
public struct DedupSignal: Sendable, Equatable {
    public let risk: Double          // 0 = looks novel, 1 = almost certainly a duplicate
    public let reasons: [String]
    public var novelty: Double { max(0, 1 - risk) }
}

public struct DedupRiskScorer: Sendable {
    /// Your prior submissions (from `SubmissionTracker.list`) — the ground-truth "already filed" signal.
    public let priorSubmissions: [SubmissionRecord]
    public init(priorSubmissions: [SubmissionRecord] = []) { self.priorSubmissions = priorSubmissions }

    /// Rules so common that a bare hit is very likely a known/duplicate issue for a mature target.
    static let highCommonnessRules: Set<String> = [
        "weak-hash-md5", "weak-hash-sha1", "ats-arbitrary-loads"
    ]

    public func score(finding f: SecurityFinding) -> DedupSignal {
        var reasons: [String] = []

        // 1) OWN HISTORY — the hard signal.
        if priorSubmissions.contains(where: { $0.findingId == f.id }) {
            return DedupSignal(risk: 0.95, reasons: ["you already submitted this exact finding (\(f.id))"])
        }
        let pattern = Self.patternKey(f.id)   // category:rule:file (line-agnostic)
        if priorSubmissions.contains(where: { Self.patternKey($0.findingId) == pattern }) {
            reasons.append("you already submitted the same rule on the same file — likely the same issue")
            return DedupSignal(risk: 0.8, reasons: reasons)
        }

        // 2) HEURISTIC baseline from severity + rule commonness.
        var risk: Double
        switch f.severity {
        case .info, .low:
            risk = 0.55; reasons.append("low/info severity — commonly duplicated, scanners find these everywhere")
        case .medium:
            risk = 0.35
        case .high, .critical:
            risk = 0.18; reasons.append("high-impact class — more likely to be novel/valuable if it reproduces")
        }
        if Self.highCommonnessRules.contains(f.rule) {
            risk += 0.2; reasons.append("rule '\(f.rule)' is very common — higher duplicate odds")
        }
        if f.category == .dependency || f.category == .config {
            risk += 0.1; reasons.append("\(f.category.rawValue) findings are frequently already known")
        }
        if reasons.isEmpty { reasons.append("no prior match; moderate baseline duplicate risk") }
        return DedupSignal(risk: min(1, max(0, risk)), reasons: reasons)
    }

    /// "category:rule:file:line" → "category:rule:file" (drop the line so the same rule on the same file at
    /// a different line still counts as the same reported pattern).
    static func patternKey(_ id: String) -> String {
        guard let lastColon = id.lastIndex(of: ":") else { return id }
        return String(id[..<lastColon])
    }
}
