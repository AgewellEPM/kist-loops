import Foundation

/// Zhipu AI / BigModel (GLM family). OpenAI-compatible chat/completions API,
/// so the request/stream shape mirrors `DeepSeekProvider` exactly: Bearer auth,
/// `choices[].delta.content` SSE streaming, and `choices[].message.content` for
/// non-streaming responses.
final class ZhipuProvider: AIProvider {
    let id = "zhipu"
    let name = "GLM (Z.AI)"
    let iconName = "sparkles"
    let supportsStreaming = true
    let supportsVision = false
    let requiresAPIKey = true
    let apiKeySettingKey = "zhipu_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    // Z.AI international OpenAI-compatible endpoint. (Mainland Zhipu users can
    // override to https://open.bigmodel.cn/api/paas/v4/chat/completions via the
    // "zhipu_base_url" default.)
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "zhipu_base_url") ?? "https://api.z.ai/api/paas/v4/chat/completions"
    }
    static let defaultModelId = "glm-5.2"

    var availableModels: [AIModel] = [
        AIModel(id: "glm-5.2", name: "glm-5.2", displayName: "GLM-5.2"),
        AIModel(id: "glm-4.6", name: "glm-4.6", displayName: "GLM-4.6"),
        AIModel(id: "glm-4.5", name: "glm-4.5", displayName: "GLM-4.5"),
        AIModel(id: "glm-4-flash", name: "glm-4-flash", displayName: "GLM-4 Flash")
    ]

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting it — so a team
    /// agent's model choice can't thrash the user's saved selection or race
    /// other agents. Honors any GLM model id, not just the curated list.
    var modelOverride: String?

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "zhipu_model") ?? Self.defaultModelId
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "zhipu_model")
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
        // GLM keys are formatted "id.secret"; non-empty is the only safe check.
        return !key.isEmpty
    }
}
