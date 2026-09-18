import XCTest
@testable import AgentCore

final class ProviderRetryTests: XCTestCase {
    func testFallbackFailureNamesTheActualProviderAndPreservesFaultClassification() async throws {
        for mode in 0..<3 {
            let registry = ProviderRegistry(providers: [
                FlakyProvider(id: "openai", attempts: AttemptCounter(), failure: .rateLimited, failAttempts: 99),
                FlakyProvider(id: "ollama", attempts: AttemptCounter(),
                    failure: .http(status: 404, body: "model missing"), failAttempts: 99)
            ], fallbackProviderIds: ["openai": ["ollama"]], retryDelaysNanoseconds: [])
            let messages = [ChatMessage(role: .user, content: "test")]
            do {
                if mode == 0 {
                    _ = try await registry.complete(providerId: "openai", messages: messages,
                        routePolicy: ProviderRoutePolicy(allowFallback: true, allowModelResolution: false,
                                                         allowModelDiscovery: false))
                } else {
                    let policy = ProviderRoutePolicy(allowFallback: true, allowModelResolution: false,
                                                     allowModelDiscovery: false)
                    let stream = mode == 1
                        ? try await registry.stream(providerId: "openai", model: nil, messages: messages,
                            settings: ModelSettings(), routePolicy: policy)
                        : try await registry.streamTools(providerId: "openai", model: nil, messages: messages,
                            settings: ModelSettings(), tools: [], routePolicy: policy)
                    _ = try await stream.collectText()
                }
                XCTFail("expected fallback failure")
            } catch let error as ProviderRouteFailure {
                XCTAssertEqual(error.provider, "ollama")
                XCTAssertEqual(error.model, "f1")
                XCTAssertEqual(error.requestedProvider, "openai")
                XCTAssertFalse(ProviderFault.isProviderFault(error))
                XCTAssertTrue(error.description.contains("provider 'ollama'"))
            } catch { XCTFail("missing actual route: \(error)") }
        }
    }

    func testRetriesRetryableFailureThrownDuringStreamConsumption() async throws {
        let attempts = AttemptCounter()
        let registry = ProviderRegistry(
            providers: [FlakyProvider(attempts: attempts, failure: .rateLimited, failAttempts: 1)],
            keyStore: RetryNullKeys(),
            retryDelaysNanoseconds: [0]
        )

        let text = try await registry.complete(providerId: "flaky", messages: [ChatMessage(role: .user, content: "hi")])

        XCTAssertEqual(text, "ok")
        let count = await attempts.count()
        XCTAssertEqual(count, 2)
    }

    // FLAKINESS SIGNAL: a retry that RECOVERS still increments retryCount — that's the whole point (the
    // great-loop routes around a flaky-but-not-down provider whose 5xx are absorbed here). AND the output
    // is still exactly correct (no double-emission on the retry path — the invariant this file guards).
    func testRecoveredRetryIncrementsFlakinessCountAndDoesNotDoubleEmit() async throws {
        let registry = ProviderRegistry(
            providers: [FlakyProvider(attempts: AttemptCounter(), failure: .rateLimited, failAttempts: 1)],
            keyStore: RetryNullKeys(), retryDelaysNanoseconds: [0])
        XCTAssertEqual(registry.retryCount(providerId: "flaky"), 0)
        let text = try await registry.complete(providerId: "flaky", messages: [ChatMessage(role: .user, content: "hi")])
        XCTAssertEqual(text, "ok", "output correct exactly once — no double-emission after the retry")
        XCTAssertEqual(registry.retryCount(providerId: "flaky"), 1, "one recovered retry is counted as flakiness")
    }

    func testStreamingRetryIncrementsFlakinessCount() async throws {
        let registry = ProviderRegistry(
            providers: [FlakyProvider(attempts: AttemptCounter(), failure: .http(status: 503, body: "unavailable"), failAttempts: 2)],
            keyStore: RetryNullKeys(), retryDelaysNanoseconds: [0, 0])
        let stream = try await registry.streamTools(providerId: "flaky", model: nil,
                                                    messages: [ChatMessage(role: .user, content: "hi")],
                                                    settings: ModelSettings(), tools: [])
        let text = try await stream.collectText()
        XCTAssertEqual(text, "native-ok")
        XCTAssertEqual(registry.retryCount(providerId: "flaky"), 2, "two streaming retries counted")
    }

    func testNonRetryableFailureIsNotCountedAsFlakiness() async {
        let registry = ProviderRegistry(
            providers: [FlakyProvider(attempts: AttemptCounter(), failure: .invalidAPIKey, failAttempts: 5)],
            keyStore: RetryNullKeys(), retryDelaysNanoseconds: [0, 0, 0])
        _ = try? await registry.complete(providerId: "flaky", messages: [ChatMessage(role: .user, content: "hi")])
        XCTAssertEqual(registry.retryCount(providerId: "flaky"), 0, "auth failure is not retried → not flakiness")
    }

    func testDoesNotRetryNonRetryableProviderFailure() async {
        let attempts = AttemptCounter()
        let registry = ProviderRegistry(
            providers: [FlakyProvider(attempts: attempts, failure: .invalidAPIKey, failAttempts: 5)],
            keyStore: RetryNullKeys(),
            retryDelaysNanoseconds: [0, 0, 0]
        )

        do {
            _ = try await registry.complete(providerId: "flaky", messages: [ChatMessage(role: .user, content: "hi")])
            XCTFail("expected invalid API key to fail without retry")
        } catch {
            let count = await attempts.count()
            XCTAssertEqual(count, 1)
        }
    }

    func testRetriesNativeToolStreamToo() async throws {
        let attempts = AttemptCounter()
        let registry = ProviderRegistry(
            providers: [FlakyProvider(attempts: attempts, failure: .http(status: 502, body: "bad gateway"), failAttempts: 1)],
            keyStore: RetryNullKeys(),
            retryDelaysNanoseconds: [0]
        )

        let stream = try await registry.streamTools(
            providerId: "flaky",
            model: nil,
            messages: [ChatMessage(role: .user, content: "hi")],
            settings: ModelSettings(),
            tools: []
        )
        let text = try await stream.collectText()

        XCTAssertEqual(text, "native-ok")
        let count = await attempts.count()
        XCTAssertEqual(count, 2)
    }

    func testFailsOverToExplicitFallbackProviderAfterRetryBudget() async throws {
        let primaryAttempts = AttemptCounter()
        let fallbackAttempts = AttemptCounter()
        let registry = ProviderRegistry(
            providers: [
                FlakyProvider(id: "primary", attempts: primaryAttempts, failure: .rateLimited, failAttempts: 10),
                SuccessProvider(id: "backup", attempts: fallbackAttempts, text: "backup-ok"),
            ],
            keyStore: RetryNullKeys(),
            fallbackProviderIds: ["primary": ["backup"]],
            retryDelaysNanoseconds: [0]
        )

        let text = try await registry.complete(providerId: "primary", messages: [ChatMessage(role: .user, content: "hi")],
                                               allowFallback: true)

        XCTAssertEqual(text, "backup-ok")
        let primaryCount = await primaryAttempts.count()
        let fallbackCount = await fallbackAttempts.count()
        XCTAssertEqual(primaryCount, 2)
        XCTAssertEqual(fallbackCount, 1)
    }

    func testFailsOverToFallbackProviderForStaleModel404() async throws {
        let primaryAttempts = AttemptCounter()
        let fallbackAttempts = AttemptCounter()
        let registry = ProviderRegistry(
            providers: [
                FlakyProvider(id: "grok", attempts: primaryAttempts,
                              failure: .http(status: 404, body: "model grok-2-latest does not exist"),
                              failAttempts: 10),
                SuccessProvider(id: "openai", attempts: fallbackAttempts, text: "fallback-ok"),
            ],
            keyStore: RetryNullKeys(),
            fallbackProviderIds: ["grok": ["openai"]],
            retryDelaysNanoseconds: [0]
        )

        let text = try await registry.complete(providerId: "grok", messages: [ChatMessage(role: .user, content: "hi")],
                                               allowFallback: true)

        XCTAssertEqual(text, "fallback-ok")
        let primaryCount = await primaryAttempts.count()
        let fallbackCount = await fallbackAttempts.count()
        XCTAssertEqual(primaryCount, 1)
        XCTAssertEqual(fallbackCount, 1)
    }

    func testDoesNotFallbackForBadRequestTranscriptBug() async {
        let primaryAttempts = AttemptCounter()
        let fallbackAttempts = AttemptCounter()
        let registry = ProviderRegistry(
            providers: [
                FlakyProvider(id: "primary", attempts: primaryAttempts,
                              failure: .http(status: 400, body: "bad request malformed tool result"),
                              failAttempts: 10),
                SuccessProvider(id: "backup", attempts: fallbackAttempts, text: "backup-ok"),
            ],
            keyStore: RetryNullKeys(),
            fallbackProviderIds: ["primary": ["backup"]],
            retryDelaysNanoseconds: [0]
        )

        do {
            _ = try await registry.complete(providerId: "primary", messages: [ChatMessage(role: .user, content: "hi")])
            XCTFail("expected bad request to fail on the primary")
        } catch {
            let primaryCount = await primaryAttempts.count()
            let fallbackCount = await fallbackAttempts.count()
            XCTAssertEqual(primaryCount, 1)
            XCTAssertEqual(fallbackCount, 0)
        }
    }
}

private struct RetryNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private actor AttemptCounter {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
    func count() -> Int { value }
}

private final class FlakyProvider: ChatProvider, @unchecked Sendable {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel = "f1"
    let availableModels = [AIModel(id: "f1")]
    var supportsNativeTools: Bool { true }

    private let attempts: AttemptCounter
    private let failure: AIProviderError
    private let failAttempts: Int

    init(id: String = "flaky", attempts: AttemptCounter, failure: AIProviderError, failAttempts: Int) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.attempts = attempts
        self.failure = failure
        self.failAttempts = failAttempts
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let attempt = await attempts.next()
        let failure = self.failure
        let failAttempts = self.failAttempts
        return AsyncThrowingStream { continuation in
            if attempt <= failAttempts {
                continuation.finish(throwing: failure)
            } else {
                continuation.yield(.delta("ok"))
                continuation.finish()
            }
        }
    }

    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let attempt = await attempts.next()
        let failure = self.failure
        let failAttempts = self.failAttempts
        return AsyncThrowingStream { continuation in
            if attempt <= failAttempts {
                continuation.finish(throwing: failure)
            } else {
                continuation.yield(.delta("native-ok"))
                continuation.finish()
            }
        }
    }
}

private final class SuccessProvider: ChatProvider, @unchecked Sendable {
    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel = "s1"
    let availableModels = [AIModel(id: "s1")]

    private let attempts: AttemptCounter
    private let text: String

    init(id: String, attempts: AttemptCounter, text: String) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.attempts = attempts
        self.text = text
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        _ = await attempts.next()
        let text = self.text
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(text))
            continuation.finish()
        }
    }
}
