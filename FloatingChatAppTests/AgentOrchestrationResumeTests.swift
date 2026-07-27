import XCTest
@testable import FloatingChatApp

/// Tests for orchestration resume + checkpoint persistence (AgentLoopEngine).
/// All paths here are offline — resume guard paths return before any LLM call.
final class AgentOrchestrationResumeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fca-orch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeAgents() -> [AgentConfig] {
        [
            AgentConfig(id: "a1", name: "Lead", provider: "claude", model: "m", role: .lead, color: "#fff", systemPrompt: nil),
            AgentConfig(id: "a2", name: "Coder", provider: "deepseek", model: "m", role: .coder, color: "#000", systemPrompt: nil)
        ]
    }

    // MARK: - Checkpoint round-trip

    func testOrchestrationCheckpoint_roundTripsCursorAndPayload() throws {
        let store = OrchestrationCheckpointStore(directory: tempDir)
        var cp = OrchestrationCheckpoint(mode: .sequential, userMessage: "build a feature", projectPath: "/p", agents: makeAgents())
        cp.phase = .sequential
        cp.sequentialIndex = 1
        cp.conversationHistory = [.user("hi"), .assistant(agentId: "a1", content: "done step 1")]
        try store.save(cp)

        let loaded = try store.load(id: cp.id)
        XCTAssertEqual(loaded.mode, .sequential)
        XCTAssertEqual(loaded.phase, .sequential)
        XCTAssertEqual(loaded.sequentialIndex, 1)
        XCTAssertEqual(loaded.agents.count, 2)
        XCTAssertEqual(loaded.agents.first?.role, .lead)
        XCTAssertEqual(loaded.conversationHistory.count, 2)
    }

    func testOrchestrationCheckpoint_pendingToolBracket() throws {
        let store = OrchestrationCheckpointStore(directory: tempDir)
        var cp = OrchestrationCheckpoint(mode: .sequential, userMessage: "x", projectPath: "/p", agents: makeAgents())
        cp.pendingTool = "write_file"
        try store.save(cp)
        XCTAssertEqual(try store.load(id: cp.id).pendingTool, "write_file")
    }

    func testOrchestrationCheckpoint_debateCursor() throws {
        let store = OrchestrationCheckpointStore(directory: tempDir)
        var cp = OrchestrationCheckpoint(mode: .debate, userMessage: "argue", projectPath: "/p", agents: makeAgents())
        cp.phase = .debateRounds
        cp.debateRound = 2
        cp.consensusReached = false
        try store.save(cp)

        let loaded = try store.load(id: cp.id)
        XCTAssertEqual(loaded.debateRound, 2)
        XCTAssertEqual(loaded.consensusReached, false)
    }

    // MARK: - Resumable filtering

    func testOrchestrationStore_resumableFilter() throws {
        let store = OrchestrationCheckpointStore(directory: tempDir)
        var running = OrchestrationCheckpoint(mode: .debate, userMessage: "x", projectPath: "/p", agents: makeAgents())
        var done = OrchestrationCheckpoint(mode: .sequential, userMessage: "y", projectPath: "/p", agents: makeAgents())
        running.status = .running; running.phase = .debateRounds
        done.status = .completed; done.phase = .done
        try store.save(running); try store.save(done)

        let ids = Set(store.resumable().map(\.id))
        XCTAssertTrue(ids.contains(running.id))
        XCTAssertFalse(ids.contains(done.id), "completed/done runs are not resumable")
    }

    // MARK: - Generic store

    func testJSONDirectoryStore_overwriteAndDelete() throws {
        let store = JSONDirectoryStore<OrchestrationCheckpoint>(directory: tempDir)
        var cp = OrchestrationCheckpoint(mode: .sequential, userMessage: "a", projectPath: "/p", agents: makeAgents())
        try store.save(cp)
        cp.title = "updated title"
        try store.save(cp)   // overwrite existing
        XCTAssertEqual(try store.load(id: cp.id).title, "updated title")

        try store.delete(id: cp.id)
        XCTAssertThrowsError(try store.load(id: cp.id))
    }

    func testJSONDirectoryStore_skipsCorruptFiles() throws {
        let store = JSONDirectoryStore<OrchestrationCheckpoint>(directory: tempDir)
        let good = OrchestrationCheckpoint(mode: .debate, userMessage: "g", projectPath: "/p", agents: makeAgents())
        try store.save(good)
        try "{not json".data(using: .utf8)!.write(to: tempDir.appendingPathComponent("corrupt.json"))
        XCTAssertEqual(store.list().count, 1)
    }

    // MARK: - Environmental failure classification

    @MainActor
    func testEngine_classifiesEnvironmentalFailure() {
        let engine = AgentLoopEngine.shared
        XCTAssertTrue(engine.isEnvironmentalFailure(ToolResult(success: false, output: "", error: "Project path not set")))
        XCTAssertFalse(engine.isEnvironmentalFailure(ToolResult(success: false, output: "", error: "compile error: missing brace")))
    }

    // MARK: - Resume guards (offline — return before any LLM call)

    @MainActor
    func testResumeOrchestration_rejectedWhileRunning() async {
        let engine = AgentLoopEngine.shared
        let saved = engine.isProcessing
        defer { engine.isProcessing = saved }
        engine.isProcessing = true
        let ok = await engine.resumeOrchestration(checkpointId: "anything")
        XCTAssertFalse(ok, "must refuse to resume while a run is in progress")
    }

    @MainActor
    func testResume_rejectsUnsupportedModeAndNonResumable() async throws {
        let engine = AgentLoopEngine.shared
        let savedStore = engine.orchestrationStore
        defer { engine.orchestrationStore = savedStore; engine.reset() }

        let store = OrchestrationCheckpointStore(directory: tempDir)
        engine.orchestrationStore = store

        // Parallel resume is unsupported (would duplicate side effects).
        var parallel = OrchestrationCheckpoint(mode: .parallel, userMessage: "x", projectPath: "/p", agents: makeAgents())
        parallel.status = .running; parallel.phase = .parallelDone
        try store.save(parallel)
        let r1 = await engine.resumeOrchestration(checkpointId: parallel.id)
        XCTAssertFalse(r1, "parallel resume must be refused")

        // Completed run is not resumable.
        var done = OrchestrationCheckpoint(mode: .sequential, userMessage: "y", projectPath: "/p", agents: makeAgents())
        done.status = .completed; done.phase = .done
        try store.save(done)
        let r2 = await engine.resumeOrchestration(checkpointId: done.id)
        XCTAssertFalse(r2, "completed run must not resume")

        // Unknown id.
        let r3 = await engine.resumeOrchestration(checkpointId: "does-not-exist")
        XCTAssertFalse(r3)
    }
}
