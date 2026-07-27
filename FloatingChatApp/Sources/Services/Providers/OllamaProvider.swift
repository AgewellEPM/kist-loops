import Foundation

final class OllamaProvider: AIProvider {
    let id = "ollama"
    let name = "Ollama"
    let iconName = "desktopcomputer"
    let supportsStreaming = true
    let requiresAPIKey = false
    let apiKeySettingKey = ""
    let isLocal = true

    private var baseURL: String {
        UserDefaults.standard.string(forKey: "ollama_base_url") ?? "http://localhost:11434"
    }

    var availableModels: [AIModel] = []

    /// Per-instance model override (set from the agent's configured model). Takes
    /// precedence over the global default WITHOUT persisting. Honors any model id.
    var modelOverride: String?

    var selectedModel: AIModel? {
        get {
            if let override = modelOverride, !override.isEmpty {
                return availableModels.first { $0.id == override || $0.name == override } ?? AIModel(id: override, name: override)
            }
            let modelName = UserDefaults.standard.string(forKey: "ollama_model") ?? "deepseek-coder:6.7b"
            return availableModels.first { $0.name == modelName } ?? AIModel(id: modelName, name: modelName, isLocal: true)
        }
        set {
            if let model = newValue {
                UserDefaults.standard.set(model.name, forKey: "ollama_model")
            }
        }
    }

    init() {
        // Load cached models
        if let data = UserDefaults.standard.data(forKey: "ollama_cached_models"),
           let models = try? JSONDecoder().decode([AIModel].self, from: data) {
            self.availableModels = models
        }
    }

    func refreshModels() async -> [AIModel] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return availableModels }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                let aiModels = models.compactMap { modelInfo -> AIModel? in
                    guard let name = modelInfo["name"] as? String else { return nil }
                    let size = modelInfo["size"] as? Int
                    let sizeStr = size.map { formatBytes($0) }

                    // Detect vision models (expanded list)
                    let lname = name.lowercased()
                    let visionKeywords = [
                        "llava", "vision", "bakllava", "vl", "-vl-",
                        "qwen2-vl", "qwen2.5-vl", "moondream", "minicpm",
                        "idefics", "pixtral", "llama-3.2-vision", "llama3.2-vision",
                        "phi-3-vision", "phi3-vision", "deepseek-vl"
                    ]
                    let isVision = visionKeywords.contains { lname.contains($0) }

                    return AIModel(
                        id: name,
                        name: name,
                        displayName: name.components(separatedBy: ":").first ?? name,
                        isVision: isVision,
                        isLocal: true,
                        size: sizeStr
                    )
                }
                self.availableModels = aiModels

                // Cache models
                if let data = try? JSONEncoder().encode(aiModels) {
                    UserDefaults.standard.set(data, forKey: "ollama_cached_models")
                }

                return aiModels
            }
        } catch {
            print("Failed to fetch Ollama models: \(error)")
        }
        return availableModels
    }

    func checkStatus() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }

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
        // Preflight: ensure the local server is reachable to avoid connection-refused spam
        let reachable = await checkStatus()
        if !reachable {
            throw AIProviderError.unknown(message: "Ollama server not reachable at \(baseURL). Start Ollama (e.g. 'ollama run <model>') or update the URL in Settings.")
        }

        let modelName = selectedModel?.name ?? "llama3.2"

        var apiMessages: [[String: Any]] = []

        // Add system message if present
        if !settings.systemPrompt.isEmpty {
            apiMessages.append([
                "role": "system",
                "content": settings.systemPrompt
            ])
        }

        for message in messages {
            if message.hasImage, let imageData = message.imageData {
                // Vision message with image
                apiMessages.append([
                    "role": message.role.rawValue,
                    "content": message.content,
                    "images": [imageData.base64EncodedString()]
                ])
            } else {
                apiMessages.append([
                    "role": message.role.rawValue,
                    "content": message.content
                ])
            }
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/api/chat")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": modelName,
            "messages": apiMessages,
            "stream": stream,
            "options": [
                "temperature": settings.temperature,
                "top_p": settings.topP,
                "top_k": settings.topK,
                "num_predict": settings.maxTokens,
                "repeat_penalty": settings.repeatPenalty
            ]
        ]

        if let seed = settings.seed {
            var options = body["options"] as? [String: Any] ?? [:]
            options["seed"] = seed
            body["options"] = options
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
            throw AIProviderError.unknown(message: "HTTP \(httpResponse.statusCode)")
        }

        for try await line in bytes.lines {
            if let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = json["message"] as? [String: Any],
               let content = message["content"] as? String {
                continuation.yield(content)
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
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIProviderError.invalidResponse
        }

        return content
    }

    func validateAPIKey(_ key: String) async -> Bool {
        return true
    }

    private func formatBytes(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 {
            return String(format: "%.1fGB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        return String(format: "%.0fMB", mb)
    }
}
