import Foundation

/// What a streaming completion emits. A sum type (not raw String) so the
/// contract can carry tool calls, finish reasons, and usage WITHOUT a breaking
/// change in later phases (resume needs ids/usage; orchestration needs tool
/// events). Providers that only produce text just emit `.delta`.
public enum StreamEvent: Sendable, Equatable {
    case delta(String)                                   // assistant text chunk
    case reasoning(String)                               // hidden reasoning chunk (reasoning models)
    case toolCall(id: String, name: String, argumentsJSON: String)
    case finish(reason: String?)
    case usage(promptTokens: Int, completionTokens: Int)
}

/// Measured token usage for one completion (from the provider's `.usage` event; zero if the
/// provider doesn't report it — callers may then fall back to an explicit estimate).
public struct TokenUsage: Sendable, Equatable, Codable {
    public let promptTokens: Int
    public let completionTokens: Int
    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
    }
    public static let zero = TokenUsage(promptTokens: 0, completionTokens: 0)
    public var total: Int { promptTokens + completionTokens }
    public var isZero: Bool { promptTokens == 0 && completionTokens == 0 }
}

/// A neutral tool definition handed to a provider for NATIVE tool-calling. Derived from an
/// `AgentTool` (name + description + parameters); each provider translates it into its own wire
/// schema (Anthropic `input_schema`, OpenAI `function.parameters`, Gemini `functionDeclarations`).
public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let parameters: [ToolParameter]
    public init(name: String, description: String, parameters: [ToolParameter]) {
        self.name = name; self.description = description; self.parameters = parameters
    }
}

/// The AgentCore provider contract. Deliberately STATELESS + Sendable (no
/// mutable `selectedModel`, no embedded keychain) so it crosses task/actor
/// boundaries cleanly and builds on Linux: the model id and API key are passed
/// in explicitly by the caller (resolved via KeyStore).
public protocol ChatProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var iconName: String { get }
    var requiresAPIKey: Bool { get }
    /// Keychain/env account name for this provider's key.
    var keyAccount: String { get }
    var defaultModel: String { get }
    var availableModels: [AIModel] { get }

    /// Stream a completion. `apiKey` is nil for local providers. Returns chunks
    /// of assistant text.
    func stream(
        messages: [ChatMessage],
        model: String,
        settings: ModelSettings,
        apiKey: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error>

    /// Whether this provider implements NATIVE tool-calling (sends tool defs, emits
    /// `.toolCall` events). Default false → callers use the text-protocol path instead.
    var supportsNativeTools: Bool { get }

    /// Capabilities for a specific model (native tools / vision / reasoning). Declared as a
    /// protocol REQUIREMENT — not just an extension — so the override is dynamically dispatched
    /// when called through an `any ChatProvider` existential (e.g. local MLX → text protocol).
    func capabilities(forModel model: String) -> ModelCapabilities

    /// The provider's `GET /models` URL for Layer-B model-id reconciliation, or nil if it has none in the
    /// OpenAI shape (Anthropic/Gemini, whose ids are stable). A REQUIREMENT (not just an extension default)
    /// so an override dispatches through an `any ChatProvider` existential.
    var modelsListEndpoint: String? { get }

    /// Liveness-probe URL for a LOCAL provider (mlx/ollama). A REQUIREMENT — not merely an extension default —
    /// so an override dispatches through an `any ChatProvider` existential (an extension-only member resolves
    /// statically to nil for every existential and would never probe). Only local providers return non-nil.
    var healthProbeURL: String? { get }

    /// Stream WITH native tool definitions. Default ignores `tools` and forwards to `stream`
    /// (the text-protocol path). Providers that support native tools override this to send the
    /// tool schema and emit `StreamEvent.toolCall`.
    func streamTools(
        messages: [ChatMessage],
        model: String,
        settings: ModelSettings,
        apiKey: String?,
        tools: [ToolSpec]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error>
}

public extension ChatProvider {
    var iconName: String { "cpu" }
    var supportsNativeTools: Bool { false }
    var modelsListEndpoint: String? { nil }   // default: no OpenAI-shaped /models list
    /// A URL to fast-liveness-probe a LOCAL provider (mlx/ollama) before including it in a fan-out like the
    /// wide council — a keyless local server passes `hasKey` even when its process is down, so it would
    /// otherwise eat a panel slot a working model could use. nil = remote/trusted (no probe; a real outage
    /// just degrades to a failed mind). Only local providers override this. (Added 2026-07-29.)
    var healthProbeURL: String? { nil }
    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings,
                     apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        try await stream(messages: messages, model: model, settings: settings, apiKey: apiKey)
    }
    func resolvedModel(_ requested: String?) -> String {
        if let requested, !requested.isEmpty, requested != "auto", requested != "default" { return requested }
        return defaultModel
    }
}

public extension AsyncThrowingStream where Element == StreamEvent, Failure == Error {
    /// Collapse a stream to its visible assistant text (ignores reasoning/usage).
    func collectText() async throws -> String {
        var out = ""
        for try await event in self { if case .delta(let d) = event { out += d } }
        return out
    }
}
