import XCTest
@testable import AgentCore

final class ComputerUsePreflightTests: XCTestCase {

    func testAllSetIsReady() {
        let r = ComputerUsePreflight.evaluate(accessibility: true, screenRecording: true, moondreamKey: "k", moondreamURL: nil)
        XCTAssertTrue(r.ready)
        let report = ComputerUsePreflight.report(r)
        XCTAssertTrue(report.contains("READY"))
        // The ready path also hands the model the loop playbook.
        XCTAssertTrue(report.contains("wait_for_screen"))
        XCTAssertTrue(report.contains("tap("))
    }

    func testNotReadyDoesNotIncludePlaybook() {
        let r = ComputerUsePreflight.evaluate(accessibility: false, screenRecording: true, moondreamKey: "k", moondreamURL: nil)
        // No point teaching the loop when it can't run yet — fix-list only.
        XCTAssertFalse(ComputerUsePreflight.report(r).contains("the loop:"))
    }

    func testLocalUrlCountsAsMoondream() {
        let r = ComputerUsePreflight.evaluate(accessibility: true, screenRecording: true, moondreamKey: nil, moondreamURL: "http://localhost:2020/v1")
        XCTAssertTrue(r.moondreamConfigured)
        XCTAssertTrue(r.ready)
    }

    func testEmptyKeyAndUrlIsNotConfigured() {
        let r = ComputerUsePreflight.evaluate(accessibility: true, screenRecording: true, moondreamKey: "", moondreamURL: "")
        XCTAssertFalse(r.moondreamConfigured)
        XCTAssertFalse(r.ready)
    }

    func testReportNamesEachMissingItemWithFix() {
        let r = ComputerUsePreflight.evaluate(accessibility: false, screenRecording: false, moondreamKey: nil, moondreamURL: nil)
        let report = ComputerUsePreflight.report(r)
        XCTAssertTrue(report.contains("Accessibility"))
        XCTAssertTrue(report.contains("Screen Recording"))
        XCTAssertTrue(report.contains("MOONDREAM_API_KEY"))
        XCTAssertTrue(report.contains("✗"))
        XCTAssertFalse(report.contains("READY"))
    }

    func testPartialReadinessNotReady() {
        // Perms granted but no vision backend → not ready.
        let r = ComputerUsePreflight.evaluate(accessibility: true, screenRecording: true, moondreamKey: nil, moondreamURL: nil)
        XCTAssertFalse(r.ready)
        XCTAssertTrue(ComputerUsePreflight.report(r).contains("✓ Accessibility"))
        XCTAssertTrue(ComputerUsePreflight.report(r).contains("✗ Moondream"))
    }

    func testCheckReadsInjectedEnvironment() {
        // check() with an env lacking Moondream → moondream false regardless of OS permission state.
        let r = ComputerUsePreflight.check(environment: [:])
        XCTAssertFalse(r.moondreamConfigured)
    }

    func testToolReportsReadinessAndMetadata() async throws {
        let notReady = ComputerUsePreflight.Readiness(accessibility: false, screenRecording: true, moondreamConfigured: false)
        let tool = ComputerUseCheckTool(probe: { notReady })
        let r = try await tool.execute(arguments: [:], context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["ready"], "false")
        XCTAssertEqual(r.metadata["accessibility"], "false")
        XCTAssertEqual(r.metadata["screen_recording"], "true")
        XCTAssertTrue(r.output.contains("NOT ready"))
    }
}
