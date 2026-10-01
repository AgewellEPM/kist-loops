import Foundation
import AgentCore

extension KistRunner {
    /// Comparison keys may be case-folded for independence, but execution contracts must name
    /// the exact resolved model sent on the wire. Ollama quantization tags commonly contain capitals.
    static func builderWireIdentity(_ binding: ProviderBinding, registry: ProviderRegistry) throws -> String {
        guard let provider = registry.provider(id: binding.providerId),
              let model = canonicalProviderModel(provider: provider.id,
                  model: provider.resolvedModel(binding.model)) else {
            throw BuilderPreflightError.invalid("execution identity cannot be resolved")
        }
        return try BuilderModelIdentity(providerID: provider.id, modelID: model).canonicalID
    }

    static func builderWireProducers(_ roles: RoleBindings, registry: ProviderRegistry) throws -> [String] {
        try Set([AgentRole.planner, .worker, .coder].map {
            try builderWireIdentity(roles.binding(for: $0), registry: registry)
        }).sorted()
    }
}
