import Foundation

/// Google Gemini (Generative Language API).
///
/// Differs from the OpenAI/Anthropic shape: roles are `user` / `model`, the
/// system prompt goes in `systemInstruction`, generation params live under
/// `generationConfig`, and the API key is a query parameter. Request-body
/// construction is factored into `makeRequestBody` so it's unit-testable
/// without the network.
final class GeminiProvider: AIProvider {
    let id = "gemini"
    let name = "Gemini"
    let iconName = "sparkles"
    let supportsStreaming = true
    let supportsVision = true
    let requiresAPIKey = true
    let apiKeySettingKey = "gemini_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    private let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    static let defaultModelId = "gemini-3.1-pro"

    var availableModels: [AIModel] = [
        AIModel(id: "gemini-3.1-pro", name: "gemini-3.1-pro", displayName: "Gemini 3.1 Pro", isVision: true),
        AIModel(id: "gemini-3.5-flash", name: "gemini-3.5-flash", displayName: "Gemini 3.5 Flash", isVision: true),
        AIModel(id: "gemini-2.5-flash", name: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", isVision: true),
        AIModel(id: "gemini-2.5-pro", name: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", isVision: true),
        AIModel(id: "gemini-2.5-flash-lite", name: "gemini-2.5-flash-lite", displayName: "Gemini 2.5 Flash-Lite", isVision: true)
    ]

    /// Per-instance model override (set by `getProvider(for:)` from the agent's
    /// configured model). Takes precedence over the global default WITHOUT
    /// persisting it — so a team agent's model choice can't thrash the user's
    /// saved selection or race other agents. Honors any Gemini model id, not
    /// just the curated list. (Codex HIGH-2.)
    var modelOverride: String?

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "gemini_model") ?? Self.defaultModelId
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "gemini_model")
            }
        }
    }

    // MARK: - Request body (pure / testable)

    /// Map ChatMessages to Gemini's request body. `assistant` → `model`;
    /// `system` messages and `settings.systemPrompt` → `systemInstruction`.
    func makeRequestBody(messages: [ChatMessage], settings: ModelSettings) -> [String: Any] {
        var contents: [[String: Any]] = []
        var systemTexts: [String] = []
        if !settings.systemPrompt.isEmpty { systemTexts.append(settings.systemPrompt) }

        for message in messages {
            switch message.role {
            case .system:
                if !message.content.isEmpty { systemTexts.append(message.content) }
            case .user, .assistant:
                let role = message.role == .assistant ? "model" : "user"
                var parts: [[String: Any]] = []
                if !message.content.isEmpty { parts.append(["text": message.content]) }
                if message.hasImage, let imageData = message.imageData {
                    parts.append([
                        "inline_data": [
                            "mime_type": message.imageMimeType ?? "image/jpeg",
                            "data": imageData.base64EncodedString()
                        ]
                    ])
                }
                if parts.isEmpty { parts.append(["text": ""]) }

                // Coalesce consecutive same-role turns: Gemini rejects two
                // adjacent turns with the same role, and the agent loop commonly
                // emits assistant reply + <thinking> + <tool_use> back-to-back.
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

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": [
                "temperature": settings.temperature,
                "topP": settings.topP,
                "maxOutputTokens": settings.maxTokens
            ]
        ]
        if !systemTexts.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemTexts.joined(separator: "\n\n")]]]
        }
        return body
    }

    // MARK: - Send

    func sendMessage(
        messages: [ChatMessage],
        settings: ModelSettings,
        stream: Bool
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard !apiKey.isEmpty else { throw AIProviderError.invalidAPIKey }

        let modelId = selectedModel?.id ?? Self.defaultModelId
        let method = stream ? "streamGenerateContent" : "generateContent"
        var urlString = "\(baseURL)/\(modelId):\(method)?key=\(apiKey)"
        if stream { urlString += "&alt=sse" }

        guard let url = URL(string: urlString) else {
            throw AIProviderError.configurationError("Invalid API URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: makeRequestBody(messages: messages, settings: settings))

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if stream {
                        try await self.streamResponse(request: request, continuation: continuation)
                    } else {
                        let response = try await self.nonStreamResponse(request: request)
                        continuation.yield(response)
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func streamResponse(
        request: URLRequest,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
            throw Self.error(for: httpResponse.statusCode, body: errorBody)
        }

        // Accumulate SSE `data:` lines per event (flush on blank line). Per the
        // SSE spec multiple data lines join with "\n" (a single leading space
        // after the colon is stripped) — bare concatenation would corrupt JSON
        // whose string content spans lines.
        var dataLines: [String] = []
        func flush() {
            guard !dataLines.isEmpty else { return }
            for text in Self.extractTexts(fromChunk: dataLines.joined(separator: "\n")) {
                continuation.yield(text)
            }
            dataLines.removeAll()
        }
        for try await line in bytes.lines {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("data:") {
                var payload = String(line.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                dataLines.append(payload)
            }
        }
        flush()
        continuation.finish()
    }

    private func nonStreamResponse(request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(for: httpResponse.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let jsonString = String(data: data, encoding: .utf8) else { throw AIProviderError.invalidResponse }
        let texts = Self.extractTexts(fromChunk: jsonString)
        guard !texts.isEmpty else { throw AIProviderError.invalidResponse }
        return texts.joined()
    }

    /// Pull `candidates[0].content.parts[].text` out of a Gemini JSON chunk.
    /// Only the FIRST candidate — additional candidates are alternative
    /// completions and must not be concatenated into one stream. Static + pure
    /// so it's unit-testable.
    static func extractTexts(fromChunk jsonString: String) -> [String] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return []
        }
        return parts.compactMap { part in
            (part["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// Map an HTTP status to a precise error. 403 (permission/billing/allowlist)
    /// is NOT collapsed into invalidAPIKey.
    static func error(for status: Int, body: String) -> AIProviderError {
        switch status {
        case 401: return .invalidAPIKey
        case 429: return .rateLimited
        case 403: return .unknown(message: "HTTP 403 (permission/billing/allowlist): \(String(body.prefix(300)))")
        default:  return .unknown(message: "HTTP \(status): \(String(body.prefix(300)))")
        }
    }

    func validateAPIKey(_ key: String) async -> Bool {
        key.hasPrefix("AIza")
    }
}
