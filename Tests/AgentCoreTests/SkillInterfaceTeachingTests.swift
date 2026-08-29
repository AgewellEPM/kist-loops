import XCTest
@testable import AgentCore

/// Autopsy regression (2026-08-25): the autonomy flatline's first domino was a model calling the
/// advertised skill `code-investigation` as if it were a TOOL. The bare "unknown tool" refusal was
/// classified as a capability gap (toolLimit) and spawned a ghost "extend the tool" self-heal
/// mission. These tests pin the teaching bridge and the fail-loud discovery contract.
final class SkillInterfaceTeachingTests: XCTestCase {
    private let ctx = ToolContext(projectRoot: NSTemporaryDirectory())

    func testSkillCalledAsToolTeachesTheRealInterface() async throws {
        // Requires the builtin bundle beside the test runner (SPM provides Bundle.module in tests).
        let (skills, _) = SkillDiscovery.discoverBuiltins()
        guard let skill = skills.first(where: { $0.name == "code-investigation" }) else {
            throw XCTSkip("builtin bundle not present in this test environment")
        }
        let registry = ToolRegistry([])
        let result = await registry.execute(name: "code-investigation", arguments: [:], context: ctx)
        let message = result.error ?? result.output
        XCTAssertFalse(result.success)
        XCTAssertTrue(message.contains("is a skill, not a tool"),
                      "must teach the interface, got: \(message)")
        XCTAssertTrue(message.contains(skill.skillFilePath),
                      "must name the skill's real location so the next step is the correct read")
        XCTAssertFalse(message.contains("unknown tool"),
                       "must NOT read as tool absence — that misclassifies as a capability gap")
    }

    func testTrulyUnknownToolStillRefusesPlainly() async {
        let registry = ToolRegistry([])
        let result = await registry.execute(name: "definitely-not-a-real-tool", arguments: [:], context: ctx)
        let message = result.error ?? result.output
        XCTAssertFalse(result.success)
        XCTAssertTrue(message.contains("unknown tool: definitely-not-a-real-tool"))
    }

    // Site pin (multi-site discipline): discovery must be fail-LOUD when the bundle is absent.
    func testSiteDiscoverBuiltinsIsFailLoud() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let src = try String(contentsOf: root.appendingPathComponent("Sources/AgentCore/Skills/SkillDiscovery.swift"),
                             encoding: .utf8)
        XCTAssertTrue(src.contains("builtin resource bundle missing"),
                      "an absent bundle must announce itself, never silently amputate builtin skills")
    }
}
