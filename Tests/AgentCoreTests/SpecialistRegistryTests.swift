import XCTest
@testable import AgentCore

final class SpecialistRegistryTests: XCTestCase {

    private var root: String!
    private var userDir: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "spec_\(UUID().uuidString)"
        userDir = NSTemporaryDirectory() + "specuser_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: userDir)
    }

    // claudeUserDir: nil isolates tests from the real ~/.claude/agents.
    private func registry() -> SpecialistRegistry {
        SpecialistRegistry(projectRoot: root, userDir: userDir, claudeUserDir: nil)
    }

    func testSaveLoadRoundTrip() throws {
        let reg = registry()
        let d = SpecialistDefinition(name: "reviewer", description: "reviews code for bugs",
                                     systemPrompt: "Review.", source: "authored")
        let path = try reg.save(d)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(reg.named("reviewer")?.description, "reviews code for bugs")
    }

    func testSaveRefusesInvalidName() {
        let bad = SpecialistDefinition(name: "../evil", description: "d", systemPrompt: "b")
        XCTAssertThrowsError(try registry().save(bad))
    }

    func testProjectWinsOverUserOnNameCollision() throws {
        // Same name in both scopes — project must win.
        try SpecialistDefinition(name: "dup", description: "USER one", systemPrompt: "u")
            .render().write(toFile: userDir + "/dup.md", atomically: true, encoding: .utf8)
        let projAgents = root + "/.kist/agents"
        try FileManager.default.createDirectory(atPath: projAgents, withIntermediateDirectories: true)
        try SpecialistDefinition(name: "dup", description: "PROJECT one", systemPrompt: "p")
            .render().write(toFile: projAgents + "/dup.md", atomically: true, encoding: .utf8)

        XCTAssertEqual(registry().named("dup")?.description, "PROJECT one")
    }

    // MARK: - Claude Code compat (.claude/agents)

    func testLoadsClaudeAgentsProjectScope() throws {
        // A real .claude/agents file must be discovered unchanged.
        let claudeAgents = root + "/.claude/agents"
        try FileManager.default.createDirectory(atPath: claudeAgents, withIntermediateDirectories: true)
        let claudeFile = """
        ---
        name: claude-native
        description: a subagent authored for Claude Code
        tools: [Read, Grep]
        model: haiku
        ---

        You review code.
        """
        try claudeFile.write(toFile: claudeAgents + "/claude-native.md", atomically: true, encoding: .utf8)
        let d = registry().named("claude-native")
        XCTAssertNotNil(d, ".claude/agents file is discovered")
        XCTAssertEqual(d?.toolAllowlist, ["Read", "Grep"])
        XCTAssertEqual(d?.modelAlias, "haiku")
    }

    func testKistProjectWinsOverClaudeProjectOnCollision() throws {
        let claudeAgents = root + "/.claude/agents"
        let kistAgents = root + "/.kist/agents"
        try FileManager.default.createDirectory(atPath: claudeAgents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: kistAgents, withIntermediateDirectories: true)
        try SpecialistDefinition(name: "dup", description: "CLAUDE version", systemPrompt: "c")
            .render().write(toFile: claudeAgents + "/dup.md", atomically: true, encoding: .utf8)
        try SpecialistDefinition(name: "dup", description: "KIST version", systemPrompt: "k")
            .render().write(toFile: kistAgents + "/dup.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(registry().named("dup")?.description, "KIST version",
                       "kist-native project scope beats .claude/agents on a name collision")
    }

    func testMatchingRanksByKeywordOverlap() throws {
        let reg = registry()
        try reg.save(SpecialistDefinition(name: "db-migrator", description: "migrate database schema migrations", systemPrompt: "x"))
        try reg.save(SpecialistDefinition(name: "ui-designer", description: "design user interface layouts", systemPrompt: "x"))
        let hits = reg.matching(goal: "help me migrate the database schema", limit: 3)
        XCTAssertEqual(hits.first?.name, "db-migrator")
        XCTAssertFalse(hits.contains { $0.name == "ui-designer" })   // no overlap → not returned
    }

    // H5: if `.kist/agents` is a symlink pointing OUTSIDE the project root, save must refuse (no escape).
    func testSaveRefusesSymlinkedAgentsDirEscape() throws {
        let escapeTarget = NSTemporaryDirectory() + "escape_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: escapeTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: escapeTarget) }
        // make <root>/.kist exist, and <root>/.kist/agents → escapeTarget (a symlink out of the project)
        try FileManager.default.createDirectory(atPath: root + "/.kist", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/.kist/agents", withDestinationPath: escapeTarget)

        let d = SpecialistDefinition(name: "escapee", description: "d", systemPrompt: "b")
        XCTAssertThrowsError(try registry().save(d))                 // real target is outside root → refused
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget + "/escapee.md"))
    }

    func testUnparseableFilesSkippedNotCrash() throws {
        let projAgents = root + "/.kist/agents"
        try FileManager.default.createDirectory(atPath: projAgents, withIntermediateDirectories: true)
        try "garbage not frontmatter".write(toFile: projAgents + "/broken.md", atomically: true, encoding: .utf8)
        try registry().save(SpecialistDefinition(name: "good", description: "works", systemPrompt: "x"))
        let all = registry().load()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "good")
    }
}
