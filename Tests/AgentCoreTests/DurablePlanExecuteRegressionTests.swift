import XCTest
@testable import AgentCore

private actor DurablePlanProbe {
    private var attempts: [String: [Int]] = [:]
    func record(_ request: DurablePlanNodeRequest) {
        attempts[request.node.id, default: []].append(request.attempt)
    }
    func snapshot() -> [String: [Int]] { attempts }
}

private enum DeliberateStoreFailure: Error, Equatable { case unavailable }

private actor FailingReasoningControlStore: ReasoningControlStateStoring {
    func load(runID: String) async throws -> ReasoningControlState? {
        throw DeliberateStoreFailure.unavailable
    }
    func save(_ state: ReasoningControlState) async throws -> ReasoningControlState {
        throw DeliberateStoreFailure.unavailable
    }
    func update(runID: String, create: ReasoningControlState?,
                _ mutation: ReasoningStateMutation) async throws -> ReasoningControlState {
        throw DeliberateStoreFailure.unavailable
    }
}

final class DurablePlanExecuteRegressionTests: XCTestCase {
    func testResumeSkipsSucceededNodeAndRecoversInterruptedActiveNode() async throws {
        let root = temporaryDirectory("durable-resume")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        let nodes = [
            ReasoningPlanNode(id: "a", title: "already done"),
            ReasoningPlanNode(id: "b", title: "resume me", dependencies: ["a"]),
        ]
        var seed = ReasoningControlState(id: "plan-run", route: .planned,
                                         goalFingerprint: "goal")
        try seed.installPlanNodes(nodes, acceptedIDs: Set(nodes.map(\.id)))
        try seed.activatePlanNode("a")
        try seed.recordPlanNodeExecution(.init(nodeID: "a", outcome: .succeeded,
                                               summary: "a complete"))
        try seed.activatePlanNode("b")
        _ = try await store.save(seed)
        let probe = DurablePlanProbe()
        let loop = DurablePlanExecuteLoop(runID: "plan-run", goalFingerprint: "goal",
                                          store: store)

        let outcome = try await loop.run(plan: .init(id: "plan", nodes: nodes)) { request in
            await probe.record(request)
            return .init(nodeID: request.node.id, outcome: .succeeded,
                         summary: "resumed successfully")
        }

        XCTAssertEqual(outcome.status, .completed)
        let attempts = await probe.snapshot()
        XCTAssertNil(attempts["a"])
        XCTAssertEqual(attempts["b"], [2])
        XCTAssertEqual(outcome.control.recoveryCount, 1)
        XCTAssertEqual(outcome.control.planNodes["a"]?.phase, .succeeded)
        XCTAssertEqual(outcome.control.planNodes["b"]?.phase, .succeeded)
    }

    func testTargetedReplanRetainsSucceededNodes() async throws {
        let root = temporaryDirectory("durable-replan")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AtomicReasoningControlStore(directory: root)
        let nodes = [ReasoningPlanNode(id: "a", title: "stable success"),
                     ReasoningPlanNode(id: "b", title: "repair target")]
        let probe = DurablePlanProbe()
        let loop = DurablePlanExecuteLoop(runID: "repair-run", store: store, maxReplans: 2)

        let outcome = try await loop.run(
            plan: .init(id: "plan", nodes: nodes),
            execute: { request in
                await probe.record(request)
                if request.node.id == "b" && request.attempt == 1 {
                    return .init(nodeID: "b", outcome: .failed, summary: "first failure")
                }
                return .init(nodeID: request.node.id, outcome: .succeeded,
                             summary: "completed")
            },
            repair: { request, receipt in
                XCTAssertEqual(request.node.id, "b")
                XCTAssertEqual(receipt.outcome, .failed)
                let alternative = RepairAlternative(id: "retry", summary: "retry b only",
                                                    retryOriginalNode: true)
                return NodeScopedRepairReceipt(
                    nodeID: "b", trigger: .init(kind: .failedAction,
                                                 summary: receipt.summary),
                    alternatives: [alternative], selectedAlternativeID: alternative.id)
            })

        XCTAssertEqual(outcome.status, .completed)
        let attempts = await probe.snapshot()
        XCTAssertEqual(attempts["a"], [1])
        XCTAssertEqual(attempts["b"], [1, 2])
        XCTAssertEqual(outcome.control.planNodes["a"]?.phase, .succeeded)
        XCTAssertEqual(outcome.control.planNodes["a"]?.attempts, 1)
        XCTAssertEqual(outcome.control.repairReceipts.count, 1)
        XCTAssertEqual(Set(outcome.control.repairReceipts[0].retainedAcceptedNodeIDs),
                       Set(["a", "b"]))
    }

    func testStoreFailureStopsBeforeAnyPlanNodeExecutes() async throws {
        let probe = DurablePlanProbe()
        let loop = DurablePlanExecuteLoop(runID: "store-failure",
                                          store: FailingReasoningControlStore())
        do {
            _ = try await loop.run(plan: .init(nodes: [
                ReasoningPlanNode(id: "n", title: "must not run"),
            ])) { request in
                await probe.record(request)
                return .init(nodeID: request.node.id, outcome: .succeeded, summary: "wrong")
            }
            XCTFail("store failures must fail closed")
        } catch let error as DeliberateStoreFailure {
            XCTAssertEqual(error, .unavailable)
        }
        let attempts = await probe.snapshot()
        XCTAssertTrue(attempts.isEmpty)
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }
}
