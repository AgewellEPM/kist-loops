import XCTest
@testable import AgentCore

/// Self-evolution phase 1. These pin the classifier against the REAL failures Luke screenshotted, because
/// the whole point is to route THOSE correctly instead of giving up. Each category is exercised with the
/// exact tool-error text the model actually saw.
final class FailureClassifierTests: XCTestCase {

    private func classify(_ failures: [ToolFailure], edited: Bool = false, built: Bool = false)
        -> FailureClassifier.Verdict {
        FailureClassifier.classify(FailureSignals(toolFailures: failures, editedSource: edited, ranBuildOrTest: built))
    }

    // MARK: - The perslis win98 round (Luke 2026-08-06)

    func testUnknownCommandWithNoHintIsToolLimit() {
        // First round: bare refusal, no guidance → the tool genuinely can't run an arbitrary file.
        let v = classify([ToolFailure(tool: "perslis__win98_run_command",
                                      error: "unknown Windows 98 run command: C:\\HELLO.VBS")])
        XCTAssertEqual(v.category, .toolLimit)
        XCTAssertEqual(v.culpritTool, "perslis__win98_run_command")
    }

    func testRepeatedUnknownCommandsRaiseToolLimitConfidence() {
        // The model tried C:\HELLO.VBS, wscript.exe …, C:\RUNHELLO.BAT, RUNHELLO.BAT — every one refused.
        let v = classify([
            ToolFailure(tool: "perslis__win98_run_command", error: "unknown Windows 98 run command: C:\\HELLO.VBS"),
            ToolFailure(tool: "perslis__win98_run_command", error: "unknown Windows 98 run command: wscript.exe C:\\HELLO.VBS"),
            ToolFailure(tool: "perslis__win98_run_command", error: "unknown Windows 98 run command: RUNHELLO.BAT"),
        ])
        XCTAssertEqual(v.category, .toolLimit)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.85)
        XCTAssertTrue(v.evidence.contains("refused attempts"))
    }

    func testUnknownCommandWITHHintIsKnowledgeGap() {
        // Later round: the tool now teaches recovery → discover its real vocabulary and retry, don't give up.
        let v = classify([ToolFailure(tool: "perslis__win98_run_command",
            error: "unknown Windows 98 run command: C:\\HELLO.VBS, hint: this tool launches only cataloged Run-prompt commands (search: win98_run_commands)")])
        XCTAssertEqual(v.category, .knowledgeGap)
        XCTAssertNotNil(v.discoveryHint)
        XCTAssertTrue(v.discoveryHint!.lowercased().contains("search"))
    }

    func testVmKeyUnknownKeyIsKnowledgeGapWithHint() {
        // "unknown key 'exit' — not a QEMU qcode. Use e.g. ret, esc, tab…" — the tool says the right form.
        let v = classify([ToolFailure(tool: "perslis__vm_key",
            error: "unknown key 'exit' — not a QEMU qcode. Use e.g. ret, esc, tab, up/down/left/right, ctrl, alt, shift, f1..f12, delete")])
        XCTAssertEqual(v.category, .knowledgeGap)
        XCTAssertNotNil(v.discoveryHint)
        XCTAssertTrue(v.discoveryHint!.lowercased().contains("ret"))
    }

    // MARK: - Blocked (authority), checked before everything

    func testAuthorizationScopeIsBlocked() {
        // The fetch_url "plan-only scope for serverDiagnostics" block from the over-escalation screenshot.
        let v = classify([ToolFailure(tool: "fetch_url",
            error: "blocked by authorization scope: plan-only scope for serverDiagnostics: server diagnosis should begin read-only")])
        XCTAssertEqual(v.category, .blocked)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.9)
    }

    func testBlockedBeatsCapabilityLanguage() {
        // A denied action can read like a broken tool; authority must win.
        let v = classify([ToolFailure(tool: "run_command",
            error: "permission denied: command not authorized in plan mode")])
        XCTAssertEqual(v.category, .blocked)
    }

    // MARK: - Task bug (the cobc case, once errors are visible)

    func testCompilerErrorIsTaskBug() {
        let v = classify([ToolFailure(tool: "run_command",
            error: "exit code 1\nbroken.cbl:7: error: 'UNDEFINED-VAR' is not defined")], edited: true, built: true)
        XCTAssertEqual(v.category, .taskBug)
        XCTAssertGreaterThanOrEqual(v.confidence, 0.85)
    }

    func testNoToolFailuresIsTaskBug() {
        let v = classify([])
        XCTAssertEqual(v.category, .taskBug)
        XCTAssertLessThan(v.confidence, 0.6)   // low confidence — nothing concrete to go on
    }

    // MARK: - Priority: a knowledge-gap hint outranks a bare capability miss

    func testHintWinsOverPlainCapabilityMiss() {
        let v = classify([
            ToolFailure(tool: "some_tool", error: "unknown action: frobnicate"),                 // toolLimit-ish
            ToolFailure(tool: "other_tool", error: "unsupported verb 'zap'. Try one of: read, write, list"),  // hint
        ])
        XCTAssertEqual(v.category, .knowledgeGap, "if ANY failure tells us how, discovery beats extension")
        XCTAssertEqual(v.culpritTool, "other_tool")
    }
}
