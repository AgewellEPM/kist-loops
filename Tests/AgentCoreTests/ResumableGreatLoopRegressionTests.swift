import XCTest
@testable import AgentCore

private actor ResumableLoopProbe {
    struct Observation: Sendable {
        let cycle: Int
        let tokens: Int
        let noProgress: Int
        let remaining: Int?
        let checkpoints: [String: String]
        let effort: ProviderReasoningEffort
    }
    private var observations: [Observation] = []
    func record(_ request: ResumableGreatLoopCycleRequest) {
        observations.append(.init(cycle: request.control.cycle,
                                  tokens: request.control.tokensSpent,
                                  noProgress: request.control.consecutiveNoProgress,
                                  remaining: request.remainingTokens,
                                  checkpoints: request.control.childCheckpointIDs,
                                  effort: request.requestedEffort))
    }
    func values() -> [Observation] { observations }
}

private actor ResumableLoopCounter {
    private var value = 0
    func increment() { value += 1 }
    func count() -> Int { value }
}

final class ResumableGreatLoopRegressionTests: XCTestCase {
    func testResumeRestoresOuterCountersAndChildCheckpoints() async throws {
        let root = temporaryDirectory("resumable-loop")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root, clock: { 1_000 })
        var seed = ReasoningControlState(id: "loop", route: .planned,
                                         goalFingerprint: "goal", updatedAt: 0)
        seed.cycle = 2
        seed.tokensSpent = 100
        seed.consecutiveNoProgress = 1
        seed.childCheckpointIDs["existing"] = "child-1"
        _ = try await store.save(seed)
        let probe = ResumableLoopProbe()
        let runner = ResumableGreatLoopRunner(
            runID: "loop", route: .planned, goalFingerprint: "goal",
            caps: GreatLoopCaps(maxCycles: 10, maxTokens: 500, noProgressLimit: 3),
            store: store, effort: { _ in .deep }, clock: { 1_000 },
            runCycle: { request in
                await probe.record(request)
                let progress = ReasoningProgressReceipt(
                    id: "artifact-progress",
                    evidence: .artifact(.init(id: "artifact", path: "out",
                                              revision: "2", nodeID: "node")), at: 2)
                return .init(doneAndVerified: true, tokensSpent: 20,
                             progress: [progress], summary: "done",
                             childCheckpointIDs: ["new": "child-2"])
            })

        let decision = try await runner.run()
        XCTAssertTrue(decision.succeeded)
        let seen = await probe.values()
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.cycle, 2)
        XCTAssertEqual(seen.first?.tokens, 100)
        XCTAssertEqual(seen.first?.noProgress, 1)
        XCTAssertEqual(seen.first?.remaining, 400)
        XCTAssertEqual(seen.first?.checkpoints["existing"], "child-1")
        XCTAssertEqual(seen.first?.effort, .deep)
        let restoredState = try await store.load(runID: "loop")
        let stored = try XCTUnwrap(restoredState)
        XCTAssertEqual(stored.cycle, 3)
        XCTAssertEqual(stored.tokensSpent, 120)
        XCTAssertEqual(stored.consecutiveNoProgress, 0)
        XCTAssertEqual(stored.childCheckpointIDs,
                       ["existing": "child-1", "new": "child-2"])
    }

    func testTypedNoProgressStopsAtConfiguredLimit() async throws {
        let root = temporaryDirectory("resumable-no-progress")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        let counter = ResumableLoopCounter()
        let runner = ResumableGreatLoopRunner(
            runID: "stalled", route: .direct,
            caps: GreatLoopCaps(maxCycles: 10, maxTokens: 100, noProgressLimit: 2),
            store: store, effort: { _ in .light }, clock: { 0 },
            runCycle: { _ in
                await counter.increment()
                return .init(doneAndVerified: false, tokensSpent: 1,
                             progress: [], summary: "read-only success is not progress")
            })

        let decision = try await runner.run()
        guard case .stopNoProgress = decision else {
            return XCTFail("expected no-progress stop, got \(decision)")
        }
        let calls = await counter.count()
        XCTAssertEqual(calls, 2)
        let stalledState = try await store.load(runID: "stalled")
        let stored = try XCTUnwrap(stalledState)
        XCTAssertEqual(stored.cycle, 2)
        XCTAssertEqual(stored.consecutiveNoProgress, 2)
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
