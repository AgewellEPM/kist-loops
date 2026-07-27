import XCTest
@testable import AgentCore

final class CountTokensToolTests: XCTestCase {

    private func tempRoot() throws -> String {
        let raw = NSTemporaryDirectory() + "tok_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
        return ToolContext.canonicalize(raw)!
    }

    func testParseTotalTokens() throws {
        XCTAssertEqual(try GeminiTokenCounter.parse(#"{"totalTokens":123}"#.data(using: .utf8)!), 123)
        XCTAssertThrowsError(try GeminiTokenCounter.parse(#"{}"#.data(using: .utf8)!))
    }

    func testCountsText() async throws {
        let tool = CountTokensTool { text in XCTAssertEqual(text, "hello world"); return 2 }
        let r = try await tool.execute(arguments: ["text": "hello world"], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "2 tokens")
        XCTAssertEqual(r.metadata["tokens"], "2")
    }

    func testCountsFileAndRejectsEmpty() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "some file text".write(toFile: root + "/doc.txt", atomically: true, encoding: .utf8)
        let tool = CountTokensTool { text in text.contains("file text") ? 4 : 0 }
        let fromFile = try await tool.execute(arguments: ["path": "doc.txt"], context: ToolContext(projectRoot: root))
        XCTAssertTrue(fromFile.success)
        XCTAssertEqual(fromFile.output, "4 tokens")

        let empty = try await tool.execute(arguments: [:], context: ToolContext(projectRoot: root))
        XCTAssertFalse(empty.success)
    }
}
