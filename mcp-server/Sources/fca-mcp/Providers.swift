import Foundation

/// Provider config mirroring FloatingChatApp (endpoints, keychain accounts,
/// default models). Kept in sync with the app's providers so this MCP server
/// talks to the same models with the same keys.
struct Provider {
    enum Kind { case openAICompatible, anthropic, gemini }
    let id: String
    let name: String
    let kind: Kind
    let endpoint: String          // for openAI/anthropic; gemini builds per-model
    let keychainAccount: String
    let defaultModel: String
}

enum ProviderError: Error, CustomStringConvertible {
    case unknownProvider(String)
    case missingKey(String)
    case http(Int, String)
    case badResponse(String)
    var description: String {
        switch self {
        case .unknownProvider(let p): return "Unknown provider '\(p)'"
        case .missingKey(let p): return "No API key set for '\(p)' (add it in the FloatingChatApp wizard)"
        case .http(let c, let b): return "HTTP \(c): \(b.prefix(300))"
        case .badResponse(let s): return "Bad response: \(s.prefix(300))"
        }
    }
}

enum Providers {
    static let all: [Provider] = [
        Provider(id: "mimo", name: "MiMo (Xiaomi)", kind: .openAICompatible,
                 endpoint: "https://api.xiaomimimo.com/v1/chat/completions",
                 keychainAccount: "mimo_api_key", defaultModel: "mimo-v2.5-pro"),
        Provider(id: "zhipu", name: "GLM (Z.AI)", kind: .openAICompatible,
                 endpoint: "https://api.z.ai/api/paas/v4/chat/completions",
                 keychainAccount: "zhipu_api_key", defaultModel: "glm-5.2"),
        Provider(id: "moonshot", name: "Kimi (Moonshot)", kind: .openAICompatible,
                 endpoint: "https://api.moonshot.ai/v1/chat/completions",
                 keychainAccount: "moonshot_api_key", defaultModel: "kimi-k2-turbo-preview"),
        Provider(id: "deepseek", name: "DeepSeek", kind: .openAICompatible,
                 endpoint: "https://api.deepseek.com/chat/completions",
                 keychainAccount: "deepseek_api_key", defaultModel: "deepseek-v4-pro"),
        Provider(id: "openai", name: "OpenAI", kind: .openAICompatible,
                 endpoint: "https://api.openai.com/v1/chat/completions",
                 keychainAccount: "openai_api_key", defaultModel: "gpt-5.5"),
        Provider(id: "grok", name: "Grok (xAI)", kind: .openAICompatible,
                 endpoint: "https://api.x.ai/v1/chat/completions",
                 keychainAccount: "grok_api_key", defaultModel: "grok-4.3"),
        Provider(id: "anthropic", name: "Claude", kind: .anthropic,
                 endpoint: "https://api.anthropic.com/v1/messages",
                 keychainAccount: "anthropic_api_key", defaultModel: "claude-fable-5"),
        Provider(id: "gemini", name: "Gemini", kind: .gemini,
                 endpoint: "https://generativelanguage.googleapis.com/v1beta/models",
                 keychainAccount: "gemini_api_key", defaultModel: "gemini-3.1-pro")
    ]

    static func find(_ id: String) -> Provider? {
        all.first { $0.id == id || $0.name.lowercased() == id.lowercased() }
    }

    /// One-shot chat completion. Synchronous (blocks via semaphore) so the
    /// stdio JSON-RPC loop stays simple.
    static func chat(providerId: String, model: String?, system: String?, prompt: String, maxTokens: Int = 2048) throws -> String {
        guard let provider = find(providerId) else { throw ProviderError.unknownProvider(providerId) }
        guard let key = Keychain.get(provider.keychainAccount) else { throw ProviderError.missingKey(provider.id) }
        let modelId = (model?.isEmpty == false ? model! : provider.defaultModel)

        let request = try buildRequest(provider: provider, model: modelId, system: system, prompt: prompt, key: key, maxTokens: maxTokens)
        let (data, status) = syncSend(request)
        guard status == 200 else {
            throw ProviderError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        return try parseReply(provider: provider, data: data)
    }

    // MARK: - Request building

    private static func buildRequest(provider: Provider, model: String, system: String?, prompt: String, key: String, maxTokens: Int) throws -> URLRequest {
        switch provider.kind {
        case .openAICompatible:
            var msgs: [[String: Any]] = []
            if let system, !system.isEmpty { msgs.append(["role": "system", "content": system]) }
            msgs.append(["role": "user", "content": prompt])
            let body: [String: Any] = ["model": model, "messages": msgs, "stream": false, "max_tokens": maxTokens]
            return try jsonPOST(provider.endpoint, body: body, headers: ["Authorization": "Bearer \(key)"])

        case .anthropic:
            var body: [String: Any] = [
                "model": model, "max_tokens": maxTokens,
                "messages": [["role": "user", "content": prompt]]
            ]
            if let system, !system.isEmpty { body["system"] = system }
            return try jsonPOST(provider.endpoint, body: body,
                                headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])

        case .gemini:
            let urlStr = "\(provider.endpoint)/\(model):generateContent?key=\(key)"
            var body: [String: Any] = [
                "contents": [["role": "user", "parts": [["text": prompt]]]],
                "generationConfig": ["maxOutputTokens": maxTokens]
            ]
            if let system, !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
            return try jsonPOST(urlStr, body: body, headers: [:])
        }
    }

    private static func jsonPOST(_ urlString: String, body: [String: Any], headers: [String: String]) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw ProviderError.badResponse("bad URL \(urlString)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 110
        return req
    }

    // MARK: - Response parsing

    private static func parseReply(provider: Provider, data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        switch provider.kind {
        case .openAICompatible:
            if let choices = json["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any] {
                // content can be a String or an array of {type:text,text:...} parts.
                if let s = msg["content"] as? String, !s.isEmpty { return s }
                if let parts = msg["content"] as? [[String: Any]] {
                    let joined = parts.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty { return joined }
                }
            }
            throw ProviderError.badResponse("no visible content (reasoning model may have spent the budget — increase max_tokens)")
        case .anthropic:
            if let content = json["content"] as? [[String: Any]] {
                // Join ALL text blocks (skip thinking/tool blocks).
                let joined = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined()
                if !joined.isEmpty { return joined }
            }
            throw ProviderError.badResponse("no content")
        case .gemini:
            if let cands = json["candidates"] as? [[String: Any]],
               let parts = (cands.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined()
                if !text.isEmpty { return text }
            }
            throw ProviderError.badResponse("no content")
        }
    }

    // MARK: - Sync HTTP

    private static func syncSend(_ request: URLRequest) -> (Data, Int) {
        let sem = DispatchSemaphore(value: 0)
        var outData = Data()
        var status = 0
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let http = response as? HTTPURLResponse {
                outData = data ?? Data()
                status = http.statusCode
            } else {
                // Transport failure (incl. URLSession's own timeout): no HTTP
                // response. Surface a clear 504 instead of a bare "HTTP 0".
                status = 504
                outData = Data("transport error: \(error?.localizedDescription ?? "no response")".utf8)
            }
            sem.signal()
        }
        task.resume()
        // Bounded wait so a stuck request can never wedge the whole stdin loop.
        if sem.wait(timeout: .now() + 120) == .timedOut {
            task.cancel()
            return (Data("request timed out".utf8), 504)
        }
        return (outData, status)
    }
}
