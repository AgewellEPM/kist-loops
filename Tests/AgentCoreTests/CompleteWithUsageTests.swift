import XCTest
@testable import AgentCore

/// `completeWithUsage` must return both the text AND the measured token usage (the `.usage` event),
/// which `complete` (collectText) drops — the basis for the cost/observability layers.
final class CompleteWithUsageTests: XCTestCase {

    func testCapturesTextAndUsage() async throws {
        let registry = ProviderRegistry(providers: [UsageProvider(text: "hello world", prompt: 120, completion: 8)],
                                        keyStore: UsageNullKeys())
        let (text, usage) = try await registry.completeWithUsage(providerId: "usage", messages: [ChatMessage(role: .user, content: "hi")])
        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(usage.promptTokens, 120)
        XCTAssertEqual(usage.completionTokens, 8)
        XCTAssertEqual(usage.total, 128)
    }

    func testUsageZeroWhenProviderOmitsIt() async throws {
        let registry = ProviderRegistry(providers: [UsageProvider(text: "no usage", prompt: nil, completion: nil)],
                                        keyStore: UsageNullKeys())
        let (text, usage) = try await registry.completeWithUsage(providerId: "usage", messages: [ChatMessage(role: .user, content: "hi")])
        XCTAssertEqual(text, "no usage")
        XCTAssertTrue(usage.isZero)   // caller may then fall back to an estimate
    }

    func testEmptyCompletionFallsBackWhenAllowed() async throws {
        let registry = ProviderRegistry(
            providers: [
                UsageProvider(id: "primary", text: "  \n", prompt: 1, completion: 0),
                UsageProvider(id: "backup", text: "backup text", prompt: 2, completion: 3),
            ],
            keyStore: UsageNullKeys(),
            fallbackProviderIds: ["primary": ["backup"]],
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )

        let (text, usage) = try await registry.completeWithUsage(providerId: "primary",
                                                                 messages: [ChatMessage(role: .user, content: "hi")])

        XCTAssertEqual(text, "backup text")
        XCTAssertEqual(usage.total, 5)
    }

    func testEmptyCompletionFailsWhenFallbackDisabled() async throws {
        let registry = ProviderRegistry(
            providers: [
                UsageProvider(id: "primary", text: "  \n", prompt: 1, completion: 0),
                UsageProvider(id: "backup", text: "backup text", prompt: 2, completion: 3),
            ],
            keyStore: UsageNullKeys(),
            fallbackProviderIds: ["primary": ["backup"]],
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )

        do {
            _ = try await registry.completeWithUsage(providerId: "primary",
                                                     messages: [ChatMessage(role: .user, content: "hi")],
                                                     allowFallback: false)
            XCTFail("expected empty primary completion to fail without fallback")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .transport("empty completion from primary:u1"))
        }
    }

    func testCancellationDoesNotFallBackToAnotherProvider() async throws {
        let registry = ProviderRegistry(
            providers: [
                CancellingProvider(id: "primary"),
                UsageProvider(id: "backup", text: "backup text", prompt: 2, completion: 3),
            ],
            keyStore: UsageNullKeys(),
            fallbackProviderIds: ["primary": ["backup"]],
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )

        do {
            _ = try await registry.completeWithUsage(providerId: "primary",
                                                     messages: [ChatMessage(role: .user, content: "hi")])
            XCTFail("expected cancellation to stop instead of falling back")
        } catch let error as AIProviderError {
            XCTAssertEqual(error, .transport("completion cancelled"))
        }
    }

    func testTokenUsageHelpers() {
        XCTAssertTrue(TokenUsage.zero.isZero)
        XCTAssertEqual(TokenUsage(promptTokens: 3, completionTokens: 4).total, 7)
        XCTAssertFalse(TokenUsage(promptTokens: 1, completionTokens: 0).isZero)
    }
}

private struct CancellingProvider: ChatProvider {
    let id: String
    let name = "Cancel", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "cancel", defaultModel = "u1"
    let availableModels = [AIModel(id: "u1")]

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw CancellationError()
    }
}

private struct UsageNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

/// Emits a text delta then optionally a `.usage` event (mirrors OpenAI's include_usage final chunk).
private struct UsageProvider: ChatProvider {
    let id: String
    let name = "Usage", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "usage", defaultModel = "u1"
    let availableModels = [AIModel(id: "u1")]
    let text: String; let prompt: Int?; let completion: Int?

    init(id: String = "usage", text: String, prompt: Int?, completion: Int?) {
        self.id = id
        self.text = text
        self.prompt = prompt
        self.completion = completion
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let t = text, p = prompt, c = completion
        return AsyncThrowingStream { cont in
            cont.yield(.delta(t))
            if let p, let c { cont.yield(.usage(promptTokens: p, completionTokens: c)) }
            cont.finish()
        }
    }
}
