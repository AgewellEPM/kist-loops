import XCTest
import Foundation
@testable import AgentCore

/// S1 — agentskills.io `allowed-tools` capability scoping. A loaded skill that declares a tool
/// allow-list scopes the session to least-privilege (its tools + always-safe read-only tools);
/// anything else is refused. With no restrictive skill loaded, behavior is unchanged.
final class SkillCapabilityScopeTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() + "scope-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(dir) ?? dir
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    // MARK: parse

    func testParseAllowedToolsSpaceSeparated() throws {
        // Space-separated per the agentskills.io spec; double-space tolerated (empty parts dropped).
        let md = "---\nname: s\ndescription: d\nallowed-tools: read_file  search_code write_file\n---\nbody"
        let s = try Skill.parse(content: md)
        XCTAssertEqual(s.allowedTools, ["read_file", "search_code", "write_file"])
    }

    func testParseNoAllowedToolsIsEmpty() throws {
        let s = try Skill.parse(content: "---\nname: s\ndescription: d\n---\nbody")
        XCTAssertTrue(s.allowedTools.isEmpty)
    }

    // MARK: tracker allowlist

    func testNoRestrictiveSkillMeansNoScope() async {
        let open = Skill(name: "open", description: "d", instructions: "i")          // no allowed-tools
        let tracker = SkillTracker(activeSkills: [open])
        await tracker.markLoaded("open")
        let allow = await tracker.activeToolAllowlist()
        XCTAssertNil(allow, "a loaded skill with no allowed-tools imposes no scope")
    }

    func testRestrictiveSkillUnionsWithAlwaysSafe() async {
        let scoped = Skill(name: "scoped", description: "d", allowedTools: ["custom_tool"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [scoped])
        // before load: no restriction yet
        let before = await tracker.activeToolAllowlist()
        XCTAssertNil(before)
        await tracker.markLoaded("scoped")
        let allow = await tracker.activeToolAllowlist()
        XCTAssertNotNil(allow)
        XCTAssertTrue(allow!.contains("custom_tool"), "declared tool is allowed")
        XCTAssertTrue(allow!.contains("read_file"), "always-safe read tool survives (can still load skills)")
        XCTAssertFalse(allow!.contains("write_file"), "an undeclared mutating tool is NOT allowed")
    }

    // Sprint 2 (Codex HIGH): the ENFORCED scope must come from the LOAD-TIME verified bytes, not the
    // discovery snapshot. An attacker who presents a broad allow-list at discovery but whose load is
    // trusted only for the narrow (signed/pinned) bytes must get the NARROW scope.
    func testLoadTimeScopeOverridesDiscoverySnapshot() async {
        let discovered = Skill(name: "s", description: "d", allowedTools: ["run_command", "write_file"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [discovered])   // discovery snapshot = broad
        // Trusted load, but the verified bytes declared only the narrow set.
        await tracker.markLoaded("s", trusted: true, allowedTools: ["read_file"])
        let allow = await tracker.activeToolAllowlist()
        XCTAssertNotNil(allow)
        XCTAssertFalse(allow!.contains("run_command"), "discovery-time broad tool must NOT survive a load proven on narrow bytes")
        XCTAssertFalse(allow!.contains("write_file"), "discovery-time broad tool must NOT survive")
        XCTAssertTrue(allow!.contains("read_file"), "the load-time verified scope is enforced")
    }

    // Codex re-review LOW: a trusted skill whose verified bytes have NO allowed-tools field (parsed → [])
    // must be UNRESTRICTED, not conflated with an empty restriction that caps it to read-only.
    func testTrustedNoAllowedToolsFieldIsUnrestrictedNotCapped() async {
        let noField = Skill(name: "n", description: "d", instructions: "i")   // no allowed-tools
        let tracker = SkillTracker(activeSkills: [noField])
        await tracker.markLoaded("n", trusted: true, allowedTools: [])        // parsed.allowedTools == []
        let allow = await tracker.activeToolAllowlist()
        XCTAssertNil(allow, "no allowed-tools field ⇒ no restriction; must not cap to read-only")
    }

    // Most-restrictive-wins still holds: an unrestricted skill co-loaded with a restrictive one does NOT
    // lift the restriction.
    func testUnrestrictedSkillDoesNotLiftACoLoadedRestriction() async {
        let open = Skill(name: "open", description: "d", instructions: "i")
        let scoped = Skill(name: "scoped", description: "d", allowedTools: ["custom_tool"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [open, scoped])
        await tracker.markLoaded("open", trusted: true, allowedTools: [])
        await tracker.markLoaded("scoped", trusted: true, allowedTools: ["custom_tool"])
        let allow = await tracker.activeToolAllowlist()
        XCTAssertNotNil(allow)
        XCTAssertTrue(allow!.contains("custom_tool"))
        XCTAssertFalse(allow!.contains("write_file"), "the restrictive skill still caps the session")
    }

    // A load with NO explicit load-time scope (e.g. a builtin) still falls back to the discovery set.
    func testNoLoadTimeScopeFallsBackToDiscovery() async {
        let scoped = Skill(name: "b", description: "d", allowedTools: ["custom_tool"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [scoped])
        await tracker.markLoaded("b")                            // no allowedTools passed
        let allow = await tracker.activeToolAllowlist()
        XCTAssertTrue(allow?.contains("custom_tool") ?? false, "fallback to discovery scope for builtins/no-scope loads")
    }

    // MARK: enforcement at ToolRegistry.execute

    private func ctx(tracker: SkillTracker) -> ToolContext {
        ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true))
            .withSkills(locations: [:], tracker: tracker)
    }

    func testEnforcementBlocksUndeclaredTool() async {
        let scoped = Skill(name: "ro", description: "d", allowedTools: ["read_file"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [scoped])
        await tracker.markLoaded("ro")
        let registry = ToolRegistry.headless()

        // write_file is NOT in the allow-list and not always-safe → refused by capability scope.
        let blocked = await registry.execute(name: "write_file",
                                             arguments: ["path": "x.txt", "content": "y"], context: ctx(tracker: tracker))
        XCTAssertFalse(blocked.success)
        XCTAssertTrue((blocked.error ?? "").contains("skill capability scope"), blocked.error ?? "")

        // list_files is always-safe → NOT blocked by scope (may succeed/fail on its own, but not the scope gate).
        let safe = await registry.execute(name: "list_files", arguments: ["path": "."], context: ctx(tracker: tracker))
        XCTAssertFalse((safe.error ?? "").contains("skill capability scope"), "always-safe tool must not be scope-blocked")
    }

    func testNoScopeWhenNoRestrictiveSkillLoaded() async {
        let open = Skill(name: "open", description: "d", instructions: "i")
        let tracker = SkillTracker(activeSkills: [open])
        await tracker.markLoaded("open")
        let registry = ToolRegistry.headless()
        let r = await registry.execute(name: "write_file",
                                       arguments: ["path": "x.txt", "content": "y"], context: ctx(tracker: tracker))
        // write_file should run (and succeed) — no capability scope in force.
        XCTAssertFalse((r.error ?? "").contains("skill capability scope"), "no restrictive skill ⇒ no scope block")
    }
}
