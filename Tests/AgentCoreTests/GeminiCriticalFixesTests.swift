import XCTest
@testable import AgentCore

/// Pins the Phase-1 fixes from the adversarial review: thinking-mode model guards, the grounded_answer
/// tool (grounding reachable for the agent), and the generate_image confined write.
final class GeminiCriticalFixesTests: XCTestCase {

    private let provider = GeminiProvider()

    // MARK: H3 — gemini-2.5-pro / gemini-3 must NOT get thinkingBudget:0

    func testThinkingBudgetGuardsByModel() {
        // 2.5-pro can't disable thinking → no thinkingConfig emitted (was a guaranteed 400).
        let pro = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                         model: "gemini-2.5-pro", settings: ModelSettings(disableThinking: true), tools: [])
        XCTAssertNil((pro["generationConfig"] as? [String: Any])?["thinkingConfig"], "2.5-pro must not get thinkingBudget:0")
        // flash CAN disable → budget 0 present.
        let flash = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                           model: "gemini-2.5-flash", settings: ModelSettings(disableThinking: true), tools: [])
        XCTAssertEqual(((flash["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int, 0)
        // gemini-3 uses thinkingLevel, not budget → a positive budget is dropped.
        let g3 = provider.makeBodyTools(messages: [ChatMessage(role: .user, content: "hi")],
                                        model: "gemini-3.1-pro", settings: ModelSettings(thinkingBudget: 2048), tools: [])
        XCTAssertNil((g3["generationConfig"] as? [String: Any])?["thinkingConfig"], "gemini-3 must not get a thinkingBudget")
        XCTAssertFalse(GeminiProvider.canDisableThinking(model: "gemini-2.5-pro"))
        XCTAssertTrue(GeminiProvider.canDisableThinking(model: "gemini-2.5-flash"))
        XCTAssertFalse(GeminiProvider.supportsThinkingBudget(model: "gemini-3.5-flash"))
    }

    // Regression (chain-of-thought leak): Gemini streams a "thinking" summary part with `thought:true`
    // (the model headers it "[CURRENT_TURN_THOUGHT]"). It must NOT be concatenated into the visible answer.
    func testSSEDropsThoughtPartsFromTheAnswer() {
        let sse = #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"[CURRENT_TURN_THOUGHT] the user wants X; I will read files"},{"text":"Here is the answer."}]}}]}"#
        let deltas = GeminiProvider.events(fromSSE: sse).compactMap { e -> String? in
            if case .delta(let t) = e { return t }; return nil
        }
        XCTAssertEqual(deltas, ["Here is the answer."])
        XCTAssertFalse(deltas.joined().contains("CURRENT_TURN_THOUGHT"),
                       "the model's private thought must never leak into the streamed answer")
    }

    // MARK: CRITICAL-1 — grounded_answer makes grounding reachable for the tool-using agent

    func testGroundedAnswerReturnsTextAndRejectsEmpty() async throws {
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory())
        let tool = GroundedAnswerTool { q in
            XCTAssertEqual(q, "who won the 2026 super bowl")
            return "The X won.\n\nSources:\n- https://example.com"
        }
        let ok = try await tool.execute(arguments: ["question": "who won the 2026 super bowl"], context: ctx)
        XCTAssertTrue(ok.success)
        XCTAssertTrue(ok.output.contains("Sources:"))
        // Empty / blank grounded answer → honest failure, not a fake success.
        let blank = GroundedAnswerTool { _ in "   " }
        let r = try await blank.execute(arguments: ["question": "x"], context: ctx)
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("empty"))
    }
}
