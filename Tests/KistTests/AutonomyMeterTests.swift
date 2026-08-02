import XCTest
import AgentCore
@testable import Kist

final class AutonomyMeterTests: XCTestCase {
    private func span(_ kind: SpanKind, role: String? = nil, tool: String? = nil, ms: Double) -> AgentSpan {
        let t0 = Date(timeIntervalSince1970: 1_785_000_000)
        return AgentSpan(id: UUID().uuidString, traceId: "t", kind: kind, role: role, vendor: "gemini",
                         model: "m", toolName: tool, startedAt: t0, endedAt: t0.addingTimeInterval(ms / 1000), status: .ok)
    }

    func testPhaseMapping() {
        XCTAssertEqual(AutonomyMeter.phase(for: span(.toolCall, tool: "web_search", ms: 1)), .researching)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.toolCall, tool: "read_file", ms: 1)), .researching)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.toolCall, tool: "write_file", ms: 1)), .coding)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.toolCall, tool: "run_command", ms: 1)), .running)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.toolCall, tool: "spawn_agent", ms: 1)), .delegating)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.llmCall, role: "captain", ms: 1)), .thinking)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.llmCall, role: "coder", ms: 1)), .coding)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.llmCall, role: "critic", ms: 1)), .running)
        XCTAssertEqual(AutonomyMeter.phase(for: span(.llmCall, role: "researcher", ms: 1)), .researching)
    }

    func testSlicesAggregateTimeRichestFirst() {
        let spans = [
            span(.llmCall, role: "captain", ms: 40_000),
            span(.toolCall, tool: "run_command", ms: 30_000),
            span(.toolCall, tool: "read_file", ms: 3_000),
        ]
        let slices = AutonomyMeter.slices(spans)
        XCTAssertEqual(slices.first?.phase, .thinking)              // 40s = biggest
        XCTAssertEqual(slices.first?.seconds ?? 0, 40, accuracy: 0.001)
        XCTAssertEqual(slices.map { $0.phase }, [.thinking, .running, .researching])
    }

    func testRenderCard() {
        let spans = [span(.llmCall, role: "coder", ms: 10_000), span(.toolCall, tool: "run_command", ms: 5_000)]
        let out = AutonomyMeter.render(spans: spans, color: false)
        XCTAssertTrue(out.contains("🫀 Autonomy"))
        XCTAssertTrue(out.contains("Coding"))
        XCTAssertTrue(out.contains("Running"))
        XCTAssertTrue(out.contains("total"))
        XCTAssertFalse(out.contains("\u{001B}"), "color:false must emit no escapes")
    }

    func testEmptyIsHonest() {
        XCTAssertTrue(AutonomyMeter.slices([]).isEmpty)
        XCTAssertTrue(AutonomyMeter.render(spans: [], color: false).contains("No timed activity"))
    }

    func testCardRowsAreEqualCellWidth() {
        let spans = [span(.llmCall, role: "captain", ms: 40_000), span(.toolCall, tool: "web_search", ms: 8_000)]
        for color in [false, true] {
            let out = AutonomyMeter.render(spans: spans, color: color, width: 76)
            for line in out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            where line.contains("│") || line.contains("╭") || line.contains("╰") {
                XCTAssertEqual(TerminalCellText.width(line), 76,
                               "autonomy row not 76 cells (color=\(color)): \(TerminalCellText.stripANSI(line))")
            }
        }
    }

    func testAutonomyCommandsCompletable() {
        for cmd in ["/autonomy", "/activity", "/pulse"] {
            XCTAssertTrue(InputCompleter.builtInCommands.contains(cmd))
        }
    }
}
