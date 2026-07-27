import XCTest
@testable import Kist

/// The command "glow" (a real command lights up purple) + the live slash menu — pure, pinned without a
/// terminal. Purple = ESC[35;1m, cyan-bold = ESC[36;1m, cyan = ESC[36m, dim = ESC[2m.
final class InputGlowTests: XCTestCase {

    private let cmds: Set<String> = ["model", "media", "chain", "copilot", "clear", "council"]

    // MARK: glow on the input line — exact / prefix / unknown

    func testExactCommandGlowsPurple() {
        let out = InputHighlighter.highlight("/model", commands: cmds)
        XCTAssertTrue(out.contains("\u{001B}[35;1m/model\u{001B}[0m"), "an exact command must glow purple")
    }

    func testValidPrefixIsCyanNotPurple() {
        // "/mod" is on its way to "/model" but isn't a command yet → cyan, not the purple glow.
        let out = InputHighlighter.highlight("/mod", commands: cmds)
        XCTAssertTrue(out.contains("\u{001B}[36;1m/mod\u{001B}[0m"))
        XCTAssertFalse(out.contains("\u{001B}[35;1m"))
    }

    func testUnknownCommandIsDim() {
        // "/zzz" matches nothing → dim, signalling "this won't trigger anything".
        let out = InputHighlighter.highlight("/zzz", commands: cmds)
        XCTAssertTrue(out.contains("\u{001B}[2m/zzz\u{001B}[0m"))
    }

    func testGlowOnlyAppliesToLeadingCommandToken() {
        // The command glows; the argument after it is highlighted as ordinary body text, not a command.
        let out = InputHighlighter.highlight("/model gemini", commands: cmds)
        XCTAssertTrue(out.contains("\u{001B}[35;1m/model\u{001B}[0m"))
        XCTAssertTrue(out.contains("gemini"))
    }

    func testEmptyCatalogPreservesOldCyanBehavior() {
        // No catalog wired ⇒ any /token stays cyan (no regression for callers that don't pass commands).
        let out = InputHighlighter.highlight("/whatever", commands: [])
        XCTAssertTrue(out.contains("\u{001B}[36;1m/whatever\u{001B}[0m"))
    }

    // MARK: the live slash menu

    func testMenuForBareSlashListsCommands() {
        let menu = InputHighlighter.commandMenu(typed: "", commands: cmds, width: 80)
        XCTAssertTrue(menu.contains("/model"))
        XCTAssertTrue(menu.contains("/council"))
    }

    // MARK: arrow-key browse mode (↓ opens, ←/→ move, ⏎ picks)

    func testBrowseShowsAffordanceWhenOverflowing() {
        // Many commands + a narrow box ⇒ some hidden ⇒ the "↓ browse" affordance appears.
        let many = Set((0..<40).map { "command\($0)" })
        let menu = InputHighlighter.commandMenu(typed: "", commands: many, width: 40, selected: nil)
        XCTAssertTrue(menu.contains("↓ browse"), "overflowing menu must invite ↓ to browse: \(menu)")
    }

    func testBrowseHighlightsSelectedAndShowsPosition() {
        let many = (0..<40).map { "command\($0)" }
        let set = Set(many)
        let sorted = InputHighlighter.commandMatches(typed: "", commands: set)
        // Select an index deep in the list; the window must scroll to include it, draw it reversed,
        // and show its 1-based position + the ←→ / ⏎ affordance.
        let sel = 20
        let menu = InputHighlighter.commandMenu(typed: "", commands: set, width: 40, selected: sel)
        XCTAssertTrue(menu.contains("\u{001B}[7m/\(sorted[sel])\u{001B}[0m"), "selected command must be reversed")
        XCTAssertTrue(menu.contains("\(sel + 1)/\(sorted.count)"), "position indicator must be shown")
        XCTAssertTrue(menu.contains("⏎"), "pick affordance must be shown")
    }

    func testBrowseClampsIndicatorToMatchCount() {
        let menu = InputHighlighter.commandMenu(typed: "c", commands: cmds, width: 80, selected: 0)
        // typed "c" → chain/clear/copilot/council (4). Indicator counts only the filtered set.
        XCTAssertTrue(menu.contains("1/4"), "position must be relative to the filtered matches: \(menu)")
    }

    func testMenuFiltersByPrefixAndGlowsExact() {
        let menu = InputHighlighter.commandMenu(typed: "c", commands: cmds, width: 80)
        XCTAssertTrue(menu.contains("/chain"))
        XCTAssertTrue(menu.contains("/copilot"))
        XCTAssertTrue(menu.contains("/clear"))
        XCTAssertFalse(menu.contains("/model"), "'c' must not surface /model")
        // exact match glows purple
        let exact = InputHighlighter.commandMenu(typed: "chain", commands: cmds, width: 80)
        XCTAssertTrue(exact.contains("\u{001B}[35;1m/chain\u{001B}[0m"))
    }

    func testMenuReportsNoMatch() {
        let menu = InputHighlighter.commandMenu(typed: "qqq", commands: cmds, width: 80)
        XCTAssertTrue(menu.contains("no command matches /qqq"))
    }

    func testMenuStaysWithinWidthBudget() {
        // A narrow box must not spill the menu across lines (would break the box cursor math). Strip ANSI
        // and assert the visible text fits the budget-ish (never the full catalog).
        let many = Set((0..<40).map { "command\($0)" })
        let menu = InputHighlighter.commandMenu(typed: "", commands: many, width: 40)
        let visible = menu.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        XCTAssertLessThanOrEqual(visible.count, 60, "menu must stay roughly one line: \(visible)")
        XCTAssertTrue(menu.contains("+"), "a truncated menu shows a +N overflow count")
    }
}
