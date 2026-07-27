import Foundation

final class DeepSeekProvider: AIProvider {
    let id = "deepseek"
    let name = "DeepSeek"
    let iconName = "bolt.fill"
    let supportsStreaming = true
    let supportsVision = false
    let requiresAPIKey = true
    let apiKeySettingKey = "deepseek_api_key"
    let isLocal = false

    private var apiKey: String {
        KeychainService.shared.get(key: apiKeySettingKey) ?? ""
    }

    private let baseURL = "https://api.deepseek.com/v1/chat/completions"
    private let fimBaseURL = "https://api.deepseek.com/beta/completions"

    var availableModels: [AIModel] = [
        AIModel(id: "deepseek-v4-pro", name: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro"),
        AIModel(id: "deepseek-v4", name: "deepseek-v4", displayName: "DeepSeek V4"),
        AIModel(id: "deepseek-v4-flash", name: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash"),
        AIModel(id: "deepseek-chat", name: "deepseek-chat", displayName: "DeepSeek Chat (deprecated)"),
        AIModel(id: "deepseek-reasoner", name: "deepseek-reasoner", displayName: "DeepSeek Reasoner (deprecated)")
    ]

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting. Honors any model id.
    var modelOverride: String?

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "deepseek_model") ?? "deepseek-v4-pro"
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "deepseek_model")
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

        let modelId = selectedModel?.id ?? "deepseek-v4-pro"
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

    // MARK: - Fill-in-Middle (FIM) for Code Completion

    func fillInMiddle(prefix: String, suffix: String, maxTokens: Int = 4096) async throws -> String {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        guard let url = URL(string: fimBaseURL) else {
            throw AIProviderError.configurationError("Invalid FIM API URL: \(fimBaseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "deepseek-v4-pro",
            "prompt": prefix,
            "suffix": suffix,
            "max_tokens": maxTokens
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AIProviderError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let text = choices.first?["text"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return text
    }

    // MARK: - Function Calling

    func sendWithTools(
        messages: [ChatMessage],
        tools: [ToolDefinition],
        settings: ModelSettings
    ) async throws -> ToolCallResult {
        guard !apiKey.isEmpty else {
            throw AIProviderError.invalidAPIKey
        }

        var apiMessages: [[String: Any]] = []

        if !settings.systemPrompt.isEmpty {
            apiMessages.append([
                "role": "system",
                "content": settings.systemPrompt
            ])
        }

        for message in messages {
            apiMessages.append([
                "role": message.role.rawValue,
                "content": message.content
            ])
        }

        // Convert tools to API format
        let toolsArray: [[String: Any]] = tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": tool.parameters.type,
                        "properties": tool.parameters.properties.mapValues { prop in
                            ["type": prop.type, "description": prop.description]
                        },
                        "required": tool.parameters.required
                    ]
                ]
            ]
        }

        guard let url = URL(string: baseURL) else {
            throw AIProviderError.configurationError("Invalid API URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": selectedModel?.id ?? "deepseek-v4-pro",
            "messages": apiMessages,
            "tools": toolsArray,
            "tool_choice": "auto"
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw AIProviderError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIProviderError.invalidResponse
        }

        var toolCalls: [ToolCall] = []

        if let toolCallsArray = message["tool_calls"] as? [[String: Any]] {
            for call in toolCallsArray {
                if let id = call["id"] as? String,
                   let function = call["function"] as? [String: Any],
                   let name = function["name"] as? String,
                   let arguments = function["arguments"] as? String {
                    toolCalls.append(ToolCall(id: id, name: name, arguments: arguments))
                }
            }
        }

        let content = message["content"] as? String

        return ToolCallResult(toolCalls: toolCalls, content: content)
    }
}
