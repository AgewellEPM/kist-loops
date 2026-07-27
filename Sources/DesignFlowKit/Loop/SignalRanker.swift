import Foundation

/// Pure, deterministic ranking of signals by estimated build-worthiness.
/// No I/O, no randomness — fully unit-testable. Higher score = higher priority.
public struct SignalRanker: Sendable {
    /// Keyword → weight. Biased toward Luke's domain (accessibility, assistive tech)
    /// and away from low-signal noise.
    private let weights: [String: Double]

    public init(weights: [String: Double]? = nil) {
        self.weights = weights ?? [
            "accessible": 3, "accessibility": 3, "ada": 3, "aac": 3,
            "assistive": 3, "disability": 2.5, "therapy": 2.5, "nonprofit": 2,
            "speech": 2, "stroke": 2, "vulnerable": 2, "elderly": 2,
            "build": 1, "tool": 1, "app": 1,
            // negative signals
            "todo app": -3, "hello world": -3, "yet another": -2,
        ]
    }

    public func score(_ signal: Signal) -> Double {
        let haystack = "\(signal.title) \(signal.body)".lowercased()
        var keywordScore = 0.0
        for (term, weight) in weights where haystack.contains(term) {
            keywordScore += weight
        }
        // Engagement contributes on a compressed (log) scale so a viral-but-trivial
        // post can't outrank a high-relevance one.
        let engagementScore = log2(Double(max(signal.engagement, 0)) + 1)
        return keywordScore + engagementScore
    }

    /// Rank descending. Ties broken by engagement then title for determinism.
    public func rank(_ signals: [Signal]) -> [RankedSignal] {
        signals
            .map { RankedSignal(signal: $0, score: score($0)) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.signal.engagement != b.signal.engagement { return a.signal.engagement > b.signal.engagement }
                return a.signal.title < b.signal.title
            }
    }

    /// The single best signal to act on, if any.
    public func top(_ signals: [Signal]) -> RankedSignal? { rank(signals).first }
}
