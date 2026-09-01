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

    func testCoderSpecialistUsesRawTaskIntentAndReturnsTypedMutationCompletion() async throws {
        let root = NSTemporaryDirectory() + "specialist-write-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let provider = SpecialistScriptedProvider([
            #"{"tool":"write_file","parameters":{"path":"specialist.txt","content":"written"}}"#,
            #"{"done":true,"summary":"specialist wrote the file"}"#,
        ])
        let registry = ProviderRegistry(providers: [provider], keyStore: SpecialistNullKeyStore())
        let definition = SpecialistDefinition(
            name: "coder", description: "writes scoped files", systemPrompt: "Implement exactly the task.",
            toolAllowlist: ["write_file"])
        let spawner = SpecialistSpawner(
            providers: registry, baseTools: ToolRegistry([WriteFileTool()]),
            context: ToolContext(projectRoot: root),
            roleDefault: ProviderBinding(providerId: provider.id), defaultMaxIterations: 4)
        let tool = SpawnSpecialistTool(specialists: [definition], spawner: spawner)

        let result = try await tool.execute(arguments: [
            "agent": "coder", "task": "write specialist.txt containing written",
        ], context: ToolContext(projectRoot: root))

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertEqual(try String(contentsOfFile: root + "/specialist.txt", encoding: .utf8), "written")
        XCTAssertEqual(result.metadata["delegation_status"], "completed")
        XCTAssertEqual(result.metadata["delegation_scope"], "parent-workspace")
        XCTAssertEqual(result.metadata["sub_agent_expected_outcome"], "mutation")
    }
}

private struct SpecialistNullKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
}

private final class SpecialistScriptedProvider: ChatProvider, @unchecked Sendable {
    let id = "specialist-scripted"
    let name = "Specialist Scripted"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = "specialist-scripted"
    let defaultModel = "specialist-scripted-1"
    let availableModels = [AIModel(id: "specialist-scripted-1")]
    private let state: SpecialistScriptedResponses

    init(_ responses: [String]) { state = SpecialistScriptedResponses(responses) }

    func stream(messages: [ChatMessage], model: String, settings: ModelSettings,
                apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let response = await state.next()
        return AsyncThrowingStream { continuation in
            continuation.yield(.delta(response))
            continuation.finish()
        }
    }
}

private actor SpecialistScriptedResponses {
    let responses: [String]
    var index = 0
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String {
        defer { index += 1 }
        return index < responses.count ? responses[index]
            : #"{"done":true,"summary":"out of scripted responses"}"#
    }
}
