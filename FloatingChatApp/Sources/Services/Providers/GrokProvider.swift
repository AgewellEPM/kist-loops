import Foundation

final class GrokProvider: AIProvider {
    let id = "grok"
    let name = "Grok (xAI)"
    let iconName = "bolt.fill"
    let supportsStreaming = true
    let supportsVision = true
    let requiresAPIKey = true
    let apiKeySettingKey = "grok_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    private let baseURL = "https://api.x.ai/v1/chat/completions"

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting. Honors any model id.
    var modelOverride: String?

    var availableModels: [AIModel] = [
        AIModel(id: "grok-4.3", name: "grok-4.3", displayName: "Grok 4.3", isVision: true),
        AIModel(id: "grok-code-fast-1", name: "grok-code-fast-1", displayName: "Grok Code Fast 1", isVision: false),
        AIModel(id: "grok-2-latest", name: "grok-2-latest", displayName: "Grok 2", isVision: true),
        AIModel(id: "grok-2-vision-1212", name: "grok-2-vision-1212", displayName: "Grok 2 Vision", isVision: true),
        AIModel(id: "grok-beta", name: "grok-beta", displayName: "Grok Beta", isVision: false)
    ]

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "grok_model") ?? "grok-4.3"
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "grok_model")
            }
        }
    }

    func validateAPIKey(_ key: String) async -> Bool {
        guard !key.isEmpty else { return false }
        guard let url = URL(string: "https://api.x.ai/v1/models") else { return false }
        do {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
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

        let modelId = selectedModel?.id ?? "grok-4.3"

        // Build messages array
        var apiMessages: [[String: Any]] = []

        // Add system message if present
        if !settings.systemPrompt.isEmpty {
            apiMessages.append([
                "role": "system",
                "content": settings.systemPrompt
            ])
        }

        for message in messages.filter({ $0.role != .system }) {
            if message.hasImage, let imageData = message.imageData {
                // Vision message
                let base64 = imageData.base64EncodedString()
                let mimeType = message.imageMimeType ?? "image/jpeg"

                var content: [[String: Any]] = []
                if !message.content.isEmpty {
                    content.append(["type": "text", "text": message.content])
                }
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mimeType);base64,\(base64)"]
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": modelId,
            "messages": apiMessages,
            "stream": stream,
            "temperature": settings.temperature,
            "max_tokens": settings.maxTokens
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    if stream {
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            continuation.finish(throwing: AIProviderError.invalidResponse)
                            return
                        }

                        if httpResponse.statusCode != 200 {
                            continuation.finish(throwing: AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode)"))
                            return
                        }

                        for try await line in bytes.lines {
                            if line.hasPrefix("data: ") {
                                let jsonString = String(line.dropFirst(6))
                                if jsonString == "[DONE]" {
                                    break
                                }

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
                    } else {
                        let (data, response) = try await URLSession.shared.data(for: request)

                        guard let httpResponse = response as? HTTPURLResponse else {
                            continuation.finish(throwing: AIProviderError.invalidResponse)
                            return
                        }

                        if httpResponse.statusCode != 200 {
                            continuation.finish(throwing: AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode)"))
                            return
                        }

                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = json["choices"] as? [[String: Any]],
                           let message = choices.first?["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            continuation.yield(content)
                        }
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
