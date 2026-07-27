import XCTest
import Foundation
@testable import AgentCore

/// Sprint 3 / C1 — dollar-denominated budgets. The BudgetLedger tracks a $ ceiling alongside tokens;
/// either cap halts; cost is priced live per provider. Answers the council's "tokens-only is a toy."
final class CostDollarTests: XCTestCase {

    // MARK: pricing

    func testPriceUSDKnownVendor() {
        // openai = $5/M input, $15/M output.
        let usd = CompetitiveBenchmark.priceUSD(vendor: "openai", promptTokens: 1_000_000, completionTokens: 1_000_000)
        XCTAssertEqual(usd ?? -1, 20.0, accuracy: 1e-9)
        let half = CompetitiveBenchmark.priceUSD(vendor: "deepseek", promptTokens: 1_000_000, completionTokens: 0)
        XCTAssertEqual(half ?? -1, 0.27, accuracy: 1e-9)
    }

    func testPriceUSDUnknownVendorIsNil() {
        XCTAssertNil(CompetitiveBenchmark.priceUSD(vendor: "scripted", promptTokens: 100, completionTokens: 100))
        XCTAssertNil(CompetitiveBenchmark.priceUSD(vendor: nil, promptTokens: 100, completionTokens: 100))
    }

    // Codex gate: the price book covers EVERY catalog provider so --max-cost actually fires
    // regardless of vendor (an unpriced vendor would silently never trigger the cap). Local = $0.
    func testPriceBookCoversAllCatalogProviders() {
        for vendor in ["openai", "anthropic", "gemini", "grok", "deepseek", "mimo", "zhipu",
                       "moonshot", "qwen", "doubao", "hunyuan", "ernie", "yi", "stepfun", "baichuan", "minimax"] {
            let usd = CompetitiveBenchmark.priceUSD(vendor: vendor, promptTokens: 1_000_000, completionTokens: 0)
            XCTAssertNotNil(usd, "\(vendor) must be priced so --max-cost can fire")
            XCTAssertGreaterThan(usd ?? 0, 0, "\(vendor) cloud price must be > 0")
        }
        for local in ["mlx", "ollama"] {
            XCTAssertEqual(CompetitiveBenchmark.priceUSD(vendor: local, promptTokens: 1_000_000, completionTokens: 1_000_000) ?? -1,
                           0, accuracy: 1e-9, "\(local) is local ⇒ $0")
        }
    }

    // Codex gate: GenerateTool + FleetPlanner account DOLLARS, not tokens-only (silent $ undercount).
    func testGenerateAndPlannerPriceDollars() throws {
        let gen = try source("Sources/AgentCore/Tools/GenerateTool.swift").replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(gen.contains("CompetitiveBenchmark.priceUSD(") && gen.contains("actualTokens:measured.total,actualUSD:usd"),
                      "GenerateTool must price its call in dollars (reserve→commit)")
        let planner = try source("Sources/AgentCore/FleetPlanner.swift").replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(planner.contains("CompetitiveBenchmark.priceUSD(") && planner.contains("budget?.add(tokens:est.total,usd:usd)"),
                      "FleetPlanner must price its planner call in dollars")
    }

    private func source(_ rel: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
    }

    func testPriceUSDClampsNegative() {
        XCTAssertEqual(CompetitiveBenchmark.priceUSD(vendor: "openai", promptTokens: -5, completionTokens: -5) ?? -1, 0, accuracy: 1e-9)
    }

    // MARK: ledger USD cap

    func testUSDCapExceededIndependentOfTokens() async {
        let b = BudgetLedger(maxUSD: 0.50)
        await b.add(tokens: 1_000_000, usd: 0.40)
        let under = await b.isExceeded(); XCTAssertFalse(under, "under the dollar cap")
        await b.add(tokens: 10, usd: 0.20)                  // now $0.60 ≥ $0.50
        let over = await b.isExceeded(); XCTAssertTrue(over, "over the dollar cap")
        let reason = await b.exceededReason()
        XCTAssertTrue(reason?.contains("cost budget exceeded") ?? false, reason ?? "nil")
        let usd = await b.spentUSD(); XCTAssertEqual(usd, 0.60, accuracy: 1e-9)
    }

    func testEitherCapHalts() async {
        let t = BudgetLedger(maxTokens: 1000, maxUSD: 100.0)
        await t.add(tokens: 2000, usd: 0.01)
        let tOver = await t.isExceeded(); XCTAssertTrue(tOver)
        let tReason = await t.exceededReason(); XCTAssertTrue(tReason?.contains("token budget") ?? false)

        let d = BudgetLedger(maxTokens: 1_000_000, maxUSD: 0.10)
        await d.add(tokens: 50, usd: 0.50)
        let dOver = await d.isExceeded(); XCTAssertTrue(dOver)
        let dReason = await d.exceededReason(); XCTAssertTrue(dReason?.contains("cost budget") ?? false)
    }

    func testUncappedNeverExceeds() async {
        let b = BudgetLedger()
        await b.add(tokens: 9_999_999, usd: 9999.0)
        let over = await b.isExceeded(); XCTAssertFalse(over)
        let reason = await b.exceededReason(); XCTAssertNil(reason)
        let rem = await b.remainingUSD(); XCTAssertNil(rem)
    }

    // MARK: end-to-end — a loop halts on the DOLLAR cap

    func testLoopHaltsOnDollarBudget() async throws {
        let dir = NSTemporaryDirectory() + "cost-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = ToolContext.canonicalize(dir) ?? dir

        let budget = BudgetLedger(maxUSD: 0.01)
        await budget.add(tokens: 0, usd: 0.50)               // already over the dollar cap
        let registry = ProviderRegistry(providers: [ScriptedProvider([
            #"{"thinking":"x","done":true,"summary":"should-not-reach"}"#
        ])], keyStore: NullKeyStore())
        let loop = HeadlessAgentLoop(providers: registry, providerId: "scripted", model: nil,
                                     tools: .headless(), context: ToolContext(projectRoot: root),
                                     sink: NullEventSink(), maxIterations: 4, budget: budget)
        let outcome = await loop.run(goal: "go")
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.summary.contains("cost budget exceeded"), outcome.summary)
    }
}

// MARK: - Local doubles (file-private)

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
    func next() -> String { defer { idx += 1 }; return idx < responses.count ? responses[idx] : #"{"done":true,"summary":"x"}"# }
}
