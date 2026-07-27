import XCTest
@testable import FloatingChatApp

@MainActor
final class AgentSubTeamTests: XCTestCase {

    private var tempDir: URL!
    private var savedProvider: (any AIProvider)!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fca-subteam-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedProvider = ProviderManager.shared.currentProvider
    }

    override func tearDownWithError() throws {
        ProviderManager.shared.currentProvider = savedProvider
        AgentLoopEngine.shared.reset()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func lead() -> AgentConfig {
        AgentConfig(id: "l", name: "L", provider: "user_selected", model: "auto", role: .lead, color: "#fff", systemPrompt: nil)
    }

    // MARK: - Parsing

    func testParseSpawnTeam_extractsTeamAndTask() {
        let r = AgentLoopEngine.parseSpawnTeam("<spawn_team team=\"debate\">argue about X</spawn_team>")
        XCTAssertEqual(r?.teamId, "debate")
        XCTAssertEqual(r?.task, "argue about X")
        XCTAssertNil(AgentLoopEngine.parseSpawnTeam("just a normal reply, no tag"))
    }

    // MARK: - Depth guard

    func testDepthGuard_allowsTopLevelRefusesAtCap() {
        XCTAssertTrue(AgentLoopEngine(depth: 0).canSpawnSubTeam())
        let atCap = AgentLoopEngine(depth: 3)
        atCap.maxTeamDepth = 3
        XCTAssertFalse(atCap.canSpawnSubTeam(), "depth 3 with cap 3 cannot spawn a 4th level")
    }

    func testSpawnSubTeam_refusedAtMaxDepth() async {
        let atCap = AgentLoopEngine(depth: 3)
        atCap.maxTeamDepth = 3
        let result = await atCap.spawnSubTeam(.init(teamId: "solo", task: "x"), parentAgent: lead())
        XCTAssertTrue(result.contains("refused"), "must refuse rather than recurse past the cap")
    }

    // MARK: - Runtime isolation

    func testRuntimeSnapshot_roundTripsState() {
        let service = AgentRuntimeService.shared
        let original = service.currentProjectPath
        defer { service.currentProjectPath = original }

        let snapshot = service.captureSnapshot()
        service.currentProjectPath = "/changed-by-child-\(UUID().uuidString)"
        service.restoreSnapshot(snapshot)
        XCTAssertEqual(service.currentProjectPath, snapshot.currentProjectPath,
                       "restoreSnapshot must roll back child mutations")
    }

    func testRuntimeSnapshot_cancelsPendingDebounce() {
        let service = AgentRuntimeService.shared
        let snapshot = service.captureSnapshot()
        service.scheduleBuildDebounce(projectPath: "/tmp/does-not-exist")
        XCTAssertTrue(service.hasPendingAutoBuild, "debounce scheduled")
        service.restoreSnapshot(snapshot)
        XCTAssertFalse(service.hasPendingAutoBuild,
                       "restore must cancel a child-scheduled auto-build (Codex HIGH-2)")
    }

    // MARK: - Recursive spawn (real, offline)

    func testRecursiveSpawn_runsChildAndInjectsResult() async {
        ProviderManager.shared.currentProvider = SubScriptedProvider(responses: [
            "<spawn_team team=\"solo\">do the sub task</spawn_team>",  // parent lead, call 1
            "sub-team final answer",                                    // child solo agent
            "parent final answer"                                       // parent lead, call 2
        ])

        let engine = AgentLoopEngine.shared
        engine.reset()
        engine.setup(projectPath: tempDir.path, agents: [AgentLoopEngine.createUserSelectedAgent(role: .lead)])

        await engine.processMessage("parent task")

        let injected = engine.conversationHistory.contains { message in
            if case .user(let content, _, _) = message {
                return content.contains("Sub-team (solo) result:") && content.contains("sub-team final answer")
            }
            return false
        }
        XCTAssertTrue(injected, "the sub-team's result must be injected back into the parent context")

        let parentFinished = engine.conversationHistory.contains { message in
            if case .assistant(_, let content, _, _) = message { return content.contains("parent final answer") }
            return false
        }
        XCTAssertTrue(parentFinished, "parent continues and completes after the sub-team returns")
    }
}

// MARK: - Scripted provider (ordered canned responses, no network)

private final class SubScriptedProvider: AIProvider {
    let id = "sub-scripted"
    let name = "SubScripted"
    let iconName = "circle"
    let supportsStreaming = true
    let requiresAPIKey = false
    let apiKeySettingKey = "k"
    let availableModels: [AIModel] = []
    var selectedModel: AIModel?

    private let responses: [String]
    private var index = 0
    init(responses: [String]) { self.responses = responses }

    func refreshModels() async -> [AIModel] { [] }
    func checkStatus() async -> Bool { true }
    func validateAPIKey(_ key: String) async -> Bool { true }

    func sendMessage(messages: [ChatMessage], settings: ModelSettings, stream: Bool) async throws -> AsyncThrowingStream<String, Error> {
        let response = index < responses.count ? responses[index] : "done"
        index += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }
}
