import Foundation
import AgentCore

/// BUILD-LANE PROVIDER RESILIENCE (2026-09-27).
///
/// Why this exists: the chat/research lanes already route around a dead provider (AutoModelRouter's
/// avoid gate, REPL model substitution, one-shot resilience, cross-process cooldowns). The BUILD lane
/// did not. `runBuilderCompatibility` took the pinned role profile literally, ran the sealed planning
/// pass on the pinned planner with `allowFallback: false`, and on the first live provider failure
/// refused the whole run with "builder refused unsafe compatibility mutation" — a message that reads
/// like a safety veto when the truth was "OpenAI has no credits". Result, observed over weeks of run
/// logs: every `intent=build` turn exited 1/2 while every chat turn on a healthy provider completed,
/// i.e. "he researches fine but can't code".
///
/// Contract:
///   * Substitution only ever moves a role to a provider that is CONFIGURED (key present or keyless)
///     and NOT benched (cooldown ledger / health daemon). It never widens authority: the role's tools,
///     approval gates, and the independent-reviewer requirement are unchanged downstream.
///   * Fail-open, like every other availability gate: if nothing warm is configured for a role, the
///     pinned binding stays and the run fails loudly on the real provider error, exactly as before.
///   * Every substitution is disclosed (`note`, which also lands in the replay as `hostNote`).
extension KistRunner {
    struct RoleSubstitution: Equatable, Sendable {
        let role: AgentRole
        let from: ProviderBinding
        let to: ProviderBinding
        let reason: String
    }

    struct WarmedRoles: Equatable, Sendable {
        let roles: RoleBindings
        let substitutions: [RoleSubstitution]
        /// Roles whose pinned provider is benched but no warm substitute exists (pin kept, fail-open).
        let stranded: [AgentRole]
    }

    /// Preference order per role when its pinned provider is benched. Mirrors
    /// `ModelRouter.bestEffortRoles` (the keyless-default team), extended with the subscription CLIs
    /// and the remaining keyed vendors so an API-account outage still finds a lane. Order within a
    /// role is strength-first for planner/critic and code-first for coder/worker.
    ///
    /// Planner/critic go strength-first: the installed subscription CLIs (the same models the chat
    /// lane succeeds on), then the frontier API keys. Gemini sits BEHIND those on purpose — its
    /// default model is the flash tier, which slipped the sealed plan schema on the first live
    /// substitution (2026-09-27) where a stronger planner would not have.
    static let warmRolePreferences: [AgentRole: [String]] = [
        .planner: ["codex-cli", "claude-cli", "openai", "anthropic", "gemini", "deepseek", "grok",
                   "moonshot", "mimo", "ollama", "mlx"],
        .critic:  ["codex-cli", "claude-cli", "openai", "anthropic", "gemini", "deepseek", "grok",
                   "moonshot", "mimo", "ollama", "mlx"],
        .coder:   ["deepseek", "codex-cli", "claude-cli", "openai", "gemini", "grok", "moonshot",
                   "mimo", "qwen", "ollama", "mlx"],
        .worker:  ["deepseek", "gemini", "codex-cli", "claude-cli", "openai", "grok", "moonshot",
                   "mimo", "qwen", "ollama", "mlx"],
    ]

    /// Pure core: rebind every role whose provider is `benched` to the first preferred provider that
    /// is warm and `usable`. The critic is settled last and never lands on the coder's provider, so
    /// the independent-review requirement is not defeated by the substitution itself.
    static func warmRoleBindings(_ roles: RoleBindings,
                                 benched: (String) -> Bool,
                                 usable: (String) -> Bool,
                                 benchReason: (String) -> String = { _ in "cooling down / health down" }) -> WarmedRoles {
        var next = roles
        var substitutions: [RoleSubstitution] = []
        var stranded: [AgentRole] = []
        for role in [AgentRole.planner, .worker, .coder, .critic] {
            let current = next.binding(for: role)
            guard benched(current.providerId) else { continue }
            let avoidProvider = role == .critic ? next.binding(for: .coder).providerId.lowercased() : nil
            let candidates = warmRolePreferences[role] ?? []
            guard let pick = candidates.first(where: { id in
                let lower = id.lowercased()
                return lower != current.providerId.lowercased()
                    && lower != avoidProvider
                    && !benched(id)
                    && usable(id)
            }) else {
                stranded.append(role)
                continue
            }
            let to = ProviderBinding(providerId: pick)   // the provider's default model
            substitutions.append(RoleSubstitution(role: role, from: current, to: to,
                                                  reason: benchReason(current.providerId)))
            next = next.binding(role, to: to)
        }
        return WarmedRoles(roles: next, substitutions: substitutions, stranded: stranded)
    }

    /// The plan-execute INNER critic is advisory, but every model call in the build stage is
    /// observed as a producer identity and must be one the contract declares (planner / worker /
    /// coder). Warming can move the critic to a provider none of them use (live 2026-09-27:
    /// planner deepseek, critic claude-cli → "Observed provider/model identity is not
    /// contract-bound: producer" after a finished build). Unless the operator pinned --critic,
    /// keep the critic on the planner's provider whenever it is not already a producer provider.
    /// The OUTER independent reviewer is selected separately and stays distinct.
    static func alignInnerCriticWithProducers(_ roles: RoleBindings,
                                              criticPinnedExplicitly: Bool) -> (roles: RoleBindings, moved: Bool) {
        guard !criticPinnedExplicitly else { return (roles, false) }
        let producers = Set([AgentRole.planner, .worker, .coder].map { roles.binding(for: $0).providerId.lowercased() })
        let critic = roles.binding(for: .critic)
        guard !producers.contains(critic.providerId.lowercased()) else { return (roles, false) }
        return (roles.binding(.critic, to: roles.binding(for: .planner)), true)
    }

    /// Registry-backed wiring: benched = live cooldown OR health-daemon down; usable = provider exists
    /// and is keyless or keyed. Both stores re-read their files per call (a recovered provider comes
    /// back without a relaunch).
    static func warmRoleBindings(_ roles: RoleBindings,
                                 registry: ProviderRegistry,
                                 cooldowns: ProviderCooldownStore = ProviderCooldownStore(),
                                 health: ProviderHealthFileStore = ProviderHealthFileStore()) -> WarmedRoles {
        warmRoleBindings(
            roles,
            benched: { cooldowns.coolingDown($0) || health.down($0) },
            usable: providerUsable(registry),
            benchReason: { id in
                cooldowns.coolingDown(id)
                    ? "live cooldown: rate limit, exhausted quota, or outage seen recently"
                    : "health daemon reports it down"
            })
    }

    /// The live availability gate every build-lane selection shares: cooldown ledger OR health
    /// daemon. Both stores re-read their files per call.
    static func liveProviderBenched(cooldowns: ProviderCooldownStore = ProviderCooldownStore(),
                                    health: ProviderHealthFileStore = ProviderHealthFileStore()) -> (String) -> Bool {
        { cooldowns.coolingDown($0) || health.down($0) }
    }

    /// A provider the build lane may bind a role to: registered and READY — `hasKey` is the
    /// registry's readiness verdict (key present for API providers, binary installed for the
    /// subscription CLIs, always true for keyless local engines). A CLI that is merely registered
    /// but not installed must never be picked as a substitute.
    static func providerUsable(_ registry: ProviderRegistry) -> (String) -> Bool {
        { id in
            guard let provider = registry.provider(id: id) else { return false }
            return registry.hasKey(for: provider)
        }
    }

    /// Planner replacement AFTER the pinned planner just failed live (it was not benched yet, so the
    /// up-front pass could not have known). Pure: the failed provider is treated as benched.
    static func warmPlannerSubstitute(afterFailing failed: String,
                                      roles: RoleBindings,
                                      benched: @escaping (String) -> Bool,
                                      usable: (String) -> Bool) -> ProviderBinding? {
        let warmed = warmRoleBindings(
            roles,
            benched: { $0.lowercased() == failed.lowercased() || benched($0) },
            usable: usable)
        return warmed.substitutions.first { $0.role == .planner }?.to
    }

    static func warmPlannerSubstitute(afterFailing failed: String,
                                      roles: RoleBindings,
                                      registry: ProviderRegistry,
                                      cooldowns: ProviderCooldownStore,
                                      health: ProviderHealthFileStore) -> ProviderBinding? {
        warmPlannerSubstitute(afterFailing: failed, roles: roles,
                              benched: { cooldowns.coolingDown($0) || health.down($0) },
                              usable: providerUsable(registry))
    }

    /// A LIVE provider failure seen by the sealed planning pass: the kind that clears with time or a
    /// different vendor, so it earns a cooldown record and one planner substitution. Validation,
    /// budget, and cancellation errors return nil and keep the existing refusal path.
    struct BuildLaneProviderFailure: Equatable, Sendable {
        let summary: String
        let cooldownTTL: TimeInterval
        let quotaExhausted: Bool
    }

    static func buildLaneProviderFailure(_ error: Error) -> BuildLaneProviderFailure? {
        if error is CancellationError { return nil }
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .rateLimited:
                return BuildLaneProviderFailure(summary: "rate limited",
                                                cooldownTTL: ProviderCooldownStore.defaultTTL,
                                                quotaExhausted: false)
            case .http(let status, _):
                if ProviderQuotaExhaustion.isQuotaExhausted(providerError) {
                    return BuildLaneProviderFailure(
                        summary: "account out of credits/quota (HTTP \(status))",
                        cooldownTTL: ProviderQuotaExhaustion.cooldownTTL, quotaExhausted: true)
                }
                guard status == 429 || (500...599).contains(status) else { return nil }
                return BuildLaneProviderFailure(summary: "HTTP \(status)",
                                                cooldownTTL: ProviderCooldownStore.defaultTTL,
                                                quotaExhausted: false)
            case .transport(let detail):
                // The registry reports a cancelled completion as a transport error; that is the
                // operator's ESC, not an outage (same shape ConversationRouter.isCancellation guards).
                if detail == "completion cancelled" { return nil }
                return BuildLaneProviderFailure(summary: "transport failure",
                                                cooldownTTL: ProviderCooldownStore.defaultTTL,
                                                quotaExhausted: false)
            case .streamTimedOut:
                return BuildLaneProviderFailure(summary: "stream timed out",
                                                cooldownTTL: ProviderCooldownStore.defaultTTL,
                                                quotaExhausted: false)
            case .invalidAPIKey, .missingAPIKey:
                // A rejected key will not fix itself in five minutes; bench for the quota window.
                return BuildLaneProviderFailure(summary: "API key missing or rejected",
                                                cooldownTTL: ProviderQuotaExhaustion.cooldownTTL,
                                                quotaExhausted: false)
            case .configuration(let detail):
                guard detail.hasPrefix("local model capacity unavailable:") else { return nil }
                return BuildLaneProviderFailure(summary: "local memory capacity unavailable",
                                                cooldownTTL: 60, quotaExhausted: false)
            case .invalidResponse:
                return nil
            }
        }
        if let cliError = error as? CLIProviderError {
            switch cliError {
            case .exited(_, _, let stderr):
                // "You've hit your usage limit … try again at 1:27 AM" is the subscription's
                // quota wall (seen live 2026-09-27 right after OpenAI's API balance drained);
                // any other non-zero exit is an outage-shaped failure worth the short bench.
                if ProviderQuotaExhaustion.mentioned(in: stderr) {
                    return BuildLaneProviderFailure(summary: "subscription usage limit reached",
                                                    cooldownTTL: ProviderQuotaExhaustion.cooldownTTL,
                                                    quotaExhausted: true)
                }
                return BuildLaneProviderFailure(summary: "CLI exited non-zero",
                                                cooldownTTL: ProviderCooldownStore.defaultTTL,
                                                quotaExhausted: false)
            case .timedOut:
                return BuildLaneProviderFailure(summary: "CLI timed out",
                                                cooldownTTL: ProviderCooldownStore.defaultTTL,
                                                quotaExhausted: false)
            case .notRunnable:
                // A missing/broken binary will not heal in minutes; bench for the long window.
                return BuildLaneProviderFailure(summary: "CLI not runnable",
                                                cooldownTTL: ProviderQuotaExhaustion.cooldownTTL,
                                                quotaExhausted: false)
            case .invalidStructuredOutput:
                return nil   // protocol failure, not availability
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
                return BuildLaneProviderFailure(summary: "network failure (\(urlError.code.rawValue))",
                                                cooldownTTL: ProviderCooldownStore.defaultTTL,
                                                quotaExhausted: false)
            default:
                return nil
            }
        }
        return nil
    }
}
