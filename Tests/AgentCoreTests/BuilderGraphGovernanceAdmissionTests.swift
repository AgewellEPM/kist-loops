import XCTest
@testable import AgentCore

final class BuilderGraphGovernanceAdmissionTests: XCTestCase {
    private enum TestFailure: Error { case shouldNotExecute }

    private actor InvocationLog {
        private var workers = 0
        private var nodeVerifiers = 0
        private var finalVerifiers = 0
        private var reviewers = 0
        func worker() { workers += 1 }
        func nodeVerifier() { nodeVerifiers += 1 }
        func finalVerifier() { finalVerifiers += 1 }
        func reviewer() { reviewers += 1 }
        func values() -> (Int, Int, Int, Int) {
            (workers, nodeVerifiers, finalVerifiers, reviewers)
        }
    }

    private struct ContractProvider: BuilderNodeExecutionContractProvider {
        let identity: BuilderNodeContractProviderIdentity
        func sealedContract(for request: BuilderNodeContractRequest) async throws
            -> SealedBuilderExecutionContract {
            throw TestFailure.shouldNotExecute
        }
    }

    private struct ObservationProvider: BuilderNodeObservationSourceProvider {
        func source(for request: BuilderNodeObservationSourceRequest) async throws
            -> any BuilderStageObservationSource {
            NeverObservationSource()
        }
    }

    private struct NeverObservationSource: BuilderStageObservationSource {
        func prepare(_ context: BuilderStageContext) async throws -> BuilderStageBaseline {
            throw TestFailure.shouldNotExecute
        }
        func observe(_ request: BuilderStageObservationRequest) async throws
            -> BuilderStageObservation {
            throw TestFailure.shouldNotExecute
        }
        func rollback(_ request: BuilderRollbackRequest) async throws
            -> BuilderRollbackObservation {
            throw TestFailure.shouldNotExecute
        }
    }

    private func graph(path: String = "src") throws -> BuilderGraph {
        try .init(nodes: [BuilderNode(
            id: "mutation", objective: "mutate",
            resources: [.init(path: path, access: .write)])])
    }

    private var policy: BuilderGraphExecutionPolicy {
        .init(nodeClasses: ["mutation": .mutation])
    }

    private var identity: BuilderNodeContractProviderIdentity {
        try! .init(
            providerID: "trusted-contract-provider",
            implementationFingerprint: String(repeating: "1", count: 64))
    }

    func testAdmissionBindsTopologyResourcesPolicyProviderAndNodeSet() throws {
        let original = try graph()
        let admission = try BuilderGraphGovernanceAdmission.make(
            graph: original, policy: policy, providerIdentity: identity)
        XCTAssertTrue(admission.governanceRequired)
        XCTAssertEqual(admission.governedNodeIDs, ["mutation"])
        XCTAssertNoThrow(try admission.validate(matches: admission))

        let changedResources = try BuilderGraphGovernanceAdmission.make(
            graph: graph(path: "other"), policy: policy, providerIdentity: identity)
        XCTAssertThrowsError(try admission.validate(matches: changedResources))

        let readGraph = try BuilderGraph(nodes: [BuilderNode(
            id: "mutation", objective: "mutate",
            resources: [.init(path: "src", access: .read)])])
        let readOnly = try BuilderGraphGovernanceAdmission.make(
            graph: readGraph,
            policy: .init(nodeClasses: ["mutation": .readOnly]),
            providerIdentity: identity)
        XCTAssertThrowsError(try admission.validate(matches: readOnly))

        let otherProvider = try BuilderNodeContractProviderIdentity(
            providerID: "other", implementationFingerprint: String(repeating: "2", count: 64))
        let changedProvider = try BuilderGraphGovernanceAdmission.make(
            graph: original, policy: policy, providerIdentity: otherProvider)
        XCTAssertThrowsError(try admission.validate(matches: changedProvider))
    }

    func testLegacyAcceptedMutationWithoutAdmissionFailsClosed() async throws {
        try await assertAcceptedMutationResumeRejected(snapshotAdmission: nil)
    }

    func testAcceptedMutationWithAdmissionButMissingSelectedContractFailsClosed() async throws {
        let graph = try graph()
        let admission = try BuilderGraphGovernanceAdmission.make(
            graph: graph, policy: policy, providerIdentity: identity)
        try await assertAcceptedMutationResumeRejected(snapshotAdmission: admission)
    }

    func testFreshRawMutationCannotReachFinalVerificationReviewOrReceipt() async throws {
        let graph = try graph()
        let contract = BuilderContract(
            id: "raw-parent", objective: "raw mutation", allowedPaths: ["src"],
            doneWhen: ["verified"])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-raw-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BuilderJSONStore(fileURL: root.appendingPathComponent("run.json"))
        let log = InvocationLog()
        XCTAssertThrowsError(try BuilderRun(
            contract: contract, graph: graph, store: store,
            execute: { request in
                await log.worker()
                return BuilderWorkerReceipt(
                    nodeID: request.node.id, provider: "worker", model: "model",
                    changedPaths: ["src/file"],
                    checks: [.init(name: "build", passed: true)])
            },
            verify: { request in
                switch request {
                case .node(_, let node, _, _):
                    await log.nodeVerifier()
                    return BuilderVerifierReceipt(
                        scope: .node(node.id), provider: "verifier", model: "model",
                        deterministic: true, passed: true,
                        checks: [.init(name: "node", passed: true)])
                case .final:
                    await log.finalVerifier()
                    return BuilderVerifierReceipt(
                        scope: .final, provider: "verifier", model: "model",
                        deterministic: true, passed: true,
                        checks: [.init(name: "final", passed: true)])
                }
            },
            review: { _ in
                await log.reviewer()
                return BuilderReviewReceipt(
                    provider: "reviewer", model: "other", accepted: true,
                    checks: [.init(name: "review", passed: true)])
            }))
        let calls = await log.values()
        XCTAssertEqual(calls.0, 0)
        XCTAssertEqual(calls.1, 0)
        XCTAssertEqual(calls.2, 0)
        XCTAssertEqual(calls.3, 0)
        let snapshot = try await store.load()
        XCTAssertNil(snapshot?.reviewAttempt)
        XCTAssertNil(snapshot?.finalReceipt)
    }

    private func assertAcceptedMutationResumeRejected(
        snapshotAdmission: BuilderGraphGovernanceAdmission?
    ) async throws {
        let graph = try graph()
        let admission = try BuilderGraphGovernanceAdmission.make(
            graph: graph, policy: policy, providerIdentity: identity)
        let contract = BuilderContract(
            id: "parent", objective: "governed mutation", allowedPaths: ["src"],
            doneWhen: ["verified"], governanceAdmission: admission)
        let worker = BuilderWorkerReceipt(
            nodeID: "mutation", provider: "worker", model: "model",
            changedPaths: ["src/file"], checks: [.init(name: "build", passed: true)])
        let proof = BuilderVerifierReceipt(
            scope: .node("mutation"), provider: "verifier", model: "model",
            deterministic: true, passed: true, checks: [.init(name: "verify", passed: true)])
        let review = BuilderReviewReceipt(
            provider: "reviewer", model: "different", accepted: true,
            checks: [.init(name: "review", passed: true)])
        let final = BuilderFinalReceipt(
            contractID: contract.id, route: .direct, workers: [worker],
            verification: BuilderVerifierReceipt(
                scope: .final, provider: "verifier", model: "model",
                deterministic: true, passed: true,
                checks: [.init(name: "final", passed: true)]),
            review: review, accepted: true, completedAt: Date())
        var state = BuilderNodeState(phase: .accepted)
        state.attempts = 1; state.worker = worker; state.verification = proof
        var snapshot = BuilderRunSnapshot(
            contractID: contract.id, route: .direct,
            nodeStates: ["mutation": state], finalReceipt: final, updatedAt: Date())
        snapshot.governanceAdmission = snapshotAdmission
        snapshot.selectedExecutionContracts = nil

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BuilderJSONStore(fileURL: root.appendingPathComponent("run.json"))
        try await store.create(snapshot)
        let loadedSnapshot = try await store.load()
        let loaded = try XCTUnwrap(loadedSnapshot)
        XCTAssertEqual(loaded.finalReceipt?.accepted, true)
        XCTAssertEqual(loaded.governanceAdmission, snapshotAdmission)
        XCTAssertNil(loaded.selectedExecutionContracts)
        let provider = ContractProvider(identity: identity)
        let run = try BuilderRun(
            contract: contract, graph: graph, store: store, resumeExisting: true,
            graphExecutionPolicy: policy,
            nodeExecutionContractProvider: provider,
            nodeObservationSourceProvider: ObservationProvider(),
            execute: { _ in throw TestFailure.shouldNotExecute },
            verify: { _ in throw TestFailure.shouldNotExecute },
            review: { _ in throw TestFailure.shouldNotExecute })
        do {
            _ = try await run.run()
            XCTFail("accepted mutation resume bypassed governance admission")
        } catch {
            XCTAssertTrue(error is BuilderRunError || error is BuilderGraphGovernanceAdmissionError)
        }
    }
}
