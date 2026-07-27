import XCTest
import Foundation
@testable import AgentCore

/// Pins the Agent-Skills WIRING — the sites where skills change real behavior. Per the
/// multi-site rule each enforcement site gets its own named assertion so a regression names
/// the exact site that broke:
///
///   SITE A — read_file builtin branch (`kist:` prefix): reads the embedded body whole + marks loaded.
///   SITE B — read_file project-local branch: a known SKILL.md location reads WHOLE (window lifted) + marks loaded.
///   SITE C — read_file non-skill file: unchanged windowed behavior, NOT marked.
///   SITE D — security: builtin path traversal is refused; no escape to arbitrary files.
///   SITE E — prompt assembly: the menu is injected, the body is not.
final class SkillsWiringTests: XCTestCase {

    // MARK: SITE D — builtin read is bounded to the embedded subtree

    func testReadBuiltinHappyPath() throws {
        let body = try SkillDiscovery.readBuiltin("kist:web-research/SKILL.md")
        XCTAssertTrue(body.contains("name: web-research"))
        XCTAssertTrue(body.contains("Web research procedure"))
    }

    func testReadBuiltinRejectsTraversalAndBadInputs() {
        for evil in ["kist:../../../etc/passwd", "kist:web-research/../../secret",
                     "kist:/etc/passwd", "kist:./SKILL.md", "kist:", "no-prefix/SKILL.md"] {
            XCTAssertThrowsError(try SkillDiscovery.readBuiltin(evil), "must refuse: \(evil)") { err in
                XCTAssertEqual(err as? SkillError, .notFound(evil))
            }
        }
    }

    // MARK: SITE A — read_file resolves a builtin and marks it loaded

    func testReadFileLoadsBuiltinSkillAndTracks() async throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (ctx, tracker) = try contextWithSkills(root: root)

        let result = try await ReadFileTool().execute(
            arguments: ["path": "kist:web-research/SKILL.md"], context: ctx)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.metadata["builtin_skill"], "true")
        XCTAssertTrue(result.output.contains("Web research procedure"))
        let loadedA = await tracker.loadedNames()
        XCTAssertEqual(loadedA, ["web-research"])
    }

    // MARK: SITE B — project-local SKILL.md reads WHOLE (window lifted) + marks loaded

    func testReadFileLoadsProjectSkillWholeFileAndTracks() async throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        // A skill body longer than the 400-line default window — proves the window is lifted.
        let longBody = (1...500).map { "line \($0)" }.joined(separator: "\n")
        try confined.makeDirectory(".kist/skills/big-skill")
        try confined.writeString(".kist/skills/big-skill/SKILL.md",
            "---\nname: big-skill\ndescription: a big skill\n---\n\(longBody)", createParents: true)

        let (ctx, tracker) = try contextWithSkills(root: root)
        let result = try await ReadFileTool().execute(
            arguments: ["path": ".kist/skills/big-skill/SKILL.md"], context: ctx)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.metadata["truncated"], "false", "skill read must NOT truncate at 400 lines")
        XCTAssertTrue(result.output.contains("line 500"), "whole skill body must be present")
        let loadedB = await tracker.loadedNames()
        XCTAssertEqual(loadedB, ["big-skill"])
    }

    // MARK: SITE C — a non-skill file is unchanged: windowed + NOT tracked

    func testReadFileNonSkillIsWindowedAndNotTracked() async throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let confined = try ConfinedRoot(root: root)
        let longBody = (1...500).map { "line \($0)" }.joined(separator: "\n")
        try confined.writeString("notes.txt", longBody, createParents: true)

        let (ctx, tracker) = try contextWithSkills(root: root)
        let result = try await ReadFileTool().execute(arguments: ["path": "notes.txt"], context: ctx)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.metadata["truncated"], "true", "non-skill file keeps the 400-line window")
        XCTAssertFalse(result.output.contains("line 500"))
        let loadedC = await tracker.loadedNames()
        XCTAssertEqual(loadedC, [], "reading a normal file must NOT mark a skill loaded")
    }

    // MARK: SITE D (cont.) — read_file refuses an escaping builtin path, reads nothing

    func testReadFileRefusesEscapingBuiltinPath() async throws {
        let root = try makeTempProject()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let (ctx, _) = try contextWithSkills(root: root)
        await XCTAssertThrowsErrorAsync(
            try await ReadFileTool().execute(arguments: ["path": "kist:../../../etc/passwd"], context: ctx))
    }

    // MARK: SITE E — prompt assembly injects the menu, never the body

    func testSystemPromptsIncludeMenuNotBody() {
        let s = Skill(name: "web-research", description: "Find info",
                      instructions: "BODY-MUST-NOT-APPEAR-IN-PROMPT",
                      skillFilePath: "kist:web-research/SKILL.md", builtin: true)
        let xml = SkillManager(allSkills: [s], activeSkills: [s], states: []).promptXML()
        let tools = ToolRegistry.headless()

        let textPrompt = HeadlessAgentLoop.systemPrompt(tools: tools, projectRoot: "/tmp", skillsXML: xml)
        let nativePrompt = HeadlessAgentLoop.nativeSystemPrompt(tools: tools, projectRoot: "/tmp", skillsXML: xml)
        for prompt in [textPrompt, nativePrompt] {
            XCTAssertTrue(prompt.contains("AGENT SKILLS"))
            XCTAssertTrue(prompt.contains("<name>web-research</name>"))
            XCTAssertFalse(prompt.contains("BODY-MUST-NOT-APPEAR-IN-PROMPT"))
        }
        // Empty XML ⇒ no skills section at all (callers append unconditionally).
        XCTAssertEqual(HeadlessAgentLoop.skillsSection(""), "")
    }

    // MARK: helpers

    private func makeTempProject() throws -> String {
        let dir = NSTemporaryDirectory() + "skills-wire-" + UUID().uuidString
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

/// Minimal async throwing assertion (XCTAssertThrowsError has no async overload).
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ message: String = "", file: StaticString = #filePath,
                                  line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail(message.isEmpty ? "expected an error to be thrown" : message, file: file, line: line)
    } catch {
        // expected
    }
}
