import XCTest
@testable import AgentCore

final class LocalContextBudgetTests: XCTestCase {
    func testRuntimeAllocationMatchesAdvertisedWindowOnBothProtocols() throws {
        let provider = OllamaProvider()
        for model in ["qwen3.5:9b-q4_K_M", "qwen3-vl:4b-instruct"] {
            let caps = provider.capabilities(forModel: model)
            for body in [provider.makeBody(messages: [], model: model, settings: .init(maxTokens: 200)),
                         try provider.makeBodyTools(messages: [], model: model,
                            settings: .init(maxTokens: 200), tools: [])] {
                XCTAssertEqual((body["options"] as? [String: Any])?["num_ctx"] as? Int, caps.contextWindowTokens)
                XCTAssertNoThrow(try provider.validateContextEstimate(body))
            }
        }
        XCTAssertNil((provider.makeBody(messages: [], model: "unknown-custom", settings: .init())["options"]
            as? [String: Any])?["num_ctx"])
    }

    func testSmallWindowDoesNotInheritEightyThousandCharacterFloor() {
        let small = ContextWindowManager.forModel(capabilities: .init(nativeTools: true, contextWindowTokens: 4_096))
        XCTAssertLessThan(small.maxCharacters, 4_096 * 4)
        let window = ContextWindowManager.forModel(capabilities: .init(nativeTools: true, contextWindowTokens: 16_384))
        let settings = ModelSettings(maxTokens: 2_048, systemPrompt: String(repeating: "system ", count: 200))
        let request = window.reservingRequest(settings: settings)
        XCTAssertLessThanOrEqual(request.maxCharacters + 2_048 * 4 + settings.systemPrompt.count, window.maxCharacters)
    }

    func testSchemasAndToolArgumentsConsumeBudget() {
        let settings = ModelSettings(maxTokens: 1_024)
        let schema = ToolSpec(name: "read_file", description: "Read", parameters: [
            .init(name: "path", type: "string", description: String(repeating: "path ", count: 400), required: true)
        ])
        let window = ContextWindowManager(maxCharacters: 30_000)
        XCTAssertLessThan(window.reservingRequest(settings: settings, tools: [schema]).maxCharacters,
                          window.reservingRequest(settings: settings).maxCharacters)
        let call = ChatMessage(role: .assistant, content: "", toolCalls: [
            .init(id: "1", name: "write_file", argumentsJSON: String(repeating: "x", count: 10_000))
        ])
        XCTAssertGreaterThan(HeadlessAgentLoop.promptCharacters(messages: [call], settings: settings), 10_000)
    }

    func testOverflowIsRejectedBeforeContactingServer() {
        let provider = OllamaProvider()
        let body = provider.makeBody(messages: [.init(role: .user, content: String(repeating: "x", count: 80_000))],
            model: "qwen3.5:9b-q4_K_M", settings: .init(maxTokens: 2_048))
        XCTAssertThrowsError(try provider.validateContextEstimate(body)) { error in
            XCTAssertTrue(error.localizedDescription.contains("local context capacity estimate exceeded:"))
        }
    }

    func testRequestProjectionKeepsObjectiveAndCompleteToolExchange() async {
        let settings = ModelSettings(maxTokens: 1_024, systemPrompt: String(repeating: "rules ", count: 100))
        let base = ContextWindowManager.forModel(capabilities: .init(nativeTools: true, contextWindowTokens: 8_192))
        let window = base.reservingRequest(settings: settings)
        let history: [ChatMessage] = [
            .init(role: .user, content: "Create the card"),
            .init(role: .assistant, content: String(repeating: "old ", count: 12_000)),
            .init(role: .assistant, content: "", toolCalls: [.init(id: "one", name: "read_file", argumentsJSON: "{}")]),
            .toolResult(callId: "one", content: "card exists")
        ]
        let prepared = await ConversationWindowPreparer(contextWindow: window).prepare(history,
            mode: .native, currentObjective: "Create the card") { _ in nil }
        XCTAssertEqual(prepared.checkpointMessages, history)
        XCTAssertLessThanOrEqual(window.totalCost(prepared.outboundMessages), window.maxCharacters)
        XCTAssertTrue(prepared.outboundMessages.contains { $0.content.contains("Create the card") })
        XCTAssertTrue(prepared.outboundMessages.contains { $0.toolCallId == "one" })
        XCTAssertTrue(prepared.outboundMessages.contains { $0.toolCalls?.first?.id == "one" })
    }
}
