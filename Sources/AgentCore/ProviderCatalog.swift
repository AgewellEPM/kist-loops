import Foundation

/// The built-in providers AgentCore ships with. The OpenAI-compatible set includes a deep bench of
/// Chinese models (DeepSeek, MiMo, Qwen, Doubao, Hunyuan, ERNIE, Yi, GLM, Kimi, Step, Baichuan,
/// MiniMax), plus OpenAI, Grok, and local MLX. Anthropic, Gemini, and Ollama keep distinct wire shapes.
/// All remote providers are BYOK; set the matching *_API_KEY through env or Keychain.
public enum ProviderCatalog {
    /// Resolve a chat-completions endpoint from an optional base-URL override. When `base` is nil (or
    /// blank), fall back to `fallback`. Otherwise normalize `base` to a `…/chat/completions` URL: pass
    /// through if it already ends in that suffix, else trim trailing slashes and append it. Pure so the
    /// override contract is unit-testable — the live catalog reads the env once at static-init time.
    public static func resolveEndpoint(base: String?, fallback: String) -> String {
        guard let base = base?.trimmingCharacters(in: .whitespaces), !base.isEmpty else { return fallback }
        if base.hasSuffix("/chat/completions") { return base }
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
    }

    public static let openAICompatible: [OpenAICompatibleProvider] = [
        OpenAICompatibleProvider(
            id: "mimo", name: "MiMo (Xiaomi)", iconName: "cpu", keyAccount: "mimo_api_key",
            // Public pay-per-token API by default. A "Token Plan" subscription (tp-… key) is served
            // from a per-account DEDICATED base URL (e.g. token-plan-sgp.xiaomimimo.com) and 401s on
            // the public host — set MIMO_BASE_URL to that base (…/v1) to use it. Mirrors MOONDREAM_BASE_URL.
            endpoint: resolveEndpoint(base: ProcessInfo.processInfo.environment["MIMO_BASE_URL"],
                                      fallback: "https://api.xiaomimimo.com/v1/chat/completions"),
            defaultModel: "mimo-v2.5-pro",
            availableModels: [AIModel(id: "mimo-v2.5-pro", displayName: "MiMo V2.5 Pro", contextWindowTokens: 1_000_000),
                              AIModel(id: "mimo-v2.5", displayName: "MiMo V2.5 (Omni)", contextWindowTokens: 1_000_000)],
            // MiMo's native tools work for round 1 then 400 on tool-call history (XiaomiMiMo/MiMo#44,
            // open) — unusable for a multi-turn agent loop. Route it to the universal text protocol,
            // which exposes the SAME tools (read/search/grep/run) and works every round.
            nativeToolsSupported: false),
        OpenAICompatibleProvider(
            id: "zhipu", name: "GLM (Z.AI)", iconName: "sparkles", keyAccount: "zhipu_api_key",
            endpoint: "https://api.z.ai/api/paas/v4/chat/completions", defaultModel: "glm-5.2",
            availableModels: [AIModel(id: "glm-5.2", displayName: "GLM-5.2"),
                              AIModel(id: "glm-4.6", displayName: "GLM-4.6")]),
        OpenAICompatibleProvider(
            id: "moonshot", name: "Kimi (Moonshot)", iconName: "moon.stars.fill", keyAccount: "moonshot_api_key",
            endpoint: "https://api.moonshot.ai/v1/chat/completions", defaultModel: "kimi-k2-turbo-preview",
            availableModels: [AIModel(id: "kimi-k2-turbo-preview", displayName: "Kimi K2 Turbo"),
                              AIModel(id: "kimi-k2-0711-preview", displayName: "Kimi K2")]),
        OpenAICompatibleProvider(
            id: "deepseek", name: "DeepSeek", iconName: "brain", keyAccount: "deepseek_api_key",
            endpoint: "https://api.deepseek.com/chat/completions", defaultModel: "deepseek-v4-pro",
            availableModels: [AIModel(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro"),
                              AIModel(id: "deepseek-v4", displayName: "DeepSeek V4"),
                              AIModel(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash"),
                              AIModel(id: "deepseek-chat", displayName: "DeepSeek Chat (deprecated)"),
                              AIModel(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner (deprecated)")],
            // DeepSeek's OpenAI-compatible native tools path can reject multi-turn histories with
            // strict "tool_calls must be followed by tool messages" 400s. Default to Mythos's
            // universal text protocol; --tools native still exists for explicit experiments.
            nativeToolsSupported: false),
        // Chinese model APIs that follow the OpenAI-compatible chat/completions shape.
        OpenAICompatibleProvider(
            id: "qwen", name: "Qwen (Alibaba)", iconName: "cloud", keyAccount: "dashscope_api_key",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", defaultModel: "qwen-max",
            availableModels: [AIModel(id: "qwen-max", displayName: "Qwen Max"),
                              AIModel(id: "qwen-plus", displayName: "Qwen Plus"),
                              AIModel(id: "qwen-turbo", displayName: "Qwen Turbo"),
                              AIModel(id: "qwen2.5-72b-instruct", displayName: "Qwen2.5 72B")]),
        OpenAICompatibleProvider(
            id: "doubao", name: "Doubao (ByteDance)", iconName: "waveform", keyAccount: "ark_api_key",
            endpoint: "https://ark.cn-beijing.volces.com/api/v3/chat/completions", defaultModel: "doubao-pro-128k",
            availableModels: [AIModel(id: "doubao-pro-128k", displayName: "Doubao Pro 128K"),
                              AIModel(id: "doubao-pro-32k", displayName: "Doubao Pro 32K"),
                              AIModel(id: "doubao-lite-32k", displayName: "Doubao Lite 32K")]),
        OpenAICompatibleProvider(
            id: "hunyuan", name: "Hunyuan (Tencent)", iconName: "atom", keyAccount: "hunyuan_api_key",
            endpoint: "https://api.hunyuan.cloud.tencent.com/v1/chat/completions", defaultModel: "hunyuan-pro",
            availableModels: [AIModel(id: "hunyuan-pro", displayName: "Hunyuan Pro"),
                              AIModel(id: "hunyuan-turbo", displayName: "Hunyuan Turbo"),
                              AIModel(id: "hunyuan-standard", displayName: "Hunyuan Standard")]),
        OpenAICompatibleProvider(
            id: "ernie", name: "ERNIE (Baidu)", iconName: "leaf", keyAccount: "qianfan_api_key",
            endpoint: "https://qianfan.baidubce.com/v2/chat/completions", defaultModel: "ernie-4.0-8k",
            availableModels: [AIModel(id: "ernie-4.0-8k", displayName: "ERNIE 4.0"),
                              AIModel(id: "ernie-4.0-turbo-8k", displayName: "ERNIE 4.0 Turbo"),
                              AIModel(id: "ernie-3.5-8k", displayName: "ERNIE 3.5")]),
        OpenAICompatibleProvider(
            id: "yi", name: "Yi (01.AI)", iconName: "01.circle", keyAccount: "yi_api_key",
            endpoint: "https://api.lingyiwanwu.com/v1/chat/completions", defaultModel: "yi-large",
            availableModels: [AIModel(id: "yi-large", displayName: "Yi Large"),
                              AIModel(id: "yi-medium", displayName: "Yi Medium")]),
        OpenAICompatibleProvider(
            id: "stepfun", name: "Step (StepFun)", iconName: "stairs", keyAccount: "step_api_key",
            endpoint: "https://api.stepfun.com/v1/chat/completions", defaultModel: "step-2-16k",
            availableModels: [AIModel(id: "step-2-16k", displayName: "Step-2 16K"),
                              AIModel(id: "step-1-8k", displayName: "Step-1 8K")]),
        OpenAICompatibleProvider(
            id: "baichuan", name: "Baichuan", iconName: "mountain.2", keyAccount: "baichuan_api_key",
            endpoint: "https://api.baichuan-ai.com/v1/chat/completions", defaultModel: "Baichuan4",
            availableModels: [AIModel(id: "Baichuan4", displayName: "Baichuan4"),
                              AIModel(id: "Baichuan3-Turbo", displayName: "Baichuan3 Turbo")]),
        OpenAICompatibleProvider(
            id: "minimax", name: "MiniMax", iconName: "m.circle", keyAccount: "minimax_api_key",
            endpoint: "https://api.minimaxi.com/v1/text/chatcompletion_v2", defaultModel: "MiniMax-Text-01",
            availableModels: [AIModel(id: "MiniMax-Text-01", displayName: "MiniMax Text-01"),
                              AIModel(id: "abab6.5s-chat", displayName: "abab6.5s")]),
        OpenAICompatibleProvider(
            id: "openai", name: "OpenAI", iconName: "circle", keyAccount: "openai_api_key",
            endpoint: "https://api.openai.com/v1/chat/completions", defaultModel: "gpt-5.5",
            availableModels: [AIModel(id: "gpt-5.5", displayName: "GPT-5.5", isVision: true),
                              AIModel(id: "gpt-5.4", displayName: "GPT-5.4", isVision: true),
                              AIModel(id: "gpt-4o", displayName: "GPT-4o", isVision: true),
                              AIModel(id: "gpt-4o-mini", displayName: "GPT-4o mini")]),
        OpenAICompatibleProvider(
            id: "grok", name: "Grok (xAI)", iconName: "bolt", keyAccount: "grok_api_key",
            endpoint: "https://api.x.ai/v1/chat/completions", defaultModel: "grok-4.3",
            availableModels: [AIModel(id: "grok-4.3", displayName: "Grok 4.3", isVision: true),
                              AIModel(id: "grok-code-fast-1", displayName: "Grok Code Fast 1"),
                              AIModel(id: "grok-2-latest", displayName: "Grok 2", isVision: true)]),
        // MLX is a local OpenAI-compatible server and needs no key.
        OpenAICompatibleProvider(
            id: "mlx", name: "MLX (local)", iconName: "desktopcomputer", keyAccount: "mlx_api_key",
            endpoint: "http://localhost:8080/v1/chat/completions",
            defaultModel: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            availableModels: [AIModel(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B (MLX)", isLocal: true)],
            requiresAPIKey: false, isLocal: true),
    ]

    /// All built-in providers: OpenAI-compatible providers plus distinct-shape adapters, plus the
    /// subscription-backed CLI providers (Claude Code / Codex — no key, use the local CLI's auth).
    /// CLI providers are included only when their binary is actually installed (fast file probe,
    /// no subprocess) — a `requiresAPIKey == false` provider whose binary is absent would otherwise
    /// look permanently "ready" to every enumeration-driven selection/fallback path and dead-end at
    /// request time (Codex review 532fa03 issue 1).
    public static let all: [any ChatProvider] =
        openAICompatible + [AnthropicProvider(), GeminiProvider(), WatsonXProvider(), OllamaProvider()]
        + [CLIChatProvider.claudeCode(), CLIChatProvider.codexCLI()].filter { $0.isInstalled() }
        + [OllamaProvider.cobol()]   // offline COBOL specialist (kist -p cobol); NOT in the default rotation
}

/// Thread-safe per-provider retry tally. Lock-guarded so a `let` reference to it keeps `ProviderRegistry`
/// Sendable. Monotonic; the great-loop diffs two snapshots to get a per-cycle retry count.
final class RetryTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ providerId: String) { lock.lock(); counts[providerId, default: 0] += 1; lock.unlock() }
    func count(_ providerId: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[providerId] ?? 0 }
}

/// Holds the available providers and resolves keys via a KeyStore.
/// Fully Sendable: only immutable Sendable state (the retry tally is a lock-guarded reference).
public final class ProviderRegistry: Sendable {
    public let providers: [any ChatProvider]
    private let keyStore: KeyStore
    private let retryDelaysNanoseconds: [UInt64]
    private let retrySleep: @Sendable (UInt64) async -> Void
    private let fallbackProviderIds: [String: [String]]
    /// Per-provider tally of same-provider RETRIES issued this process — a flakiness signal (immutable
    /// reference; the internal mutation is lock-guarded, so the registry stays Sendable). See `retryCount`.
    private let retryTally = RetryTally()
    /// Live `/models` fetch for Layer-B model-id reconciliation. Called REACTIVELY (only on a
    /// model-not-found error), so there's no per-call network. Injected for tests.
    private let modelListFetch: @Sendable (_ modelsURL: String, _ apiKey: String?) async -> Result<[String], Error>

    public init(providers: [any ChatProvider] = ProviderCatalog.all,
                keyStore: KeyStore = DefaultKeyStore.make(),
                fallbackProviderIds: [String: [String]] = [:],
                retryDelaysNanoseconds: [UInt64] = [250_000_000, 750_000_000],
                retrySleep: @escaping @Sendable (UInt64) async -> Void = { delay in
                    guard delay > 0 else { return }
                    try? await Task.sleep(nanoseconds: delay)
                },
                modelListFetch: @escaping @Sendable (String, String?) async -> Result<[String], Error> = {
                    url, key in await ProviderDoctor.liveFetch(modelsURL: url, apiKey: key)
                }) {
        self.providers = providers
        self.keyStore = keyStore
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
        self.retrySleep = retrySleep
        self.fallbackProviderIds = fallbackProviderIds
        self.modelListFetch = modelListFetch
    }

    /// Resolve a valid model id on the SAME provider after a model-not-found error (Layer B). Returns the
    /// resolved id (different from `current`) or nil if no resolution is possible (caller then falls back).
    private func resolveValidModel(for provider: any ChatProvider, apiKey: String?, current: String) async -> String? {
        guard let modelsURL = provider.modelsListEndpoint,
              case let .success(live) = await modelListFetch(modelsURL, apiKey),
              let resolved = ModelResolver.resolve(requested: current, default: provider.defaultModel, live: live),
              resolved != current
        else { return nil }
        return resolved
    }

    public func provider(id: String) -> (any ChatProvider)? {
        providers.first { $0.id == id || $0.name.lowercased() == id.lowercased() }
    }

    /// Cumulative count of same-provider RETRIES issued for `providerId` this process — a FLAKINESS signal.
    /// A retry means a recoverable error (5xx / rate-limit / transport) was re-attempted; it is counted even
    /// when the retry eventually RECOVERS, because a provider whose calls keep needing retries is degrading.
    /// The great-loop diffs this across a cycle to route around a flaky-but-not-down provider whose errors
    /// are absorbed here and would otherwise surface only as budget-exhaustion (never a terminal fault).
    public func retryCount(providerId: String) -> Int { retryTally.count(providerId) }

    public func hasKey(for provider: any ChatProvider) -> Bool {
        !provider.requiresAPIKey || keyStore.key(forAccount: provider.keyAccount) != nil
    }

    /// Resolve the API key for a provider id (nil if unknown or unset). Needed by out-of-band
    /// provider calls like the Gemini Files API uploader, which run outside the stream() path.
    public func apiKey(forProviderId id: String) -> String? {
        guard let provider = provider(id: id) else { return nil }
        return keyStore.key(forAccount: provider.keyAccount)
    }

    /// Stream a completion from a provider id, resolving the key.
    public func stream(providerId: String, model: String?, messages: [ChatMessage], settings: ModelSettings,
                       allowFallback: Bool = true) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let provider = provider(id: providerId) else { throw AIProviderError.configuration("unknown provider \(providerId)") }
        let candidates = streamCandidates(primary: provider, providerId: providerId, requestedModel: model, allowFallback: allowFallback)
        return retryingCandidateStream(candidates) { candidate, resolvedModel in
            try await candidate.provider.stream(messages: messages, model: resolvedModel, settings: settings, apiKey: candidate.apiKey)
        }
    }

    /// Convenience: stream and collapse to full assistant text.
    public func complete(providerId: String, model: String? = nil, messages: [ChatMessage], settings: ModelSettings = ModelSettings()) async throws -> String {
        // Route through completeWithUsage so non-streaming callers also get the reasoning self-heal.
        try await completeWithUsage(providerId: providerId, model: model, messages: messages, settings: settings).text
    }

    /// Self-heal bounds: how many times an empty-because-truncated completion is retried on the SAME model
    /// with a doubled budget before giving up, and the floor/ceiling those doublings move between.
    private static let maxSelfHeals = 2
    private static let selfHealFloorTokens = 8192
    private static let selfHealCeilingTokens = 32768

    /// Like `complete`, but also returns MEASURED token usage (the last `.usage` event). Used by the
    /// observability + cost layers. Usage is `.zero` if the provider doesn't report it — the caller
    /// decides whether to fall back to an estimate.
    public func completeWithUsage(providerId: String, model: String? = nil, messages: [ChatMessage],
                                  settings: ModelSettings = ModelSettings(),
                                  allowFallback: Bool = true,
                                  allowModelResolution: Bool = true) async throws -> (text: String, usage: TokenUsage) {
        guard let provider = provider(id: providerId) else { throw AIProviderError.configuration("unknown provider \(providerId)") }
        let candidates = allowFallback
            ? streamCandidates(primary: provider, providerId: providerId, requestedModel: model)
            : [StreamCandidate(provider: provider,
                               model: provider.resolvedModel(model),
                               apiKey: keyStore.key(forAccount: provider.keyAccount))]
        let delays = retryDelaysNanoseconds
        var lastError: Error?

        for (candidateIndex, candidate) in candidates.enumerated() {
            var attempt = 0
            var healedSettings = settings
            var selfHeals = 0
            var currentModel = candidate.model
            var resolvedModelOnce = false
            while !Task.isCancelled {
                do {
                    let stream = try await candidate.provider.stream(messages: messages, model: currentModel,
                                                                     settings: healedSettings, apiKey: candidate.apiKey)
                    var text = ""
                    var usage = TokenUsage.zero
                    var sawReasoning = false
                    var finishReason: String?
                    for try await event in stream {
                        switch event {
                        case .delta(let d): text += d
                        case .reasoning: sawReasoning = true
                        case .finish(let r): finishReason = r
                        case .usage(let p, let c): usage = TokenUsage(promptTokens: p, completionTokens: c)
                        default: break
                        }
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        // SELF-HEAL: an empty answer because the model spent its budget on hidden reasoning
                        // (saw reasoning chunks, or finish_reason == "length") is fixed by giving the SAME
                        // model more room — NOT by silently switching providers. Bounded so it can't loop.
                        if sawReasoning || finishReason == "length", selfHeals < Self.maxSelfHeals {
                            // Codex MED: heal must be MONOTONIC — only retry if the new budget is strictly
                            // larger than the current one (a caller asking for >ceiling must never be lowered).
                            let bumped = min(max(healedSettings.maxTokens, Self.selfHealFloorTokens) * 2,
                                             Self.selfHealCeilingTokens)
                            if bumped > healedSettings.maxTokens {
                                selfHeals += 1
                                healedSettings.maxTokens = bumped
                                continue
                            }
                        }
                        // Empty after heals: go STRAIGHT to the next candidate (the codebase intentionally
                        // falls back on empty — see CompleteWithUsageTests) WITHOUT the wasteful
                        // same-provider attempt-retries a deterministic empty would otherwise trigger
                        // (Codex HIGH). No fallback candidate ⇒ surface honestly.
                        lastError = AIProviderError.transport("empty completion from \(candidate.provider.id):\(currentModel)")
                        if candidateIndex < candidates.count - 1 { break }
                        throw lastError ?? AIProviderError.transport("empty completion")
                    }
                    return (text, usage)
                } catch is CancellationError {
                    throw AIProviderError.transport("completion cancelled")
                } catch {
                    if Task.isCancelled { throw AIProviderError.transport("completion cancelled") }
                    lastError = error
                    // Layer B: a model-not-found (dead/renamed id like grok-2-latest) is healed by resolving
                    // a VALID id on the SAME provider and retrying — NOT by silently switching providers.
                    // Once per candidate, reactive (only fetches /models on this error path).
                    if allowModelResolution, !resolvedModelOnce, ModelResolver.isModelNotFound(error),
                       let resolved = await resolveValidModel(for: candidate.provider, apiKey: candidate.apiKey, current: currentModel) {
                        resolvedModelOnce = true
                        currentModel = resolved
                        continue   // retry SAME provider with a valid model
                    }
                    guard Self.shouldRetry(error) else {
                        if candidateIndex < candidates.count - 1, Self.shouldFallback(error) { break }
                        throw error
                    }
                    guard attempt < delays.count else { break }
                    let delay = delays[attempt]
                    attempt += 1
                    retryTally.record(candidate.provider.id)   // flakiness signal (counts even if it recovers)
                    await retrySleep(delay)
                }
            }
        }
        throw lastError ?? AIProviderError.transport("completion cancelled")
    }

    /// Does this provider implement native tool-calling?
    public func supportsNativeTools(providerId: String) -> Bool {
        provider(id: providerId)?.supportsNativeTools ?? false
    }

    /// Stream WITH native tool definitions, resolving the key. Falls back to the text path for
    /// providers that don't override `streamTools`.
    public func streamTools(providerId: String, model: String?, messages: [ChatMessage], settings: ModelSettings, tools: [ToolSpec],
                            allowFallback: Bool = true) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let provider = provider(id: providerId) else { throw AIProviderError.configuration("unknown provider \(providerId)") }
        // History-repair at the native encode boundary: strict providers (Gemini/Anthropic) 400 on
        // an orphan tool result. The loop builds valid transcripts, but resumed/edited ones may not.
        let safeMessages = TranscriptRepair.repairForNativeTools(messages)
        let candidates = streamCandidates(primary: provider, providerId: providerId, requestedModel: model, allowFallback: allowFallback)
        return retryingCandidateStream(candidates) { candidate, resolvedModel in
            try await candidate.provider.streamTools(messages: safeMessages, model: resolvedModel, settings: settings, apiKey: candidate.apiKey, tools: tools)
        }
    }

    private struct StreamCandidate: Sendable {
        let provider: any ChatProvider
        let model: String
        let apiKey: String?
    }

    private func streamCandidates(primary: any ChatProvider, providerId: String, requestedModel: String?,
                                  allowFallback: Bool = true) -> [StreamCandidate] {
        // Fallback OFF (e.g. the model canary probe) ⇒ ONLY the requested provider, so a probe can never
        // report a model READY because a DIFFERENT fallback provider happened to answer.
        guard allowFallback else {
            return [StreamCandidate(provider: primary, model: primary.resolvedModel(requestedModel),
                                    apiKey: keyStore.key(forAccount: primary.keyAccount))]
        }
        let fallbackIds = fallbackProviderIds[providerId] ?? fallbackProviderIds[primary.id] ?? []
        let orderedProviders = [primary] + fallbackIds.compactMap { id in
            provider(id: id)
        }.filter { fallback in
            fallback.id != primary.id
        }
        return orderedProviders.map { provider in
            let resolvedModel = provider.id == primary.id ? provider.resolvedModel(requestedModel) : provider.resolvedModel(nil)
            return StreamCandidate(provider: provider, model: resolvedModel, apiKey: keyStore.key(forAccount: provider.keyAccount))
        }
    }

    /// Candidate-aware streaming retry. Builds the stream from `(candidate, model)` so it can apply Layer-B
    /// model resolution: a dead-id model-not-found error caught BEFORE any event is yielded resolves a valid
    /// id on the SAME provider and retries — instead of the silent cross-provider switch. (The reasoning
    /// empty-self-heal of completeWithUsage is intentionally NOT replicated here: it would require buffering
    /// the whole stream, defeating streaming. The reasoning BUDGET FLOOR in makeBody still applies to every
    /// streamed call, so streamed reasoning models already get headroom up front.)
    private func retryingCandidateStream(
        _ candidates: [StreamCandidate],
        build: @escaping @Sendable (_ candidate: StreamCandidate, _ model: String) async throws -> AsyncThrowingStream<StreamEvent, Error>
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let delays = retryDelaysNanoseconds
        let sleep = retrySleep
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                guard !candidates.isEmpty else {
                    continuation.finish(throwing: AIProviderError.configuration("no provider candidates"))
                    return
                }
                var lastError: Error?
                for (candidateIndex, candidate) in candidates.enumerated() {
                    var attempt = 0
                    var currentModel = candidate.model
                    var resolvedModelOnce = false
                    while !Task.isCancelled {
                        var yieldedAny = false
                        do {
                            let stream = try await build(candidate, currentModel)
                            for try await event in stream {
                                yieldedAny = true
                                continuation.yield(event)
                            }
                            continuation.finish()
                            return
                        } catch is CancellationError {
                            continuation.finish(throwing: AIProviderError.transport("stream cancelled"))
                            return
                        } catch {
                            if Task.isCancelled {
                                continuation.finish(throwing: AIProviderError.transport("stream cancelled"))
                                return
                            }
                            lastError = error
                            // Layer B: only safe to re-issue if NOTHING was yielded yet (else we'd double-emit).
                            if !yieldedAny, !resolvedModelOnce, ModelResolver.isModelNotFound(error),
                               let resolved = await resolveValidModel(for: candidate.provider, apiKey: candidate.apiKey, current: currentModel) {
                                resolvedModelOnce = true
                                currentModel = resolved
                                continue
                            }
                            // Codex HIGH: once partial output has been forwarded, NEITHER a same-candidate
                            // retry NOR a cross-provider fallback is safe — re-issuing would append a second
                            // stream's events to what the consumer already received (duplicate/interleaved
                            // output). After any emission, surface the error outward.
                            if yieldedAny {
                                continuation.finish(throwing: error)
                                return
                            }
                            guard Self.shouldRetry(error) else {
                                if candidateIndex < candidates.count - 1, Self.shouldFallback(error) {
                                    break
                                }
                                continuation.finish(throwing: error)
                                return
                            }
                            guard attempt < delays.count else { break }
                            let delay = delays[attempt]
                            attempt += 1
                            self.retryTally.record(candidate.provider.id)   // flakiness signal (counts even if it recovers)
                            await sleep(delay)
                        }
                    }
                }
                continuation.finish(throwing: lastError ?? AIProviderError.transport("stream cancelled"))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if let providerError = error as? AIProviderError {
            return providerError.isRetryable
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }

    private static func shouldFallback(_ error: Error) -> Bool {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .missingAPIKey, .invalidAPIKey, .rateLimited, .transport:
                return true
            case .http(let status, _):
                return status == 401 || status == 403 || status == 404 || status == 429 || (500...599).contains(status)
            case .configuration:
                return true
            case .invalidResponse:
                return false
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
