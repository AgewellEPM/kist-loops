import Foundation

final class OpenAIProvider: AIProvider {
    let id = "openai"
    let name = "GPT"
    let iconName = "sparkles"
    let supportsStreaming = true
    let supportsVision = true
    let requiresAPIKey = true
    let apiKeySettingKey = "openai_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    private let baseURL = "https://api.openai.com/v1/chat/completions"

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting. Honors any model id.
    var modelOverride: String?

    var availableModels: [AIModel] = [
        AIModel(id: "gpt-5.5", name: "gpt-5.5", displayName: "GPT-5.5", isVision: true),
        AIModel(id: "gpt-5.4", name: "gpt-5.4", displayName: "GPT-5.4", isVision: true),
        AIModel(id: "gpt-4o", name: "gpt-4o", displayName: "GPT-4o", isVision: true),
        AIModel(id: "gpt-4o-mini", name: "gpt-4o-mini", displayName: "GPT-4o Mini", isVision: true),
        AIModel(id: "gpt-4-turbo", name: "gpt-4-turbo", displayName: "GPT-4 Turbo", isVision: true),
        AIModel(id: "gpt-3.5-turbo", name: "gpt-3.5-turbo", displayName: "GPT-3.5 Turbo")
    ]

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "openai_model") ?? "gpt-5.5"
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "openai_model")
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

        let modelId = selectedModel?.id ?? "gpt-5.5"
        var apiMessages: [[String: Any]] = []

        // Add system message
        if !settings.systemPrompt.isEmpty {
            apiMessages.append([
                "role": "system",
                "content": settings.systemPrompt
            ])
        }

        for message in messages {
            if message.hasImage, let imageData = message.imageData {
                // Vision message
                let base64 = imageData.base64EncodedString()
                let mimeType = message.imageMimeType ?? "image/jpeg"
                let dataUrl = "data:\(mimeType);base64,\(base64)"

                var content: [[String: Any]] = []

                if !message.content.isEmpty {
                    content.append(["type": "text", "text": message.content])
                }

                content.append([
                    "type": "image_url",
                    "image_url": ["url": dataUrl]
                ])

                apiMessages.append([
                    "role": message.role == .assistant ? "assistant" : (message.role == .system ? "system" : "user"),
                    "content": content
                ])
            } else {
                apiMessages.append([
                    "role": message.role == .assistant ? "assistant" : (message.role == .system ? "system" : "user"),
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": modelId,
            "messages": apiMessages,
            "stream": stream,
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "frequency_penalty": settings.frequencyPenalty,
            "presence_penalty": settings.presencePenalty
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
            throw AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode)")
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
