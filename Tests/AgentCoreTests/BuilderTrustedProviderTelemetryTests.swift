import XCTest
@testable import AgentCore

final class BuilderTrustedProviderTelemetryTests: XCTestCase {
    private func capture<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> (Result<T, any Error>, [BuilderTrustedTelemetryObservation]) {
        await BuilderTrustedTelemetry.captureScope(
            binding: try BuilderTrustedTelemetryBinding(
                contractFingerprint: String(repeating: "a", count: 64),
                nodeID: "telemetry-test", attempt: 1, stage: .build),
            registerBudgetAuthority: false,
            operation: operation)
    }

    func testCompletionRetryAndFallbackRecordsEveryConcreteRoute() async throws {
        let primary = TelemetrySequenceProvider(
            id: "primary", steps: [.failure(.rateLimited), .failure(.rateLimited)])
        let backup = TelemetrySequenceProvider(id: "backup", steps: [.success("ok", nil)])
        let registry = ProviderRegistry(
            providers: [primary, backup], fallbackProviderIds: ["primary": ["backup"]],
            retryDelaysNanoseconds: [0], retrySleep: { _ in })

        let captured = try await capture {
            try await registry.completeWithRoute(
                providerId: "primary",
                messages: [ChatMessage(role: .user, content: "build it")],
                allowFallback: true)
        }
        XCTAssertEqual(try captured.0.get().text, "ok")
        let providers = captured.1.filter { $0.kind == .provider }
        XCTAssertEqual(providers.map(\.providerID), ["primary", "primary", "backup"])
        XCTAssertEqual(providers.map(\.success), [false, false, true])
        XCTAssertTrue(providers.allSatisfy { $0.inputTokens + $0.outputTokens > 0 })
    }

    func testUsageLessProviderGetsConservativeMeasuredUpperBound() async throws {
        let provider = TelemetrySequenceProvider(id: "cli", steps: [.success("answer", nil)])
        let registry = ProviderRegistry(providers: [provider], retryDelaysNanoseconds: [])
        let captured = try await capture {
            try await registry.completeWithRoute(
                providerId: "cli", messages: [ChatMessage(role: .user, content: "hi")])
        }
        _ = try captured.0.get()
        let route = try XCTUnwrap(captured.1.first { $0.kind == .provider })
        XCTAssertEqual(route.providerID, "cli")
        XCTAssertGreaterThan(route.inputTokens, 0)
        XCTAssertGreaterThan(route.outputTokens, 0)
    }

    func testStreamToolsRetryRecordsFailureAndSuccess() async throws {
        let provider = TelemetrySequenceProvider(
            id: "native", native: true,
            steps: [.failure(.http(status: 503, body: "offline")), .success("tool-ok", nil)])
        let registry = ProviderRegistry(
            providers: [provider], retryDelaysNanoseconds: [0], retrySleep: { _ in })
        let captured = try await capture {
            let stream = try await registry.streamTools(
                providerId: "native", model: nil,
                messages: [ChatMessage(role: .user, content: "use tool")],
                settings: ModelSettings(), tools: [])
            return try await stream.collectText()
        }
        XCTAssertEqual(try captured.0.get(), "tool-ok")
        let attempts = captured.1.filter { $0.kind == .provider }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.map(\.success), [false, true])
        XCTAssertTrue(attempts.allSatisfy { $0.name == "stream-tools" })
    }

    func testModelResolutionRecordsFailedRequestDiscoveryAndResolvedRequest() async throws {
        let provider = TelemetrySequenceProvider(
            id: "model-heal", modelsEndpoint: "https://example.invalid/models",
            steps: [
                .failure(.http(status: 404, body: "model not found")),
                .success("resolved", nil),
            ])
        let registry = ProviderRegistry(
            providers: [provider], retryDelaysNanoseconds: [],
            modelListFetch: { _, _ in .success(["live-model"]) })
        let captured = try await capture {
            try await registry.completeWithRoute(
                providerId: "model-heal", model: "dead-model",
                messages: [ChatMessage(role: .user, content: "go")])
        }
        XCTAssertEqual(try captured.0.get().text, "resolved")
        let attempts = captured.1.filter { $0.kind == .provider }
        XCTAssertEqual(attempts.map(\.name), ["completion-attempt", "model-discovery", "completion"])
        XCTAssertEqual(attempts.map(\.success), [false, true, true])
    }

    func testThrowingScopeRetainsFailedProviderAttempt() async throws {
        let provider = TelemetrySequenceProvider(
            id: "broken", steps: [.failure(.invalidAPIKey)])
        let registry = ProviderRegistry(providers: [provider], retryDelaysNanoseconds: [])
        let captured = try await capture {
            try await registry.completeWithRoute(
                providerId: "broken", messages: [ChatMessage(role: .user, content: "go")])
        }
        XCTAssertThrowsError(try captured.0.get())
        let attempt = try XCTUnwrap(captured.1.first { $0.kind == .provider })
        XCTAssertEqual(attempt.providerID, "broken")
        XCTAssertFalse(attempt.success)
        XCTAssertGreaterThan(attempt.inputTokens, 0)
    }

    func testDeniedAdmissionAndUnknownProviderEmitNoForgedProviderRoute() async throws {
        let provider = TelemetrySequenceProvider(id: "only", steps: [.success("never", nil)])
        let registry = ProviderRegistry(providers: [provider], retryDelaysNanoseconds: [])
        let denied = try await capture {
            try await registry.completeWithRoute(
                providerId: "only", messages: [ChatMessage(role: .user, content: "go")],
                requestBudget: ProviderRequestBudget(limit: 0))
        }
        XCTAssertThrowsError(try denied.0.get())
        XCTAssertTrue(denied.1.filter { $0.kind == .provider }.isEmpty)
        XCTAssertTrue(denied.1.contains { $0.kind == .tool && $0.name == "provider-admission" })

        let unknown = try await capture {
            try await registry.completeWithRoute(
                providerId: "missing", messages: [ChatMessage(role: .user, content: "go")])
        }
        XCTAssertThrowsError(try unknown.0.get())
        XCTAssertTrue(unknown.1.filter { $0.kind == .provider }.isEmpty)
        XCTAssertTrue(unknown.1.contains { $0.kind == .tool && $0.name == "provider-routing" })
    }
}

private final class TelemetrySequenceProvider: ChatProvider, @unchecked Sendable {
    enum Step: Sendable {
        case failure(AIProviderError)
        case success(String, TokenUsage?)
    }

    let id: String
    let name: String
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel = "dead-model"
    let availableModels = [AIModel(id: "dead-model"), AIModel(id: "live-model")]
    let supportsNativeTools: Bool
    let modelsListEndpoint: String?
    private let lock = NSLock()
    private var steps: [Step]

    init(id: String, native: Bool = false, modelsEndpoint: String? = nil,
         steps: [Step]) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.supportsNativeTools = native
        self.modelsListEndpoint = modelsEndpoint
        self.steps = steps
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        makeStream()
    }

    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings,
                     apiKey: String?, tools: [ToolSpec]) async throws
        -> AsyncThrowingStream<StreamEvent, Error> {
        makeStream()
    }

    private func makeStream() -> AsyncThrowingStream<StreamEvent, Error> {
        let step = lock.withLock { steps.isEmpty ? .success("ok", nil) : steps.removeFirst() }
        return AsyncThrowingStream { continuation in
            switch step {
            case .failure(let error):
                continuation.finish(throwing: error)
            case .success(let text, let usage):
                continuation.yield(.delta(text))
                if let usage {
                    continuation.yield(.usage(
                        promptTokens: usage.promptTokens,
                        completionTokens: usage.completionTokens))
                }
                continuation.finish()
            }
        }
    }
}
