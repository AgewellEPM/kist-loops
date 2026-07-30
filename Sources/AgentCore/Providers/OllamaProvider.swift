import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// Local Ollama provider (`/api/chat`). No auth — talks to a server on the same
/// machine. Mirrors `OpenAICompatibleProvider`'s stream lifecycle, but Ollama
/// emits NDJSON (newline-delimited JSON objects), NOT SSE: each line is a full
/// JSON object like `{"message":{"role":"assistant","content":"..."},"done":false}`.
public struct OllamaProvider: ChatProvider {
    public let id = "ollama"
    public let name = "Ollama (local)"
    public let iconName = "desktopcomputer"
    /// Local server — needs no key.
    public let requiresAPIKey = false
    /// Kept for parity with the keyed providers; unused (no auth header sent).
    public let keyAccount = "ollama_api_key"
    public let defaultModel = "llama3.1"
    public let availableModels: [AIModel] = [
        AIModel(id: "llama3.1", name: "Llama 3.1", displayName: "Llama 3.1", isLocal: true),
        AIModel(id: "deepseek-coder:6.7b", name: "DeepSeek Coder 6.7B", displayName: "DeepSeek Coder 6.7B", isLocal: true),
        AIModel(id: "qwen2.5-coder", name: "Qwen2.5 Coder", displayName: "Qwen2.5 Coder", isLocal: true),
    ]

    public init() {}

    /// Endpoint — `http://localhost:11434/api/chat`, overridable via `OLLAMA_HOST`
    /// (e.g. `OLLAMA_HOST=http://192.168.1.5:11434`).
    public var endpoint: String {
        if let host = ProcessInfo.processInfo.environment["OLLAMA_HOST"], !host.isEmpty {
            return "\(host)/api/chat"
        }
        return "http://localhost:11434/api/chat"
    }

    /// Liveness-probe URL so a fan-out (wide council) can skip Ollama when the daemon isn't running,
    /// instead of wasting a panel slot. Local by definition unless OLLAMA_HOST points elsewhere.
    public var healthProbeURL: String? { endpoint }

    /// Build the request body — pure/testable.
    public func makeBody(messages: [ChatMessage], model: String, settings: ModelSettings) -> [String: Any] {
        var apiMessages: [[String: Any]] = []
        if !settings.systemPrompt.isEmpty {
            apiMessages.append(["role": "system", "content": settings.systemPrompt])
        }
        for m in messages where m.role != .system {
            apiMessages.append(["role": m.role == .assistant ? "assistant" : "user", "content": m.content])
        }
        var options: [String: Any] = [
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "num_predict": settings.maxTokens,   // honor the caller's token cap
        ]
        // Forward caller-supplied stop sequences (a local model's turn-end tokens) so generation halts
        // at the real turn boundary instead of running on.
        if !settings.stopSequences.isEmpty { options["stop"] = settings.stopSequences }
        return [
            "model": model,
            "messages": apiMessages,
            "stream": true,
            "options": options,
        ]
    }

    /// Parse one NDJSON line (a complete JSON object) into stream events.
    /// `message.content` -> `.delta`; `done:true` -> `.finish` (+ `.usage` if
    /// `prompt_eval_count`/`eval_count` are present). No `data:` prefix to strip.
    public static func events(fromLine jsonString: String) -> [StreamEvent] {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [StreamEvent] = []
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String, !content.isEmpty {
            out.append(.delta(content))
        }
        if let done = json["done"] as? Bool, done {
            if json["prompt_eval_count"] != nil || json["eval_count"] != nil {
                out.append(.usage(promptTokens: json["prompt_eval_count"] as? Int ?? 0,
                                  completionTokens: json["eval_count"] as? Int ?? 0))
            }
            out.append(.finish(reason: nil))
        }
        return out
    }

    public func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        // apiKey intentionally ignored — local server, no auth header.
        guard let url = URL(string: endpoint) else { throw AIProviderError.configuration("bad endpoint \(endpoint)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: makeBody(messages: messages, model: model, settings: settings))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        if http.statusCode == 429 { throw AIProviderError.rateLimited }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw AIProviderError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines {
                        for event in Self.events(fromLine: line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    // Consumer stopped — end cleanly.
                    continuation.finish()
                } catch let e as AIProviderError {
                    continuation.finish(throwing: e)
                } catch {
                    // Connection refused (server down) and other raw URL errors land here.
                    continuation.finish(throwing: AIProviderError.transport(error.localizedDescription))
                }
            }
            // Cancel the in-flight HTTP stream when the consumer stops.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
