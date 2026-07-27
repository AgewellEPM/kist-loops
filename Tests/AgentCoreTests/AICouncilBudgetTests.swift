import XCTest
import Foundation
@testable import AgentCore

/// C3 — the council/research path is no longer the big uncapped hole. With `--budget`, an exhausted
/// ledger halts the council BEFORE spending any mind call; under a generous budget, every mind turn +
/// the final synthesis is accounted at the single chokepoint (record).
final class AICouncilBudgetTests: XCTestCase {

    private func council(budget: BudgetLedger?) -> AICouncil {
        let registry = ProviderRegistry(providers: [ScriptedProvider([
            "Mind says: do the thing.", "Decision: do it.\nKanban Board:\n| Ready | x | builder | y |",
        ])], keyStore: NullKeyStore())
        let roles = RoleBindings(default: ProviderBinding(providerId: "scripted", model: nil))
        return AICouncil(providers: registry, roles: roles, budget: budget)
    }

    // An exhausted budget halts every mind before it spends — total council spend stays 0.
    func testExhaustedBudgetHaltsCouncilWithoutSpending() async {
        let budget = BudgetLedger(maxTokens: 0)                  // exceeded from the start
        let result = await council(budget: budget).run(goal: "build a thing")
        let spent = await budget.spentTokens()
        XCTAssertEqual(spent, 0, "no model call may run once the budget is exhausted")
        // Every MODEL mind (binding != nil; the memory mind has no binding and isn't a model call)
        // is skipped under an exhausted budget.
        let modelMinds = result.minds.filter { $0.binding != nil }
        XCTAssertFalse(modelMinds.isEmpty)
        XCTAssertTrue(modelMinds.allSatisfy { $0.failed }, "every model mind is skipped under an exhausted budget")
        XCTAssertTrue(result.minds.contains { $0.output.contains("budget exceeded") })
    }

    // A generous budget runs the council and accounts spend at the chokepoint.
    func testCouncilAccountsSpendUnderGenerousBudget() async {
        let budget = BudgetLedger(maxTokens: 5_000_000)
        _ = await council(budget: budget).run(goal: "build a thing")
        let spent = await budget.spentTokens()
        XCTAssertGreaterThan(spent, 0, "council spend must accrue against the ledger (was uncapped before C3)")
    }

    // Uncapped (nil) council behaves as before.
    func testUncappedCouncilRuns() async {
        let result = await council(budget: nil).run(goal: "build a thing")
        XCTAssertFalse(result.minds.isEmpty)
    }
}

// MARK: - Local test doubles (file-private)

private struct NullKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class ScriptedProvider: ChatProvider {
    let id = "scripted", name = "Scripted", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "scripted", defaultModel = "scripted-1"
    let availableModels = [AIModel(id: "scripted-1")]
    private let responses: ScriptedResponses
    init(_ responses: [String]) { self.responses = ScriptedResponses(responses) }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let r = await responses.next()
        return AsyncThrowingStream { cont in cont.yield(.delta(r)); cont.finish() }
    }
}

private actor ScriptedResponses {
    private let responses: [String]; private var idx = 0
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String { defer { idx += 1 }; return idx < responses.count ? responses[idx] : "ok" }
}
