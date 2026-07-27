import Foundation
import AgentCore

// RoleSelection / RoleCommand — the terminal's role↔provider binding state machine.
// Extracted verbatim from KistREPL.swift (Pass-1 modularization; no behavior change).
extension KistREPL {

    struct RoleSelection: Equatable {
        private(set) var fallback: ProviderBinding
        private var bound: [AgentRole: ProviderBinding]
        private let initialError: String?

        init(default fallback: ProviderBinding,
             plannerSpec: String? = nil,
             workerSpec: String? = nil,
             coderSpec: String? = nil,
             criticSpec: String? = nil) {
            self.fallback = fallback
            var initial: [AgentRole: ProviderBinding] = [:]
            var initialError: String?

            func bind(_ spec: String?, to role: AgentRole) {
                guard let spec else { return }
                guard let b = ProviderBinding.parse(spec) else {
                    if initialError == nil { initialError = "invalid \(role.rawValue) binding '\(spec)'" }
                    return
                }
                initial[role] = b
            }

            bind(plannerSpec, to: .planner)
            bind(workerSpec, to: .worker)
            bind(coderSpec, to: .coder)
            bind(criticSpec, to: .critic)
            self.bound = initial
            self.initialError = initialError
        }

        var bindings: RoleBindings {
            var roles = RoleBindings(default: fallback)
            for role in AgentRole.allCases {
                if let binding = bound[role] { roles = roles.binding(role, to: binding) }
            }
            return roles
        }

        var summary: String { bindings.summary }

        mutating func assign(_ role: AgentRole, to binding: ProviderBinding, knownProviders: [String: String]) -> String? {
            let canonical = canonicalized(binding, knownProviders: knownProviders)
            if canonical == nil {
                return "unknown provider '\(binding.providerId)'. Run --list-providers to see configured ids."
            }
            bound[role] = canonical ?? binding
            return nil
        }

        /// Switch the SESSION DEFAULT (provider+model) that the conversational loop and every unbound
        /// role inherit. Explicit per-role `/roles` bindings are untouched. Returns an error string on
        /// an unknown provider, leaving the default unchanged.
        mutating func setDefault(_ binding: ProviderBinding, knownProviders: [String: String]) -> String? {
            guard let canonical = canonicalized(binding, knownProviders: knownProviders) else {
                return "unknown provider '\(binding.providerId)'. Run /providers to see configured ids."
            }
            fallback = canonical
            return nil
        }

        mutating func assignSpec(_ spec: String?, to role: AgentRole, knownProviders: [String: String]) -> String? {
            guard let spec else { return nil }
            guard let binding = ProviderBinding.parse(spec) else {
                return "invalid \(role.rawValue) binding '\(spec)'"
            }
            return assign(role, to: binding, knownProviders: knownProviders)
        }

        mutating func apply(_ profile: RoleProfileStore.Profile, knownProviders: [String: String]) -> String? {
            var next = self
            for role in AgentRole.allCases {
                guard let binding = profile.binding(for: role) else {
                    return "invalid \(role.rawValue) binding in role profile"
                }
                if let error = next.assign(role, to: binding, knownProviders: knownProviders) { return error }
            }
            self = next
            return nil
        }

        mutating func canonicalizeProviders(knownProviders: [String: String]) {
            guard !knownProviders.isEmpty else { return }
            fallback = canonicalized(fallback, knownProviders: knownProviders) ?? fallback
            for (role, binding) in bound {
                bound[role] = canonicalized(binding, knownProviders: knownProviders) ?? binding
            }
        }

        func validationError(knownProviders: [String: String]) -> String? {
            if let initialError { return initialError }
            guard !knownProviders.isEmpty else { return nil }
            guard canonicalized(fallback, knownProviders: knownProviders) != nil else {
                return "unknown default provider '\(fallback.providerId)'"
            }
            for role in AgentRole.allCases {
                guard let binding = bound[role], canonicalized(binding, knownProviders: knownProviders) == nil else { continue }
                return "unknown \(role.rawValue) provider '\(binding.providerId)'"
            }
            return nil
        }

        mutating func reset() { bound = [:] }

        private func canonicalized(_ binding: ProviderBinding, knownProviders: [String: String]) -> ProviderBinding? {
            guard !knownProviders.isEmpty else { return binding }
            guard let providerId = knownProviders[binding.providerId.lowercased()] else { return nil }
            return ProviderBinding(providerId: providerId, model: binding.model)
        }
    }


    enum RoleCommand: Equatable {
        case show
        case reset
        case assign(AgentRole, ProviderBinding)
        case save(String)
        case load(String)
        case delete(String)
        case profiles
    }
}
