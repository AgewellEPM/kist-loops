import XCTest
@testable import FloatingChatApp

@MainActor
final class ResumePickerViewModelTests: XCTestCase {

    private var checkpointDir: URL!
    private var orchestrationDir: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fca-resume-ui-\(UUID().uuidString)", isDirectory: true)
        checkpointDir = base.appendingPathComponent("checkpoints")
        orchestrationDir = base.appendingPathComponent("orchestrations")
        try FileManager.default.createDirectory(at: checkpointDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: orchestrationDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: checkpointDir.deletingLastPathComponent())
    }

    func testReload_listsBothKinds_excludesUnsafeOrchestration_newestFirst() throws {
        let cpStore = CheckpointStore(directory: checkpointDir)
        let orStore = OrchestrationCheckpointStore(directory: orchestrationDir)

        var single = AgentCheckpoint(iterativeFor: "single run", projectPath: "/p", maxIterations: 5)
        single.status = .paused
        single.updatedAt = Date(timeIntervalSince1970: 100)
        try cpStore.save(single)

        var seq = OrchestrationCheckpoint(mode: .sequential, userMessage: "team seq", projectPath: "/p", agents: [])
        seq.status = .running; seq.phase = .sequential
        seq.updatedAt = Date(timeIntervalSince1970: 300)
        try orStore.save(seq)

        // Parallel is resumable-by-status but UNSAFE to resume → must be hidden.
        var parallel = OrchestrationCheckpoint(mode: .parallel, userMessage: "team par", projectPath: "/p", agents: [])
        parallel.status = .running; parallel.phase = .parallelDone
        parallel.updatedAt = Date(timeIntervalSince1970: 200)
        try orStore.save(parallel)

        let viewModel = ResumePickerViewModel(checkpointStore: cpStore, orchestrationStore: orStore)
        viewModel.reload()

        XCTAssertEqual(viewModel.runs.count, 2, "parallel orchestration must be excluded")
        XCTAssertEqual(viewModel.runs.first?.id, seq.id, "newest first")
        XCTAssertTrue(viewModel.runs.contains { $0.kind == .single && $0.id == single.id })
        XCTAssertFalse(viewModel.runs.contains { $0.id == parallel.id })
    }

    func testReload_orchestrationOnly_excludesSingleAgentRuns() throws {
        let cpStore = CheckpointStore(directory: checkpointDir)
        let orStore = OrchestrationCheckpointStore(directory: orchestrationDir)

        var single = AgentCheckpoint(iterativeFor: "s", projectPath: "/p", maxIterations: 3)
        single.status = .paused
        try cpStore.save(single)
        var seq = OrchestrationCheckpoint(mode: .sequential, userMessage: "t", projectPath: "/p", agents: [])
        seq.status = .running; seq.phase = .sequential
        try orStore.save(seq)

        // Presented from the team chat → orchestration only (single-agent runs
        // would resume invisibly in a different runtime).
        let viewModel = ResumePickerViewModel(allowedKinds: [.orchestration], checkpointStore: cpStore, orchestrationStore: orStore)
        viewModel.reload()
        XCTAssertEqual(viewModel.runs.count, 1)
        XCTAssertEqual(viewModel.runs.first?.kind, .orchestration)
    }

    func testDiscard_removesRunFromListAndStore() throws {
        let cpStore = CheckpointStore(directory: checkpointDir)
        let orStore = OrchestrationCheckpointStore(directory: orchestrationDir)

        var single = AgentCheckpoint(iterativeFor: "r", projectPath: "/p", maxIterations: 3)
        single.status = .failed
        try cpStore.save(single)

        let viewModel = ResumePickerViewModel(checkpointStore: cpStore, orchestrationStore: orStore)
        viewModel.reload()
        XCTAssertEqual(viewModel.runs.count, 1)

        viewModel.discard(viewModel.runs[0])
        XCTAssertTrue(viewModel.runs.isEmpty)
        XCTAssertTrue(cpStore.resumable().isEmpty)
    }
}
