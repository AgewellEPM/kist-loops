import XCTest
import Foundation
@testable import AgentCore

/// The launcher: validate proposed subtasks into disjoint leases → isolate worktrees → seed the board →
/// spawn each worker + mint a held baton per working agent. Uses a REAL temp repo (for the isGitRepo guard) but injects a fake
/// worktree maker + a recording spawner + a fixed dir-tree, so NO real worktrees/agents are spawned.
final class CaptainOrchestratorTests: XCTestCase {

    private var repo: URL!
    private var baseDir: URL!

    @discardableResult
    private func git(_ args: [String], cwd: URL) -> Int32? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + args
        p.currentDirectoryURL = cwd; let n = Pipe(); p.standardOutput = n; p.standardError = n
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return nil }
    }

    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("captain-\(UUID().uuidString)")
        baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("captbase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        guard let rc = git(["init"], cwd: repo), rc == 0 else { throw XCTSkip("git not available") }
        _ = git(["config", "user.email", "t@t.test"], cwd: repo)
        _ = git(["config", "user.name", "Test"], cwd: repo)
        try "x\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: repo); _ = git(["commit", "-m", "init"], cwd: repo)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repo); try? FileManager.default.removeItem(at: baseDir)
    }

    // A recording spawner that never runs real work.
    private final class RecordingSpawner: AgentSpawner, @unchecked Sendable {
        private let queue = DispatchQueue(label: "captain-tests.recording-spawner")
        private var storedCalls: [(task: String, wt: GitWorktree)] = []
        var calls: [(task: String, wt: GitWorktree)] { queue.sync { storedCalls } }
        let ok: (GitWorktree) -> Bool
        let onSpawn: (GitWorktree) -> Void
        init(ok: @escaping (GitWorktree) -> Bool = { _ in true },
             onSpawn: @escaping (GitWorktree) -> Void = { _ in }) {
            self.ok = ok
            self.onSpawn = onSpawn
        }
        func spawn(task: String, worktree: GitWorktree) async -> Bool {
            onSpawn(worktree)
            queue.sync { storedCalls.append((task, worktree)) }
            return ok(worktree)
        }
    }

    private final class RecordingAssignedSpawner: AssignedAgentSpawner, @unchecked Sendable {
        private let queue = DispatchQueue(label: "captain-tests.recording-assigned-spawner")
        private var storedCalls: [(
            task: String, wt: GitWorktree, assignment: ModelAssignmentDecision
        )] = []
        var calls: [(task: String, wt: GitWorktree, assignment: ModelAssignmentDecision)] {
            queue.sync { storedCalls }
        }
        func spawn(task: String, worktree: GitWorktree) async -> Bool { false }
        func spawn(task: String, worktree: GitWorktree, assignment: ModelAssignmentDecision) async -> Bool {
            queue.sync { storedCalls.append((task, worktree, assignment)) }
            return true
        }
    }

    private actor BarrierSpawner: AgentSpawner {
        struct Metrics: Sendable {
            let maximumActive: Int
            let branches: [String]
        }

        private var active = 0
        private var maximumActive = 0
        private var branches: [String] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func spawn(task: String, worktree: GitWorktree) async -> Bool {
            active += 1
            maximumActive = max(maximumActive, active)
            branches.append(worktree.branch)
            if active >= 2 {
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
            } else {
                await withCheckedContinuation { waiters.append($0) }
            }
            active -= 1
            return true
        }

        func metrics() -> Metrics {
            Metrics(maximumActive: maximumActive, branches: branches)
        }
    }

    private final class FailingBlackboardStore: FleetBlackboardPersisting, @unchecked Sendable {
        private let failOnSeeds: Set<Int>
        private(set) var seeds: [FleetBlackboard] = []
        private var attempts = 0
        private var lastError: String?

        init(failOnSeeds: Set<Int>) {
            self.failOnSeeds = failOnSeeds
        }

        func seed(_ initial: FleetBlackboard) -> Bool {
            attempts += 1
            if failOnSeeds.contains(attempts) {
                lastError = "injected seed failure \(attempts)"
                return false
            }
            seeds.append(initial)
            lastError = nil
            return true
        }

        func lastSaveError() -> String? { lastError }
    }

    private let knownDirs: Set<String> = ["", "Core", "Lex", "Gen", "Other"]
    private func fixedTree() -> (String, Set<String>) { ("Core\nLex\nGen\nOther", knownDirs) }

    private func orchestrator(_ spawner: AgentSpawner,
                              makeWT: @escaping (String, String) -> GitWorktree? = { repo, label in
                                  GitWorktree(repo: repo, path: "/wt/\(label)", branch: "mythos/\(label)", base: "base") },
                              makeBlackboardStore: @escaping @Sendable (UUID, URL) -> any FleetBlackboardPersisting = {
                                  FleetBlackboardStore(fleetID: $0, baseDir: $1)
                              }
    ) -> CaptainOrchestrator {
        CaptainOrchestrator(spawner: spawner,
                            makeWorktree: makeWT,
                            dirTree: { _ in self.fixedTree() },
                            makeBlackboardStore: makeBlackboardStore)
    }

    private func sub(_ t: String, _ scope: [String], crit: String = "") -> FleetSubtask {
        FleetSubtask(title: t, intent: "do \(t)", scopeGlobs: scope, acceptanceCriterion: crit)
    }

    // MARK: happy path

    func testLaunchesOneAgentPerDisjointSubtask() async {
        let spawner = RecordingSpawner()
        let launch = await orchestrator(spawner).launchFleet(
            goal: "build it", repo: repo.path,
            subtasks: [sub("parser", ["Core/*"]), sub("lexer", ["Lex/*"]), sub("gen", ["Gen/*"])],
            maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)

        XCTAssertEqual(launch.agents.count, 3)
        XCTAssertEqual(launch.launchedCount, 3)
        XCTAssertTrue(launch.supervisionReady)
        XCTAssertEqual(spawner.calls.count, 3, "one spawn per subtask")
        XCTAssertEqual(launch.board.cells.filter { $0.status == .working }.count, 3)
        // disjoint leases preserved
        XCTAssertEqual(Set(launch.agents.map { $0.scopeGlobs.first }), ["Core/*", "Lex/*", "Gen/*"])
        // one held baton per working agent, persisted under the per-fleet dir
        let batons = FleetBatonStore(baseDir: launch.fleetDir).all()
        XCTAssertEqual(batons.count, 3)
        XCTAssertTrue(batons.allSatisfy { $0.state == .held })
    }

    func testDisjointPreparedWorkersActuallyOverlapAndPublishDeterministically() async {
        let spawner = BarrierSpawner()
        let launch = await orchestrator(spawner).launchFleet(
            goal: "build it", repo: repo.path,
            subtasks: [sub("parser", ["Core/*"]), sub("lexer", ["Lex/*"])],
            maxAgents: 2, baseDir: baseDir, nowEpoch: 1000)

        let metrics = await spawner.metrics()
        XCTAssertEqual(metrics.maximumActive, 2, "two disjoint armed workers must overlap")
        XCTAssertEqual(Set(metrics.branches), Set(["mythos/parser", "mythos/lexer"]))
        XCTAssertEqual(launch.agents.map(\.title), ["parser", "lexer"])
        XCTAssertEqual(launch.board.cells.map(\.status), [.working, .working])
        XCTAssertTrue(launch.supervisionReady)
        let batons = FleetBatonStore(baseDir: launch.fleetDir).all()
        XCTAssertEqual(batons.count, 2)
        XCTAssertTrue(batons.allSatisfy { $0.state == .held })
    }

    func testBriefCarriesScopeDoneProtocolAndCrew() async {
        let spawner = RecordingSpawner()
        _ = await orchestrator(spawner).launchFleet(
            goal: "G", repo: repo.path, subtasks: [sub("parser", ["Core/*"]), sub("lexer", ["Lex/*"])],
            maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)
        let parserBrief = spawner.calls.first { $0.wt.branch.hasSuffix("parser") }!.task
        XCTAssertTrue(parserBrief.contains("Core/*"), "the brief names the agent's validated lease")
        XCTAssertTrue(parserBrief.contains("DONE PROTOCOL"), "the load-bearing done protocol is present")
        XCTAssertTrue(parserBrief.contains(".fleet-done"))
        XCTAssertTrue(parserBrief.contains("Do NOT write"), "the runtime owns the done sentinel after worker exit")
        XCTAssertTrue(parserBrief.contains("lexer owns"), "the crew (no-touch set) is listed")
        XCTAssertTrue(parserBrief.contains("NOT merge"), "the no-merge contract is present")
    }

    // MARK: cap

    func testFleetSizeIsHardCapped() async {
        let spawner = RecordingSpawner()
        let disjoint = [
            sub("t0", ["Core/*"]),
            sub("t1", ["Lex/*"]),
            sub("t2", ["Gen/*"]),
            sub("t3", ["Other/*"]),
        ]
        let launch = await orchestrator(spawner).launchFleet(
            goal: "G", repo: repo.path,
            subtasks: disjoint, maxAgents: 2, baseDir: baseDir, nowEpoch: 1000)
        XCTAssertEqual(launch.agents.count, 2, "never a runaway swarm")
        XCTAssertEqual(spawner.calls.count, 2)
    }

    // MARK: scope validation

    func testOverlappingScopesBlockBeforeLaunchAndAreFlagged() async {
        let spawner = RecordingSpawner()
        let launch = await orchestrator(spawner).launchFleet(
            goal: "G", repo: repo.path,
            subtasks: [sub("a", ["Core/*"]), sub("b", ["Core/*"])],   // overlapping lease
            maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)
        XCTAssertTrue(launch.agents.isEmpty, "a multi-agent fleet with repaired/colliding leases must not launch")
        XCTAssertTrue(spawner.calls.isEmpty, "no worker should start when the Captain lease gate rejects the plan")
        XCTAssertFalse(launch.scopeIssues.isEmpty, "the clearing is surfaced, never silent")
        XCTAssertTrue(launch.summary.contains("Scope repair required"))
    }

    func testAssignedSpawnerReceivesPerTaskModelAssignment() async {
        let spawner = RecordingAssignedSpawner()
        let roles = RoleBindings(default: ProviderBinding(providerId: "mimo"))
            .binding(.planner, to: ProviderBinding(providerId: "openai"))
            .binding(.coder, to: ProviderBinding(providerId: "deepseek"))
            .binding(.critic, to: ProviderBinding(providerId: "gemini"))
        let assignment = ModelAssignmentDecision(taskTitle: "parser", roles: roles,
                                                 worker: ProviderBinding(providerId: "deepseek"),
                                                 confidence: 0.8,
                                                 reason: "test assignment",
                                                 capabilityTags: ["coding"])
        let assigned = AssignedFleetTask(subtask: sub("parser", ["Core/*"]),
                                         roles: roles, assignment: assignment)

        let launch = await orchestrator(spawner).launchFleet(
            goal: "G", repo: repo.path, assignedTasks: [assigned],
            maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)

        XCTAssertEqual(launch.launchedCount, 1)
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(spawner.calls.first?.assignment.worker.providerId, "deepseek")
        XCTAssertTrue(spawner.calls.first?.task.contains("MODEL ASSIGNMENT") == true)
    }

    // MARK: failure modes

    func testWorktreeFailureMarksAgentFailedNoBaton() async {
        let spawner = RecordingSpawner()
        // 2nd worktree fails.
        let orch = orchestrator(spawner, makeWT: { repo, label in
            label == "b" ? nil : GitWorktree(repo: repo, path: "/wt/\(label)", branch: "mythos/\(label)", base: "base")
        })
        let launch = await orch.launchFleet(goal: "G", repo: repo.path,
            subtasks: [sub("a", ["Core/*"]), sub("b", ["Lex/*"])], maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)
        XCTAssertEqual(launch.launchedCount, 1)
        XCTAssertFalse(launch.supervisionReady, "a partial launch must not report the whole fleet as supervision-ready")
        XCTAssertTrue(launch.scopeIssues.contains { $0.contains("agent not running b") })
        XCTAssertEqual(launch.agents.filter { !$0.launched }.count, 1, "the worktree-failed agent is recorded")
        XCTAssertEqual(launch.board.cells.count, 1, "a worktree-failed agent gets no cell (it never started)")
        XCTAssertEqual(launch.board.cells.first?.status, .working)
        XCTAssertEqual(FleetBatonStore(baseDir: launch.fleetDir).all().count, 1, "one baton for the one working agent")
    }

    func testBlackboardIsSeededBeforeFirstSpawn() async {
        final class Box {
            var sawBoard = false
            var sawHeldBaton = false
        }
        let box = Box()
        let spawner = RecordingSpawner(onSpawn: { _ in
            let children = (try? FileManager.default.contentsOfDirectory(at: self.baseDir,
                                                                         includingPropertiesForKeys: nil)) ?? []
            box.sawBoard = children.contains {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("blackboard.json").path)
            }
            box.sawHeldBaton = children.contains {
                FleetBatonStore(baseDir: $0).all().contains { $0.state == .held }
            }
        })

        let launch = await orchestrator(spawner).launchFleet(goal: "G", repo: repo.path,
            subtasks: [sub("a", ["Core/*"])], maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)

        XCTAssertEqual(launch.launchedCount, 1)
        XCTAssertTrue(box.sawBoard, "the durable blackboard must exist before the first worker spawn")
        XCTAssertTrue(box.sawHeldBaton, "the durable baton must exist before the first worker spawn")
    }

    func testBlackboardSeedFailurePreventsSpawnsAndBatons() async throws {
        let blockedBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("captbase-blocked-\(UUID().uuidString)")
        try "file, not directory".write(to: blockedBase, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: blockedBase) }
        let spawner = RecordingSpawner()

        let launch = await orchestrator(spawner).launchFleet(goal: "G", repo: repo.path,
            subtasks: [sub("a", ["Core/*"]), sub("b", ["Lex/*"])],
            maxAgents: 5, baseDir: blockedBase, nowEpoch: 1000)

        XCTAssertEqual(spawner.calls.count, 0, "no worker can start without a durable blackboard")
        XCTAssertEqual(launch.launchedCount, 0)
        XCTAssertFalse(launch.supervisionReady)
        XCTAssertTrue(launch.summary.contains("no agents started"))
        XCTAssertTrue(launch.scopeIssues.contains { $0.contains("blackboard seed failed") })
        XCTAssertTrue(FleetBatonStore(baseDir: launch.fleetDir).all().isEmpty)
    }

    func testLaunchStatusPersistenceFailureMarksUnstartedCellsFailed() async {
        let spawner = RecordingSpawner()
        let blackboard = FailingBlackboardStore(failOnSeeds: [2])
        let launch = await orchestrator(spawner, makeBlackboardStore: { _, _ in blackboard })
            .launchFleet(goal: "G", repo: repo.path,
                         subtasks: [sub("a", ["Core/*"]), sub("b", ["Lex/*"])],
                         maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)

        XCTAssertEqual(spawner.calls.count, 0, "no worker should spawn when working-status persistence fails")
        XCTAssertFalse(launch.supervisionReady)
        XCTAssertTrue(launch.scopeIssues.contains { $0.contains("launch status persistence failed") })
        XCTAssertTrue(launch.scopeIssues.contains { $0.contains("agent not running a") })
        XCTAssertEqual(launch.board.cells.map(\.status), [.failed, .failed])
        XCTAssertEqual(blackboard.seeds.last?.cells.map(\.status), [.failed, .failed],
                       "Captain should persist an explicit abort board when the first launch status write fails")
    }

    func testLaterLaunchStatusPersistenceFailureLeavesStartedAgentWorkingAndFailsRest() async {
        let spawner = RecordingSpawner()
        let blackboard = FailingBlackboardStore(failOnSeeds: [3])
        let launch = await orchestrator(spawner, makeBlackboardStore: { _, _ in blackboard })
            .launchFleet(goal: "G", repo: repo.path,
                         subtasks: [sub("a", ["Core/*"]), sub("b", ["Lex/*"]), sub("c", ["Gen/*"])],
                         maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)

        XCTAssertEqual(spawner.calls.count, 1, "already-durable workers may run, but no later worker should start")
        XCTAssertEqual(launch.launchedCount, 1)
        XCTAssertFalse(launch.supervisionReady)
        XCTAssertTrue(launch.scopeIssues.contains { $0.contains("launch status persistence failed") })
        XCTAssertTrue(launch.scopeIssues.contains { $0.contains("agent not running b") })
        XCTAssertTrue(launch.scopeIssues.contains { $0.contains("agent not running c") })
        XCTAssertEqual(launch.board.cells.map(\.status), [.working, .failed, .failed])
        XCTAssertEqual(blackboard.seeds.last?.cells.map(\.status), [.working, .failed, .failed],
                       "Captain should not leave later prepared cells pending after an abort")
    }

    func testSpawnFailureMarksAgentFailed() async {
        let spawner = RecordingSpawner(ok: { _ in false })
        let launch = await orchestrator(spawner).launchFleet(goal: "G", repo: repo.path,
            subtasks: [sub("a", ["Core/*"])], maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)
        XCTAssertEqual(launch.launchedCount, 0)
        XCTAssertFalse(launch.supervisionReady)
        XCTAssertEqual(launch.board.cells.first?.status, .failed)
        XCTAssertEqual(FleetBatonStore(baseDir: launch.fleetDir).all().map(\.state), [.failed],
                       "a pre-spawn held baton is closed out when the worker refuses to start")
    }

    func testNonGitRepoLaunchesNothing() async {
        let notRepo = FileManager.default.temporaryDirectory.appendingPathComponent("notrepo-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: notRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: notRepo) }
        let launch = await orchestrator(RecordingSpawner()).launchFleet(
            goal: "G", repo: notRepo.path, subtasks: [sub("a", ["Core/*"])], maxAgents: 5, baseDir: baseDir, nowEpoch: 1000)
        XCTAssertTrue(launch.agents.isEmpty)
        XCTAssertTrue(launch.summary.contains("isn't a git repo"))
    }

    // MARK: unique integration branch (Codex HIGH — no collision with a stale "integration")

    func testIntegrationBranchIsUniquePerFleetNeverTheHardcodedName() async {
        let l1 = await orchestrator(RecordingSpawner()).launchFleet(
            goal: "G", repo: repo.path, subtasks: [sub("a", ["Core/*"])], maxAgents: 1, baseDir: baseDir, nowEpoch: 1000)
        let l2 = await orchestrator(RecordingSpawner()).launchFleet(
            goal: "G", repo: repo.path, subtasks: [sub("a", ["Core/*"])], maxAgents: 1, baseDir: baseDir, nowEpoch: 1000)
        XCTAssertNotEqual(l1.board.integrationBranch, l2.board.integrationBranch, "each fleet gets its own integration branch")
        XCTAssertNotEqual(l1.board.integrationBranch, "integration", "never the collision-prone hard-coded name")
        XCTAssertTrue(l1.board.integrationBranch.contains(String(l1.fleetID.uuidString.prefix(8))),
                      "the branch is scoped to this fleet's id, so a stale branch can never spoof success")
    }

    // MARK: pure helpers

    func testDeriveScopeContext() {
        let (snapshot, dirs) = CaptainOrchestrator.deriveScopeContext(
            fromFiles: ["Sources/Core/A.swift", "Sources/Lex/B.swift", "README.md"])
        XCTAssertTrue(dirs.contains("Sources/Core"))
        XCTAssertTrue(dirs.contains(""), "root is always known")
        XCTAssertFalse(dirs.contains("README.md"), "a root-level file is not a dir")
        XCTAssertTrue(snapshot.contains("Sources/Core"))
    }

    func testChooseSubtasksFloorsAtOne() {
        XCTAssertEqual(CaptainOrchestrator.chooseSubtasks([sub("a", [])], maxAgents: 0).count, 1, "floored at 1")
        XCTAssertEqual(CaptainOrchestrator.chooseSubtasks([], maxAgents: 5).count, 0)
    }
}
