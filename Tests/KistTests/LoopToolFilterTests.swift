import XCTest
@testable import Kist

/// The great-loop trims coding-irrelevant tools so their schemas don't inflate every model call (dogfood:
/// ~70 tools / ~25k schema chars ≈ 6.5k tokens/call ate ~half a cycle's budget → no convergence). These
/// pin what's dropped vs kept, so the lean set stays a lean CODING set and never drops an essential tool.
final class LoopToolFilterTests: XCTestCase {

    func testDropsCodingIrrelevantTools() {
        for name in ["computer_control", "desktop_control", "tap", "locate", "look", "ui_elements", "ax_press",
                     "wait_for_screen", "watch_screen", "computer_use_selftest", "computer_use_check",
                     "pentest", "security_audit", "business_workflow", "governance_report",
                     "edit_image", "generate_audio", "analyze_media", "watch_video", "extract_clip", "view_image",
                     "isolated-tester__click", "isolated-tester__run_test"] {
            XCTAssertTrue(KistRunner.isLoopIrrelevantTool(name), "\(name) should be dropped from the coding loop")
        }
    }

    func testKeepsCodingEssentialTools() {
        for name in ["read_file", "write_file", "edit_file", "apply_patch", "list_files", "glob_files",
                     "make_dir", "run_command", "symbols", "cortex", "recall", "tasks", "context_brain",
                     "lsp-swift__hover", "lsp-swift__references", "research_run", "fetch_url", "web_search"] {
            XCTAssertFalse(KistRunner.isLoopIrrelevantTool(name), "\(name) is essential — must NOT be dropped")
        }
    }
}
