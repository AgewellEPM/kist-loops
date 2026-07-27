import Foundation

/// The agent roles a Mythos run can assign to DIFFERENT vendors — the heart of the differentiator
/// ("Claude plans, GPT codes, Gemini reviews, local does grunt work"). The research's four archetypes:
/// a planner that decomposes the goal, read-only workers, a coder that writes, and a critic that
/// verifies. Plan/execute binds `planner`, `coder`, and `critic`; `spawn_agent` can route dynamic
/// sub-agents through any of these roles, including `worker`/researcher.
public enum AgentRole: String, Sendable, CaseIterable, Codable {
    case planner    // decomposes the goal into an executable plan
    case worker     // read-only research / analysis sub-agent
    case coder      // produces/edits content / build sub-agent
    case critic     // verifies the goal is met / reviews output
}

/// A specific (provider, model) a role is bound to. `model` nil → the provider's default.
public struct ProviderBinding: Sendable, Equatable, Codable {
    public let providerId: String
    public let model: String?
    public init(providerId: String, model: String? = nil) {
        self.providerId = providerId; self.model = model
    }

    /// Parse a CLI spec `"<provider>"` or `"<provider>:<model>"` (e.g. "gemini", "openai:gpt-5.5").
    /// Returns nil for an empty provider.
    public static func parse(_ spec: String) -> ProviderBinding? {
        let trimmed = spec.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.firstIndex(of: ":") {
            let provider = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let model = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !provider.isEmpty else { return nil }
            return ProviderBinding(providerId: provider, model: model.isEmpty ? nil : model)
        }
        return ProviderBinding(providerId: trimmed)
    }
}

/// Maps roles → vendors, with a single `fallback` for any unbound role. By default everything routes
/// to one provider (so a single-vendor run is just `RoleBindings(default:)` — no behavior change);
/// binding a role to a different vendor is what turns the run into a heterogeneous team.
public struct RoleBindings: Sendable, Equatable {
    public let fallback: ProviderBinding
    private let bound: [AgentRole: ProviderBinding]

    public init(default fallback: ProviderBinding, _ bound: [AgentRole: ProviderBinding] = [:]) {
        self.fallback = fallback; self.bound = bound
    }

    /// The vendor for a role (its explicit binding, else the fallback).
    public func binding(for role: AgentRole) -> ProviderBinding { bound[role] ?? fallback }

    /// True if any role is bound to a different provider than the fallback — i.e. a real cross-vendor team.
    public var isHeterogeneous: Bool { bound.values.contains { $0.providerId != fallback.providerId } }

    /// A copy with `role` bound to `binding`.
    public func binding(_ role: AgentRole, to binding: ProviderBinding) -> RoleBindings {
        var next = bound; next[role] = binding
        return RoleBindings(default: fallback, next)
    }

    /// One-line summary of the team for status/logging, e.g. "planner=openai critic=gemini".
    public var summary: String {
        let roles = AgentRole.allCases.map { role -> String in
            let b = binding(for: role)
            let model = b.model.map { ":\($0)" } ?? ""
            return "\(role.rawValue)=\(b.providerId)\(model)"
        }
        return roles.joined(separator: " ")
    }
}
