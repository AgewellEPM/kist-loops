import XCTest
@testable import AgentCore

final class TranslateDocumentToolTests: XCTestCase {

    private final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (system: String, user: String, attachment: MediaAttachment?)?
        func record(_ s: String, _ u: String, _ a: MediaAttachment?) {
            lock.lock(); defer { lock.unlock() }; stored = (s, u, a)
        }
        func snapshot() -> (system: String, user: String, attachment: MediaAttachment?)? {
            lock.lock(); defer { lock.unlock() }; return stored
        }
    }

    private func tempRoot() throws -> String {
        let dir = NSTemporaryDirectory() + "translate_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testTranslatesTextFileInlineAndSavesMarkdown() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "# Hello\n- one\n- two".write(toFile: root + "/notes.md", atomically: true, encoding: .utf8)
        let capture = CaptureBox()
        let tool = TranslateDocumentTool { system, user, attachment in
            capture.record(system, user, attachment)
            return .init(text: "# Hola\n- uno\n- dos", truncated: false)
        }

        let result = try await tool.execute(arguments: ["path": "notes.md", "to": "Spanish"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.error ?? "")
        // Default output name: <stem>.<lang>.md
        let out = root + "/notes.spanish.md"
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
        XCTAssertEqual(try String(contentsOfFile: out, encoding: .utf8), "# Hola\n- uno\n- dos")
        XCTAssertTrue(result.output.contains("Spanish"))
        XCTAssertTrue(result.output.contains("structure preserved"))
        // Text files go INLINE (no media attachment); the doc body rides in the user prompt.
        let seen = try XCTUnwrap(capture.snapshot())
        XCTAssertNil(seen.attachment)
        XCTAssertTrue(seen.user.contains("# Hello"))
        XCTAssertTrue(seen.user.contains("into Spanish"))
    }

    func testTranslatesPDFAsAttachmentAndHonorsCustomOutputAndHTML() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("%PDF-1.7 stub".utf8).write(to: URL(fileURLWithPath: root + "/report.pdf"))
        let capture = CaptureBox()
        let tool = TranslateDocumentTool { system, user, attachment in
            capture.record(system, user, attachment)
            return .init(text: "<h1>Rapport</h1>", truncated: false)
        }

        let result = try await tool.execute(
            arguments: ["path": "report.pdf", "to": "French", "format": "html", "output": "out/report.fr.html"],
            context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/out/report.fr.html"))
        // PDF rides as a media attachment, not inline text.
        let seen = try XCTUnwrap(capture.snapshot())
        XCTAssertEqual(seen.attachment?.kind, .pdf)
        XCTAssertEqual(seen.attachment?.mimeType, "application/pdf")
        XCTAssertTrue(seen.user.contains("attached document"))
        XCTAssertTrue(seen.user.contains("clean HTML"))
    }

    func testRefusesUnsupportedTypeAndOversizeWithoutFilesAPI() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([1, 2, 3, 4, 5]).write(to: URL(fileURLWithPath: root + "/big.pdf"))
        try Data([0]).write(to: URL(fileURLWithPath: root + "/clip.mp4"))
        // No filesClient (test init) → a PDF over the inline cap is refused, not silently dropped.
        let tool = TranslateDocumentTool(inlineCap: 3) { _, _, _ in .init(text: "should not run", truncated: false) }

        let oversize = try await tool.execute(arguments: ["path": "big.pdf", "to": "German"],
                                              context: ToolContext(projectRoot: root))
        XCTAssertFalse(oversize.success)
        XCTAssertTrue((oversize.error ?? "").contains("Files API"))

        let badType = try await tool.execute(arguments: ["path": "clip.mp4", "to": "German"],
                                             context: ToolContext(projectRoot: root))
        XCTAssertFalse(badType.success)
        XCTAssertTrue((badType.error ?? "").contains("not supported"))
    }

    func testEmptyTranslationIsAnError() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "x".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        let tool = TranslateDocumentTool { _, _, _ in .init(text: "   \n  ", truncated: false) }
        let result = try await tool.execute(arguments: ["path": "a.txt", "to": "Italian"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("empty"))
    }

    func testTruncatedTranslationFailsAndWritesNothing() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "# Long doc".write(toFile: root + "/long.md", atomically: true, encoding: .utf8)
        // Model hit its output cap → incomplete. Must NOT ship a partial file.
        let tool = TranslateDocumentTool { _, _, _ in .init(text: "# Documento (cut of", truncated: true) }
        let result = try await tool.execute(arguments: ["path": "long.md", "to": "Spanish"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("INCOMPLETE"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/long.spanish.md"),
                       "no partial file written on truncation")
    }

    func testOutputPathEscapingProjectRootIsRefused() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let outside = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: outside) }
        try "hi".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        let tool = TranslateDocumentTool { _, _, _ in .init(text: "translated", truncated: false) }
        do {
            _ = try await tool.execute(arguments: ["path": "a.txt", "to": "French", "output": "../escape.md"],
                                       context: ToolContext(projectRoot: root))
            XCTFail("output path escaping the project root must be refused")
        } catch {
            // confined writer rejects the escape; nothing is written outside the root.
            XCTAssertFalse(FileManager.default.fileExists(atPath: (outside as NSString).deletingLastPathComponent + "/escape.md"))
        }
    }

    func testIsTruncatedReasons() {
        XCTAssertTrue(TranslateDocumentTool.isTruncated("MAX_TOKENS"))
        XCTAssertTrue(TranslateDocumentTool.isTruncated("length"))
        XCTAssertFalse(TranslateDocumentTool.isTruncated("STOP"))
        XCTAssertFalse(TranslateDocumentTool.isTruncated(nil))
    }

    func testFidelityFileUsesCloudTranslationAndKeepsExtension() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data("%PDF-1.7 original".utf8).write(to: URL(fileURLWithPath: root + "/report.pdf"))
        let tool = TranslateDocumentTool(
            translateFile: { data, mime, lang in
                XCTAssertEqual(mime, "application/pdf")
                XCTAssertEqual(lang, "es")                      // "Spanish" → es
                return .init(bytes: Data("%PDF translated".utf8), mimeType: mime)
            },
            translate: { _, _, _ in .init(text: "should not run", truncated: false) })
        let result = try await tool.execute(arguments: ["path": "report.pdf", "to": "Spanish", "fidelity": "file"],
                                            context: ToolContext(projectRoot: root))
        XCTAssertTrue(result.success, result.error ?? "")
        // Re-rendered file keeps the original extension (.pdf), not .md.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/report.spanish.pdf"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: root + "/report.spanish.pdf")), Data("%PDF translated".utf8))
        XCTAssertTrue(result.output.contains("layout preserved"))
    }

    func testFidelityFileRejectsUnsupportedTypeAndMissingClient() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "plain".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try Data("%PDF".utf8).write(to: URL(fileURLWithPath: root + "/b.pdf"))
        // Unsupported type for file fidelity (txt) → refused.
        let t1 = TranslateDocumentTool(translateFile: { _, _, _ in .init(bytes: Data([1]), mimeType: "x") },
                                       translate: { _, _, _ in .init(text: "x", truncated: false) })
        let bad = try await t1.execute(arguments: ["path": "a.txt", "to": "French", "fidelity": "file"],
                                       context: ToolContext(projectRoot: root))
        XCTAssertFalse(bad.success)
        XCTAssertTrue((bad.error ?? "").contains("pdf/docx"))
        // No cloud client available → honest failure, not a silent fall-through to the Gemini path.
        let t2 = TranslateDocumentTool(translate: { _, _, _ in .init(text: "x", truncated: false) })   // translateFile nil
        let unavail = try await t2.execute(arguments: ["path": "b.pdf", "to": "French", "fidelity": "file"],
                                           context: ToolContext(projectRoot: root))
        XCTAssertFalse(unavail.success)
        XCTAssertTrue((unavail.error ?? "").contains("not available"))
    }

    func testCloudTranslationParseAndLangCode() throws {
        let out = Data("translated.pdf".utf8)
        let body = #"{"documentTranslation":{"byteStreamOutputs":["\#(out.base64EncodedString())"],"mimeType":"application/pdf"}}"#.data(using: .utf8)!
        let parsed = try CloudTranslationClient.parse(body, fallbackMime: "x")
        XCTAssertEqual(parsed.bytes, out)
        XCTAssertEqual(parsed.mimeType, "application/pdf")
        XCTAssertThrowsError(try CloudTranslationClient.parse(#"{"documentTranslation":{"byteStreamOutputs":[]}}"#.data(using: .utf8)!, fallbackMime: "x"))
        XCTAssertEqual(TranslateDocumentTool.langCode("Japanese"), "ja")
        XCTAssertEqual(TranslateDocumentTool.langCode("es"), "es")        // pass-through code
        XCTAssertEqual(CloudTranslationClient.mimeType(forExtension: "docx"),
                       "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        XCTAssertNil(CloudTranslationClient.mimeType(forExtension: "txt"))
    }

    func testLangSlugAndPromptShape() {
        XCTAssertEqual(TranslateDocumentTool.langSlug("Brazilian Portuguese"), "brazilian-portuguese")
        XCTAssertEqual(TranslateDocumentTool.langSlug("es"), "es")
        let p = TranslateDocumentTool.prompt(to: "Japanese", asHTML: false, inlineText: "BODY", hasAttachment: false)
        XCTAssertTrue(p.contains("into Japanese"))
        XCTAssertTrue(p.contains("clean Markdown"))
        XCTAssertTrue(p.contains("BODY"))
        XCTAssertTrue(p.contains("Preserve the original structure"))
    }
}
