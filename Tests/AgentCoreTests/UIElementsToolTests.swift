import XCTest
@testable import AgentCore

private struct MockProvider: UIElementProvider {
    let elements: [UIElement]
    func snapshot(maxElements: Int, on display: DisplayInfo?) -> [UIElement] { Array(elements.prefix(maxElements)) }
}

final class UIElementInspectorTests: XCTestCase {

    private func el(_ role: String, _ label: String?, x: Int = 100, y: Int = 100, w: Int = 80, h: Int = 40, enabled: Bool = true, value: String? = nil) -> UIElement {
        UIElement(role: role, label: label, value: value, x: x, y: y, width: w, height: h, enabled: enabled)
    }

    func testCenterIsElementMiddle() {
        let e = el("AXButton", "New Game", x: 600, y: 380, w: 80, h: 40)
        XCTAssertEqual(e.centerX, 640)
        XCTAssertEqual(e.centerY, 400)
    }

    func testFilterKeepsInteractiveOnlyByDefault() {
        let els = [el("AXButton", "Save"), el("AXStaticText", "Untitled"), el("AXImage", nil)]
        let out = UIElementRenderer.filter(els, query: nil, interactiveOnly: true)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].label, "Save")
    }

    func testFilterAllIncludesNonInteractive() {
        let els = [el("AXButton", "Save"), el("AXStaticText", "Untitled")]
        XCTAssertEqual(UIElementRenderer.filter(els, query: nil, interactiveOnly: false).count, 2)
    }

    func testFilterByQueryMatchesRoleOrLabel() {
        let els = [el("AXButton", "Save"), el("AXButton", "Cancel"), el("AXTextField", "filename")]
        XCTAssertEqual(UIElementRenderer.filter(els, query: "save", interactiveOnly: true).map(\.label), ["Save"])
        // role match
        XCTAssertEqual(UIElementRenderer.filter(els, query: "textfield", interactiveOnly: true).count, 1)
    }

    func testFilterDropsZeroSizeElements() {
        let els = [el("AXButton", "Ghost", w: 0, h: 0), el("AXButton", "Real")]
        XCTAssertEqual(UIElementRenderer.filter(els, query: nil, interactiveOnly: true).map(\.label), ["Real"])
    }

    func testRenderIsCompactAndHasCenter() {
        let r = UIElementRenderer.render([el("AXButton", "New Game", x: 600, y: 380, w: 80, h: 40)])
        XCTAssertTrue(r.contains("button"))         // AX prefix stripped
        XCTAssertTrue(r.contains("\"New Game\""))
        XCTAssertTrue(r.contains("@ (640,400)"))
    }

    func testRenderShowsDisabledState() {
        let r = UIElementRenderer.render([el("AXButton", "Load", enabled: false)])
        XCTAssertTrue(r.contains("[disabled]"))
    }

    func testRenderSanitizesUntrustedTextToSingleLine() {
        let r = UIElementRenderer.render([
            el("AXButton", "Save\nbutton \"Spoof\" @ (1,1)", value: "ready\r\nnext")
        ])
        XCTAssertFalse(r.contains("\n"))
        XCTAssertTrue(r.contains("\"Save button \\\"Spoof\\\" @ (1,1)\""))
        XCTAssertTrue(r.contains("=ready next"))
    }

    func testRenderBoundsLongLabels() {
        let long = String(repeating: "a", count: 140)
        let r = UIElementRenderer.render([el("AXButton", long)])
        XCTAssertFalse(r.contains(String(repeating: "a", count: 120)))
        XCTAssertTrue(r.contains(String(repeating: "a", count: 80) + "..."))
    }
}

final class UIElementsToolTests: XCTestCase {

    private func ctx() -> ToolContext { ToolContext(projectRoot: NSTemporaryDirectory()) }
    private func el(_ role: String, _ label: String?, enabled: Bool = true) -> UIElement {
        UIElement(role: role, label: label, value: nil, x: 600, y: 380, width: 80, height: 40, enabled: enabled)
    }

    func testListsInteractiveElementsWithClickGuidance() async throws {
        let tool = UIElementsTool(provider: MockProvider(elements: [el("AXButton", "New Game"), el("AXStaticText", "v1.0")]))
        let r = try await tool.execute(arguments: [:], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["count"], "1")   // only the button (interactive)
        XCTAssertTrue(r.output.contains("New Game"))
        XCTAssertTrue(r.output.contains("desktop_control"))
    }

    func testEmptyTreeGivesFallbackGuidance() async throws {
        let tool = UIElementsTool(provider: MockProvider(elements: []))
        let r = try await tool.execute(arguments: [:], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["count"], "0")
        XCTAssertTrue(r.output.contains("look/locate"))   // steers to vision fallback
    }

    func testQueryNoMatchStillSucceedsWithHint() async throws {
        let tool = UIElementsTool(provider: MockProvider(elements: [el("AXButton", "Save")]))
        let r = try await tool.execute(arguments: ["query": "delete"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["count"], "0")
        XCTAssertEqual(r.metadata["total"], "1")
    }

    func testAllIncludesNonInteractive() async throws {
        let tool = UIElementsTool(provider: MockProvider(elements: [el("AXButton", "Save"), el("AXStaticText", "hi")]))
        let r = try await tool.execute(arguments: ["all": true], context: ctx())
        XCTAssertEqual(r.metadata["count"], "2")
    }

    func testTargetPastTwoHundredStaticElementsIsStillFound() async throws {
        // Council: a low raw cap applied before filtering would miss a control after the first 200 nodes.
        var els = (0..<250).map { el("AXStaticText", "line \($0)") }
        els.append(el("AXButton", "New Game"))   // the real target, at index 250
        let tool = UIElementsTool(provider: MockProvider(elements: els))
        let r = try await tool.execute(arguments: ["query": "new game"], context: ctx())
        XCTAssertEqual(r.metadata["count"], "1")
        XCTAssertTrue(r.output.contains("New Game"))
    }

    func testExplicitBadDisplayIndexFails() async throws {
        // Multi-display: an explicit out-of-range display must FAIL, not silently read main. 99 is out
        // of range on any real setup (machine-independent).
        let tool = UIElementsTool(provider: MockProvider(elements: [el("AXButton", "Save")]))
        let r = try await tool.execute(arguments: ["display": 99], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("out of range") ?? false)
    }

    func testNonIntegerDisplayFails() async throws {
        let tool = UIElementsTool(provider: MockProvider(elements: [el("AXButton", "Save")]))
        let r = try await tool.execute(arguments: ["display": "left"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("whole-number") ?? false)
    }

    func testFractionalDisplayFailsNotTruncates() async throws {
        // Council HIGH: 0.5 must NOT truncate to display 0 (main) — it must fail.
        let tool = UIElementsTool(provider: MockProvider(elements: [el("AXButton", "Save")]))
        let r = try await tool.execute(arguments: ["display": 0.5], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("whole-number") ?? false)
    }

    func testReturnedListCappedAtMaxReturned() async throws {
        let els = (0..<300).map { el("AXButton", "btn \($0)") }
        let tool = UIElementsTool(provider: MockProvider(elements: els))
        let r = try await tool.execute(arguments: [:], context: ctx())
        XCTAssertEqual(r.metadata["count"], "\(UIElementsTool.maxReturned)")   // capped at 200
        XCTAssertEqual(r.metadata["total"], "300")
    }
}
