import Foundation

/// Pure aggregation logic for a tag-team review: classify each reviewer's verdict,
/// then decide whether the builder must go fix things. No I/O — fully testable.
public enum ReviewVerdict: String, Sendable, Equatable {
    case ship        // reviewer says SHIP, no blockers
    case mustFix     // reviewer says NO-SHIP or found a BLOCKER
    case unclear     // no clear signal
}

public struct ReviewResult: Sendable, Equatable {
    public let reviewer: String
    public let text: String
    public let verdict: ReviewVerdict
    public let blockers: Int
    public let highs: Int
    public init(reviewer: String, text: String, verdict: ReviewVerdict, blockers: Int, highs: Int) {
        self.reviewer = reviewer
        self.text = text
        self.verdict = verdict
        self.blockers = blockers
        self.highs = highs
    }
}

public struct PanelVerdict: Sendable, Equatable {
    public let mustFix: Bool
    public let verdict: ReviewVerdict
    /// Reviewers (by name) that demand fixes, with their blocker/high counts.
    public let objectors: [String]
    public init(mustFix: Bool, verdict: ReviewVerdict, objectors: [String]) {
        self.mustFix = mustFix
        self.verdict = verdict
        self.objectors = objectors
    }
}

public enum ReviewClassifier {
    /// Count non-overlapping occurrences of `token` (case-insensitive).
    public static func count(_ haystack: String, _ token: String) -> Int {
        guard !token.isEmpty else { return 0 }
        return haystack.lowercased().components(separatedBy: token.lowercased()).count - 1
    }

    /// Classify one reviewer's raw text into a verdict + severity counts. Conservative:
    /// any BLOCKER or an explicit NO-SHIP means mustFix, even if "SHIP" also appears.
    public static func classify(reviewer: String, text: String) -> ReviewResult {
        let lower = text.lowercased()
        let blockers = count(lower, "blocker")
        let highs = count(lower, "high")
        let saysNoShip = lower.contains("no-ship") || lower.contains("no ship")
        let saysShip = lower.contains("ship") && !saysNoShip

        let verdict: ReviewVerdict
        if saysNoShip || blockers > 0 {
            verdict = .mustFix
        } else if saysShip {
            verdict = .ship
        } else {
            verdict = .unclear
        }
        return ReviewResult(reviewer: reviewer, text: text, verdict: verdict, blockers: blockers, highs: highs)
    }

    /// Combine reviewer results. mustFix if ANY reviewer demands a fix (a single skeptic
    /// with a blocker outweighs the rest — the whole point of a tag team).
    public static func summarize(_ results: [ReviewResult]) -> PanelVerdict {
        let objectors = results.filter { $0.verdict == .mustFix }.map(\.reviewer)
        if !objectors.isEmpty {
            return PanelVerdict(mustFix: true, verdict: .mustFix, objectors: objectors)
        }
        // No objections: SHIP only if every reviewer was a clear ship; else unclear.
        let allShip = !results.isEmpty && results.allSatisfy { $0.verdict == .ship }
        return PanelVerdict(mustFix: false, verdict: allShip ? .ship : .unclear, objectors: [])
    }
}
