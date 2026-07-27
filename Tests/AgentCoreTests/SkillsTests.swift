import XCTest
import Foundation
@testable import AgentCore

/// Agent-Skills unit tests: parsing, validation, dedup, the Tier-1 prompt menu (and the
/// SECURITY invariant that the body NEVER leaks into it), the tracker, and discovery of the
/// builtin + project-local sources. Wiring into `read_file` is pinned in SkillsWiringTests.
final class SkillsTests: XCTestCase {

    // MARK: Parsing

    func testParseFrontmatterAndBody() throws {
        let md = """
        ---
        name: web-research
        description: Find current info from real sources.
        user-invocable: true
        license: MIT
        ---

        # Body heading
        Do the thing.
        """
        let s = try Skill.parse(content: md)
        XCTAssertEqual(s.name, "web-research")
        XCTAssertEqual(s.description, "Find current info from real sources.")
        XCTAssertTrue(s.userInvocable)
        XCTAssertEqual(s.license, "MIT")
        XCTAssertFalse(s.disableModelInvocation)
        XCTAssertTrue(s.instructions.hasPrefix("# Body heading"))
        XCTAssertTrue(s.instructions.contains("Do the thing."))
    }

    func testParseToleratesBOMAndCRLF() throws {
        let md = "\u{FEFF}---\r\nname: a\r\ndescription: d\r\n---\r\nbody\r\n"
        let s = try Skill.parse(content: md)
        XCTAssertEqual(s.name, "a")
        XCTAssertEqual(s.description, "d")
        XCTAssertEqual(s.instructions, "body")
    }

    func testParseStripsQuotesAndParsesMetadataBlock() throws {
        let md = """
        ---
        name: "quoted-name"
        description: 'single quoted'
        metadata:
          author: luke
          version: 2
        ---
        b
        """
        let s = try Skill.parse(content: md)
        XCTAssertEqual(s.name, "quoted-name")
        XCTAssertEqual(s.description, "single quoted")
        XCTAssertEqual(s.metadata["author"], "luke")
        XCTAssertEqual(s.metadata["version"], "2")
    }

    func testParseNoFrontmatterThrows() {
        XCTAssertThrowsError(try Skill.parse(content: "# just markdown\nno frontmatter")) { err in
            XCTAssertEqual(err as? SkillError, .noFrontmatter)
        }
    }

    func testParseUnclosedFrontmatterThrows() {
        XCTAssertThrowsError(try Skill.parse(content: "---\nname: x\n(no close)\n"))
    }

    // MARK: Validation

    func testValidNamesAndInvalidNames() {
        for good in ["a", "web-research", "code-investigation", "x1", "a-b-c"] {
            XCTAssertTrue(Skill.isValidName(good), "expected valid: \(good)")
        }
        for bad in ["", "-lead", "trail-", "double--hyphen", "Has Space", "under_score", "dot.name", "slash/name"] {
            XCTAssertFalse(Skill.isValidName(bad), "expected invalid: \(bad)")
        }
    }

    func testValidateRequiresNameAndDescription() {
        XCTAssertNotNil(Skill(name: "", description: "d", instructions: "i").validate())
        XCTAssertNotNil(Skill(name: "ok", description: "", instructions: "i").validate())
        XCTAssertNil(Skill(name: "ok", description: "d", instructions: "i").validate())
    }

    func testValidateNameMustMatchDirectory() {
        // path's last component is the identity — a mismatch is a copy-paste bug.
        let mismatch = Skill(name: "alpha", description: "d", instructions: "i", path: "/x/beta")
        XCTAssertNotNil(mismatch.validate())
        let match = Skill(name: "alpha", description: "d", instructions: "i", path: "/x/alpha")
        XCTAssertNil(match.validate())
    }

    func testValidateLengthCaps() {
        let longName = String(repeating: "a", count: Skill.maxNameLength + 1)
        XCTAssertNotNil(Skill(name: longName, description: "d", instructions: "i").validate())
        let longDesc = String(repeating: "d", count: Skill.maxDescriptionLength + 1)
        XCTAssertNotNil(Skill(name: "ok", description: longDesc, instructions: "i").validate())
    }

    // MARK: Tier-1 menu — and the no-body-leak SECURITY invariant

    func testPromptXMLContainsMenuFieldsButNeverBody() {
        let s = Skill(name: "web-research", description: "Find info",
                      instructions: "SECRET-BODY-INSTRUCTIONS that must not leak",
                      skillFilePath: "kist:web-research/SKILL.md", builtin: true)
        let mgr = SkillManager(allSkills: [s], activeSkills: [s], states: [])
        let xml = mgr.promptXML()
        XCTAssertTrue(xml.contains("<name>web-research</name>"))
        XCTAssertTrue(xml.contains("<description>Find info</description>"))
        XCTAssertTrue(xml.contains("<location>kist:web-research/SKILL.md</location>"))
        XCTAssertTrue(xml.contains("<type>builtin</type>"))
        // THE invariant: the body is Tier-2, loaded on demand — it must NOT appear in the menu.
        XCTAssertFalse(xml.contains("SECRET-BODY-INSTRUCTIONS"))
    }

    func testPromptXMLExcludesDisableModelInvocation() {
        let hidden = Skill(name: "hidden", description: "d", disableModelInvocation: true,
                           instructions: "i", skillFilePath: "x")
        let shown = Skill(name: "shown", description: "d", instructions: "i", skillFilePath: "y")
        let mgr = SkillManager(allSkills: [hidden, shown], activeSkills: [hidden, shown], states: [])
        let xml = mgr.promptXML()
        XCTAssertFalse(xml.contains("hidden"))
        XCTAssertTrue(xml.contains("shown"))
    }

    func testPromptXMLEmptyWhenNoSkills() {
        XCTAssertEqual(SkillManager.empty.promptXML(), "")
    }

    func testPromptXMLEscapesAngleBrackets() {
        let s = Skill(name: "x", description: "a < b & c > d \"e\"", instructions: "i", skillFilePath: "p")
        let mgr = SkillManager(allSkills: [s], activeSkills: [s], states: [])
        let xml = mgr.promptXML()
        XCTAssertTrue(xml.contains("&lt;"))
        XCTAssertTrue(xml.contains("&amp;"))
        XCTAssertFalse(xml.contains("a < b"))
    }

    // MARK: Dedup (last-wins → project skill overrides builtin)

    func testDedupLastWins() {
        let builtin = Skill(name: "dup", description: "builtin", instructions: "b", builtin: true)
        let user = Skill(name: "dup", description: "user override", instructions: "u", builtin: false)
        let out = SkillManager.dedup([builtin, user])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.description, "user override")
        XCTAssertEqual(out.first?.builtin, false)
    }

    // MARK: Tracker

    func testTrackerMarksOnlyActiveSkills() async {
        let active = Skill(name: "active", description: "d", instructions: "i")
        let tracker = SkillTracker(activeSkills: [active])
        await tracker.markLoaded("active")
        await tracker.markLoaded("not-active")          // must be ignored
        let loaded = await tracker.loadedNames()
        XCTAssertEqual(loaded, ["active"])
        let count = await tracker.loadedCount()
        XCTAssertEqual(count, 1)
    }

    func testTrackerLoadedNamesSorted() async {
        let skills = ["c", "a", "b"].map { Skill(name: $0, description: "d", instructions: "i") }
        let tracker = SkillTracker(activeSkills: skills)
        for n in ["c", "a", "b"] { await tracker.markLoaded(n) }
        let names = await tracker.loadedNames()
        XCTAssertEqual(names, ["a", "b", "c"])
    }

    // MARK: Builtin discovery (real shipped resources)

    func testBuiltinSkillsAreDiscoveredAndValid() {
        let (skills, states) = SkillDiscovery.discoverBuiltins()
        let names = Set(skills.map(\.name))
        XCTAssertTrue(names.contains("web-research"), "shipped builtin web-research must be discovered")
        XCTAssertTrue(names.contains("code-investigation"), "shipped builtin code-investigation must be discovered")
        // Every shipped builtin must parse+validate clean (no error states).
        XCTAssertTrue(states.allSatisfy { $0.status == .ok }, "shipped builtins must all be valid: \(states)")
        // Builtins carry the kist: location prefix so read_file routes them to the embedded FS.
        XCTAssertTrue(skills.allSatisfy { $0.skillFilePath.hasPrefix(Skill.builtinPrefix) })
    }

    // MARK: Project-local discovery (via ConfinedRoot, no new FS surface)

    func testProjectLocalDiscovery() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        try confined.makeDirectory(".kist/skills/my-skill")
        try confined.writeString(".kist/skills/my-skill/SKILL.md",
            "---\nname: my-skill\ndescription: a local skill\n---\nbody", createParents: true)

        let (skills, states) = SkillDiscovery.discoverProjectLocal(confined: confined)
        XCTAssertEqual(skills.map(\.name), ["my-skill"])
        XCTAssertEqual(skills.first?.skillFilePath, ".kist/skills/my-skill/SKILL.md")
        XCTAssertFalse(skills.first!.builtin)
        XCTAssertEqual(states.first?.status, .ok)
    }

    func testManagerLocationIndexMapsLocationToName() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        try confined.makeDirectory(".kist/skills/local-one")
        try confined.writeString(".kist/skills/local-one/SKILL.md",
            "---\nname: local-one\ndescription: d\n---\nb", createParents: true)

        let mgr = SkillManager.discover(confined: confined)
        let idx = mgr.locationIndex()
        XCTAssertEqual(idx[".kist/skills/local-one/SKILL.md"], "local-one")
        // builtins are indexed too
        XCTAssertEqual(idx["kist:web-research/SKILL.md"], "web-research")
    }

    func testManagerDisabledFilter() throws {
        let mgr = SkillManager.discover(projectRoot: NSTemporaryDirectory(), disabled: ["web-research"])
        XCTAssertFalse(mgr.activeSkills.contains { $0.name == "web-research" })
        XCTAssertTrue(mgr.allSkills.contains { $0.name == "web-research" }, "disabled stays in allSkills")
    }

    // MARK: helpers

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "skills-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // realpath so ConfinedRoot's canonicalization matches (macOS /var → /private/var).
        return ToolContext.canonicalize(dir) ?? dir
    }
}
