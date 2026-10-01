import Foundation
import AgentCore

extension KistRunner {
    static func configuredLocalProvider(_ provider: any ChatProvider, config: KistConfig) -> any ChatProvider {
        guard let binding = config.localFirstBinding, let model = binding.model,
              provider.id == binding.providerId, let ollama = provider as? OllamaProvider else { return provider }
        return OllamaProvider(defaultModel: model, availableModels: ollama.availableModels,
                              automaticAcquisition: true)
    }

    static func modelRouter(registry: ProviderRegistry, fallback: ProviderBinding) -> AutoModelRouter {
        let candidates: [AutoModelRouter.Candidate] = registry.providers
            .filter { registry.hasKey(for: $0) }
            .map { provider in
                let model = provider.id == fallback.providerId
                    ? provider.resolvedModel(fallback.model) : provider.defaultModel
                let caps = registry.capabilities(providerId: provider.id, model: model)
                return .init(binding: ProviderBinding(providerId: provider.id, model: model),
                             vision: caps.vision, reasoning: caps.reasoning,
                             contextTokens: caps.contextWindowTokens ?? 0,
                             fast: AutoModelRouter.isFastModel(model, contextTokens: caps.contextWindowTokens ?? 0))
            }
            .sorted { a, b in a.binding.providerId == "gemini" && b.binding.providerId != "gemini" }
        return AutoModelRouter(candidates: candidates, fallback: fallback)
    }

    static func interactiveAutoRoute(autoRouting: Bool, config: KistConfig,
                                     noMemory: Bool, root: String, registry: ProviderRegistry,
                                     autoRouter: AutoModelRouter,
                                     avoidProvider: @escaping @Sendable (String) -> Bool)
        -> (String, Bool, ProviderBinding) -> AutoModelRouter.Decision {
        if autoRouting, let local = config.localFirstBinding {
            return { text, hasMedia, _ in
                autoRouter.localFirstDecision(text, hasMedia: hasMedia, local: local,
                                              avoid: avoidProvider)
            }
        }
        if autoRouting {
            let snapshot = ProjectSnapshot.capture(repo: root, registry: registry)
            // Respect --no-memory: no learned-outcome retrieval when cross-run memory is disabled
            // (mirrors the fleet's gate). Snapshot + learning captured ONCE (not per turn).
            let learning = noMemory ? nil : CaptainLearningStore(projectRoot: root).assignmentContext()
            return { text, _, current in
                // No keyed providers to reason over ⇒ the standalone heuristic (one-provider setups).
                guard !snapshot.providers.isEmpty else {
                    return autoRouter.route(text, hasMedia: false, current: current,
                                            avoid: avoidProvider)
                }
                // Fall back to the CURRENT model (not the startup default): "stay" must mean stay on
                // whatever we're on now, or a no-signal turn route-flips back after any switch (Codex HIGH).
                let a = ModelAssignmentEngine.assignInteractive(turn: text, snapshot: snapshot,
                                                                fallback: current, learning: learning,
                                                                unavailable: avoidProvider)
                return AutoModelRouter.captainDecision(a, fallback: current,
                                                       avoid: avoidProvider)
            }
        } else {
            return { text, hasMedia, current in
                autoRouter.route(text, hasMedia: hasMedia, current: current,
                                 avoid: avoidProvider)
            }
        }
    }
}
