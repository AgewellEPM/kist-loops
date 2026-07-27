import Foundation

/// A REAL flywheel review stage: N independent models each review the change and return a `ReviewReport`.
/// This is the "independent reviews" node made concrete — the same multi-model panel that catches fail-open
/// holes a single reviewer misses. It is fail-closed by construction:
///   • a reviewer that errors / returns empty ⇒ `completed: false` (consensus rejects a non-completed panel)
///   • only lines a reviewer EXPLICITLY marks BLOCK become blocking findings; a reviewer can raise issues
///     but never mint an accept (accept is the absence of blockers across a completed quorum).
///
/// It reviews a provided change context (diff / summary / file list) so it's self-contained and testable;
/// the flywheel adapter feeds it the build's diff. Wire `complete` to `ProviderCatalog.complete` per model.
public struct CouncilReviewStage: Sendable {
    public typealias Complete = @Sendable (_ reviewer: String, _ system: String, _ user: String) async -> String?

    public let reviewers: [String]   // model ids acting as independent reviewers
    private let complete: Complete

    public init(reviewers: [String], complete: @escaping Complete) {
        self.reviewers = reviewers
        self.complete = complete
    }

    static let system = """
    You are an independent code reviewer on a merge-gate panel. Review the change below for correctness,
    security, and fail-open behavior. Reply in EXACTLY this format:
    - If nothing should block the merge, reply the single line: NO BLOCKING ISSUES
    - Otherwise one finding per line: `BLOCK|<critical|high|med>|<issue>` for anything that must be fixed
      before merge, or `NIT|<low|nit>|<issue>` for non-blocking polish. No prose, no other lines.
    """

    public func review(changeContext: String) async -> [ReviewReport] {
        var reports: [ReviewReport] = []
        for reviewer in reviewers {
            let raw = await complete(reviewer, Self.system, "Change under review:\n\n" + changeContext)
            reports.append(Self.parse(reviewer: reviewer, raw: raw))
        }
        return reports
    }

    /// Parse one reviewer's response into a report. `nil`/blank ⇒ NOT completed (the reviewer didn't run) —
    /// this is what lets the consensus quorum fail closed on a silent reviewer failure.
    static func parse(reviewer: String, raw: String?) -> ReviewReport {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ReviewReport(reviewer: reviewer, completed: false)
        }
        var findings: [ReviewFinding] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3 else { continue }
            let kind = parts[0].uppercased()
            guard kind == "BLOCK" || kind == "NIT" else { continue }
            let severity = ReviewSeverity(rawValue: parts[1].lowercased()) ?? (kind == "BLOCK" ? .high : .nit)
            findings.append(ReviewFinding(reviewer: reviewer, severity: severity, issue: parts[2],
                                          mustFix: kind == "BLOCK"))
        }
        return ReviewReport(reviewer: reviewer, completed: true, findings: findings)
    }
}
