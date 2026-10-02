import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// Local Ollama provider (`/api/chat`). No auth — talks to a server on the same
/// machine. Mirrors `OpenAICompatibleProvider`'s stream lifecycle, but Ollama
/// emits NDJSON (newline-delimited JSON objects), NOT SSE: each line is a full
/// JSON object like `{"message":{"role":"assistant","content":"..."},"done":false}`.
public struct OllamaProvider: ChatProvider {
    public let id: String
    public let name: String
    public let iconName = "desktopcomputer"
    /// Local server — needs no key.
    public let requiresAPIKey = false
    /// Kept for parity with the keyed providers; unused (no auth header sent).
    public let keyAccount = "ollama_api_key"
    public let defaultModel: String
    public let availableModels: [AIModel]
    public let automaticAcquisition: Bool
    /// The packaged launcher owns a smaller allocation than the publisher's maximum.
    public let runtimeContextTokens: Int?
    public var supportsNativeTools: Bool { id == "ollama" }

    /// Only templates with a known Ollama tool contract opt into native calls. Custom models
    /// retain the text protocol; --tools native remains an explicit way to probe them.
    public func capabilities(forModel model: String) -> ModelCapabilities {
        let family = model.lowercased().split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let meta = availableModels.first { $0.id == model || $0.name == model }
        // qwen2.5-coder:7b advertises tools in /api/show but our live Ollama 0.32.3 canary
        // returned the call as content, not message.tool_calls. Keep it on the text path.
        let known = id == "ollama" && ["qwen3-vl", "qwen3.5"].contains(family)
        let publishedContext = meta?.contextWindowTokens ?? (known ? 16_384 : nil)
        let context = runtimeContextTokens.map { min($0, publishedContext ?? $0) } ?? publishedContext
        return ModelCapabilities(nativeTools: known,
                                 vision: id == "ollama" && (known || meta?.isVision == true),
                                 reasoning: known && family == "qwen3.5",
                                 contextWindowTokens: context,
                                 structuredOutput: known || (id == "ollama" && family == "qwen2.5-coder"))
    }

    /// Default construction is the generic local Ollama provider (id "ollama"). The identity is
    /// parameterizable so a SPECIALIST local model can be a first-class provider over the same
    /// NDJSON transport — e.g. `.cobol()` exposes the offline `cobol-jeeves` COBOL model as
    /// `-p cobol` without a second copy of the stream lifecycle.
    public init(id: String = "ollama",
                name: String = "Ollama (local)",
                defaultModel: String = "llama3.1",
                availableModels: [AIModel] = [
                    AIModel(id: "qwen3.5:9b-q4_K_M", displayName: "Qwen3.5 9B Q4 · local", isVision: true, isLocal: true, contextWindowTokens: 16_384),
                    AIModel(id: "qwen3-vl:4b-instruct", displayName: "Qwen3-VL 4B · local", isVision: true, isLocal: true, contextWindowTokens: 16_384),
                    AIModel(id: "llama3.1", name: "Llama 3.1", displayName: "Llama 3.1", isLocal: true),
                    AIModel(id: "deepseek-coder:6.7b", name: "DeepSeek Coder 6.7B", displayName: "DeepSeek Coder 6.7B", isLocal: true),
                    AIModel(id: "qwen2.5-coder", name: "Qwen2.5 Coder", displayName: "Qwen2.5 Coder", isLocal: true),
                ], automaticAcquisition: Bool = false,
                runtimeContextTokens: Int? = ProcessInfo.processInfo.environment["KIST_LOCAL_CONTEXT_TOKENS"].flatMap(Int.init)) {
        self.id = id
        self.name = name
        self.defaultModel = defaultModel
        self.availableModels = availableModels
        self.automaticAcquisition = automaticAcquisition
        self.runtimeContextTokens = runtimeContextTokens.flatMap { (256...131_072).contains($0) ? $0 : nil }
    }

    /// The offline COBOL specialist: the locally fine-tuned `cobol-jeeves` model served by Ollama.
    /// First-class so `kist -p cobol` just works with no network. NOT in the default rotation (it
    /// only knows COBOL); pick it explicitly.
    public static func cobol() -> OllamaProvider {
        OllamaProvider(
            id: "cobol",
            name: "COBOL (offline · cobol-jeeves)",
            defaultModel: "cobol-jeeves-ft:latest",
            availableModels: [
                AIModel(id: "cobol-jeeves-ft:latest", name: "cobol-jeeves (fine-tuned)",
                        displayName: "COBOL Jeeves · fine-tuned", isLocal: true),
                AIModel(id: "cobol-jeeves:latest", name: "cobol-jeeves (base)",
                        displayName: "COBOL Jeeves · base", isLocal: true),
            ])
    }

    /// Endpoint — `http://localhost:11434/api/chat`, overridable via `OLLAMA_HOST`
    /// (e.g. `OLLAMA_HOST=http://192.168.1.5:11434`).
    public var endpoint: String {
        if let host = ProcessInfo.processInfo.environment["OLLAMA_HOST"], !host.isEmpty {
            return "\(host.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/api/chat"
        }
        // The COBOL specialist is contractually loopback-only. Keep other Ollama providers'
        // legacy default unchanged, but make the specialist's unset-host route numeric so its
        // provenance cannot depend on hostname resolution.
        return id == "cobol"
            ? "http://127.0.0.1:11434/api/chat"
            : "http://localhost:11434/api/chat"
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
        for m in messages where m.role != .system || settings.systemPrompt.isEmpty {
            let role = m.role == .assistant ? "assistant" : (m.role == .system ? "system" : "user")
            var message: [String: Any] = ["role": role, "content": m.content]
            if m.role == .user, capabilities(forModel: model).vision {
                let images = m.allAttachments.filter { $0.kind == .image }.compactMap { $0.inlineData?.base64EncodedString() }
                if !images.isEmpty { message["images"] = images }
            }
            apiMessages.append(message)
        }
        var options: [String: Any] = [
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "num_predict": settings.maxTokens,   // honor the caller's token cap
        ]
        // This is the runtime allocation, not the publisher's maximum context. Keep the host's
        // capsule budget and Ollama's KV-cache allocation in agreement on a 16 GB machine.
        if let context = capabilities(forModel: model).contextWindowTokens, context > 0 {
            options["num_ctx"] = context
        }
        // Forward caller-supplied stop sequences (a local model's turn-end tokens) so generation halts
        // at the real turn boundary instead of running on.
        if !settings.stopSequences.isEmpty { options["stop"] = settings.stopSequences }
        if let seed = settings.seed { options["seed"] = seed }
        if let topK = settings.topK { options["top_k"] = topK }
        var body: [String: Any] = [
            "model": model,
            "messages": apiMessages,
            "stream": true,
            // A daemon can stay available without keeping model weights resident. Ollama
            // loads on demand and releases this request's model when inference finishes.
            // The scheduler owns concurrent users; never kill or unload another client's work.
            "keep_alive": 0,
            "options": options,
        ]
        if let schema = settings.decodedJSONSchema() { body["format"] = schema }
        else if settings.jsonOutput { body["format"] = "json" }
        // Unknown/custom models may reject `think`; only send it for the proven switchable family.
        if capabilities(forModel: model).reasoning, settings.disableThinking { body["think"] = false }
        return body
    }

    /// Parse one NDJSON line (a complete JSON object) into stream events.
    /// `message.content` -> `.delta`; `done:true` -> `.finish` (+ `.usage` if
    /// `prompt_eval_count`/`eval_count` are present). No `data:` prefix to strip.
    public static func events(fromLine jsonString: String) -> [StreamEvent] {
        var decoder = OllamaStreamDecoder()
        return (try? decoder.consume(jsonString)) ?? []
    }

    /// Disk preparation is separate from an inference deadline; a first download can take
    /// minutes without loading any weights onto the GPU. Its own acquisition limit applies.
    public func prepareModel(_ model: String) async throws {
        if automaticAcquisition {
            try await OllamaModelAcquisition.shared.ensure(model: model, endpoint: endpoint)
        }
    }

    public func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        try validateMedia(messages: messages, model: model)
        return try await streamBody(makeBody(messages: messages, model: model, settings: settings))
    }

    public func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings,
                            apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        try validateMedia(messages: messages, model: model)
        return try await streamBody(makeBodyTools(messages: messages, model: model, settings: settings, tools: tools))
    }

    private func streamBody(_ body: [String: Any]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        try validateContextEstimate(body)
        if let url = URL(string: endpoint), ManagedLocalModel.isLoopback(url) {
            let memory = LocalModelMemory.current()
            let candidate = automaticAcquisition ? ManagedLocalModel.lookup(body["model"] as? String ?? "") : nil
            if memory.requestBudgetBytes == 0
                || candidate.map({ UInt64($0.maximumDownloadBytes) >= memory.requestBudgetBytes }) == true {
                throw LocalModelAdmission.blocked(model: body["model"] as? String ?? "",
                    memory: memory, context: runtimeContextTokens ?? 4096,
                    reason: memory.admissionBlocker ?? "acquisition size exceeds the current memory budget").providerError
            }
        }
        if let model = body["model"] as? String {
            try await prepareModel(model)
        }
        let body = try await admittedBody(body)
        // apiKey intentionally ignored — local server, no auth header.
        guard let url = URL(string: endpoint) else { throw AIProviderError.configuration("bad endpoint \(endpoint)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
                    var decoder = OllamaStreamDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        for event in try decoder.consume(line) { continuation.yield(event) }
                        if decoder.finished { break }
                    }
                    try decoder.validateCompletion()
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
