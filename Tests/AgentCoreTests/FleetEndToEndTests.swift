import XCTest
import Foundation
@testable import AgentCore

/// THE WHOLE FLEET, end-to-end, against REAL git — launch → spawn (in-process) → commit → .fleet-done →
/// supervise → Foreman verify over real artifacts → forge-proof sign → merge gate. The "agent" is a
/// deterministic closure (writes a source file + a passing test.sh) standing in for the real cross-vendor
/// PlanExecuteLoop, so every SEAM is proven connected with real worktrees, real commits, a real test.sh,
/// and a real sealed ledger. XCTSkip if git is absent.
final class FleetEndToEndTests: XCTestCase {

    private var repo: URL!
    private var baseDir: URL!

    @discardableResult
    private func git(_ args: [String], cwd: URL) -> Int32? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + args
        p.currentDirectoryURL = cwd; let n = Pipe(); p.standardOutput = n; p.standardError = n
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return nil }
    }

    override func setUpWithError() throws {
        ForgeSeal.forceEphemeralKeyForTesting()
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString)")
        baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("e2ebase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        guard let rc = git(["init"], cwd: repo), rc == 0 else { throw XCTSkip("git not available") }
        _ = git(["config", "user.email", "t@t.test"], cwd: repo)
        _ = git(["config", "user.name", "Test"], cwd: repo)
        try "x\n".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        // A TRUSTED base verifier (committed before any worktree, so it's not agent-authored): it validates
        // the agent's actual output rather than trusting an agent-supplied script.
        try "#!/bin/sh\ngrep -q 'answer = 42' Feature.swift\n"
            .write(to: repo.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        _ = git(["add", "-A"], cwd: repo); _ = git(["commit", "-m", "init"], cwd: repo)
    }
    override func tearDownWithError() throws {
        // Best-effort: discard any leftover fleet worktrees, then remove temp trees.
        _ = git(["worktree", "prune"], cwd: repo)
        try? FileManager.default.removeItem(at: repo)
        try? FileManager.default.removeItem(at: baseDir)
    }

    /// A deterministic in-process "agent": writes ONLY a source file and commits — the trusted base test.sh
    /// (see setUp) then validates it. `passing` controls whether the agent writes the value the verifier
    /// expects. Stands in for the real PlanExecuteLoop so the wiring is tested without an LLM.
    private func fakeAgent(passing: Bool) -> InProcessAgentSpawner {
        InProcessAgentSpawner { _, wt in
            let feature = (wt.path as NSString).appendingPathComponent("Feature.swift")
            try? "let answer = \(passing ? 42 : 0)\n".write(toFile: feature, atomically: true, encoding: .utf8)
            _ = GitIsolation.commit(wt, message: "agent deliverable")
            return "wrote Feature.swift"
        }
    }

    /// Build a supervisor over the SAME per-fleet substrate `launchFleet` seeded (paths must match).
    private func supervisor(for launch: FleetLaunch, mergeRecorder: @escaping ([String]) -> Void) -> FleetSupervisor {
        let board = FleetBlackboardStore(fleetID: launch.fleetID, baseDir: baseDir)
        let inbox = FleetUpdateInbox(fleetID: launch.fleetID, baseDir: baseDir)
        let ledger = FleetSignoffLedger(baseDir: launch.fleetDir.appendingPathComponent("signoff"))
        let batons = FleetBatonStore(baseDir: launch.fleetDir)
        let foreman = Foreman(ledger: ledger, allowWorktreeHarness: true)
        return FleetSupervisor(
            board: board, inbox: inbox, ledger: ledger, batons: batons, foreman: foreman,
            maxSweeps: 100, nowEpoch: { 2000 }, writeSlice: { _, _ in true },
            waitBetweenSweeps: { try? await Task.sleep(nanoseconds: 10_000_000) },
            policy: FleetSupervisorPolicy(staleAfterSeconds: 10_000),
            merge: { _, _, branches, intBranch, _ in mergeRecorder(branches)
                     return .merged(integrationBranch: intBranch, worktreePath: "/int", branches: branches) })
    }

    func testGreenAgentRunsLaunchToSignToMerge() async throws {
        guard git(["rev-parse", "HEAD"], cwd: repo) == 0 else { throw XCTSkip("git not available") }

        // LAUNCH — real worktrees, the deterministic agent as the spawner.
        let orch = CaptainOrchestrator(spawner: fakeAgent(passing: true))
        let launch = await orch.launchFleet(goal: "add the feature", repo: repo.path,
                                            subtasks: [FleetSubtask(title: "feature", intent: "add answer")],
                                            maxAgents: 1, baseDir: baseDir, nowEpoch: 1000)
        XCTAssertEqual(launch.launchedCount, 1, "the agent launched in its own worktree")
        let agentID = launch.agents[0].agentID

        // SUPERVISE — the agent is running in-process in the background; the supervisor waits for
        // `.fleet-done`, then verifies the REAL artifacts and seals.
        var mergedBranches: [String] = []
        let sup = supervisor(for: launch, mergeRecorder: { mergedBranches = $0 })
        let result = await sup.supervise(goalID: launch.fleetID.uuidString)

        XCTAssertEqual(result.signed, 1, "the agent's REAL committed+green work was sealed")
        XCTAssertTrue(result.allSigned)
        let ledger = FleetSignoffLedger(baseDir: launch.fleetDir.appendingPathComponent("signoff"))
        XCTAssertTrue(ledger.signedOff(goalID: launch.fleetID.uuidString, agentID: agentID))

        // MERGE GATE — the signed in-lease branch joins (onto a fresh integration branch, never main).
        let merge = sup.joinSignedBranches(goalID: launch.fleetID.uuidString, base: "HEAD")
        guard case .merged = merge else { return XCTFail("expected merged, got \(merge)") }
        XCTAssertEqual(mergedBranches, [launch.agents[0].branch], "the verified branch is the one joined")
    }

    func testFailingAgentRunsLaunchToRejectNeverSigned() async throws {
        guard git(["rev-parse", "HEAD"], cwd: repo) == 0 else { throw XCTSkip("git not available") }

        let orch = CaptainOrchestrator(spawner: fakeAgent(passing: false))   // test.sh exits 1
        let launch = await orch.launchFleet(goal: "add the feature", repo: repo.path,
                                            subtasks: [FleetSubtask(title: "feature", intent: "add answer")],
                                            maxAgents: 1, baseDir: baseDir, nowEpoch: 1000)
        let agentID = launch.agents[0].agentID

        let sup = supervisor(for: launch, mergeRecorder: { _ in })
        let result = await sup.supervise(goalID: launch.fleetID.uuidString)

        XCTAssertEqual(result.signed, 0, "a failing test.sh can NEVER seal — even with a real commit")
        let ledger = FleetSignoffLedger(baseDir: launch.fleetDir.appendingPathComponent("signoff"))
        XCTAssertFalse(ledger.signedOff(goalID: launch.fleetID.uuidString, agentID: agentID))
        XCTAssertEqual(sup.joinSignedBranches(goalID: launch.fleetID.uuidString, base: "HEAD"), .nothingToMerge)
    }
}
