import XCTest
@testable import AgentCore

/// Layer A of the provider-resilience plan: reasoning models get budget headroom so their hidden reasoning
/// can't truncate the visible answer to empty, and an empty-because-truncated completion SELF-HEALS on the
/// SAME model (bigger budget) instead of silently switching providers.
final class ReasoningBudgetSelfHealTests: XCTestCase {

    private func provider(_ id: String, models: [AIModel], nativeTools: Bool = true) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(id: id, name: id, iconName: "cpu", keyAccount: "\(id)_api_key",
                                 endpoint: "https://example/v1/chat/completions", defaultModel: models[0].id,
                                 availableModels: models, nativeToolsSupported: nativeTools)
    }

    // MARK: reasoning detection + budget floor (request build)

    func testReasoningFamiliesAreDetected() {
        for m in ["mimo-v2.5-pro", "deepseek-reasoner", "o3-mini", "gpt-5.5", "qwq-32b", "some-thinking-model", "deepseek-r1"] {
            XCTAssertTrue(OpenAICompatibleProvider.modelLooksLikeReasoning(m), "\(m) should be reasoning")
        }
        for m in ["gpt-4o", "deepseek-v4", "glm-4.6", "grok-4.3", "llama3.1"] {
            XCTAssertFalse(OpenAICompatibleProvider.modelLooksLikeReasoning(m), "\(m) should NOT be reasoning")
        }
    }

    func testReasoningModelBudgetIsFlooredEvenWhenCallerAsksSmall() {
        let p = provider("mimo", models: [AIModel(id: "mimo-v2.5-pro")])
        // Caller asks for a tiny 600-token answer — a reasoning model would burn that on thinking → empty.
        let body = p.makeBody(messages: [], model: "mimo-v2.5-pro",
                              settings: ModelSettings(maxTokens: 600), stream: false)
        XCTAssertEqual(body["max_tokens"] as? Int, OpenAICompatibleProvider.reasoningTokenFloor)
    }

    func testNonReasoningModelBudgetIsUnchanged() {
        let p = provider("openai", models: [AIModel(id: "gpt-4o")])
        let body = p.makeBody(messages: [], model: "gpt-4o", settings: ModelSettings(maxTokens: 600), stream: false)
        XCTAssertEqual(body["max_tokens"] as? Int, 600)
    }

    func testDisableThinkingRespectsTheTightBudget() {
        // A tight agent loop that explicitly disabled thinking keeps its small budget (no floor).
        let p = provider("mimo", models: [AIModel(id: "mimo-v2.5-pro")])
        let body = p.makeBody(messages: [], model: "mimo-v2.5-pro",
                              settings: ModelSettings(maxTokens: 600, disableThinking: true), stream: false)
        XCTAssertEqual(body["max_tokens"] as? Int, 600)
    }

    // MARK: registry self-heal (completeWithUsage)

    /// Stub that mimics a reasoning model: with a small budget it spends everything on reasoning and emits
    /// NO content (finish=length); with a big budget it answers. Records every budget it was called with.
    private final class TruncatingReasoner: ChatProvider, @unchecked Sendable {
        let id = "stub"; let name = "stub"; let requiresAPIKey = false
        let keyAccount = "stub_api_key"; let defaultModel = "stub-reasoner"
        let availableModels = [AIModel(id: "stub-reasoner")]
        let threshold: Int
        private(set) var budgetsSeen: [Int] = []
        init(threshold: Int) { self.threshold = threshold }
        func capabilities(forModel model: String) -> ModelCapabilities { ModelCapabilities(nativeTools: false, reasoning: true) }
        func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
            budgetsSeen.append(settings.maxTokens)
            let enough = settings.maxTokens >= threshold
            return AsyncThrowingStream { c in
                if enough {
                    c.yield(.delta("the answer"))
                    c.yield(.finish(reason: "stop"))
                } else {
                    c.yield(.reasoning("thinking hard…"))   // burned the budget on hidden reasoning
                    c.yield(.finish(reason: "length"))
                }
                c.yield(.usage(promptTokens: 5, completionTokens: 5))
                c.finish()
            }
        }
    }

    func testSelfHealRetriesSameModelWithBiggerBudget() async throws {
        let stub = TruncatingReasoner(threshold: 16000)   // needs ~16k to answer
        let reg = ProviderRegistry(providers: [stub], keyStore: EmptyKeyStore(), retryDelaysNanoseconds: [])
        let (text, _) = try await reg.completeWithUsage(providerId: "stub", messages: [],
                                                        settings: ModelSettings(maxTokens: 4096))
        XCTAssertEqual(text, "the answer")
        XCTAssertGreaterThan(stub.budgetsSeen.count, 1, "should have retried the SAME model with a bigger budget")
        XCTAssertGreaterThanOrEqual(stub.budgetsSeen.last ?? 0, 16000)
    }

    /// A model that is empty for a NON-reasoning reason (no reasoning, natural stop) must NOT self-heal
    /// forever — it surfaces as an error after bounded attempts.
    private struct AlwaysEmpty: ChatProvider {
        let id = "empty"; let name = "empty"; let requiresAPIKey = false
        let keyAccount = "empty_api_key"; let defaultModel = "m"; let availableModels = [AIModel(id: "m")]
        func capabilities(forModel model: String) -> ModelCapabilities { ModelCapabilities(nativeTools: false) }
        func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { c in c.yield(.finish(reason: "stop")); c.finish() }
        }
    }

    func testGenuinelyEmptyDoesNotSelfHealAndSurfaces() async {
        let reg = ProviderRegistry(providers: [AlwaysEmpty()], keyStore: EmptyKeyStore(), retryDelaysNanoseconds: [])
        do {
            _ = try await reg.completeWithUsage(providerId: "empty", messages: [], settings: ModelSettings())
            XCTFail("expected an empty-completion error, not an infinite heal")
        } catch { /* expected */ }
    }
}

/// A KeyStore that returns no keys — fine for stub providers with requiresAPIKey=false.
private struct EmptyKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
}
