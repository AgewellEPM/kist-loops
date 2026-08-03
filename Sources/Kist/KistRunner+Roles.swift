import Foundation
import AgentCore

/// Role-team resolution helpers, extracted from KistRunner (RED-zone modular split, behavior-preserving).
/// These answer one question: given the CLI flags/config, which (provider, model) fills each agent role
/// (planner/worker/coder/critic), and which providers/vision engine are available to draw from.
extension KistRunner {

    /// Build the role team (planner/coder/critic), falling back to the chosen provider. nil after an error.
    static func resolveRoles(_ opts: KistOptions, _ registry: ProviderRegistry,
                                     providerId: String, model: String?) -> RoleBindings? {
        var selection = KistREPL.RoleSelection(default: ProviderBinding(providerId: providerId, model: model))
        guard applyProfileAndRoleFlags(opts, to: &selection, knownProviders: providerAliases(for: registry)) else { return nil }
        return selection.bindings
    }

    static func applyProfileAndRoleFlags(_ opts: KistOptions, to selection: inout KistREPL.RoleSelection,
                                                 knownProviders: [String: String]) -> Bool {
        if let profileName = opts.roleProfile {
            do {
                let profile = try RoleProfileStore().profile(named: profileName)
                if let error = selection.apply(profile, knownProviders: knownProviders) {
                    err("error: \(error). Try --list-providers."); return false
                }
            } catch {
                err("error: \(error)"); return false
            }
        }

        for (spec, role): (String?, AgentRole) in [
            (opts.plannerSpec, .planner),
            (opts.workerSpec, .worker),
            (opts.coderSpec, .coder),
            (opts.criticSpec, .critic),
        ] {
            if let error = selection.assignSpec(spec, to: role, knownProviders: knownProviders) {
                err("error: \(error). Try --list-providers."); return false
            }
        }

        if let error = selection.validationError(knownProviders: knownProviders) {
            err("error: \(error). Try --list-providers."); return false
        }
        selection.canonicalizeProviders(knownProviders: knownProviders)
        return true
    }

    static func providerAliases(for registry: ProviderRegistry) -> [String: String] {
        var aliases: [String: String] = [:]
        for provider in registry.providers {
            aliases[provider.id.lowercased()] = provider.id
            aliases[provider.name.lowercased()] = provider.id
        }
        return aliases
    }

    static func firstVisionBinding(_ registry: ProviderRegistry) -> ProviderBinding? {
        // Prefer Gemini for image/PDF inspection because it already backs video/audio and files.
        if let g = registry.provider(id: "gemini"), registry.hasKey(for: g),
           let model = g.availableModels.first(where: { $0.isVision })?.id {
            return ProviderBinding(providerId: g.id, model: model)
        }
        for provider in registry.providers where registry.hasKey(for: provider) {
            if let model = provider.availableModels.first(where: { $0.isVision })?.id {
                return ProviderBinding(providerId: provider.id, model: model)
            }
        }
        return nil
    }
}
