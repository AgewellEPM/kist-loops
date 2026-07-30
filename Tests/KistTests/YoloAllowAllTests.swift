import XCTest
@testable import Kist

/// YOLO allow-all on IRREVERSIBLE prompts (2026-07-29). Luke: "all this should be covered by allow all —
/// need a YOLO allow-all, once I see this I can ok it." Previously an irreversible/dangerous approval
/// offered only run-once/skip and never latched, so a wall of MCP-tool confirms (perslis/jeeves) couldn't
/// be cleared in one keystroke. The fix adds an explicit `[a] allow ALL incl. irreversible` latch.
///
/// The interactors read real stdin, so behaviour is pinned at the source per the codebase convention.
/// Per the multi-site rule, BOTH interactors that gate dangerous approvals are asserted.
final class YoloAllowAllTests: XCTestCase {

    private func source(_ rel: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
    }

    func testTerminalInteractorOffersAndArmsYoloOnIrreversible() throws {
        let s = try source("Sources/Kist/TerminalInteractor.swift")
        XCTAssertTrue(s.contains("[a] allow ALL incl. irreversible"),
                      "the irreversible prompt must OFFER a YOLO allow-all option")
        // On a dangerous prompt, 'a' must arm full autopilot (latch everything), not run-once.
        XCTAssertTrue(s.contains("if dangerous {\n                // Explicit YOLO on an irreversible prompt: arm full autopilot")
                      || s.range(of: #"case "a"[\s\S]{0,200}autopilot = true"#, options: .regularExpression) != nil,
                      "'a' on an irreversible prompt must set autopilot = true (latch everything for the session)")
    }

    func testTUIInteractorLatchesYoloOnIrreversible() throws {
        let s = try source("Sources/Kist/TUI/TUIBridge.swift")
        XCTAssertTrue(s.contains("approveAllDangerous"),
                      "TUIInteractor (sibling site) must also support a dangerous YOLO latch")
        XCTAssertTrue(s.contains("if approveAllDangerous { return true }"),
                      "once armed, the TUI YOLO latch must short-circuit every subsequent approval")
    }
}
