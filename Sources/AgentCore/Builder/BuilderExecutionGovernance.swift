import Foundation

enum BuilderGovernedAttemptResult: Sendable {
    case accepted(BuilderWorkerReceipt, BuilderVerifierReceipt,
                  BuilderTransactionPromotionReceipt?,
                  [BuilderTrustedTelemetryObservation])
    case retryable(String, String)
    case terminal(String, String)
}

struct BuilderExecutionGovernanceRuntime: Sendable {
    let contract: BuilderExecutionContract
    let source: (any BuilderStageObservationSource)?
    let ledger: BuilderBudgetLedger
    let checkpoints: BuilderPipelineCheckpointStore
    let verifier = BuilderContractVerifier()

    init(sealed: SealedBuilderExecutionContract,
         source: (any BuilderStageObservationSource)?, beside storeURL: URL,
         contractSealReference: String? = nil) throws {
        self.contract = sealed.contract
        self.source = source
        let directory = storeURL.deletingLastPathComponent().appendingPathComponent(
            ".builder-governance-\(sealed.fingerprint.prefix(16))", isDirectory: true)
        self.ledger = try BuilderBudgetLedger(
            fileURL: directory.appendingPathComponent("budget.json"), contract: sealed.contract)
        self.checkpoints = try BuilderPipelineCheckpointStore(
            directoryURL: directory.appendingPathComponent("checkpoints", isDirectory: true),
            contract: sealed.contract,
            contractSealReference: contractSealReference)
    }

    func ensureReady() throws {
        guard source != nil else {
            throw BuilderRunError.invalidConfiguration(
                "sealed execution contract requires an injected trusted BuilderStageObservationSource")
        }
        let supported: Set<BuilderExecutionStage> = [
            .planning, .build, .verification, .review, .promotion
        ]
        let unsupported = Set(contract.criteria.filter(\.required).map(\.stage)).subtracting(supported)
        guard unsupported.isEmpty else {
            throw BuilderRunError.invalidConfiguration(
                "BuilderRun has no trusted lifecycle hook for stages: \(unsupported.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        if !contract.mutations.isEmpty {
            guard let transaction = source as? BuilderIsolatedWorkspaceTransactionSource else {
                throw BuilderRunError.invalidConfiguration(
                    "mutation contracts require the concrete isolated workspace transaction source")
            }
            guard transaction.usesOSProcessSandbox else {
                throw BuilderRunError.invalidConfiguration(
                    "mutation contracts require an active host OS process sandbox")
            }
        } else if contract.criteria.contains(where: { $0.required && $0.stage == .promotion }),
                  !(source is any BuilderTransactionalStageObservationSource) {
            throw BuilderRunError.invalidConfiguration(
                "required promotion criteria need a transactional observation source")
        }
    }

    func reconcile(snapshotAccepted: Bool, runAccepted: Bool = false) async throws {
        guard let source else { try ensureReady(); return }
        guard let checkpoint = try await checkpoints.load(nodeID: contract.builderNodeID) else {
            if snapshotAccepted {
                throw BuilderRunError.persistedStateInvalid(
                    "accepted governed node has no sealed pipeline checkpoint")
            }
            return
        }
        let node = BuilderNode(id: contract.builderNodeID, objective: "resume reconciliation")
        let context = try BuilderStageContext(
            contract: contract, node: node, attempt: checkpoint.attempt, stage: .build)
        let transactional = source as? any BuilderTransactionalStageObservationSource
        if snapshotAccepted,
           let aggregate = source as? any BuilderAggregateTransactionalStageObservationSource,
           try await aggregate.aggregateDescriptor(for: context) != nil {
            switch checkpoint.phase {
            case .committed, .reviewApproved:
                return
            case .finalized:
                guard runAccepted else {
                    throw BuilderRunError.persistedStateInvalid(
                        "aggregate child finalized before run acceptance")
                }
                try await transactional?.verifyFinalized(context: context)
                return
            default:
                throw BuilderRunError.persistedStateInvalid(
                    "accepted aggregate child checkpoint is \(checkpoint.phase.rawValue)")
            }
        }
        if snapshotAccepted {
            if let transactional {
                switch checkpoint.phase {
                case .committed where runAccepted:
                    try await transactional.markReviewApproved(context: context)
                    _ = try await checkpoints.transition(
                        nodeID: contract.builderNodeID, attempt: checkpoint.attempt,
                        to: .reviewApproved,
                        currentWorkspaceDigest: checkpoint.currentWorkspaceDigest)
                    try await transactional.finalize(context: context)
                    _ = try await checkpoints.transition(
                        nodeID: contract.builderNodeID, attempt: checkpoint.attempt,
                        to: .finalized,
                        currentWorkspaceDigest: checkpoint.currentWorkspaceDigest)
                case .committed:
                    return
                case .reviewApproved where runAccepted:
                    try await transactional.finalize(context: context)
                    _ = try await checkpoints.transition(
                        nodeID: contract.builderNodeID, attempt: checkpoint.attempt,
                        to: .finalized, currentWorkspaceDigest: checkpoint.currentWorkspaceDigest)
                case .finalized:
                    guard runAccepted else {
                        throw BuilderRunError.persistedStateInvalid(
                            "transaction finalized before durable run-level acceptance")
                    }
                    try await transactional.verifyFinalized(context: context)
                default:
                    throw BuilderRunError.persistedStateInvalid(
                        "accepted transactional node checkpoint is \(checkpoint.phase.rawValue), not finalized")
                }
                return
            }
            guard checkpoint.phase == .committed else {
                throw BuilderRunError.persistedStateInvalid(
                    "accepted governed node checkpoint is \(checkpoint.phase.rawValue), not committed")
            }
            return
        }
        switch checkpoint.phase {
        case .rolledBack: return
        case .reviewApproved:
            guard let transactional else {
                throw BuilderRunError.persistedStateInvalid(
                    "legacy governed pipeline cannot resume review-approved state")
            }
            _ = try await checkpoints.transition(
                nodeID: contract.builderNodeID, attempt: checkpoint.attempt,
                to: .rollingBack, currentWorkspaceDigest: checkpoint.currentWorkspaceDigest,
                failureReason: "review approval exists without run-level acceptance")
            let rollback = try await transactional.rollbackCommitted(
                context: context,
                reason: "review approval exists without run-level acceptance")
            try verifier.verifyRollback(
                contract: contract, baseline: checkpoint.baseline,
                observation: rollback)
            _ = try await checkpoints.transition(
                nodeID: contract.builderNodeID, attempt: checkpoint.attempt,
                to: .rolledBack, currentWorkspaceDigest: rollback.workspaceDigestAfter)
        case .finalized:
            guard let transactional else {
                throw BuilderRunError.persistedStateInvalid(
                    "legacy governed pipeline cannot contain finalized state")
            }
            try await transactional.verifyFinalized(context: context)
        case .failed:
            throw BuilderRunError.persistedStateInvalid(
                checkpoint.failureReason ?? "governed pipeline checkpoint is failed")
        case .prepared, .running, .verifying, .committed, .rollingBack:
            _ = try? await checkpoints.transition(
                nodeID: contract.builderNodeID, attempt: checkpoint.attempt,
                to: .rollingBack, currentWorkspaceDigest: checkpoint.currentWorkspaceDigest,
                failureReason: "crash/resume reconciliation")
            let rollback: BuilderRollbackObservation
            if checkpoint.phase == .committed, let transactional {
                rollback = try await transactional.rollbackCommitted(
                    context: context, reason: "crash/resume reconciliation")
            } else {
                rollback = try await source.rollback(.init(
                    context: context, baseline: checkpoint.baseline,
                    currentWorkspaceDigest: checkpoint.currentWorkspaceDigest,
                    reason: "crash/resume reconciliation"))
            }
            try await record(rollback.budgetObservations)
            try verifier.verifyRollback(contract: contract, baseline: checkpoint.baseline,
                                        observation: rollback)
            _ = try await checkpoints.transition(
                nodeID: contract.builderNodeID, attempt: checkpoint.attempt,
                to: .rolledBack, currentWorkspaceDigest: rollback.workspaceDigestAfter)
        }
    }

    func execute(builderContract: BuilderContract, route: BuilderRoute,
                 node: BuilderNode, attempt: Int,
                 acceptedDependencies: [BuilderAcceptedDependencyResult] = [],
                 execute: @escaping BuilderExecute,
                 verify: @escaping BuilderVerify) async -> BuilderGovernedAttemptResult {
        guard let source else {
            let reason = "trusted stage observation source is unavailable"
            return .terminal(stableBuilderGovernanceFingerprint(reason), reason)
        }
        let buildContext: BuilderStageContext
        do {
            buildContext = try BuilderStageContext(
                contract: contract, node: node, attempt: attempt, stage: .build)
        } catch {
            let reason = "stage context binding is invalid: \(error.localizedDescription)"
            return .terminal(stableBuilderGovernanceFingerprint(reason), reason)
        }
        if contract.criteria.contains(where: { $0.required && $0.stage == .planning }),
           Set(acceptedDependencies.map(\.nodeID)) != Set(node.dependencies) {
            let reason = "required planning admission is not backed by every accepted dependency receipt"
            return .terminal(stableBuilderGovernanceFingerprint(reason), reason)
        }
        do {
            for dependency in acceptedDependencies {
                try dependency.validateBinding(
                    parentContractFingerprint: BuilderEvidenceDigest.sha256(String(
                        decoding: BuilderDurableIO.canonicalData(builderContract), as: UTF8.self)),
                    graphFingerprint: dependency.graphFingerprint ?? "",
                    consumerNodeID: node.id, consumerAttempt: attempt,
                    currentCheckpointSequence: dependency.acceptedCheckpointSequence ?? -1)
            }
        } catch {
            let reason = "dependency authority is forged or stale: \(error.localizedDescription)"
            return .terminal(stableBuilderGovernanceFingerprint(reason), reason)
        }
        var baseline: BuilderStageBaseline?
        var currentDigest: String?
        do {
            let prepared = try await source.prepare(buildContext)
            try verifier.validateBaseline(contract: contract, baseline: prepared)
            try await record(prepared.budgetObservations)
            baseline = prepared
            _ = try await checkpoints.prepare(nodeID: node.id, attempt: attempt, baseline: prepared)
            _ = try await checkpoints.transition(
                nodeID: node.id, attempt: attempt, to: .running,
                currentWorkspaceDigest: prepared.workspaceDigest)

            let transactional = source as? any BuilderTransactionalStageObservationSource
            if !contract.mutations.isEmpty, transactional == nil {
                throw BuilderRunError.invalidConfiguration(
                    "mutation worker has no concrete transactional execution workspace")
            }
            let executionWorkspace = try await transactional?.executionWorkspace(for: buildContext)
            let executionRequest = BuilderExecutionRequest(
                contract: builderContract,
                route: route, node: node, attempt: attempt,
                executionWorkspace: executionWorkspace,
                acceptedDependencies: acceptedDependencies)
            let telemetryBinding = try BuilderTrustedTelemetryBinding(
                contractFingerprint: contract.fingerprint(), nodeID: node.id,
                attempt: attempt, stage: .build)
            let (worker, trustedTelemetry) = try await captureTrustedOperation(
                binding: telemetryBinding) {
                if let executionWorkspace {
                    return try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                        workspace: executionWorkspace,
                        builderContractID: builderContract.id
                    ) {
                        try await execute(executionRequest)
                            .bindingObservedCLIInvocationsIfRequired()
                    }
                }
                return try await execute(executionRequest)
                    .bindingObservedCLIInvocationsIfRequired()
            }
            try validateToolWorkspaceIdentity(
                trustedTelemetry, executionWorkspace: executionWorkspace)
            guard trustedTelemetry.hasSuccessfulProviderRoute(
                providerID: worker.provider, modelID: worker.model) else {
                throw BuilderRunError.persistedStateInvalid(
                    "worker provider/model receipt is not backed by a trusted route observation")
            }
            guard worker.trustedCLIInvocationsMatch(
                trustedTelemetry, requireComplete: true) else {
                throw BuilderRunError.persistedStateInvalid(
                    "worker CLI route receipt is missing, forged, reused, or unmatched")
            }
            try BuilderGovernedWorkerIdentity.validate(
                actual: worker.nodeID,
                expected: node.id
            )
            let buildObservation = try await source.observe(.init(
                context: buildContext, baseline: prepared, subject: .execution(worker),
                trustedTelemetry: trustedTelemetry))
            try await record(buildObservation.budgetObservations)
            _ = try verifier.verify(contract: contract, baseline: prepared,
                                    observation: buildObservation)
            currentDigest = buildObservation.workspaceDigestAfter
            _ = try await checkpoints.transition(
                nodeID: node.id, attempt: attempt, to: .verifying,
                currentWorkspaceDigest: currentDigest)

            let verificationContext = try BuilderStageContext(
                contract: contract, node: node, attempt: attempt, stage: .verification)
            let verificationBaseline = try await source.prepare(verificationContext)
            try verifier.validateBaseline(contract: contract, baseline: verificationBaseline)
            guard verificationBaseline.workspaceDigest == currentDigest else {
                throw BuilderContractVerifierError.bindingMismatch("verification baseline")
            }
            try await record(verificationBaseline.budgetObservations)
            let verificationWorkspace = try await transactional?.executionWorkspace(
                for: verificationContext)
            let verificationTelemetryBinding = try BuilderTrustedTelemetryBinding(
                contractFingerprint: contract.fingerprint(), nodeID: node.id,
                attempt: attempt, stage: .verification)
            let (proof, verificationTelemetry) = try await captureTrustedOperation(
                binding: verificationTelemetryBinding) {
                if let verificationWorkspace {
                    return try await BuilderOSProcessSandboxAttestor.withRegisteredScope(
                        workspace: verificationWorkspace,
                        builderContractID: builderContract.id
                    ) {
                        try await verify(.node(
                            contract: builderContract,
                            node: node, worker: worker,
                            executionWorkspace: verificationWorkspace))
                    }
                }
                return try await verify(.node(
                    contract: builderContract,
                    node: node, worker: worker,
                    executionWorkspace: nil))
            }
            try validateToolWorkspaceIdentity(
                verificationTelemetry, executionWorkspace: verificationWorkspace)
            let proofRouteObserved = verificationTelemetry.contains {
                ($0.kind == .provider && $0.success
                    && $0.providerID?.lowercased() == proof.provider.lowercased()
                    && $0.modelID == proof.model)
                || ($0.kind == .command && $0.success
                    && ["host", "process"].contains(proof.provider.lowercased())
                    && ["deterministic", "command"].contains(proof.model.lowercased()))
            }
            guard proofRouteObserved else {
                throw BuilderRunError.persistedStateInvalid(
                    "verification provider/model receipt is not backed by trusted route telemetry")
            }
            guard proof.scope == .node(node.id), proof.deterministic, proof.passed,
                  proof.checks.allSatisfy(\.passed) else {
                throw BuilderRunError.finalVerificationFailed("deterministic node verifier rejected")
            }
            let verificationObservation = try await source.observe(.init(
                context: verificationContext, baseline: verificationBaseline,
                subject: .verification(worker, proof),
                trustedTelemetry: verificationTelemetry))
            try await record(verificationObservation.budgetObservations)
            _ = try verifier.verify(contract: contract, baseline: verificationBaseline,
                                    observation: verificationObservation)
            currentDigest = verificationObservation.workspaceDigestAfter
            var promotionReceipt: BuilderTransactionPromotionReceipt?
            if let transactional {
                guard let verifiedWorkspaceDigest = currentDigest else {
                    throw BuilderRunError.persistedStateInvalid(
                        "transactional verification produced no workspace digest")
                }
                try await transactional.commit(
                    context: buildContext,
                    verifiedWorkspaceDigest: verifiedWorkspaceDigest)
                guard let verifierSubjectDigest = proof.subjectDigest,
                      !verifierSubjectDigest.hasPrefix("unavailable:") else {
                    throw BuilderRunError.persistedStateInvalid(
                        "transactional verification produced no verifier subject digest")
                }
                let rawReceipt = try await transactional.promotionReceipt(context: buildContext)
                promotionReceipt = try BuilderTransactionPromotionReceipt(
                    contractFingerprint: rawReceipt.contractFingerprint,
                    builderContractID: rawReceipt.builderContractID,
                    nodeID: rawReceipt.nodeID,
                    attempt: rawReceipt.attempt,
                    workspaceDigest: rawReceipt.workspaceDigest,
                    verifierSubjectDigest: verifierSubjectDigest,
                    operations: rawReceipt.operations)
            }
            _ = try await checkpoints.transition(
                nodeID: node.id, attempt: attempt, to: .committed,
                currentWorkspaceDigest: currentDigest)
            return .accepted(worker, proof, promotionReceipt,
                             trustedTelemetry + verificationTelemetry)
        } catch {
            let reason = error.localizedDescription
            guard let baseline else {
                return .terminal(stableBuilderGovernanceFingerprint(reason), reason)
            }
            do {
                _ = try await checkpoints.transition(
                    nodeID: node.id, attempt: attempt, to: .rollingBack,
                    currentWorkspaceDigest: currentDigest, failureReason: reason)
                let rollback = try await source.rollback(.init(
                    context: buildContext, baseline: baseline,
                    currentWorkspaceDigest: currentDigest, reason: reason))
                try await record(rollback.budgetObservations)
                try verifier.verifyRollback(contract: contract, baseline: baseline,
                                            observation: rollback)
                _ = try await checkpoints.transition(
                    nodeID: node.id, attempt: attempt, to: .rolledBack,
                    currentWorkspaceDigest: rollback.workspaceDigestAfter)
                return await classifyRolledBackFailure(error, reason: reason)
            } catch {
                let rollbackReason = "\(reason); rollback failed: \(error.localizedDescription)"
                _ = try? await checkpoints.transition(
                    nodeID: node.id, attempt: attempt, to: .failed,
                    currentWorkspaceDigest: currentDigest, failureReason: rollbackReason)
                return .terminal(stableBuilderGovernanceFingerprint(rollbackReason), rollbackReason)
            }
        }
    }

    private func classifyRolledBackFailure(
        _ error: Error, reason: String
    ) async -> BuilderGovernedAttemptResult {
        guard case .noMutation = error as? BuilderWorkspaceTransactionError else {
            return .terminal(stableBuilderGovernanceFingerprint(reason), reason)
        }
        do {
            guard try await ledger.admitsProviderRetry(stage: .build) else {
                let denied = reason
                    + "; bounded no-mutation retry refused because the sealed build budget has no provider capacity"
                return .terminal(stableBuilderGovernanceFingerprint(denied), denied)
            }
            return .retryable(stableBuilderGovernanceFingerprint(reason), reason)
        } catch {
            let denied = reason
                + "; bounded no-mutation retry admission failed: \(error.localizedDescription)"
            return .terminal(stableBuilderGovernanceFingerprint(denied), denied)
        }
    }

    private func captureTrustedOperation<T: Sendable>(
        binding: BuilderTrustedTelemetryBinding,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> (T, [BuilderTrustedTelemetryObservation]) {
        let captured = await BuilderTrustedTelemetry.captureScope(
            binding: binding, operation: operation)
        // Charge observations before interpreting the operation result. This also consumes the
        // one-use telemetry authority on failures, so retrying cannot erase spent budget.
        try await record(try captured.1.compactMap {
            try $0.accountableBudgetObservation()
        })
        return (try captured.0.get(), captured.1)
    }

    func ensureReviewProviderCapacity() async throws {
        guard contract.budgets.stages.contains(where: { $0.stage == .review }) else {
            throw BuilderBudgetLedgerError.unknownStage(.review)
        }
        guard try await ledger.admitsProviderRetry(stage: .review) else {
            throw BuilderBudgetLedgerError.exceeded(
                "sealed review budget has no remaining provider capacity")
        }
    }

    func recordReviewTelemetry(
        _ trustedTelemetry: [BuilderTrustedTelemetryObservation]
    ) async throws {
        try await record(try trustedTelemetry.compactMap {
            try $0.accountableBudgetObservation()
        })
    }

    func verifyReview(node: BuilderNode, attempt: Int, workers: [BuilderWorkerReceipt],
                      proof: BuilderVerifierReceipt, review: BuilderReviewReceipt,
                      trustedTelemetry: [BuilderTrustedTelemetryObservation]) async throws {
        guard let source else { try ensureReady(); return }
        let context = try BuilderStageContext(
            contract: contract, node: node, attempt: attempt, stage: .review)
        let baseline = try await source.prepare(context)
        try verifier.validateBaseline(contract: contract, baseline: baseline)
        try await record(baseline.budgetObservations)
        let observation = try await source.observe(.init(
            context: context, baseline: baseline,
            subject: .review(workers, proof, review),
            trustedTelemetry: trustedTelemetry))
        try await record(observation.budgetObservations)
        _ = try verifier.verify(contract: contract, baseline: baseline, observation: observation)
    }

    func rollbackCommitted(node: BuilderNode, attempt: Int, reason: String) async throws {
        guard let source, let checkpoint = try await checkpoints.load(nodeID: node.id) else {
            throw BuilderRunError.persistedStateInvalid("cannot rollback committed governed node")
        }
        if checkpoint.phase == .rolledBack { return }
        _ = try await checkpoints.transition(
            nodeID: node.id, attempt: attempt, to: .rollingBack,
            currentWorkspaceDigest: checkpoint.currentWorkspaceDigest, failureReason: reason)
        let context = try BuilderStageContext(contract: contract, node: node, attempt: attempt, stage: .build)
        let rollback: BuilderRollbackObservation
        if let transactional = source as? any BuilderTransactionalStageObservationSource {
            rollback = try await transactional.rollbackCommitted(context: context, reason: reason)
        } else {
            rollback = try await source.rollback(.init(
                context: context, baseline: checkpoint.baseline,
                currentWorkspaceDigest: checkpoint.currentWorkspaceDigest, reason: reason))
        }
        try await record(rollback.budgetObservations)
        try verifier.verifyRollback(contract: contract, baseline: checkpoint.baseline,
                                    observation: rollback)
        _ = try await checkpoints.transition(
            nodeID: node.id, attempt: attempt, to: .rolledBack,
            currentWorkspaceDigest: rollback.workspaceDigestAfter)
    }

    func markReviewApproved(node: BuilderNode, attempt: Int) async throws {
        guard let source,
              let transactional = source as? any BuilderTransactionalStageObservationSource,
              let checkpoint = try await checkpoints.load(nodeID: node.id) else { return }
        if checkpoint.phase == .reviewApproved || checkpoint.phase == .finalized { return }
        guard checkpoint.phase == .committed else {
            throw BuilderRunError.persistedStateInvalid(
                "cannot approve review from \(checkpoint.phase.rawValue)")
        }
        let context = try BuilderStageContext(
            contract: contract, node: node, attempt: attempt, stage: .review)
        try await transactional.markReviewApproved(context: context)
        _ = try await checkpoints.transition(
            nodeID: node.id, attempt: attempt, to: .reviewApproved,
            currentWorkspaceDigest: checkpoint.currentWorkspaceDigest)
    }

    func finalize(node: BuilderNode, attempt: Int) async throws {
        guard let source,
              let transactional = source as? any BuilderTransactionalStageObservationSource,
              let checkpoint = try await checkpoints.load(nodeID: node.id) else { return }
        let context = try BuilderStageContext(
            contract: contract, node: node, attempt: attempt, stage: .review)
        if checkpoint.phase == .finalized {
            try await transactional.verifyFinalized(context: context)
            return
        }
        guard checkpoint.phase == .reviewApproved else {
            throw BuilderRunError.persistedStateInvalid(
                "cannot finalize from \(checkpoint.phase.rawValue)")
        }
        try await transactional.finalize(context: context)
        _ = try await checkpoints.transition(
            nodeID: node.id, attempt: attempt, to: .finalized,
            currentWorkspaceDigest: checkpoint.currentWorkspaceDigest)
    }

    func releaseRetainedData(node: BuilderNode, attempt: Int) async throws {
        guard let source,
              let transactional = source as? any BuilderTransactionalStageObservationSource,
              let checkpoint = try await checkpoints.load(nodeID: node.id) else { return }
        guard checkpoint.phase == .finalized else {
            throw BuilderRunError.persistedStateInvalid(
                "cannot release retained data from \(checkpoint.phase.rawValue)")
        }
        let context = try BuilderStageContext(
            contract: contract, node: node, attempt: attempt, stage: .review)
        try await transactional.releaseRetainedData(context: context)
    }

    private func record(_ observations: [BuilderTrustedBudgetObservation]) async throws {
        for observation in observations.sorted(by: { $0.id < $1.id }) {
            _ = try await ledger.record(observation)
        }
    }

    private func validateToolWorkspaceIdentity(
        _ observations: [BuilderTrustedTelemetryObservation],
        executionWorkspace: BuilderExecutionWorkspace?
    ) throws {
        let rootedTools = ToolEffectCatalog.knownMutationTools
            .union(ToolEffectCatalog.knownCommandTools)
        let successful = observations.filter {
            $0.kind == .tool && $0.success && rootedTools.contains($0.name)
        }
        guard !successful.isEmpty else { return }
        guard let identity = executionWorkspace?.rootIdentity,
              successful.allSatisfy({ $0.workspaceRootIdentity == identity }) else {
            throw BuilderRunError.persistedStateInvalid(
                "concurrent governed-root drift: tool telemetry is not bound to the execution workspace")
        }
    }
}

private func stableBuilderGovernanceFingerprint(_ value: String) -> String {
    BuilderEvidenceDigest.sha256(value)
}
