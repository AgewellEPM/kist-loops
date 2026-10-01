import Foundation
import XCTest
@testable import AgentCore

final class ReadFilesToolTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("read-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func read(_ requests: [[String: Any]], context: ToolContext? = nil) async throws -> (ToolResult, [[String: Any]]) {
        let encoded = try JSONSerialization.data(withJSONObject: requests)
        let result = try await ReadFilesTool().execute(arguments: ["requests": String(decoding: encoded, as: UTF8.self)],
                                                     context: context ?? ToolContext(projectRoot: root.path))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        return (result, try XCTUnwrap(body["files"] as? [[String: Any]]))
    }

    func testIndependentFilesReturnExactDigestAndRangesWithoutChangingThem() async throws {
        let first = "one\ntwo\nthree"
        try first.write(to: root.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "other".write(to: root.appendingPathComponent("b.py"), atomically: true, encoding: .utf8)
        let (result, files) = try await read([["path": "a.swift", "start_line": 2, "end_line": 2], ["path": "b.py"]])
        XCTAssertTrue(result.success)
        XCTAssertEqual(files[0]["sourceSHA256"] as? String, BuilderEvidenceDigest.sha256(first))
        XCTAssertEqual(files[0]["numberedLines"] as? String, "2│ two\n")
        XCTAssertEqual(files[0]["nextStartLine"] as? Int, 3)
        XCTAssertEqual(files[0]["wholeFileIncluded"] as? Bool, false)
        XCTAssertEqual(files[0]["requestedWindowComplete"] as? Bool, true)
        XCTAssertEqual(files[1]["wholeFileIncluded"] as? Bool, true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.swift"), encoding: .utf8), first)
    }

    func testOutputRemainsValidJSONWithExplicitUnicodeContinuation() async throws {
        let text = (1...400).map { "\($0) " + String(repeating: "🙂", count: 40) }.joined(separator: "\n")
        try text.write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let (result, files) = try await read([["path": "large.txt"]])
        XCTAssertLessThanOrEqual(result.output.utf8.count, ReadFilesTool.maximumBytes)
        XCTAssertEqual(files[0]["requestedWindowComplete"] as? Bool, false)
        let end = try XCTUnwrap(files[0]["endLine"] as? Int)
        XCTAssertEqual(files[0]["nextStartLine"] as? Int, end + 1)
        XCTAssertFalse((files[0]["numberedLines"] as? String ?? "").contains("�"))
        let (_, continuation) = try await read([["path": "large.txt", "start_line": end + 1, "end_line": end + 1]])
        XCTAssertTrue((continuation[0]["numberedLines"] as? String ?? "").hasPrefix("\(end + 1)│"))
    }

    func testMissingFileAndSymlinkAreReportedWithoutHidingSuccessfulPeer() async throws {
        try "visible".write(to: root.appendingPathComponent("safe.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"),
                                                  withDestinationURL: root.appendingPathComponent("safe.txt"))
        let (result, files) = try await read([["path": "missing"], ["path": "alias"], ["path": "../escape"], ["path": "safe.txt"]])
        XCTAssertFalse(result.success)
        XCTAssertTrue(files.prefix(3).allSatisfy { $0["error"] != nil && $0["sourceSHA256"] == nil })
        XCTAssertEqual(files[3]["numberedLines"] as? String, "1│ visible\n")
    }

    func testSkillRequiresCompleteDedicatedRead() async throws {
        let (result, files) = try await read([["path": "kist:code-investigation"]])
        XCTAssertFalse(result.success)
        XCTAssertTrue((files[0]["error"] as? String ?? "").contains("load a skill completely"))
        XCTAssertNil(files[0]["sourceSHA256"])
    }

    func testEditChangesDigestAndInvalidatesOldSnapshot() async throws {
        let path = root.appendingPathComponent("source.txt")
        try "before".write(to: path, atomically: true, encoding: .utf8)
        let (_, before) = try await read([["path": "source.txt"]])
        try "after".write(to: path, atomically: true, encoding: .utf8)
        let (_, after) = try await read([["path": "source.txt"]])
        XCTAssertNotEqual(before[0]["sourceSHA256"] as? String, after[0]["sourceSHA256"] as? String)
    }

    func testRegistryAndPlanScopeExposeOnlyReadCapability() async throws {
        XCTAssertTrue(HeadlessAgentLoop.readOnlyTools.contains("read_files"))
        XCTAssertTrue(SkillTracker.alwaysSafe.contains("read_files"))
        XCTAssertTrue(ToolRegistry.headless().names.contains("read_files"))
        let invalid = ["requests": "[{\"path\":\"a\",\"start_line\":9223372036854775807}]"]
        do {
            _ = try await ReadFilesTool().execute(arguments: invalid, context: ToolContext(projectRoot: root.path))
            XCTFail("overflowing ranges must be rejected before reading")
        } catch ToolError.invalidParameter { } catch { XCTFail("unexpected error: \(error)") }
    }

    func testStructuredPlannerArrayUsesSameReadAndConfinementChecks() async throws {
        try "visible".write(to: root.appendingPathComponent("safe.txt"), atomically: true, encoding: .utf8)
        let result = try await ReadFilesTool().execute(arguments: ["requests": [
            ["path": "safe.txt"], ["path": "../escape"]
        ]], context: ToolContext(projectRoot: root.path))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any])
        let files = try XCTUnwrap(json["files"] as? [[String: Any]])
        XCTAssertEqual(files[0]["numberedLines"] as? String, "1│ visible\n")
        XCTAssertNotNil(files[1]["error"])
        XCTAssertNil(files[1]["sourceSHA256"])
        XCTAssertFalse(result.success)
        do {
            _ = try await ReadFilesTool().execute(arguments: ["requests": Array(repeating: ["path": "safe.txt"], count: 9)],
                context: ToolContext(projectRoot: root.path))
            XCTFail("The direct array must retain the eight-window bound")
        } catch ToolError.invalidParameter { }
    }
}
