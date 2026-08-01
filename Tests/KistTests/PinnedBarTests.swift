import XCTest
@testable import Kist

/// R2b (2026-07-29): the always-visible bottom input bar. Pure screen-math pins (no terminal), plus
/// the load-bearing SAFE-FALLBACK guarantee: a disabled bar emits exactly the pre-R2b inline bytes.
final class PinnedBarTests: XCTestCase {

    // MARK: - PinnedBarLayout math (panelRows = 6, sized to the tallest panel)

    func testBandAndPanelSplit() {
        let l = PinnedBarLayout(rows: 40, cols: 100, panelRows: 6)
        XCTAssertEqual(l.transcriptBottom, 34, "band is rows 1..34")
        XCTAssertEqual(l.panelTop, 35, "panel starts right below the band")
    }

    func testActivateSetsRegionAndParksInBand() {
        let l = PinnedBarLayout(rows: 40, cols: 100, panelRows: 6)
        // DECSTBM [1;34r confines scrolling to the band; cursor drops to the band's last row.
        XCTAssertEqual(l.activateSequence, "\u{001B}[1;34r" + "\u{001B}[34;1H")
    }

    func testReReserveScrollsTranscriptUpBeforePinning() {
        let l = PinnedBarLayout(rows: 40, cols: 100, panelRows: 6)
        // Re-pin after a turn must FIRST scroll the transcript up by panelRows so turn-trailing output
        // (the second-opinion review) in the bottom band is preserved in scrollback, NOT clobbered by
        // the panel clear that follows. Then it pins exactly like activate.
        XCTAssertEqual(l.reReserveSequence, String(repeating: "\n", count: 6) + l.activateSequence)
        XCTAssertTrue(l.reReserveSequence.hasPrefix("\n\n\n\n\n\n"),
                      "must scroll up one row per reserved panel row before pinning")
        XCTAssertTrue(l.reReserveSequence.hasSuffix(l.activateSequence),
                      "after the scroll-up it still sets the region + parks the cursor")
        // The scroll-up count is exactly panelRows — never eats more transcript than the band it protects.
        XCTAssertEqual(l.reReserveSequence.prefix(while: { $0 == "\n" }).count, l.panelRows)
    }

    func testDeactivateReleasesRegionAndRestores() {
        let l = PinnedBarLayout(rows: 40, cols: 100, panelRows: 6)
        XCTAssertEqual(l.deactivateSequence,
                       "\u{001B}[r" + "\u{001B}[40;1H" + "\u{001B}[?25h" + "\r\n",
                       "reset region → real last row → show cursor → newline off the panel")
    }

    func testPanelLeadClearsEachPhysicalRowWithoutED() {
        let l = PinnedBarLayout(rows: 40, cols: 100, panelRows: 6)
        XCTAssertFalse(l.panelLeadSequence.contains(TerminalANSI.clearBelow),
                       "ED is forbidden while DECSTBM is active")
        XCTAssertFalse(l.panelLeadSequence.contains("\n"))
        XCTAssertEqual(l.panelLeadSequence.components(separatedBy: "\u{001B}[K").count - 1, 6)
        XCTAssertTrue(l.panelLeadSequence.hasSuffix(TerminalANSI.moveTo(row: l.panelTop, col: 1)))
    }

    func testTranscriptLeadParksOnLastBandRow() {
        let l = PinnedBarLayout(rows: 40, cols: 100, panelRows: 6)
        XCTAssertEqual(l.transcriptLeadSequence, "\u{001B}[34;1H")
    }

    func testPanelNeverEatsTheWholeScreen() {
        // A panel taller than the screen is clamped so at least one transcript row survives.
        let l = PinnedBarLayout(rows: 4, cols: 80, panelRows: 5)
        XCTAssertEqual(l.panelRows, 3, "clamped to rows-1")
        XCTAssertGreaterThanOrEqual(l.transcriptBottom, 1)
        XCTAssertEqual(l.panelTop, l.transcriptBottom + 1)
    }

    func testRegionBottomNeverGoesBelowOne() {
        // Degenerate tiny terminal must still emit a valid (non-negative) region.
        let l = PinnedBarLayout(rows: 2, cols: 80, panelRows: 6)
        XCTAssertTrue(l.activateSequence.contains("\u{001B}[1;1r"), l.activateSequence)
    }

    // MARK: - the panel MUST fit in the reserved strip (the overflow bug the review caught)

    func testReservedStripFitsTheTallestPanel() {
        // The panel is `statusRows` (1 line, or 2 when a task board is active) + boxRows (top border,
        // input, bottom border, hint). If content ever exceeds panelRows the box overflows the DECSTBM
        // region and corrupts the panel — exactly the mid-plan state R2b exists to keep pinned. This
        // pins the invariant on BOTH status heights (the 2-line variant is the one that broke).
        for statusRows in [1, 2] {
            XCTAssertLessThanOrEqual(statusRows + PinnedBar.boxRows, PinnedBar.panelRows,
                                     "a \(statusRows)-line status panel must fit the reserved \(PinnedBar.panelRows)-row strip")
        }
    }

    func testStatusIsNeverMoreThanTwoLines() {
        // The fit above assumes status ≤ 2 physical rows. If StatusLine grows a 3rd line, this fails
        // loudly (raise panelRows in lockstep) instead of silently overflowing the panel again.
        let twoLine = StatusLine(modelLabel: "m", mode: "plan", cost: "$0 · 1k tok",
                                 activeTask: "E3 doing a thing", nextStep: "E4 then the next")
        XCTAssertLessThanOrEqual(twoLine.render(color: false).split(separator: "\n", omittingEmptySubsequences: false).count, 2,
                                 "status must stay ≤ 2 rows or panelRows must grow with it")
        let oneLine = StatusLine(modelLabel: "m", mode: "chat", cost: "—", activeTask: nil, nextStep: nil)
        XCTAssertEqual(oneLine.render(color: false).split(separator: "\n", omittingEmptySubsequences: false).count, 1)
    }

    // MARK: - PinnedBar controller gating & SAFE FALLBACK

    func testDisabledBarIsInertAndByteIdenticalToInlineREPL() {
        // The whole point of the fallback: when off, the loop emits exactly what pre-R2b emitted —
        // a bare "\n" before the panel and nothing before the turn. Any drift here is a silent
        // regression to every non-TTY/piped/`--no-pinned-bar` session.
        let bar = PinnedBar(enabled: false)
        bar.activate()
        XCTAssertFalse(bar.active, "disabled bar must never pin")
        XCTAssertEqual(bar.panelLead(), "\n", "off ⇒ the old inline leading newline")
        XCTAssertEqual(bar.transcriptLead(), "", "off ⇒ no cursor parking")
        bar.deactivate()   // must be a safe no-op even though never activated
    }

    func testEnabledBarInNonTTYTestProcessStaysInert() {
        // The test runner's stdout is not a TTY, so even enabled the bar must refuse to pin (it would
        // otherwise spray scroll-region escapes into a captured log). Proves the isatty gate.
        let bar = PinnedBar(enabled: true)
        bar.activate()
        XCTAssertFalse(bar.active, "no TTY ⇒ no pin, even when enabled")
        XCTAssertEqual(bar.panelLead(), "\n")
        XCTAssertEqual(bar.transcriptLead(), "")
    }
}
