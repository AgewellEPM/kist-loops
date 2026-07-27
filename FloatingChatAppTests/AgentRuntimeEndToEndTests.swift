import XCTest
@testable import FloatingChatApp

/// End-to-end tests that drive the REAL UnifiedAgentRuntime loop with a scripted
/// provider (no network). These exercise process() / resume() / live re-plan
/// against the actual control flow — not just the DTO/store seams.
@MainActor
final class AgentRuntimeEndToEndTests: XCTestCase {

    private var tempDir: URL!

    /// Full snapshot of the shared runtime's mutable config, captured in setUp
    /// and restored in tearDown so these tests can't contaminate the others
    /// (the runtime is a shared singleton).
    private struct ConfigSnapshot {
        let provider: any AIProvider
        let store: CheckpointStore
        let maxIterations: Int
        let maxRetryAttempts: Int
        let maxReplanAttempts: Int
        let replanFailureThreshold: Int
        let requirePlanApproval: Bool
        let oneShotMode: Bool
        let planPreviewBeforeIterative: Bool
        let runTestsAfterWrite: Bool
        let autoInstallDependencies: Bool
        let enforceProjectPathForProjectTools: Bool
        let persistCheckpoints: Bool
        let projectPath: String
    }
    private var snapshot: ConfigSnapshot!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fca-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let rt = UnifiedAgentRuntime.shared
        snapshot = ConfigSnapshot(
            provider: ProviderManager.shared.currentProvider,
            store: rt.checkpointStore,
            maxIterations: rt.maxIterations,
            maxRetryAttempts: rt.maxRetryAttempts,
            maxReplanAttempts: rt.maxReplanAttempts,
            replanFailureThreshold: rt.replanFailureThreshold,
            requirePlanApproval: rt.requirePlanApproval,
            oneShotMode: rt.oneShotMode,
            planPreviewBeforeIterative: rt.planPreviewBeforeIterative,
            runTestsAfterWrite: rt.runTestsAfterWrite,
            autoInstallDependencies: rt.autoInstallDependencies,
            enforceProjectPathForProjectTools: rt.enforceProjectPathForProjectTools,
            persistCheckpoints: rt.persistCheckpoints,
            projectPath: rt.projectPath
        )
    }

    override func tearDownWithError() throws {
        let rt = UnifiedAgentRuntime.shared
        rt.reset()
        if let s = snapshot {
            ProviderManager.shared.currentProvider = s.provider
            rt.checkpointStore = s.store
            rt.maxIterations = s.maxIterations
            rt.maxRetryAttempts = s.maxRetryAttempts
            rt.maxReplanAttempts = s.maxReplanAttempts
            rt.replanFailureThreshold = s.replanFailureThreshold
            rt.requirePlanApproval = s.requirePlanApproval
            rt.oneShotMode = s.oneShotMode
            rt.planPreviewBeforeIterative = s.planPreviewBeforeIterative
            rt.runTestsAfterWrite = s.runTestsAfterWrite
            rt.autoInstallDependencies = s.autoInstallDependencies
            rt.enforceProjectPathForProjectTools = s.enforceProjectPathForProjectTools
            rt.persistCheckpoints = s.persistCheckpoints
            rt.projectPath = s.projectPath
        }
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    private func iter(_ type: String, tool: String? = nil, _ params: [String: Any] = [:]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let toolField = tool.map { "\"\($0)\"" } ?? "null"
        return "{\"thinking\":\"t\",\"next_action\":{\"type\":\"\(type)\",\"tool\":\(toolField),\"parameters\":\(json)},\"message\":\"m\"}"
    }

    private func configure(_ rt: UnifiedAgentRuntime, responses: [String], maxIterations: Int) {
        ProviderManager.shared.currentProvider = ScriptedProvider(responses: responses)
        rt.checkpointStore = CheckpointStore(directory: tempDir)
        rt.persistCheckpoints = true
        rt.planPreviewBeforeIterative = false   // skip the batch preview call
        rt.oneShotMode = false
        rt.maxIterations = maxIterations
        rt.runTestsAfterWrite = false           // keep e2e deterministic, no tool side trips
        rt.autoInstallDependencies = false
    }

    /// Flush the runtime's deferred `postUpdate` tasks (1 ms delayed) so they
    /// don't land during the next test's setup.
    private func flushDeferredUpdates() async {
        try? await Task.sleep(nanoseconds: 30_000_000) // 30 ms
    }

    // MARK: - Full run

    func testFullRun_completesAndCheckpoints() async {
        let rt = UnifiedAgentRuntime.shared
        configure(rt, responses: [
            iter("observe", ["check": "filesystem"]),
            iter("done", ["summary": "all set"])
        ], maxIterations: 5)

        let result = await rt.process("do a thing")

        XCTAssertTrue(result.isSuccess, "scripted run should complete")
        let saved = rt.checkpointStore.list()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.status, .completed)
        XCTAssertGreaterThanOrEqual(saved.first?.actionResults.count ?? 0, 1, "the observe action should be recorded")
        await flushDeferredUpdates()
    }

    // MARK: - Crash → resume

    func testResume_continuesInterruptedRunFromCheckpoint() async throws {
        let rt = UnifiedAgentRuntime.shared
        let store = CheckpointStore(directory: tempDir)

        // Realistic crash fixture: built the way the real loop would leave it —
        // one completed action recorded, status still .running (never finalized).
        let firstAction = ExecutableAction(type: .observe, tool: nil, parameters: ["check": "filesystem"], description: "observe filesystem", stepIndex: 0)
        let firstResult = ActionExecutionResult(action: firstAction, success: true, output: "Project path: Not set", error: nil, duration: 0.01, metadata: nil)

        var interrupted = AgentCheckpoint(iterativeFor: "long task", projectPath: "", maxIterations: 5)
        interrupted.iterationCount = 1
        interrupted.currentActionIndex = 0
        interrupted.status = .running
        interrupted.actionResults = [CheckpointActionResult(firstResult)]
        interrupted.conversation = [
            ConversationTurn(role: .user, content: "long task"),
            ConversationTurn(role: .assistant, content: "{\"next_action\":{\"type\":\"observe\"}}"),
            ConversationTurn(role: .system, content: "Action: observe filesystem\nResult: SUCCESS")
        ]
        try store.save(interrupted)

        ProviderManager.shared.currentProvider = ScriptedProvider(responses: [iter("done", ["summary": "finished on resume"])])
        rt.checkpointStore = store
        rt.persistCheckpoints = true
        rt.planPreviewBeforeIterative = false

        let result = await rt.resume(checkpointId: interrupted.id)

        XCTAssertTrue(result.isSuccess, "interrupted run should resume and complete")
        let after = try store.load(id: interrupted.id)
        XCTAssertEqual(after.status, .completed)
        XCTAssertEqual(after.iterationCount, 2, "resume CONTINUED from iteration 1, not restarted")
        await flushDeferredUpdates()
    }

    func testResume_refusesRunThatAlreadyHitItsCap() async throws {
        let rt = UnifiedAgentRuntime.shared
        let store = CheckpointStore(directory: tempDir)

        var maxed = AgentCheckpoint(iterativeFor: "x", projectPath: "", maxIterations: 2)
        maxed.iterationCount = 2
        maxed.status = .failed
        try store.save(maxed)

        rt.checkpointStore = store
        let result = await rt.resume(checkpointId: maxed.id)
        XCTAssertFalse(result.isSuccess, "a capped run should not resume into more iterations")
        await flushDeferredUpdates()
    }

    // MARK: - Single-flight

    func testProcess_rejectsConcurrentRun() async {
        let rt = UnifiedAgentRuntime.shared
        rt.isProcessing = true
        defer { rt.isProcessing = false }

        let result = await rt.process("second run")
        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.message.contains("already in progress"))
    }

    // MARK: - Live re-plan end-to-end

    func testLiveReplan_firesAfterRepeatedFailuresAndCompletes() async {
        let rt = UnifiedAgentRuntime.shared
        // edit_file with NO params fails deterministically ("Missing edit
        // parameters") regardless of the tool registry. Two failures trip the
        // threshold; response 3 is the re-plan's revised strategy; response 4 ends.
        configure(rt, responses: [
            iter("edit_file"),
            iter("edit_file"),
            "1. Try a completely different approach\n2. Verify state first",
            iter("done", ["summary": "recovered"])
        ], maxIterations: 8)
        rt.maxReplanAttempts = 2
        rt.replanFailureThreshold = 2

        let result = await rt.process("task that keeps failing")

        XCTAssertTrue(result.isSuccess, "should recover and complete after re-plan")
        let saved = rt.checkpointStore.list().first
        XCTAssertEqual(saved?.replanCount, 1, "exactly one live re-plan should have fired")
        let injected = saved?.conversation.contains { $0.content.contains("REVISED STRATEGY") } ?? false
        XCTAssertTrue(injected, "the revised strategy should be injected into the working context")
        await flushDeferredUpdates()
    }
}

// MARK: - Scripted provider (returns canned responses in order, no network)

private final class ScriptedProvider: AIProvider {
    let id = "scripted"
    let name = "Scripted"
    let iconName = "circle"
    let supportsStreaming = true
    let requiresAPIKey = false
    let apiKeySettingKey = "scripted_key"
    let availableModels: [AIModel] = []
    var selectedModel: AIModel?

    private let responses: [String]
    private var index = 0

    init(responses: [String]) { self.responses = responses }

    func refreshModels() async -> [AIModel] { [] }
    func checkStatus() async -> Bool { true }
    func validateAPIKey(_ key: String) async -> Bool { true }

    func sendMessage(messages: [ChatMessage], settings: ModelSettings, stream: Bool) async throws -> AsyncThrowingStream<String, Error> {
        let response = index < responses.count
            ? responses[index]
            : "{\"next_action\":{\"type\":\"done\",\"parameters\":{\"summary\":\"done\"}},\"message\":\"m\"}"
        index += 1
        return AsyncThrowingStream { continuation in
            continuation.yield(response)
            continuation.finish()
        }
    }
}
