import Foundation
// Cross-platform crypto: swift-crypto's `Crypto` (CryptoKit-compatible, Linux-safe).
import Crypto

func builderIsHostDeterministicVerifier(provider: String, model: String) -> Bool {
    ["host", "process", "kist"].contains(provider.lowercased())
        && ["deterministic", "command"].contains(model.lowercased())
}

func builderFinalVerifierIdentitiesMatch(
    _ lhs: BuilderModelIdentity, _ rhs: BuilderModelIdentity
) -> Bool {
    lhs == rhs || (
        builderIsHostDeterministicVerifier(
            provider: lhs.providerID, model: lhs.modelID)
            && builderIsHostDeterministicVerifier(
                provider: rhs.providerID, model: rhs.modelID)
    )
}
private struct BuilderReviewProvenanceFacts {
    let reviewGrade: EvolutionReviewGrade
    let independent: Bool
    let freshConversation: Bool?
    let separateInvocation: Bool?
    let producerInvocationIDs: [String]?
    let reviewerInvocationIDs: [String]?
    let reviewThreshold: Int?
}
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
public actor BuilderRun {
    public let contract: BuilderContract; public let graph: BuilderGraph; public let route: BuilderRoute; public let maxParallelism: Int; public let identicalFailureLimit: Int
    private let store: BuilderJSONStore
    private let leases: BuilderResourceLeaseTable
    private let execute: BuilderExecute
    private let verify: BuilderVerify
    private let review: BuilderReview
    private let resumeExisting: Bool
    private let executionGovernance: BuilderExecutionGovernanceRuntime?
    private let graphExecutionPolicy: BuilderGraphExecutionPolicy?
    private let nodeExecutionContractProvider: (any BuilderNodeExecutionContractProvider)?
    private let nodeObservationSourceProvider: (any BuilderNodeObservationSourceProvider)?
    private let readOnlyObservationSourceProvider: (any BuilderReadOnlyObservationSourceProvider)?
    private let configuredAggregateTransaction: BuilderAggregateTransactionDescriptor?
    private let finalAcceptanceCommit: BuilderFinalAcceptanceCommit?
    public init(
        contract: BuilderContract,
        graph: BuilderGraph,
        store: BuilderJSONStore,
        leases: BuilderResourceLeaseTable = .init(),
        maxParallelism: Int = 4,
        identicalFailureLimit: Int = 2,
        resumeExisting: Bool = false,
        graphExecutionPolicy: BuilderGraphExecutionPolicy? = nil,
        nodeExecutionContractProvider: (any BuilderNodeExecutionContractProvider)? = nil,
        nodeObservationSourceProvider: (any BuilderNodeObservationSourceProvider)? = nil,
        readOnlyObservationSourceProvider: (any BuilderReadOnlyObservationSourceProvider)? = nil,
        aggregateTransaction: BuilderAggregateTransactionDescriptor? = nil,
        stageObservationSource: (any BuilderStageObservationSource)? = nil,
        finalAcceptanceCommit: BuilderFinalAcceptanceCommit? = nil,
        execute: @escaping BuilderExecute,
        verify: @escaping BuilderVerify,
        review: @escaping BuilderReview
    ) throws {
        guard maxParallelism > 0 else {
            throw BuilderRunError.invalidConfiguration("maxParallelism must be positive")
        }
        guard identicalFailureLimit > 0 else {
            throw BuilderRunError.invalidConfiguration("identicalFailureLimit must be positive")
        }
        try validateBuilderReviewConfiguration(
            contract: contract, graph: graph, graphExecutionPolicy: graphExecutionPolicy)
        if contract.effectiveCompletionMode == .build, graphExecutionPolicy == nil {
            throw BuilderRunError.invalidConfiguration(
                "build/mutation runs require an explicit graph execution policy; legacy execution is read-only only")
        }
        if let startup = contract.executionContract {
            guard let startupNode = graph.nodes.first(where: {
                $0.id == startup.contract.builderNodeID
            }) else {
                throw BuilderRunError.invalidConfiguration(
                    "startup execution contract references an unknown node")
            }
            do {
                try BuilderSelectedNodeExecutionContract.validateMutationAuthority(
                    startup.contract.mutations.map(\.path),
                    parentAllowedPaths: contract.allowedPaths,
                    nodeWriteClaims: startupNode.resources
                        .filter { $0.access == .write }.map(\.path))
            } catch {
                throw BuilderRunError.invalidConfiguration(error.localizedDescription)
            }
        }
        if let graphExecutionPolicy {
            do {
                try graphExecutionPolicy.validate(graph: graph)
                if let startup = contract.executionContract,
                   let startupNode = graph.nodes.first(where: {
                       $0.id == startup.contract.builderNodeID
                   }) {
                    if graphExecutionPolicy.executionClass(for: startupNode.id) == .readOnly,
                       !startup.contract.mutations.isEmpty {
                        throw BuilderRunError.invalidConfiguration(
                            "read-only startup node has mutation operations")
                    }
                }
            } catch {
                throw BuilderRunError.invalidConfiguration(error.localizedDescription)
            }
            let startupNodeID = contract.executionContract?.contract.builderNodeID
            let requiresDynamic = graph.nodes.contains {
                graphExecutionPolicy.executionClass(for: $0.id) == .mutation
                    && $0.id != startupNodeID
            }
            if requiresDynamic, nodeExecutionContractProvider == nil {
                throw BuilderRunError.invalidConfiguration(
                    "strict graph governance requires a dynamic contract provider")
            }
            if requiresDynamic, nodeObservationSourceProvider == nil {
                throw BuilderRunError.invalidConfiguration(
                    "dynamic governed nodes require a scoped observation-source provider")
            }
            let hasReadOnly = graph.nodes.contains {
                graphExecutionPolicy.executionClass(for: $0.id) == .readOnly
                    && $0.id != startupNodeID
            }
            if hasReadOnly, readOnlyObservationSourceProvider == nil {
                throw BuilderRunError.invalidConfiguration(
                    "explicit read-only nodes require a trusted workspace observation source")
            }
        } else if nodeExecutionContractProvider != nil || nodeObservationSourceProvider != nil
                    || readOnlyObservationSourceProvider != nil {
            throw BuilderRunError.invalidConfiguration(
                "dynamic contract providers require an explicit graph execution policy")
        }
        if let executionContract = contract.executionContract {
            do {
                try executionContract.validate(
                    builderContractID: contract.id,
                    graphNodeIDs: graph.nodes.map(\.id))
                try validateBuilderExecutionReviewPolicy(
                    executionContract.contract, parent: contract)
                try validateBuilderDisposableReviewSource(
                    stageObservationSource, parent: contract)
            } catch {
                throw BuilderRunError.invalidConfiguration(
                    "invalid sealed execution contract: \(error.localizedDescription)")
            }
        }
        self.contract = contract
        self.graph = graph
        self.route = contract.routeHint.resolve()
        self.store = store
        self.leases = leases
        self.maxParallelism = maxParallelism
        self.identicalFailureLimit = identicalFailureLimit
        self.resumeExisting = resumeExisting
        self.graphExecutionPolicy = graphExecutionPolicy
        self.nodeExecutionContractProvider = nodeExecutionContractProvider
        self.nodeObservationSourceProvider = nodeObservationSourceProvider
        self.readOnlyObservationSourceProvider = readOnlyObservationSourceProvider
        self.configuredAggregateTransaction = aggregateTransaction
        self.finalAcceptanceCommit = finalAcceptanceCommit
        if let sealed = contract.executionContract {
            self.executionGovernance = try BuilderExecutionGovernanceRuntime(
                sealed: sealed, source: stageObservationSource, beside: store.fileURL)
        } else {
            self.executionGovernance = nil
        }
        self.execute = execute
        self.verify = verify
        self.review = review
    }

    private func dynamicGovernance(
        for node: BuilderNode,
        attempt: Int,
        snapshot: inout BuilderRunSnapshot
    ) async throws -> BuilderExecutionGovernanceRuntime? {
        if let executionGovernance,
           executionGovernance.contract.builderNodeID == node.id {
            return executionGovernance
        }
        guard let graphExecutionPolicy else { return nil }
        guard graphExecutionPolicy.executionClass(for: node.id) == .mutation else { return nil }
        guard let provider = nodeExecutionContractProvider else {
            throw BuilderDynamicContractError.missingContractProvider(node.id)
        }
        guard let sourceProvider = nodeObservationSourceProvider else {
            throw BuilderDynamicContractError.missingObservationSource(node.id)
        }

        let graphNodeIDs = graph.nodes.map(\.id)
        let writeClaims = node.resources.filter { $0.access == .write }.map(\.path)
        let selection: BuilderSelectedNodeExecutionContract
        if let persisted = snapshot.selectedExecutionContracts?[node.id],
           persisted.attempt == attempt {
            try persisted.validate(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                expectedNodeID: node.id,
                expectedAttempt: attempt,
                providerIdentity: provider.identity,
                parentAllowedPaths: contract.allowedPaths,
                nodeWriteClaims: writeClaims)
            selection = persisted
        } else {
            if let persisted = snapshot.selectedExecutionContracts?[node.id],
               persisted.attempt >= attempt {
                throw BuilderDynamicContractError.invalidAttempt
            }
            let dependencies = try node.dependencies.map { dependencyID in
                guard let dependencyNode = graph.nodes.first(where: { $0.id == dependencyID }),
                      let state = snapshot.nodeStates[dependencyID],
                      state.phase == .accepted,
                      let worker = state.worker,
                      let verification = state.verification else {
                    throw BuilderDynamicContractError.invalidDependencyResults(node.id)
                }
                return try BuilderCommittedDependencyResult(
                    node: dependencyNode, worker: worker, verification: verification,
                    parentContractFingerprint: parentContractFingerprint(contract),
                    graphFingerprint: builderGraphFingerprint(graph),
                    consumerNodeID: node.id, consumerAttempt: attempt,
                    acceptedCheckpointSequence: snapshot.sequence)
            }
            let request = try BuilderNodeContractRequest(
                builderContract: contract, graph: graph, node: node,
                attempt: attempt, dependencies: dependencies)
            let sealed = try await provider.sealedContract(for: request)
            let derived = try BuilderSelectedNodeExecutionContract(
                nodeID: node.id, attempt: attempt,
                providerIdentity: provider.identity, sealedContract: sealed)
            try derived.validate(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                expectedNodeID: node.id,
                expectedAttempt: attempt,
                providerIdentity: provider.identity,
                parentAllowedPaths: contract.allowedPaths,
                nodeWriteClaims: writeClaims)
            if let persisted = snapshot.selectedExecutionContracts?[node.id] {
                try persisted.validate(
                    builderContractID: contract.id,
                    graphNodeIDs: graphNodeIDs,
                    expectedNodeID: node.id,
                    expectedAttempt: persisted.attempt,
                    providerIdentity: provider.identity,
                    parentAllowedPaths: contract.allowedPaths,
                    nodeWriteClaims: writeClaims)
                guard persisted.attempt + 1 == attempt,
                      persisted.contractFingerprint == derived.contractFingerprint,
                      persisted.contractSealReference == derived.contractSealReference else {
                    throw BuilderDynamicContractError.retryContractDrift
                }
            }
            var selected = snapshot.selectedExecutionContracts ?? [:]
            selected[node.id] = derived
            snapshot.selectedExecutionContracts = selected
            selection = derived
        }

        do {
            try validateBuilderExecutionReviewPolicy(
                selection.sealedContract.contract, parent: contract)
        } catch {
            throw BuilderDynamicContractError.invalidSealedContract(
                "child review policy drifted from its parent: \(error.localizedDescription)")
        }

        let source = try await sourceProvider.source(for: .init(
            builderContractID: contract.id,
            graphNodeIDs: graphNodeIDs,
            node: node,
            attempt: attempt,
            contractFingerprint: selection.contractFingerprint,
            contractSealReference: selection.contractSealReference))
        try validateBuilderDisposableReviewSource(source, parent: contract)
        let runtime = try BuilderExecutionGovernanceRuntime(
            sealed: selection.sealedContract,
            source: source,
            beside: store.fileURL,
            contractSealReference: selection.contractSealReference)
        try runtime.ensureReady()
        return runtime
    }

    private func reconcileDynamicGovernance(
        snapshot: inout BuilderRunSnapshot,
        runtimes: inout [String: BuilderExecutionGovernanceRuntime],
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: inout BuilderIsolatedWorkspaceTransactionSource?
    ) async throws {
        guard let selections = snapshot.selectedExecutionContracts, !selections.isEmpty else { return }
        guard graphExecutionPolicy != nil,
              let provider = nodeExecutionContractProvider,
              let sourceProvider = nodeObservationSourceProvider else {
            throw BuilderRunError.persistedStateInvalid(
                "persisted dynamic contracts require their trusted provider and observation source")
        }
        let graphNodeIDs = graph.nodes.map(\.id)
        for nodeID in selections.keys.sorted() {
            guard let selection = selections[nodeID],
                  let node = graph.nodes.first(where: { $0.id == nodeID }),
                  let state = snapshot.nodeStates[nodeID] else {
                throw BuilderRunError.persistedStateInvalid(
                    "persisted dynamic contract references an unknown node")
            }
            try selection.validate(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                expectedNodeID: nodeID,
                expectedAttempt: state.attempts,
                providerIdentity: provider.identity,
                parentAllowedPaths: contract.allowedPaths,
                nodeWriteClaims: node.resources.filter { $0.access == .write }.map(\.path))
            do {
                try validateBuilderExecutionReviewPolicy(
                    selection.sealedContract.contract, parent: contract)
            } catch {
                throw BuilderRunError.persistedStateInvalid(
                    "persisted child review policy drifted from its parent: \(error.localizedDescription)")
            }
            let source = try await sourceProvider.source(for: .init(
                builderContractID: contract.id,
                graphNodeIDs: graphNodeIDs,
                node: node,
                attempt: selection.attempt,
                contractFingerprint: selection.contractFingerprint,
                contractSealReference: selection.contractSealReference))
            do {
                try validateBuilderDisposableReviewSource(source, parent: contract)
            } catch {
                throw BuilderRunError.persistedStateInvalid(
                    "persisted same-model review source is no longer eligible: "
                        + error.localizedDescription)
            }
            let runtime = try BuilderExecutionGovernanceRuntime(
                sealed: selection.sealedContract,
                source: source,
                beside: store.fileURL,
                contractSealReference: selection.contractSealReference)
        try runtime.ensureReady()
        if let aggregate {
            aggregateSource = try await registerAggregateRuntime(
                runtime, node: node, attempt: selection.attempt,
                descriptor: aggregate, current: aggregateSource)
        }
        try await runtime.reconcile(
            snapshotAccepted: state.phase == .accepted,
            runAccepted: snapshot.reviewAccepted
                && (snapshot.pendingFinalReceipt?.accepted == true
                    || snapshot.finalReceipt?.accepted == true)
                && snapshot.commitEpoch?.count == 64)
        runtimes[nodeID] = runtime
    }
}

    private func ensureAggregateDescriptor(
        snapshot: inout BuilderRunSnapshot
    ) throws -> BuilderAggregateTransactionDescriptor? {
        guard let policy = graphExecutionPolicy else { return nil }
        let nodes = graph.nodes.filter {
            policy.executionClass(for: $0.id) == .mutation
        }.map(\.id).sorted()
        guard nodes.count > 1 else {
            guard configuredAggregateTransaction == nil else {
                throw BuilderRunError.invalidConfiguration(
                    "aggregate transaction supplied for fewer than two mutation nodes")
            }
            return nil
        }
        let expectedParent = try parentContractFingerprint(contract)
        let expectedGraph = try builderGraphFingerprint(graph)
        let descriptor: BuilderAggregateTransactionDescriptor
        if let configuredAggregateTransaction {
            descriptor = configuredAggregateTransaction
        } else if let persisted = snapshot.aggregateTransaction {
            descriptor = persisted
        } else {
            descriptor = try .init(
                aggregateID: BuilderEvidenceDigest.sha256(
                    "\(expectedParent):\(expectedGraph):\(UUID().uuidString)"),
                parentContractFingerprint: expectedParent,
                graphFingerprint: expectedGraph,
                expectedNodeIDs: nodes)
        }
        try descriptor.validate()
        guard descriptor.parentContractFingerprint == expectedParent,
              descriptor.graphFingerprint == expectedGraph,
              descriptor.expectedNodeIDs == nodes,
              snapshot.aggregateTransaction == nil || snapshot.aggregateTransaction == descriptor else {
            throw BuilderRunError.persistedStateInvalid(
                "aggregate transaction does not match the parent graph")
        }
        snapshot.aggregateTransaction = descriptor
        return descriptor
    }

    private func registerAggregateRuntime(
        _ runtime: BuilderExecutionGovernanceRuntime,
        node: BuilderNode,
        attempt: Int,
        descriptor: BuilderAggregateTransactionDescriptor,
        current: BuilderIsolatedWorkspaceTransactionSource?
    ) async throws -> BuilderIsolatedWorkspaceTransactionSource {
        guard let source = runtime.source as? BuilderIsolatedWorkspaceTransactionSource else {
            throw BuilderRunError.invalidConfiguration(
                "fleet mutation nodes require one aggregate-capable transaction source")
        }
        if let current, current !== source {
            throw BuilderRunError.invalidConfiguration(
                "fleet mutation nodes must share one aggregate transaction source instance")
        }
        try await source.beginAggregate(descriptor)
        let context = try BuilderStageContext(
            contract: runtime.contract, node: node, attempt: attempt, stage: .build)
        try await source.registerAggregateChild(descriptor, context: context)
        return source
    }

    private func readOnlyGuard(for node: BuilderNode, attempt: Int) async throws
        -> BuilderReadOnlyExecutionGuard? {
        guard let graphExecutionPolicy,
              graphExecutionPolicy.executionClass(for: node.id) == .readOnly else { return nil }
        guard let provider = readOnlyObservationSourceProvider else {
            throw BuilderReadOnlyObservationError.missingTrustedSource(node.id)
        }
        let context = try BuilderReadOnlyObservationContext(
            builderContractID: contract.id,
            graphNodeIDs: graph.nodes.map(\.id),
            node: node,
            attempt: attempt)
        let source = try await provider.source(for: context)
        return .init(context: context, source: source)
    }

    private func admitGraphGovernance(snapshot: inout BuilderRunSnapshot) throws {
        let policy = graphExecutionPolicy ?? BuilderGraphExecutionPolicy(nodeClasses:
            Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, .readOnly) }))
        let expected = try BuilderGraphGovernanceAdmission.make(
            graph: graph, policy: policy,
            providerIdentity: nodeExecutionContractProvider?.identity)
        let hasDurableProgress = snapshot.finalReceipt != nil
            || snapshot.reviewAttempt != nil
            || snapshot.selectedExecutionContracts != nil
            || snapshot.nodeStates.values.contains {
                $0.attempts > 0 || $0.phase != .pending
            }
        if expected.governanceRequired {
            if let declared = contract.governanceAdmission {
                try declared.validate(matches: expected)
            } else if hasDurableProgress && snapshot.governanceAdmission == nil {
                throw BuilderGraphGovernanceAdmissionError.missingMutationGovernance
            }
        } else if let declared = contract.governanceAdmission {
            try declared.validate(matches: expected)
        }
        if let persisted = snapshot.governanceAdmission {
            try persisted.validate(matches: expected)
        } else {
            if expected.governanceRequired && hasDurableProgress {
                throw BuilderRunError.persistedStateInvalid(
                    "mutation run snapshot predates sealed graph-governance admission")
            }
            snapshot.governanceAdmission = expected
        }

        guard expected.governanceRequired else { return }
        let startupNodeID = contract.executionContract?.contract.builderNodeID
        let selected = Set(snapshot.selectedExecutionContracts?.keys.map { $0 } ?? [])
        for nodeID in expected.governedNodeIDs where nodeID != startupNodeID {
            guard let state = snapshot.nodeStates[nodeID] else {
                throw BuilderRunError.persistedStateInvalid(
                    "governed graph admission references missing node \(nodeID)")
            }
            if state.phase == .accepted || state.attempts > 0 {
                guard selected.contains(nodeID) else {
                    throw BuilderRunError.persistedStateInvalid(
                        "progressed mutation node \(nodeID) has no sealed selected execution contract")
                }
            }
        }
        if snapshot.finalReceipt?.accepted == true {
            let requiredDynamic = Set(expected.governedNodeIDs.filter { $0 != startupNodeID })
            guard selected == requiredDynamic else {
                throw BuilderRunError.persistedStateInvalid(
                    "accepted mutation run has an incomplete governed contract set")
            }
        }
    }

    public func run() async throws -> BuilderFinalReceipt {
        let runLease = try await store.acquireLease()
        defer { runLease.release() }
        var snapshot = try await restoredSnapshot()
        try admitGraphGovernance(snapshot: &snapshot)
        let aggregate = try ensureAggregateDescriptor(snapshot: &snapshot)
        try await persist(&snapshot)
        var governedRuntimes: [String: BuilderExecutionGovernanceRuntime] = [:]
        var aggregateSource: BuilderIsolatedWorkspaceTransactionSource?
        if let executionGovernance {
            try executionGovernance.ensureReady()
            let nodeID = executionGovernance.contract.builderNodeID
            if let aggregate,
               let node = graph.nodes.first(where: { $0.id == nodeID }),
               let attempt = snapshot.nodeStates[nodeID]?.attempts,
               attempt > 0 {
                aggregateSource = try await registerAggregateRuntime(
                    executionGovernance, node: node, attempt: attempt,
                    descriptor: aggregate, current: aggregateSource)
            }
            try await executionGovernance.reconcile(
                snapshotAccepted: snapshot.nodeStates[nodeID]?.phase == .accepted,
            runAccepted: snapshot.reviewAccepted
                && (snapshot.pendingFinalReceipt?.accepted == true
                    || snapshot.finalReceipt?.accepted == true)
                && snapshot.commitEpoch?.count == 64)
            governedRuntimes[nodeID] = executionGovernance
        }
        try await reconcileDynamicGovernance(
            snapshot: &snapshot, runtimes: &governedRuntimes,
            aggregate: aggregate, aggregateSource: &aggregateSource)
        if let pending = snapshot.pendingFinalReceipt, pending.accepted {
            guard snapshot.reviewAccepted, snapshot.commitEpoch?.count == 64 else {
                throw BuilderRunError.persistedStateInvalid(
                    "pending final receipt lacks a durable global acceptance decision")
            }
            try validatePersistedReviewProvenance(
                pending.review, workers: pending.workers, snapshot: snapshot)
            do {
                let refreshed: BuilderVerifierReceipt
                if let aggregate {
                    guard let aggregateSource, let commitEpoch = snapshot.commitEpoch else {
                        throw BuilderRunError.persistedStateInvalid(
                            "pending aggregate acceptance has no transaction source or epoch")
                    }
                    refreshed = try await finalizeAcceptedAggregate(
                        aggregate, source: aggregateSource, commitEpoch: commitEpoch,
                        workers: pending.workers, expected: pending.verification,
                        runtimes: governedRuntimes, snapshot: &snapshot)
                } else {
                    refreshed = try await trustedFinalVerification(
                        workers: pending.workers, snapshot: &snapshot)
                }
                try validateTrustedTelemetry(snapshot)
                guard refreshed.scope == .final, refreshed.deterministic, refreshed.passed,
                      refreshed.checks.allSatisfy(\.passed),
                      refreshed.verificationSubject == pending.verification.verificationSubject,
                      refreshed.subjectDigest == pending.verification.subjectDigest else {
                    throw BuilderRunError.finalVerificationFailed(
                        "finalized workspace does not match the pending acceptance digest")
                }
                let unsignedReceipt = BuilderFinalReceipt(
                    contractID: pending.contractID, route: pending.route,
                    workers: pending.workers, verification: refreshed,
                    review: pending.review, accepted: true, completedAt: pending.completedAt)
                let receipt = try authorizePublishedFinal(
                    unsignedReceipt, snapshot: snapshot)
                snapshot.finalReceipt = receipt
                snapshot.pendingFinalReceipt = nil
                snapshot.finalizationPending = false
                try await persistAcceptedFinalReceipt(
                    receipt, aggregate: aggregate, aggregateSource: aggregateSource,
                    runtimes: governedRuntimes, snapshot: &snapshot)
            } catch {
                let original = error
                if snapshot.finalReceipt?.accepted != true {
                    let failures = await rollbackPendingGlobalAcceptance(
                        aggregate: aggregate, aggregateSource: aggregateSource,
                        runtimes: governedRuntimes, snapshot: &snapshot,
                        reason: "pending finalization failed: \(original.localizedDescription)")
                    if !failures.isEmpty {
                        throw BuilderRunError.finalVerificationFailed(
                            "pending finalization failed and rollback was not proven: \(failures.joined(separator: "; "))")
                    }
                    try await persist(&snapshot)
                }
                throw original
            }
        }
        if let completed = snapshot.finalReceipt, completed.accepted {
            try validatePublishedFinalAuthority(completed, snapshot: snapshot)
            try validatePersistedReviewProvenance(
                completed.review, workers: completed.workers, snapshot: snapshot)
            if let aggregate {
                guard let aggregateSource else {
                    throw BuilderRunError.persistedStateInvalid(
                        "completed aggregate run has no transaction source")
                }
                _ = try await aggregateSource.verifyAggregateFinalized(aggregate)
            } else if governedRuntimes.isEmpty && (contract.effectiveCompletionMode == .verificationOnly
                || completed.verification.subjectDigest != nil) {
                let refreshed = try await trustedFinalVerification(
                    workers: completed.workers, snapshot: &snapshot)
                guard refreshed.scope == .final, refreshed.deterministic, refreshed.passed,
                      refreshed.checks.allSatisfy(\.passed),
                      refreshed.verificationSubject == completed.verification.verificationSubject,
                      refreshed.subjectDigest == completed.verification.subjectDigest else {
                    throw BuilderRunError.finalVerificationFailed(
                        "persisted verification is stale for the current governed workspace digest")
                }
            }
            try await commitAcceptedFinalExternally(completed, snapshot: snapshot)
            await releaseAcceptedRetainedData(
                aggregate: aggregate, aggregateSource: aggregateSource,
                runtimes: governedRuntimes, snapshot: snapshot)
            return completed
        }
        while !graph.nodes.allSatisfy({ snapshot.nodeStates[$0.id]?.phase == .accepted }) {
            blockDescendants(in: &snapshot)
            let ready = graph.nodes.filter { node in
                guard snapshot.nodeStates[node.id]?.phase == .pending else { return false }
                return node.dependencies.allSatisfy { snapshot.nodeStates[$0]?.phase == .accepted }
            }
            if ready.isEmpty {
                let failures = snapshot.nodeStates.compactMapValues { state -> String? in
                    state.phase == .failed ? (state.failureReason ?? "failed") : nil
                }
                if !failures.isEmpty {
                    try await persist(&snapshot)
                    throw BuilderRunError.executionFailed(failures)
                }
                let unfinished = snapshot.nodeStates.filter { $0.value.phase != .accepted }.map(\.key).sorted()
                try await persist(&snapshot)
                throw BuilderRunError.stalled(unfinished)
            }
            let batch = selectBatch(from: ready)
        for node in batch {
                snapshot.nodeStates[node.id]!.attempts += 1
            }
var executionGovernanceByNode: [String: BuilderExecutionGovernanceRuntime] = [:]
var readOnlyGuardsByNode: [String: BuilderReadOnlyExecutionGuard] = [:]
var acceptedDependenciesByNode: [String: [BuilderAcceptedDependencyResult]] = [:]
var governancePreparationFailures: [String: String] = [:]
for node in batch {
    let attempt = snapshot.nodeStates[node.id]!.attempts
    do {
        acceptedDependenciesByNode[node.id] = try node.dependencies.sorted().map { dependencyID in
            guard let dependency = snapshot.nodeStates[dependencyID],
                  dependency.phase == .accepted,
                  let worker = dependency.worker,
                  let verification = dependency.verification else {
                throw BuilderRunError.persistedStateInvalid(
                    "dependency \(dependencyID) is not durably accepted")
            }
            return try BuilderAcceptedDependencyResult(
                nodeID: dependencyID, worker: worker, verification: verification,
                parentContractFingerprint: parentContractFingerprint(contract),
                graphFingerprint: builderGraphFingerprint(graph),
                consumerNodeID: node.id, consumerAttempt: attempt,
                acceptedCheckpointSequence: snapshot.sequence)
        }
        if let runtime = try await dynamicGovernance(
                for: node, attempt: attempt, snapshot: &snapshot) {
                if let aggregate {
                    aggregateSource = try await registerAggregateRuntime(
                        runtime, node: node, attempt: attempt,
                        descriptor: aggregate, current: aggregateSource)
                }
                executionGovernanceByNode[node.id] = runtime
                governedRuntimes[node.id] = runtime
            }
                    if let guardValue = try await readOnlyGuard(for: node, attempt: attempt) {
                        readOnlyGuardsByNode[node.id] = guardValue
                    }
                    snapshot.nodeStates[node.id]!.phase = .running
                } catch {
                    governancePreparationFailures[node.id] = String(reflecting: error)
                    snapshot.nodeStates[node.id]!.phase = .failed
                    snapshot.nodeStates[node.id]!.failureReason = error.localizedDescription
                }
            }
            try await persist(&snapshot)
            let outcomes = await withTaskGroup(of: BuilderAttemptOutcome.self) { group in
                for node in batch {
                    let attempt = snapshot.nodeStates[node.id]!.attempts
                    group.addTask { [contract, route, leases, execute, verify, graphExecutionPolicy,
                                     executionGovernanceByNode, readOnlyGuardsByNode,
                                     governancePreparationFailures] in
                        if let reason = governancePreparationFailures[node.id] {
                            return .terminal(node.id, stableFingerprint(reason), reason)
                        }
                        do {
                            let lease = try await leases.acquire(owner: "\(contract.id):\(node.id)", claims: node.resources)
                            do {
if let nodeGovernance = executionGovernanceByNode[node.id] {
    let acceptedDependencies = acceptedDependenciesByNode[node.id] ?? []
    let result = await nodeGovernance.execute(
        builderContract: contract, route: route,
        node: node, attempt: attempt,
        acceptedDependencies: acceptedDependencies,
        execute: execute, verify: verify)
                                    await leases.release(lease)
                                    switch result {
                                    case .accepted(let worker, let proof, let promotion, let telemetry):
                                        return .accepted(node.id, worker, proof, promotion, telemetry)
                                    case .retryable(let fingerprint, let reason):
                                        return .rejected(node.id, fingerprint, reason)
                                    case .terminal(let fingerprint, let reason):
                                        return .terminal(node.id, fingerprint, reason)
                                    }
                                }
let executionRequest = BuilderExecutionRequest(
    contract: contract, route: route, node: node, attempt: attempt,
    acceptedDependencies: acceptedDependenciesByNode[node.id] ?? [])
                                let worker: BuilderWorkerReceipt
                                if let readOnlyGuard = readOnlyGuardsByNode[node.id] {
                                    worker = try await readOnlyGuard.execute {
                                        try await execute(executionRequest)
                                    }
                                } else {
                                    worker = try await execute(executionRequest)
                                }
                                guard worker.nodeID == node.id else {
                                    throw BuilderRunError.persistedStateInvalid("worker receipt has wrong node ID")
                                }
                                if graphExecutionPolicy?.executionClass(for: node.id) == .readOnly,
                                   !worker.changedPaths.isEmpty {
                                    throw BuilderRunError.persistedStateInvalid(
                                        "explicit read-only node reported changed paths")
                                }
                                let proof = try await verify(.node(
                                    contract: contract, node: node, worker: worker,
                                    executionWorkspace: nil))
                                await leases.release(lease)
                                guard proof.scope == .node(node.id) else {
                                    return .rejected(node.id, stableFingerprint("wrong verification scope"), "wrong verification scope")
                                }
                                guard proof.deterministic, proof.passed, proof.checks.allSatisfy(\.passed) else {
                                    let reason = proof.checks.filter { !$0.passed }.map(\.details).joined(separator: "; ")
                                    let basis = proof.failureFingerprint ?? reason.nonEmpty ?? "node verification rejected"
                                    return .rejected(node.id, stableFingerprint(basis), basis)
                                }
                                return .accepted(node.id, worker, proof, nil, [])
                            } catch {
                                await leases.release(lease)
                                throw error
                            }
                        } catch {
                            let reason = String(reflecting: error)
                            return .rejected(node.id, stableFingerprint(reason), reason)
                        }
                    }
                }
                var values: [BuilderAttemptOutcome] = []
                for await value in group { values.append(value) }
                return values
            }
            for outcome in outcomes {
                switch outcome {
                case .accepted(let id, let worker, let proof, let promotion, let telemetry):
                    snapshot.nodeStates[id]!.phase = .accepted
                    snapshot.nodeStates[id]!.worker = worker
                    snapshot.nodeStates[id]!.verification = proof
                    snapshot.nodeStates[id]!.promotion = promotion
                    snapshot.nodeStates[id]!.trustedTelemetry = telemetry
                    snapshot.trustedTelemetry.append(contentsOf: telemetry)
                    snapshot.nodeStates[id]!.failureReason = nil
                case .rejected(let id, let fingerprint, let reason):
                    var state = snapshot.nodeStates[id]!
                    state.identicalFailureCount = state.lastFailureFingerprint == fingerprint
                        ? state.identicalFailureCount + 1 : 1
                    state.lastFailureFingerprint = fingerprint
                    state.failureReason = reason
                    let node = graph.nodes.first { $0.id == id }!
                    let exhausted = state.attempts >= node.retryLimit + 1
                    state.phase = exhausted || state.identicalFailureCount >= identicalFailureLimit ? .failed : .pending
                    snapshot.nodeStates[id] = state
                case .terminal(let id, let fingerprint, let reason):
                    snapshot.nodeStates[id]!.phase = .failed
                    snapshot.nodeStates[id]!.lastFailureFingerprint = fingerprint
                    snapshot.nodeStates[id]!.failureReason = reason
                }
            }
            let usage = snapshot.nodeStates.values.compactMap(\.worker?.usage)
            let unmeteredStages = usage.flatMap { $0.unmeteredStages ?? [] }
            let hasCompleteAggregate = usage.allSatisfy { $0.aggregateTokens != nil }
            snapshot.usage = BuilderUsageReceipt(
                inputTokens: usage.reduce(0) { $0 + $1.inputTokens },
                outputTokens: usage.reduce(0) { $0 + $1.outputTokens },
                wallTimeSeconds: usage.reduce(0) { $0 + $1.wallTimeSeconds },
                aggregateTokens: hasCompleteAggregate
                    ? usage.reduce(0) { $0 + ($1.aggregateTokens ?? 0) }
                    : nil,
                unmeteredStages: unmeteredStages.isEmpty ? nil : unmeteredStages.sorted()
            )
            try await persist(&snapshot)
        }
        let workers = try graph.nodes.map { node -> BuilderWorkerReceipt in
            guard let worker = snapshot.nodeStates[node.id]?.worker else {
                throw BuilderRunError.persistedStateInvalid("accepted node \(node.id) has no worker receipt")
            }
            return worker
        }
        let acceptedAttempts = Dictionary(uniqueKeysWithValues:
            snapshot.nodeStates.compactMap { nodeID, state in
                state.phase == .accepted ? (nodeID, state.attempts) : nil
            })
        let selectedContracts = snapshot.selectedExecutionContracts ?? [:]
        let selectedContractFingerprints = selectedContracts.mapValues(\.contractFingerprint)
        let acceptedVerificationSubjectDigests: [String: String] = Dictionary(
            uniqueKeysWithValues: snapshot.nodeStates.compactMap {
                nodeID, state -> (String, String)? in
                guard state.phase == .accepted,
                      let subjectDigest = state.verification?.subjectDigest else { return nil }
                return (nodeID, subjectDigest)
            })
        let trustedPromotions = try snapshot.nodeStates.compactMap {
            nodeID, state -> BuilderTransactionPromotionReceipt? in
            guard let promotion = state.promotion else { return nil }
            guard state.phase == .accepted,
                  state.attempts == promotion.attempt,
                  promotion.nodeID == nodeID,
                  promotion.hasValidReceiptDigest else {
                throw BuilderRunError.persistedStateInvalid(
                    "promotion receipt is stale, forged, or not bound to its accepted attempt")
            }
            if let selected = selectedContracts[nodeID] {
                guard selected.attempt == state.attempts,
                      selected.contractFingerprint == promotion.contractFingerprint else {
                    throw BuilderRunError.persistedStateInvalid(
                        "promotion receipt is not bound to the current selected execution contract")
                }
            }
            return promotion
        }
        let mutationObserved = trustedPromotions.contains { !$0.operations.isEmpty }
        switch contract.effectiveCompletionMode {
        case .build:
            guard mutationObserved else {
                throw BuilderRunError.finalVerificationFailed(
                    "build/change contract produced no governed workspace mutation")
            }
        case .verificationOnly:
            guard !mutationObserved else {
                throw BuilderRunError.finalVerificationFailed(
                    "verification-only contract forbids governed workspace mutations")
            }
        }
        try admitGraphGovernance(snapshot: &snapshot)
        try await persist(&snapshot)
        let finalProof: BuilderVerifierReceipt
        do {
            if let aggregate {
                guard let aggregateSource else {
                    throw BuilderRunError.invalidConfiguration(
                        "aggregate transaction source was not registered")
                }
                _ = try await aggregateSource.assertAggregateReady(aggregate)
            }
            finalProof = try await trustedFinalVerification(
                workers: workers, snapshot: &snapshot)
            guard finalProof.scope == .final, finalProof.deterministic,
                  finalProof.passed, finalProof.checks.allSatisfy(\.passed) else {
                let reason = finalProof.checks.filter { !$0.passed }
                    .map(\.details).joined(separator: "; ")
                throw BuilderRunError.finalVerificationFailed(
                    reason.nonEmpty ?? "deterministic verifier rejected")
            }
        } catch {
            if let aggregate, let aggregateSource {
                try? await aggregateSource.rollbackAggregate(
                    aggregate, reason: "final verification failed: \(error.localizedDescription)")
                for nodeID in governedRuntimes.keys.sorted() {
                    guard let runtime = governedRuntimes[nodeID],
                          let node = graph.nodes.first(where: { $0.id == nodeID }),
                          let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                    try? await runtime.rollbackCommitted(
                        node: node, attempt: attempt,
                        reason: "final verification failed: \(error.localizedDescription)")
                }
            }
            throw error
        }
        if contract.effectiveCompletionMode == .verificationOnly {
            guard let subject = finalProof.verificationSubject?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !subject.isEmpty,
                  let digest = finalProof.subjectDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !digest.isEmpty, !digest.hasPrefix("unavailable:") else {
                throw BuilderRunError.finalVerificationFailed(
                    "verification-only completion requires a concrete governed subject and digest")
            }
        }
        do {
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID] else { continue }
                try await runtime.ensureReviewProviderCapacity()
            }
        } catch {
            let reason = "review budget admission failed before invocation: \(error.localizedDescription)"
            let rollbackFailures = await rollbackGovernedReviewAttempt(
                runtimes: governedRuntimes, snapshot: &snapshot, reason: reason)
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw BuilderRunError.reviewRejected([reason])
        }
        let reviewTelemetryBinding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: parentContractFingerprint(contract),
            nodeID: graph.nodes.first?.id ?? "final-review",
            attempt: max(1, snapshot.nodeStates.values.map(\.attempts).max() ?? 1),
            stage: .review)
        let capturedReview = await BuilderTrustedTelemetry.captureScope(
            binding: reviewTelemetryBinding, registerBudgetAuthority: false) {
            try await self.review(.init(
                contract: self.contract, route: self.route, workers: workers,
                verification: finalProof,
                promotionReceipts: trustedPromotions,
                acceptedAttempts: acceptedAttempts,
                selectedContractFingerprints: selectedContractFingerprints,
                acceptedVerificationSubjectDigests:
                    acceptedVerificationSubjectDigests))
        }
        let rawReviewTelemetry = capturedReview.1
        snapshot.trustedTelemetry.append(contentsOf: rawReviewTelemetry)
        try await persist(&snapshot)
        var governedReviewTelemetry: [String: [BuilderTrustedTelemetryObservation]] = [:]
        do {
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let governedNode = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "governed review runtime is not bound to a graph node")
                }
                let telemetry = try BuilderTrustedTelemetry.rebound(
                    rawReviewTelemetry,
                    to: BuilderTrustedTelemetryBinding(
                        contractFingerprint: runtime.contract.fingerprint(),
                        nodeID: governedNode.id, attempt: attempt, stage: .review))
                try await runtime.recordReviewTelemetry(telemetry)
                governedReviewTelemetry[nodeID] = telemetry
            }
        } catch {
            let reason = "review budget accounting failed: \(error.localizedDescription)"
            let rollbackFailures = await rollbackGovernedReviewAttempt(
                runtimes: governedRuntimes, snapshot: &snapshot, reason: reason)
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw BuilderRunError.reviewRejected([reason])
        }
        let submittedReview: BuilderReviewReceipt
        do {
            submittedReview = try capturedReview.0.get()
        } catch {
            let reason = "independent review failed: \(error.localizedDescription)"
            let rollbackFailures = await rollbackGovernedReviewAttempt(
                runtimes: governedRuntimes, snapshot: &snapshot, reason: reason)
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw error
        }
        let reviewerIdentity = identity(submittedReview.provider, submittedReview.model)
        let rejectedDiagnostics = submittedReview.findings
            + (submittedReview.votes ?? []).filter(\.failed).map {
                "\($0.lens): \($0.reason)"
            }
        guard !reviewerIdentity.isEmpty else {
            if !submittedReview.accepted, !rejectedDiagnostics.isEmpty {
                throw BuilderRunError.reviewRejected(Array(Set(rejectedDiagnostics)).sorted())
            }
            throw BuilderRunError.reviewerNotIndependent("no distinct configured reviewer was available")
        }
        guard rawReviewTelemetry.hasAuthenticatedReviewerRoute(
            providerID: submittedReview.provider, modelID: submittedReview.model) else {
            if !submittedReview.accepted, !rejectedDiagnostics.isEmpty {
                // A host-side evidence gate can reject before any reviewer invocation. Preserve
                // that concrete fail-closed diagnosis instead of masking it with a secondary
                // missing-route error for a provider that was intentionally never called.
                throw BuilderRunError.reviewRejected(
                    Array(Set(rejectedDiagnostics)).sorted())
            }
            throw BuilderRunError.reviewRejected(
                ["reviewer identity has no trusted provider-route observation"])
        }
        if let votes = submittedReview.votes {
            let completed = votes.filter { !$0.failed }
            let routes = completed.compactMap { vote -> String? in
                guard let provider = vote.provider?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let model = vote.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !provider.isEmpty, !model.isEmpty else { return nil }
                return identity(provider, model)
            }
            if !routes.isEmpty {
                guard routes.count == completed.count,
                      Set(routes).count == 1,
                      routes[0] == reviewerIdentity,
                      completed.allSatisfy({ vote in
                          rawReviewTelemetry.hasAuthenticatedReviewerRoute(
                              providerID: vote.provider ?? "", modelID: vote.model ?? "")
                      }) else {
                    throw BuilderRunError.reviewRejected(
                        ["review votes do not share the authenticated reviewer route"])
                }
            }
        }
        if let threshold = submittedReview.reviewThreshold,
           !builderCouncilReviewVoteSemantics(
                submittedReview.votes ?? [], threshold: threshold) {
            throw BuilderRunError.reviewRejected([
                "review receipt does not preserve the 3-of-4 zero-veto council decision",
            ])
        }
        let builderIdentities = try canonicalProducerIdentities(contract: contract, workers: workers)
        let provenance: BuilderReviewProvenanceFacts
        switch contract.effectiveReviewPolicy.grade {
        case .independent:
            guard !builderIdentities.contains(reviewerIdentity) else {
                throw BuilderRunError.reviewerNotIndependent(reviewerIdentity)
            }
            provenance = BuilderReviewProvenanceFacts(
                reviewGrade: .independent, independent: true,
                freshConversation: nil, separateInvocation: nil,
                producerInvocationIDs: nil, reviewerInvocationIDs: nil,
                reviewThreshold: submittedReview.reviewThreshold)
        case .freshContextSameModel:
            provenance = try sameModelReviewProvenance(
                reviewerIdentity: reviewerIdentity,
                producerIdentities: builderIdentities,
                workers: workers,
                votes: submittedReview.votes ?? [],
                reviewThreshold: submittedReview.reviewThreshold,
                rawReviewTelemetry: rawReviewTelemetry,
                snapshot: snapshot)
        }
        let reviewReceipt = BuilderReviewReceipt(
            provider: submittedReview.provider,
            model: submittedReview.model,
            accepted: submittedReview.accepted,
            checks: submittedReview.checks,
            findings: submittedReview.findings,
            usage: submittedReview.usage,
            workerIdentities: builderIdentities.sorted(),
            reviewerIdentity: reviewerIdentity,
            evidencePacketDigest: submittedReview.evidencePacketDigest,
            votes: submittedReview.votes,
            reviewGrade: provenance.reviewGrade,
            independent: provenance.independent,
            freshConversation: provenance.freshConversation,
            separateInvocation: provenance.separateInvocation,
            producerInvocationIDs: provenance.producerInvocationIDs,
            reviewerInvocationIDs: provenance.reviewerInvocationIDs,
            reviewThreshold: provenance.reviewThreshold
        )
        if contract.producerIdentities != nil,
           reviewReceipt.evidencePacketDigest?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw BuilderRunError.reviewRejected(["outer review supplied no evidence-packet digest"])
        }
        snapshot.reviewAttempt = BuilderReviewAttemptReceipt(
            reviewerIdentity: reviewerIdentity, producerIdentities: builderIdentities.sorted(),
            evidencePacketDigest: reviewReceipt.evidencePacketDigest ?? "legacy-unbound",
            votes: reviewReceipt.votes ?? [],
            accepted: reviewReceipt.accepted && reviewReceipt.checks.allSatisfy(\.passed),
            attemptedAt: Date(),
            missionInstanceID: contract.checkpointIdentity.flatMap { value in
                value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
                    ? value : nil
            },
            reviewGrade: provenance.reviewGrade,
            independent: provenance.independent,
            freshConversation: provenance.freshConversation,
            separateInvocation: provenance.separateInvocation,
            producerInvocationIDs: provenance.producerInvocationIDs,
            reviewerInvocationIDs: provenance.reviewerInvocationIDs,
            reviewThreshold: provenance.reviewThreshold)
        try await persist(&snapshot)
        guard reviewReceipt.accepted, reviewReceipt.checks.allSatisfy(\.passed) else {
            var rollbackFailures: [String] = []
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                do {
                    try await runtime.rollbackCommitted(
                        node: node, attempt: attempt, reason: "independent review rejected")
                    snapshot.nodeStates[nodeID]?.phase = .failed
                    snapshot.nodeStates[nodeID]?.failureReason = "independent review rejected"
                } catch {
                    rollbackFailures.append("\(nodeID): \(error.localizedDescription)")
                }
            }
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "review rejected and rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw BuilderRunError.reviewRejected(reviewReceipt.findings)
        }
        var acceptedProof = finalProof
        do {
            if finalProof.subjectDigest != nil || contract.effectiveCompletionMode == .verificationOnly {
                let refreshed = try await trustedFinalVerification(
                    workers: workers, snapshot: &snapshot)
                guard refreshed.scope == .final, refreshed.deterministic, refreshed.passed,
                      refreshed.checks.allSatisfy(\.passed) else {
                    let reason = refreshed.checks.filter { !$0.passed }.map(\.details).joined(separator: "; ")
                    throw BuilderRunError.finalVerificationFailed(
                        reason.nonEmpty ?? "post-review deterministic verifier rejected")
                }
                guard refreshed.verificationSubject == finalProof.verificationSubject,
                      refreshed.subjectDigest == finalProof.subjectDigest else {
                    throw BuilderRunError.finalVerificationFailed(
                        "governed workspace digest changed during independent review")
                }
                acceptedProof = refreshed
            }
        } catch {
            let verificationError = error
            var rollbackFailures: [String] = []
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                do {
                    try await runtime.rollbackCommitted(
                        node: node, attempt: attempt,
                        reason: "post-review verification failed: \(verificationError.localizedDescription)")
                    snapshot.nodeStates[nodeID]?.phase = .failed
                    snapshot.nodeStates[nodeID]?.failureReason = verificationError.localizedDescription
                } catch {
                    rollbackFailures.append("\(nodeID): \(error.localizedDescription)")
                }
            }
            try await persist(&snapshot)
            if !rollbackFailures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "post-review verification failed and rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
            }
            throw verificationError
        }
        if !governedRuntimes.isEmpty {
            do {
                for nodeID in governedRuntimes.keys.sorted() {
                    guard let runtime = governedRuntimes[nodeID],
                          let governedNode = graph.nodes.first(where: { $0.id == nodeID }),
                          let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                        throw BuilderRunError.persistedStateInvalid(
                            "governed review runtime is not bound to a graph node")
                    }
                    try await runtime.verifyReview(
                        node: governedNode, attempt: attempt, workers: workers,
                        proof: acceptedProof, review: reviewReceipt,
                        trustedTelemetry: governedReviewTelemetry[nodeID] ?? [])
                }
            } catch {
                let reviewError = error
                var rollbackFailures: [String] = []
                for nodeID in governedRuntimes.keys.sorted() {
                    guard let runtime = governedRuntimes[nodeID],
                          let governedNode = graph.nodes.first(where: { $0.id == nodeID }),
                          let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                    do {
                        try await runtime.rollbackCommitted(
                            node: governedNode, attempt: attempt,
                            reason: "contract review verification failed: \(reviewError.localizedDescription)")
                        snapshot.nodeStates[nodeID]?.phase = .failed
                        snapshot.nodeStates[nodeID]?.failureReason = reviewError.localizedDescription
                    } catch {
                        rollbackFailures.append("\(nodeID): \(error.localizedDescription)")
                    }
                }
                try await persist(&snapshot)
                if !rollbackFailures.isEmpty {
                    throw BuilderRunError.finalVerificationFailed(
                        "contract review failed and rollback was not proven: \(rollbackFailures.joined(separator: "; "))")
                }
                throw BuilderRunError.reviewRejected([reviewError.localizedDescription])
            }
        }
        try validateTrustedTelemetry(snapshot)
        try validatePersistedReviewProvenance(
            reviewReceipt, workers: workers, snapshot: snapshot)
        let commitEpoch = BuilderEvidenceDigest.sha256(
            "\(contract.id):\(try parentContractFingerprint(contract)):\(Date().timeIntervalSince1970):\(UUID().uuidString)")
        let pendingFinal = BuilderFinalReceipt(
            contractID: contract.id, route: route, workers: workers,
            verification: acceptedProof, review: reviewReceipt, accepted: true,
            completedAt: Date())
        snapshot.reviewAccepted = true
        snapshot.commitEpoch = commitEpoch
        snapshot.finalizationPending = !governedRuntimes.isEmpty
        snapshot.pendingFinalReceipt = pendingFinal
        // This is the single durable run-level commit decision. No transaction may discard
        // rollback material until the accepted pending receipt and epoch are persisted.
        try await persist(&snapshot)
        if let aggregate {
            guard let aggregateSource else {
                throw BuilderRunError.invalidConfiguration(
                    "accepted aggregate run has no transaction source")
            }
            do {
                let finalizedProof = try await finalizeAcceptedAggregate(
                    aggregate, source: aggregateSource, commitEpoch: commitEpoch,
                    workers: workers, expected: acceptedProof,
                    runtimes: governedRuntimes, snapshot: &snapshot)
                let unsignedFinal = BuilderFinalReceipt(
                    contractID: pendingFinal.contractID, route: pendingFinal.route,
                    workers: pendingFinal.workers, verification: finalizedProof,
                    review: pendingFinal.review, accepted: true,
                    completedAt: pendingFinal.completedAt)
                let publishedFinal = try authorizePublishedFinal(
                    unsignedFinal, snapshot: snapshot)
                snapshot.finalizationPending = false
                snapshot.pendingFinalReceipt = nil
                snapshot.finalReceipt = publishedFinal
                try await persistAcceptedFinalReceipt(
                    publishedFinal, aggregate: aggregate, aggregateSource: aggregateSource,
                    runtimes: governedRuntimes, snapshot: &snapshot)
                return publishedFinal
            } catch {
                let original = error
                if snapshot.finalReceipt?.accepted != true {
                    let failures = await rollbackPendingGlobalAcceptance(
                        aggregate: aggregate, aggregateSource: aggregateSource,
                        runtimes: governedRuntimes, snapshot: &snapshot,
                        reason: "aggregate finalization failed: \(original.localizedDescription)")
                    if !failures.isEmpty {
                        throw BuilderRunError.finalVerificationFailed(
                            "aggregate finalization failed and rollback was not proven: \(failures.joined(separator: "; "))")
                    }
                    try await persist(&snapshot)
                }
                throw original
            }
        }
        do {
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "governed finalization runtime is not bound to a graph node")
                }
                try await runtime.markReviewApproved(node: node, attempt: attempt)
            }
            for nodeID in governedRuntimes.keys.sorted() {
                guard let runtime = governedRuntimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "governed finalization runtime is not bound to a graph node")
                }
                try await runtime.finalize(node: node, attempt: attempt)
            }
            let finalizedProof = try await trustedFinalVerification(
                workers: workers, snapshot: &snapshot)
            try validateTrustedTelemetry(snapshot)
            guard finalizedProof.scope == .final, finalizedProof.deterministic,
                  finalizedProof.passed, finalizedProof.checks.allSatisfy(\.passed),
                  finalizedProof.verificationSubject == acceptedProof.verificationSubject,
                  finalizedProof.subjectDigest == acceptedProof.subjectDigest else {
                throw BuilderRunError.finalVerificationFailed(
                    "finalized workspace changed after the pending acceptance decision")
            }
            let unsignedFinal = BuilderFinalReceipt(
                contractID: pendingFinal.contractID, route: pendingFinal.route,
                workers: pendingFinal.workers, verification: finalizedProof,
                review: pendingFinal.review, accepted: true,
                completedAt: pendingFinal.completedAt)
            let publishedFinal = try authorizePublishedFinal(
                unsignedFinal, snapshot: snapshot)
            snapshot.finalizationPending = false
            snapshot.pendingFinalReceipt = nil
            snapshot.finalReceipt = publishedFinal
            try await persistAcceptedFinalReceipt(
                publishedFinal, aggregate: nil, aggregateSource: nil,
                runtimes: governedRuntimes, snapshot: &snapshot)
            return publishedFinal
        } catch {
            let original = error
            if snapshot.finalReceipt?.accepted != true {
                let failures = await rollbackPendingGlobalAcceptance(
                    aggregate: nil, aggregateSource: nil,
                    runtimes: governedRuntimes, snapshot: &snapshot,
                    reason: "post-promotion final verification failed: \(original.localizedDescription)")
                if !failures.isEmpty {
                    throw BuilderRunError.finalVerificationFailed(
                        "post-promotion final verification failed and rollback was not proven: \(failures.joined(separator: "; "))")
                }
                try await persist(&snapshot)
            }
            throw original
        }
    }

    private func finalizeAcceptedAggregate(
        _ descriptor: BuilderAggregateTransactionDescriptor,
        source: BuilderIsolatedWorkspaceTransactionSource,
        commitEpoch: String,
        workers: [BuilderWorkerReceipt],
        expected: BuilderVerifierReceipt,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot
    ) async throws -> BuilderVerifierReceipt {
        do {
            try await source.markAggregateReviewApproved(
                descriptor, commitEpoch: commitEpoch)
            for nodeID in runtimes.keys.sorted() {
                guard let runtime = runtimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else {
                    throw BuilderRunError.persistedStateInvalid(
                        "aggregate review runtime is not bound to a graph node")
                }
                try await runtime.markReviewApproved(node: node, attempt: attempt)
            }
            _ = try await source.finalizeAggregate(descriptor)
            let proof = try await trustedFinalVerification(
                workers: workers, snapshot: &snapshot)
            try validateTrustedTelemetry(snapshot)
            guard proof.scope == .final, proof.deterministic, proof.passed,
                  proof.checks.allSatisfy(\.passed),
                  proof.verificationSubject == expected.verificationSubject,
                  proof.subjectDigest == expected.subjectDigest else {
                throw BuilderRunError.finalVerificationFailed(
                    "globally promoted aggregate differs from the reviewed staged subject")
            }
            try await source.completeAggregate(descriptor)
            for nodeID in runtimes.keys.sorted() {
                guard let runtime = runtimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                try await runtime.finalize(node: node, attempt: attempt)
            }
            return proof
        } catch {
            let original = error
            var failures: [String] = []
            do {
                try await source.rollbackAggregate(
                    descriptor, reason: original.localizedDescription)
            } catch {
                failures.append(error.localizedDescription)
            }
            for nodeID in runtimes.keys.sorted() {
                guard let runtime = runtimes[nodeID],
                      let node = graph.nodes.first(where: { $0.id == nodeID }),
                      let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
                do {
                    try await runtime.rollbackCommitted(
                        node: node, attempt: attempt,
                        reason: original.localizedDescription)
                } catch {
                    failures.append("\(nodeID): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "aggregate failure could not prove rollback: \(failures.joined(separator: "; "))")
            }
            throw original
        }
    }
    private func trustedFinalVerification(
        workers: [BuilderWorkerReceipt], snapshot: inout BuilderRunSnapshot
    ) async throws -> BuilderVerifierReceipt {
        let binding = try BuilderTrustedTelemetryBinding(
            contractFingerprint: parentContractFingerprint(contract),
            nodeID: "final-verification", attempt: 1, stage: .verification)
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: binding, registerBudgetAuthority: false) {
            try await self.verify(.final(
                contract: self.contract, route: self.route, workers: workers))
        }
        let telemetry = captured.1
        snapshot.trustedTelemetry.append(contentsOf: telemetry)
        try await persist(&snapshot)
        let proof = try captured.0.get()
        guard proof.scope == .final, proof.deterministic else {
            throw BuilderRunError.finalVerificationFailed(
                "final verifier did not return a deterministic final-scope proof")
        }
        // A negative deterministic proof is already safe to consume: the caller will
        // reject it and surface the failed check. Success evidence is required only
        // before a proof can authorize review or acceptance.
        if !proof.passed || !proof.checks.allSatisfy(\.passed) {
            return proof
        }
        if let fleet = proof.fleetVerification {
            try validateFleetFinalVerification(
                fleet, proof: proof, telemetry: telemetry, snapshot: snapshot)
            let obligations = proof.requiredSupportingObligations ?? []
            if !obligations.isEmpty {
                guard let receipts = proof.supportingCommandReceipts,
                      receipts.count >= obligations.count,
                      proof.planFinalVerificationReceipt != nil else {
                    throw BuilderRunError.finalVerificationFailed(
                        "supporting/final command receipts are incomplete")
                }
            }
            return proof
        }
        let hostDeterministic = builderIsHostDeterministicVerifier(
            provider: proof.provider, model: proof.model)
        let routeObserved = hostDeterministic
            ? telemetry.contains { $0.kind == .command && $0.success }
            : telemetry.hasSuccessfulProviderRoute(
                providerID: proof.provider, modelID: proof.model)
        guard routeObserved else {
            throw BuilderRunError.finalVerificationFailed(
                "final verifier identity has no trusted route observation")
        }
        guard let subject = proof.subjectDigest,
              subject.count == 64, !subject.hasPrefix("unavailable:"),
              let fingerprint = proof.contractFingerprint,
              fingerprint.count == 64 else {
            throw BuilderRunError.finalVerificationFailed(
                "final verifier supplied no canonical bound subject/contract digest")
        }
        let commands = telemetry.filter { $0.kind == .command }
        let evidence = proof.commandEvidence ?? []
        guard !commands.isEmpty,
              BuilderTrustedTelemetry.commandEvidenceMatches(
                evidence, observations: telemetry,
                contractFingerprint: fingerprint, subjectDigest: subject,
                requireBuilderOSSandbox: hostDeterministic) else {
            throw BuilderRunError.finalVerificationFailed(
                "final command evidence is missing, unbound, or not observed by the trusted launcher")
        }
        let obligations = proof.requiredSupportingObligations ?? []
        if !obligations.isEmpty {
            guard let receipts = proof.supportingCommandReceipts,
                  receipts.count >= obligations.count,
                  proof.planFinalVerificationReceipt != nil else {
                throw BuilderRunError.finalVerificationFailed(
                    "supporting/final command receipts are incomplete")
            }
        }
        return proof
    }

    private func validateFleetFinalVerification(
        _ fleet: BuilderFleetVerificationBundle,
        proof: BuilderVerifierReceipt,
        telemetry: [BuilderTrustedTelemetryObservation],
        snapshot: BuilderRunSnapshot
    ) throws {
        guard let policy = graphExecutionPolicy,
              let selections = snapshot.selectedExecutionContracts else {
            throw BuilderRunError.finalVerificationFailed(
                "fleet final proof has no selected partition contracts")
        }
        let mutationNodes = graph.nodes.filter {
            policy.executionClass(for: $0.id) == .mutation
        }.sorted { $0.id < $1.id }
        guard !mutationNodes.isEmpty,
              mutationNodes.allSatisfy({ $0.id.hasPrefix("fleet-") }),
              Set(selections.keys) == Set(mutationNodes.map(\.id)) else {
            throw BuilderRunError.finalVerificationFailed(
                "fleet selected contract set is incomplete or not partition-bound")
        }
        let parent = try parentContractFingerprint(contract)
        let graphDigest = BuilderEvidenceDigest.sha256(String(
            decoding: try BuilderDurableIO.canonicalData(graph), as: UTF8.self))
        guard snapshot.parentContractFingerprint == parent,
              snapshot.graphFingerprint == graphDigest,
              fleet.parentContractFingerprint == parent,
              fleet.graphFingerprint == graphDigest,
              proof.contractFingerprint == parent,
              proof.verificationSubject == fleet.verificationSubject,
              proof.subjectDigest == fleet.subjectDigest,
              proof.commandEvidence?.isEmpty == false,
              let verifiedAt = proof.verifiedAt,
              verifiedAt >= (fleet.children.map(\.verifiedAt).max() ?? verifiedAt) else {
            throw BuilderRunError.finalVerificationFailed(
                "fleet aggregate proof is not bound to the parent contract and graph")
        }
        let verifierIdentity: BuilderModelIdentity
        do {
            verifierIdentity = try BuilderModelIdentity(
                providerID: proof.provider, modelID: proof.model)
        } catch {
            throw BuilderRunError.finalVerificationFailed(
                "fleet aggregate verifier identity is invalid")
        }
        let expected = try mutationNodes.map { node -> BuilderFleetChildVerificationExpectation in
            guard let selection = selections[node.id] else {
                throw BuilderFleetVerificationError.invalid(
                    "selected contract is missing for \(node.id)")
            }
            let graphPaths = node.resources.filter { $0.access == .write }.map(\.path).sorted()
            let mutationPaths = selection.sealedContract.contract.mutations.map(\.path).sorted()
            guard graphPaths == mutationPaths else {
                throw BuilderFleetVerificationError.invalid(
                    "graph claims and selected mutations differ for \(node.id)")
            }
            return try BuilderFleetChildVerificationExpectation(
                nodeID: node.id, attempt: selection.attempt,
                partitionPaths: graphPaths,
                contractFingerprint: selection.contractFingerprint)
        }
        do {
            guard let subject = proof.subjectDigest,
                  let verificationSubject = proof.verificationSubject,
                  let aggregateEvidence = proof.commandEvidence,
                  !aggregateEvidence.isEmpty else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate command evidence is missing")
            }
            let aggregateReferences = aggregateEvidence.compactMap(\.trustedCommandReference)
            let childEvidence = fleet.children.flatMap(\.commandEvidence)
            let childReferences = childEvidence.compactMap(\.trustedCommandReference)
            guard aggregateReferences.count == aggregateEvidence.count,
                  childReferences.count == childEvidence.count,
                  Set(aggregateReferences.map(\.observationID)).count
                    == aggregateReferences.count,
                  Set(aggregateReferences.map(\.invocationID)).count
                    == aggregateReferences.count,
                  Set(childReferences.map(\.observationID)).count
                    == childReferences.count,
                  Set(childReferences.map(\.invocationID)).count
                    == childReferences.count else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate or child command evidence is duplicated")
            }
            let aggregateObservationIDs = Set(aggregateReferences.map(\.observationID))
            let childObservationIDs = Set(childReferences.map(\.observationID))
            let aggregateInvocationIDs = Set(aggregateReferences.map(\.invocationID))
            let childInvocationIDs = Set(childReferences.map(\.invocationID))
            guard aggregateObservationIDs.isDisjoint(with: childObservationIDs),
                  aggregateInvocationIDs.isDisjoint(with: childInvocationIDs) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate command evidence reuses child telemetry")
            }
            let commandTelemetry = telemetry.filter { $0.kind == .command }
            guard Set(commandTelemetry.map(\.id))
                    == aggregateObservationIDs.union(childObservationIDs) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet final command telemetry is missing or unclaimed")
            }
            let aggregateTelemetry = commandTelemetry.filter {
                aggregateObservationIDs.contains($0.id)
            }
            guard aggregateTelemetry.allSatisfy({
                      $0.contractFingerprint == parent
                          && $0.nodeID == "final-verification"
                          && $0.attempt == 1
                          && $0.stage == .verification
                  }),
                  BuilderTrustedTelemetry.commandEvidenceMatches(
                      aggregateEvidence, observations: aggregateTelemetry,
                      contractFingerprint: parent, subjectDigest: subject,
                      requireBuilderOSSandbox: true) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet aggregate command evidence is not parent-bound trusted telemetry")
            }
            let rootIdentity = try BuilderWorkspaceRootIdentity.capture(
                rootPath: verificationSubject)
            let allEvidence = aggregateEvidence + childEvidence
            let commandTools = telemetry.filter {
                $0.kind == .tool && $0.name == "run_command"
            }
            let expectedArgumentCounts = Dictionary(
                grouping: allEvidence, by: \.argsFingerprint).mapValues(\.count)
            let observedArgumentCounts = Dictionary(
                grouping: commandTools, by: \.subjectDigest).mapValues(\.count)
            guard commandTools.count == allEvidence.count,
                  expectedArgumentCounts == observedArgumentCounts,
                  commandTools.allSatisfy({
                      $0.success && $0.workspaceRootIdentity == rootIdentity
                  }) else {
                throw BuilderFleetVerificationError.invalid(
                    "fleet command tools are not completely bound to the aggregate workspace identity")
            }
            let childTelemetry = commandTelemetry.filter {
                !aggregateObservationIDs.contains($0.id)
            }
            try fleet.validate(
                expectedChildren: expected, verifierIdentity: verifierIdentity,
                observations: childTelemetry)
        } catch {
            throw BuilderRunError.finalVerificationFailed(error.localizedDescription)
        }
    }

    private func sameModelReviewProvenance(
        reviewerIdentity: String,
        producerIdentities: Set<String>,
        workers: [BuilderWorkerReceipt],
        votes: [BuilderReviewVoteReceipt],
        reviewThreshold: Int?,
        rawReviewTelemetry: [BuilderTrustedTelemetryObservation],
        snapshot: BuilderRunSnapshot
    ) throws -> BuilderReviewProvenanceFacts {
        let policy = contract.effectiveReviewPolicy
        guard policy.authorizesDisposableFreshContextSameModel,
              producerIdentities == [reviewerIdentity],
              workers.count == 1,
              identity(workers[0].provider, workers[0].model) == reviewerIdentity,
              workers[0].claimsSubscriptionCLI else {
            throw BuilderRunError.reviewRejected([
                "fresh_context_same_model provenance is not bound to one exact subscription-CLI producer",
            ])
        }

        guard reviewThreshold == 3,
              builderCouncilReviewVoteSemantics(votes, threshold: 3) else {
            throw BuilderRunError.reviewRejected([
                "fresh_context_same_model requires the sealed 3-of-4 zero-veto council protocol",
            ])
        }
        let completedVotes = votes.filter { !$0.failed }
        let lensInvocationIDs = completedVotes.compactMap(\.invocationID)
        let voteRoutes = completedVotes.compactMap { vote -> String? in
            guard let provider = vote.provider, let model = vote.model else { return nil }
            return identity(provider, model)
        }
        guard !completedVotes.isEmpty,
              completedVotes.allSatisfy({ $0.freshConversation == true }),
              lensInvocationIDs.count == completedVotes.count,
              Set(lensInvocationIDs).count == completedVotes.count,
              voteRoutes.count == completedVotes.count,
              voteRoutes.allSatisfy({ $0 == reviewerIdentity }) else {
            throw BuilderRunError.reviewRejected([
                "fresh_context_same_model votes lack unique fresh-call provenance on the exact route",
            ])
        }

        let expectedParent = try parentContractFingerprint(contract)
        guard !rawReviewTelemetry.isEmpty,
              rawReviewTelemetry.allSatisfy({
                  $0.contractFingerprint == expectedParent && $0.stage == .review
              }) else {
            throw BuilderRunError.reviewRejected([
                "fresh_context_same_model telemetry is not bound to the parent review stage",
            ])
        }
        for observation in rawReviewTelemetry {
            try observation.validate(binding: .init(
                contractFingerprint: observation.contractFingerprint,
                nodeID: observation.nodeID, attempt: observation.attempt,
                stage: observation.stage))
        }
        let providerObservations = rawReviewTelemetry.filter { $0.kind == .provider }
        let successfulProviders = providerObservations.filter(\.success)
        guard providerObservations.allSatisfy({
                  identity($0.providerID ?? "", $0.modelID ?? "") == reviewerIdentity
                      && $0.name.hasPrefix("completion")
              }),
              successfulProviders.count == completedVotes.count,
              successfulProviders.allSatisfy({ $0.name == "completion" }) else {
            throw BuilderRunError.reviewRejected([
                "fresh_context_same_model provider telemetry is missing, extra, or not exact-route",
            ])
        }
        let reviewerCLI = rawReviewTelemetry.filter { $0.kind == .cliProviderInvocation }
        guard reviewerCLI.count == completedVotes.count,
              reviewerCLI.allSatisfy({ observation in
                  guard observation.success,
                        identity(observation.providerID ?? "", observation.modelID ?? "")
                            == reviewerIdentity,
                        let receipt = observation.cliRouteReceipt else { return false }
                  return receipt.isValid && receipt.observationID == observation.id
                      && receipt.stage == .review
              }),
              Set(reviewerCLI.map(\.id)).count == reviewerCLI.count else {
            throw BuilderRunError.reviewRejected([
                "fresh_context_same_model lacks one authenticated CLI process observation per completed vote",
            ])
        }

        var producerInvocationIDs: [String] = []
        for worker in workers {
            guard let receipts = worker.trustedCLIRouteReceipts, !receipts.isEmpty,
                  let stateTelemetry = snapshot.nodeStates[worker.nodeID]?.trustedTelemetry else {
                throw BuilderRunError.reviewRejected([
                    "fresh_context_same_model producer CLI invocation evidence is unavailable",
                ])
            }
            let producerCLI = stateTelemetry.filter { $0.kind == .cliProviderInvocation }
            guard receipts.allSatisfy({ receipt in
                      receipt.isValid && receipt.stage == .build
                          && identity(receipt.providerID, receipt.modelID) == reviewerIdentity
                  }),
                  producerCLI.allSatisfy({ observation in
                      observation.success
                          && identity(observation.providerID ?? "", observation.modelID ?? "")
                              == reviewerIdentity
                          && observation.cliRouteReceipt?.isValid == true
                  }),
                  Set(receipts.map(\.observationID)) == Set(producerCLI.map(\.id)),
                  receipts.allSatisfy({ receipt in
                      producerCLI.contains(where: {
                          $0.id == receipt.observationID && $0.cliRouteReceipt == receipt
                      })
                  }) else {
                throw BuilderRunError.reviewRejected([
                    "fresh_context_same_model producer CLI receipts are missing, extra, or unmatched",
                ])
            }
            producerInvocationIDs.append(contentsOf: receipts.map(\.observationID))
        }
        let producerSet = Set(producerInvocationIDs)
        let reviewerSet = Set(reviewerCLI.map(\.id))
        guard !producerSet.isEmpty,
              producerSet.count == producerInvocationIDs.count,
              producerSet.isDisjoint(with: reviewerSet) else {
            throw BuilderRunError.reviewRejected([
                "fresh_context_same_model producer and reviewer process invocations are not separate",
            ])
        }
        return BuilderReviewProvenanceFacts(
            reviewGrade: .freshContextSameModel, independent: false,
            freshConversation: true, separateInvocation: true,
            producerInvocationIDs: producerSet.sorted(),
            reviewerInvocationIDs: reviewerSet.sorted(), reviewThreshold: 3)
    }

    private func validatePersistedReviewProvenance(
        _ review: BuilderReviewReceipt,
        workers: [BuilderWorkerReceipt],
        snapshot: BuilderRunSnapshot
    ) throws {
        let producers = try canonicalProducerIdentities(contract: contract, workers: workers)
        guard let storedReviewer = canonicalIdentity(review.reviewerIdentity ?? ""),
              identity(review.provider, review.model) == storedReviewer,
              let storedProducers = canonicalIdentitySet(review.workerIdentities ?? []),
              storedProducers == producers else {
            throw BuilderRunError.persistedStateInvalid(
                "completion review has missing or mismatched provider:model provenance")
        }
        switch contract.effectiveReviewPolicy.grade {
        case .independent:
            guard !producers.contains(storedReviewer),
                  review.reviewGrade == nil || review.reviewGrade == .independent,
                  review.independent == nil || review.independent == true else {
                throw BuilderRunError.reviewerNotIndependent(
                    "persisted completion reviewer is not distinct from every producer")
            }
            if let threshold = review.reviewThreshold {
                guard builderCouncilReviewVoteSemantics(
                          review.votes ?? [], threshold: threshold),
                      snapshot.reviewAttempt?.reviewThreshold == threshold else {
                    throw BuilderRunError.persistedStateInvalid(
                        "persisted independent review lost its council threshold or zero-veto decision")
                }
            }
        case .freshContextSameModel:
            let parent = try parentContractFingerprint(contract)
            let reviewTelemetry = snapshot.trustedTelemetry.filter { $0.stage == .review }
            guard reviewTelemetry.allSatisfy({ $0.contractFingerprint == parent }) else {
                throw BuilderRunError.persistedStateInvalid(
                    "persisted review contains telemetry outside the parent contract")
            }
            let facts: BuilderReviewProvenanceFacts
            do {
                facts = try sameModelReviewProvenance(
                    reviewerIdentity: storedReviewer,
                    producerIdentities: producers,
                    workers: workers,
                    votes: review.votes ?? [],
                    reviewThreshold: review.reviewThreshold,
                    rawReviewTelemetry: reviewTelemetry,
                    snapshot: snapshot)
            } catch {
                throw BuilderRunError.persistedStateInvalid(
                    "persisted same-model review provenance is invalid: \(error.localizedDescription)")
            }
            guard review.reviewGrade == facts.reviewGrade,
                  review.independent == facts.independent,
                  review.freshConversation == facts.freshConversation,
                  review.separateInvocation == facts.separateInvocation,
                  review.producerInvocationIDs == facts.producerInvocationIDs,
                  review.reviewerInvocationIDs == facts.reviewerInvocationIDs,
                  review.reviewThreshold == facts.reviewThreshold,
                  review.accepted, review.checks.allSatisfy(\.passed),
                  let digest = review.evidencePacketDigest,
                  digest.count == 64,
                  digest.allSatisfy({ "0123456789abcdef".contains($0) }),
                  let attempt = snapshot.reviewAttempt,
                  attempt.reviewerIdentity == storedReviewer,
                  Set(attempt.producerIdentities) == producers,
                  attempt.evidencePacketDigest == digest,
                  attempt.votes == (review.votes ?? []),
                  attempt.accepted,
                  attempt.reviewGrade == facts.reviewGrade,
                  attempt.independent == facts.independent,
                  attempt.freshConversation == facts.freshConversation,
                  attempt.separateInvocation == facts.separateInvocation,
                  attempt.producerInvocationIDs == facts.producerInvocationIDs,
                  attempt.reviewerInvocationIDs == facts.reviewerInvocationIDs,
                  attempt.reviewThreshold == facts.reviewThreshold else {
                throw BuilderRunError.persistedStateInvalid(
                    "persisted same-model review receipt does not match its authenticated evidence")
            }
        }
    }

    private func validateTrustedTelemetry(_ snapshot: BuilderRunSnapshot) throws {
        let ids = snapshot.trustedTelemetry.map(\.id)
        guard Set(ids).count == ids.count else {
            throw BuilderRunError.persistedStateInvalid(
                "trusted telemetry observation ID was omitted or reused")
        }
        for observation in snapshot.trustedTelemetry {
            try observation.validate(binding: .init(
                contractFingerprint: observation.contractFingerprint,
                nodeID: observation.nodeID, attempt: observation.attempt,
                stage: observation.stage))
        }
        for state in snapshot.nodeStates.values {
            guard let worker = state.worker else { continue }
            guard worker.trustedCLIInvocationsMatch(
                snapshot.trustedTelemetry, requireComplete: false) else {
                throw BuilderRunError.persistedStateInvalid(
                    "worker CLI route receipt is missing, forged, reused, or unmatched")
            }
        }
        if let maxTokens = contract.maxTokens {
            let total = snapshot.trustedTelemetry
                .filter { $0.kind == .provider }
                .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
            guard total > 0, total <= maxTokens else {
                throw BuilderRunError.finalVerificationFailed(
                    "trusted token usage is omitted or exceeds BuilderContract.maxTokens (\(total)/\(maxTokens))")
            }
        }
    }

    private func validateGlobalDecisionState(_ snapshot: BuilderRunSnapshot) throws {
        let pending = snapshot.pendingFinalReceipt
        let final = snapshot.finalReceipt
        guard pending == nil || final == nil else {
            throw BuilderRunError.persistedStateInvalid(
                "pending and public final receipts cannot coexist")
        }
        if snapshot.reviewAccepted {
            guard let epoch = snapshot.commitEpoch,
                  epoch.count == 64,
                  epoch.allSatisfy({ "0123456789abcdef".contains($0) }),
                  pending?.accepted == true || final?.accepted == true else {
                throw BuilderRunError.persistedStateInvalid(
                    "accepted review lacks a sealed run-level decision")
            }
        } else {
            guard snapshot.commitEpoch == nil, pending == nil, final == nil,
                  !snapshot.finalizationPending else {
                throw BuilderRunError.persistedStateInvalid(
                    "receipt or commit epoch exists before global review acceptance")
            }
        }
        guard !snapshot.finalizationPending || pending?.accepted == true else {
            throw BuilderRunError.persistedStateInvalid(
                "finalization is pending without an accepted pending receipt")
        }
    }

    private func restoredSnapshot() async throws -> BuilderRunSnapshot {
        if resumeExisting {
            guard var loaded = try await store.load() else {
                throw BuilderRunError.persistedStateMismatch
            }
            let graphIDs = Set(graph.nodes.map(\.id))
            guard loaded.schemaVersion == 2,
                  loaded.contractID == contract.id, loaded.route == route,
                  loaded.checkpointIdentity == contract.checkpointIdentity,
                  loaded.parentContractFingerprint == (try parentContractFingerprint(contract)),
                  loaded.graphFingerprint == (try builderGraphFingerprint(graph)),
                  Set(loaded.nodeStates.keys) == graphIDs else {
                throw BuilderRunError.persistedStateMismatch
            }
            try validateGlobalDecisionState(loaded)
            for id in graphIDs {
                if loaded.nodeStates[id]?.phase == .accepted && loaded.nodeStates[id]?.worker == nil {
                    throw BuilderRunError.persistedStateInvalid("accepted node \(id) has no receipt")
                }
                if loaded.nodeStates[id]?.phase == .running || loaded.nodeStates[id]?.phase == .verifying {
                    loaded.nodeStates[id]?.phase = .pending
                }
            }
            loaded.checkpointIdentity = contract.checkpointIdentity ?? loaded.checkpointIdentity
            if loaded.finalReceipt?.accepted == true {
                guard loaded.reviewAccepted, loaded.commitEpoch?.count == 64,
                      loaded.pendingFinalReceipt == nil, !loaded.finalizationPending else {
                    throw BuilderRunError.persistedStateInvalid(
                        "accepted snapshot lacks a complete global commit decision")
                }
            }
            try await persist(&loaded)
            return loaded
        }
        var snapshot = BuilderRunSnapshot(
            contractID: contract.id,
            checkpointIdentity: contract.checkpointIdentity,
            route: route,
            nodeStates: Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, BuilderNodeState()) }),
            finalReceipt: nil,
            updatedAt: Date()
        )
        snapshot.parentContractFingerprint = try parentContractFingerprint(contract)
        snapshot.graphFingerprint = try builderGraphFingerprint(graph)
        try await store.create(snapshot)
        return snapshot
    }
    private func blockDescendants(in snapshot: inout BuilderRunSnapshot) {
        var changed = true
        while changed {
            changed = false
            for node in graph.nodes where snapshot.nodeStates[node.id]?.phase == .pending {
                let blocker = node.dependencies.first {
                    let phase = snapshot.nodeStates[$0]?.phase
                    return phase == .failed || phase == .blocked
                }
                if let blocker {
                    snapshot.nodeStates[node.id]?.phase = .blocked
                    snapshot.nodeStates[node.id]?.failureReason = "blocked by \(blocker)"
                    changed = true
                }
            }
        }
    }
    private func rollbackGovernedReviewAttempt(
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot,
        reason: String
    ) async -> [String] {
        var failures: [String] = []
        for nodeID in runtimes.keys.sorted() {
            guard let runtime = runtimes[nodeID],
                  let node = graph.nodes.first(where: { $0.id == nodeID }),
                  let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
            do {
                try await runtime.rollbackCommitted(
                    node: node, attempt: attempt, reason: reason)
                snapshot.nodeStates[nodeID]?.phase = .failed
                snapshot.nodeStates[nodeID]?.failureReason = reason
            } catch {
                failures.append("\(nodeID): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func rollbackPendingGlobalAcceptance(
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: BuilderIsolatedWorkspaceTransactionSource?,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot,
        reason: String
    ) async -> [String] {
        var failures: [String] = []
        if let aggregate {
            guard let aggregateSource else {
                failures.append("aggregate transaction source is unavailable")
                return failures
            }
            do {
                try await aggregateSource.rollbackAggregate(aggregate, reason: reason)
            } catch {
                failures.append("aggregate: \(error.localizedDescription)")
            }
        }
        failures.append(contentsOf: await rollbackGovernedReviewAttempt(
            runtimes: runtimes, snapshot: &snapshot, reason: reason))
        if failures.isEmpty {
            snapshot.reviewAccepted = false
            snapshot.commitEpoch = nil
            snapshot.finalizationPending = false
            snapshot.pendingFinalReceipt = nil
            snapshot.finalReceipt = nil
        }
        return failures
    }

    private func persistAcceptedFinalReceipt(
        _ receipt: BuilderFinalReceipt,
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: BuilderIsolatedWorkspaceTransactionSource?,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: inout BuilderRunSnapshot
    ) async throws {
        try validatePublishedFinalAuthority(receipt, snapshot: snapshot)
        do {
            try await persist(&snapshot)
        } catch {
            let persistenceError = error
            if let durable = try? await store.load(),
               durable.finalReceipt == receipt,
               durable.pendingFinalReceipt == nil,
               durable.finalizationPending == false,
               durable.reviewAccepted == true {
                try validatePublishedFinalAuthority(receipt, snapshot: durable)
                snapshot = durable
                try await commitAcceptedFinalExternally(receipt, snapshot: snapshot)
                await releaseAcceptedRetainedData(
                    aggregate: aggregate, aggregateSource: aggregateSource,
                    runtimes: runtimes, snapshot: snapshot)
                return
            }
            snapshot.finalReceipt = nil
            let reason = "accepted final receipt persistence was not proven: \(persistenceError.localizedDescription)"
            let failures = await rollbackPendingGlobalAcceptance(
                aggregate: aggregate, aggregateSource: aggregateSource,
                runtimes: runtimes, snapshot: &snapshot, reason: reason)
            if !failures.isEmpty {
                throw BuilderRunError.finalVerificationFailed(
                    "\(reason); rollback was not proven: \(failures.joined(separator: "; "))")
            }
            do {
                try await persist(&snapshot)
            } catch {
                throw BuilderRunError.persistedStateInvalid(
                    "\(reason); rollback succeeded but its cleared acceptance state could not be persisted: \(error.localizedDescription)")
            }
            throw persistenceError
        }
        try await commitAcceptedFinalExternally(receipt, snapshot: snapshot)
        await releaseAcceptedRetainedData(
            aggregate: aggregate, aggregateSource: aggregateSource,
            runtimes: runtimes, snapshot: snapshot)
    }

    private func authorizePublishedFinal(
        _ receipt: BuilderFinalReceipt,
        snapshot: BuilderRunSnapshot
    ) throws -> BuilderFinalReceipt {
        guard let parent = snapshot.parentContractFingerprint,
              let graph = snapshot.graphFingerprint,
              let epoch = snapshot.commitEpoch else {
            throw BuilderRunError.persistedStateInvalid(
                "accepted Builder final lacks parent, graph, or commit authority")
        }
        let authorized = try receipt.authorizing(
            parentContractFingerprint: parent,
            graphFingerprint: graph,
            objectiveFingerprint: builderFinalObjectiveFingerprint(contract),
            commitEpoch: epoch,
            trustedTelemetry: snapshot.trustedTelemetry)
        try validatePublishedFinalAuthority(authorized, snapshot: snapshot)
        return authorized
    }

    private func validatePublishedFinalAuthority(
        _ receipt: BuilderFinalReceipt,
        snapshot: BuilderRunSnapshot
    ) throws {
        let telemetryDigest = try BuilderEvidenceDigest.sha256(String(
            decoding: BuilderDurableIO.canonicalData(snapshot.trustedTelemetry), as: UTF8.self))
        guard receipt.hasValidBuilderFinalAuthority,
              let authority = receipt.authority,
              authority.parentContractFingerprint == snapshot.parentContractFingerprint,
              authority.graphFingerprint == snapshot.graphFingerprint,
              authority.objectiveFingerprint == builderFinalObjectiveFingerprint(contract),
              authority.commitEpoch == snapshot.commitEpoch,
              authority.trustedTelemetryDigest == telemetryDigest else {
            throw BuilderRunError.persistedStateInvalid(
                "published Builder final authority is missing, forged, or detached from durable telemetry")
        }
    }

    private func commitAcceptedFinalExternally(
        _ receipt: BuilderFinalReceipt,
        snapshot: BuilderRunSnapshot
    ) async throws {
        guard let finalAcceptanceCommit else { return }
        guard let parent = snapshot.parentContractFingerprint,
              let graph = snapshot.graphFingerprint,
              let epoch = snapshot.commitEpoch else {
            throw BuilderRunError.persistedStateInvalid(
                "external Builder acceptance lacks durable parent, graph, or commit identity")
        }
        let authority = try BuilderFinalAcceptanceAuthority(
            finalReceipt: receipt,
            trustedTelemetry: snapshot.trustedTelemetry,
            parentContractFingerprint: parent,
            graphFingerprint: graph,
            objectiveFingerprint: builderFinalObjectiveFingerprint(contract),
            commitEpoch: epoch)
        do {
            try await finalAcceptanceCommit(authority)
        } catch {
            throw BuilderRunError.acceptancePersistencePending(
                error.localizedDescription)
        }
    }

    private func releaseAcceptedRetainedData(
        aggregate: BuilderAggregateTransactionDescriptor?,
        aggregateSource: BuilderIsolatedWorkspaceTransactionSource?,
        runtimes: [String: BuilderExecutionGovernanceRuntime],
        snapshot: BuilderRunSnapshot
    ) async {
        guard snapshot.finalReceipt?.accepted == true,
              snapshot.pendingFinalReceipt == nil,
              !snapshot.finalizationPending else { return }
        if let aggregate, let aggregateSource {
            try? await aggregateSource.releaseAggregate(aggregate)
        }
        for nodeID in runtimes.keys.sorted() {
            guard let runtime = runtimes[nodeID],
                  let node = graph.nodes.first(where: { $0.id == nodeID }),
                  let attempt = snapshot.nodeStates[nodeID]?.attempts else { continue }
            try? await runtime.releaseRetainedData(node: node, attempt: attempt)
        }
    }
    private func selectBatch(from ready: [BuilderNode]) -> [BuilderNode] {
        var selected: [BuilderNode] = []
        for node in ready.sorted(by: { $0.id < $1.id }) {
            guard selected.count < maxParallelism else { break }
            let conflicts = selected.contains { other in
                node.resources.contains { left in
                    other.resources.contains { right in
                        pathsOverlap(left.path, right.path) && (left.access == .write || right.access == .write)
                    }
                }
            }
            if !conflicts { selected.append(node) }
        }
        return selected.isEmpty ? Array(ready.prefix(1)) : selected
    }
    private func persist(_ snapshot: inout BuilderRunSnapshot) async throws {
        snapshot.updatedAt = Date()
        snapshot.sequence += 1
        try await store.save(snapshot)
    }
}
private func identity(_ provider: String, _ model: String) -> String {
    let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let model = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return provider.isEmpty || model.isEmpty ? "" : "\(provider):\(model)"
}
private func canonicalIdentity(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = value.firstIndex(of: ":"), separator != value.startIndex else { return nil }
    let modelStart = value.index(after: separator)
    guard modelStart != value.endIndex else { return nil }
    let canonical = identity(String(value[..<separator]), String(value[modelStart...]))
    return canonical.isEmpty ? nil : canonical
}
private func canonicalIdentitySet(_ values: [String]) -> Set<String>? {
    let canonical = values.compactMap(canonicalIdentity)
    return canonical.count == values.count ? Set(canonical) : nil
}
private func canonicalProducerIdentities(
    contract: BuilderContract,
    workers: [BuilderWorkerReceipt]
) throws -> Set<String> {
    let workerIdentities = workers.map { identity($0.provider, $0.model) }
    guard !workerIdentities.contains("") else {
        throw BuilderRunError.persistedStateInvalid("builder provider:model identity is empty")
    }
    guard let declared = canonicalIdentitySet(contract.producerIdentities ?? []) else {
        throw BuilderRunError.persistedStateInvalid("declared producer provider:model identity is malformed")
    }
    return Set(workerIdentities).union(declared)
}
private func validateBuilderReviewConfiguration(
    contract: BuilderContract,
    graph: BuilderGraph,
    graphExecutionPolicy: BuilderGraphExecutionPolicy?
) throws {
    let policy = contract.effectiveReviewPolicy
    guard policy.grade == .freshContextSameModel else { return }
    guard contract.reviewPolicy != nil,
          policy.authorizesDisposableFreshContextSameModel else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model requires the exact disposable low-risk review policy")
    }
    guard contract.effectiveCompletionMode == .build,
          contract.routeHint.resolve() == .direct,
          contract.routeHint.risk != .high,
          contract.routeHint.risk != .critical,
          !contract.routeHint.requiresResearch,
          !contract.routeHint.requiresSimulation else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model is limited to a direct low-effect-risk build")
    }
    guard contract.allowedPaths.count == 1,
          let allowed = contract.allowedPaths.first,
          (try? BuilderExecutionValidation.path(allowed)) == allowed else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model requires one normalized file path")
    }
    guard let declared = canonicalIdentitySet(contract.producerIdentities ?? []),
          declared.count == 1,
          let producer = declared.first,
          producer.hasPrefix("codex-cli:") || producer.hasPrefix("claude-cli:") else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model requires one exact subscription-CLI producer identity")
    }
    guard graph.nodes.count == 1,
          let node = graph.nodes.first,
          node.isolation == .sandbox,
          node.role == .builder,
          node.resources == [BuilderResourceClaim(path: allowed, access: .write)],
          graphExecutionPolicy?.executionClass(for: node.id) == .mutation else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model requires one sandboxed mutation node with one exact write claim")
    }
}
private func validateBuilderExecutionReviewPolicy(
    _ child: BuilderExecutionContract,
    parent: BuilderContract
) throws {
    let policy = parent.effectiveReviewPolicy
    guard child.identities.effectiveReviewGrade == policy.grade else {
        throw BuilderRunError.invalidConfiguration(
            "sealed child review grade does not match its parent BuilderContract")
    }
    guard policy.grade == .freshContextSameModel else { return }
    guard policy.authorizesDisposableFreshContextSameModel,
          child.mutations.count == policy.maximumMutationPaths,
          child.identities.producers.count == 1,
          child.identities.reviewers.count == 1,
          let producer = canonicalIdentity(child.identities.producers[0].canonicalID),
          let reviewer = canonicalIdentity(child.identities.reviewers[0].canonicalID),
          producer == reviewer,
          canonicalIdentitySet(parent.producerIdentities ?? []) == [producer] else {
        throw BuilderRunError.invalidConfiguration(
            "sealed child does not preserve the exact same-model disposable review authority")
    }
}
private func validateBuilderDisposableReviewSource(
    _ source: (any BuilderStageObservationSource)?,
    parent: BuilderContract
) throws {
    let policy = parent.effectiveReviewPolicy
    guard policy.grade == .freshContextSameModel else { return }
    guard policy.authorizesDisposableFreshContextSameModel,
          let transaction = source as? BuilderIsolatedWorkspaceTransactionSource,
          transaction.usesOSProcessSandbox else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model requires the exact OS-sandboxed isolated workspace source")
    }

    let rootIdentity = try BuilderWorkspaceRootIdentity.capture(
        rootPath: transaction.projectRoot.path)
    let boundIdentity = BuilderEvidenceDigest.sha256([
        rootIdentity.canonicalPath,
        String(rootIdentity.deviceID),
        String(rootIdentity.inode),
    ].joined(separator: "\u{0}"))
    guard boundIdentity == policy.disposableRootIdentity else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model governed root does not match its sealed filesystem identity")
    }

    let fm = FileManager.default
    let root = URL(fileURLWithPath: rootIdentity.canonicalPath, isDirectory: true)
    let tempRoots = Set([
        "/private/tmp", "/tmp", NSTemporaryDirectory(),
    ].compactMap { raw -> String? in
        try? BuilderWorkspaceRootIdentity.capture(rootPath: raw).canonicalPath
    })
    guard let boundary = tempRoots
        .filter({ root.path.hasPrefix($0 + "/") })
        .max(by: { $0.count < $1.count }) else {
        throw BuilderRunError.invalidConfiguration(
            "fresh_context_same_model governed root is not a disposable temp descendant")
    }

    var rootCursor = root
    while rootCursor.path != boundary {
        guard rootCursor.path.hasPrefix(boundary + "/"),
              !fm.fileExists(atPath: rootCursor.appendingPathComponent(".git").path) else {
            throw BuilderRunError.invalidConfiguration(
                "fresh_context_same_model governed root is inside a Git worktree")
        }
        let parentURL = rootCursor.deletingLastPathComponent()
        guard parentURL.path != rootCursor.path else {
            throw BuilderRunError.invalidConfiguration(
                "fresh_context_same_model governed root escaped its temp boundary")
        }
        rootCursor = parentURL
    }

    for rawPath in parent.allowedPaths {
        guard (try? BuilderExecutionValidation.path(rawPath)) == rawPath else {
            throw BuilderRunError.invalidConfiguration(
                "fresh_context_same_model target path is not canonical")
        }
        var targetCursor = root
        for component in rawPath.split(separator: "/").dropLast() {
            targetCursor.appendPathComponent(String(component), isDirectory: true)
            if fm.fileExists(atPath: targetCursor.path) {
                let resolved = try BuilderWorkspaceRootIdentity.capture(
                    rootPath: targetCursor.path).canonicalPath
                guard resolved == root.path || resolved.hasPrefix(root.path + "/") else {
                    throw BuilderRunError.invalidConfiguration(
                        "fresh_context_same_model target ancestor escapes its governed root")
                }
                targetCursor = URL(fileURLWithPath: resolved, isDirectory: true)
            }
            guard !fm.fileExists(
                atPath: targetCursor.appendingPathComponent(".git").path) else {
                throw BuilderRunError.invalidConfiguration(
                    "fresh_context_same_model target is inside a nested Git worktree")
            }
        }
    }
}
private func builderCouncilReviewVoteSemantics(
    _ votes: [BuilderReviewVoteReceipt], threshold: Int
) -> Bool {
    let expectedLenses: Set<String> = ["Correctness", "Security", "Worth", "Completeness"]
    guard threshold == 3,
          votes.count == expectedLenses.count,
          Set(votes.map(\.lens)) == expectedLenses,
          votes.allSatisfy({ !$0.failed || !$0.accepted }) else { return false }
    let completed = votes.filter { !$0.failed }
    return completed.count >= threshold && completed.allSatisfy(\.accepted)
}
private func governedMutationObserved(_ worker: BuilderWorkerReceipt) -> Bool {
    if !worker.changedPaths.isEmpty { return true }
    let before = worker.artifacts.first { $0.kind == "governed-workspace-baseline" }?.digest
    let after = worker.artifacts.last { $0.kind == "governed-workspace-subject" }?.digest
    return before != nil && after != nil && before != after
}
private func pathsOverlap(_ left: String, _ right: String) -> Bool {
    let left = (left as NSString).standardizingPath
    let right = (right as NSString).standardizingPath
    if left == right || left == "." || right == "." || left == "/" || right == "/" { return true }
    return left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
}
private func stableFingerprint(_ value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
}
private func parentContractFingerprint(_ contract: BuilderContract) throws -> String {
    try BuilderContractFingerprint.canonical(contract)
}
private func builderFinalObjectiveFingerprint(_ contract: BuilderContract) -> String {
    BuilderEvidenceDigest.sha256(contract.id + "\u{0}" + contract.objective)
}
private func builderGraphFingerprint(_ graph: BuilderGraph) throws -> String {
    BuilderEvidenceDigest.sha256(String(
        decoding: try BuilderDurableIO.canonicalData(graph), as: UTF8.self))
}
private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
