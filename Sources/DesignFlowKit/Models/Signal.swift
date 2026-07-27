import Foundation

/// A raw opportunity harvested from an external source (HN, Reddit, GitHub…).
public struct Signal: Codable, Sendable, Equatable {
    public let source: String
    public let title: String
    public let body: String
    public let url: String
    public let engagement: Int

    public init(source: String, title: String, body: String, url: String, engagement: Int) {
        self.source = source
        self.title = title
        self.body = body
        self.url = url
        self.engagement = engagement
    }

    /// One-line brief handed to the pipeline as the seed intent.
    public var brief: String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBody.isEmpty ? title : "\(title) — \(trimmedBody)"
    }
}

/// A signal after ranking, carrying its computed pain score.
public struct RankedSignal: Codable, Sendable, Equatable {
    public let signal: Signal
    public let score: Double

    public init(signal: Signal, score: Double) {
        self.signal = signal
        self.score = score
    }
}
