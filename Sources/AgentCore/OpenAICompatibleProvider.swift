import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// One configurable provider for every OpenAI-compatible chat/completions API
/// (MiMo, GLM/Z.AI, Kimi/Moonshot, DeepSeek, OpenAI, Grok). Bearer auth,
/// `choices[].delta.content` SSE streaming. Collapses 6 near-identical providers
/// into a single tested implementation.
public struct OpenAICompatibleProvider: ChatProvider {
    public let id: String
    public let name: String
    public let iconName: String
    public let requiresAPIKey: Bool
    public let keyAccount: String
    public let defaultModel: String
    public let availableModels: [AIModel]
    public let endpoint: String
    /// A LOCAL OpenAI-compatible server (e.g. MLX). Local/small models are unreliable at the
    /// native tools API, so they degrade to the universal text protocol (see `capabilities`).
    public let isLocal: Bool
    /// Whether this provider's native tool-calling API is usable for a MULTI-TURN agent loop. Default
    /// true. Set FALSE for a provider whose `tools`/`tool_calls` works for round 1 but rejects the
    /// tool-call CONVERSATION HISTORY on later rounds — e.g. Xiaomi MiMo (api 400 "Param Incorrect" on
    /// the 2nd round, GitHub XiaomiMiMo/MiMo#44, open). Such a provider degrades to the universal TEXT
    /// protocol — which exposes the SAME tools (read/search/grep/run), just serialized as text — so the
    /// agent still pulls every tool, it just doesn't die on round 2. Honest fallback, not a silent break.
    public let nativeToolsSupported: Bool

    public init(id: String, name: String, iconName: String, keyAccount: String,
                endpoint: String, defaultModel: String, availableModels: [AIModel],
                requiresAPIKey: Bool = true, isLocal: Bool = false, nativeToolsSupported: Bool = true) {
        self.id = id; self.name = name; self.iconName = iconName
        self.requiresAPIKey = requiresAPIKey; self.keyAccount = keyAccount
        self.endpoint = endpoint; self.defaultModel = defaultModel; self.availableModels = availableModels
        self.isLocal = isLocal; self.nativeToolsSupported = nativeToolsSupported
    }

    /// Native tool-calling for CLOUD OpenAI-compatible providers WHOSE multi-turn tools API works; LOCAL
    /// servers (MLX), any model flagged `isLocal`, AND providers with broken multi-turn tools (MiMo)
    /// degrade to the text protocol — honest "uses all AIs", not a silent failure.
    public func capabilities(forModel model: String) -> ModelCapabilities {
        let meta = availableModels.first { $0.id == model || $0.name == model }
        let modelIsLocal = isLocal || (meta?.isLocal ?? false)
        return ModelCapabilities(nativeTools: !modelIsLocal && nativeToolsSupported,
                                 vision: meta?.isVision ?? false,
                                 reasoning: Self.modelLooksLikeReasoning(model),
                                 contextWindowTokens: meta?.contextWindowTokens)
    }

    /// Heuristic: does this model id belong to a reasoning family that emits hidden `reasoning_content`
    /// FIRST and only then the visible answer? Such a model truncates to an EMPTY answer if `max_tokens`
    /// is small (the reasoning eats the budget) — the recurring MiMo failure. Detected by family so even a
    /// new/unlisted reasoning id gets budget headroom. Bias to flag: a bigger budget never hurts a
    /// non-reasoning model (it stops at its natural finish), but too small a budget breaks a reasoning one.
    static func modelLooksLikeReasoning(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") || m.hasPrefix("gpt-5") { return true }
        return ["reasoner", "reasoning", "thinking", "qwq", "deepseek-r", "mimo", "r1-", "-r1"].contains { m.contains($0) }
    }

    /// The floor a reasoning model needs so reasoning + the visible answer both fit. A caller asking for a
    /// short answer (e.g. 600 tokens) from a reasoning model would otherwise get nothing.
    static let reasoningTokenFloor = 8000

    /// The budget actually sent: a reasoning model is floored to `reasoningTokenFloor` (unless the caller
    /// explicitly disabled thinking for a tight loop, in which case its small budget is respected).
    func effectiveMaxTokens(model: String, settings: ModelSettings) -> Int {
        guard !settings.disableThinking, capabilities(forModel: model).reasoning else { return settings.maxTokens }
        return max(settings.maxTokens, Self.reasoningTokenFloor)
    }

    /// Build the request body — pure/testable.
    /// A user turn's `content`: a plain string when there are no images, else an OpenAI vision parts
    /// array (text + `image_url` data URLs). Images only — video/audio is routed to Gemini upstream.
    static func userContent(for m: ChatMessage) -> Any {
        let images = m.allAttachments.filter { $0.kind == .image && $0.inlineData != nil }
        guard !images.isEmpty else { return m.content }
        var parts: [[String: Any]] = []
        if !m.content.isEmpty { parts.append(["type": "text", "text": m.content]) }
        for img in images {
            parts.append(["type": "image_url",
                          "image_url": ["url": "data:\(img.mimeType);base64,\(img.inlineData!.base64EncodedString())"]])
        }
        return parts
    }

    static func textOnlyUserContent(for m: ChatMessage) -> String {
        let attachments = m.allAttachments
        guard !attachments.isEmpty else { return m.content }
        let mediaSummary = attachmentSummary(attachments)
        guard !m.content.isEmpty else { return mediaSummary }
        return m.content + "\n\n" + mediaSummary
    }

    private static func requestUserContent(for m: ChatMessage, includeImages: Bool) -> Any {
        includeImages ? userContent(for: m) : textOnlyUserContent(for: m)
    }

    private static func attachmentSummary(_ attachments: [MediaAttachment]) -> String {
        let counts = Dictionary(grouping: attachments, by: \.kind).mapValues(\.count)
        let rendered = MediaAttachment.Kind.allCases.compactMap { kind -> String? in
            guard let count = counts[kind], count > 0 else { return nil }
            let noun = count == 1 ? "\(kind.rawValue) attachment" : "\(kind.rawValue) attachments"
            return "\(count) \(noun)"
        }.joined(separator: ", ")
        return "[\(rendered) omitted for this text-only model]"
    }

    static func tokenBudgetKey(providerId: String, model: String) -> String {
        guard providerId == "openai" else { return "max_tokens" }
        let m = model.lowercased()
        if m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            return "max_completion_tokens"
        }
        return "max_tokens"
    }

    static func supportsSamplingControls(providerId: String, model: String) -> Bool {
        guard providerId == "openai" else { return true }
        let m = model.lowercased()
        return !(m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4"))
    }


    public func makeBody(messages: [ChatMessage], model: String, settings: ModelSettings, stream: Bool) -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        if !settings.systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": settings.systemPrompt])
        }
        let includeImages = capabilities(forModel: model).vision
        for m in messages where m.role != .system {
            if m.role == .assistant {
                apiMessages.append(["role": "assistant", "content": m.content])
            } else {
                apiMessages.append(["role": "user", "content": Self.requestUserContent(for: m, includeImages: includeImages)])
            }
        }
        var body: [String: Any] = [
            "model": model, "messages": apiMessages, "stream": stream
        ]
        if Self.supportsSamplingControls(providerId: id, model: model) {
            body["temperature"] = settings.temperature
            body["top_p"] = settings.topP
        }
        // Reasoning-aware budget: a reasoning model is floored so its hidden reasoning can't starve the
        // visible answer to empty (the recurring MiMo failure). Non-reasoning models are unchanged.
        body[Self.tokenBudgetKey(providerId: id, model: model)] = effectiveMaxTokens(model: model, settings: settings)
        // Ask for token usage in the stream (OTel cost/observability). Standard OpenAI option,
        // ignored by servers that don't support it.
        if stream { body["stream_options"] = ["include_usage": true] }
        if let seed = settings.seed { body["seed"] = seed }
        if shouldDisableThinking(settings: settings) { body["thinking"] = ["type": "disabled"] }
        // Forward caller-supplied stop sequences (e.g. a local model's turn-end tokens) so the server
        // halts at the real turn boundary. OpenAI caps `stop` at 4 — trim defensively.
        if !settings.stopSequences.isEmpty { body["stop"] = Array(settings.stopSequences.prefix(4)) }
        return body
    }

    /// Parse one SSE `data:` JSON line into stream events (delta/finish/usage).
    public static func events(fromSSE jsonString: String) -> [StreamEvent] {
        guard jsonString != "[DONE]",
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [StreamEvent] = []
        if let choices = json["choices"] as? [[String: Any]], let c0 = choices.first {
            if let delta = c0["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty { out.append(.delta(content)) }
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { out.append(.reasoning(reasoning)) }
            }
            if let fr = c0["finish_reason"] as? String { out.append(.finish(reason: fr)) }
        }
        if let usage = json["usage"] as? [String: Any] {
            out.append(.usage(promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                              completionTokens: usage["completion_tokens"] as? Int ?? 0))
        }
        return out
    }

    public var supportsNativeTools: Bool { nativeToolsSupported }

    /// Layer B: the `/models` URL derived from this provider's chat endpoint.
    public var modelsListEndpoint: String? { ProviderDoctor.modelsEndpoint(for: self) }

    /// JSON Schema (object) for a tool's parameters, from the neutral `[ToolParameter]`.
    public static func jsonSchema(_ params: [ToolParameter]) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in params {
            var schema: [String: Any] = ["type": p.type, "description": p.description]
            if p.type == "array" { schema["items"] = ["type": "string"] }   // array schemas need items
            props[p.name] = schema
            if p.required { required.append(p.name) }
        }
        return ["type": "object", "properties": props, "required": required]
    }

    /// Request body for the NATIVE path: encodes assistant `tool_calls` + `.tool` results and a
    /// `tools` array. (Kept separate from `makeBody` so the text-path body/tests are untouched.)
    public func makeBodyTools(messages: [ChatMessage], model: String, settings: ModelSettings, tools: [ToolSpec], stream: Bool) -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        if !settings.systemPrompt.isEmpty { apiMessages.append(["role": "system", "content": settings.systemPrompt]) }
        let includeImages = capabilities(forModel: model).vision
        for m in messages where m.role != .system {
            switch m.role {
            case .assistant:
                var msg: [String: Any] = ["role": "assistant", "content": m.content]
                if let calls = m.toolCalls, !calls.isEmpty {
                    msg["tool_calls"] = calls.map { ["id": $0.id, "type": "function",
                                                     "function": ["name": $0.name, "arguments": $0.argumentsJSON]] }
                }
                apiMessages.append(msg)
            case .tool:
                apiMessages.append(["role": "tool", "tool_call_id": m.toolCallId ?? "", "content": m.content])
            default:
                apiMessages.append(["role": "user", "content": Self.requestUserContent(for: m, includeImages: includeImages)])
            }
        }
        var body: [String: Any] = [
            "model": model, "messages": apiMessages, "stream": stream,
        ]
        if Self.supportsSamplingControls(providerId: id, model: model) {
            body["temperature"] = settings.temperature
            body["top_p"] = settings.topP
        }
        // Reasoning-aware budget: a reasoning model is floored so its hidden reasoning can't starve the
        // visible answer to empty (the recurring MiMo failure). Non-reasoning models are unchanged.
        body[Self.tokenBudgetKey(providerId: id, model: model)] = effectiveMaxTokens(model: model, settings: settings)
        if stream { body["stream_options"] = ["include_usage": true] }
        if let seed = settings.seed { body["seed"] = seed }
        if shouldDisableThinking(settings: settings) { body["thinking"] = ["type": "disabled"] }
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function",
                                         "function": ["name": $0.name, "description": $0.description,
                                                      "parameters": Self.jsonSchema($0.parameters)]] }
        }
        if !settings.stopSequences.isEmpty { body["stop"] = Array(settings.stopSequences.prefix(4)) }
        return body
    }

    private func shouldDisableThinking(settings: ModelSettings) -> Bool {
        settings.disableThinking && id == "mimo"
    }

    public func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        if requiresAPIKey { guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: id) } }
        guard let url = URL(string: endpoint) else { throw AIProviderError.configuration("bad endpoint \(endpoint)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: makeBodyTools(messages: messages, model: model, settings: settings, tools: tools, stream: true))

        return AsyncThrowingStream { continuation in
            let task = Task {
                var accumulator = OpenAIToolCallAccumulator()
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        if http.statusCode == 401 { throw AIProviderError.invalidAPIKey }
                        if http.statusCode == 429 { throw AIProviderError.rateLimited }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw AIProviderError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        if payload == "[DONE]" { break }
                        for event in accumulator.consume(payload) { continuation.yield(event) }
                    }
                    // Emit the assembled tool calls (after the stream completes — buffer-then-parse).
                    for event in accumulator.finishToolCalls() { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch let e as AIProviderError { continuation.finish(throwing: e) }
                catch { continuation.finish(throwing: AIProviderError.transport(error.localizedDescription)) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        if requiresAPIKey {
            guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: id) }
        }
        guard let url = URL(string: endpoint) else { throw AIProviderError.configuration("bad endpoint \(endpoint)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local providers (MLX) need no auth header.
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: makeBody(messages: messages, model: model, settings: settings, stream: true))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        if http.statusCode == 401 { throw AIProviderError.invalidAPIKey }
                        if http.statusCode == 429 { throw AIProviderError.rateLimited }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw AIProviderError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        for event in Self.events(fromSSE: payload) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let e as AIProviderError {
                    continuation.finish(throwing: e)
                } catch {
                    // Normalize raw Foundation/URL errors to the shared type.
                    continuation.finish(throwing: AIProviderError.transport(error.localizedDescription))
                }
            }
            // Cancel the in-flight HTTP stream when the consumer stops.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Deterministic accumulator for OpenAI-compatible streaming tool-call fragments. The wire
/// sends `id`/`name` once and streams `function.arguments` over multiple SSE chunks, keyed by
/// `tool_calls[].index`; the loop needs one complete `StreamEvent.toolCall` per assembled call.
struct OpenAIToolCallAccumulator {
    private var fragments: [Int: (id: String, name: String, args: String)] = [:]

    mutating func consume(_ jsonString: String) -> [StreamEvent] {
        guard jsonString != "[DONE]",
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [StreamEvent] = []
        if let choices = json["choices"] as? [[String: Any]], let c0 = choices.first {
            if let delta = c0["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty { out.append(.delta(content)) }
                if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { out.append(.reasoning(reasoning)) }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for toolCall in toolCalls {
                        let index = toolCall["index"] as? Int ?? 0
                        var entry = fragments[index] ?? ("", "", "")
                        if let id = toolCall["id"] as? String, !id.isEmpty { entry.id = id }
                        if let function = toolCall["function"] as? [String: Any] {
                            // Names arrive whole in the first fragment; arguments stream.
                            if let name = function["name"] as? String, !name.isEmpty, entry.name.isEmpty {
                                entry.name = name
                            }
                            if let args = function["arguments"] as? String { entry.args += args }
                        }
                        fragments[index] = entry
                    }
                }
            }
            if let finish = c0["finish_reason"] as? String { out.append(.finish(reason: finish)) }
        }
        if let usage = json["usage"] as? [String: Any] {
            out.append(.usage(promptTokens: usage["prompt_tokens"] as? Int ?? 0,
                              completionTokens: usage["completion_tokens"] as? Int ?? 0))
        }
        return out
    }

    mutating func finishToolCalls() -> [StreamEvent] {
        defer { fragments.removeAll() }
        return fragments.sorted { $0.key < $1.key }.map { _, entry in
            let callId = entry.id.isEmpty ? "call_\(UUID().uuidString.prefix(8))" : entry.id
            return .toolCall(id: callId, name: entry.name, argumentsJSON: entry.args.isEmpty ? "{}" : entry.args)
        }
    }
}
