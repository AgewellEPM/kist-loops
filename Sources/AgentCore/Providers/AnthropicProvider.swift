import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// Anthropic Messages API provider for AgentCore. Mirrors `OpenAICompatibleProvider`'s
/// shape (pure `makeBody`, static `events(fromSSE:)`, `URLSession.bytes` streaming,
/// normalized errors) but speaks Anthropic's wire format: `x-api-key` + `anthropic-version`
/// auth, a top-level `system` field, and `content_block_delta` / `message_delta` SSE events.
public struct AnthropicProvider: ChatProvider {
    public let id = "anthropic"
    public let name = "Claude"
    public let iconName = "brain.head.profile"
    public let requiresAPIKey = true
    public let keyAccount = "anthropic_api_key"
    public let defaultModel = "claude-fable-5"
    public let availableModels: [AIModel] = [
        // Vision IS wired: `userContent(for:)` encodes Anthropic base64 image blocks (pinned by
        // ProviderVisionEncodingTests). All these Claude models are vision-capable, so advertise it —
        // otherwise capabilities.vision stays false and the REPL never AUTO-ROUTES an image to Claude
        // even though a direct call would encode it. (Video/audio still route to Gemini upstream.)
        AIModel(id: "claude-fable-5", displayName: "Claude Fable 5", isVision: true),
        AIModel(id: "claude-opus-4-8-20251215", displayName: "Claude Opus 4.8", isVision: true),
        AIModel(id: "claude-sonnet-4-5-20250514", displayName: "Claude 4.5 Sonnet", isVision: true),
        AIModel(id: "claude-3-5-haiku-20241022", displayName: "Claude 3.5 Haiku", isVision: true)
    ]

    /// Messages endpoint — override with `ANTHROPIC_API_URL` (proxy/staging); default is the public API.
    private let endpoint = ProcessInfo.processInfo.environment["ANTHROPIC_API_URL"]
        ?? "https://api.anthropic.com/v1/messages"
    /// Anthropic API version pin (required header).
    private let anthropicVersion = "2023-06-01"

    public init() {}

    /// A user turn's `content`: a plain string when there are no images, else Anthropic image content
    /// blocks (base64) + the text. Claude takes images only — video/audio is routed to Gemini upstream.
    static func userContent(for m: ChatMessage) -> Any {
        let images = m.allAttachments.filter { $0.kind == .image && $0.inlineData != nil }
        guard !images.isEmpty else { return m.content }
        var blocks: [[String: Any]] = []
        if !m.content.isEmpty { blocks.append(["type": "text", "text": m.content]) }
        for img in images {
            blocks.append(["type": "image",
                           "source": ["type": "base64", "media_type": img.mimeType,
                                      "data": img.inlineData!.base64EncodedString()]])
        }
        return blocks
    }

    /// Build the request body — pure/testable. Filters out `.system` role messages and
    /// hoists the system prompt to the top-level `system` field (Anthropic's contract).
    public func makeBody(messages: [ChatMessage], model: String, settings: ModelSettings, stream: Bool) -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        for m in messages where m.role != .system {
            if m.role == .assistant {
                apiMessages.append(["role": "assistant", "content": m.content])
            } else {
                apiMessages.append(["role": "user", "content": Self.userContent(for: m)])
            }
        }
        // NOTE (extended-thinking gap): this builder does not yet map `settings.disableThinking` to
        // Anthropic's native `thinking: {type:enabled, budget_tokens}` block, and the stream parser does
        // not emit thinking deltas — so `--think` is currently a no-op on the Anthropic provider (it IS
        // honored by the OpenAI-compatible providers via `disableThinking`). Wiring Anthropic native
        // extended thinking is a tracked follow-up (see docs/AGENT_RUNTIME_CROSS_COMPARE.md gap #1).
        var body: [String: Any] = [
            "model": model,
            "max_tokens": settings.maxTokens,
            "messages": apiMessages,
            "stream": stream,
            "temperature": settings.temperature,
            "top_p": settings.topP
        ]
        if !settings.systemPrompt.isEmpty { body["system"] = settings.systemPrompt }
        return body
    }

    /// Parse one SSE `data:` JSON line into stream events. Anthropic emits typed events:
    /// `content_block_delta` (delta.text) → .delta; `message_delta` (usage.output_tokens) → .usage;
    /// `message_stop` → .finish.
    public static func events(fromSSE jsonString: String) -> [StreamEvent] {
        guard jsonString != "[DONE]",
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [StreamEvent] = []
        switch json["type"] as? String {
        case "message_start":
            // Prompt (input) tokens arrive here, not in message_delta.
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let inTokens = usage["input_tokens"] as? Int {
                out.append(.usage(promptTokens: inTokens, completionTokens: 0))
            }
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String, !text.isEmpty {
                out.append(.delta(text))
            }
        case "message_delta":
            if let usage = json["usage"] as? [String: Any],
               let outTokens = usage["output_tokens"] as? Int {
                out.append(.usage(promptTokens: usage["input_tokens"] as? Int ?? 0,
                                  completionTokens: outTokens))
            }
        case "message_stop":
            out.append(.finish(reason: nil))
        default:
            break
        }
        return out
    }

    // MARK: - Native tool-calling (Messages API tools)

    public var supportsNativeTools: Bool { true }

    /// Anthropic `input_schema` (JSON Schema object) for a tool's parameters, from the
    /// neutral `[ToolParameter]`. Same shape as OpenAI's `jsonSchema` but lives under the
    /// tool's `input_schema` key rather than `function.parameters`.
    public static func inputSchema(_ params: [ToolParameter]) -> [String: Any] {
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

    /// Parse a tool call's `argumentsJSON` string back into the object Anthropic expects in a
    /// `tool_use` block's `input` field. Non-object / unparseable input degrades to `{}` rather
    /// than dropping the block (the model still sees the call, just with empty args).
    static func parseToolInput(_ argumentsJSON: String) -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Request body for the NATIVE path — pure/testable. Mirrors `makeBody` (system hoisted to
    /// top level) but every assistant tool call becomes a `tool_use` content block and every
    /// `.tool` result message COLLAPSES to a `user` message carrying a `tool_result` block
    /// (Anthropic has no tool role). Adds a top-level `tools` array of `{name, description,
    /// input_schema}`. Kept separate from `makeBody` so the text-path body/tests are untouched.
    public func makeBodyTools(messages: [ChatMessage], model: String, settings: ModelSettings, tools: [ToolSpec], stream: Bool) -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        for m in messages where m.role != .system {
            switch m.role {
            case .assistant:
                if let calls = m.toolCalls, !calls.isEmpty {
                    var blocks: [[String: Any]] = []
                    if !m.content.isEmpty { blocks.append(["type": "text", "text": m.content]) }
                    for c in calls {
                        blocks.append(["type": "tool_use", "id": c.id, "name": c.name,
                                       "input": Self.parseToolInput(c.argumentsJSON)])
                    }
                    apiMessages.append(["role": "assistant", "content": blocks])
                } else {
                    apiMessages.append(["role": "assistant", "content": m.content])
                }
            case .tool:
                // No tool role in Anthropic — a result rides in a user message's content block.
                apiMessages.append(["role": "user",
                                    "content": [["type": "tool_result",
                                                 "tool_use_id": m.toolCallId ?? "",
                                                 "content": m.content]]])
            default:
                apiMessages.append(["role": "user", "content": Self.userContent(for: m)])
            }
        }
        // NOTE (extended-thinking gap): this builder does not yet map `settings.disableThinking` to
        // Anthropic's native `thinking: {type:enabled, budget_tokens}` block, and the stream parser does
        // not emit thinking deltas — so `--think` is currently a no-op on the Anthropic provider (it IS
        // honored by the OpenAI-compatible providers via `disableThinking`). Wiring Anthropic native
        // extended thinking is a tracked follow-up (see docs/AGENT_RUNTIME_CROSS_COMPARE.md gap #1).
        var body: [String: Any] = [
            "model": model,
            "max_tokens": settings.maxTokens,
            "messages": apiMessages,
            "stream": stream,
            "temperature": settings.temperature,
            "top_p": settings.topP
        ]
        if !settings.systemPrompt.isEmpty { body["system"] = settings.systemPrompt }
        if !tools.isEmpty {
            body["tools"] = tools.map { ["name": $0.name, "description": $0.description,
                                         "input_schema": Self.inputSchema($0.parameters)] }
        }
        return body
    }

    /// Stateful SSE accumulator for the NATIVE tools path — pure (no network), so the streaming
    /// state machine is unit-testable. Anthropic streams a tool call's JSON `input` across many
    /// `input_json_delta` fragments keyed by content-block INDEX; we buffer `partial_json` per
    /// block and only finalize `.toolCall` at `content_block_stop`. Text blocks stream via
    /// `text_delta` → `.delta`. Usage/finish mirror the text path.
    public struct ToolStreamAccumulator {
        private struct Block { var type: String; var id: String; var name: String; var partialJSON: String }
        private var blocks: [Int: Block] = [:]

        public init() {}

        /// Feed one decoded SSE `data:` JSON object; returns the stream events it produced (text
        /// deltas immediately; a `.toolCall` when its block closes).
        public mutating func consume(_ json: [String: Any]) -> [StreamEvent] {
            var out: [StreamEvent] = []
            switch json["type"] as? String {
            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any],
                   let inTokens = usage["input_tokens"] as? Int {
                    out.append(.usage(promptTokens: inTokens, completionTokens: 0))
                }
            case "content_block_start":
                let idx = json["index"] as? Int ?? 0
                if let cb = json["content_block"] as? [String: Any] {
                    blocks[idx] = Block(type: cb["type"] as? String ?? "",
                                        id: cb["id"] as? String ?? "",
                                        name: cb["name"] as? String ?? "",
                                        partialJSON: "")
                }
            case "content_block_delta":
                let idx = json["index"] as? Int ?? 0
                if let delta = json["delta"] as? [String: Any] {
                    switch delta["type"] as? String {
                    case "input_json_delta":
                        if let frag = delta["partial_json"] as? String {
                            blocks[idx, default: Block(type: "tool_use", id: "", name: "", partialJSON: "")].partialJSON += frag
                        }
                    default:
                        // text_delta (or a server that omits the delta type for text).
                        if let text = delta["text"] as? String, !text.isEmpty { out.append(.delta(text)) }
                    }
                }
            case "content_block_stop":
                let idx = json["index"] as? Int ?? 0
                if let b = blocks.removeValue(forKey: idx), b.type == "tool_use" {
                    out.append(.toolCall(id: b.id, name: b.name,
                                         argumentsJSON: b.partialJSON.isEmpty ? "{}" : b.partialJSON))
                }
            case "message_delta":
                if let usage = json["usage"] as? [String: Any],
                   let outTokens = usage["output_tokens"] as? Int {
                    out.append(.usage(promptTokens: usage["input_tokens"] as? Int ?? 0,
                                      completionTokens: outTokens))
                }
            case "message_stop":
                out.append(.finish(reason: nil))
            default:
                break
            }
            return out
        }

        /// Convenience: decode a raw SSE `data:` payload string, then `consume` it.
        public mutating func consume(payload: String) -> [StreamEvent] {
            guard payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return consume(json)
        }
    }

    public func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: id) }
        guard let url = URL(string: endpoint) else { throw AIProviderError.configuration("bad endpoint \(endpoint)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: makeBodyTools(messages: messages, model: model, settings: settings, tools: tools, stream: true))

        return AsyncThrowingStream { continuation in
            let task = Task {
                var acc = ToolStreamAccumulator()
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
                        for event in acc.consume(payload: payload) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let e as AIProviderError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: AIProviderError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: id) }
        guard let url = URL(string: endpoint) else { throw AIProviderError.configuration("bad endpoint \(endpoint)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
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
