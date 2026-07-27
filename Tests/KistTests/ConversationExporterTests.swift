import XCTest
import AgentCore
@testable import Kist

final class ConversationExporterTests: XCTestCase {

    private var root: String!

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "kist-export-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    func testMarkdownIncludesConversationAndToolCalls() {
        let transcript = [
            ChatMessage(role: .user, content: "Build a spec file."),
            ChatMessage(role: .assistant, content: "I'll write it.",
                        toolCalls: [ToolCallRef(id: "call_1", name: "write_file", argumentsJSON: #"{"path":"SPEC.md"}"#)]),
            ChatMessage.toolResult(callId: "call_1", content: "Wrote SPEC.md"),
        ]

        let markdown = ConversationExporter.markdown(
            transcript: transcript,
            exportedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(markdown.contains("# Kist Conversation"))
        XCTAssertTrue(markdown.contains("## 1. User"))
        XCTAssertTrue(markdown.contains("Build a spec file."))
        XCTAssertTrue(markdown.contains("`write_file` id `call_1`"))
        XCTAssertTrue(markdown.contains("Tool call id: `call_1`"))
        XCTAssertTrue(markdown.contains("Wrote SPEC.md"))
    }

    func testWriteMarkdownStaysConfinedToProjectRoot() throws {
        let transcript = [ChatMessage(role: .user, content: "save this")]
        let written = try ConversationExporter.writeMarkdown(
            transcript: transcript,
            path: "notes/chat.md",
            projectRoot: root,
            exportedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(written, root + "/notes/chat.md")
        let content = try String(contentsOfFile: written, encoding: .utf8)
        XCTAssertTrue(content.contains("save this"))
    }

    func testWriteMarkdownRejectsEscapes() {
        XCTAssertThrowsError(try ConversationExporter.writeMarkdown(
            transcript: [],
            path: "../outside.md",
            projectRoot: root,
            exportedAt: Date(timeIntervalSince1970: 0)
        )) { error in
            guard case ToolError.pathEscape = error else { return XCTFail("expected pathEscape, got \(error)") }
        }
    }
}
