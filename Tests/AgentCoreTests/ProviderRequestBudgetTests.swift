import XCTest
import Foundation
@testable import AgentCore

final class ProviderRequestBudgetTests: XCTestCase {
    func testRetriesAndFallbackCandidatesEachConsumeOneRequestSlot() async throws {
        let primary = RequestCountingProvider(id: "primary", behavior: .transportFailure)
        let fallback = RequestCountingProvider(id: "fallback", behavior: .success("fallback ok"))
        let registry = ProviderRegistry(
            providers: [primary, fallback],
            fallbackProviderIds: ["primary": ["fallback"]],
            retryDelaysNanoseconds: [0])

        let tooSmall = ProviderRequestBudget(limit: 2)
        do {
            let stream = try await registry.stream(
                providerId: "primary", model: nil,
                messages: [ChatMessage(role: .user, content: "go")],
                settings: ModelSettings(), allowFallback: true,
                requestBudget: tooSmall)
            _ = try await stream.collectText()
            XCTFail("the fallback request must not issue without a third slot")
        } catch let error as ProviderRequestBudgetError {
            XCTAssertEqual(error, .exhausted(limit: 2, consumed: 2))
        }
        XCTAssertEqual(primary.requestCount, 2)
        XCTAssertEqual(fallback.requestCount, 0)
        let tooSmallConsumed = await tooSmall.consumedCount()
        XCTAssertEqual(tooSmallConsumed, 2)

        let enough = ProviderRequestBudget(limit: 3)
        let stream = try await registry.stream(
            providerId: "primary", model: nil,
            messages: [ChatMessage(role: .user, content: "go")],
            settings: ModelSettings(), allowFallback: true,
            requestBudget: enough)
        let fallbackText = try await stream.collectText()
        XCTAssertEqual(fallbackText, "fallback ok")
        let enoughConsumed = await enough.consumedCount()
        XCTAssertEqual(enoughConsumed, 3)
        XCTAssertEqual(primary.requestCount, 4)
        XCTAssertEqual(fallback.requestCount, 1)
    }

    func testPersistenceFailureIsStickyAndIssuesNoRequest() async throws {
        struct PersistFailure: Error {}
        let provider = RequestCountingProvider(id: "only", behavior: .success("must not run"))
        let registry = ProviderRegistry(providers: [provider])
        let budget = ProviderRequestBudget(limit: 3, persistence: { _, _ in throw PersistFailure() })

        for _ in 0..<2 {
            do {
                let stream = try await registry.stream(
                    providerId: "only", model: nil,
                    messages: [ChatMessage(role: .user, content: "go")],
                    settings: ModelSettings(), requestBudget: budget)
                _ = try await stream.collectText()
                XCTFail("fail-closed admission must not invoke the provider")
            } catch is ProviderRequestBudgetError { }
        }
        XCTAssertEqual(provider.requestCount, 0)
        let consumed = await budget.consumedCount()
        XCTAssertEqual(consumed, 1,
                       "the uncertain slot is burned conservatively, never refunded")
    }

    func testIndependentActorsCannotBothSpendOneDurableLastSlot() async throws {
        let directory = NSTemporaryDirectory() + "provider-admission-race-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = LoopCheckpointStore(directory: directory)
        let checkpoint = LoopCheckpoint(
            goal: "race", providerId: "only", model: nil, projectRoot: "/tmp",
            messages: [ChatMessage(role: .user, content: "race")])
        try store.save(checkpoint)
        let provider = RequestCountingProvider(id: "only", behavior: .success("ok"))
        let registry = ProviderRegistry(providers: [provider])
        let persistence: ProviderRequestBudget.Persistence = { minimum, limit in
            try store.admitProviderRequest(
                id: checkpoint.id, minimumConsumed: minimum, limit: limit)
        }
        let firstBudget = ProviderRequestBudget(limit: 1, persistence: persistence)
        let secondBudget = ProviderRequestBudget(limit: 1, persistence: persistence)

        func issue(_ budget: ProviderRequestBudget) async -> Bool {
            do {
                let stream = try await registry.stream(
                    providerId: "only", model: nil,
                    messages: [ChatMessage(role: .user, content: "go")],
                    settings: ModelSettings(), requestBudget: budget)
                _ = try await stream.collectText()
                return true
            } catch { return false }
        }
        async let first = issue(firstBudget)
        async let second = issue(secondBudget)
        let outcomes = await (first, second)
        let successes = [outcomes.0, outcomes.1].filter { $0 }.count

        XCTAssertEqual(successes, 1)
        XCTAssertEqual(provider.requestCount, 1,
                       "the losing actor must be denied before provider invocation")
        let durable = try store.load(id: checkpoint.id)
        XCTAssertEqual(durable.providerRequestsConsumed, 1)
        XCTAssertEqual(durable.iteration, 1)
    }
}

private final class RequestCountingProvider: ChatProvider, @unchecked Sendable {
    enum Behavior: Sendable { case transportFailure, success(String) }
    let id: String
    let name: String
    let requiresAPIKey = false
    let keyAccount: String
    let defaultModel = "model-1"
    let availableModels = [AIModel(id: "model-1")]
    private let behavior: Behavior
    private let lock = NSLock()
    private var count = 0

    init(id: String, behavior: Behavior) {
        self.id = id
        self.name = id
        self.keyAccount = id
        self.behavior = behavior
    }

    var requestCount: Int { lock.withLock { count } }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock { count += 1 }
        return AsyncThrowingStream { continuation in
            switch behavior {
            case .transportFailure:
                continuation.finish(throwing: AIProviderError.transport("offline"))
            case .success(let text):
                continuation.yield(.delta(text))
                continuation.finish()
            }
        }
    }
}
