import Foundation

/// Ranks report-ready findings so the human works the highest-value ones first: novel + severe + better-
/// paying float up, likely-duplicates and low-impact sink. Deterministic and explainable — every score
/// carries the components that produced it. This is triage, not a gate: nothing is dropped here, only ordered.
public struct PrioritizedFinding: Sendable, Equatable {
    public let finding: SecurityFinding
    public let priority: Double        // 0..1, higher = work first
    public let dedup: DedupSignal
    public let estimatedPayoutUSD: Int?
    public let rationale: String
}

public struct FindingPrioritizer: Sendable {
    // Weights: novelty dominates (a duplicate is worthless no matter how severe), then severity, then payout.
    static let wNovelty = 0.45
    static let wSeverity = 0.35
    static let wPayout   = 0.20

    public let scorer: DedupRiskScorer
    public init(priorSubmissions: [SubmissionRecord] = []) { self.scorer = DedupRiskScorer(priorSubmissions: priorSubmissions) }

    public func rank(_ findings: [SecurityFinding], program: BountyProgramRules) -> [PrioritizedFinding] {
        let scored = findings.map { f -> PrioritizedFinding in
            let dedup = scorer.score(finding: f)
            let payout = program.payoutTableUSD[f.severity.rawValue]
            let priority =
                Self.wNovelty * dedup.novelty +
                Self.wSeverity * Self.severityScore(f.severity) +
                Self.wPayout * Self.payoutScore(payout)
            let rationale = "novelty \(pct(dedup.novelty)) · severity \(f.severity.rawValue) · "
                + (payout.map { "payout $\($0)" } ?? "payout n/a")
                + " → priority \(pct(priority))"
            return PrioritizedFinding(finding: f, priority: priority, dedup: dedup,
                                      estimatedPayoutUSD: payout, rationale: rationale)
        }
        // Highest priority first; ties broken by severity then id for stable output.
        return scored.sorted {
            $0.priority != $1.priority ? $0.priority > $1.priority
                : ($0.finding.severity != $1.finding.severity ? $0.finding.severity > $1.finding.severity
                   : $0.finding.id < $1.finding.id)
        }
    }

    static func severityScore(_ s: SecurityFinding.Severity) -> Double {
        switch s { case .critical: return 1.0; case .high: return 0.8; case .medium: return 0.5; case .low: return 0.2; case .info: return 0.05 }
    }
    /// Normalize a payout to 0..1 (a $5k+ bounty saturates the payout term).
    static func payoutScore(_ usd: Int?) -> Double {
        guard let usd, usd > 0 else { return 0 }
        return min(1.0, Double(usd) / 5000.0)
    }
    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
}
