import Foundation

/// A one-tap onboarding preset for a universal gateway. Because HuggingFace's router,
/// OpenRouter, and a LiteLLM proxy all expose an OpenAI-compatible `/chat/completions`
/// surface, picking one of these unlocks thousands of models THROUGH THE ONBOARDING WE
/// ALREADY SHIP — no new wire-shape code. The user supplies only a key + a model id.
public struct GatewayPreset: Sendable, Equatable {
    public let key: String            // stable id, e.g. "huggingface"
    public let displayName: String
    /// Fixed chat-completions endpoint, or nil when the user must supply a base URL (self-hosted).
    public let endpoint: String?
    /// True when there is no fixed endpoint and we must prompt for a base URL (e.g. LiteLLM proxy).
    public let requiresBaseURL: Bool
    /// What a valid model id looks like for this gateway (shown at the model prompt).
    public let modelHint: String
    /// Human label for the credential prompt (never the secret itself).
    public let keyLabel: String
    /// One-line description shown in the gateway menu.
    public let docNote: String

    public init(key: String, displayName: String, endpoint: String?, requiresBaseURL: Bool,
                modelHint: String, keyLabel: String, docNote: String) {
        self.key = key; self.displayName = displayName; self.endpoint = endpoint
        self.requiresBaseURL = requiresBaseURL; self.modelHint = modelHint
        self.keyLabel = keyLabel; self.docNote = docNote
    }
}

public enum GatewayPresets {
    public static let all: [GatewayPreset] = [
        GatewayPreset(
            key: "huggingface",
            displayName: "HuggingFace (router)",
            endpoint: "https://router.huggingface.co/v1/chat/completions",
            requiresBaseURL: false,
            modelHint: "owner/model[:provider], e.g. deepseek-ai/DeepSeek-V3-0324 or Qwen/Qwen2.5-72B-Instruct:fastest",
            keyLabel: "HuggingFace access token (hf_…)",
            docNote: "20+ backends (Groq, Cerebras, Together, Fireworks, …), 100k+ models"),
        GatewayPreset(
            key: "openrouter",
            displayName: "OpenRouter",
            endpoint: "https://openrouter.ai/api/v1/chat/completions",
            requiresBaseURL: false,
            modelHint: "vendor/model, e.g. anthropic/claude-3.7-sonnet or meta-llama/llama-3.3-70b-instruct",
            keyLabel: "OpenRouter API key (sk-or-…)",
            docNote: "hundreds of models, one credit balance"),
        GatewayPreset(
            key: "litellm",
            displayName: "LiteLLM proxy (self-hosted)",
            endpoint: nil,
            requiresBaseURL: true,
            modelHint: "the model name as configured in your proxy, e.g. gpt-4o or bedrock/claude-3",
            keyLabel: "your LiteLLM proxy key",
            docNote: "your own gateway fronting 140+ providers"),
    ]

    public static func preset(key: String) -> GatewayPreset? {
        all.first { $0.key == key }
    }
}
