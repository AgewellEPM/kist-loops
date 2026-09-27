import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Provider selection / routing policy (resolveProvider, pickByPolicy, pickProvider) — extracted from KistRunner.swift to keep the core orchestration file under the
// size limit. Part of `enum KistRunner`.
extension KistRunner {
    static func startupModel(explicit: String?, selectedProvider: String,
                             configProvider: String?, configModel: String?,
                             goalModel: String? = nil) -> String? {
        if let explicit { return explicit }
        if let goalModel { return goalModel }
        guard configProvider == nil || configProvider?.lowercased() == selectedProvider.lowercased() else { return nil }
        return configModel
    }

    /// Explicit flag > config (unless benched) > strongest-or-cheapest available (per selection policy)
    /// > first local. Nil after an error.
    ///
    /// `benched` is the live availability gate (cooldown ledger / health daemon). The `--provider`
    /// flag is absolute. The CONFIGURED default is a standing preference, not a per-run order: when
    /// it is known-benched and a warm eligible provider exists, the warm one leads this run, loudly
    /// (0.17.63 — every one-shot run first walked into the drained OpenAI pinned in captain config,
    /// failed, then substituted; same class of bug the build lane's role warming fixed).
    static func resolveProvider(_ opts: KistOptions, _ registry: ProviderRegistry, configProvider: String?,
                                        verdicts: [String: ModelVerdict] = [:],
                                        policy: ProviderSelectionPolicy = .power,
                                        benched: ((String) -> Bool)? = nil) -> String? {
        if let pid = opts.providerId {
            guard registry.provider(id: pid) != nil else { err("error: unknown provider '\(pid)'. Try --list-providers."); return nil }
            return pid   // explicit user choice always wins — the scorecard/policy never override it
        }
        let liveCooldowns = ProviderCooldownStore()
        let liveHealth = ProviderHealthFileStore()
        let configuredBenched: (String) -> Bool = benched
            ?? { liveCooldowns.coolingDown($0) || liveHealth.down($0) }
        if let pid = configProvider {
            guard registry.provider(id: pid) != nil else { err("error: unknown provider '\(pid)'. Try --list-providers."); return nil }
            if !configuredBenched(pid) { return pid }
            note("router · configured default \(pid) is benched (live failures / health daemon says down) — "
                 + "picking a warm provider for this run; pass --provider \(pid) to force it")
            // fall through: the warm pick below; fail-open re-admits the pin when nothing is warm.
        }
        // Pick the STRONGEST AVAILABLE provider, not whatever sorts first in the catalog. Two kinds are
        // eligible for the single-model default (Luke 2026-08-06 — "strongest leads", team stays opt-in):
        //   • keyed cloud: requiresAPIKey && a key is present (gemini/deepseek/grok/openai/…). MiMo sorts
        //     first in the catalog but 400s on multi-turn tool history, so "first with a key" silently made
        //     it the default and turns died with 0 tool calls — hence rank, not order.
        //   • subscription CLI (claude-cli/codex-cli): requiresAPIKey == false but auth lives in the CLI.
        //     Previously EXCLUDED from the default entirely, so the two STRONGEST providers could never lead
        //     and gemini always won. Now included WHEN `isLocallyAvailable()` passes — a bounded, non-billable
        //     local probe (binary on a trusted PATH + `auth/login status` succeeds; never sends a prompt).
        // Rank by ModelEscalator strength (claude-cli/codex-cli outrank the cloud APIs), scorecard-adjusted so
        // a chronically-failing provider isn't silently chosen. Local models (ollama/mlx, no auth) stay the
        // last-resort fallback below, never chosen over a keyed/subscription provider.
        let subscriptionReady = registry.providers.filter { p in
            !p.requiresAPIKey && (p as? CLIChatProvider)?.isLocallyAvailable() == true
        }
        let keyedCloud = registry.providers.filter { $0.requiresAPIKey && registry.hasKey(for: $0) }
        let eligible = subscriptionReady + keyedCloud
        // Cross-process live-failure memory (cooldowns) + the daemon's health snapshot: a provider
        // that just rate-limited another kist process — or that the health daemon already knows is
        // down — sits out instead of being re-picked by every new session. The health file was
        // previously written but NEVER read here, so a dead ollama became the session default and
        // every turn failed identically (routing audit 2026-08-25).
        // Fail-open: if EVERYTHING is benched, the full eligible set still competes.
        let benchedGate = configuredBenched
        let warm = eligible.filter { !benchedGate($0.id) }
        if warm.count < eligible.count {
            let benched = eligible.map(\.id).filter(benchedGate).sorted().joined(separator: ", ")
            note("router · benched (live failures / health daemon says down): \(benched)")
        }
        if let best = pickByPolicy(warm.isEmpty ? eligible : warm, policy: policy, verdicts: verdicts) { return best.id }
        // Last-resort local fallback honors the same gate: prefer a WARM local provider over the
        // catalog-first one (previously this line blindly returned dead ollama). If every local is
        // benched, still return the first — fail-open, but say so instead of dying silently.
        // "Local" must mean USABLE-local (Codex P2, 2026-08-25): a subscription CLI that is
        // installed but logged out would fail authentication, and the explicit-only COBOL
        // specialist (`kist -p cobol`) only knows COBOL — neither is a sane session default.
        let locals = registry.providers.filter { p in
            guard !p.requiresAPIKey, p.id != "cobol" else { return false }
            if let cli = p as? CLIChatProvider { return cli.isLocallyAvailable() }
            return true
        }
        if let local = locals.first(where: { !benchedGate($0.id) }) ?? locals.first {
            if benchedGate(local.id) {
                note("router · WARNING: all local providers benched; last resort \(local.id) will likely fail until it recovers")
            }
            return local.id
        }
        err("error: no provider has a key. Set one (e.g. export OPENAI_API_KEY=…) or use --provider. See --list-providers.")
        return nil
    }

    /// Pick the default from `eligible` under the selection policy. `.power` → strongest (rank desc).
    /// `.cost` → cheapest marginal $/token (asc), ties broken toward the stronger model so "cheapest"
    /// is never gratuitously the weakest. Pure/testable.
    static func pickByPolicy(_ eligible: [any ChatProvider], policy: ProviderSelectionPolicy,
                             verdicts: [String: ModelVerdict]) -> (any ChatProvider)? {
        switch policy {
        case .power:
            return eligible.max { ModelEscalator.rank($0.id, verdicts: verdicts) < ModelEscalator.rank($1.id, verdicts: verdicts) }
        case .cost:
            return eligible.min { a, b in
                let ca = ProviderCostRank.marginalPerMillion(a.id)
                let cb = ProviderCostRank.marginalPerMillion(b.id)
                if ca != cb { return ca < cb }
                // Equal cost (e.g. two flat-rate/local $0 providers) → prefer the stronger one.
                return ModelEscalator.rank(a.id, verdicts: verdicts) > ModelEscalator.rank(b.id, verdicts: verdicts)
            }
        }
    }

    /// Interactive startup picker for a bare `kist` REPL. It is deliberately TTY-only so piped
    /// commands like `printf '/help\n/exit\n' | kist` still go straight to the REPL.
    static func pickProvider(_ registry: ProviderRegistry, config: KistConfig) async -> ProviderPick? {
        guard stdinIsTTY() else { return nil }
        var reg = registry
        while true {
        let choices = reg.providers.filter { reg.hasKey(for: $0) }
        guard !choices.isEmpty else { return nil }

        note("Select model for this session (Enter = default):")
        for (idx, provider) in choices.enumerated() {
            let model = provider.defaultModel.isEmpty ? "" : " default \(provider.defaultModel)"
            note("  \(idx + 1). \(provider.id) · \(provider.name)\(model)")
        }
        let addIndex = choices.count + 1
        if config.allowedProviders == nil {
            note("  \(addIndex). add · Add a model (any OpenAI-compatible) — auto-tests & configures it")
        }
        FileHandle.standardError.write(Data("provider> ".utf8))
        guard let raw = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        // "Add a model": onboard it (self-heal · self-test · pen-test), then re-render so it's pickable now.
        if raw.lowercased() == "add" || Int(raw) == addIndex {
            guard config.allowedProviders == nil else {
                err("provider onboarding is disabled while allowedProviders is configured")
                continue
            }
            _ = await AddModelFlow.run()
            reg = makeRegistry(config: config)   // rebuild without widening the configured provider boundary
            continue
        }

        let provider: any ChatProvider
        var model: String?
        if let n = Int(raw), choices.indices.contains(n - 1) {
            provider = choices[n - 1]
        } else if let binding = ProviderBinding.parse(raw),
                  let resolved = reg.provider(id: binding.providerId),
                  !resolved.requiresAPIKey || reg.hasKey(for: resolved) {
            provider = resolved
            model = binding.model
        } else {
            err("unknown or unconfigured provider '\(raw)' - using the default.")
            return nil
        }

        if model == nil, !provider.availableModels.isEmpty {
            note("Models for \(provider.id) (Enter = \(provider.defaultModel)):")
            for (idx, candidate) in provider.availableModels.enumerated() {
                note("  \(idx + 1). \(candidate.id)")
            }
            FileHandle.standardError.write(Data("model> ".utf8))
            if let rawModel = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawModel.isEmpty {
                if let n = Int(rawModel), provider.availableModels.indices.contains(n - 1) {
                    model = provider.availableModels[n - 1].id
                } else {
                    model = rawModel
                }
            }
        }

        return ProviderPick(providerId: provider.id, model: model)
        }
    }

}
