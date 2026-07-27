import XCTest
@testable import AgentCore

final class GeminiLiveClientTests: XCTestCase {

    func testSetupMessageShape() {
        let m = GeminiLiveClient.setupMessage(model: "gemini-2.0-flash-live-001")
        let setup = m["setup"] as? [String: Any]
        XCTAssertEqual(setup?["model"] as? String, "models/gemini-2.0-flash-live-001")
        let modalities = (setup?["generationConfig"] as? [String: Any])?["responseModalities"] as? [String]
        XCTAssertEqual(modalities, ["TEXT"])
    }

    func testTextTurnMessageShape() {
        let m = GeminiLiveClient.textTurnMessage("hello")
        let cc = m["clientContent"] as? [String: Any]
        XCTAssertEqual(cc?["turnComplete"] as? Bool, true)
        let turns = cc?["turns"] as? [[String: Any]]
        XCTAssertEqual(turns?.first?["role"] as? String, "user")
        let parts = turns?.first?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.first?["text"] as? String, "hello")
    }

    func testSetupCompleteDetection() {
        XCTAssertTrue(GeminiLiveClient.isSetupComplete(["setupComplete": [:]]))
        XCTAssertFalse(GeminiLiveClient.isSetupComplete(["serverContent": [:]]))
    }

    func testParseServerContentTextAndTurnComplete() {
        let frame: [String: Any] = ["serverContent": [
            "modelTurn": ["parts": [["text": "hi "], ["text": "there"]]],
            "turnComplete": true,
        ]]
        let chunk = GeminiLiveClient.parseServerContent(frame)
        XCTAssertEqual(chunk?.text, "hi there")
        XCTAssertEqual(chunk?.turnComplete, true)
        // partial chunk (no turnComplete)
        let partial = GeminiLiveClient.parseServerContent(["serverContent": ["modelTurn": ["parts": [["text": "x"]]]]])
        XCTAssertEqual(partial?.text, "x")
        XCTAssertEqual(partial?.turnComplete, false)
        // non-serverContent → nil
        XCTAssertNil(GeminiLiveClient.parseServerContent(["setupComplete": [:]]))
    }

    func testLiveAskToolReturnsAnswerAndRejectsEmpty() async throws {
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory())
        let tool = LiveAskTool { text in
            XCTAssertEqual(text, "what time is it")
            return "It is noon."
        }
        let ok = try await tool.execute(arguments: ["text": "what time is it"], context: ctx)
        XCTAssertTrue(ok.success)
        XCTAssertEqual(ok.output, "It is noon.")

        let blankIn = try await tool.execute(arguments: ["text": "   "], context: ctx)
        XCTAssertFalse(blankIn.success)

        let blankOut = LiveAskTool { _ in "   " }
        let r = try await blankOut.execute(arguments: ["text": "x"], context: ctx)
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("no answer"))
    }
}
