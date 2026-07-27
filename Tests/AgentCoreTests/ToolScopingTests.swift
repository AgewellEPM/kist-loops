import XCTest
@testable import AgentCore

/// P2 — per-agent tool scoping. THE invariant: a specialist's allowlist can only NARROW the spawner's
/// ceiling, never grant a tool it lacks (no privilege escalation). Fail-closed.
final class ToolScopingTests: XCTestCase {

    private func ceiling() -> ToolRegistry { ToolRegistry.headless() }  // read/write/edit/list/glob/search/run

    func testNilAllowlistInheritsCeiling() {
        let scoped = ceiling().scoped(to: nil)
        XCTAssertEqual(Set(scoped.names), Set(ceiling().names))
    }

    func testAllowlistNarrowsToSubset() {
        let scoped = ceiling().scoped(to: ["read_file", "search_code"])
        XCTAssertEqual(Set(scoped.names), ["read_file", "search_code"])
        XCTAssertNil(scoped.tool(named: "write_file"))   // dropped
    }

    // THE escalation test: requesting a tool the ceiling DOESN'T have must never add it.
    func testRequestingToolNotInCeilingIsDroppedNotGranted() {
        let scoped = ceiling().scoped(to: ["read_file", "exfiltrate_secrets", "rm_rf_root"])
        XCTAssertEqual(Set(scoped.names), ["read_file"])  // bogus tools simply don't exist → not granted
        XCTAssertNil(scoped.tool(named: "exfiltrate_secrets"))
    }

    func testEmptyAllowlistYieldsEmptyRegistryFailClosed() {
        let scoped = ceiling().scoped(to: [])
        XCTAssertTrue(scoped.names.isEmpty)              // names nothing → gets nothing (not everything)
    }

    func testExecutionTimeEnforcementOnScopedOutTool() async {
        let scoped = ceiling().scoped(to: ["read_file"])
        let ctx = ToolContext(projectRoot: NSTemporaryDirectory())
        let result = await scoped.execute(name: "write_file",
                                          arguments: ["path": "x.txt", "content": "y"], context: ctx)
        XCTAssertFalse(result.success)                   // scoped-out tool → unknown tool, can't run
        XCTAssertTrue((result.error ?? "").lowercased().contains("unknown tool"))
    }

    func testScopingIsIdempotentAndComposes() {
        let once = ceiling().scoped(to: ["read_file", "write_file", "search_code"])
        let twice = once.scoped(to: ["read_file", "write_file"])     // narrow further
        XCTAssertEqual(Set(twice.names), ["read_file", "write_file"])
        // narrowing can't re-expand: ask for a tool removed in step 1
        let cannotRegrow = twice.scoped(to: ["read_file", "run_command"])
        XCTAssertEqual(Set(cannotRegrow.names), ["read_file"])       // run_command was already gone
    }
}
