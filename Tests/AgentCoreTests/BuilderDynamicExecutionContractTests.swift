import Foundation
import XCTest
@testable import AgentCore

final class BuilderDynamicExecutionContractTests: XCTestCase {
    func testPlanResultDerivesMutationContractImmediatelyBeforeExecute() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(mode: .dependencyRequest, log: log)
        let source = DynamicTestObservationSource(log: log)
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "plan", objective: "plan"),
            BuilderNode(
                id: "build", objective: "build", dependencies: ["plan"],
                resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 0)
        ])
        let contract = dynamicParentContract()
        let run = try dynamicRun(
            contract: contract, graph: graph,
            policy: .init(nodeClasses: ["plan": .readOnly, "build": .mutation]),
            provider: provider, source: source, log: log,
            planRequest: "Sources/Feature/New.swift")

        let receipt = try await run.run()
        let providerAttempts = await log.providerAttempts()
        let providerDependencies = await log.providerDependencies()
        let workerNodes = await log.workerNodes()

        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(providerAttempts, ["build:1"])
        XCTAssertEqual(providerDependencies, [["plan"]])
        XCTAssertEqual(Set(workerNodes), Set(["plan", "build"]))
    }

    func testDependencyCannotWidenParentOrNodePathAuthority() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(mode: .dependencyRequest, log: log)
        let source = DynamicTestObservationSource(log: log)
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "plan", objective: "plan"),
            BuilderNode(
                id: "build", objective: "build", dependencies: ["plan"],
                resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 0)
        ])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["plan": .readOnly, "build": .mutation]),
            provider: provider, source: source, log: log,
            planRequest: "Sources/FeatureExtra/Exfil.swift")

        await assertAsyncThrows { _ = try await run.run() }
        let providerAttempts = await log.providerAttempts()
        let workerNodes = await log.workerNodes()

        XCTAssertEqual(providerAttempts, ["build:1"])
        XCTAssertEqual(workerNodes, ["plan"])
    }

    func testWorkerCannotWidenSealedPathsAndDependentRemainsBlocked() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let source = DynamicTestObservationSource(log: log, mirrorWorkerPaths: true)
        let graph = try BuilderGraph(nodes: [
            BuilderNode(
                id: "build", objective: "build",
                resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 0),
            BuilderNode(id: "consume", objective: "consume", dependencies: ["build"])
        ])
        let store = BuilderJSONStore(fileURL: dynamicTemporaryFile())
        let mutationSource = try dynamicIsolatedSource(beside: store.fileURL)
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation, "consume": .readOnly]),
            provider: provider, source: source, log: log,
            widenedWorkerNode: "build", store: store,
            mutationSource: mutationSource)

        await assertAsyncThrows { _ = try await run.run() }
        let workerNodes = await log.workerNodes()

        XCTAssertEqual(workerNodes, ["build"])
        let restored = try BuilderWorkspaceManifestScanner.scan(
            root: mutationSource.projectRoot,
            limits: try BuilderWorkspaceTraversalLimits(), mode: .restoration)
        XCTAssertTrue(restored.entries.isEmpty)
    }

    func testNoMutationRetriesOnceWithSameContractFreshTelemetryAndSucceeds() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 1)])
        let store = BuilderJSONStore(fileURL: dynamicTemporaryFile())
        let mutationSource = try dynamicIsolatedSource(beside: store.fileURL)
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            store: store, mutationSource: mutationSource,
            noOpMutationAttempts: [1])

        let receipt = try await run.run()
        let loadedSnapshot = try await store.load()
        let snapshot = try XCTUnwrap(loadedSnapshot)
        let selection = try XCTUnwrap(snapshot.selectedExecutionContracts?["build"])
        let runtime = try BuilderExecutionGovernanceRuntime(
            sealed: selection.sealedContract, source: mutationSource, beside: store.fileURL,
            contractSealReference: selection.contractSealReference)
        let budget = try await runtime.ledger.snapshot()
        let buildUsage = try XCTUnwrap(
            budget.stages.first(where: { $0.stage == .build })?.usage)
        let workerAttempts = await log.workerAttempts()
        let providerAttempts = await log.providerAttempts()
        let capturedReview = await log.lastReviewRequest()
        let reviewRequest = try XCTUnwrap(capturedReview)
        let promotion = try XCTUnwrap(reviewRequest.promotionReceipts.first)

        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(workerAttempts, ["build:1", "build:2"])
        XCTAssertEqual(providerAttempts, ["build:1", "build:2"])
        XCTAssertEqual(snapshot.nodeStates["build"]?.attempts, 2)
        XCTAssertEqual(selection.attempt, 2)
        XCTAssertEqual(reviewRequest.promotionReceipts.count, 1)
        XCTAssertEqual(reviewRequest.acceptedAttempts["build"], 2)
        XCTAssertEqual(reviewRequest.selectedContractFingerprints["build"],
                       selection.contractFingerprint)
        XCTAssertEqual(promotion.attempt, 2)
        XCTAssertEqual(promotion.contractFingerprint, selection.contractFingerprint)
        XCTAssertEqual(promotion.verifierSubjectDigest,
                       reviewRequest.verification.subjectDigest)
        XCTAssertTrue(promotion.hasValidReceiptDigest)
        XCTAssertEqual(buildUsage.tokens, 4,
                       "both fresh attempt route observations must remain charged")
        XCTAssertEqual(
            try Data(contentsOf: mutationSource.projectRoot
                .appendingPathComponent("Sources/Feature/New.swift")),
            Data("dynamic-build".utf8))
    }

    func testNoMutationDoesNotRetryWithoutSealedProviderBudget() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log, maxTokens: 2)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 1)])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            noOpMutationAttempts: [1])

        await assertAsyncThrows { _ = try await run.run() }
        let workerAttempts = await log.workerAttempts()
        let providerAttempts = await log.providerAttempts()
        XCTAssertEqual(workerAttempts, ["build:1"])
        XCTAssertEqual(providerAttempts, ["build:1"])
    }

    func testUndeclaredMutationIsTerminalEvenWhenNodeHasRetryCapacity() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 1)])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            widenedWorkerNode: "build")

        await assertAsyncThrows { _ = try await run.run() }
        let workerAttempts = await log.workerAttempts()
        let providerAttempts = await log.providerAttempts()
        XCTAssertEqual(workerAttempts, ["build:1"])
        XCTAssertEqual(providerAttempts, ["build:1"])
    }

    func testNoMutationRetryIsCappedAtOne() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 1)])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            noOpMutationAttempts: [1, 2])

        await assertAsyncThrows { _ = try await run.run() }
        let workerAttempts = await log.workerAttempts()
        let providerAttempts = await log.providerAttempts()
        XCTAssertEqual(workerAttempts, ["build:1", "build:2"])
        XCTAssertEqual(providerAttempts, ["build:1", "build:2"])
    }

    func testNoMutationRetryRejectsAlternativeSealedAuthorityBeforeSecondWorker() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .retryDrift("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 1)])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            noOpMutationAttempts: [1])

        await assertAsyncThrows { _ = try await run.run() }
        let workerAttempts = await log.workerAttempts()
        let providerAttempts = await log.providerAttempts()
        XCTAssertEqual(workerAttempts, ["build:1"])
        XCTAssertEqual(providerAttempts, ["build:1", "build:2"])
    }

    func testReadOnlyReceiptCannotHideTrustedWorkspaceMutation() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let source = DynamicTestObservationSource(
            log: log, hiddenReadOnlyMutationNodes: ["inspect"])
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "inspect", objective: "inspect", retryLimit: 0),
            BuilderNode(id: "consume", objective: "consume", dependencies: ["inspect"])
        ])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["inspect": .readOnly, "consume": .readOnly]),
            provider: provider, source: source, log: log)

        await assertAsyncThrows { _ = try await run.run() }
        let workerNodes = await log.workerNodes()
        let rollbackCount = await log.rollbackCount()
        let providerAttempts = await log.providerAttempts()

        XCTAssertEqual(workerNodes, ["inspect"])
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(providerAttempts, [])
    }

    func testProviderNodeSubstitutionFailsBeforeTargetWorkerLaunch() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(mode: .wrongNode("plan"), log: log)
        let source = DynamicTestObservationSource(log: log)
        let graph = try BuilderGraph(nodes: [
            BuilderNode(id: "plan", objective: "plan"),
            BuilderNode(
                id: "build", objective: "build", dependencies: ["plan"],
                resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 0)
        ])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["plan": .readOnly, "build": .mutation]),
            provider: provider, source: source, log: log)

        await assertAsyncThrows { _ = try await run.run() }
        let workerNodes = await log.workerNodes()

        XCTAssertEqual(workerNodes, ["plan"])
    }

    func testMutationGraphRejectsMissingScopedObservationProvider() throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)])])

        XCTAssertThrowsError(try BuilderRun(
            contract: dynamicParentContract(), graph: graph,
            store: BuilderJSONStore(fileURL: dynamicTemporaryFile()),
            graphExecutionPolicy: .init(nodeClasses: ["build": .mutation]),
            nodeExecutionContractProvider: provider,
            execute: { _ in fatalError("worker must not launch") },
            verify: { _ in fatalError("verifier must not launch") },
            review: { _ in fatalError("reviewer must not launch") }
        ))
    }

    func testPersistedSelectionRejectsProviderDriftAndTamper() throws {
        let identity = try dynamicProviderIdentity("a")
        let sealed = try dynamicSealedContract(
            builderContractID: "parent-contract", nodeID: "build",
            path: "Sources/Feature/New.swift")
        let selection = try BuilderSelectedNodeExecutionContract(
            nodeID: "build", attempt: 1,
            providerIdentity: identity, sealedContract: sealed)

        XCTAssertThrowsError(try selection.validate(
            builderContractID: "parent-contract", graphNodeIDs: ["build"],
            expectedNodeID: "build", expectedAttempt: 1,
            providerIdentity: dynamicProviderIdentity("b"),
            parentAllowedPaths: ["Sources/Feature"],
            nodeWriteClaims: ["Sources/Feature"]))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as? [String: Any])
        var sealedObject = try XCTUnwrap(object["sealedContract"] as? [String: Any])
        sealedObject["fingerprint"] = dynamicDigest("f")
        object["sealedContract"] = sealedObject
        let tamperedData = try JSONSerialization.data(withJSONObject: object)
        let tampered = try JSONDecoder().decode(
            BuilderSelectedNodeExecutionContract.self, from: tamperedData)
        XCTAssertThrowsError(try tampered.validate(
            builderContractID: "parent-contract", graphNodeIDs: ["build"],
            expectedNodeID: "build", expectedAttempt: 1,
            providerIdentity: identity,
            parentAllowedPaths: ["Sources/Feature"],
            nodeWriteClaims: ["Sources/Feature"]))
    }

    func testCrashAfterPreparedReusesSelectionBeforeNewAttempt() async throws {
        let log = DynamicBuilderLog()
        let identity = try dynamicProviderIdentity("a")
        let provider = DynamicTestContractProvider(
            identity: identity, mode: .fixed("Sources/Feature/New.swift"), log: log)
        let node = BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)], retryLimit: 0)
        let graph = try BuilderGraph(nodes: [node])
        let parent = dynamicParentContract(checkpointIdentity: "dynamic-resume")
        let sealed = try dynamicSealedContract(
            builderContractID: parent.id, nodeID: node.id,
            path: "Sources/Feature/New.swift")
        let selection = try BuilderSelectedNodeExecutionContract(
            nodeID: node.id, attempt: 1,
            providerIdentity: identity, sealedContract: sealed)
        let store = BuilderJSONStore(fileURL: dynamicTemporaryFile())
        let source = try dynamicIsolatedSource(beside: store.fileURL)
        let readOnlySource = DynamicTestObservationSource(log: log)
        var state = BuilderNodeState(phase: .running)
        state.attempts = 1
        let policy = BuilderGraphExecutionPolicy(nodeClasses: [node.id: .mutation])
        var snapshot = BuilderRunSnapshot(
            contractID: parent.id,
            checkpointIdentity: parent.checkpointIdentity,
            route: parent.routeHint.resolve(),
            nodeStates: [node.id: state],
            finalReceipt: nil,
            updatedAt: Date(),
            usage: nil,
            reviewAttempt: nil,
            selectedExecutionContracts: [node.id: selection])
        snapshot.parentContractFingerprint = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(parent), as: UTF8.self))
        snapshot.graphFingerprint = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(graph), as: UTF8.self))
        snapshot.governanceAdmission = try BuilderGraphGovernanceAdmission.make(
            graph: graph, policy: policy, providerIdentity: identity)
        try await store.create(snapshot)

        let runtime = try BuilderExecutionGovernanceRuntime(
            sealed: sealed, source: source, beside: store.fileURL,
            contractSealReference: selection.contractSealReference)
        let baseline = try await source.prepare(.init(
            contract: sealed.contract, node: node, attempt: 1, stage: .build))
        _ = try await runtime.checkpoints.prepare(
            nodeID: node.id, attempt: 1, baseline: baseline)

        let run = try dynamicRun(
            contract: parent, graph: graph,
            policy: policy,
            provider: provider, source: readOnlySource, log: log,
            store: store, resumeExisting: true, mutationSource: source)
        let receipt = try await run.run()
        let providerAttempts = await log.providerAttempts()

        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(providerAttempts, ["build:2"])
    }

    func testAcceptedReviewAccountsActualTelemetryExactlyOnce() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)])])
        let store = BuilderJSONStore(fileURL: dynamicTemporaryFile())
        let mutationSource = try dynamicIsolatedSource(beside: store.fileURL)
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            store: store, mutationSource: mutationSource)

        let receipt = try await run.run()
        let loaded = try await store.load()
        let snapshot = try XCTUnwrap(loaded)
        let selection = try XCTUnwrap(snapshot.selectedExecutionContracts?["build"])
        let runtime = try BuilderExecutionGovernanceRuntime(
            sealed: selection.sealedContract, source: mutationSource, beside: store.fileURL,
            contractSealReference: selection.contractSealReference)
        let budget = try await runtime.ledger.snapshot()
        let usage = try XCTUnwrap(budget.stages.first {
            $0.stage == .review
        }?.usage)
        let reviewInvocations = await log.reviewInvocationCount()

        XCTAssertTrue(receipt.accepted)
        XCTAssertEqual(reviewInvocations, 1)
        XCTAssertEqual(usage.tokens, 2)
    }

    func testMissingReviewStageDeniesBeforeReviewerInvocation() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log,
            includeReviewStageAuthority: false)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)])])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            includeReviewStageAuthority: false)

        await assertAsyncThrows { _ = try await run.run() }
        let reviewInvocations = await log.reviewInvocationCount()
        XCTAssertEqual(reviewInvocations, 0)
    }

    func testExhaustedReviewStageDeniesBeforeReviewerInvocation() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log, maxTokens: 4)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)])])
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            executionContractMaxTokens: 4)

        await assertAsyncThrows { _ = try await run.run() }
        let reviewInvocations = await log.reviewInvocationCount()
        XCTAssertEqual(reviewInvocations, 0)
    }

    func testRejectedReviewStillAccountsActualTelemetry() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)])])
        let store = BuilderJSONStore(fileURL: dynamicTemporaryFile())
        let mutationSource = try dynamicIsolatedSource(beside: store.fileURL)
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            store: store, mutationSource: mutationSource, reviewAccepted: false)

        await assertAsyncThrows { _ = try await run.run() }
        let loaded = try await store.load()
        let snapshot = try XCTUnwrap(loaded)
        let selection = try XCTUnwrap(snapshot.selectedExecutionContracts?["build"])
        let runtime = try BuilderExecutionGovernanceRuntime(
            sealed: selection.sealedContract, source: mutationSource, beside: store.fileURL,
            contractSealReference: selection.contractSealReference)
        let budget = try await runtime.ledger.snapshot()
        let usage = try XCTUnwrap(budget.stages.first {
            $0.stage == .review
        }?.usage)
        let reviewInvocations = await log.reviewInvocationCount()

        XCTAssertEqual(reviewInvocations, 1)
        XCTAssertEqual(usage.tokens, 2)
    }

    func testPostPromotionFinalVerifierFailureRollsBackAndClearsPendingAcceptance() async throws {
        let log = DynamicBuilderLog()
        let provider = try DynamicTestContractProvider(
            mode: .fixed("Sources/Feature/New.swift"), log: log)
        let graph = try BuilderGraph(nodes: [BuilderNode(
            id: "build", objective: "build",
            resources: [.init(path: "Sources/Feature", access: .write)])])
        let store = BuilderJSONStore(fileURL: dynamicTemporaryFile())
        let mutationSource = try dynamicIsolatedSource(beside: store.fileURL)
        let run = try dynamicRun(
            contract: dynamicParentContract(), graph: graph,
            policy: .init(nodeClasses: ["build": .mutation]),
            provider: provider, source: DynamicTestObservationSource(log: log), log: log,
            store: store, mutationSource: mutationSource,
            failFinalVerificationInvocation: 3)

        await assertAsyncThrows { _ = try await run.run() }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            mutationSource.projectRoot.appendingPathComponent("Sources/Feature/New.swift").path))
        let loadedSnapshot = try await store.load()
        let snapshot = try XCTUnwrap(loadedSnapshot)
        XCTAssertFalse(snapshot.reviewAccepted)
        XCTAssertNil(snapshot.commitEpoch)
        XCTAssertFalse(snapshot.finalizationPending)
        XCTAssertNil(snapshot.pendingFinalReceipt)
        XCTAssertNil(snapshot.finalReceipt)
        XCTAssertEqual(snapshot.nodeStates["build"]?.phase, .failed)
    }
}

private enum DynamicProviderMode: Sendable {
    case fixed(String)
    case dependencyRequest
    case wrongNode(String)
    case retryDrift(String)
}

private actor DynamicBuilderLog {
    private var providerAttemptValues: [String] = []
    private var providerDependencyValues: [[String]] = []
    private var workerNodeValues: [String] = []
    private var workerAttemptValues: [String] = []
    private var rollbackValue = 0
    private var workspaceRoots: [String: String] = [:]
    private var lastReviewRequestValue: BuilderReviewRequest?
    private var reviewInvocationValue = 0
    private var finalVerificationInvocationValue = 0

    func recordProvider(_ request: BuilderNodeContractRequest) {
        providerAttemptValues.append("\(request.node.id):\(request.attempt)")
        providerDependencyValues.append(request.dependencies.map(\.node.id).sorted())
    }
    func recordWorker(_ nodeID: String, attempt: Int) {
        workerNodeValues.append(nodeID)
        workerAttemptValues.append("\(nodeID):\(attempt)")
    }
    func recordWorkspace(_ nodeID: String, rootPath: String) {
        workspaceRoots[nodeID] = rootPath
    }
    func recordRollback() { rollbackValue += 1 }
    func recordReview(_ request: BuilderReviewRequest) {
        lastReviewRequestValue = request
        reviewInvocationValue += 1
    }
    func providerAttempts() -> [String] { providerAttemptValues }
    func providerDependencies() -> [[String]] { providerDependencyValues }
    func workerNodes() -> [String] { workerNodeValues }
    func workerAttempts() -> [String] { workerAttemptValues }
    func rollbackCount() -> Int { rollbackValue }
    func workspace(_ nodeID: String) -> String? { workspaceRoots[nodeID] }
    func lastReviewRequest() -> BuilderReviewRequest? { lastReviewRequestValue }
    func reviewInvocationCount() -> Int { reviewInvocationValue }
    func recordFinalVerification() -> Int {
        finalVerificationInvocationValue += 1
        return finalVerificationInvocationValue
    }
}

private actor DynamicTestContractProvider: BuilderNodeExecutionContractProvider {
    nonisolated let identity: BuilderNodeContractProviderIdentity
    private let mode: DynamicProviderMode
    private let log: DynamicBuilderLog
    private let maxTokens: Int
    private let includeReviewStageAuthority: Bool

    init(mode: DynamicProviderMode, log: DynamicBuilderLog, maxTokens: Int = 10_000,
         includeReviewStageAuthority: Bool = true) throws {
        self.identity = try dynamicProviderIdentity("a")
        self.mode = mode
        self.log = log
        self.maxTokens = maxTokens
        self.includeReviewStageAuthority = includeReviewStageAuthority
    }

    init(identity: BuilderNodeContractProviderIdentity,
         mode: DynamicProviderMode, log: DynamicBuilderLog) {
        self.identity = identity
        self.mode = mode
        self.log = log
        self.maxTokens = 10_000
        self.includeReviewStageAuthority = true
    }

    func sealedContract(for request: BuilderNodeContractRequest) async throws
        -> SealedBuilderExecutionContract {
        await log.recordProvider(request)
        let nodeID: String
        let path: String
        switch mode {
        case .fixed(let value):
            nodeID = request.node.id
            path = value
        case .dependencyRequest:
            nodeID = request.node.id
            let requestValue = request.dependencies
                .flatMap(\.worker.unresolvedRisks)
                .first(where: { $0.hasPrefix("requested-path:") })
            path = requestValue.map { String($0.dropFirst("requested-path:".count)) }
                ?? "Sources/Feature/New.swift"
        case .wrongNode(let value):
            nodeID = value
            path = "Sources/Feature/New.swift"
        case .retryDrift(let value):
            nodeID = request.node.id
            path = request.attempt == 1 ? value : "Sources/Feature/Alternative.swift"
        }
        return try dynamicSealedContract(
            builderContractID: request.builderContract.id,
            nodeID: nodeID,
            path: path,
            maxTokens: maxTokens,
            includeReviewStageAuthority: includeReviewStageAuthority)
    }
}

private struct DynamicObservationSourceProvider: BuilderNodeObservationSourceProvider {
    let sourceValue: BuilderIsolatedWorkspaceTransactionSource
    func source(for request: BuilderNodeObservationSourceRequest) async throws
        -> any BuilderStageObservationSource {
        sourceValue
    }
}

private struct DynamicReadOnlyObservationSourceProvider: BuilderReadOnlyObservationSourceProvider {
    let sourceValue: DynamicTestObservationSource
    func source(for context: BuilderReadOnlyObservationContext) async throws
        -> any BuilderReadOnlyObservationSource {
        sourceValue
    }
}

private final class DynamicTestObservationSource: BuilderStageObservationSource,
                                                  BuilderReadOnlyObservationSource,
                                                  @unchecked Sendable {
    private let log: DynamicBuilderLog
    private let mirrorWorkerPaths: Bool
    private let hiddenReadOnlyMutationNodes: Set<String>

    init(log: DynamicBuilderLog, mirrorWorkerPaths: Bool = false,
         hiddenReadOnlyMutationNodes: Set<String> = []) {
        self.log = log
        self.mirrorWorkerPaths = mirrorWorkerPaths
        self.hiddenReadOnlyMutationNodes = hiddenReadOnlyMutationNodes
    }

    func prepare(_ context: BuilderStageContext) async throws -> BuilderStageBaseline {
        try BuilderStageBaseline(
            contractFingerprint: context.contract.fingerprint(),
            builderContractID: context.contract.builderContractID,
            nodeID: context.node.id,
            attempt: context.attempt,
            stage: context.stage,
            workspaceDigest: context.stage == .build
                ? dynamicDigest("a") : dynamicDigest("b"),
            pathStates: context.stage == .build
                ? try context.contract.mutations.map {
                    try BuilderObservedPathState(path: $0.path, digest: $0.preimageSHA256)
                } : [])
    }

    func observe(_ request: BuilderStageObservationRequest) async throws -> BuilderStageObservation {
        let mutationPaths: [String]
        if mirrorWorkerPaths, request.context.stage == .build,
           case .execution(let worker) = request.subject {
            mutationPaths = worker.changedPaths
        } else if request.context.stage == .build {
            mutationPaths = request.context.contract.mutations.map(\.path)
        } else {
            mutationPaths = []
        }
        let operations = try mutationPaths.map {
            try BuilderObservedMutation(
                kind: .create, path: $0,
                preimageSHA256: nil, postimageSHA256: dynamicDigest("b"))
        }
        let criteria = try request.context.contract.criteria
            .filter { $0.stage == request.context.stage }
            .map { try BuilderCriterionObservation(
                criterionID: $0.id, passed: true, evidenceDigest: dynamicDigest("c")) }
        let identities: [BuilderIdentityObservation]
        if request.context.stage == .build {
            identities = request.context.contract.identities.producers.map {
                .init(role: .producer, identity: $0)
            }
        } else {
            identities = request.context.contract.identities.reviewers.map {
                .init(role: .reviewer, identity: $0)
            }
        }
        return try BuilderStageObservation(
            contractFingerprint: request.context.contract.fingerprint(),
            builderContractID: request.context.contract.builderContractID,
            nodeID: request.context.node.id,
            attempt: request.context.attempt,
            stage: request.context.stage,
            workspaceDigestBefore: request.baseline.workspaceDigest,
            workspaceDigestAfter: dynamicDigest("b"),
            operations: operations,
            criteria: criteria,
            identities: identities,
            lineage: request.context.contract.lineage)
    }

    func rollback(_ request: BuilderRollbackRequest) async throws -> BuilderRollbackObservation {
        await log.recordRollback()
        return try BuilderRollbackObservation(
            contractFingerprint: request.context.contract.fingerprint(),
            builderContractID: request.context.contract.builderContractID,
            nodeID: request.context.node.id,
            attempt: request.context.attempt,
            workspaceDigestAfter: request.baseline.workspaceDigest,
            restoredPathStates: request.baseline.pathStates,
            warnings: request.baseline.warnings)
    }

    func prepare(_ context: BuilderReadOnlyObservationContext) async throws
        -> BuilderReadOnlyBaseline {
        try BuilderReadOnlyBaseline(
            builderContractID: context.builderContractID,
            nodeID: context.node.id,
            attempt: context.attempt,
            workspaceDigest: dynamicDigest("a"))
    }

    func observe(context: BuilderReadOnlyObservationContext,
                 baseline: BuilderReadOnlyBaseline,
                 worker: BuilderWorkerReceipt) async throws -> BuilderReadOnlyObservation {
        let mutated = hiddenReadOnlyMutationNodes.contains(context.node.id)
        return try BuilderReadOnlyObservation(
            builderContractID: context.builderContractID,
            nodeID: context.node.id,
            attempt: context.attempt,
            workspaceDigestBefore: baseline.workspaceDigest,
            workspaceDigestAfter: mutated ? dynamicDigest("b") : baseline.workspaceDigest,
            observedChangedPaths: mutated ? ["Secrets/Hidden.swift"] : [])
    }

    func rollback(_ request: BuilderReadOnlyRollbackRequest) async throws
        -> BuilderReadOnlyRollbackObservation {
        await log.recordRollback()
        return try BuilderReadOnlyRollbackObservation(
            builderContractID: request.context.builderContractID,
            nodeID: request.context.node.id,
            attempt: request.context.attempt,
            workspaceDigestAfter: request.baseline.workspaceDigest,
            restoredPathStates: request.baseline.pathStates)
    }
}

private func dynamicParentContract(checkpointIdentity: String? = nil) -> BuilderContract {
    BuilderContract(
        id: "parent-contract",
        objective: "build dynamic graph",
        allowedPaths: ["Sources/Feature"],
        doneWhen: ["verified"],
        checkpointIdentity: checkpointIdentity)
}

private func dynamicProviderIdentity(_ marker: String) throws
    -> BuilderNodeContractProviderIdentity {
    try BuilderNodeContractProviderIdentity(
        providerID: "trusted-contract-factory",
        implementationFingerprint: dynamicDigest(marker))
}

private func dynamicSealedContract(
    builderContractID: String, nodeID: String, path: String, maxTokens: Int = 10_000,
    includeReviewStageAuthority: Bool = true
) throws
    -> SealedBuilderExecutionContract {
    let producer = try BuilderModelIdentity(providerID: "build-provider", modelID: "builder-model")
    let reviewer = try BuilderModelIdentity(providerID: "review-provider", modelID: "reviewer-model")
    let total = try BuilderResourceBudget(
        maxToolCalls: 100, maxTokens: maxTokens, maxWallTimeSeconds: 100)
    let stage = try BuilderResourceBudget(
        maxToolCalls: 40, maxTokens: min(4_000, maxTokens), maxWallTimeSeconds: 40)
    var criteria = try [
        BuilderStageCriterion(
            id: "build-artifact", stage: .build,
            kind: .artifactDigest, statement: "Bound mutation is observed"),
        BuilderStageCriterion(
            id: "verification-command", stage: .verification,
            kind: .deterministicCommand, statement: "Independent verification passes")
    ]
    var stages = [
        BuilderStageBudget(stage: .build, limit: stage),
        BuilderStageBudget(stage: .verification, limit: stage)
    ]
    if includeReviewStageAuthority {
        criteria.append(try BuilderStageCriterion(
            id: "independent-review", stage: .review,
            kind: .modelJudgment, statement: "Independent review accepts"))
        stages.append(BuilderStageBudget(stage: .review, limit: stage))
    }
    let contract = try BuilderExecutionContract(
        builderContractID: builderContractID,
        builderNodeID: nodeID,
        mutations: [try BuilderMutationOperation(kind: .create, path: path)],
        criteria: criteria,
        budgets: try BuilderBudgetPolicy(total: total, stages: stages),
        identities: try BuilderIdentityPlan(producers: [producer], reviewers: [reviewer]),
        lineage: try BuilderLineageEnvelope())
    return try SealedBuilderExecutionContract.issue(contract)
}

private func dynamicRun(
    contract: BuilderContract,
    graph: BuilderGraph,
    policy: BuilderGraphExecutionPolicy,
    provider: DynamicTestContractProvider,
    source: DynamicTestObservationSource,
    log: DynamicBuilderLog,
    planRequest: String? = nil,
    widenedWorkerNode: String? = nil,
    store: BuilderJSONStore? = nil,
    resumeExisting: Bool = false,
    mutationSource: BuilderIsolatedWorkspaceTransactionSource? = nil,
    noOpMutationAttempts: Set<Int> = [],
    executionContractMaxTokens: Int = 10_000,
    includeReviewStageAuthority: Bool = true,
    reviewAccepted: Bool = true,
    failFinalVerificationInvocation: Int? = nil
) throws -> BuilderRun {
    let storeValue = store ?? BuilderJSONStore(fileURL: dynamicTemporaryFile())
    let governedSource = try mutationSource ?? dynamicIsolatedSource(beside: storeValue.fileURL)
    return try BuilderRun(
        contract: contract,
        graph: graph,
        store: storeValue,
        resumeExisting: resumeExisting,
        graphExecutionPolicy: policy,
        nodeExecutionContractProvider: provider,
        nodeObservationSourceProvider: DynamicObservationSourceProvider(
            sourceValue: governedSource),
        readOnlyObservationSourceProvider: DynamicReadOnlyObservationSourceProvider(
            sourceValue: source),
        execute: { request in
            await log.recordWorker(request.node.id, attempt: request.attempt)
            var changedPaths: [String] = []
            var risks: [String] = []
            if request.node.id == "plan", let planRequest {
                risks = ["requested-path:\(planRequest)"]
            } else if request.node.resources.contains(where: { $0.access == .write }) {
                guard let rootPath = request.executionWorkspace?.rootPath else {
                    throw DynamicFixtureFailure.missingExecutionWorkspace
                }
                await log.recordWorkspace(request.node.id, rootPath: rootPath)
                BuilderTrustedTelemetry.recordProvider(
                    providerID: "build-provider", modelID: "builder-model",
                    inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                    outputDigest: BuilderEvidenceDigest.sha256(
                        "dynamic-worker-attempt-\(request.attempt)"))
                if !noOpMutationAttempts.contains(request.attempt) {
                    changedPaths = ["Sources/Feature/New.swift"]
                    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                    let target = root.appendingPathComponent("Sources/Feature/New.swift")
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("dynamic-build".utf8).write(to: target, options: .atomic)
                }
            }
            if request.node.id == widenedWorkerNode {
                changedPaths.append("Secrets/Exfil.swift")
                if let rootPath = request.executionWorkspace?.rootPath {
                    let exfil = URL(fileURLWithPath: rootPath, isDirectory: true)
                        .appendingPathComponent("Secrets/Exfil.swift")
                    try FileManager.default.createDirectory(
                        at: exfil.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("undeclared".utf8).write(to: exfil, options: .atomic)
                }
            }
            return BuilderWorkerReceipt(
                nodeID: request.node.id,
                provider: "build-provider",
                model: "builder-model",
                changedPaths: changedPaths,
                checks: [.init(name: "worker", passed: true)],
                unresolvedRisks: risks)
        },
        verify: { request in
            BuilderTrustedTelemetry.recordProvider(
                providerID: "review-provider", modelID: "reviewer-model",
                inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                outputDigest: dynamicDigest("f"))
            switch request {
            case .node(let parent, let node, _, let executionWorkspace)
                where node.resources.contains(where: { $0.access == .write }):
                guard let rootPath = executionWorkspace?.rootPath else {
                    throw DynamicFixtureFailure.missingExecutionWorkspace
                }
                let subjectDigest = try BuilderWorkspaceManifestScanner.scan(
                    root: URL(fileURLWithPath: rootPath, isDirectory: true),
                    limits: try BuilderWorkspaceTraversalLimits()).contentDigest()
                let sealed = try dynamicSealedContract(
                    builderContractID: parent.id, nodeID: node.id,
                    path: "Sources/Feature/New.swift",
                    maxTokens: executionContractMaxTokens,
                    includeReviewStageAuthority: includeReviewStageAuthority)
                let result = await ToolRegistry([RunCommandTool()]).execute(
                    name: "run_command",
                    arguments: [
                        "executable": "/usr/bin/printf",
                        "args": ["%s", "verified"],
                    ],
                    context: ToolContext(
                        projectRoot: rootPath,
                        shell: ShellPolicy(
                            enabled: true, autoApprove: true, allow: ["printf"]),
                        sandbox: .disabled))
                guard result.success, let reference = result.trustedCommandReference else {
                    throw DynamicFixtureFailure.commandEvidenceMissing(
                        result.error ?? "trusted command reference was not issued")
                }
                let command = BuilderCommandEvidenceReceipt.boundPrehashed(
                    tool: "run_command", verifierStatus: .passed,
                    exitCode: reference.exitCode, allowedExitCodes: "0",
                    semanticStatus: "clean_exit",
                    argsFingerprint: reference.gateArgumentsDigest,
                    outputDigest: reference.stdoutDigest,
                    boundedRedactedOutputExcerpt: result.output,
                    subjectDigestAfter: subjectDigest,
                    contractFingerprint: try sealed.contract.fingerprint(),
                    trustedCommandReference: reference)
                return BuilderVerifierReceipt(
                    scope: .node(node.id), provider: "review-provider",
                    model: "reviewer-model", deterministic: true, passed: true,
                    checks: [.init(name: "verify", passed: true)],
                    verificationSubject: rootPath, baselineDigest: subjectDigest,
                    subjectDigest: subjectDigest,
                    contractFingerprint: try sealed.contract.fingerprint(),
                    commandEvidence: [command])
            case .node(_, let node, _, _):
                return BuilderVerifierReceipt(
                    scope: .node(node.id), provider: "review-provider",
                    model: "reviewer-model", deterministic: true, passed: true,
                    checks: [.init(name: "verify", passed: true)])
            case .final(_, _, let workers):
                let finalInvocation = await log.recordFinalVerification()
                let project = governedSource.projectRoot
                var verificationRoot = project
                for worker in workers where !worker.changedPaths.isEmpty {
                    if let stagedRoot = await log.workspace(worker.nodeID),
                       FileManager.default.fileExists(atPath: stagedRoot) {
                        verificationRoot = URL(
                            fileURLWithPath: stagedRoot, isDirectory: true)
                        break
                    }
                }
                let subjectDigest = try BuilderWorkspaceManifestScanner.scan(
                    root: verificationRoot,
                    limits: try BuilderWorkspaceTraversalLimits()).contentDigest()
                let fingerprint = BuilderEvidenceDigest.sha256(String(
                    decoding: try BuilderDurableIO.canonicalData(contract), as: UTF8.self))
                let result = await ToolRegistry([RunCommandTool()]).execute(
                    name: "run_command",
                    arguments: [
                        "executable": "/usr/bin/printf",
                        "args": ["%s", "final-verified"],
                    ],
                    context: ToolContext(
                        projectRoot: verificationRoot.path,
                        shell: ShellPolicy(
                            enabled: true, autoApprove: true, allow: ["printf"])))
                guard result.success, let reference = result.trustedCommandReference else {
                    throw DynamicFixtureFailure.commandEvidenceMissing(
                        result.error ?? "trusted command reference was not issued")
                }
                let command = BuilderCommandEvidenceReceipt.boundPrehashed(
                    tool: "run_command", verifierStatus: .passed,
                    exitCode: reference.exitCode, allowedExitCodes: "0",
                    semanticStatus: "clean_exit",
                    argsFingerprint: reference.gateArgumentsDigest,
                    outputDigest: reference.stdoutDigest,
                    boundedRedactedOutputExcerpt: result.output,
                    subjectDigestAfter: subjectDigest,
                    contractFingerprint: fingerprint,
                    trustedCommandReference: reference)
                let passed = finalInvocation != failFinalVerificationInvocation
                return BuilderVerifierReceipt(
                    scope: .final, provider: "review-provider",
                    model: "reviewer-model", deterministic: true, passed: passed,
                    checks: [.init(name: "verify", passed: passed,
                                   details: passed ? "passed" : "injected post-promotion failure")],
                    verificationSubject: project.path,
                    baselineDigest: subjectDigest, subjectDigest: subjectDigest,
                    contractFingerprint: fingerprint, commandEvidence: [command])
            }
        },
        review: { request in
            await log.recordReview(request)
            BuilderTrustedTelemetry.recordProvider(
                providerID: "review-provider", modelID: "reviewer-model",
                inputTokens: 1, outputTokens: 1, elapsedMilliseconds: 1,
                outputDigest: dynamicDigest("e"))
            return BuilderReviewReceipt(
                provider: "review-provider",
                model: "reviewer-model",
                accepted: reviewAccepted,
                checks: [.init(name: "review", passed: reviewAccepted)],
                findings: reviewAccepted ? [] : ["review rejected"],
                evidencePacketDigest: dynamicDigest("review-packet"))
        })
}

private enum DynamicFixtureFailure: Error, LocalizedError {
    case missingExecutionWorkspace
    case commandEvidenceMissing(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutionWorkspace:
            return "governance did not supply its attested verification workspace"
        case .commandEvidenceMissing(let reason):
            return "verification command evidence is missing: \(reason)"
        }
    }
}

private func dynamicIsolatedSource(beside file: URL) throws
    -> BuilderIsolatedWorkspaceTransactionSource {
    let base = file.deletingLastPathComponent()
    let project = base.appendingPathComponent("project", isDirectory: true)
    let staging = base.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(
        at: project, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return try BuilderIsolatedWorkspaceTransactionSource(
        projectRoot: project, stagingBase: staging,
        attestor: BuilderOSProcessSandboxAttestor())
}

private func dynamicTemporaryFile() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("builder-dynamic-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("run.json")
}

private func dynamicDigest(_ marker: String) -> String {
    String(repeating: String(marker.prefix(1)), count: 64)
}

private func assertAsyncThrows(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected operation to throw", file: file, line: line)
    } catch {}
}
