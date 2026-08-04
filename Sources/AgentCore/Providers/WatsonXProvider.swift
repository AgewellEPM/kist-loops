import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // Linux: URLSession lives here
#endif

/// IBM watsonx.ai (foundation-model chat) as an AgentCore `ChatProvider`.
///
/// watsonx is NOT OpenAI-drop-in, so it can't ride `OpenAICompatibleProvider`:
///  1. **Auth is a two-step IAM exchange.** You POST your API key to IBM IAM
///     (`iam.cloud.ibm.com/identity/token`) and get a bearer token that lives
///     ~1h; you refresh it, you don't send the raw key. (`WatsonXTokenCache`.)
///  2. **`project_id` is required** in every request body — a second secret
///     beyond the API key. Read from `WATSONX_PROJECT_ID` (or `WATSONX_SPACE_ID`).
///  3. **Region base URL + `?version=` param + non-OpenAI paths.** Base from
///     `WATSONX_URL` (default us-south); the chat path is `/ml/v1/text/chat_stream`.
///
/// The wire shape is otherwise close to OpenAI: `messages:[{role,content}]` in,
/// SSE `data:` chunks with `choices[0].delta.content` out. Body construction
/// (`makeBody`) and SSE parsing (`events(fromSSE:)`) are pure/static so they're
/// unit-testable without a network round-trip — mirrors GeminiProvider.
///
/// Routed through the UNIVERSAL TEXT tool-protocol (`supportsNativeTools` stays
/// false): watsonx's native `tools` support varies by model and is fragile on
/// multi-turn tool histories (the same class of break as MiMo/DeepSeek). The
/// text protocol exposes the SAME tools serialized as text, so Watson still
/// "thinks" with full tool access and never dies on round 2. Honest fallback.
public struct WatsonXProvider: ChatProvider {
    public let id = "watsonx"
    public let name = "watsonx (IBM)"
    public let iconName = "cpu"
    public let requiresAPIKey = true
    public let keyAccount = "watsonx_api_key"
    // A strong hosted reasoner by default — the "hand the thinking to Watson" case.
    // Any id here is overridable with `/model watsonx:<id>` or `WATSONX_MODEL`.
    public let defaultModel = "meta-llama/llama-3-3-70b-instruct"

    public let availableModels: [AIModel] = [
        AIModel(id: "meta-llama/llama-3-3-70b-instruct", displayName: "Llama 3.3 70B (watsonx)", contextWindowTokens: 128_000),
        AIModel(id: "mistralai/mistral-large", displayName: "Mistral Large (watsonx)", contextWindowTokens: 128_000),
        AIModel(id: "ibm/granite-3-8b-instruct", displayName: "Granite 3 8B (watsonx)", contextWindowTokens: 128_000),
        AIModel(id: "meta-llama/llama-3-2-90b-vision-instruct", displayName: "Llama 3.2 90B Vision (watsonx)", isVision: true, contextWindowTokens: 128_000),
    ]

    /// The API version pin watsonx requires on every call. A dated contract; bumping it is a
    /// deliberate, testable change (not a silent drift).
    static let apiVersion = "2024-10-08"

    public init() {}

    // MARK: - Config resolved from the environment (project_id / region are NOT the API key)

    /// The region base URL (`https://us-south.ml.cloud.ibm.com` by default). Overridable per IBM
    /// Cloud region via `WATSONX_URL`. HTTPS is required — a plaintext override is refused fail-fast.
    static func baseURL(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let raw = (env["WATSONX_URL"] ?? "").trimmingCharacters(in: .whitespaces)
        let base = raw.isEmpty ? "https://us-south.ml.cloud.ibm.com" : raw
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The IAM token-exchange endpoint. Overridable (e.g. IBM Cloud staging) via `WATSONX_IAM_URL`.
    static func iamURL(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let raw = (env["WATSONX_IAM_URL"] ?? "").trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "https://iam.cloud.ibm.com/identity/token" : raw
    }

    /// The scoping id watsonx requires in the body. A project id wins; a space id is the alternative.
    /// Returns the (bodyKey, value) pair, or nil if neither is set (caller fails fast with guidance).
    static func scope(env: [String: String] = ProcessInfo.processInfo.environment) -> (key: String, value: String)? {
        if let p = env["WATSONX_PROJECT_ID"]?.trimmingCharacters(in: .whitespaces), !p.isEmpty { return ("project_id", p) }
        if let s = env["WATSONX_SPACE_ID"]?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return ("space_id", s) }
        return nil
    }

    // MARK: - Request body (pure / testable)

    /// Map our neutral `ChatMessage`s to watsonx `messages`. Roles map straight (system/user/assistant);
    /// a `.tool` result is folded into a user turn (text protocol carries tool output as text anyway).
    static func wireMessages(_ messages: [ChatMessage]) -> [[String: Any]] {
        messages.map { m in
            let role: String
            switch m.role {
            case .system: role = "system"
            case .assistant: role = "assistant"
            case .user, .tool: role = "user"
            }
            return ["role": role, "content": m.content]
        }
    }

    /// The chat_stream request body. `scope` is the (project_id|space_id, value) pair. Pure so the
    /// contract — model_id, scope, params — is unit-testable without a live IAM token.
    static func makeBody(messages: [ChatMessage], model: String, scope: (key: String, value: String),
                         settings: ModelSettings) -> [String: Any] {
        var body: [String: Any] = [
            "model_id": model,
            scope.key: scope.value,
            "messages": wireMessages(messages),
            "max_tokens": effectiveMaxTokens(model: model, settings: settings),
            "temperature": settings.temperature,
            "top_p": settings.topP,
        ]
        if let seed = settings.seed { body["seed"] = seed }
        if !settings.stopSequences.isEmpty { body["stop"] = settings.stopSequences }
        return body
    }

    /// A reasoning model needs headroom so the thinking + the visible answer both fit; a caller asking
    /// for a short answer would otherwise get an empty completion. Mirrors the OpenAI-compat floor.
    static let reasoningTokenFloor = 8000
    static func effectiveMaxTokens(model: String, settings: ModelSettings) -> Int {
        guard !settings.disableThinking, modelLooksLikeReasoning(model) else { return settings.maxTokens }
        return max(settings.maxTokens, reasoningTokenFloor)
    }

    static func modelLooksLikeReasoning(_ model: String) -> Bool {
        let m = model.lowercased()
        return ["70b", "90b", "large", "reason", "thinking", "granite-3"].contains { m.contains($0) }
    }

    // MARK: - SSE parsing (pure / testable)

    /// Parse one watsonx SSE `data:` payload into `StreamEvent`s. Shape mirrors OpenAI:
    /// `choices[0].delta.content` (text), optional `usage`. `[DONE]`/empty are ignored.
    static func events(fromSSE payload: String) -> [StreamEvent] {
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "[DONE]",
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var out: [StreamEvent] = []
        if let choices = obj["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any], let text = delta["content"] as? String, !text.isEmpty {
                out.append(.delta(text))
            }
            if let reason = first["finish_reason"] as? String, !reason.isEmpty {
                out.append(.finish(reason: reason))
            }
        }
        if let usage = obj["usage"] as? [String: Any] {
            let p = (usage["prompt_tokens"] as? Int) ?? 0
            let c = (usage["completion_tokens"] as? Int) ?? 0
            if p != 0 || c != 0 { out.append(.usage(promptTokens: p, completionTokens: c)) }
        }
        return out
    }

    // MARK: - Capabilities

    public func capabilities(forModel model: String) -> ModelCapabilities {
        let modelId = resolvedModel(model)
        let meta = availableModels.first { $0.id == modelId || $0.name == modelId }
        return ModelCapabilities(
            nativeTools: false,                                   // universal text protocol (see type doc)
            vision: meta?.isVision ?? false,
            reasoning: Self.modelLooksLikeReasoning(modelId),
            contextWindowTokens: meta?.contextWindowTokens
        )
    }

    // MARK: - Stream

    public func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let apiKey, !apiKey.isEmpty else { throw AIProviderError.missingAPIKey(provider: id) }
        guard let scope = Self.scope() else {
            throw AIProviderError.configuration(
                "watsonx needs a project (or space) id — set WATSONX_PROJECT_ID (or WATSONX_SPACE_ID). "
              + "Find it in the IBM Cloud watsonx project's Manage → General page.")
        }

        // Mint/refresh the short-lived IAM bearer token (cached per API key).
        let token = try await WatsonXTokenCache.shared.token(apiKey: apiKey, iamURL: Self.iamURL())

        let modelId = resolvedModel(model)
        let urlString = "\(Self.baseURL())/ml/v1/text/chat_stream?version=\(Self.apiVersion)"
        guard let url = URL(string: urlString) else { throw AIProviderError.configuration("bad endpoint \(urlString)") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.makeBody(messages: messages, model: modelId, scope: scope, settings: settings))

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        if http.statusCode == 401 || http.statusCode == 403 {
                            // Stale/invalid token → drop the cache so the next attempt re-mints.
                            await WatsonXTokenCache.shared.invalidate(apiKey: apiKey)
                            throw AIProviderError.invalidAPIKey
                        }
                        if http.statusCode == 429 { throw AIProviderError.rateLimited }
                        var body = ""
                        for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                        throw AIProviderError.http(status: http.statusCode, body: body)
                    }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        for event in Self.events(fromSSE: payload) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let e as AIProviderError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: AIProviderError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Caches the IBM IAM bearer token so we exchange the API key at most once per ~hour, not per request.
/// An actor for thread-safe access from concurrent streams; keyed by API key so multiple accounts are
/// isolated. Refreshes when the token is within a 5-minute skew of expiry.
actor WatsonXTokenCache {
    static let shared = WatsonXTokenCache()

    private struct Entry { let token: String; let expiresAt: Date }
    private var cache: [String: Entry] = [:]
    private static let skew: TimeInterval = 300   // refresh 5 min before expiry

    /// A live token for `apiKey`, exchanging with IAM only when the cache is empty or near-expiry.
    func token(apiKey: String, iamURL: String) async throws -> String {
        if let e = cache[apiKey], e.expiresAt.timeIntervalSinceNow > Self.skew { return e.token }
        let (token, expiresAt) = try await Self.exchange(apiKey: apiKey, iamURL: iamURL)
        cache[apiKey] = Entry(token: token, expiresAt: expiresAt)
        return token
    }

    /// Drop a cached token (called on a 401/403 so the next request re-mints).
    func invalidate(apiKey: String) { cache[apiKey] = nil }

    /// POST the API key to IAM and parse `{access_token, expiration|expires_in}`. `expiration` is an
    /// absolute epoch; `expires_in` is relative — prefer the absolute, fall back to now+relative,
    /// then a conservative 50-minute default so a malformed body can't wedge a never-expiring token.
    static func exchange(apiKey: String, iamURL: String) async throws -> (token: String, expiresAt: Date) {
        guard let url = URL(string: iamURL) else { throw AIProviderError.configuration("bad IAM url \(iamURL)") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let form = "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=\(iamEncode(apiKey))"
        request.httpBody = form.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 400 || http.statusCode == 401 { throw AIProviderError.invalidAPIKey }
            throw AIProviderError.http(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty else {
            throw AIProviderError.invalidResponse("watsonx IAM: no access_token in response")
        }
        let expiresAt: Date
        if let exp = obj["expiration"] as? TimeInterval { expiresAt = Date(timeIntervalSince1970: exp) }
        else if let rel = obj["expires_in"] as? TimeInterval { expiresAt = Date(timeIntervalSinceNow: rel) }
        else { expiresAt = Date(timeIntervalSinceNow: 3000) }
        return (token, expiresAt)
    }

    /// Percent-encode the API key for the form body (it can contain `+`/`/` that must not be lost).
    private static func iamEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
