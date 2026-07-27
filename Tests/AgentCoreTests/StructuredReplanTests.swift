import XCTest
@testable import AgentCore

/// The escalated re-plan steer: when the soft "revise your approach" nudge didn't work, force explicit
/// diagnose → alternatives → pick. Pure text builders, pinned here.
final class StructuredReplanTests: XCTestCase {

    func testStructuredSteerForcesDiagnoseAlternativesChoose() {
        let s = HeadlessAgentLoop.structuredReplanSteering(recentFailure: "fatal: not a git repository",
                                                           validTools: ["read_file", "run_command"])
        XCTAssertTrue(s.contains("DIAGNOSE"))
        XCTAssertTrue(s.contains("ALTERNATIVES"))
        XCTAssertTrue(s.contains("CHOOSE"))
        XCTAssertTrue(s.contains("not a git repository"), "grounds the diagnosis in the real error")
        XCTAssertTrue(s.contains("read_file"))
        XCTAssertTrue(s.contains("single JSON object"), "text protocol ending")
    }

    func testNativeVariantEndsWithToolCall() {
        let s = HeadlessAgentLoop.nativeStructuredReplanSteering(recentFailure: "boom")
        XCTAssertTrue(s.contains("DIAGNOSE"))
        XCTAssertTrue(s.contains("call the tool"), "native protocol ending")
        XCTAssertFalse(s.contains("single JSON object"))
    }

    func testStructuredDiffersFromSoftNudge() {
        let soft = HeadlessAgentLoop.replanSteering(recentFailure: "boom")
        let hard = HeadlessAgentLoop.structuredReplanSteering(recentFailure: "boom")
        XCTAssertNotEqual(soft, hard)
        XCTAssertFalse(soft.contains("DIAGNOSE"), "the soft nudge is NOT the structured one")
    }
}
