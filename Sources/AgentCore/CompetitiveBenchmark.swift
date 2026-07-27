import Foundation

/// User-supplied per-provider price in USD per million tokens.
///
/// Prices change often, so Mythos does not hardcode them into the trust layer. A launch/benchmark
/// run supplies the current price book, and this layer computes dollars-per-verified-success from
/// measured spans.
public struct ProviderTokenPrice: Sendable, Codable, Equatable {
    public let inputPerMillionUSD: Double
    public let outputPerMillionUSD: Double

    public init(inputPerMillionUSD: Double, outputPerMillionUSD: Double) {
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
    }
}

public struct CostEstimate: Sendable, Codable, Equatable {
    public let inputUSD: Double
    public let outputUSD: Double
    public let unknownTokenCount: Int

    public init(inputUSD: Double, outputUSD: Double, unknownTokenCount: Int = 0) {
        self.inputUSD = inputUSD
        self.outputUSD = outputUSD
        self.unknownTokenCount = unknownTokenCount
    }

    public var totalUSD: Double { inputUSD + outputUSD }
}

public struct VerifiedRunCost: Sendable, Codable, Equatable {
    public let label: String
    public let verified: Bool
    public let estimate: CostEstimate

    public init(label: String, verified: Bool, estimate: CostEstimate) {
        self.label = label
        self.verified = verified
        self.estimate = estimate
    }
}

public struct CostPerVerifiedSuccess: Sendable, Codable, Equatable {
    public let totalUSD: Double
    public let verifiedSuccesses: Int
    public let failedRuns: Int

    public init(totalUSD: Double, verifiedSuccesses: Int, failedRuns: Int) {
        self.totalUSD = totalUSD
        self.verifiedSuccesses = verifiedSuccesses
        self.failedRuns = failedRuns
    }

    public var dollarsPerVerifiedSuccess: Double? {
        verifiedSuccesses > 0 ? totalUSD / Double(verifiedSuccesses) : nil
    }
}

public enum CompetitiveBenchmark {
    /// Live per-call dollar cost from measured tokens + a price for `vendor` (defaults to the
    /// conservative price book). Returns nil when the vendor is unpriced — the caller can then keep
    /// the token cap authoritative and flag the $-figure as incomplete rather than undercounting to 0.
    public static func priceUSD(vendor: String?, promptTokens: Int, completionTokens: Int,
                                prices: [String: ProviderTokenPrice] = UsageCost.conservativePriceBook) -> Double? {
        guard let vendor, let price = prices[vendor] else { return nil }
        return Double(max(0, promptTokens)) / 1_000_000.0 * price.inputPerMillionUSD
             + Double(max(0, completionTokens)) / 1_000_000.0 * price.outputPerMillionUSD
    }

    public static func estimateCost(spans: [AgentSpan], prices: [String: ProviderTokenPrice]) -> CostEstimate {
        var input = 0.0
        var output = 0.0
        var unknown = 0
        for span in spans where span.kind == .llmCall {
            guard let vendor = span.vendor, let price = prices[vendor] else {
                unknown += span.promptTokens + span.completionTokens
                continue
            }
            input += Double(span.promptTokens) / 1_000_000.0 * price.inputPerMillionUSD
            output += Double(span.completionTokens) / 1_000_000.0 * price.outputPerMillionUSD
        }
        return CostEstimate(inputUSD: input, outputUSD: output, unknownTokenCount: unknown)
    }

    public static func rollup(_ runs: [VerifiedRunCost]) -> CostPerVerifiedSuccess {
        CostPerVerifiedSuccess(
            totalUSD: runs.reduce(0) { $0 + $1.estimate.totalUSD },
            verifiedSuccesses: runs.filter(\.verified).count,
            failedRuns: runs.filter { !$0.verified }.count
        )
    }
}

public struct ToolEnduranceReport: Sendable, Codable, Equatable {
    public let targetToolCalls: Int
    public let startedToolCalls: Int
    public let succeededToolCalls: Int
    public let failedToolCalls: Int
    public let completed: Bool

    public init(targetToolCalls: Int, startedToolCalls: Int, succeededToolCalls: Int,
                failedToolCalls: Int, completed: Bool) {
        self.targetToolCalls = targetToolCalls
        self.startedToolCalls = startedToolCalls
        self.succeededToolCalls = succeededToolCalls
        self.failedToolCalls = failedToolCalls
        self.completed = completed
    }

    public var reachedTarget: Bool { completed && startedToolCalls >= targetToolCalls && failedToolCalls == 0 }
}

public enum ToolEnduranceBenchmark {
    public static func evaluate(events: [RuntimeEvent], targetToolCalls: Int) -> ToolEnduranceReport {
        var started = 0
        var succeeded = 0
        var failed = 0
        var completed = false
        for event in events {
            switch event {
            case .actionStarted:
                started += 1
            case .actionFinished(_, let success, _, _):
                if success { succeeded += 1 } else { failed += 1 }
            case .completed:
                completed = true
            default:
                break
            }
        }
        return ToolEnduranceReport(targetToolCalls: targetToolCalls,
                                   startedToolCalls: started,
                                   succeededToolCalls: succeeded,
                                   failedToolCalls: failed,
                                   completed: completed)
    }
}
