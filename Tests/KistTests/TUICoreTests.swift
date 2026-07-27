import XCTest
@testable import Kist

final class TUICoreTests: XCTestCase {

    // MARK: KeyDecoder

    func testDecodesPlainTextAndControlKeys() {
        XCTAssertEqual(KeyDecoder.decode(Array("hi".utf8)), [.char("h"), .char("i")])
        XCTAssertEqual(KeyDecoder.decode([0x0D]), [.enter])
        XCTAssertEqual(KeyDecoder.decode([0x7F]), [.backspace])
        XCTAssertEqual(KeyDecoder.decode([0x03]), [.ctrlC])
        XCTAssertEqual(KeyDecoder.decode([0x04]), [.ctrlD])
        XCTAssertEqual(KeyDecoder.decode([0x16]), [.ctrlV])
    }

    func testDecodesArrowAndEditSequences() {
        XCTAssertEqual(KeyDecoder.decode([0x1B, 0x5B, 0x41]), [.up])
        XCTAssertEqual(KeyDecoder.decode([0x1B, 0x5B, 0x42]), [.down])
        XCTAssertEqual(KeyDecoder.decode([0x1B, 0x5B, 0x43]), [.right])
        XCTAssertEqual(KeyDecoder.decode([0x1B, 0x5B, 0x44]), [.left])
        XCTAssertEqual(KeyDecoder.decode([0x1B, 0x5B, 0x33, 0x7E]), [.delete])   // ESC [ 3 ~
    }

    func testDecodesMixedRunThenEnter() {
        XCTAssertEqual(KeyDecoder.decode(Array("ab".utf8) + [0x0D]), [.char("a"), .char("b"), .enter])
    }

    func testDecodesUTF8MultibyteCharacter() {
        XCTAssertEqual(KeyDecoder.decode(Array("é".utf8)), [.char("é")])
    }

    // MARK: LineEditor

    func testLineEditorTypeMoveDeleteSubmit() {
        var e = LineEditor()
        for c in "helo" { _ = e.handle(.char(c)) }
        XCTAssertEqual(e.line, "helo")
        _ = e.handle(.left)                       // cursor before 'o'
        _ = e.handle(.char("l"))                  // insert 'l' → "hello"
        XCTAssertEqual(e.line, "hello")
        XCTAssertEqual(e.handle(.enter), .submit("hello"))
        XCTAssertEqual(e.line, "")                // cleared after submit
    }

    func testLineEditorBackspaceAndCtrlU() {
        var e = LineEditor()
        for c in "abc" { _ = e.handle(.char(c)) }
        _ = e.handle(.backspace)
        XCTAssertEqual(e.line, "ab")
        _ = e.handle(.ctrlU)
        XCTAssertEqual(e.line, "")
    }

    func testLineEditorWordDelete() {
        var e = LineEditor()
        for c in "hello world" { _ = e.handle(.char(c)) }
        _ = e.handle(.ctrlW)
        XCTAssertEqual(e.line, "hello ")
    }

    func testLineEditorHistoryBrowse() {
        var e = LineEditor()
        for c in "first" { _ = e.handle(.char(c)) }
        _ = e.handle(.enter)
        for c in "second" { _ = e.handle(.char(c)) }
        _ = e.handle(.enter)
        _ = e.handle(.up)
        XCTAssertEqual(e.line, "second")
        _ = e.handle(.up)
        XCTAssertEqual(e.line, "first")
        _ = e.handle(.down)
        XCTAssertEqual(e.line, "second")
    }

    func testLineEditorCtrlDEofOnlyWhenEmpty() {
        var e = LineEditor()
        XCTAssertEqual(e.handle(.ctrlD), .eof)
        _ = e.handle(.char("x"))
        XCTAssertEqual(e.handle(.ctrlD), .ignored)
    }

    func testLineEditorReplaceRangeForCompletion() {
        var e = LineEditor()
        for c in "/he" { _ = e.handle(.char(c)) }
        e.replace(range: 0..<3, with: "/help")
        XCTAssertEqual(e.line, "/help")
        XCTAssertEqual(e.cursor, 5)
    }

    // MARK: Completion + highlighting

    func testInputCompleterCompletesSingleSlashCommand() {
        let single = InputCompleter.edit(line: "/log", cursor: 4, candidates: ["/logs", "/help"])
        XCTAssertEqual(single?.replacement, "/logs")
        XCTAssertEqual(single?.completed, true)
    }

    func testInputCompleterIncludesCaptainStrategyCommands() {
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/captain"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/strategy"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/organize"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/teach"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/rules"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/learning"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/model-learning"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/industry"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/strategic-intelligence"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/retrieve"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/recall"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/self-heal"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/fix-self"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/simulate"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/sandbox"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/symbolic"))
        XCTAssertTrue(InputCompleter.builtInCommands.contains("/workflow"))
    }

    func testInputCompleterUsesCommonPrefix() {
        let edit = InputCompleter.edit(line: "/h", cursor: 2, candidates: ["/help", "/health"])
        XCTAssertEqual(edit?.replacement, "/he")
        XCTAssertEqual(edit?.completed, true)
    }

    func testInputCompleterExtractsProjectSymbols() {
        let text = """
        import Foundation
        struct PromptBox {}
        func renderInput() {}
        let activeTask = 1
        """
        let symbols = InputCompleter.extractSymbols(from: text)
        XCTAssertTrue(symbols.contains("PromptBox"))
        XCTAssertTrue(symbols.contains("renderInput"))
        XCTAssertTrue(symbols.contains("activeTask"))
    }

    func testInputHighlighterColorsCommandsFlagsAndKeywords() {
        let out = InputHighlighter.highlight("/model --help func renderInput", color: true)
        XCTAssertTrue(out.contains("\u{001B}[36;1m/model"))
        XCTAssertTrue(out.contains("\u{001B}[33m--help"))
        XCTAssertTrue(out.contains("\u{001B}[35;1mfunc"))
    }

    func testEnhancedPromptReaderCollapsesRepeatedPastedPaths() {
        let path = "/Users/lukekist/Desktop/Mythos Desktop Cleanup 2026-06-28 22.30.43/Scyrou/Screenshot 33.png"
        let repeated = Array(repeating: "'\(path)'", count: 12).joined(separator: " ")
        let normalized = EnhancedPromptReader.normalizePastedText(repeated)

        XCTAssertEqual(MediaResolver.tokenize(normalized), [path])
    }

    func testBoxedPromptWindowsLongInputSoItDoesNotWrap() {
        let line = String(repeating: "a", count: 120)
        let window = EnhancedPromptReader.boxedPromptWindow(line: line, cursor: line.count,
                                                            promptColumns: 4, width: 80)

        XCTAssertEqual(window.text.count, 74)
        XCTAssertEqual(window.text, String(repeating: "a", count: 74))
        XCTAssertEqual(window.cursorCol, 79)
    }

    func testBoxedPromptKeepsCursorVisibleInLongInput() {
        let line = "0123456789" + String(repeating: "x", count: 100)
        let window = EnhancedPromptReader.boxedPromptWindow(line: line, cursor: 10,
                                                            promptColumns: 4, width: 20)

        XCTAssertEqual(window.text.count, 14)
        XCTAssertTrue(window.text.hasPrefix("0123456789"))
        XCTAssertEqual(window.cursorCol, 15)
    }

    // MARK: ScreenLayout

    func testScreenLayoutPinsInputBox() {
        let l = ScreenLayout(rows: 24, cols: 80, inputRows: 2)
        XCTAssertEqual(l.transcriptBottom, 22)
        XCTAssertEqual(l.inputTop, 23)
        XCTAssertEqual(l.scrollRegion, "\u{001B}[1;22r")
    }

    func testScreenLayoutClampsInputRowsOnTinyScreen() {
        let l = ScreenLayout(rows: 2, cols: 40, inputRows: 5)
        XCTAssertGreaterThanOrEqual(l.transcriptBottom, 1)   // never zero/negative
        XCTAssertEqual(l.inputRows, 1)
    }
}
