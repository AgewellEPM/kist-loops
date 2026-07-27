import XCTest
@testable import AgentCore

/// The observability data layer: OTel-shaped spans + per-role/per-vendor token rollups. Measured
/// facts only — the rollups are pure accounting, the basis for the terminal trace + the cost layer.
final class AgentTraceTests: XCTestCase {

    private func span(role: String?, vendor: String?, prompt: Int, completion: Int,
                      kind: SpanKind = .llmCall, status: SpanStatus = .ok, tool: String? = nil) -> AgentSpan {
        let t0 = Date(timeIntervalSince1970: 1_000)
        return AgentSpan(id: TraceID.make(), traceId: "trace1", kind: kind, role: role, vendor: vendor,
                         model: "m", toolName: tool, promptTokens: prompt, completionTokens: completion,
                         startedAt: t0, endedAt: t0.addingTimeInterval(0.25), status: status)
    }

    func testSpanDerivedFields() {
        let s = span(role: "planner", vendor: "openai", prompt: 100, completion: 40)
        XCTAssertEqual(s.totalTokens, 140)
        XCTAssertEqual(s.durationMs, 250, accuracy: 0.001)
        XCTAssertTrue(s.label.contains("planner/openai"))
        XCTAssertTrue(s.label.contains("140 tok"))
    }

    func testNegativeDurationClampedToZero() {
        let t = Date(timeIntervalSince1970: 5_000)
        let s = AgentSpan(id: "x", traceId: "t", kind: .llmCall, startedAt: t, endedAt: t.addingTimeInterval(-1))
        XCTAssertEqual(s.durationMs, 0)   // never negative
    }

    func testRollupsByRoleAndVendor() async {
        let rec = TraceRecorder(traceId: "trace1")
        await rec.record(span(role: "planner", vendor: "openai", prompt: 100, completion: 50))   // 150
        await rec.record(span(role: "coder",   vendor: "deepseek", prompt: 200, completion: 100)) // 300
        await rec.record(span(role: "critic",  vendor: "gemini", prompt: 80, completion: 20))     // 100
        await rec.record(span(role: "planner", vendor: "openai", prompt: 10, completion: 5))      // 15 (replan)

        let total = await rec.totalTokens()
        XCTAssertEqual(total, 565)
        let byRole = await rec.tokensByRole()
        XCTAssertEqual(byRole["planner"], 165)   // 150 + 15
        XCTAssertEqual(byRole["coder"], 300)
        XCTAssertEqual(byRole["critic"], 100)
        let byVendor = await rec.tokensByVendor()
        XCTAssertEqual(byVendor["openai"], 165)
        XCTAssertEqual(byVendor["deepseek"], 300)
        XCTAssertEqual(byVendor["gemini"], 100)
    }

    func testZeroTokenSpansExcludedFromRollup() async {
        // A tool-call span (no tokens) must not create a "(none)" bucket noise.
        let rec = TraceRecorder(traceId: "t")
        await rec.record(span(role: nil, vendor: nil, prompt: 0, completion: 0, kind: .toolCall, tool: "write_file"))
        await rec.record(span(role: "planner", vendor: "openai", prompt: 10, completion: 5))
        let byRole = await rec.tokensByRole()
        XCTAssertEqual(byRole, ["planner": 15])
        let count = await rec.all().count
        XCTAssertEqual(count, 2)   // both spans recorded; only token spans rolled up
    }

    func testSummary() async {
        let rec = TraceRecorder(traceId: "trace1")
        await rec.record(span(role: "planner", vendor: "openai", prompt: 100, completion: 50))
        await rec.record(span(role: "critic", vendor: "gemini", prompt: 0, completion: 0, status: .error))
        let s = await rec.summary()
        XCTAssertEqual(s.traceId, "trace1")
        XCTAssertEqual(s.spanCount, 2)
        XCTAssertEqual(s.totalTokens, 150)
        XCTAssertEqual(s.errorCount, 1)
        XCTAssertEqual(s.tokensByRole, ["planner": 150])
    }

    func testSpanCodableRoundTrip() throws {
        let s = span(role: "coder", vendor: "deepseek", prompt: 12, completion: 8)
        let back = try JSONDecoder().decode(AgentSpan.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testSummaryTerminalLines() async {
        let rec = TraceRecorder(traceId: "t")
        await rec.record(span(role: "coder", vendor: "deepseek", prompt: 200, completion: 100))   // 300
        await rec.record(span(role: "planner", vendor: "openai", prompt: 100, completion: 50))     // 150
        let lines = await rec.summary().terminalLines()
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("450 tokens"))
        XCTAssertTrue(lines[0].contains("2 calls"))
        XCTAssertTrue(lines[1].hasPrefix("  by role:"))
        XCTAssertTrue(lines[1].contains("coder 300 · planner 150"))   // sorted by spend desc
        XCTAssertTrue(lines[2].contains("deepseek 300 · openai 150"))
    }

    func testEmptyTraceRendersNothing() {
        let empty = TraceSummary(traceId: "t", spanCount: 0, totalTokens: 0, tokensByRole: [:], tokensByVendor: [:], errorCount: 0)
        XCTAssertTrue(empty.terminalLines().isEmpty)
    }

    func testTraceIDsAreUniqueHex() {
        let a = TraceID.make(), b = TraceID.make()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
    }
}
