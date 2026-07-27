import Foundation

/// Xiaomi MiMo. OpenAI-compatible chat/completions. VERIFIED against a live key:
/// host = https://api.xiaomimimo.com/v1, Bearer auth, returns choices[].message.
/// Current text models are the V2.5 series (mimo-v2.5-pro, mimo-v2.5 omni); the
/// legacy mimo-v2-* names are deprecating (auto-route to V2.5, gone ~2026-06-30).
/// Base URL still overridable via "mimo_base_url" if Xiaomi changes the host.
final class MiMoProvider: AIProvider {
    let id = "mimo"
    let name = "MiMo (Xiaomi)"
    let iconName = "cpu"
    let supportsStreaming = true
    let supportsVision = false
    let requiresAPIKey = true
    let apiKeySettingKey = "mimo_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    /// Inferred OpenAI-compatible endpoint; overridable via "mimo_base_url".
    private var baseURL: String {
        UserDefaults.standard.string(forKey: "mimo_base_url") ?? "https://api.xiaomimimo.com/v1/chat/completions"
    }
    static let defaultModelId = "mimo-v2.5-pro"

    var availableModels: [AIModel] = [
        AIModel(id: "mimo-v2.5-pro", name: "mimo-v2.5-pro", displayName: "MiMo V2.5 Pro"),
        AIModel(id: "mimo-v2.5", name: "mimo-v2.5", displayName: "MiMo V2.5 (Omni)")
    ]

    /// Per-instance, non-persisting model override (set from the agent's model).
    var modelOverride: String?

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "mimo_model") ?? Self.defaultModelId
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "mimo_model")
            }
        }
    }

    func sendMessage(
        messages: [ChatMessage],
        settings: ModelSettings,
        stream: Bool
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard !apiKey.isEmpty else { throw AIProviderError.invalidAPIKey }

        let modelId = selectedModel?.id ?? Self.defaultModelId
        var apiMessages: [[String: Any]] = []
        if !settings.systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": settings.systemPrompt])
        }
        for message in messages.filter({ $0.role != .system }) {
            apiMessages.append([
                "role": message.role == .assistant ? "assistant" : "user",
                "content": message.content
            ])
        }

        guard let url = URL(string: baseURL) else {
            throw AIProviderError.configurationError("Invalid MiMo API URL: \(baseURL)")
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
        if let seed = settings.seed { body["seed"] = seed }
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
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 { throw AIProviderError.invalidAPIKey }
            if httpResponse.statusCode == 429 { throw AIProviderError.rateLimited }
            var errorBody = ""
            for try await line in bytes.lines { errorBody += line }
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
        guard let httpResponse = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 { throw AIProviderError.invalidAPIKey }
            if httpResponse.statusCode == 429 { throw AIProviderError.rateLimited }
            throw AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
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
        !key.isEmpty
    }
}
