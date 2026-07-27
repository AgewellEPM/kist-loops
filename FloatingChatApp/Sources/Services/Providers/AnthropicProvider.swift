import Foundation

final class AnthropicProvider: AIProvider {
    let id = "anthropic"
    let name = "Claude"
    let iconName = "brain.head.profile"
    let supportsStreaming = true
    let supportsVision = true
    let requiresAPIKey = true
    let apiKeySettingKey = "anthropic_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    private let baseURL = "https://api.anthropic.com/v1/messages"

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting. Honors any model id.
    var modelOverride: String?

    var availableModels: [AIModel] = [
        AIModel(id: "claude-fable-5", name: "claude-fable-5", displayName: "Claude Fable 5", isVision: true),
        AIModel(id: "claude-opus-4-8-20251215", name: "claude-opus-4-8-20251215", displayName: "Claude Opus 4.8", isVision: true),
        AIModel(id: "claude-sonnet-4-5-20250514", name: "claude-sonnet-4-5-20250514", displayName: "Claude 4.5 Sonnet", isVision: true),
        AIModel(id: "claude-sonnet-4-20250514", name: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4", isVision: true),
        AIModel(id: "claude-3-5-sonnet-20241022", name: "claude-3-5-sonnet-20241022", displayName: "Claude 3.5 Sonnet", isVision: true),
        AIModel(id: "claude-3-5-haiku-20241022", name: "claude-3-5-haiku-20241022", displayName: "Claude 3.5 Haiku", isVision: true),
        AIModel(id: "claude-3-opus-20240229", name: "claude-3-opus-20240229", displayName: "Claude 3 Opus", isVision: true)
    ]

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "anthropic_model") ?? "claude-fable-5"
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "anthropic_model")
            }
        }
    }

    func sendMessage(
        messages: [ChatMessage],
        settings: ModelSettings,
        stream: Bool
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        let modelId = selectedModel?.id ?? "claude-fable-5"

        // Build messages array - filter out system messages
        var apiMessages: [[String: Any]] = []

        for message in messages.filter({ $0.role != .system }) {
            if message.hasImage, let imageData = message.imageData {
                // Vision message with image
                let base64 = imageData.base64EncodedString()
                let mimeType = message.imageMimeType ?? "image/jpeg"

                var content: [[String: Any]] = []

                if !message.content.isEmpty {
                    content.append(["type": "text", "text": message.content])
                }

                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mimeType,
                        "data": base64
                    ]
                ])

                apiMessages.append([
                    "role": message.role.rawValue,
                    "content": content
                ])
            } else {
                apiMessages.append([
                    "role": message.role.rawValue,
                    "content": message.content
                ])
            }
        }

        guard let url = URL(string: baseURL) else {
            throw AIProviderError.configurationError("Invalid API URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var body: [String: Any] = [
            "model": modelId,
            "max_tokens": settings.maxTokens,
            "messages": apiMessages,
            "stream": stream,
            "temperature": settings.temperature,
            "top_p": settings.topP
        ]

        // Add system prompt
        if !settings.systemPrompt.isEmpty {
            body["system"] = settings.systemPrompt
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw AIProviderError.invalidAPIKey
            } else if httpResponse.statusCode == 429 {
                throw AIProviderError.rateLimited
            }
            // Read error body for details
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode): \(String(errorBody.prefix(500)))")
        }

        for try await line in bytes.lines {
            if line.hasPrefix("data: ") {
                let jsonString = String(line.dropFirst(6))
                if jsonString == "[DONE]" { continue }

                if let data = jsonString.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                    if let delta = json["delta"] as? [String: Any],
                       let text = delta["text"] as? String {
                        continuation.yield(text)
                    }

                    if let contentBlock = json["content_block"] as? [String: Any],
                       let text = contentBlock["text"] as? String {
                        continuation.yield(text)
                    }
                }
            }
        }
        continuation.finish()
    }

    private func nonStreamResponse(request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw AIProviderError.invalidAPIKey
            }
            throw AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return text
    }

    func validateAPIKey(_ key: String) async -> Bool {
        return key.hasPrefix("sk-ant-")
    }
}
