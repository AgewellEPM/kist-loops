import Foundation
import AgentCore

/// One-shot lanes (`kist "<goal>"`, vm-agent) get the same provider resilience
/// the interactive REPL already had. Before this, a one-shot run locked its
/// provider before reading the goal, never honored an NL pin, and died
/// terminally on the first rateLimited call while the REPL lane substituted.
extension KistRunner {

    /// NL model pin for a one-shot goal: "use claude-cli for this…" pins the
    /// provider exactly as it would in the REPL. Only the goal's HEAD may pin
    /// (same per-turn position rule as the REPL); prose that merely mentions a
    /// model does not match — ControlIntentParser's verb+position guards apply.
    static func oneShotModelPin(goal: String,
                                knownProviders: [String: String]) -> ProviderBinding? {
        let head = String(goal.prefix(120))
        guard case .setModel(let binding)? =
            ControlIntentParser.parse(head, knownProviders: knownProviders)?.action else { return nil }
        return binding
    }

    struct OneShotSubstitution: Equatable {
        var decision: KistREPL.ModelSubstitutionDecision
        /// Rate limits and outages clear with time — those cool the provider down
        /// CROSS-PROCESS. Protocol failures / refusals don't (the scorecard owns those).
        var shouldCooldown: Bool
    }

    /// Substitution decision for a failed one-shot run. Same brain as the REPL
    /// (`KistREPL.modelSubstitutionDecision`) plus a cooldown gate so a
    /// replacement is never itself a provider we just watched fail elsewhere.
    static func oneShotSubstitution(success: Bool,
                                    summary: String,
                                    trajectory: [ActionRecord],
                                    current: ProviderBinding,
                                    roles: RoleBindings,
                                    providerHasKey: ((String) -> Bool)?,
                                    providerModels: [String: [String]],
                                    coolingDown: @escaping (String) -> Bool) -> OneShotSubstitution? {
        let warmHasKey: (String) -> Bool = { pid in
            guard !coolingDown(pid) else { return false }
            return providerHasKey?(pid) ?? true
        }
        guard let decision = KistREPL.modelSubstitutionDecision(
            success: success, summary: summary, trajectory: trajectory,
            current: current, roles: roles,
            providerHasKey: warmHasKey, providerModels: providerModels)
        else { return nil }
        let transient = decision.reason == "provider/transient failure"
            || decision.reason == "provider/connectivity failure"
        return OneShotSubstitution(decision: decision, shouldCooldown: transient)
    }

    /// Registry-backed convenience wiring for the pure decision above.
    static func oneShotSubstitution(outcomeSuccess: Bool,
                                    outcomeSummary: String,
                                    trajectory: [ActionRecord],
                                    current: ProviderBinding,
                                    roles: RoleBindings,
                                    registry: ProviderRegistry,
                                    cooldowns: ProviderCooldownStore) -> OneShotSubstitution? {
        let models = Dictionary(
            registry.providers.map { ($0.id.lowercased(), $0.availableModels.map(\.id)) },
            uniquingKeysWith: { first, _ in first })
        let hasKey: (String) -> Bool = { pid in
            registry.provider(id: pid).map { registry.hasKey(for: $0) } ?? false
        }
        return oneShotSubstitution(success: outcomeSuccess, summary: outcomeSummary,
                                   trajectory: trajectory, current: current, roles: roles,
                                   providerHasKey: hasKey, providerModels: models,
                                   coolingDown: cooldowns.coolingDown)
    }
}
