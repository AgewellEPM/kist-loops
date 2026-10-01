import XCTest
@testable import AgentCore
@testable import Kist

final class CodingCostGateTests: XCTestCase {
    func testImpossibleReviewerConfigurationMakesNoPlanningRequest() async throws {
        let root = NSTemporaryDirectory() + "coding-cost-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let provider = NoPlanningSpendProvider()
        let registry = ProviderRegistry(providers: [provider])
        let budget = BudgetLedger(maxTokens: 50000)
        let options = KistOptions.parse(["--headless", "--provider", provider.id, "fix parser.py"])
        let code = await KistRunner.runBuilderCompatibility(options, goal: "fix parser.py",
            registry: registry, root: root, tools: .headless(), context: ToolContext(projectRoot: root),
            checkpoints: nil, toolMode: .text, providerId: provider.id, model: provider.defaultModel,
            rolesOverride: RoleBindings(default: ProviderBinding(providerId: provider.id, model: provider.defaultModel)),
            budgetOverride: budget)
        XCTAssertEqual(code, 2)
        let spent = await budget.spentTokens()
        XCTAssertEqual(spent, 0)
    }
}

private struct NoPlanningSpendProvider: ChatProvider {
    let id = "cost-fixture", name = "Cost fixture", keyAccount = "", defaultModel = "fixture"
    let requiresAPIKey = false
    let availableModels: [AIModel] = []
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        XCTFail("missing reviewer was knowable before spending planning tokens")
        return AsyncThrowingStream { $0.finish() }
    }
}
