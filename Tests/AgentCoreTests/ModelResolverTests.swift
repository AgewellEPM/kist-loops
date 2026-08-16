import XCTest
@testable import AgentCore

final class ModelResolverTests: XCTestCase {

    // MARK: pure resolution

    func testExactLiveMatchIsKept() {
        XCTAssertEqual(ModelResolver.resolve(requested: "grok-4.3", default: "grok-4.3",
                                             live: ["grok-4.3", "grok-3"]), "grok-4.3")
    }

    func testDeadIdResolvesToNearestSameFamily() {
        // The actual failure: grok-2-latest is gone; resolve to a live GROK model, not another provider.
        let r = ModelResolver.resolve(requested: "grok-2-latest", default: "grok-4.3",
                                      live: ["grok-4.3", "grok-3", "grok-code-fast-1"])
        XCTAssertNotNil(r)
        XCTAssertEqual(ModelResolver.family(r!), "grok")
    }

    func testFallsBackToDefaultWhenNoFamilyMatch() {
        // requested family absent from live → provider default (if live) wins over a random pick.
        let r = ModelResolver.resolve(requested: "zzz-9", default: "gpt-4o", live: ["gpt-4o", "gpt-5.5"])
        XCTAssertEqual(r, "gpt-4o")
    }

    func testEmptyLiveListReturnsNil() {
        XCTAssertNil(ModelResolver.resolve(requested: "anything", default: "x", live: []))
    }

    func testFamilyAndModelNotFoundDetection() {
        XCTAssertEqual(ModelResolver.family("deepseek-v4-pro"), "deepseek")
        XCTAssertEqual(ModelResolver.family("o3-mini"), "o")
        // xAI returns 400 + "Model not found" — must be treated as a model-not-found, not a generic 400.
        XCTAssertTrue(ModelResolver.isModelNotFound(AIProviderError.http(status: 400, body: #"{"error":"Model not found: grok-2-latest"}"#)))
        XCTAssertTrue(ModelResolver.isModelNotFound(AIProviderError.http(status: 404, body: "")))
        XCTAssertFalse(ModelResolver.isModelNotFound(AIProviderError.http(status: 400, body: "bad temperature")))
        XCTAssertFalse(ModelResolver.isModelNotFound(AIProviderError.rateLimited))
    }

    // MARK: registry on-404 self-heal (same provider, resolved model)

    func testRegistryResolvesDeadModelOnSameProvider() async throws {
        // Real OpenAICompatibleProvider so Layer B can derive its /models URL; we inject the live list.
        let grok = OpenAICompatibleProvider(id: "grok", name: "Grok", iconName: "bolt", keyAccount: "grok_api_key",
                                            endpoint: "https://api.x.ai/v1/chat/completions", defaultModel: "grok-2-latest",
                                            availableModels: [AIModel(id: "grok-2-latest")], requiresAPIKey: false)
        // Realistic: ONLY the dead catalog id 404s; any live grok model succeeds.
        let wrapper = DeadIdWrapper(inner: grok, deadModel: "grok-2-latest")
        let reg = ProviderRegistry(providers: [wrapper], keyStore: EmptyKeyStore(), retryDelaysNanoseconds: [],
                                   modelListFetch: { _, _ in .success(["grok-4.3", "grok-3"]) })
        let (text, _) = try await reg.completeWithUsage(providerId: "grok", messages: [], settings: ModelSettings())
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(wrapper.modelsTried.count, 2)                          // 404 then ONE resolved retry
        XCTAssertEqual(wrapper.modelsTried.first, "grok-2-latest")
        XCTAssertEqual(ModelResolver.family(wrapper.modelsTried[1]), "grok")  // resolved to a live GROK model, SAME provider
    }

    func testStreamingPathAlsoResolvesDeadModelOnSameProvider() async throws {
        let grok = OpenAICompatibleProvider(id: "grok", name: "Grok", iconName: "bolt", keyAccount: "grok_api_key",
                                            endpoint: "https://api.x.ai/v1/chat/completions", defaultModel: "grok-2-latest",
                                            availableModels: [AIModel(id: "grok-2-latest")], requiresAPIKey: false)
        let wrapper = DeadIdWrapper(inner: grok, deadModel: "grok-2-latest")
        let reg = ProviderRegistry(providers: [wrapper], keyStore: EmptyKeyStore(), retryDelaysNanoseconds: [],
                                   modelListFetch: { _, _ in .success(["grok-4.3", "grok-3"]) })
        // The interactive REPL path is stream(); it must resolve the dead id, not cross-provider fallback.
        var text = ""
        for try await event in try await reg.stream(providerId: "grok", model: nil, messages: [], settings: ModelSettings()) {
            if case .delta(let d) = event { text += d }
        }
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(wrapper.modelsTried.count, 2)
        XCTAssertEqual(wrapper.modelsTried.first, "grok-2-latest")
        XCTAssertEqual(ModelResolver.family(wrapper.modelsTried[1]), "grok")
    }

    func testModelDiscoveryConsumesBudgetBeforeNetworkAndBeforeResolvedRetry() async throws {
        func makeRegistry(_ fetches: LockedModelFetchCounter) -> (ProviderRegistry, DeadIdWrapper) {
            let inner = OpenAICompatibleProvider(
                id: "grok", name: "Grok", iconName: "bolt", keyAccount: "grok_api_key",
                endpoint: "https://api.x.ai/v1/chat/completions", defaultModel: "dead-model",
                availableModels: [AIModel(id: "dead-model")], requiresAPIKey: false)
            let wrapper = DeadIdWrapper(inner: inner, deadModel: "dead-model")
            let registry = ProviderRegistry(
                providers: [wrapper], keyStore: EmptyKeyStore(), retryDelaysNanoseconds: [],
                modelListFetch: { _, _ in
                    fetches.increment()
                    return .success(["live-model"])
                })
            return (registry, wrapper)
        }

        let deniedFetches = LockedModelFetchCounter()
        let (deniedRegistry, deniedProvider) = makeRegistry(deniedFetches)
        let oneSlot = ProviderRequestBudget(limit: 1)
        do {
            _ = try await deniedRegistry.completeWithUsage(
                providerId: "grok", messages: [], settings: ModelSettings(),
                requestBudget: oneSlot)
            XCTFail("model discovery must not issue without its own slot")
        } catch let error as ProviderRequestBudgetError {
            XCTAssertEqual(error, .exhausted(limit: 1, consumed: 1))
        }
        XCTAssertEqual(deniedFetches.value, 0)
        XCTAssertEqual(deniedProvider.modelsTried, ["dead-model"])

        let allowedFetches = LockedModelFetchCounter()
        let (allowedRegistry, allowedProvider) = makeRegistry(allowedFetches)
        let threeSlots = ProviderRequestBudget(limit: 3)
        let result = try await allowedRegistry.completeWithUsage(
            providerId: "grok", messages: [], settings: ModelSettings(),
            requestBudget: threeSlots)
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(allowedFetches.value, 1)
        XCTAssertEqual(allowedProvider.modelsTried, ["dead-model", "live-model"])
        let consumed = await threeSlots.consumedCount()
        XCTAssertEqual(consumed, 3,
                       "dead request + /models discovery + resolved retry")
    }

    /// Wraps an OpenAICompatibleProvider (so Layer B sees its /models endpoint) but overrides stream() to
    /// simulate the dead-id 404 → valid-id success behavior.
    private final class DeadIdWrapper: ChatProvider, @unchecked Sendable {
        let inner: OpenAICompatibleProvider
        let deadModel: String
        private(set) var modelsTried: [String] = []
        init(inner: OpenAICompatibleProvider, deadModel: String) { self.inner = inner; self.deadModel = deadModel }
        var id: String { inner.id }
        var name: String { inner.name }
        var iconName: String { inner.iconName }
        var requiresAPIKey: Bool { inner.requiresAPIKey }
        var keyAccount: String { inner.keyAccount }
        var defaultModel: String { inner.defaultModel }
        var availableModels: [AIModel] { inner.availableModels }
        var modelsListEndpoint: String? { inner.modelsListEndpoint }   // Layer B sees grok's /models URL
        func capabilities(forModel model: String) -> ModelCapabilities { inner.capabilities(forModel: model) }
        func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
            modelsTried.append(model)
            if model == deadModel {
                return AsyncThrowingStream { c in c.finish(throwing: AIProviderError.http(status: 400, body: "Model not found: \(model)")) }
            }
            return AsyncThrowingStream { c in c.yield(.delta("ok")); c.yield(.finish(reason: "stop")); c.finish() }
        }
    }
}

private struct EmptyKeyStore: KeyStore { func key(forAccount account: String) -> String? { nil } }

private final class LockedModelFetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
