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

        XCTAssertTrue(out.contains("Usage"))
        XCTAssertTrue(out.contains("Session"))
        XCTAssertTrue(out.contains("Local Week"))
        XCTAssertTrue(out.contains("gemini:gemini-2.5-flash"))
        XCTAssertTrue(out.contains("mimo:mimo-v2.5-pro"))
        XCTAssertTrue(out.contains("council_worker"))
        XCTAssertTrue(out.contains("Account quota:"))
        XCTAssertTrue(out.contains("delegated/council"))
    }

    func testUsagePanelHandlesEmptyTraceHonestly() {
        let out = UsagePanel.render(sessionSpans: [], ledgerSpans: [], color: false)

        XCTAssertTrue(out.contains("No token usage recorded"))
        XCTAssertTrue(out.contains("Account quota:     unavailable locally"))
    }

    func testUsagePanelShowsHiddenBucketCount() {
        let now = Date(timeIntervalSince1970: 1_782_700_000)
        let spans = (0..<10).map { i in
            llm(id: "s\(i)", now: now.addingTimeInterval(TimeInterval(i)), role: "role\(i)",
                vendor: "vendor\(i)", model: "model\(i)", input: 1000 + i, output: 10)
        }

        let out = UsagePanel.render(sessionSpans: spans, ledgerSpans: spans, now: now.addingTimeInterval(20), color: false)

        XCTAssertTrue(out.contains("... and 2 more"))
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
