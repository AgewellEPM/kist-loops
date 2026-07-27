import Foundation

/// Moonshot AI (Kimi K2). OpenAI-compatible chat/completions API — same request
/// and streaming shape as DeepSeek/OpenAI: `messages`, SSE `data:` lines, and
/// `choices[].delta.content` for the stream. Auth is a `Bearer <apiKey>` header.
final class MoonshotProvider: AIProvider {
    let id = "moonshot"
    let name = "Kimi (Moonshot)"
    let iconName = "moon.stars.fill"
    let supportsStreaming = true
    let supportsVision = false
    let requiresAPIKey = true
    let apiKeySettingKey = "moonshot_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    private let baseURL = "https://api.moonshot.ai/v1/chat/completions"
    static let defaultModelId = "kimi-k2-0711-preview"

    var availableModels: [AIModel] = [
        AIModel(id: "kimi-k2-0711-preview", name: "kimi-k2-0711-preview", displayName: "Kimi K2"),
        AIModel(id: "kimi-k2-turbo-preview", name: "kimi-k2-turbo-preview", displayName: "Kimi K2 Turbo"),
        AIModel(id: "moonshot-v1-128k", name: "moonshot-v1-128k", displayName: "Moonshot v1 128k")
    ]

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting. Honors any model id.
    var modelOverride: String?

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "moonshot_model") ?? Self.defaultModelId
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "moonshot_model")
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

        let modelId = selectedModel?.id ?? Self.defaultModelId
        var apiMessages: [[String: Any]] = []

        // Add system message
        if !settings.systemPrompt.isEmpty {
            apiMessages.append([
                "role": "system",
                "content": settings.systemPrompt
            ])
        }

        for message in messages.filter({ $0.role != .system }) {
            apiMessages.append([
                "role": message.role == .assistant ? "assistant" : "user",
                "content": message.content
            ])
        }

        guard let url = URL(string: baseURL) else {
            throw AIProviderError.configurationError("Invalid API URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": modelId,
            "messages": apiMessages,
            "stream": stream,
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature,
            "top_p": settings.topP
        ]

        if let seed = settings.seed {
            body["seed"] = seed
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
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let content = delta["content"] as? String {
                    continuation.yield(content)
                }
            }
        }
        continuation.finish()
    }

    private func nonStreamResponse(request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AIProviderError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return content
    }

    func validateAPIKey(_ key: String) async -> Bool {
        return key.hasPrefix("sk-")
    }
}
