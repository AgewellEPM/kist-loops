import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Harvests raw opportunity signals from external sources. Real implementation
/// hits public APIs; the stub returns a fixed set for offline runs.
public protocol SignalScanner: Sendable {
    func scan() async throws -> [Signal]
}

/// Real scanner over unauthenticated public endpoints (Hacker News Firebase).
/// Network failure surfaces as a thrown error — it is never masked as "no signals".
public struct HackerNewsScanner: SignalScanner {
    private let limit: Int
    public init(limit: Int = 15) { self.limit = limit }

    public func scan() async throws -> [Signal] {
        let idsURL = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!
        let (idData, _) = try await URLSession.shared.data(from: idsURL)
        let ids = (try? JSONDecoder().decode([Int].self, from: idData)) ?? []
        var signals: [Signal] = []
        for id in ids.prefix(limit) {
            let itemURL = URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!
            guard let (itemData, _) = try? await URLSession.shared.data(from: itemURL),
                  let item = try? JSONDecoder().decode(HNItem.self, from: itemData),
                  let title = item.title
            else { continue }
            signals.append(Signal(
                source: "hackernews",
                title: title,
                body: item.text ?? "",
                url: item.url ?? "https://news.ycombinator.com/item?id=\(id)",
                engagement: (item.score ?? 0) + (item.descendants ?? 0)
            ))
        }
        return signals
    }

    private struct HNItem: Decodable {
        let title: String?
        let text: String?
        let url: String?
        let score: Int?
        let descendants: Int?
    }
}

/// Fixed signals for dry-run / tests. Deterministic ordering.
public struct StubSignalScanner: SignalScanner {
    private let signals: [Signal]
    public init(signals: [Signal]? = nil) {
        self.signals = signals ?? [
            Signal(source: "stub", title: "Nonprofits struggle to build accessible intake forms",
                   body: "Small orgs need ADA-compliant forms but can't afford developers.",
                   url: "https://example.com/1", engagement: 240),
            Signal(source: "stub", title: "Show HN: yet another todo app",
                   body: "A minimal todo list.", url: "https://example.com/2", engagement: 12),
            Signal(source: "stub", title: "Speech therapists want a faster AAC board editor",
                   body: "Building communication boards by hand is slow and error prone.",
                   url: "https://example.com/3", engagement: 180),
        ]
    }
    public func scan() async throws -> [Signal] { signals }
}
