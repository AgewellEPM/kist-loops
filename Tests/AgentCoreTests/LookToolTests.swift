import XCTest
@testable import AgentCore

final class LookToolTests: XCTestCase {

    private func ctx() -> ToolContext { ToolContext(projectRoot: NSTemporaryDirectory()) }

    func testCaptionModeWhenNoQuestion() async throws {
        let tool = LookTool(capture: { (Data([0]), 8, 8) }, perceive: { _, q in
            XCTAssertNil(q)   // no question ⇒ caption mode
            return "a desert wasteland with a vault dweller"
        })
        let r = try await tool.execute(arguments: [:], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["mode"], "caption")
        XCTAssertTrue(r.output.contains("vault dweller"))
        XCTAssertTrue(r.output.hasPrefix("On screen:"))
    }

    func testQueryModeWhenQuestionGiven() async throws {
        let tool = LookTool(capture: { (Data([0]), 8, 8) }, perceive: { _, q in
            XCTAssertEqual(q, "is it my turn?")
            return "yes"
        })
        let r = try await tool.execute(arguments: ["question": "is it my turn?"], context: ctx())
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["mode"], "query")
        XCTAssertTrue(r.output.contains("Q: is it my turn?"))
        XCTAssertTrue(r.output.contains("A: yes"))
    }

    func testBlankQuestionTreatedAsCaption() async throws {
        let tool = LookTool(capture: { (Data([0]), 8, 8) }, perceive: { _, q in
            XCTAssertNil(q)   // whitespace question ⇒ nil ⇒ caption
            return "a menu"
        })
        let r = try await tool.execute(arguments: ["question": "   "], context: ctx())
        XCTAssertEqual(r.metadata["mode"], "caption")
    }

    func testFailsWhenCaptureUnavailable() async throws {
        let tool = LookTool(capture: { nil }, perceive: { _, _ in "unused" })
        let r = try await tool.execute(arguments: [:], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("capture the screen") ?? false)
    }

    func testFailsOnEmptyDescription() async throws {
        let tool = LookTool(capture: { (Data([0]), 8, 8) }, perceive: { _, _ in "   " })
        let r = try await tool.execute(arguments: [:], context: ctx())
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("empty") ?? false)
    }
}
