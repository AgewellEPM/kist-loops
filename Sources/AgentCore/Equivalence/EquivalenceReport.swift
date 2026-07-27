import Foundation

/// The roll-up over a slice's case verdicts — the artifact that becomes the audit-grade EvidenceReport.
/// Its ONE job is honesty: the headline is the WEAKEST LINK, never the count of greens. "If it only says
/// passed, it is dangerous" (council). It reports covered / equivalent / not-covered / unprovable
/// explicitly, and refuses to call a slice equivalent while any capture is broken or any case regressed.
public struct EquivalenceReport: Sendable, Equatable {
    public struct CaseResult: Sendable, Equatable {
        public let id: String
        public let verdict: CaseVerdict
        public init(id: String, verdict: CaseVerdict) { self.id = id; self.verdict = verdict }
    }

    public let results: [CaseResult]
    public init(_ results: [CaseResult]) { self.results = results }

    /// Build directly from evidence (judge each case, keep the id).
    public static func judging(_ evidence: [CaseEvidence]) -> EquivalenceReport {
        EquivalenceReport(evidence.map { CaseResult(id: $0.id, verdict: EquivalenceHarness.judge($0)) })
    }

    public func count(_ v: CaseVerdict) -> Int { results.reduce(0) { $0 + ($1.verdict == v ? 1 : 0) } }
    public var total: Int { results.count }

    /// The overall verdict a human accepts risk against — derived from the WEAKEST case present, in
    /// severity order. Never a bare "passed"; the top tier is explicitly *evidence-bounded*.
    public enum Overall: String, Sendable, Equatable {
        case captureFailed              // at least one broken capture → the evidence itself is invalid
        case regressed                  // at least one real NOT-EQUIVALENT
        case incomplete                 // gaps: NOT-COVERED and/or UNPROVABLE, but nothing regressed
        case evidenceBoundedEquivalent  // every case equivalent, ≥1 case, no gaps
    }

    public var overall: Overall {
        if total == 0 { return .incomplete }                 // nothing tested is a gap, not a pass
        if count(.captureFailed) > 0 { return .captureFailed }
        if count(.notEquivalent) > 0 { return .regressed }
        if count(.notCovered) > 0 || count(.unprovable) > 0 { return .incomplete }
        return .evidenceBoundedEquivalent
    }

    /// Only a fully-covered, fully-equivalent slice with intact captures is eligible to promote toward
    /// cutover. Everything else surfaces its weakest link for a human risk-acceptance decision.
    public var isCutoverEligible: Bool { overall == .evidenceBoundedEquivalent }

    /// The honest, human/audit-readable summary. Leads with the overall (weakest link), then the full
    /// four-state breakdown — gaps are first-class, never hidden behind the green count.
    public func render() -> String {
        var lines = ["Equivalence: \(overall.rawValue.uppercased()) · \(total) case\(total == 1 ? "" : "s")"]
        let order: [(CaseVerdict, String)] = [
            (.equivalent, "equivalent"), (.notEquivalent, "NOT-EQUIVALENT"),
            (.notCovered, "not-covered"), (.unprovable, "unprovable"), (.captureFailed, "CAPTURE-FAILED"),
        ]
        lines.append("  " + order.map { "\($0.1): \(count($0.0))" }.joined(separator: " · "))
        switch overall {
        case .captureFailed:
            lines.append("  ⨯ capture is broken on ≥1 case — evidence is INVALID; fix sealing before any verdict.")
        case .regressed:
            lines.append("  ⨯ ≥1 real regression — NOT safe to cut over.")
        case .incomplete:
            lines.append("  ◐ no regressions, but coverage/provability gaps remain — risk-acceptance required.")
        case .evidenceBoundedEquivalent:
            lines.append("  ✓ evidence-bounded equivalent over this corpus — cutover-eligible pending human sign-off.")
        }
        return lines.joined(separator: "\n")
    }
}
