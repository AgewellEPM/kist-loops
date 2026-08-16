import Foundation

// Core value types for AgentCore. All Sendable + Codable + Foundation-only so
// they work identically on macOS and Linux, and cross actor/task boundaries.

public struct AIModel: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let displayName: String
    public var isVision: Bool
    public var isLocal: Bool
    /// Advertised context window, when known. Nil means "unknown/default".
    public var contextWindowTokens: Int?

    public init(id: String, name: String? = nil, displayName: String? = nil,
                isVision: Bool = false, isLocal: Bool = false, contextWindowTokens: Int? = nil) {
        self.id = id
        self.name = name ?? id
        self.displayName = displayName ?? (name ?? id)
        self.isVision = isVision
        self.isLocal = isLocal
        self.contextWindowTokens = contextWindowTokens
    }
}

/// A native tool call the model made (assistant turn) — carried so it can be encoded back into
/// the provider's wire format on the next request and matched to its result.
public struct ToolCallRef: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public struct ChatMessage: Sendable, Codable, Equatable {
    /// `.tool` carries a tool RESULT (paired to a call via `toolCallId`) for the native path.
    public enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    public let role: Role
    public let content: String
    /// Optional inline image (base64-encoded by providers that support vision).
    /// LEGACY single-image path — kept working; new code attaches via `attachments` instead.
    public let imageData: Data?
    public let imageMimeType: String?
    /// Multimodal attachments (image/video/audio/pdf) carried with this turn. The drag-a-file path.
    public let attachments: [MediaAttachment]
    /// Native tool calls the assistant made this turn (native tool-calling path only).
    public let toolCalls: [ToolCallRef]?
    /// For a `.tool` message: the id of the call this result answers.
    public let toolCallId: String?
    /// Provider-issued opaque reasoning continuation state. This never contains raw reasoning text.
    public let providerReasoningHandles: [OpaqueProviderReasoningHandle]

    public init(role: Role, content: String, imageData: Data? = nil, imageMimeType: String? = nil,
                attachments: [MediaAttachment] = [],
                toolCalls: [ToolCallRef]? = nil, toolCallId: String? = nil,
                providerReasoningHandles: [OpaqueProviderReasoningHandle] = []) {
        self.role = role
        self.content = content
        self.imageData = imageData
        self.imageMimeType = imageMimeType
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.providerReasoningHandles = Array(providerReasoningHandles.suffix(32))
    }

    // Custom Codable so persisted checkpoints written BEFORE `attachments` existed still decode
    // (the key is simply absent → default to []). Everything else round-trips as synthesized would.
    private enum CodingKeys: String, CodingKey {
        case role, content, imageData, imageMimeType, attachments, toolCalls, toolCallId,
             providerReasoningHandles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        imageMimeType = try c.decodeIfPresent(String.self, forKey: .imageMimeType)
        attachments = try c.decodeIfPresent([MediaAttachment].self, forKey: .attachments) ?? []
        toolCalls = try c.decodeIfPresent([ToolCallRef].self, forKey: .toolCalls)
        toolCallId = try c.decodeIfPresent(String.self, forKey: .toolCallId)
        providerReasoningHandles = Array((try c.decodeIfPresent(
            [OpaqueProviderReasoningHandle].self, forKey: .providerReasoningHandles) ?? []).suffix(32))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        try c.encodeIfPresent(imageData, forKey: .imageData)
        try c.encodeIfPresent(imageMimeType, forKey: .imageMimeType)
        if !attachments.isEmpty { try c.encode(attachments, forKey: .attachments) }
        try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
        try c.encodeIfPresent(toolCallId, forKey: .toolCallId)
        if !providerReasoningHandles.isEmpty {
            try c.encode(providerReasoningHandles, forKey: .providerReasoningHandles)
        }
    }

    public var hasImage: Bool { imageData != nil || attachments.contains { $0.kind == .image } }
    /// All vision/media payloads on this turn, legacy image folded in as an attachment.
    public var allAttachments: [MediaAttachment] {
        var all = attachments
        if let imageData, !attachments.contains(where: { $0.inlineData == imageData }) {
            all.insert(MediaAttachment(kind: .image, mimeType: imageMimeType ?? "image/png",
                                       payload: .inline(imageData)), at: 0)
        }
        return all
    }

    /// A `.tool` result message paired to the call it answers.
    public static func toolResult(callId: String, content: String) -> ChatMessage {
        ChatMessage(role: .tool, content: content, toolCallId: callId)
    }
}

public struct ModelSettings: Sendable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    public var systemPrompt: String
    public var seed: Int?
    /// Provider-specific hint for reasoning models in tight agentic tool loops.
    public var disableThinking: Bool
    /// Enable Gemini's SERVER-SIDE built-in tools (Google Search grounding, URL context, code
    /// execution) alongside our function declarations. Default ON — they only fire when the model
    /// decides it needs them. Honored only by providers that support them (Gemini).
    public var geminiBuiltins: Bool
    /// Ask the provider to constrain the response to JSON (Gemini: responseMimeType application/json).
    /// Opt-in — used by structured sub-calls; must stay OFF for normal prose / native tool loops.
    public var jsonOutput: Bool
    /// Force/forbid function calls (Gemini toolConfig.functionCallingConfig.mode). Default .auto.
    public var toolChoice: ToolChoice
    /// A raw JSON Schema string to constrain output shape (Gemini: responseSchema). When set, also
    /// forces JSON output. Opt-in; for structured sub-calls only.
    public var jsonSchema: String?
    /// Top-K sampling (nil = provider default). Honored only where sampling controls apply.
    public var topK: Int?
    /// Stop sequences — generation halts when any is produced.
    public var stopSequences: [String]
    /// Frequency / presence penalties (nil = provider default).
    public var frequencyPenalty: Double?
    public var presencePenalty: Double?
    /// Positive thinking-token budget (Gemini 2.5). nil = provider default; ignored if disableThinking.
    public var thinkingBudget: Int?
    /// Provider-neutral reasoning request. Nil preserves legacy direct-provider behavior.
    public var reasoningEffort: ProviderReasoningEffort?
    /// Native control selected by `ProviderEffortMapper`; adapters encode this instead of guessing
    /// from the legacy Boolean when an explicit neutral request is present.
    public var providerReasoningControl: ProviderReasoningNativeControl?

    public init(temperature: Double = 0.3, topP: Double = 0.9, maxTokens: Int = 4096,
                systemPrompt: String = "", seed: Int? = nil, disableThinking: Bool = false,
                geminiBuiltins: Bool = true, jsonOutput: Bool = false,
                toolChoice: ToolChoice = .auto, jsonSchema: String? = nil,
                topK: Int? = nil, stopSequences: [String] = [], frequencyPenalty: Double? = nil,
                presencePenalty: Double? = nil, thinkingBudget: Int? = nil,
                reasoningEffort: ProviderReasoningEffort? = nil,
                providerReasoningControl: ProviderReasoningNativeControl? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
        self.seed = seed
        self.disableThinking = disableThinking
        self.geminiBuiltins = geminiBuiltins
        self.jsonOutput = jsonOutput
        self.toolChoice = toolChoice
        self.jsonSchema = jsonSchema
        self.topK = topK
        self.stopSequences = stopSequences
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.thinkingBudget = thinkingBudget
        self.reasoningEffort = reasoningEffort
        self.providerReasoningControl = providerReasoningControl
    }

    /// Parse `jsonSchema` (a raw JSON-schema string) into an object, or nil if absent OR unparseable.
    /// One place for the "malformed schema → nil → caller falls back to plain JSON" policy, so the OpenAI
    /// and Gemini structured-output paths can't drift on how they handle a bad schema string.
    public func decodedJSONSchema() -> [String: Any]? {
        guard let s = jsonSchema, let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}

/// How the model is allowed to call our functions. `auto` = its choice (default); `any` = must call
/// one; `none` = must not call any (answer in text).
public enum ToolChoice: String, Sendable, Equatable { case auto, any, none }

public enum ProviderStreamTimeoutPhase: String, Sendable, Equatable {
    case firstEvent
    case idle
}

public enum AIProviderError: Error, Sendable, Equatable, LocalizedError {
    case missingAPIKey(provider: String)
    case invalidAPIKey
    case rateLimited
    case invalidResponse(String)
    case http(status: Int, body: String)
    case transport(String)
    case configuration(String)
    case streamTimedOut(provider: String, model: String, phase: ProviderStreamTimeoutPhase)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .transport: return true
        case .http(let status, _): return status == 429 || (500...599).contains(status)
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for provider '\(Self.boundedContext(provider, limit: 96))'."
        case .invalidAPIKey:
            return "The provider rejected the configured API key."
        case .rateLimited:
            return "The provider rate limit was exceeded."
        case .invalidResponse(let detail):
            return "The provider returned an invalid response: \(Self.boundedContext(detail))"
        case .http(let status, let body):
            let bodyContext = body.isEmpty ? "no response body" : "response body omitted"
            return "The provider HTTP request failed with status \(status) (\(bodyContext))."
        case .transport(let detail):
            return "Provider transport error: \(Self.boundedContext(detail))"
        case .configuration(let detail):
            return "Provider configuration error: \(Self.boundedContext(detail))"
        case .streamTimedOut(let provider, let model, let phase):
            return "Provider stream timed out (provider: \(Self.boundedContext(provider, limit: 96)), "
                + "model: \(Self.boundedContext(model, limit: 96)), phase: \(phase.rawValue))."
        }
    }

    /// Bound before running repository redactors so a server-controlled diagnostic cannot turn
    /// error rendering into unbounded regex work. The second bound covers redactor expansion.
    private static func boundedContext(_ raw: String, limit: Int = 320) -> String {
        let sample = raw.prefix(limit + 1)
        let inputWasTruncated = sample.count > limit
        let boundedInput = String(sample.prefix(limit))
        let redacted = SecretMasker.mask(SecretScanner.redactSecrets(in: boundedInput))
        let singleLine = redacted.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let output = singleLine.prefix(limit + 1)
        let outputWasTruncated = output.count > limit
        let context = String(output.prefix(limit))
        guard !context.isEmpty else { return "no additional details" }
        return context + (inputWasTruncated || outputWasTruncated ? " [truncated]" : "")
    }
}
