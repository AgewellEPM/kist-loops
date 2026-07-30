import XCTest
@testable import AgentCore

/// Swift port of `agent-config-loader.test.sh` (task board #3, 2026-07-29). Every scenario runs
/// against a throwaway temp root so it never touches the real `~/AGENTS`.
final class AgentConfigResolverTests: XCTestCase {
    private var root: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "agents-cfg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func write(_ relPath: String, _ contents: String = "x") throws {
        let full = root + "/" + relPath
        try FileManager.default.createDirectory(
            atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    // Scenario 1 (spec): no AGENTS/ directory → root AGENTS.md, even for a named agent.
    func testNoAgentsDirResolvesToRootAgentsMd() throws {
        try write("AGENTS.md", "root config")
        XCTAssertEqual(AgentConfigResolver.resolve(root: root), root + "/AGENTS.md")
        XCTAssertEqual(AgentConfigResolver.resolve(root: root, agent: "coder"), root + "/AGENTS.md")
    }

    // Scenario 2 (spec): AGENTS/default/AGENTS.md exists → that file.
    func testAgentsDirResolvesToDefault() throws {
        try write("AGENTS/default/AGENTS.md", "default config")
        XCTAssertEqual(AgentConfigResolver.resolve(root: root), root + "/AGENTS/default/AGENTS.md")
    }

    // Scenario 3 (spec): root AGENTS.md exists but AGENTS/ takes precedence (no merging — full replace).
    func testAgentsDirWinsOverRootAgentsMd() throws {
        try write("AGENTS.md", "root config")
        try write("AGENTS/default/AGENTS.md", "default config")
        XCTAssertEqual(
            AgentConfigResolver.resolve(root: root, agent: "default"),
            root + "/AGENTS/default/AGENTS.md")
    }

    // Per-agent resolution: a named agent with its own file gets it; without one, falls back to default.
    func testNamedAgentResolutionAndFallback() throws {
        try write("AGENTS/default/AGENTS.md", "default config")
        try write("AGENTS/coder/AGENTS.md", "coder config")
        XCTAssertEqual(
            AgentConfigResolver.resolve(root: root, agent: "coder"),
            root + "/AGENTS/coder/AGENTS.md")
        XCTAssertEqual(
            AgentConfigResolver.resolve(root: root, agent: "critic"),
            root + "/AGENTS/default/AGENTS.md")
    }

    // resolveExisting reports nil when the resolved file is absent, the path when present.
    func testResolveExistingReflectsPresence() throws {
        XCTAssertNil(AgentConfigResolver.resolveExisting(root: root))
        try write("AGENTS.md", "root config")
        XCTAssertEqual(AgentConfigResolver.resolveExisting(root: root), root + "/AGENTS.md")
    }

    // Integration: the AGENTS/ precedence actually flows through ProjectMemory.facts() — the AGENTS/
    // directory content is ingested and the (ignored) root AGENTS.md is not, proving no double-load.
    func testProjectMemoryIngestsAgentsDirNotRoot() throws {
        try write("AGENTS.md", "ROOT_MARKER should be shadowed")
        try write("AGENTS/default/AGENTS.md", "DIR_MARKER wins")
        let facts = ProjectMemory(root: root).facts()
        XCTAssertTrue(facts.contains("DIR_MARKER wins"))
        XCTAssertFalse(facts.contains("ROOT_MARKER"))
    }
}
