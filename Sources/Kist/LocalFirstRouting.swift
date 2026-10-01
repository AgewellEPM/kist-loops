import Foundation
import AgentCore

/// Opt-in routing policy. It is deterministic and spends no model call to choose a model.
/// A cloud escalation lasts one turn; the next ordinary request starts locally again.
extension AutoModelRouter {
    func localFirstDecision(_ text: String, hasMedia: Bool,
                            local: ProviderBinding,
                            avoid: (String) -> Bool = { _ in false }) -> Decision {
        let localCandidate = candidates.first { $0.binding == local }
        let needsVision = hasMedia && localCandidate?.vision != true
        let difficult = Self.looksLikeReasoning(text) || text.utf8.count > 32_000
        if needsVision || difficult || avoid(local.providerId),
           let cloud = cloudFallback(needsVision: hasMedia, avoid: avoid) {
            let reason = avoid(local.providerId) ? "local model unavailable"
                : (needsVision ? "vision capability required" : "difficult task")
            return Decision(binding: cloud, tier: hasMedia ? .vision : .reasoning,
                            reason: "local-first · \(reason) → cloud fallback")
        }
        return Decision(binding: local, tier: hasMedia ? .vision : .fast,
                        reason: "local-first · configured local model")
    }

    func cloudFallback(needsVision: Bool = false,
                       avoid: (String) -> Bool = { _ in false }) -> ProviderBinding? {
        // Candidates have already passed the registry's provider allowlist and readiness gate.
        // Keep a declared order, rather than interpreting maximum context as model intelligence.
        let preference = ["deepseek", "codex-cli", "openai", "claude-cli", "anthropic",
                          "gemini", "mimo", "moonshot", "grok", "qwen"]
        for id in preference where !avoid(id) {
            if let candidate = candidates.first(where: {
                $0.binding.providerId == id && (!needsVision || $0.vision)
            }) { return candidate.binding }
        }
        return nil
    }
}

extension KistConfig {
    var localFirstBinding: ProviderBinding? {
        guard localFirst, autoRouting == true, provider == "ollama",
              permitsProvider("ollama"), let model, !model.isEmpty else { return nil }
        return ProviderBinding(providerId: "ollama", model: model)
    }
}
