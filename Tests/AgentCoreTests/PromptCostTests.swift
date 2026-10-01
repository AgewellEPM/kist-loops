import XCTest
@testable import AgentCore

final class PromptCostTests: XCTestCase {
    func testEffectiveSystemAndSchemaCountWithoutDuplicatingOldSystem() {
        var settings = ModelSettings(temperature: 0, maxTokens: 10, systemPrompt: String(repeating: "s", count: 1000))
        settings.jsonSchema = "schema"
        let messages = [ChatMessage(role: .system, content: "obsolete"), ChatMessage(role: .user, content: "task")]
        XCTAssertEqual(HeadlessAgentLoop.promptCharacters(messages: messages, settings: settings), 1042)
        settings.systemPrompt = ""
        XCTAssertEqual(HeadlessAgentLoop.promptCharacters(messages: messages, settings: settings), 82)
    }

    func testNativeToolSchemasCountTowardReservation() {
        let settings = ModelSettings(temperature: 0, maxTokens: 10, systemPrompt: "system")
        let tool = ToolSpec(name: "test", description: "description", parameters: [
            ToolParameter(name: "path", type: "string", description: "file")])
        XCTAssertGreaterThan(HeadlessAgentLoop.promptCharacters(messages: [], settings: settings, tools: [tool]), 100,
            "Count the actual schema structure, not just the 35 characters in its field values")
    }

    func testBothProtocolsDenyAnUnaffordableSystemPromptBeforeInference() async throws {
        let root = NSTemporaryDirectory() + "prompt-cost-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        for native in [false, true] {
            let provider = NeverCalledCostProvider(supportsNativeTools: native)
            let budget = BudgetLedger(maxTokens: 4200)
            let loop = HeadlessAgentLoop(providers: ProviderRegistry(providers: [provider]),
                providerId: provider.id, model: "test", tools: .headless(),
                context: ToolContext(projectRoot: root), toolMode: native ? .native : .text, budget: budget)
            let result = await loop.run(goal: "explain")
            XCTAssertFalse(result.success)
            XCTAssertTrue(result.summary.hasPrefix("budget would be exceeded"), result.summary)
            let spent = await budget.spentTokens()
            XCTAssertEqual(spent, 0)
        }
    }
}

private struct NeverCalledCostProvider: ChatProvider {
    let id = "prompt-cost-test", name = "Prompt cost test", keyAccount = "", defaultModel = "test"
    let requiresAPIKey = false
    let availableModels: [AIModel] = []
    let supportsNativeTools: Bool
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        XCTFail("budget must reject before inference")
        return AsyncThrowingStream { $0.finish() }
    }
}
