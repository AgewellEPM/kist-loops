import Foundation

final class MLXProvider: AIProvider {
    let id = "mlx"
    let name = "MLX Local"
    let iconName = "apple.logo"
    let supportsStreaming = true
    var supportsVision: Bool { selectedModel?.isVision ?? false }
    let requiresAPIKey = false
    let apiKeySettingKey = ""
    let isLocal = true

    private var baseURL: String {
        UserDefaults.standard.string(forKey: "mlx_base_url") ?? "http://localhost:8080"
    }

    var availableModels: [AIModel] = []

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting. Honors any model id.
    var modelOverride: String?

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override } ?? AIModel(id: override, name: override)
            }
            let modelId = UserDefaults.standard.string(forKey: "mlx_model") ?? ""
            if modelId.isEmpty {
                return availableModels.first
            }
            return availableModels.first { $0.id == modelId } ?? availableModels.first
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.id, forKey: "mlx_model")
            }
        }
    }

    // Common MLX models (shown when server not reachable)
    static let defaultModels: [AIModel] = [
        AIModel(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", name: "Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B", isLocal: true, size: "2GB"),
        AIModel(id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit", name: "Mistral-7B-Instruct-v0.3-4bit", displayName: "Mistral 7B", isLocal: true, size: "4GB"),
        AIModel(id: "mlx-community/gemma-2-9b-it-4bit", name: "gemma-2-9b-it-4bit", displayName: "Gemma 2 9B", isLocal: true, size: "5GB"),
        AIModel(id: "mlx-community/Qwen2.5-7B-Instruct-4bit", name: "Qwen2.5-7B-Instruct-4bit", displayName: "Qwen 2.5 7B", isLocal: true, size: "4GB"),
        AIModel(id: "mlx-community/Phi-3.5-mini-instruct-4bit", name: "Phi-3.5-mini-instruct-4bit", displayName: "Phi 3.5 Mini", isLocal: true, size: "2GB"),
        // Code-specialized (if available in mlx-community)
        AIModel(id: "mlx-community/DeepSeek-Coder-V2-Lite-Instruct-4bit", name: "DeepSeek-Coder-V2-Lite-Instruct-4bit", displayName: "DeepSeek Coder V2 Lite", isLocal: true, size: "?"),
        AIModel(id: "mlx-community/codellama-7b-instruct-4bit", name: "codellama-7b-instruct-4bit", displayName: "Code Llama 7B", isLocal: true, size: "?"),
        AIModel(id: "mlx-community/llava-1.5-7b-4bit", name: "llava-1.5-7b-4bit", displayName: "LLaVA 1.5 7B (Vision)", isVision: true, isLocal: true, size: "4GB"),
        AIModel(id: "mlx-community/Qwen2-VL-7B-Instruct-4bit", name: "Qwen2-VL-7B-Instruct-4bit", displayName: "Qwen2 VL 7B (Vision)", isVision: true, isLocal: true, size: "4GB")
    ]

    init() {
        // Load cached models or use defaults
        if let data = UserDefaults.standard.data(forKey: "mlx_cached_models"),
           let models = try? JSONDecoder().decode([AIModel].self, from: data) {
            self.availableModels = models
        } else {
            self.availableModels = Self.defaultModels
        }
    }

    func refreshModels() async -> [AIModel] {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return availableModels }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return availableModels
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["data"] as? [[String: Any]] {
                let aiModels = models.compactMap { modelInfo -> AIModel? in
                    guard let id = modelInfo["id"] as? String else { return nil }

                    let isVision = id.lowercased().contains("llava") ||
                                   id.lowercased().contains("vision") ||
                                   id.lowercased().contains("-vl")

                    return AIModel(
                        id: id,
                        name: id,
                        displayName: id.components(separatedBy: "/").last ?? id,
                        isVision: isVision,
                        isLocal: true
                    )
                }

                if !aiModels.isEmpty {
                    self.availableModels = aiModels

                    // Cache models
                    if let data = try? JSONEncoder().encode(aiModels) {
                        UserDefaults.standard.set(data, forKey: "mlx_cached_models")
                    }

                    return aiModels
                }
            }
        } catch {
            print("Failed to fetch MLX models: \(error)")
        }

        return availableModels
    }

    func checkStatus() async -> Bool {
        guard let url = URL(string: "\(baseURL)/v1/models") else { return false }

        do {
            let (_, response) = try await URLSession.shared.data(from: url)
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
        // Check if server is running, try to start it if not
        var isRunning = await checkStatus()

        if !isRunning {
            // Try to auto-start the server
            let serverManager = await MLXServerManager.shared
            let modelId = selectedModel?.id ?? "mlx-community/Llama-3.2-3B-Instruct-4bit"

            if await serverManager.isMLXInstalled() {
                isRunning = await serverManager.startServer(model: modelId)
            }
        }

        guard isRunning else {
            throw AIProviderError.serverNotRunning
        }

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

        var request = URLRequest(url: URL(string: "\(baseURL)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "messages": apiMessages,
            "stream": stream,
            "max_tokens": settings.maxTokens,
            "temperature": settings.temperature,
            "top_p": settings.topP
        ]

        // Add model if selected
        if let model = selectedModel {
            body["model"] = model.id
        }

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
            throw AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode) - Is MLX server running?")
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
        return true
    }
}
