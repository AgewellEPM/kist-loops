import XCTest
import Foundation
@testable import AgentCore

/// Regression tests for the multi-model review fixes (Codex + DeepSeek + Grok). Each pins one
/// hardening so a future change that reopens the hole names the exact invariant that broke.
final class SkillsHardeningTests: XCTestCase {

    // FIX 1 — duplicate frontmatter scalar keys are REJECTED (no silent last-wins hide).
    func testDuplicateFrontmatterKeyRejected() {
        let md = """
        ---
        name: x
        description: first
        description: second
        ---
        body
        """
        XCTAssertThrowsError(try Skill.parse(content: md)) { err in
            guard case .invalid(let problems)? = err as? SkillError else { return XCTFail("wrong error") }
            XCTAssertTrue(problems.contains { $0.contains("duplicate") })
        }
    }

    // FIX 2 — control characters are stripped from scalar values (no raw bytes into prompt XML).
    func testControlCharsStrippedFromScalars() throws {
        let md = "---\nname: x\ndescription: a\u{07}b\u{1B}c\n---\nbody"
        let s = try Skill.parse(content: md)
        XCTAssertEqual(s.description, "abc")
    }

    // FIX 3 — builtin reads require an ADVERTISED location; the bare kist: prefix is not enough.
    func testBuiltinReadRequiresAdvertisement() async throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        // Context with NO skills advertised.
        let ctx = ToolContext(projectRoot: root)
        await XCTAssertThrowsErrorAsync(
            try await ReadFileTool().execute(arguments: ["path": "kist:web-research/SKILL.md"], context: ctx),
            "an unadvertised kist: path must be refused, not read")
    }

    // FIX 4 — a skill read ignores caller line-range and never strands a mark on an invalid range.
    func testProjectSkillReadIgnoresRangeAndMarksOnce() async throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        let body = (1...50).map { "line \($0)" }.joined(separator: "\n")
        try confined.makeDirectory(".kist/skills/ranged")
        try confined.writeString(".kist/skills/ranged/SKILL.md",
            "---\nname: ranged\ndescription: d\n---\n\(body)", createParents: true)
        let (ctx, tracker) = try contextWithSkills(root: root)

        // A wildly out-of-range start_line would have stranded markLoaded under the old code.
        let result = try await ReadFileTool().execute(
            arguments: ["path": ".kist/skills/ranged/SKILL.md", "start_line": 999999], context: ctx)
        XCTAssertTrue(result.success, "skill read must succeed regardless of caller range")
        XCTAssertTrue(result.output.contains("line 50"), "whole body returned")
        let loaded = await tracker.loadedNames()
        XCTAssertEqual(loaded, ["ranged"])
    }

    // FIX 5 — oversized project SKILL.md is dropped at discovery with an error state.
    func testOversizedProjectSkillRefusedAtDiscovery() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        let huge = "---\nname: huge\ndescription: d\n---\n" + String(repeating: "A", count: SkillDiscovery.maxSkillBytes + 16)
        try confined.makeDirectory(".kist/skills/huge")
        try confined.writeString(".kist/skills/huge/SKILL.md", huge, createParents: true)

        let (skills, states) = SkillDiscovery.discoverProjectLocal(confined: confined)
        XCTAssertFalse(skills.contains { $0.name == "huge" }, "oversized skill must not load")
        XCTAssertTrue(states.contains { $0.name == "huge" && $0.status == .error }, "must record the refusal")
    }

    // FIX 6 — a disable-model-invocation skill is NOT in the load index → read_file treats its
    // file as an ordinary (windowed, untracked) file even though it parsed as a skill.
    func testDisabledModelInvocationSkillNotLoadableViaReadFile() async throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        let body = (1...500).map { "line \($0)" }.joined(separator: "\n")
        try confined.makeDirectory(".kist/skills/useronly")
        try confined.writeString(".kist/skills/useronly/SKILL.md",
            "---\nname: useronly\ndescription: d\ndisable-model-invocation: true\n---\n\(body)", createParents: true)

        let mgr = SkillManager.discover(confined: confined)
        XCTAssertNil(mgr.locationIndex()[".kist/skills/useronly/SKILL.md"], "user-only skill must not be in load index")

        let tracker = SkillTracker(activeSkills: mgr.activeSkills)
        let ctx = ToolContext(projectRoot: root).withSkills(locations: mgr.locationIndex(), tracker: tracker)
        let result = try await ReadFileTool().execute(
            arguments: ["path": ".kist/skills/useronly/SKILL.md"], context: ctx)
        XCTAssertEqual(result.metadata["truncated"], "true", "treated as ordinary file → windowed")
        let loaded = await tracker.loadedNames()
        XCTAssertEqual(loaded, [], "must NOT be marked loaded")
    }

    // FIX 7 (MiMo) — readBuiltin containment uses path-component prefix, refusing a sibling-root
    // escape, and still serves the legit builtin.
    func testBuiltinContainmentComponentwise() throws {
        XCTAssertNoThrow(try SkillDiscovery.readBuiltin("kist:web-research/SKILL.md"))
        // A name engineered to string-hasPrefix the root but not be under it must still be refused
        // (it isn't an advertised builtin and isn't a real path).
        XCTAssertThrowsError(try SkillDiscovery.readBuiltin("kist:web-research-EVIL/SKILL.md"))
    }

    // FIX 8 (MiMo) — a project skill shadowing a builtin is RECORDED (not silent supply-chain).
    func testProjectSkillShadowingBuiltinIsSurfaced() throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        try confined.makeDirectory(".kist/skills/web-research")
        try confined.writeString(".kist/skills/web-research/SKILL.md",
            "---\nname: web-research\ndescription: project override\n---\nb", createParents: true)

        let mgr = SkillManager.discover(confined: confined)
        XCTAssertTrue(mgr.overriddenBuiltins.contains("web-research"), "shadowing a builtin must be surfaced")
        // Precedence unchanged: project wins (last-wins), but visibly.
        XCTAssertEqual(mgr.activeSkills.first { $0.name == "web-research" }?.builtin, false)
    }

    // MARK: helpers

    private func makeTempProject() throws -> String {
        let dir = NSTemporaryDirectory() + "skills-hard-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return ToolContext.canonicalize(dir) ?? dir
    }

    private func contextWithSkills(root: String) throws -> (ToolContext, SkillTracker) {
        let confined = try ConfinedRoot(root: root)
        let mgr = SkillManager.discover(confined: confined)
        let tracker = SkillTracker(activeSkills: mgr.activeSkills)
        let ctx = ToolContext(projectRoot: root).withSkills(locations: mgr.locationIndex(), tracker: tracker)
        return (ctx, tracker)
    }
}
