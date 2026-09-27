import XCTest
@testable import AgentCore

/// The registry reports every candidate that finishes failing (0.17.63) so the host can bench it
/// cross-process. A planner that hit its quota INSIDE a plan-execute mission was benched by
/// nothing before this, and the next run walked straight back into it.
final class ProviderLiveFailureObserverTests: XCTestCase {
    private final class Observed: @unchecked Sendable {
        private let lock = NSLock(); private var _events: [(String, String)] = []
        func record(_ id: String, _ error: Error) { lock.lock(); _events.append((id, "\(error)")); lock.unlock() }
        var events: [(String, String)] { lock.lock(); defer { lock.unlock() }; return _events }
    }

    private func registry(_ providers: [any ChatProvider], observed: Observed,
                          fallback: [String: [String]] = [:]) -> ProviderRegistry {
        ProviderRegistry(providers: providers, keyStore: LFNullKeys(), fallbackProviderIds: fallback,
                         retryDelaysNanoseconds: [0, 0],
                         liveFailureObserver: { id, error in observed.record(id, error) })
    }

    func testExhaustedRetriesReportTheFailedCandidateOnce() async {
        let observed = Observed()
        let registry = registry([LFScriptedProvider(id: "openai", failure: .rateLimited, failAttempts: 99)],
                                observed: observed)
        do {
            _ = try await registry.complete(providerId: "openai", messages: [ChatMessage(role: .user, content: "hi")])
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(observed.events.map(\.0), ["openai"], "one report per finished candidate, not per retry")
        XCTAssertTrue(observed.events.first?.1.contains("rateLimited") == true)
    }

    func testTerminalNonRetryableFailureIsReportedAndFallbackCandidateIsReportedSeparately() async {
        let observed = Observed()
        let registry = registry(
            [LFScriptedProvider(id: "openai", failure: .invalidAPIKey, failAttempts: 99),
             LFScriptedProvider(id: "gemini", failure: .rateLimited, failAttempts: 99)],
            observed: observed, fallback: ["openai": ["gemini"]])
        do {
            _ = try await registry.complete(providerId: "openai", messages: [ChatMessage(role: .user, content: "hi")],
                                            allowFallback: true)
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(observed.events.map(\.0), ["openai", "gemini"], "each failed candidate reports itself")
    }

    func testRecoveredRetryReportsNothing() async throws {
        let observed = Observed()
        let registry = registry([LFScriptedProvider(id: "openai", failure: .rateLimited, failAttempts: 1)],
                                observed: observed)
        let text = try await registry.complete(providerId: "openai", messages: [ChatMessage(role: .user, content: "hi")])
        XCTAssertEqual(text, "ok")
        XCTAssertTrue(observed.events.isEmpty, "a provider that recovered within its retries is not benched")
    }

    func testStreamingPathReportsExhaustedCandidateToo() async {
        let observed = Observed()
        let registry = registry([LFScriptedProvider(id: "deepseek", failure: .transport("reset"), failAttempts: 99)],
                                observed: observed)
        do {
            let stream = try await registry.stream(providerId: "deepseek", model: nil,
                                                   messages: [ChatMessage(role: .user, content: "hi")],
                                                   settings: ModelSettings())
            for try await _ in stream {}
            XCTFail("expected failure")
        } catch {}
        XCTAssertEqual(observed.events.map(\.0), ["deepseek"])
    }
}

// MARK: - fixtures

private struct LFNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

/// Fails the first `failAttempts` calls with `failure`, then answers "ok".
private final class LFScriptedProvider: ChatProvider, @unchecked Sendable {
    let id: String, name = "LF", iconName = "cpu"
    let requiresAPIKey = false, keyAccount: String, defaultModel = "m"
    let availableModels = [AIModel(id: "m")]
    private let lock = NSLock(); private var calls = 0
    private let failure: AIProviderError; private let failAttempts: Int
    init(id: String, failure: AIProviderError, failAttempts: Int) {
        self.id = id; self.keyAccount = id; self.failure = failure; self.failAttempts = failAttempts
    }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); calls += 1; let n = calls; lock.unlock()
        if n <= failAttempts { throw failure }
        return AsyncThrowingStream { c in c.yield(.delta("ok")); c.finish() }
    }
}
