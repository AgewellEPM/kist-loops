import XCTest
@testable import AgentCore

final class CompetitiveBenchmarkTests: XCTestCase {
    func testEstimatesCostFromMeasuredProviderSpans() {
        let now = Date()
        let spans = [
            AgentSpan(id: "1", traceId: "t", kind: .llmCall,
                      role: "coder", vendor: "mimo", model: "mimo-v2.5-pro",
                      promptTokens: 1_000_000, completionTokens: 100_000,
                      startedAt: now, endedAt: now),
            AgentSpan(id: "2", traceId: "t", kind: .llmCall,
                      role: "critic", vendor: "gemini", model: "gemini-2.5-flash",
                      promptTokens: 10_000, completionTokens: 1_000,
                      startedAt: now, endedAt: now),
            AgentSpan(id: "3", traceId: "t", kind: .toolCall,
                      toolName: "swift test", startedAt: now, endedAt: now),
        ]
        let prices = [
            "mimo": ProviderTokenPrice(inputPerMillionUSD: 0.10, outputPerMillionUSD: 0.40),
            "gemini": ProviderTokenPrice(inputPerMillionUSD: 0.30, outputPerMillionUSD: 2.50),
        ]

        let estimate = CompetitiveBenchmark.estimateCost(spans: spans, prices: prices)

        XCTAssertEqual(estimate.inputUSD, 0.103, accuracy: 0.0001)
        XCTAssertEqual(estimate.outputUSD, 0.0425, accuracy: 0.0001)
        XCTAssertEqual(estimate.unknownTokenCount, 0)
        XCTAssertEqual(estimate.totalUSD, 0.1455, accuracy: 0.0001)
    }

    func testCostPerVerifiedSuccessRollupCountsFailuresInSpend() {
        let runs = [
            VerifiedRunCost(label: "mimo-team-1", verified: true, estimate: CostEstimate(inputUSD: 0.10, outputUSD: 0.05)),
            VerifiedRunCost(label: "mimo-team-2", verified: false, estimate: CostEstimate(inputUSD: 0.20, outputUSD: 0.10)),
            VerifiedRunCost(label: "mimo-team-3", verified: true, estimate: CostEstimate(inputUSD: 0.08, outputUSD: 0.02)),
        ]

        let rollup = CompetitiveBenchmark.rollup(runs)

        XCTAssertEqual(rollup.verifiedSuccesses, 2)
        XCTAssertEqual(rollup.failedRuns, 1)
        XCTAssertEqual(rollup.totalUSD, 0.55, accuracy: 0.0001)
        XCTAssertEqual(rollup.dollarsPerVerifiedSuccess ?? -1, 0.275, accuracy: 0.0001)
    }

    func testEnduranceReportRequiresCompletionNoFailuresAndTargetReached() {
        let events: [RuntimeEvent] = [
            .actionStarted(index: 1, tool: "read_file", description: "read"),
            .actionFinished(index: 1, success: true, output: "ok", error: nil),
            .actionStarted(index: 2, tool: "search_code", description: "search"),
            .actionFinished(index: 2, success: true, output: "ok", error: nil),
            .completed(summary: "done"),
        ]

        let report = ToolEnduranceBenchmark.evaluate(events: events, targetToolCalls: 2)

        XCTAssertEqual(report.startedToolCalls, 2)
        XCTAssertEqual(report.succeededToolCalls, 2)
        XCTAssertEqual(report.failedToolCalls, 0)
        XCTAssertTrue(report.completed)
        XCTAssertTrue(report.reachedTarget)
    }

    func testEnduranceReportFailsTargetOnAnyToolFailure() {
        let events: [RuntimeEvent] = [
            .actionStarted(index: 1, tool: "read_file", description: "read"),
            .actionFinished(index: 1, success: false, output: "", error: "missing"),
            .completed(summary: "done"),
        ]

        let report = ToolEnduranceBenchmark.evaluate(events: events, targetToolCalls: 1)

        XCTAssertEqual(report.failedToolCalls, 1)
        XCTAssertFalse(report.reachedTarget)
    }
}
