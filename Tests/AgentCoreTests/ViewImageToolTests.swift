import XCTest
@testable import AgentCore

final class ViewImageToolTests: XCTestCase {
    private final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (MediaAttachment, String)?

        func record(_ attachment: MediaAttachment, _ question: String) {
            lock.lock(); defer { lock.unlock() }
            stored = (attachment, question)
        }

        func snapshot() -> (MediaAttachment, String)? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private func tempRoot() throws -> String {
        let dir = NSTemporaryDirectory() + "viewimg_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testInspectsImageThroughInjectedAnalyzer() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: root + "/shot.png"))
        let capture = CaptureBox()
        let tool = ViewImageTool { attachment, question in
            capture.record(attachment, question)
            return "visible text: Hello\nlayout: login form"
        }

        let result = try await tool.execute(arguments: ["path": "shot.png", "question": "what errors are visible?"],
                                            context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.output.contains("Visual inspection · shot.png"))
        XCTAssertTrue(result.output.contains("visible text: Hello"))
        let seen = try XCTUnwrap(capture.snapshot())
        XCTAssertEqual(seen.0.kind, .image)
        XCTAssertEqual(seen.0.mimeType, "image/png")
        XCTAssertEqual(seen.0.inlineData, Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(seen.1, "what errors are visible?")
    }

    func testAcceptsPDFAsVisualDocument() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("%PDF-1.7".utf8).write(to: URL(fileURLWithPath: root + "/report.pdf"))
        let tool = ViewImageTool { attachment, _ in
            XCTAssertEqual(attachment.kind, .pdf)
            XCTAssertEqual(attachment.mimeType, "application/pdf")
            return "pdf visible"
        }

        let result = try await tool.execute(arguments: ["path": "report.pdf"], context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.output.contains("pdf visible"))
    }

    func testRejectsNonVisualFilesAndOversizedInlineFiles() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "hello".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        try Data([1, 2, 3, 4]).write(to: URL(fileURLWithPath: root + "/big.png"))
        let tool = ViewImageTool(inlineCap: 3) { _, _ in "should not run" }

        let text = try await tool.execute(arguments: ["path": "notes.txt"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(text.success)
        XCTAssertTrue((text.error ?? "").contains("images/PDFs"))

        let big = try await tool.execute(arguments: ["path": "big.png"], context: ToolContext(projectRoot: root))
        XCTAssertFalse(big.success)
        XCTAssertTrue((big.error ?? "").contains("over 3 bytes"))
    }

    func testRejectsPathTraversalOutsideProject() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: outside) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outside + "/secret.png"))
        let tool = ViewImageTool { _, _ in "should not run" }

        do {
            _ = try await tool.execute(arguments: ["path": "../\((outside as NSString).lastPathComponent)/secret.png"],
                                       context: ToolContext(projectRoot: root))
            XCTFail("path traversal should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("escapes the project root"), "\(error)")
        }

        do {
            _ = try await tool.execute(arguments: ["path": outside + "/secret.png"],
                                       context: ToolContext(projectRoot: root))
            XCTFail("absolute escape should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("escapes the project root"), "\(error)")
        }
    }

    func testRejectsSymlinkEscapeOutsideProject() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: outside) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: outside + "/secret.png"))
        try FileManager.default.createSymbolicLink(atPath: root + "/link.png",
                                                   withDestinationPath: outside + "/secret.png")
        let tool = ViewImageTool { _, _ in "should not run" }

        do {
            _ = try await tool.execute(arguments: ["path": "link.png"], context: ToolContext(projectRoot: root))
            XCTFail("symlink escape should throw")
        } catch {
            XCTAssertTrue("\(error)".contains("escapes the project root"), "\(error)")
        }
    }

    func testPromptIncludesFocusQuestionAndVisualContract() {
        let prompt = ViewImageTool.prompt(question: "compare these buttons", sourcePath: "/tmp/shot.png")
        XCTAssertTrue(prompt.contains("visible text/OCR"))
        XCTAssertTrue(prompt.contains("UI/layout"))
        XCTAssertTrue(prompt.contains("Focus question: compare these buttons"))
    }
}
