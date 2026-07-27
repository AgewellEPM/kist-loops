import Foundation

public struct UsageCostSummary: Sendable, Equatable {
    public let tokens: Int
    public let knownUSD: Double
    public let unknownTokens: Int

    public init(tokens: Int, knownUSD: Double, unknownTokens: Int) {
        self.tokens = tokens
        self.knownUSD = knownUSD
        self.unknownTokens = unknownTokens
    }

    public func render(label: String = "usage") -> String {
        let dollars = knownUSD > 0 ? String(format: " · ~$%.4f", knownUSD) : ""
        let unknown = unknownTokens > 0 ? " · \(unknownTokens) tok unpriced" : ""
        let prefix = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\(label) · "
        return "\(prefix)\(tokens) tokens\(dollars)\(unknown)"
    }
}

public enum UsageCost {
    /// Built-in estimates are deliberately minimal and overridable. Prices change; these are UX
    /// hints, not billing truth. Users can provide a fuller price book for exact local accounting.
    /// Covers EVERY catalog provider id so a `--max-cost` cap actually fires regardless of vendor
    /// (an unpriced vendor would silently never trigger the dollar cap — the misleading-cap trap the
    /// review flagged). Local providers are $0 (no per-token charge). Rates are conservative UX
    /// estimates, not billing truth, and are overridable.
    public static let conservativePriceBook: [String: ProviderTokenPrice] = [
        "openai": ProviderTokenPrice(inputPerMillionUSD: 5.0, outputPerMillionUSD: 15.0),
        "anthropic": ProviderTokenPrice(inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0),
        "gemini": ProviderTokenPrice(inputPerMillionUSD: 1.25, outputPerMillionUSD: 10.0),
        "grok": ProviderTokenPrice(inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0),
        "deepseek": ProviderTokenPrice(inputPerMillionUSD: 0.27, outputPerMillionUSD: 1.10),
        "mimo": ProviderTokenPrice(inputPerMillionUSD: 0.10, outputPerMillionUSD: 0.40),
        "zhipu": ProviderTokenPrice(inputPerMillionUSD: 0.60, outputPerMillionUSD: 2.20),       // GLM
        "moonshot": ProviderTokenPrice(inputPerMillionUSD: 0.60, outputPerMillionUSD: 2.50),    // Kimi
        "qwen": ProviderTokenPrice(inputPerMillionUSD: 0.40, outputPerMillionUSD: 1.20),
        "doubao": ProviderTokenPrice(inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.60),
        "hunyuan": ProviderTokenPrice(inputPerMillionUSD: 0.30, outputPerMillionUSD: 1.00),
        "ernie": ProviderTokenPrice(inputPerMillionUSD: 0.40, outputPerMillionUSD: 1.20),
        "yi": ProviderTokenPrice(inputPerMillionUSD: 0.30, outputPerMillionUSD: 1.00),
        "stepfun": ProviderTokenPrice(inputPerMillionUSD: 0.40, outputPerMillionUSD: 1.20),
        "baichuan": ProviderTokenPrice(inputPerMillionUSD: 0.40, outputPerMillionUSD: 1.20),
        "minimax": ProviderTokenPrice(inputPerMillionUSD: 0.30, outputPerMillionUSD: 1.10),
        "mlx": ProviderTokenPrice(inputPerMillionUSD: 0.0, outputPerMillionUSD: 0.0),           // local = free
        "ollama": ProviderTokenPrice(inputPerMillionUSD: 0.0, outputPerMillionUSD: 0.0),        // local = free
    ]

    public static func summarize(spans: [AgentSpan],
                                 prices: [String: ProviderTokenPrice] = conservativePriceBook) -> UsageCostSummary {
        let estimate = CompetitiveBenchmark.estimateCost(spans: spans, prices: prices)
        let tokens = spans.reduce(0) { $0 + $1.totalTokens }
        return UsageCostSummary(tokens: tokens, knownUSD: estimate.totalUSD,
                                unknownTokens: estimate.unknownTokenCount)
    }
}
