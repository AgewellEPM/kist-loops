import XCTest
@testable import AgentCore

/// Pins the CANARY PROBE's aggregation contract: readiness must NEVER report `ready` unless the model's
/// ACTIVE path actually worked. A failed/skipped path is `broken`; a degraded path or degraded round-trip
/// is `partial`. This is the same fail-closed discipline the rest of kist uses — never mint trust the
/// live signal didn't earn.
final class ModelLoopProbeTests: XCTestCase {

    func testEchoProbeUsesVisibleOutputWithoutHiddenThinking() {
        XCTAssertTrue(ModelLoopProbe.probeSettings.disableThinking)
        XCTAssertFalse(ModelLoopProbe.probeSettings.geminiBuiltins)
        XCTAssertEqual(ModelLoopProbe.probeSettings.maxTokens, 256)
        XCTAssertEqual(ModelLoopProbe.timeoutSeconds, 45, "keep the hard probe deadline")
        XCTAssertEqual(ModelLoopProbe.probeTimeout(provider: OllamaProvider(), requested: nil), 120)
        XCTAssertEqual(ModelLoopProbe.probeTimeout(provider: nil, requested: nil), 45)
        XCTAssertEqual(ModelLoopProbe.probeTimeout(provider: OllamaProvider(), requested: 0.1), 0.1,
                       "an explicit caller deadline must not be raised")
    }

    func testReadyRequiresBothPathAndRoundTripOK() {
        XCTAssertEqual(ModelLoopProbe.readiness(path: .ok("p"), roundTrip: .ok("rt")), .ready)
    }

    func testReadyWhenRoundTripIntentionallySkipped() {
        // A clean active path whose round-trip was deliberately not run (e.g. truncation-free no-op)
        // still counts as ready — the path is what the loop drives.
        XCTAssertEqual(ModelLoopProbe.readiness(path: .ok("p"), roundTrip: .skipped("n/a")), .ready)
    }

    func testDegradedPathIsPartialNeverReady() {
        XCTAssertEqual(ModelLoopProbe.readiness(path: .degraded("truncated"), roundTrip: .ok("rt")), .partial)
    }

    func testOKPathButFailedRoundTripIsPartial() {
        // Emitted a clean tool call but feeding the result back errored — usable, not flawless.
        XCTAssertEqual(ModelLoopProbe.readiness(path: .ok("p"), roundTrip: .failed("400")), .partial)
    }

    func testOKPathDegradedRoundTripIsPartial() {
        XCTAssertEqual(ModelLoopProbe.readiness(path: .ok("p"), roundTrip: .degraded("off answer")), .partial)
    }

    func testFailedPathIsBroken() {
        XCTAssertEqual(ModelLoopProbe.readiness(path: .failed("no tool call"), roundTrip: .skipped("x")), .broken)
    }

    func testSkippedActivePathIsBrokenNotReady() {
        // We could not even run the path → cannot be trusted. Fail closed to broken.
        XCTAssertEqual(ModelLoopProbe.readiness(path: .skipped("x"), roundTrip: .skipped("x")), .broken)
    }

    func testRenderSurfacesPathLabelAndReadiness() {
        let native = ModelLoopProbe.Report(providerId: "gemini", model: "gemini-2.5-flash", usesNative: true,
                                            path: .ok("clean echo call"), roundTrip: .ok("clean answer"), readiness: .ready)
        let out = ModelLoopProbe.render(native)
        XCTAssertTrue(out.contains("READY"))
        XCTAssertTrue(out.contains("native tool-calling"))
        XCTAssertTrue(out.contains("gemini:gemini-2.5-flash"))
        XCTAssertTrue(out.contains("✓"))

        let text = ModelLoopProbe.Report(providerId: "ollama", model: "", usesNative: false,
                                         path: .failed("no JSON action"), roundTrip: .skipped("path failed"), readiness: .broken)
        let out2 = ModelLoopProbe.render(text)
        XCTAssertTrue(out2.contains("BROKEN"))
        XCTAssertTrue(out2.contains("text protocol"))
        XCTAssertTrue(out2.contains("✗"))
        XCTAssertFalse(out2.contains(":"), "no model → no stray colon in the header label")
    }

    func testOutcomeSymbolsAndPassed() {
        XCTAssertTrue(ModelLoopProbe.Outcome.ok("x").passed)
        XCTAssertFalse(ModelLoopProbe.Outcome.degraded("x").passed)
        XCTAssertFalse(ModelLoopProbe.Outcome.failed("x").passed)
        XCTAssertFalse(ModelLoopProbe.Outcome.skipped("x").passed)
        XCTAssertEqual(ModelLoopProbe.Outcome.ok("x").symbol, "✓")
        XCTAssertEqual(ModelLoopProbe.Outcome.failed("x").symbol, "✗")
    }

    func testNativeProbeDoesNotReportReadyWhenNativeRoundTripRejectsToolHistory() async {
        let provider = NativeSecondTurnRejectingProbeProvider()
        let registry = ProviderRegistry(providers: [provider], keyStore: ProbeNullKeys())

        let report = await ModelLoopProbe.probe(registry: registry, providerId: provider.id, model: nil)

        XCTAssertEqual(report.readiness, ModelLoopProbe.Readiness.partial)
        XCTAssertTrue(report.path.passed)
        XCTAssertTrue(report.roundTrip.detail.contains("errored"))
        XCTAssertEqual(provider.nativeCallCount, 2, "probe must exercise the native second-turn transcript")
    }

    func testTextProbeDoesNotReportReadyUntilObservationProducesDone() async {
        let provider = TextObservationFailingProbeProvider()
        let registry = ProviderRegistry(providers: [provider], keyStore: ProbeNullKeys())

        let report = await ModelLoopProbe.probe(registry: registry, providerId: provider.id, model: nil)

        XCTAssertEqual(report.readiness, ModelLoopProbe.Readiness.partial)
        XCTAssertTrue(report.path.passed)
        XCTAssertTrue(report.roundTrip.detail.contains("done action"))
        XCTAssertEqual(provider.textCallCount, 2, "probe must feed the text-protocol observation back")
    }
}

private struct ProbeNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class NativeSecondTurnRejectingProbeProvider: ChatProvider, @unchecked Sendable {
    let id = "native-probe"
    let name = "Native Probe"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = ""
    let defaultModel = "native-probe-model"
    let availableModels: [AIModel] = []
    let supportsNativeTools = true
    private let lock = NSLock()
    private var calls = 0

    var nativeCallCount: Int { withLock { calls } }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { c in
            c.yield(.delta("plain fallback would have passed"))
            c.finish()
        }
    }

    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        withLock { calls += 1 }
        if messages.contains(where: { $0.role == .tool }) {
            throw AIProviderError.http(status: 400, body: "tool history rejected")
        }
        return AsyncThrowingStream { c in
            c.yield(.toolCall(id: "call_1", name: "echo", argumentsJSON: #"{"text":"ping"}"#))
            c.finish()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}

private final class TextObservationFailingProbeProvider: ChatProvider, @unchecked Sendable {
    let id = "text-probe"
    let name = "Text Probe"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = ""
    let defaultModel = "text-probe-model"
    let availableModels: [AIModel] = []
    private let lock = NSLock()
    private var calls = 0

    var textCallCount: Int { withLock { calls } }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let current = withLock { calls += 1; return calls }
        return AsyncThrowingStream { c in
            if current == 1 {
                c.yield(.delta(#"{"tool":"echo","parameters":{"text":"ping"}}"#))
            } else {
                c.yield(.delta("not json"))
            }
            c.finish()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
}
