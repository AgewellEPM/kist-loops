import XCTest
import Foundation
@testable import AgentCore

/// A byte limit can cut through a numbered source line. That line must remain unread.
final class ReadObservationContinuationTests: XCTestCase {
    private let metadata = ["path": "sample.swift", "shown_lines": "7-9", "total_lines": "9"]

    // Existing observation contracts moved from HeadlessAgentLoopTests.
    func testToolObservationBodyIsByteBoundedAndReportsMetadataAndTruncation() {
        let body = HeadlessAgentLoop.toolObservationBody(
            raw: String(repeating: "é", count: 20),
            metadata: ["path": "large.swift", "shown_lines": "1-10", "total_lines": "100"],
            maxBytes: 15
        )

        XCTAssertTrue(body.contains("[TRUNCATED: tool output was"))
        XCTAssertTrue(body.contains("only the first 15 bytes are shown"))
        XCTAssertTrue(body.contains("read_file(path=\"large.swift\", start_line=1, end_line=100)"))
        XCTAssertTrue(body.contains("[metadata: path=large.swift"))
    }

    func testClippedReadFileObservationGivesExactContinuationRange() {
        let raw = (1...50)
            .map { String(format: "%4d│ line-%02d abcdefghijklmnopqrstuvwxyz", $0, $0) }
            .joined(separator: "\n")
        let body = HeadlessAgentLoop.toolObservationBody(
            raw: raw,
            metadata: ["path": "Sources/Big.swift", "shown_lines": "1-50", "total_lines": "50"],
            maxBytes: 420
        )

        XCTAssertTrue(body.contains("[TRUNCATED: tool output was"), body)
        XCTAssertTrue(body.contains("Continue with read_file(path=\"Sources/Big.swift\", start_line="), body)
        XCTAssertTrue(body.contains("end_line=50"), body)
        XCTAssertTrue(body.contains("before claiming full-file coverage"), body)
        XCTAssertTrue(body.contains("[metadata: path=Sources/Big.swift"), body)
    }

    func testToolOutputEnvelopeCarriesToolAndStatus() {
        let ok = HeadlessAgentLoop.toolOutputEnvelope(tool: "read_file", success: true, body: "x")
        XCTAssertTrue(ok.contains(#"<tool_output tool="read_file" status="ok">"#))
        let failed = HeadlessAgentLoop.toolOutputEnvelope(tool: "run_command", success: false, body: "denied")
        XCTAssertTrue(failed.contains(#"<tool_output tool="run_command" status="error">"#))
    }

    func testPartialNumberedLineContinuesAtThatLine() {
        let prefix = "7│ complete\n8│ partial"
        let body = HeadlessAgentLoop.toolObservationBody(
            raw: prefix + " remainder\n9│ final", metadata: metadata, maxBytes: prefix.utf8.count)
        XCTAssertTrue(body.contains("start_line=8, end_line=9"), body)
        XCTAssertFalse(body.contains("start_line=9"), body)
    }

    func testCompleteNumberedLineContinuesAtFollowingLine() {
        let prefix = "7│ complete\n"
        let body = HeadlessAgentLoop.toolObservationBody(
            raw: prefix + "8│ next\n9│ final", metadata: metadata, maxBytes: prefix.utf8.count)
        XCTAssertTrue(body.contains("start_line=8, end_line=9"), body)
    }

    func testClippedFirstLineMarkerUsesCurrentWindowStart() {
        let body = HeadlessAgentLoop.toolObservationBody(
            raw: "7│ first\n8│ next\n9│ final", metadata: metadata, maxBytes: 1)
        XCTAssertTrue(body.contains("start_line=7, end_line=9"), body)
    }

    func testSplitUTF8ScalarDoesNotSkipItsLine() {
        let prefix = "7│ complete\n8│ "
        let body = HeadlessAgentLoop.toolObservationBody(
            raw: prefix + "é remainder\n9│ final", metadata: metadata,
            maxBytes: prefix.utf8.count + 1)
        XCTAssertTrue(body.contains("start_line=8, end_line=9"), body)
    }

    func testPartiallyVisibleFinalLineIsNotTreatedAsEOF() {
        let prefix = "8│ complete\n9│ part"
        let body = HeadlessAgentLoop.toolObservationBody(
            raw: prefix + "ial final", metadata: metadata, maxBytes: prefix.utf8.count)
        XCTAssertTrue(body.contains("start_line=9, end_line=9"), body)
    }

    func testRealTextProtocolCarriesPartialLineContinuation() async throws {
        try await assertReadContinuation(native: false)
    }

    func testRealNativeProtocolCarriesPartialLineContinuation() async throws {
        try await assertReadContinuation(native: true)
    }

    private func assertReadContinuation(native: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = try XCTUnwrap(ToolContext.canonicalize(temporary.path))
        let source = String(repeating: "a", count: 5_000) + "\n"
            + String(repeating: "b", count: 5_000) + "\nlast\n"
        try source.write(toFile: root + "/sample.swift", atomically: true, encoding: .utf8)
        let provider = ReadOnceProvider()
        let checkpoints = LoopCheckpointStore(directory: root + "/checkpoints")
        let loop = HeadlessAgentLoop(
            providers: ProviderRegistry(providers: [provider], keyStore: EmptyKeys()),
            providerId: provider.id, model: nil, tools: .headless(),
            context: ToolContext(projectRoot: root), toolMode: native ? .native : .text,
            checkpoints: checkpoints, maxIterations: 4)
        let result = await loop.run(goal: "Read sample.swift once and report the available source window.")
        XCTAssertTrue(result.success, result.summary)
        let saved = try checkpoints.load(id: result.checkpointId)
        let observation = try XCTUnwrap(saved.messages.first {
            $0.content.hasPrefix("<tool_output tool=\"read_file\"")
        })
        XCTAssertTrue(observation.content.contains("[TRUNCATED:"), observation.content)
        XCTAssertTrue(observation.content.contains("start_line=2, end_line=4"),
                      "\(native ? "native" : "text") skipped the partially observed second line")
        XCTAssertFalse(observation.content.contains(String(repeating: "b", count: 5_000)))
    }
}

private struct EmptyKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

/// Only the tool transport differs; both routes execute the real confined ReadFileTool.
private struct ReadOnceProvider: ChatProvider {
    let id = "read-once", name = "Read Once", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "read-once", defaultModel = "test"
    let availableModels = [AIModel(id: "test")]
    var supportsNativeTools: Bool { true }

    private func hasObservation(_ messages: [ChatMessage]) -> Bool {
        messages.contains { $0.content.hasPrefix("<tool_output tool=\"read_file\"") }
    }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let response = hasObservation(messages)
            ? #"{"done":true,"summary":"Observed the first source window; remainder is incomplete."}"#
            : #"{"tool":"read_file","parameters":{"path":"sample.swift"}}"#
        return AsyncThrowingStream { $0.yield(.delta(response)); $0.finish() }
    }

    func streamTools(messages: [ChatMessage], model: String, settings: ModelSettings,
                     apiKey: String?, tools: [ToolSpec]) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let read = hasObservation(messages)
        return AsyncThrowingStream { stream in
            if read {
                stream.yield(.delta("Observed the first source window; remainder is incomplete."))
            } else {
                stream.yield(.toolCall(id: "source-read", name: "read_file",
                                       argumentsJSON: #"{"path":"sample.swift"}"#))
            }
            stream.finish()
        }
    }
}
