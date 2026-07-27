import XCTest
import AgentCore
@testable import Kist

final class DocumentExportTests: XCTestCase {
    func testParsesPriorAnswerPDFRequest() {
        XCTAssertEqual(DocumentExport.parseIntent("hreay cna i have this as a pdf")?.format, .pdf)
        XCTAssertEqual(DocumentExport.parseIntent("turn this into a document")?.format, .rtf)
    }

    func testDoesNotStealSelfHealPDFDebugRequest() {
        XCTAssertNil(DocumentExport.parseIntent("fix the code malformed issue you just encountered i asked for a pdf"))
    }

    func testLatestAssistantTextUsesMostRecentAssistantAnswer() {
        let transcript = [
            ChatMessage(role: .assistant, content: "old"),
            ChatMessage(role: .user, content: "again"),
            ChatMessage(role: .assistant, content: "new")
        ]

        XCTAssertEqual(DocumentExport.latestAssistantText(from: transcript), "new")
    }

    func testWritesRTFDocumentFromLatestAssistantAnswer() throws {
        let root = NSTemporaryDirectory() + "doc_export_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let transcript = [ChatMessage(role: .assistant, content: "HARDSHIP LETTER\n\nBody")]

        let message = try XCTUnwrap(DocumentExport.writeLatestAssistantDocument(
            input: "turn this into a document",
            transcript: transcript,
            projectRoot: root,
            now: Date(timeIntervalSince1970: 1_783_056_000)))

        XCTAssertTrue(message.contains("exported RTF"))
        XCTAssertTrue(message.contains(".rtf"))
        let path = message.components(separatedBy: " · ").last ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(try String(contentsOfFile: path).hasPrefix("{\\rtf1"))
    }

    func testWritesPDFDocumentFromLatestAssistantAnswer() throws {
        let root = NSTemporaryDirectory() + "pdf_export_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let transcript = [ChatMessage(role: .assistant, content: "HARDSHIP LETTER\n\nBody")]

        let message = try XCTUnwrap(DocumentExport.writeLatestAssistantDocument(
            input: "can i have this as a pdf",
            transcript: transcript,
            projectRoot: root,
            now: Date(timeIntervalSince1970: 1_783_056_000)))

        XCTAssertTrue(message.contains("exported PDF"))
        let path = message.components(separatedBy: " · ").last ?? ""
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue(String(data: data.prefix(4), encoding: .utf8) == "%PDF")
    }

    func testREPLHandlesPDFExportBeforeNormalModelTurn() throws {
        let root = NSTemporaryDirectory() + "repl_pdf_export_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let transcript = [ChatMessage(role: .assistant, content: "HARDSHIP LETTER\n\nBody")]

        let result = KistREPL.handleDocumentExportRequest(
            "hrey cna i have this as a pdf",
            humanTranscript: transcript,
            projectRoot: root,
            now: Date(timeIntervalSince1970: 1_783_056_100))

        guard case .handled(let message) = result else {
            return XCTFail("expected local document export, got \(result)")
        }
        XCTAssertTrue(message.contains("exported PDF"))
        let path = message.components(separatedBy: " · ").last ?? ""
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue(String(data: data.prefix(4), encoding: .utf8) == "%PDF")
    }

    func testREPLDocumentExportDoesNotStealDebugRequest() {
        let result = KistREPL.handleDocumentExportRequest(
            "fix the code malformed issue you just encountered i asked for a pdf",
            humanTranscript: [ChatMessage(role: .assistant, content: "prior")],
            projectRoot: NSTemporaryDirectory())

        XCTAssertEqual(result, .notDocumentExport)
    }

    func testREPLDocumentExportReportsNoPriorAssistantText() {
        let result = KistREPL.handleDocumentExportRequest(
            "can i have this as a pdf",
            humanTranscript: [],
            projectRoot: NSTemporaryDirectory())

        guard case .handled(let message) = result else {
            return XCTFail("expected no-prior-answer message, got \(result)")
        }
        XCTAssertTrue(message.contains("No prior assistant answer to export yet"))
    }
}
