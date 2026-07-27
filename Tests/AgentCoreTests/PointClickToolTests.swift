import XCTest
@testable import AgentCore

final class PointClickToolTests: XCTestCase {

    private func ctx() -> ToolContext { ToolContext(projectRoot: NSTemporaryDirectory()) }

    func testTapCapturesLocatesAndClicks() async throws {
        var clickedAt: (Int, Int)? = nil
        let tool = PointClickTool(
            capture: { (Data([0]), 800, 600) },
            locate: { _, _ in [.init(x: 0.5, y: 0.5)] },
            click: { x, y, _, _ in clickedAt = (x, y); return .clicked(x: x, y: y) })
        let r = try await tool.execute(arguments: ["target": "the button"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["x"], "400")
        XCTAssertEqual(r.metadata["y"], "300")
        XCTAssertEqual(clickedAt?.0, 400)
        XCTAssertEqual(clickedAt?.1, 300)
    }

    func testTapNotFoundIsSuccessAndDoesNotClick() async throws {
        var clicked = false
        let tool = PointClickTool(
            capture: { (Data([0]), 800, 600) },
            locate: { _, _ in [] },   // not visible
            click: { _, _, _, _ in clicked = true; return .clicked(x: 0, y: 0) })
        let r = try await tool.execute(arguments: ["target": "unicorn"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["found"], "0")
        XCTAssertFalse(clicked, "must not click when the target isn't found")
    }

    func testTapFailsWhenCaptureUnavailable() async throws {
        let tool = PointClickTool(capture: { nil }, locate: { _, _ in [] }, click: { _, _, _, _ in .clicked(x: 0, y: 0) })
        let r = try await tool.execute(arguments: ["target": "x"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("capture the screen") ?? false)
    }

    func testTapSurfacesNotTrusted() async throws {
        let tool = PointClickTool(
            capture: { (Data([0]), 100, 100) },
            locate: { _, _ in [.init(x: 0.5, y: 0.5)] },
            click: { _, _, _, _ in .notTrusted })
        let r = try await tool.execute(arguments: ["target": "x"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("Accessibility") ?? false)
    }

    func testTapRejectsUnknownButton() async throws {
        let tool = PointClickTool(capture: { (Data([0]), 100, 100) }, locate: { _, _ in [] }, click: { _, _, _, _ in .clicked(x: 0, y: 0) })
        let r = try await tool.execute(arguments: ["target": "x", "button": "middle"], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("unknown button") ?? false)
    }

    func testTapRefusesOutOfRangeLocateResult() async throws {
        // A garbage normalized point (1.2, -0.1) must NOT be clamped-and-clicked; treat as not found.
        var clicked = false
        let tool = PointClickTool(
            capture: { (Data([0]), 800, 600) },
            locate: { _, _ in [.init(x: 1.2, y: -0.1)] },
            click: { _, _, _, _ in clicked = true; return .clicked(x: 0, y: 0) })
        let r = try await tool.execute(arguments: ["target": "x"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["found"], "0")
        XCTAssertFalse(clicked, "must not click a clamped/out-of-range point")
    }

    func testTapPrefersFirstInRangePoint() async throws {
        var clickedAt: (Int, Int)? = nil
        let tool = PointClickTool(
            capture: { (Data([0]), 1000, 1000) },
            locate: { _, _ in [.init(x: 5.0, y: 5.0), .init(x: 0.25, y: 0.75)] },   // first is garbage
            click: { x, y, _, _ in clickedAt = (x, y); return .clicked(x: x, y: y) })
        let r = try await tool.execute(arguments: ["target": "x"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(clickedAt?.0, 250)
        XCTAssertEqual(clickedAt?.1, 750)
    }

    func testTapRejectsNonStringButton() async throws {
        let tool = PointClickTool(capture: { (Data([0]), 100, 100) }, locate: { _, _ in [] }, click: { _, _, _, _ in .clicked(x: 0, y: 0) })
        let r = try await tool.execute(arguments: ["target": "x", "button": true], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("button must be a string") ?? false)
    }

    func testTapPassesRightAndDoubleThrough() async throws {
        var seen: (Bool, Int)? = nil
        let tool = PointClickTool(
            capture: { (Data([0]), 200, 200) },
            locate: { _, _ in [.init(x: 0.5, y: 0.5)] },
            click: { _, _, right, clicks in seen = (right, clicks); return .clicked(x: 100, y: 100) })
        _ = try await tool.execute(arguments: ["target": "x", "button": "right", "double": true], context: ctx())
        XCTAssertEqual(seen?.0, true)
        XCTAssertEqual(seen?.1, 2)
    }
}
