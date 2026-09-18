import XCTest
import AgentCore
@testable import Kist

final class BuilderRunAuditTests: XCTestCase {
    func testEveryRetryAndFallbackIsPersistedOnceAcrossCompletionAndBothStreams() async throws {
        let root = NSTemporaryDirectory() + "builder-audit-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let audit = BuilderRunAudit(root: root, provider: "first", model: "explicit", contractID: "contract")
        let registry = ProviderRegistry(
            providers: [AuditProvider(id: "first", fails: true), AuditProvider(id: "second", fails: false)],
            fallbackProviderIds: ["first": ["second"]], retryDelaysNanoseconds: [0])
        let messages = [ChatMessage(role: .user, content: "test")]
        let status = await audit.run(goal: "exercise accounting") {
            do {
                _ = try await registry.completeWithUsage(providerId: "first", model: "explicit",
                    messages: messages, allowFallback: true, requestBudget: ProviderRequestBudget(limit: 3))
                let stream = try await registry.stream(providerId: "first", model: "explicit",
                    messages: messages, settings: ModelSettings(), allowFallback: true,
                    requestBudget: ProviderRequestBudget(limit: 3))
                _ = try await stream.collectText()
                let native = try await registry.streamTools(providerId: "first", model: "explicit",
                    messages: messages, settings: ModelSettings(), tools: [], allowFallback: true,
                    requestBudget: ProviderRequestBudget(limit: 3))
                _ = try await native.collectText()
                let worker = AgentSpan(id: "duplicate-rollup", traceId: "worker", kind: .llmCall,
                    vendor: "second", promptTokens: 33, completionTokens: 21,
                    startedAt: Date(), endedAt: Date())
                UsageLedger.append(projectRoot: root, spans: [worker])
                let child = RunReplayStore(projectRoot: root, provider: "second", model: "default-second")
                child.recordEvent(kind: "tool", text: "worker finished")
                KistRunner.err("preflight diagnostic retained")
                return 0
            } catch { XCTFail("\(error)"); return 1 }
        }
        XCTAssertEqual(status, 0)
        XCTAssertNil(ProviderAttemptObservation.observer)
        let spans = UsageLedger.load(projectRoot: root)
        XCTAssertEqual(spans.count, 9)
        XCTAssertEqual(Set(spans.map(\.id)).count, 9)
        XCTAssertEqual(spans.filter { $0.status == .error }.count, 6)
        XCTAssertEqual(spans.reduce(0) { $0 + $1.totalTokens }, 54)
        XCTAssertEqual(Set(spans.filter { $0.vendor == "first" }.compactMap(\.model)), ["explicit"])
        XCTAssertEqual(Set(spans.filter { $0.vendor == "second" }.compactMap(\.model)), ["default-second"])
        XCTAssertEqual(audit.usage().unmeteredStages?.count, 6)
        XCTAssertNil(audit.usage().aggregateTokens)
        let events = RunReplayStore.loadEvents(projectRoot: root, runID: audit.replay.manifest.runID)
        XCTAssertEqual(events.filter { $0.kind == "providerAttempt" }.count, 9)
        XCTAssertTrue(events.contains { $0.kind == "childRun" })
        XCTAssertTrue(events.contains { $0.kind == "hostError" && $0.text == "preflight diagnostic retained" })
        XCTAssertTrue(events.contains {
            $0.kind == "hostNote" && $0.text.contains("9 provider attempt(s)")
                && $0.text.contains("54 reported tokens; 6 attempt(s) omitted usage, total incomplete")
                && $0.text.contains(audit.replay.manifest.runID)
        })
        XCTAssertEqual(events.last?.kind, "builderFinished")
        let rendered = UsagePanel.render(sessionSpans: [], projectRoot: root, color: false)
        XCTAssertTrue(rendered.contains("6 provider attempt(s) omitted usage"), rendered)
    }
}

private struct AuditProvider: ChatProvider {
    let id: String
    let fails: Bool
    var name: String { id }
    let iconName = "cpu"
    let requiresAPIKey = false
    var keyAccount: String { id }
    var defaultModel: String { "default-" + id }
    var availableModels: [AIModel] { [AIModel(id: defaultModel)] }
    var supportsNativeTools: Bool { true }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        if fails { throw AIProviderError.rateLimited }
        return AsyncThrowingStream {
            $0.yield(.delta("answer")); $0.yield(.usage(promptTokens: 11, completionTokens: 7)); $0.finish()
        }
    }
}
