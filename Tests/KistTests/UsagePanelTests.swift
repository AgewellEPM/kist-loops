import XCTest
import AgentCore
@testable import Kist

final class UsagePanelTests: XCTestCase {
    func testUsagePanelRendersSessionWeekAndContributors() {
        let now = Date(timeIntervalSince1970: 1_782_700_000)
        let spans = [
            llm(id: "g1", now: now.addingTimeInterval(-40), role: "planner",
                vendor: "gemini", model: "gemini-2.5-flash", input: 12_000, output: 1_200),
            llm(id: "m1", now: now.addingTimeInterval(-20), role: "council_worker",
                vendor: "mimo", model: "mimo-v2.5-pro", input: 8_000, output: 2_000),
            tool(id: "t1", now: now.addingTimeInterval(-10), name: "read_file"),
        ]

        let out = UsagePanel.render(sessionSpans: spans, ledgerSpans: spans, now: now, color: false)

        XCTAssertTrue(out.contains("📊 Usage"))
        XCTAssertTrue(out.contains("Session"))
        XCTAssertTrue(out.contains("This week"))
        XCTAssertTrue(out.contains("By model"))
        XCTAssertTrue(out.contains("gemini:gemini-2.5-flash"))
        XCTAssertTrue(out.contains("mimo:mimo-v2.5-pro"))
        XCTAssertTrue(out.contains("council_worker"), "delegated role shown under Subagents")
        XCTAssertTrue(out.contains("Subscription providers"))
        XCTAssertTrue(out.contains("delegated/council"))
    }

    func testClaudeAndCodexCliShownAsSubscription() {
        let now = Date(timeIntervalSince1970: 1_782_700_000)
        let spans = [
            llm(id: "c1", now: now, role: "captain", vendor: "claude-cli", model: "claude-opus-4-8", input: 50_000, output: 3_000),
            llm(id: "x1", now: now, role: "critic", vendor: "codex-cli", model: "gpt-5.6-sol", input: 20_000, output: 1_000),
        ]
        let out = UsagePanel.render(sessionSpans: spans, ledgerSpans: spans, now: now.addingTimeInterval(5), color: false)
        XCTAssertTrue(out.contains("claude-cli:claude-opus-4-8"))
        XCTAssertTrue(out.contains("codex-cli:gpt-5.6-sol"))
        XCTAssertTrue(out.contains("subscription"), "keyless CLI providers read 'subscription', not a $ figure")
        XCTAssertFalse(out.contains("unpriced, "), "no redundant 'unpriced, N unpriced' phrasing")
    }

    func testUsageCardRowsAreEqualCellWidth() {
        let now = Date(timeIntervalSince1970: 1_782_700_000)
        let spans = [
            llm(id: "c1", now: now, role: "coder", vendor: "claude-cli", model: "claude-opus-4-8", input: 90_000, output: 6_000),
            tool(id: "t1", now: now, name: "write_file"), tool(id: "t2", now: now, name: "mcp__perslis__vm_launch"),
        ]
        for color in [false, true] {
            let out = UsagePanel.render(sessionSpans: spans, ledgerSpans: spans, now: now.addingTimeInterval(5), color: color)
            let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            for line in lines where line.contains("│") || line.contains("╭") || line.contains("╰") {
                XCTAssertEqual(TerminalCellText.width(line), 76,
                               "usage card row not 76 cells (color=\(color)): \(TerminalCellText.stripANSI(line))")
            }
        }
    }

    func testCostByActivityAttributesRolesToEngineeringWork() {
        XCTAssertEqual(UsagePanel.activity(for: "architect"), "Architecture")
        XCTAssertEqual(UsagePanel.activity(for: "coder"), "Code generation")
        XCTAssertEqual(UsagePanel.activity(for: "critic"), "Review & tests")
        XCTAssertEqual(UsagePanel.activity(for: "deep-research-worker"), "Deep research")
        XCTAssertEqual(UsagePanel.activity(for: "captain"), "Orchestration")
        XCTAssertEqual(UsagePanel.activity(for: nil), "Orchestration")

        let now = Date(timeIntervalSince1970: 1_782_700_000)
        let spans = [
            llm(id: "a", now: now, role: "architect", vendor: "gemini", model: "g", input: 80_000, output: 4_000),
            llm(id: "c", now: now, role: "coder", vendor: "gemini", model: "g", input: 20_000, output: 2_000),
        ]
        let out = UsagePanel.render(sessionSpans: spans, ledgerSpans: spans, now: now.addingTimeInterval(5), color: false)
        XCTAssertTrue(out.contains("Cost by activity"))
        XCTAssertTrue(out.contains("Architecture"))
        XCTAssertTrue(out.contains("Code generation"))
    }

    func testUsagePanelHandlesEmptyTraceHonestly() {
        let out = UsagePanel.render(sessionSpans: [], ledgerSpans: [], color: false)

        XCTAssertTrue(out.contains("No token usage recorded"))
        XCTAssertTrue(out.contains("Subscription providers"))
    }

    func testUsageByModelIsCappedToTopBuckets() {
        let now = Date(timeIntervalSince1970: 1_782_700_000)
        let spans = (0..<10).map { i in
            llm(id: "s\(i)", now: now.addingTimeInterval(TimeInterval(i)), role: "role\(i)",
                vendor: "vendor\(i)", model: "model\(i)", input: 1000 + i * 100, output: 10)
        }

        let out = UsagePanel.render(sessionSpans: spans, ledgerSpans: spans, now: now.addingTimeInterval(20), color: false)

        XCTAssertTrue(out.contains("vendor9:model9"), "highest-token model shown")
        XCTAssertFalse(out.contains("vendor0:model0"), "lowest models beyond top-8 are capped out")
    }

    func testUsageLedgerPersistsAndDeduplicatesSpans() throws {
        let root = NSTemporaryDirectory() + "kist-usage-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let now = Date(timeIntervalSince1970: 1_782_700_000)
        let span = llm(id: "same-span", now: now, role: "coder",
                       vendor: "deepseek", model: "deepseek-v4-pro", input: 1000, output: 300)
        let duplicate = llm(id: "same-span", now: now.addingTimeInterval(10), role: "critic",
                            vendor: "grok", model: "grok-4.3", input: 9000, output: 3000)

        XCTAssertTrue(UsageLedger.append(projectRoot: root, spans: [span, span]))
        XCTAssertTrue(UsageLedger.append(projectRoot: root, spans: [duplicate]))
        let loaded = UsageLedger.load(projectRoot: root)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "same-span")
        XCTAssertEqual(loaded.first?.vendor, "deepseek")
        XCTAssertTrue(FileManager.default.fileExists(atPath: UsageLedger.usagePath(projectRoot: root)))
    }

    func testUsagePanelSurfacesMalformedLedgerLines() throws {
        let root = NSTemporaryDirectory() + "kist-usage-bad-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/.kist", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = UsageLedger.usagePath(projectRoot: root)
        try Data("not-json\n".utf8).write(to: URL(fileURLWithPath: path))

        let out = UsagePanel.render(sessionSpans: [], projectRoot: root, color: false)

        XCTAssertTrue(out.contains("Ledger warning: 1 unreadable usage line"))
    }

    private func llm(id: String, now: Date, role: String, vendor: String, model: String,
                     input: Int, output: Int) -> AgentSpan {
        AgentSpan(id: id, traceId: "trace", kind: .llmCall, role: role, vendor: vendor, model: model,
                  promptTokens: input, completionTokens: output,
                  startedAt: now, endedAt: now.addingTimeInterval(1), status: .ok)
    }

    private func tool(id: String, now: Date, name: String) -> AgentSpan {
        AgentSpan(id: id, traceId: "trace", kind: .toolCall, toolName: name,
                  startedAt: now, endedAt: now.addingTimeInterval(1), status: .ok)
    }
}
