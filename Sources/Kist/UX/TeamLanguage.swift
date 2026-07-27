import Foundation
import AgentCore

/// Plain-language rendering of the model/team — finding #4 (match the user's language, not system jargon)
/// and #7 (the council/team as a legible primitive). Turns `critic=gemini worker=mimo` into
/// "Gemini is reviewing · MiMo is researching".
enum TeamLanguage {

    /// Nice provider display names. Falls back to a capitalized id for unknown providers.
    static func displayName(_ providerId: String) -> String {
        switch providerId.lowercased() {
        case "gemini": return "Gemini"
        case "mimo": return "MiMo"
        case "openai": return "OpenAI"
        case "anthropic", "claude": return "Claude"
        case "deepseek": return "DeepSeek"
        case "perplexity": return "Perplexity"
        case "mistral": return "Mistral"
        case "ollama": return "Ollama"
        case "mlx": return "MLX"
        case "groq": return "Groq"
        case "xai", "grok": return "Grok"
        default:
            let s = providerId.trimmingCharacters(in: .whitespaces)
            return s.isEmpty ? providerId : s.prefix(1).uppercased() + s.dropFirst()
        }
    }

    /// What a role is doing, in plain words.
    static func activity(for role: AgentRole) -> String {
        switch role {
        case .planner: return "planning"
        case .worker:  return "researching"
        case .coder:   return "building"
        case .critic:  return "reviewing"
        }
    }

    /// True when every role is bound to the same provider (a single-model session, not a team).
    static func isHomogeneous(_ bindings: RoleBindings) -> Bool { !bindings.isHeterogeneous }

    /// "Gemini is reviewing · MiMo is researching · DeepSeek is building". Returns nil for a homogeneous
    /// session (there's no team to describe — the caller shows the single model instead).
    static func describeTeam(_ bindings: RoleBindings) -> String? {
        guard !isHomogeneous(bindings) else { return nil }
        // One clause per role, in a natural order, de-duping a provider that owns several roles.
        var seen = Set<String>()
        var clauses: [String] = []
        for role in [AgentRole.planner, .worker, .coder, .critic] {
            let id = bindings.binding(for: role).providerId
            let key = id.lowercased() + ":" + role.rawValue
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            clauses.append("\(displayName(id)) is \(activity(for: role))")
        }
        return clauses.joined(separator: " · ")
    }
}
