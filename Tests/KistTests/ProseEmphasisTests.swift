import XCTest
@testable import Kist

/// Pins the streamed-prose markdown coloring. It must make research walls scannable WITHOUT ever
/// corrupting the stream or mis-rendering. Invariants: color:false emits nothing; a complete line's
/// marker pairs resolve correctly; unclosed markers stay literal with no escapes; code fences are
/// emitted raw; and line leads (header/bullet/number) get a colored glyph.
final class ProseEmphasisTests: XCTestCase {
    private let reset = "\u{001B}[0m"

    func testColorFalseEmitsNoEscapes() {
        let s = "**bold** and `code` and\n- a bullet\n"
        XCTAssertEqual(TerminalEventSink.emphasizeProse(s, color: false), s)
        XCTAssertEqual(TerminalEventSink.renderProseLine("**bold** `code`", color: false), "**bold** `code`")
    }

    func testCompleteBoldIsColoredAndMarkersStripped() {
        let out = TerminalEventSink.renderProseLine("see **this word** now", color: true)
        XCTAssertTrue(out.contains("\u{001B}[97;1mthis word\(reset)"))
        XCTAssertFalse(out.contains("**"), "the ** markers should be consumed when colored")
    }

    func testInlineCodeColored() {
        let out = TerminalEventSink.renderProseLine("run `swift build` ok", color: true)
        XCTAssertTrue(out.contains("\u{001B}[96mswift build\(reset)"))
    }

    func testTwoBoldSpansOnOneLinePairCorrectly() {
        // The cross-chunk mispairing Codex flagged is impossible once whole lines are rendered:
        // both spans resolve independently.
        let out = TerminalEventSink.renderProseLine("**a** mid **b**", color: true)
        XCTAssertTrue(out.contains("\u{001B}[97;1ma\(reset) mid \u{001B}[97;1mb\(reset)"))
        XCTAssertFalse(out.contains("**"))
    }

    func testUnclosedMarkerLeftLiteralNoEscapes() {
        let out = TerminalEventSink.renderProseLine("this is **important", color: true)
        XCTAssertEqual(out, "this is **important")
        XCTAssertFalse(out.contains("\u{001B}"), "an unmatched marker must not emit any escape")
    }

    func testCodeFenceContentsAreRaw() {
        // Inside a ``` fence, markdown-looking source must NOT be recolored or stripped.
        let block = "```\nlet x = a ** b   # not a header\ncall(`arg`)\n```\n"
        let out = TerminalEventSink.emphasizeProse(block, color: true)
        XCTAssertTrue(out.contains("let x = a ** b   # not a header"), "fence body must be verbatim")
        XCTAssertTrue(out.contains("call(`arg`)"), "backticks in a fence body must survive")
    }

    func testBulletHeaderAndNumberLeads() {
        XCTAssertTrue(TerminalEventSink.renderProseLine("- first", color: true)
            .contains("\u{001B}[96;1m•\(reset) first"))
        XCTAssertTrue(TerminalEventSink.renderProseLine("## Big Idea", color: true)
            .contains("\u{001B}[95;1m▸ Big Idea\(reset)"))
        XCTAssertTrue(TerminalEventSink.renderProseLine("1. do this", color: true)
            .contains("\u{001B}[93;1m1.\(reset) do this"))
    }

    func testEveryColoredRunIsBalanced() {
        let out = TerminalEventSink.emphasizeProse("**a** `b`\n- c\n## d\n1. e\n", color: true)
        let resets = out.components(separatedBy: reset).count - 1
        let csi = out.components(separatedBy: "\u{001B}[").count - 1
        XCTAssertEqual(csi, resets * 2, "each colored run is exactly one open + its reset")
    }
}
