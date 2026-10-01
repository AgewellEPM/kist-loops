import XCTest
import Foundation
@testable import AgentCore

/// Pins the failure-observation fix (dogfood find 2026-08-06): when a tool FAILS, the model's
/// observation must contain the tool's actual output (compiler/test diagnostics), not just the
/// error verdict. The COBOL round: `cobc` failed with full diagnostics captured in `output`,
/// but the loop fed the model only "exit code 1" — it patched blind, tried a denied `2>&1`,
/// and reported it "cannot access stderr".
final class FailureObservationTests: XCTestCase {

    // MARK: helper unit pins

    func testFailureKeepsBothVerdictAndOutput() {
        let r = ToolResult(success: false,
                           output: "payroll.cbl:12: error: PIC clause invalid",
                           error: "exit code 1")
        let raw = HeadlessAgentLoop.failureAwareRaw(r)
        XCTAssertTrue(raw.contains("exit code 1"), raw)
        XCTAssertTrue(raw.contains("PIC clause invalid"), "the tool's diagnostics must reach the model")
    }

    func testSuccessKeepsOutputOnly() {
        let r = ToolResult(success: true, output: "ok", error: nil)
        XCTAssertEqual(HeadlessAgentLoop.failureAwareRaw(r), "ok")
    }

    func testFailureWithEmptyOutputIsJustTheError() {
        let r = ToolResult(success: false, output: "", error: "command timed out after 120s")
        XCTAssertEqual(HeadlessAgentLoop.failureAwareRaw(r), "command timed out after 120s")
    }

    func testFailureWithNoErrorKeepsOutput() {
        let r = ToolResult(success: false, output: "hunk did not match", error: nil)
        XCTAssertEqual(HeadlessAgentLoop.failureAwareRaw(r), "hunk did not match")
    }

    func testIdenticalErrorAndOutputNotDuplicated() {
        let r = ToolResult(success: false, output: "boom", error: "boom")
        XCTAssertEqual(HeadlessAgentLoop.failureAwareRaw(r), "boom")
    }

    // MARK: per-site source pins (multi-site discipline: text loop, native loop, replay)

    func testEverySiteRoutesThroughFailureAwareRaw() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let surfaces: [(label: String, file: String, minRawSites: Int)] = [
            ("native", "Sources/AgentCore/HeadlessAgentLoop.swift", 1),
            ("text", "Sources/AgentCore/HeadlessAgentLoop+TextDrive.swift", 1),
            ("replay", "Sources/AgentCore/HeadlessAgentLoop+VerificationReplay.swift", 1),
        ]
        for s in surfaces {
            let src = try String(contentsOf: repo.appendingPathComponent(s.file), encoding: .utf8)
            let uses = src.components(separatedBy: "failureAwareRaw(result)").count - 1
            XCTAssertGreaterThanOrEqual(uses, s.minRawSites,
                "\(s.label) (\(s.file)) must build observations via failureAwareRaw at every site")
            XCTAssertFalse(src.contains("result.success ? result.output : (result.error ?? result.output)"),
                "\(s.label) (\(s.file)) reintroduced the error-only observation that blinded the model")
        }
    }
}
