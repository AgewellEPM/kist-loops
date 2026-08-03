import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// Google Gemini (Generative Language API) as an AgentCore `ChatProvider`.
///
/// Differs from the OpenAI-compatible shape: roles are `user` / `model`, the
/// system prompt lives in `systemInstruction`, generation params under
/// `generationConfig`, and the API key is a query parameter (not a Bearer
/// header). SSE chunks carry `candidates[0].content.parts[].text`.
///
/// Stateless + Sendable per the `ChatProvider` contract: model id and key are
/// passed in by the caller. Body construction (`makeBody`) and SSE parsing
/// (`events(fromSSE:)`) are pure/static so they're unit-testable without a
/// network round-trip. Mirrors `OpenAICompatibleProvider.stream` structure.
public struct GeminiProvider: ChatProvider {
    public let id = "gemini"
    public let name = "Gemini"
    public let iconName = "sparkles"
    public let requiresAPIKey = true
    public let keyAccount = "gemini_api_key"
    public let defaultModel = "gemini-2.5-flash"

    public let availableModels: [AIModel] = [
        AIModel(id: "gemini-3.1-pro", name: "gemini-3.1-pro", displayName: "Gemini 3.1 Pro", isVision: true),
        AIModel(id: "gemini-3.5-flash", name: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", isVision: true),
        AIModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", isVision: true),
        AIModel(id: "gemini-2.5-pro", name: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", isVision: true)
    ]

    /// Base path; per-request URL appends `/<model>:streamGenerateContent?alt=sse&key=<key>`.
    public let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    public init() {}

    // MARK: - Request body (pure / testable)

    static func supportsSamplingControls(model: String) -> Bool {
        !model.lowercased().hasPrefix("gemini-3")
    }

    /// Apply the optional generationConfig knobs shared by both request builders: topK / penalties
    /// (only where sampling controls apply), seed, stopSequences, and thinking budget (disable wins;
    /// else a positive budget). Each is added only when the caller set it — defaults stay provider-side.
    static func augmentGeneration(_ config: inout [String: Any], settings: ModelSettings, model: String) {
        if supportsSamplingControls(model: model) {
            if let topK = settings.topK { config["topK"] = topK }
            if let fp = settings.frequencyPenalty { config["frequencyPenalty"] = fp }
            if let pp = settings.presencePenalty { config["presencePenalty"] = pp }
        }
        if let seed = settings.seed { config["seed"] = seed }
        if !settings.stopSequences.isEmpty { config["stopSequences"] = settings.stopSequences }
        // LIVE-VERIFIED: gemini-2.5-pro 400s on thinkingBudget:0 ("only works in thinking mode"); and
        // gemini-3 uses thinkingLevel, not a budget. So only disable thinking where the model allows it.
        if settings.disableThinking, Self.canDisableThinking(model: model) {
            config["thinkingConfig"] = ["thinkingBudget": 0]
        } else if let budget = settings.thinkingBudget, budget > 0, Self.supportsThinkingBudget(model: model) {
            config["thinkingConfig"] = ["thinkingBudget": budget]
        }
    }

    /// gemini-3 uses `thinkingLevel`, not a token budget — so `thinkingBudget` (any value) is invalid there.
    static func supportsThinkingBudget(model: String) -> Bool { !model.lowercased().hasPrefix("gemini-3") }

    /// Pro models cannot disable thinking (budget 0 → 400). Only flash/lite/2.0 tiers can.
    static func canDisableThinking(model: String) -> Bool {
        supportsThinkingBudget(model: model) && !model.lowercased().contains("-pro")
    }

    /// Map ChatMessages to Gemini's request body. `assistant` → `model`;
    /// `system` messages and `settings.systemPrompt` fold into `systemInstruction`.
    /// Consecutive same-role turns are coalesced (Gemini rejects two adjacent
    /// turns with the same role).
    public func makeBody(messages: [ChatMessage], model: String, settings: ModelSettings) -> [String: Any] {
        var contents: [[String: Any]] = []
        var systemTexts: [String] = []
        if !settings.systemPrompt.isEmpty { systemTexts.append(settings.systemPrompt) }

        for message in messages {
            switch message.role {
            case .system:
                if !message.content.isEmpty { systemTexts.append(message.content) }
            case .user, .assistant, .tool:
                // .tool (native result) is treated as a user text part here; the native Gemini
                // path encodes it as a functionResponse (P1 native implementation).
                let role = message.role == .assistant ? "model" : "user"
                var parts: [[String: Any]] = []
                if !message.content.isEmpty { parts.append(["text": message.content]) }
                parts.append(contentsOf: Self.mediaParts(for: message))   // image/video/audio/pdf
                if parts.isEmpty { parts.append(["text": ""]) }

                // Coalesce consecutive same-role turns: Gemini rejects two
                // adjacent turns with the same role.
                if var last = contents.last,
                   last["role"] as? String == role,
                   var lastParts = last["parts"] as? [[String: Any]] {
                    lastParts.append(contentsOf: parts)
                    last["parts"] = lastParts
                    contents[contents.count - 1] = last
                } else {
                    contents.append(["role": role, "parts": parts])
                }
            }
        }

        var generationConfig: [String: Any] = ["maxOutputTokens": settings.maxTokens]
        if Self.supportsSamplingControls(model: model) {
            generationConfig["temperature"] = settings.temperature
            generationConfig["topP"] = settings.topP
        }
        Self.augmentGeneration(&generationConfig, settings: settings, model: model)
        var body: [String: Any] = ["contents": contents, "generationConfig": generationConfig]
        if !systemTexts.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemTexts.joined(separator: "\n\n")]]]
        }
        return body
    }

    // MARK: - SSE parsing (pure / testable)

    /// Parse one Gemini SSE `data:` JSON payload into stream events. Pulls
    /// `candidates[0].content.parts[].text` → `.delta`. ONLY the first
    /// candidate — additional candidates are alternative completions and must
    /// not be concatenated into one stream.
    public static func events(fromSSE jsonString: String) -> [StreamEvent] {
        guard jsonString != "[DONE]",
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var out: [StreamEvent] = []
        if let candidates = json["candidates"] as? [[String: Any]], let c0 = candidates.first {
            if let content = c0["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    // Skip Gemini "thinking" summary parts (`thought: true`): they carry the model's
                    // private reasoning (which it often headers "[CURRENT_TURN_THOUGHT]"), NOT the answer.
                    // Concatenating them leaked chain-of-thought straight into the visible reply.
                    if (part["thought"] as? Bool) == true { continue }
                    if let text = part["text"] as? String, !text.isEmpty { out.append(.delta(text)) }
                }
            }
            if let reason = c0["finishReason"] as? String { out.append(.finish(reason: reason)) }
        }
        // Token counts arrive in usageMetadata (often on the final chunk).
        if let usage = json["usageMetadata"] as? [String: Any] {
            out.append(.usage(promptTokens: usage["promptTokenCount"] as? Int ?? 0,
                              completionTokens: usage["candidatesTokenCount"] as? Int ?? 0))
        }
        return out
    }

    // MARK: - Native tool-calling (pure / testable)

    /// Gemini implements native function-calling, so the loop hands it the tool
    /// schema directly instead of the text-protocol fallback.
    public var supportsNativeTools: Bool { true }

    public func capabilities(forModel model: String) -> ModelCapabilities {
        let modelId = resolvedModel(model)
        let meta = availableModels.first { $0.id == modelId || $0.name == modelId }
        let isGemini3 = modelId.lowercased().hasPrefix("gemini-3")
        let builtins = Self.supportsBuiltins(model: modelId)   // grounding / url-context / code-exec
        return ModelCapabilities(
            nativeTools: true,
            vision: meta?.isVision ?? true,
            contextWindowTokens: isGemini3 ? 1_000_000 : meta?.contextWindowTokens,
            video: true,
            audio: true,
            codeExecution: builtins,
            grounding: builtins,
            urlContext: builtins,
            structuredOutput: true
        )
    }

    /// Whether this model accepts Gemini's server-side built-in tools (Google Search, URL context,
    /// code execution). All current chat models (2.0 Flash, 2.5, 3.x) do; media/embedding/tts/live
    /// variants do not.
    public static func supportsBuiltins(model: String) -> Bool {
        let m = model.lowercased()
        guard m.hasPrefix("gemini-") else { return false }
        let excluded = ["image", "tts", "embedding", "veo", "live", "lyria", "aqa"]
        return !excluded.contains { m.contains($0) }
    }

    /// Kill-switch: `KIST_GEMINI_BUILTINS=off` disables the built-in tools globally (cost/escape hatch).
    static func builtinsEnabledByEnv() -> Bool {
        ProcessInfo.processInfo.environment["KIST_GEMINI_BUILTINS"]?.lowercased() != "off"
    }

    /// Citation URLs (deduped, in order) from a candidate's `groundingMetadata.groundingChunks[].web.uri`.
    static func groundingCitations(_ candidate: [String: Any]) -> [String]? {
        guard let meta = candidate["groundingMetadata"] as? [String: Any],
              let chunks = meta["groundingChunks"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        var urls: [String] = []
        for chunk in chunks {
            guard let web = chunk["web"] as? [String: Any] else { continue }
            guard let uri = web["uri"] as? String, !uri.isEmpty, seen.insert(uri).inserted else { continue }
            if let title = web["title"] as? String, !title.isEmpty { urls.append("\(title) — \(uri)") }
            else { urls.append(uri) }
        }
        return urls.isEmpty ? nil : urls
    }

    /// OpenAPI-subset JSON schema for a tool's parameters. Deliberately MINIMAL —
    /// Gemini's `functionDeclarations` parser rejects `additionalProperties`,
    /// `$ref`, `oneOf`, etc., so we emit only `type` / `properties` / `required`.
    public static func geminiSchema(_ params: [ToolParameter]) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in params {
            var schema: [String: Any] = ["type": p.type, "description": p.description]
            if p.type == "array" { schema["items"] = ["type": "string"] }   // Gemini requires items on arrays
            props[p.name] = schema
            if p.required { required.append(p.name) }
        }
        return ["type": "object", "properties": props, "required": required]
    }

    /// The `functionDeclarations` array for a set of neutral `ToolSpec`s.
    public static func functionDeclarations(_ tools: [ToolSpec]) -> [[String: Any]] {
        tools.map { ["name": $0.name, "description": $0.description, "parameters": Self.geminiSchema($0.parameters)] }
    }

    /// Parse a stored `argumentsJSON` string into the OBJECT Gemini wants under
    /// `functionCall.args`. Non-object / malformed JSON degrades to `{}`.
    public static func parseArgs(_ argumentsJSON: String) -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Encode a message's multimodal attachments (image/video/audio/pdf) into Gemini parts.
    /// Inline bytes → `inline_data` (base64); a Files-API reference → `file_data` (file_uri). Folds
    /// the legacy single `imageData` in via `allAttachments`, so both encode sites share one path.
    static func mediaParts(for message: ChatMessage) -> [[String: Any]] {
        message.allAttachments.map { attachment in
            switch attachment.payload {
            case .inline(let data):
                return ["inline_data": ["mime_type": attachment.mimeType, "data": data.base64EncodedString()]]
            case .fileURI(let uri):
                return ["file_data": ["mime_type": attachment.mimeType, "file_uri": uri]]
            }
        }
    }

    /// Recover the tool NAME from a synthesized call id, for malformed transcripts where the
    /// preceding-assistant lookup fails. Handles both the current `call_<name>_<8hex>` format
    /// (strip prefix + fixed 9-char `_<8hex>` suffix) and the legacy `call_<name>` (strip prefix
    /// only). Returns the id unchanged if it doesn't carry the `call_` prefix.
    static func recoverToolName(fromSyntheticID id: String) -> String {
        guard id.hasPrefix("call_") else { return id }
        var body = String(id.dropFirst(5))                 // drop "call_"
        // A trailing "_" + exactly 8 lowercase-hex chars is our unique suffix → strip it.
        if body.count > 9 {
            let suffix = body.suffix(9)
            if suffix.first == "_", suffix.dropFirst().allSatisfy({ $0.isHexDigit }) {
                body = String(body.dropLast(9))
            }
        }
        return body
    }

    /// Serialize a Gemini `args` object back to the canonical JSON string carried on
    /// `StreamEvent.toolCall`. Sorted keys → deterministic output (stable tests).
    public static func serializeArgs(_ args: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Request body for the NATIVE path. Like `makeBody`, but:
    ///  • assistant `toolCalls` become `model` `functionCall` parts (args re-parsed to an object);
    ///  • `.tool` results become `user` `functionResponse` parts whose NAME is looked up from the
    ///    immediately-preceding assistant message's `toolCalls` (matching `toolCallId` → `ToolCallRef.id`);
    ///  • a `tools: [{ functionDeclarations: [...] }]` array is attached.
    /// Order is preserved (a `functionResponse` turn must follow its `functionCall` turn). Kept
    /// separate from `makeBody` so the text-path body + its tests stay untouched.
    public func makeBodyTools(messages: [ChatMessage], model: String, settings: ModelSettings, tools: [ToolSpec]) -> [String: Any] {
        var contents: [[String: Any]] = []
        var systemTexts: [String] = []
        if !settings.systemPrompt.isEmpty { systemTexts.append(settings.systemPrompt) }
        // Tracks the most recent assistant turn's native calls so a following `.tool`
        // result can resolve the tool NAME Gemini requires on `functionResponse`.
        var lastAssistantCalls: [ToolCallRef] = []

        // Append parts, coalescing into the previous content when the role matches —
        // Gemini rejects two adjacent contents with the same role.
        func append(role: String, parts: [[String: Any]]) {
            if var last = contents.last,
               last["role"] as? String == role,
               var lastParts = last["parts"] as? [[String: Any]] {
                lastParts.append(contentsOf: parts)
                last["parts"] = lastParts
                contents[contents.count - 1] = last
            } else {
                contents.append(["role": role, "parts": parts])
            }
        }

        for message in messages {
            switch message.role {
            case .system:
                if !message.content.isEmpty { systemTexts.append(message.content) }

            case .user:
                var parts: [[String: Any]] = []
                if !message.content.isEmpty { parts.append(["text": message.content]) }
                parts.append(contentsOf: Self.mediaParts(for: message))   // image/video/audio/pdf
                if parts.isEmpty { parts.append(["text": ""]) }
                append(role: "user", parts: parts)

            case .assistant:
                var parts: [[String: Any]] = []
                if !message.content.isEmpty { parts.append(["text": message.content]) }
                if let calls = message.toolCalls, !calls.isEmpty {
                    lastAssistantCalls = calls
                    for call in calls {
                        parts.append(["functionCall": ["name": call.name, "args": Self.parseArgs(call.argumentsJSON)]])
                    }
                }
                if parts.isEmpty { parts.append(["text": ""]) }
                append(role: "model", parts: parts)

            case .tool:
                // Resolve the tool name from the preceding assistant's calls (PRIMARY — always
                // succeeds in our own loop, which appends assistant-with-toolCalls right before the
                // result). FALLBACK for malformed/external transcripts: recover the name from the
                // synthesized id `call_<name>_<8hex>` by stripping the prefix + the fixed-length
                // unique suffix. (Pre-suffix ids `call_<name>` have no suffix → just strip prefix.)
                let name = lastAssistantCalls.first(where: { $0.id == message.toolCallId })?.name
                    ?? (message.toolCallId.map { Self.recoverToolName(fromSyntheticID: $0) } ?? "")
                let part: [String: Any] = ["functionResponse": ["name": name, "response": ["result": message.content]]]
                append(role: "user", parts: [part])
            }
        }

        var generationConfig: [String: Any] = ["maxOutputTokens": settings.maxTokens]
        if Self.supportsSamplingControls(model: model) {
            generationConfig["temperature"] = settings.temperature
            generationConfig["topP"] = settings.topP
        }
        Self.augmentGeneration(&generationConfig, settings: settings, model: model)
        // Structured output: constrain to JSON when a sub-call asks for it (opt-in). A jsonSchema
        // additionally pins the exact shape (responseSchema) and implies JSON.
        if let schemaString = settings.jsonSchema,
           let schemaData = schemaString.data(using: .utf8),
           let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = schema
        } else if settings.jsonOutput {
            generationConfig["responseMimeType"] = "application/json"
        }
        var body: [String: Any] = ["contents": contents, "generationConfig": generationConfig]
        if !systemTexts.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemTexts.joined(separator: "\n\n")]]]
        }
        // tools[] mixes OUR function declarations with Gemini's SERVER-SIDE built-ins (Google Search
        // grounding, URL context, code execution). The model uses a built-in only when it decides it
        // needs one; otherwise it calls our functions or answers. Built-ins are documented to combine
        // with function calling on 2.5/3.x. Kill-switch: KIST_GEMINI_BUILTINS=off.
        var toolBlocks: [[String: Any]] = []
        if !tools.isEmpty { toolBlocks.append(["functionDeclarations": Self.functionDeclarations(tools)]) }
        // LIVE-VERIFIED CONSTRAINT (gemini-2.5-flash): the API rejects ANY built-in tool together with
        // functionDeclarations — HTTP 400 "Built-in tools (…) and Function calling cannot be enabled at
        // the same time." So the server-side built-ins are offered ONLY on tool-less requests. The agent
        // loop always carries its own functions, so built-ins fire on plain/sub calls, not mid-tool-loop.
        // Built-ins also can't coexist with structured output (responseSchema/JSON) — so suppress them
        // when a JSON shape is requested, too.
        if settings.geminiBuiltins, Self.builtinsEnabledByEnv(), Self.supportsBuiltins(model: model),
           tools.isEmpty, settings.jsonSchema == nil, !settings.jsonOutput {
            toolBlocks.append(["google_search": [String: Any]()])
            toolBlocks.append(["url_context": [String: Any]()])
            toolBlocks.append(["code_execution": [String: Any]()])
        }
        if !toolBlocks.isEmpty { body["tools"] = toolBlocks }
        // Force/forbid function calls when asked (default AUTO is the API default, so omit it). Only
        // meaningful alongside a tools[] body — sending toolConfig without tools is undefined.
        if settings.toolChoice != .auto, !toolBlocks.isEmpty {
            body["toolConfig"] = ["functionCallingConfig": ["mode": settings.toolChoice.rawValue.uppercased()]]
        }
        return body
    }

    /// Parse one `streamGenerateContent` SSE payload on the NATIVE path. Pulls
    /// `candidates[0].content.parts[]`: `text` → `.delta`, `functionCall` →
    /// `.toolCall` (Gemini has no native call id, so synthesize `call_<name>` and
    /// serialize `args` back to a JSON string). ONLY the first candidate.
    public static func eventsWithTools(fromSSE jsonString: String) -> [StreamEvent] {
        guard jsonString != "[DONE]",
              let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var out: [StreamEvent] = []
        if let candidates = json["candidates"] as? [[String: Any]], let c0 = candidates.first {
            if let content = c0["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty { out.append(.delta(text)) }
                    // Built-in CODE EXECUTION: surface the code Gemini ran + its result inline so the
                    // agent (and user) can see the computation, not just the conclusion.
                    if let ec = part["executableCode"] as? [String: Any], let code = ec["code"] as? String, !code.isEmpty {
                        let lang = (ec["language"] as? String ?? "python").lowercased()
                        out.append(.delta("\n```\(lang)\n\(code)\n```\n"))
                    }
                    if let cr = part["codeExecutionResult"] as? [String: Any] {
                        let output = (cr["output"] as? String) ?? ""
                        if !output.isEmpty { out.append(.delta("\n```\n\(output)\n```\n")) }
                    }
                    if let fc = part["functionCall"] as? [String: Any], let name = fc["name"] as? String {
                        let args = fc["args"] as? [String: Any] ?? [:]
                        // Gemini has NO native call id. Synthesize a UNIQUE one — `call_<name>_<8hex>`
                        // — so two calls to the SAME function in one turn don't collide (a shared id
                        // would break toolCallId→name routing for the second result). The 8-hex suffix
                        // is fixed-length so `makeBodyTools` can recover the name by stripping it.
                        let uid = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
                        out.append(.toolCall(id: "call_\(name)_\(uid)", name: name, argumentsJSON: Self.serializeArgs(args)))
                    }
                }
            }
            // GROUNDING: when Google Search backed the answer, surface the source URLs so claims are
            // checkable (and the user sees kist used live web facts). Emitted once, at finish.
            if let citations = Self.groundingCitations(c0), !citations.isEmpty {
                out.append(.delta("\n\nSources:\n" + citations.map { "- \($0)" }.joined(separator: "\n")))
            }
            if let reason = c0["finishReason"] as? String { out.append(.finish(reason: reason)) }
        }
        if let usage = json["usageMetadata"] as? [String: Any] {
            out.append(.usage(promptTokens: usage["promptTokenCount"] as? Int ?? 0,
                              completionTokens: usage["candidatesTokenCount"] as? Int ?? 0))
        }
        return out
    }

    public func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: id) }

        let modelId = resolvedModel(model)
        let urlString = "\(baseURL)/\(modelId):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw AIProviderError.configuration("bad endpoint \(urlString)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: makeBodyTools(messages: messages, model: modelId, settings: settings, tools: tools))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        if http.statusCode == 401 || http.statusCode == 403 { throw AIProviderError.invalidAPIKey }
                        if http.statusCode == 429 { throw AIProviderError.rateLimited }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw AIProviderError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        for event in Self.eventsWithTools(fromSSE: payload) { continuation.yield(event) }
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

    // MARK: - Stream

    public func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: id) }

        let modelId = resolvedModel(model)
        let urlString = "\(baseURL)/\(modelId):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw AIProviderError.configuration("bad endpoint \(urlString)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: makeBody(messages: messages, model: modelId, settings: settings))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        // 401/403 (auth/permission/billing/allowlist) → invalidAPIKey.
                        if http.statusCode == 401 || http.statusCode == 403 { throw AIProviderError.invalidAPIKey }
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
