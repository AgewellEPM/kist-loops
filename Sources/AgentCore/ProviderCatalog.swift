import Foundation
// Use swift-crypto's cross-platform `Crypto` module (CryptoKit-compatible API,
// BoringSSL-backed on Linux). A system `CryptoKit` module does not exist on Linux,
// so importing it directly would break the documented Linux build before compilation.
import Crypto

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
public enum ProviderRequestBudgetError: Error, Sendable, Equatable, CustomStringConvertible {
    case exhausted(limit: Int, consumed: Int)
    case persistence(String)

    public var description: String {
        switch self {
        case .exhausted(let limit, let consumed):
            return "provider request limit reached (\(consumed)/\(limit))"
        case .persistence(let detail):
            return "provider request admission could not be persisted: \(detail)"
        }
    }
}

/// One route decision shared by the visible completion and every hidden provider request it can
/// trigger. `.exact` is the forced-native contract: same provider, same model, no fallback, and no
/// administrative model-list discovery. Adaptive routes may heal a dead model, but that discovery
/// is itself a budgeted provider-network attempt.
public struct ProviderRoutePolicy: Sendable, Equatable {
    public let allowFallback: Bool
    public let allowModelResolution: Bool
    public let allowModelDiscovery: Bool

    public init(allowFallback: Bool, allowModelResolution: Bool,
                allowModelDiscovery: Bool) {
        self.allowFallback = allowFallback
        self.allowModelResolution = allowModelResolution
        self.allowModelDiscovery = allowModelDiscovery
    }

    public static func adaptive(allowFallback: Bool) -> ProviderRoutePolicy {
        ProviderRoutePolicy(allowFallback: allowFallback,
                            allowModelResolution: true,
                            allowModelDiscovery: true)
    }

    public static let sameProviderAdaptive = ProviderRoutePolicy(
        allowFallback: false, allowModelResolution: true, allowModelDiscovery: true)
    public static let exact = ProviderRoutePolicy(
        allowFallback: false, allowModelResolution: false, allowModelDiscovery: false)
}

/// One absolute request ceiling shared by every provider route used by a loop invocation. A slot is
/// durably admitted immediately before the concrete provider request, so retries, fallback candidates,
/// model resolution, compaction, and synthesis cannot hide requests inside one outer agent iteration.
public actor ProviderRequestBudget {
    /// Persist one atomic increment and return the authoritative total. Returning the total rather
    /// than accepting a local absolute count is what makes independent actors/processes compose.
    public typealias Persistence = @Sendable (_ minimumConsumed: Int, _ limit: Int) throws -> Int

    public let limit: Int
    private var consumed: Int
    private let persistence: Persistence?
    private var persistenceFailure: ProviderRequestBudgetError?

    public init(limit: Int, consumed: Int = 0, persistence: Persistence? = nil) {
        self.limit = max(0, limit)
        self.consumed = max(0, consumed)
        self.persistence = persistence
    }

    /// Atomically burn and persist one request slot. A persistence failure is fail-closed and sticky:
    /// no provider request is issued after durable accounting becomes uncertain.
    @discardableResult
    public func admit() throws -> Int {
        if let persistenceFailure { throw persistenceFailure }
        if let persistence {
            do {
                let admitted = try persistence(consumed, limit)
                guard admitted > consumed, admitted <= limit else {
                    let failure = ProviderRequestBudgetError.persistence(
                        "durable admission returned invalid counter \(admitted) after \(consumed)")
                    persistenceFailure = failure
                    throw failure
                }
                consumed = admitted
            } catch let budgetError as ProviderRequestBudgetError {
                if case .exhausted(_, let durableConsumed) = budgetError {
                    consumed = max(consumed, durableConsumed)
                } else {
                    consumed = min(limit, consumed + (consumed < limit ? 1 : 0))
                    persistenceFailure = budgetError
                }
                throw budgetError
            } catch {
                consumed = min(limit, consumed + (consumed < limit ? 1 : 0))
                let failure = ProviderRequestBudgetError.persistence(String(describing: error))
                persistenceFailure = failure
                throw failure
            }
        } else {
            guard consumed < limit else {
                throw ProviderRequestBudgetError.exhausted(limit: limit, consumed: consumed)
            }
            consumed += 1
        }
        return consumed
    }

    public func consumedCount() -> Int { consumed }

    /// Non-nil means another provider request must not be attempted.
    public func blockingError() -> ProviderRequestBudgetError? {
        persistenceFailure ?? (consumed >= limit ? .exhausted(limit: limit, consumed: consumed) : nil)
    }
}

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
    /// Availability gate for the cross-provider FALLBACK chain (Codex P2, 2026-08-25): without it a
    /// fresh health-daemon "down" verdict couldn't stop the stream retry lane from walking into a
    /// dead fallback. Default no-gate keeps tests hermetic; the runner wires the live combined gate
    /// (cooldowns + health daemon) in `makeRegistry`. Never applied to the PRIMARY (explicit choice),
    /// and fails open when every fallback is benched.
    private let providerUnavailable: @Sendable (String) -> Bool

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
                },
                providerUnavailable: @escaping @Sendable (String) -> Bool = { _ in false }) {
        self.providers = providers
        self.keyStore = keyStore
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
        self.retrySleep = retrySleep
        self.fallbackProviderIds = fallbackProviderIds
        self.modelListFetch = modelListFetch
        self.providerUnavailable = providerUnavailable
    }

    /// Resolve a valid model id on the SAME provider after a model-not-found error (Layer B). Returns the
    /// resolved id (different from `current`) or nil if no resolution is possible (caller then falls back).
    private func resolveValidModel(
        for provider: any ChatProvider, apiKey: String?, current: String,
        routePolicy: ProviderRoutePolicy,
        requestBudget: ProviderRequestBudget?
    ) async throws -> String? {
        guard routePolicy.allowModelResolution,
              routePolicy.allowModelDiscovery,
              let modelsURL = provider.modelsListEndpoint else { return nil }
        // The GET /models request is a real provider-network attempt. Admit immediately before it;
        // denial or disabled discovery returns to the original model error without network activity.
        let started = DispatchTime.now().uptimeNanoseconds
        let requestOrdinal: Int?
        do {
            requestOrdinal = try await requestBudget?.admit()
        } catch {
            BuilderTrustedTelemetry.recordTool(
                name: "provider-admission",
                argumentsDigest: BuilderEvidenceDigest.sha256(
                    "model-discovery:\(provider.id):\(current)"),
                success: false, elapsedMilliseconds: 1)
            throw error
        }
        let result = await modelListFetch(modelsURL, apiKey)
        let elapsed = max(1, Int((DispatchTime.now().uptimeNanoseconds &- started) / 1_000_000))
        switch result {
        case .success(let live):
            BuilderTrustedTelemetry.recordProvider(
                providerID: provider.id, modelID: current,
                inputTokens: max(1, modelsURL.utf8.count),
                outputTokens: max(1, live.reduce(0) { $0 + $1.utf8.count }),
                elapsedMilliseconds: elapsed,
                outputDigest: BuilderEvidenceDigest.sha256(
                    "\(requestOrdinal ?? 0):\(live.sorted().joined(separator: "\u{0}"))"),
                mechanism: "model-discovery")
            guard let resolved = ModelResolver.resolve(
                requested: current, default: provider.defaultModel, live: live),
                  resolved != current else { return nil }
            return resolved
        case .failure(let error):
            BuilderTrustedTelemetry.recordProvider(
                providerID: provider.id, modelID: current,
                inputTokens: max(1, modelsURL.utf8.count), outputTokens: 0,
                elapsedMilliseconds: elapsed,
                outputDigest: BuilderEvidenceDigest.sha256(
                    "\(requestOrdinal ?? 0):\(String(reflecting: type(of: error)))"),
                success: false, mechanism: "model-discovery")
            return nil
        }
    }

    public func provider(id: String) -> (any ChatProvider)? {
        providers.first { $0.id == id || $0.name.lowercased() == id.lowercased() }
    }

    public func reasoningEffortResolution(providerId: String, model: String?,
                                          requested: ProviderReasoningEffort,
                                          base: ModelSettings) -> ProviderEffortResolution {
        guard let provider = provider(id: providerId) else {
            return ProviderEffortMapper.resolve(providerID: providerId, modelID: model ?? "",
                                                requested: requested, support: .unsupported, base: base)
        }
        let modelID = provider.resolvedModel(model)
        return ProviderEffortMapper.resolve(providerID: provider.id, modelID: modelID,
                                            requested: requested,
                                            support: provider.capabilities(forModel: modelID).reasoningEffortSupport,
                                            base: base)
    }

    /// Cumulative count of same-provider RETRIES issued for `providerId` this process — a FLAKINESS signal.
    /// A retry means a recoverable error (5xx / rate-limit / transport) was re-attempted; it is counted even
    /// when the retry eventually RECOVERS, because a provider whose calls keep needing retries is degrading.
    /// The great-loop diffs this across a cycle to route around a flaky-but-not-down provider whose errors
    /// are absorbed here and would otherwise surface only as budget-exhaustion (never a terminal fault).
    public func retryCount(providerId: String) -> Int { retryTally.count(providerId) }

    /// Whether the provider has usable local credentials. API providers need a stored key; keyless
    /// subscription CLIs need both their executable and a live, non-interactive login. Treating an
    /// installed-but-logged-out CLI as configured lets reviewer/evolution selection pick a route that
    /// cannot answer, which can roll back an otherwise verified repair. Other genuinely local providers
    /// remain keyless and available.
    public func hasKey(for provider: any ChatProvider) -> Bool {
        if let cli = provider as? CLIChatProvider {
            return cli.isLocallyAvailable()
        }
        return !provider.requiresAPIKey || keyStore.containsKey(forAccount: provider.keyAccount)
    }

    /// Resolve the API key for a provider id (nil if unknown or unset). Needed by out-of-band
    /// provider calls like the Gemini Files API uploader, which run outside the stream() path.
    public func apiKey(forProviderId id: String) -> String? {
        guard let provider = provider(id: id) else { return nil }
        return keyStore.key(forAccount: provider.keyAccount)
    }

    /// Stream a completion from a provider id, resolving the key.
    public func stream(providerId: String, model: String?, messages: [ChatMessage], settings: ModelSettings,
                       allowFallback: Bool = false,
                       routePolicy: ProviderRoutePolicy? = nil,
                       requestBudget: ProviderRequestBudget? = nil) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let provider = provider(id: providerId) else {
            BuilderTrustedTelemetry.recordTool(
                name: "provider-routing", argumentsDigest: BuilderEvidenceDigest.sha256(providerId),
                success: false, elapsedMilliseconds: 1)
            throw AIProviderError.configuration("unknown provider \(providerId)")
        }
        let policy = routePolicy ?? .adaptive(allowFallback: allowFallback)
        let candidates = streamCandidates(primary: provider, providerId: providerId, requestedModel: model,
                                          allowFallback: policy.allowFallback)
        return retryingCandidateStream(candidates, routePolicy: policy,
                                       mechanism: "stream",
                                       inputTokenUpperBound: Self.tokenUpperBound(messages),
                                       requestBudget: requestBudget) { candidate, resolvedModel in
            let resolution = Self.resolveEffort(candidate: candidate, model: resolvedModel, settings: settings)
            let stream = try await candidate.provider.stream(messages: messages, model: resolvedModel,
                                                             settings: resolution.settings, apiKey: candidate.apiKey)
            return Self.annotate(stream, record: resolution.record)
        }
    }

    /// Convenience: stream and collapse to full assistant text.
    public func complete(providerId: String, model: String? = nil, messages: [ChatMessage],
                         settings: ModelSettings = ModelSettings(), allowFallback: Bool = false,
                         routePolicy: ProviderRoutePolicy? = nil,
                         requestBudget: ProviderRequestBudget? = nil) async throws -> String {
        // Route through completeWithUsage so non-streaming callers also get the reasoning self-heal.
        try await completeWithUsage(providerId: providerId, model: model, messages: messages,
                                    settings: settings, allowFallback: allowFallback,
                                    routePolicy: routePolicy,
                                    requestBudget: requestBudget).text
    }

    /// Self-heal bounds: how many times an empty-because-truncated completion is retried on the SAME model
    /// with a doubled budget before giving up, and the floor/ceiling those doublings move between.
    private static let maxSelfHeals = 2
    private static let selfHealFloorTokens = 8192
    private static let selfHealCeilingTokens = 32768

    /// Like `complete`, but also returns MEASURED token usage (the last `.usage` event). Used by the
    /// observability + cost layers. Usage is `.zero` if the provider doesn't report it — the caller
    /// decides whether to fall back to an estimate.
    public struct RoutedCompletion: Sendable {
        public let text: String
        public let usage: TokenUsage
        public let providerId: String
        public let model: String
        public let usedFallback: Bool
    }

    public func completeWithUsage(providerId: String, model: String? = nil, messages: [ChatMessage],
                                  settings: ModelSettings = ModelSettings(),
                                  allowFallback: Bool = false,
                                  allowModelResolution: Bool = true,
                                  routePolicy: ProviderRoutePolicy? = nil,
                                  requestBudget: ProviderRequestBudget? = nil) async throws -> (text: String, usage: TokenUsage) {
        let routed = try await completeWithRoute(providerId: providerId, model: model, messages: messages,
                                                 settings: settings, allowFallback: allowFallback,
                                                 allowModelResolution: allowModelResolution,
                                                 routePolicy: routePolicy,
                                                 requestBudget: requestBudget)
        return (routed.text, routed.usage)
    }

    /// Opt-in fallback with explicit route identity. Existing callers keep the tuple API above; callers that
    /// permit cross-provider fallback can use this result to prove which provider/model produced the answer.
    public func completeWithRoute(providerId: String, model: String? = nil, messages: [ChatMessage],
                                  settings: ModelSettings = ModelSettings(),
                                  allowFallback: Bool = false,
                                  allowModelResolution: Bool = true,
                                  routePolicy: ProviderRoutePolicy? = nil,
                                  requestBudget: ProviderRequestBudget? = nil) async throws -> RoutedCompletion {
        guard let provider = provider(id: providerId) else {
            BuilderTrustedTelemetry.recordTool(
                name: "provider-routing", argumentsDigest: BuilderEvidenceDigest.sha256(providerId),
                success: false, elapsedMilliseconds: 1)
            throw AIProviderError.configuration("unknown provider \(providerId)")
        }
        let policy = routePolicy ?? ProviderRoutePolicy(
            allowFallback: allowFallback,
            allowModelResolution: allowModelResolution,
            allowModelDiscovery: allowModelResolution)
        let candidates = policy.allowFallback
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
                let attemptStarted = DispatchTime.now().uptimeNanoseconds
                var admittedOrdinal: Int?
                var attemptRecorded = false
                var attemptText = ""
                var attemptUsage = TokenUsage.zero
                do {
                    let resolution = Self.resolveEffort(candidate: candidate, model: currentModel,
                                                        settings: healedSettings)
                    do {
                        admittedOrdinal = try await requestBudget?.admit()
                    } catch {
                        BuilderTrustedTelemetry.recordTool(
                            name: "provider-admission",
                            argumentsDigest: BuilderEvidenceDigest.sha256(
                                "completion:\(candidate.provider.id):\(currentModel)"),
                            success: false, elapsedMilliseconds: 1)
                        throw error
                    }
                    let stream = try await candidate.provider.stream(messages: messages, model: currentModel,
                                                                     settings: resolution.settings, apiKey: candidate.apiKey)
                    try Task.checkCancellation()
                    var text = ""
                    var usage = TokenUsage.zero
                    var sawReasoning = false
                    var finishReason: String?
                    for try await event in stream {
                        try Task.checkCancellation()
                        switch event {
                        case .delta(let d): text += d; attemptText = text
                        case .reasoning: sawReasoning = true
                        case .finish(let r): finishReason = r
                        case .usage(let p, let c):
                            usage = TokenUsage(promptTokens: p, completionTokens: c)
                            attemptUsage = usage
                        default: break
                        }
                    }
                    try Task.checkCancellation()
                    attemptText = text
                    attemptUsage = usage
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
                                Self.recordProviderAttempt(
                                    candidate: candidate, model: currentModel,
                                    mechanism: "completion-self-heal",
                                    ordinal: admittedOrdinal, messages: messages,
                                    text: text, usage: usage, success: false,
                                    started: attemptStarted)
                                attemptRecorded = true
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
                        if candidateIndex < candidates.count - 1 {
                            Self.recordProviderAttempt(
                                candidate: candidate, model: currentModel,
                                mechanism: "completion-empty", ordinal: admittedOrdinal,
                                messages: messages, text: text, usage: usage,
                                success: false, started: attemptStarted)
                            attemptRecorded = true
                            break
                        }
                        throw lastError ?? AIProviderError.transport("empty completion")
                    }
                    try Task.checkCancellation()
                    Self.recordProviderAttempt(
                        candidate: candidate, model: currentModel, mechanism: "completion",
                        ordinal: admittedOrdinal, messages: messages, text: text,
                        usage: usage, success: true, started: attemptStarted)
                    attemptRecorded = true
                    return RoutedCompletion(text: text, usage: usage, providerId: candidate.provider.id,
                                            model: currentModel, usedFallback: candidateIndex > 0)
                } catch is CancellationError {
                    if !attemptRecorded, admittedOrdinal != nil || requestBudget == nil {
                        Self.recordProviderAttempt(
                            candidate: candidate, model: currentModel,
                            mechanism: "completion-cancelled", ordinal: admittedOrdinal,
                            messages: messages, text: attemptText, usage: attemptUsage,
                            success: false, started: attemptStarted)
                    }
                    throw AIProviderError.transport("completion cancelled")
                } catch {
                    if !attemptRecorded, admittedOrdinal != nil || requestBudget == nil {
                        Self.recordProviderAttempt(
                            candidate: candidate, model: currentModel,
                            mechanism: "completion-attempt", ordinal: admittedOrdinal,
                            messages: messages, text: attemptText, usage: attemptUsage,
                            success: false, started: attemptStarted,
                            errorType: String(reflecting: type(of: error)))
                        attemptRecorded = true
                    }
                    if Task.isCancelled { throw AIProviderError.transport("completion cancelled") }
                    lastError = ProviderRouteFailure.annotate(
                        error, requested: provider.id, provider: candidate.provider.id, model: currentModel)
                    // Layer B: a model-not-found (dead/renamed id like grok-2-latest) is healed by resolving
                    // a VALID id on the SAME provider and retrying — NOT by silently switching providers.
                    // Once per candidate, reactive (only fetches /models on this error path).
                    if policy.allowModelResolution, !resolvedModelOnce, ModelResolver.isModelNotFound(error),
                       let resolved = try await resolveValidModel(
                        for: candidate.provider, apiKey: candidate.apiKey, current: currentModel,
                        routePolicy: policy, requestBudget: requestBudget) {
                        resolvedModelOnce = true
                        currentModel = resolved
                        continue   // retry SAME provider with a valid model
                    }
                    guard Self.shouldRetry(error) else {
                        if candidateIndex < candidates.count - 1, Self.shouldFallback(error) { break }
                        throw lastError ?? error
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
                            allowFallback: Bool = false,
                            allowModelResolution: Bool = true,
                            routePolicy: ProviderRoutePolicy? = nil,
                            requestBudget: ProviderRequestBudget? = nil) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let provider = provider(id: providerId) else {
            BuilderTrustedTelemetry.recordTool(
                name: "provider-routing", argumentsDigest: BuilderEvidenceDigest.sha256(providerId),
                success: false, elapsedMilliseconds: 1)
            throw AIProviderError.configuration("unknown provider \(providerId)")
        }
        // History-repair at the native encode boundary: strict providers (Gemini/Anthropic) 400 on
        // an orphan tool result. The loop builds valid transcripts, but resumed/edited ones may not.
        let safeMessages = TranscriptRepair.repairForNativeTools(messages)
        let policy = routePolicy ?? ProviderRoutePolicy(
            allowFallback: allowFallback,
            allowModelResolution: allowModelResolution,
            allowModelDiscovery: allowModelResolution)
        let candidates = streamCandidates(primary: provider, providerId: providerId, requestedModel: model,
                                          allowFallback: policy.allowFallback)
        return retryingCandidateStream(candidates, routePolicy: policy,
                                       mechanism: "stream-tools",
                                       inputTokenUpperBound: Self.tokenUpperBound(safeMessages),
                                       requestBudget: requestBudget) { candidate, resolvedModel in
            let resolution = Self.resolveEffort(candidate: candidate, model: resolvedModel, settings: settings)
            let stream = try await candidate.provider.streamTools(messages: safeMessages, model: resolvedModel,
                                                                  settings: resolution.settings,
                                                                  apiKey: candidate.apiKey, tools: tools)
            return Self.annotate(stream, record: resolution.record)
        }
    }

    private struct StreamCandidate: Sendable {
        let provider: any ChatProvider
        let model: String
        let apiKey: String?
    }

    private static func resolveEffort(candidate: StreamCandidate, model: String,
                                      settings: ModelSettings) -> ProviderEffortResolution {
        guard let requested = settings.reasoningEffort else {
            return ProviderEffortResolution(settings: settings,
                record: ProviderEffortRecord(providerID: candidate.provider.id, modelID: model,
                                             requested: settings.disableThinking ? .none : .deep,
                                             application: .providerManaged,
                                             note: "legacy settings; no explicit neutral effort request"))
        }
        return ProviderEffortMapper.resolve(providerID: candidate.provider.id, modelID: model,
                                            requested: requested,
                                            support: candidate.provider.capabilities(forModel: model).reasoningEffortSupport,
                                            base: settings)
    }

    private static func annotate(_ stream: AsyncThrowingStream<StreamEvent, Error>,
                                 record: ProviderEffortRecord) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.effortResolution(record))
                do {
                    for try await event in stream {
                        if case .reasoningHandle(let handle) = event {
                            continuation.yield(.reasoningHandle(OpaqueProviderReasoningHandle(
                                id: handle.id,
                                providerID: record.providerID,
                                modelID: record.modelID,
                                kind: handle.kind,
                                reference: handle.reference,
                                expiresAt: handle.expiresAt,
                                associationID: handle.associationID)))
                        } else {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
        let fallbacks = fallbackIds.compactMap { id in
            provider(id: id)
        }.filter { fallback in
            fallback.id != primary.id
        }
        // Benched fallbacks (health daemon "down" / live cooldown) yield to warm ones; the primary
        // is never filtered (explicit choice). "Warm" must also mean USABLE (Codex P2, 2026-08-25):
        // an unconfigured API provider (no key) is not a real alternative and must not displace a
        // benched-but-CONFIGURED fallback. Ranking, not removal: warm+usable → benched-but-usable
        // (fail-open last resort when health/cooldown data lags a recovery) → unconfigured tail
        // (cheap auth-fail; preserves the pre-gate candidate superset).
        let usable: (any ChatProvider) -> Bool = { [self] p in hasKey(for: p) }
        let warmUsable = fallbacks.filter { usable($0) && !providerUnavailable($0.id) }
        let benchedUsable = fallbacks.filter { usable($0) && providerUnavailable($0.id) }
        let unusable = fallbacks.filter { !usable($0) }
        let orderedProviders = [primary] + warmUsable + benchedUsable + unusable
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
        routePolicy: ProviderRoutePolicy,
        mechanism: String,
        inputTokenUpperBound: Int,
        requestBudget: ProviderRequestBudget? = nil,
        build: @escaping @Sendable (_ candidate: StreamCandidate, _ model: String) async throws -> AsyncThrowingStream<StreamEvent, Error>
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let delays = retryDelaysNanoseconds
        let sleep = retrySleep
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                guard !candidates.isEmpty else {
                    BuilderTrustedTelemetry.recordTool(
                        name: "provider-routing",
                        argumentsDigest: BuilderEvidenceDigest.sha256("no-provider-candidates"),
                        success: false, elapsedMilliseconds: 1)
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
                        let telemetryStarted = DispatchTime.now().uptimeNanoseconds
                        var admittedOrdinal: Int?
                        var telemetryHasher = SHA256()
                        var outputByteUpperBound = 0
                        var promptTokens = 0
                        var completionTokens = 0
                        var usageReported = false
                        do {
                            do {
                                admittedOrdinal = try await requestBudget?.admit()
                            } catch {
                                BuilderTrustedTelemetry.recordTool(
                                    name: "provider-admission",
                                    argumentsDigest: BuilderEvidenceDigest.sha256(
                                        "\(mechanism):\(candidate.provider.id):\(currentModel)"),
                                    success: false, elapsedMilliseconds: 1)
                                throw error
                            }
                            let stream = try await build(candidate, currentModel)
                            for try await event in stream {
                                if case .effortResolution = event { } else { yieldedAny = true }
                                let eventData = Data(String(describing: event).utf8)
                                telemetryHasher.update(data: eventData)
                                outputByteUpperBound += eventData.count
                                switch event {
                                case .usage(let prompt, let completion):
                                    promptTokens = prompt; completionTokens = completion
                                    usageReported = true
                                default: break
                                }
                                continuation.yield(event)
                            }
                            let elapsed = DispatchTime.now().uptimeNanoseconds &- telemetryStarted
                            ProviderAttemptObservation.record(
                                provider: candidate.provider.id, model: currentModel, mechanism: mechanism,
                                usage: TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens),
                                usageReported: usageReported, elapsedNanoseconds: elapsed, success: true)
                            let digest = telemetryHasher.finalize().map {
                                String(format: "%02x", $0)
                            }.joined()
                            BuilderTrustedTelemetry.recordProvider(
                                providerID: candidate.provider.id, modelID: currentModel,
                                inputTokens: promptTokens > 0 ? promptTokens : inputTokenUpperBound,
                                outputTokens: completionTokens > 0
                                    ? completionTokens : max(1, outputByteUpperBound),
                                elapsedMilliseconds: max(1, Int(elapsed / 1_000_000)),
                                outputDigest: BuilderEvidenceDigest.sha256(
                                    "\(admittedOrdinal ?? 0):\(digest)"),
                                mechanism: mechanism)
                            continuation.finish()
                            return
                        } catch is CancellationError {
                            let elapsed = DispatchTime.now().uptimeNanoseconds &- telemetryStarted
                            if admittedOrdinal != nil || requestBudget == nil {
                                ProviderAttemptObservation.record(
                                    provider: candidate.provider.id, model: currentModel, mechanism: mechanism,
                                    usage: TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens),
                                    usageReported: usageReported, elapsedNanoseconds: elapsed, success: false)
                                let digest = telemetryHasher.finalize().map {
                                    String(format: "%02x", $0)
                                }.joined()
                                BuilderTrustedTelemetry.recordProvider(
                                    providerID: candidate.provider.id, modelID: currentModel,
                                    inputTokens: promptTokens > 0 ? promptTokens : inputTokenUpperBound,
                                    outputTokens: completionTokens > 0
                                        ? completionTokens : outputByteUpperBound,
                                    elapsedMilliseconds: max(1, Int(elapsed / 1_000_000)),
                                    outputDigest: BuilderEvidenceDigest.sha256(
                                        "\(admittedOrdinal ?? 0):cancelled:\(digest)"),
                                    success: false, mechanism: mechanism)
                            }
                            continuation.finish(throwing: AIProviderError.transport("stream cancelled"))
                            return
                        } catch {
                            let elapsed = DispatchTime.now().uptimeNanoseconds &- telemetryStarted
                            if admittedOrdinal != nil || requestBudget == nil {
                                ProviderAttemptObservation.record(
                                    provider: candidate.provider.id, model: currentModel, mechanism: mechanism,
                                    usage: TokenUsage(promptTokens: promptTokens, completionTokens: completionTokens),
                                    usageReported: usageReported, elapsedNanoseconds: elapsed, success: false)
                                let digest = telemetryHasher.finalize().map {
                                    String(format: "%02x", $0)
                                }.joined()
                                BuilderTrustedTelemetry.recordProvider(
                                    providerID: candidate.provider.id, modelID: currentModel,
                                    inputTokens: promptTokens > 0 ? promptTokens : inputTokenUpperBound,
                                    outputTokens: completionTokens > 0
                                        ? completionTokens : outputByteUpperBound,
                                    elapsedMilliseconds: max(1, Int(elapsed / 1_000_000)),
                                    outputDigest: BuilderEvidenceDigest.sha256(
                                        "\(admittedOrdinal ?? 0):\(String(reflecting: type(of: error))):\(digest)"),
                                    success: false, mechanism: mechanism)
                            }
                            if Task.isCancelled {
                                continuation.finish(throwing: AIProviderError.transport("stream cancelled"))
                                return
                            }
                            lastError = ProviderRouteFailure.annotate(
                                error, requested: candidates[0].provider.id,
                                provider: candidate.provider.id, model: currentModel)
                            // Layer B: only safe to re-issue if NOTHING was yielded yet (else we'd double-emit).
                            if routePolicy.allowModelResolution, !yieldedAny, !resolvedModelOnce,
                               ModelResolver.isModelNotFound(error) {
                                do {
                                    if let resolved = try await resolveValidModel(
                                        for: candidate.provider, apiKey: candidate.apiKey,
                                        current: currentModel, routePolicy: routePolicy,
                                        requestBudget: requestBudget
                                    ) {
                                        resolvedModelOnce = true
                                        currentModel = resolved
                                        continue
                                    }
                                } catch {
                                    continuation.finish(throwing: error)
                                    return
                                }
                            }
                            // Codex HIGH: once partial output has been forwarded, NEITHER a same-candidate
                            // retry NOR a cross-provider fallback is safe — re-issuing would append a second
                            // stream's events to what the consumer already received (duplicate/interleaved
                            // output). After any emission, surface the error outward.
                            if yieldedAny {
                                continuation.finish(throwing: lastError ?? error)
                                return
                            }
                            guard Self.shouldRetry(error) else {
                                if candidateIndex < candidates.count - 1, Self.shouldFallback(error) {
                                    break
                                }
                                continuation.finish(throwing: lastError ?? error)
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

    private static func tokenUpperBound(_ messages: [ChatMessage]) -> Int {
        if let encoded = try? JSONEncoder().encode(messages) { return max(1, encoded.count) }
        return max(1, messages.reduce(0) { $0 + $1.content.utf8.count + $1.role.rawValue.utf8.count })
    }

    private static func recordProviderAttempt(
        candidate: StreamCandidate, model: String, mechanism: String,
        ordinal: Int?, messages: [ChatMessage], text: String, usage: TokenUsage,
        success: Bool, started: UInt64, errorType: String? = nil
    ) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- started
        ProviderAttemptObservation.record(
            provider: candidate.provider.id, model: model, mechanism: mechanism, usage: usage,
            usageReported: !usage.isZero, elapsedNanoseconds: elapsed, success: success)
        let input = usage.promptTokens > 0 ? usage.promptTokens : tokenUpperBound(messages)
        let output = usage.completionTokens > 0 ? usage.completionTokens : text.utf8.count
        BuilderTrustedTelemetry.recordProvider(
            providerID: candidate.provider.id, modelID: model,
            inputTokens: input, outputTokens: output,
            elapsedMilliseconds: max(1, Int(elapsed / 1_000_000)),
            outputDigest: BuilderEvidenceDigest.sha256(
                "\(ordinal ?? 0):\(errorType ?? "ok"):\(text)"),
            success: success, mechanism: mechanism)
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
            case .missingAPIKey, .invalidAPIKey, .rateLimited, .transport, .streamTimedOut:
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
