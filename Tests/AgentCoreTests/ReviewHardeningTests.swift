import XCTest
@testable import AgentCore

/// Regression tests for the Codex + DeepSeek review findings on the flawless-loops work.
/// Each test names the finding it pins so a future change can't silently re-open it.
final class ReviewHardeningTests: XCTestCase {

    // MARK: Codex BLOCKER — probe must never borrow a FALLBACK provider's success

    func testProbeNeverFallsBackToAnotherProvider() async {
        let alpha = ReviewFailingNativeProvider(id: "alpha")   // the requested model — always errors
        let beta = ReviewHealthyNativeProvider(id: "beta")     // a fallback that WOULD pass
        let registry = ProviderRegistry(providers: [alpha, beta], keyStore: ReviewNullKeys(),
                                        fallbackProviderIds: ["alpha": ["beta"]])
        let report = await ModelLoopProbe.probe(registry: registry, providerId: "alpha", model: nil)
        XCTAssertEqual(report.readiness, .broken, "a failing model must report broken, not borrow a fallback's pass")
        XCTAssertEqual(beta.callCount, 0, "the probe must NOT call a fallback provider")
    }

    func testFallbackStillWorksForNormalCallsWhenAllowed() async {
        // Sanity: disabling fallback in the probe must NOT have broken normal fallback behavior.
        let alpha = ReviewFailingNativeProvider(id: "alpha")
        let beta = ReviewHealthyNativeProvider(id: "beta")
        let registry = ProviderRegistry(providers: [alpha, beta], keyStore: ReviewNullKeys(),
                                        fallbackProviderIds: ["alpha": ["beta"]],
                                        retryDelaysNanoseconds: [])
        do {
            let stream = try await registry.streamTools(providerId: "alpha", model: nil,
                                                        messages: [ChatMessage(role: .user, content: "hi")],
                                                        settings: ModelSettings(), tools: [], allowFallback: true)
            for try await _ in stream {}   // drain — beta yields a tool call
        } catch { /* fallback may still surface an error; we only assert beta was reached */ }
        XCTAssertEqual(beta.callCount, 1, "with fallback ALLOWED, beta should be reached")
    }

    // MARK: DeepSeek MED — downgrade classifier must not false-trigger on a bare "tool"

    func testGenericToolWordDoesNotDowngrade() {
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 400, body: "The requested tool is not available in this project")))
        XCTAssertFalse(NativeProtocolDowngrade.shouldDowngrade(
            from: AIProviderError.http(status: 400, body: "Toolbar configuration is invalid")))
    }

    func testRealToolProtocolPhrasesStillDowngrade() {
        for body in ["function calling is unsupported", "tool_use blocks invalid",
                     "tool_call rejected", "tools are not allowed", "toolConfig error"] {
            XCTAssertTrue(NativeProtocolDowngrade.shouldDowngrade(from: AIProviderError.http(status: 400, body: body)),
                          "should still downgrade on: \(body)")
        }
    }

    // MARK: Codex/DeepSeek MED — GGUF parser fails CLOSED (nil) on truncation, not partial metadata

    func testTruncatedGGUFAfterValidKeyReturnsNil() throws {
        let dir = NSTemporaryDirectory() + "gguf-trunc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/trunc.gguf"

        // Build a valid GGUF declaring 3 KV pairs but write bytes for only 1 (+ a dangling partial key).
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func gstr(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); d.append(contentsOf: b) }
        d.append(contentsOf: [0x47, 0x47, 0x55, 0x46]); u32(3); u64(0); u64(3)   // declares 3 KVs
        gstr("general.name"); u32(8); gstr("Meta-Llama-3-8B")                    // KV 1 (complete)
        gstr("tokenizer.chat_template"); u32(8); u64(9_999_999)                  // KV 2: claims a 10MB string, no bytes
        try d.write(to: URL(fileURLWithPath: path))

        XCTAssertNil(LocalModelConfigReader.read(path: path),
                     "a truncated GGUF must fail closed (nil), not return the partial first KV as a complete config")
    }
}

// MARK: - stubs

private struct ReviewNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class ReviewFailingNativeProvider: ChatProvider, @unchecked Sendable {
    let id: String, name = "Failing", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "", defaultModel: String
    let availableModels: [AIModel] = []
    let supportsNativeTools = true
    init(id: String) { self.id = id; self.defaultModel = "\(id)-m" }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.http(status: 503, body: "service unavailable")   // transport-ish → fallback-eligible
    }
    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.http(status: 503, body: "service unavailable")
    }
}

private final class ReviewHealthyNativeProvider: ChatProvider, @unchecked Sendable {
    let id: String, name = "Healthy", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "", defaultModel: String
    let availableModels: [AIModel] = []
    let supportsNativeTools = true
    private let lock = NSLock(); private var calls = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }
    init(id: String) { self.id = id; self.defaultModel = "\(id)-m" }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); calls += 1; lock.unlock()
        return AsyncThrowingStream { c in c.yield(.delta(#"{"done":true,"summary":"ok"}"#)); c.finish() }
    }
    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); calls += 1; lock.unlock()
        return AsyncThrowingStream { c in c.yield(.toolCall(id: "1", name: "echo", argumentsJSON: #"{"text":"ping"}"#)); c.finish() }
    }
}
