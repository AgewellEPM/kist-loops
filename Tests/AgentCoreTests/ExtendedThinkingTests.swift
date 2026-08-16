import XCTest
import Foundation
@testable import AgentCore

/// Gap #1 (mirror Anthropic's thinking): the loop no longer FORCES thinking off. Extended thinking is
/// opt-in — default OFF keeps the tight low-latency loop; ON lets the model reason before each action.
/// These pin that the flag actually flows into the model settings the loop sends.
final class ExtendedThinkingTests: XCTestCase {
    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "think-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    /// Captures the `disableThinking` of the most recent model call, then ends the loop with `done`.
    private final class CaptureProvider: ChatProvider, @unchecked Sendable {
        let id = "cap", name = "cap", iconName = "cpu"
        let requiresAPIKey = false, keyAccount = "cap", defaultModel = "cap-1"
        let availableModels = [AIModel(id: "cap-1")]
        private(set) var lastDisableThinking: Bool?
        func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
            lastDisableThinking = settings.disableThinking
            return AsyncThrowingStream { c in c.yield(.delta(#"{"done":true,"summary":"ok"}"#)); c.finish() }
        }
    }
    private struct Keys: KeyStore { func key(forAccount account: String) -> String? { nil } }

    private func capturedDisableThinking(
        extendedThinking: Bool,
        reasoningEffort: ProviderReasoningEffort? = nil
    ) async -> Bool? {
        let cap = CaptureProvider()
        let loop = HeadlessAgentLoop(providers: ProviderRegistry(providers: [cap], keyStore: Keys()),
                                     providerId: "cap", model: nil, tools: .headless(),
                                     context: ToolContext(projectRoot: root),
                                     maxIterations: 4, extendedThinking: extendedThinking,
                                     reasoningEffort: reasoningEffort)
        _ = await loop.run(goal: "say done")
        return cap.lastDisableThinking
    }

    func testDefaultKeepsThinkingOff() async {
        let v = await capturedDisableThinking(extendedThinking: false)
        XCTAssertEqual(v, true, "default (no --think) must keep the tight loop: disableThinking = true")
    }

    func testExtendedThinkingLetsTheModelReason() async {
        let v = await capturedDisableThinking(extendedThinking: true)
        XCTAssertEqual(v, false, "--think must let the model reason: disableThinking = false")
    }

    func testTypedEffortOverridesLegacyThinkingBoolean() async {
        let explicitNone = await capturedDisableThinking(
            extendedThinking: true, reasoningEffort: ProviderReasoningEffort.none)
        XCTAssertEqual(explicitNone, true, "typed .none must override the legacy --think Boolean")

        let explicitDeep = await capturedDisableThinking(extendedThinking: false, reasoningEffort: .deep)
        XCTAssertEqual(explicitDeep, false, "typed .deep must override the legacy default-off Boolean")
    }

    func testToggleCopyFlipsTheFlag() {
        let loop = HeadlessAgentLoop(providers: ProviderRegistry(providers: [CaptureProvider()], keyStore: Keys()),
                                     providerId: "cap", model: nil, tools: .headless(),
                                     context: ToolContext(projectRoot: root))
        XCTAssertFalse(loop.isExtendedThinking)                                   // default off
        XCTAssertTrue(loop.extendedThinkingEnabled(true).isExtendedThinking)      // /think on
        XCTAssertFalse(loop.extendedThinkingEnabled(true).extendedThinkingEnabled(false).isExtendedThinking)  // /think off
    }
}
