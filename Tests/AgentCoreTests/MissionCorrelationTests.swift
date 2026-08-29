import Foundation
import XCTest
@testable import AgentCore

final class MissionCorrelationTests: XCTestCase {
    private struct ReceiptTool: AgentTool {
        let name = "receipt"
        let description = "test receipt"
        let parameters: [ToolParameter] = []

        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            ToolResult(success: true, output: "sensitive-result-payload",
                       metadata: ["remote-receipt": "sensitive-metadata-value"])
        }
    }

    func testToolSpanAndAuditShareMissionWithoutRawPayloads() async throws {
        let root = NSTemporaryDirectory() + "mission-correlation-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let mission = try XCTUnwrap(PlanExecuteMissionID(
            rawValue: String(repeating: "e", count: 64)))
        let recorder = TraceRecorder(traceId: mission.rawValue)
        let audit = AuditLog(path: root + "/audit/tools.jsonl")
        let context = ToolContext(projectRoot: root, auditLog: audit)
            .withPlanExecuteMission(mission, traceRecorder: recorder)

        _ = await ToolRegistry([ReceiptTool()]).execute(
            name: "receipt", arguments: ["secret": "sensitive-model-argument"],
            context: context)

        let spans = await recorder.all()
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.kind, .toolCall)
        XCTAssertEqual(span.traceId, mission.rawValue)
        XCTAssertEqual(span.toolName, "receipt")
        XCTAssertNotNil(span.attributes?["arguments.digest"])
        XCTAssertNotNil(span.attributes?["result.digest"])
        XCTAssertNotNil(span.attributes?["result.metadata_digest"])
        let encodedSpan = String(decoding: try JSONEncoder().encode(span), as: UTF8.self)
        XCTAssertFalse(encodedSpan.contains("sensitive-model-argument"))
        XCTAssertFalse(encodedSpan.contains("sensitive-result-payload"))
        XCTAssertFalse(encodedSpan.contains("sensitive-metadata-value"))
        let auditEntries = await audit.entries()
        XCTAssertEqual(auditEntries.first?.correlationID, mission.rawValue)
    }

    func testNonMissionContextHasNoCorrelationOrToolTrace() async throws {
        let root = NSTemporaryDirectory() + "no-mission-correlation-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let context = ToolContext(projectRoot: root)
        XCTAssertNil(context.correlationID)
        XCTAssertNil(context.traceRecorder)
        _ = await ToolRegistry([ReceiptTool()]).execute(name: "receipt", arguments: [:], context: context)
    }
}
