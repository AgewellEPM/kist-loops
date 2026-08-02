import XCTest
@testable import Kist

/// Pins the streamed-prose markdown coloring: it must make research walls scannable WITHOUT ever
/// corrupting the stream. The invariants that matter: balanced escapes only, split markers left
/// literal, mono/NO_COLOR emits nothing, and a mid-sentence chunk is never falsely bulletized.
final class ProseEmphasisTests: XCTestCase {
    private let reset = "\u{001B}[0m"

    func testColorFalseEmitsNoEscapes() {
        let s = "**bold** and `code` and\n- a bullet\n"
        XCTAssertEqual(TerminalEventSink.emphasizeProse(s, color: false), s)
    }

    func testCompleteBoldIsColoredAndMarkersStripped() {
        let out = TerminalEventSink.emphasizeProse("see **this word** now", color: true)
        XCTAssertTrue(out.contains("\u{001B}[97;1mthis word\(reset)"))
        XCTAssertFalse(out.contains("**"), "the ** markers should be consumed when colored")
    }

    func testInlineCodeColored() {
        let out = TerminalEventSink.emphasizeProse("run `swift build` ok", color: true)
        XCTAssertTrue(out.contains("\u{001B}[96mswift build\(reset)"))
    }

    func testSplitMarkerLeftLiteralAndBalanced() {
        // A ** with no closer on the line must be left untouched (the other half is in the next chunk),
        // and no escape sequence may be emitted for it.
        let out = TerminalEventSink.emphasizeProse("this is **important", color: true)
        XCTAssertEqual(out, "this is **important")
        XCTAssertFalse(out.contains("\u{001B}"), "an unmatched marker must not emit any escape")
    }

    func testEveryColorRunIsBalanced() {
        // Whatever gets colored, opens (CSI with an m-terminated arg) must each be closed by a reset.
        let out = TerminalEventSink.emphasizeProse("**a** `b`\n- c\n## d\n1. e\n", color: true)
        let resets = out.components(separatedBy: reset).count - 1
        let opens = out.components(separatedBy: "\u{001B}[").count - 1
        XCTAssertEqual(opens, resets * 2, "each colored run is one open + its reset (reset is also a CSI)")
    }

    func testBulletAtLineStartGetsColoredDot() {
        let out = TerminalEventSink.emphasizeProse("- first\n- second\n", color: true, firstIsLineStart: true)
        XCTAssertTrue(out.contains("\u{001B}[96;1m•\(reset) first"))
    }

    func testMidSentenceChunkNotFalselyBulletized() {
        // Previous chunk ended mid-line, so this chunk's line 0 is a continuation — "- x" here is NOT a
        // real bullet and must be left alone.
        let out = TerminalEventSink.emphasizeProse("- not a bullet\nreal line\n", color: true, firstIsLineStart: false)
        XCTAssertTrue(out.hasPrefix("- not a bullet"), "continuation line must keep its literal leading dash")
    }

    func testHeaderGetsNeonLead() {
        let out = TerminalEventSink.emphasizeProse("## Big Idea\nbody\n", color: true, firstIsLineStart: true)
        XCTAssertTrue(out.contains("\u{001B}[95;1m▸ Big Idea\(reset)"))
        XCTAssertFalse(out.contains("## "))
    }

    func testNumberedListColored() {
        let out = TerminalEventSink.emphasizeProse("1. do this\n2. then that\n", color: true, firstIsLineStart: true)
        XCTAssertTrue(out.contains("\u{001B}[93;1m1.\(reset) do this"))
    }
}
