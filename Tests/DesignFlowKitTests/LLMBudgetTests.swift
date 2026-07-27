import XCTest
@testable import DesignFlowKit

/// The spend safety valve: a bounded model-call budget and a bounded outer loop.
final class LLMBudgetTests: XCTestCase {

    /// Counts calls so we can prove the budget actually gates the underlying client.
    actor CountingClient: LLMClient {
        private(set) var calls = 0
        func complete(system: String, user: String) async throws -> String {
            calls += 1
            return "ok"
        }
        func count() -> Int { calls }
    }

    func testBudgetStopsAfterMaxCalls() async {
        let budget = LLMBudget(maxCalls: 2)
        let first = await budget.tryConsume()
        let second = await budget.tryConsume()
        let third = await budget.tryConsume()
        let spent = await budget.spent()
        let remaining = await budget.remaining()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertFalse(third, "3rd consume must be refused")
        XCTAssertEqual(spent, 2)
        XCTAssertEqual(remaining, 0)
    }

    func testBudgetedClientThrowsAfterCapAndDoesNotCallInner() async throws {
        let inner = CountingClient()
        let client = BudgetedLLMClient(inner, budget: LLMBudget(maxCalls: 1))
        _ = try await client.complete(system: "s", user: "u")          // 1 — ok
        await XCTAssertThrowsErrorAsync(try await client.complete(system: "s", user: "u")) { error in
            guard case LLMError.budgetExceeded = error else { return XCTFail("expected budgetExceeded, got \(error)") }
        }
        // The inner client was called exactly once — the over-budget call never reached it.
        let count = await inner.count()
        XCTAssertEqual(count, 1, "over-budget call must not hit the real client (no spend)")
    }

    func testPipelineBlocksFailClosedWhenBudgetExhausted() async throws {
        let ws = GitWorkspace(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: ws.root) }
        // Budget of 1: the Designer's call succeeds, the Analyst's is refused → block.
        let client = BudgetedLLMClient(StubLLMClient(), budget: LLMBudget(maxCalls: 1))
        let agents = AgentFactory.agents(for: .designAndAnalysis, llm: client)
        let result = await InnerPipeline().run(brief: "x", agents: agents, workspace: ws)

        XCTAssertFalse(result.completed, "an over-budget stage must block the pipeline")
        XCTAssertEqual(result.blockedStage, .designAnalyst)
        XCTAssertEqual(result.artifacts.count, 1, "only the first (in-budget) stage produced")
    }

    func testOuterLoopHonorsMaxCycles() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let loop = OuterLoop(scanner: StubSignalScanner(), llm: StubLLMClient(), outputRoot: root)
        let ran = await loop.run(intervalSeconds: 0, maxCycles: 2)
        XCTAssertEqual(ran, 2, "the loop must stop after exactly maxCycles")
    }
}

/// Minimal async throwing-assertion helper (XCTAssertThrowsError isn't async-aware).
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) }
    catch { handler(error) }
}
