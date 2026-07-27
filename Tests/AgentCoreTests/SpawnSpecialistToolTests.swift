import XCTest
@testable import AgentCore

/// Pins the proactive-delegation tool: its roster description (drives the model's choice) and the
/// unknown-agent guard. The full spawn is exercised via SpecialistSpawner's plan tests + integration.
final class SpawnSpecialistToolTests: XCTestCase {

    private func spawner() -> SpecialistSpawner {
        SpecialistSpawner(providers: ProviderRegistry(), baseTools: ToolRegistry([]),
                          context: ToolContext(projectRoot: NSTemporaryDirectory()))
    }

    private let roster = [
        SpecialistDefinition(name: "security-auditor", description: "audits for vulnerabilities", systemPrompt: "p"),
        SpecialistDefinition(name: "test-writer", description: "writes unit tests", systemPrompt: "p"),
    ]

    func testDescriptionListsEverySpecialistForDelegation() {
        let tool = SpawnSpecialistTool(specialists: roster, spawner: spawner())
        XCTAssertTrue(tool.description.contains("security-auditor: audits for vulnerabilities"))
        XCTAssertTrue(tool.description.contains("test-writer: writes unit tests"))
    }

    func testEmptyRosterDescriptionIsHonest() {
        let tool = SpawnSpecialistTool(specialists: [], spawner: spawner())
        XCTAssertTrue(tool.description.contains("No specialists are configured"))
    }

    func testUnknownAgentFailsWithoutSpawning() async throws {
        let tool = SpawnSpecialistTool(specialists: roster, spawner: spawner())
        let r = try await tool.execute(arguments: ["agent": "nope", "task": "do it"],
                                       context: ToolContext(projectRoot: NSTemporaryDirectory()))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("no specialist named 'nope'") ?? false)
        XCTAssertTrue(r.error?.contains("security-auditor") ?? false, "lists available names")
    }
}
