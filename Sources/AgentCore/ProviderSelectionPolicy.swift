import Foundation

/// How the single-model DEFAULT provider is chosen when the user pins nothing (Luke 2026-08-06:
/// "we need a cost determination option — if they'd rather go by cost than by power").
///
///   • `.power` (default): the STRONGEST available model leads (ModelEscalator rank). claude-cli /
///     codex-cli / gemini lead. Best answers, may cost more per token.
///   • `.cost`: the CHEAPEST available model leads (marginal $/token from the price book). Local
///     models and flat-rate subscription CLIs are $0 marginal; among paid APIs the cheapest wins.
///     Ties break toward the more powerful model, so "cheapest" never means "needlessly weakest".
///
/// Only the DEFAULT pick changes; an explicit `-p/--provider`, `/model`, `/role`, or a team mode
/// (/council, /ultra) always overrides regardless of policy.
public enum ProviderSelectionPolicy: String, Sendable, Equatable, Codable {
    case power
    case cost

    public static let `default`: ProviderSelectionPolicy = .power

    public init?(loose raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "power", "strong", "strongest", "best", "quality": self = .power
        case "cost", "cheap", "cheapest", "budget", "economy", "$": self = .cost
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .power: return "power (strongest model leads)"
        case .cost: return "cost (cheapest model leads)"
        }
    }
}

public enum ProviderCostRank {
    /// Marginal $ per million tokens for RANKING (blended input+output — a coarse but honest
    /// ordering, not a bill). Lower = cheaper. Flat-rate subscription CLIs and truly-local models
    /// are 0 (no per-token charge). An unknown vendor sorts as expensive so `.cost` never silently
    /// prefers something it can't price.
    public static func marginalPerMillion(_ providerId: String,
                                          prices: [String: ProviderTokenPrice] = UsageCost.conservativePriceBook) -> Double {
        let id = providerId.lowercased()
        // Subscription CLIs authenticate through the CLI and bill a FLAT monthly fee — zero marginal
        // per-token cost, so under `.cost` they're as cheap as a local model but far more capable.
        if id == "claude-cli" || id == "codex-cli" { return 0.0 }
        guard let p = prices[id] else { return .greatestFiniteMagnitude }
        return (p.inputPerMillionUSD + p.outputPerMillionUSD) / 2.0
    }
}
