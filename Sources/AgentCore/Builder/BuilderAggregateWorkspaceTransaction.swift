import Foundation

enum BuilderAggregateTransactionPhase: String, Codable, Sendable, Equatable {
    case collecting, merging, ready, reviewApproved, promoting, committed
    case finalized, rollingBack, rolledBack, failed
}

struct BuilderAggregateChildState: Codable, Sendable, Equatable {
    let contractFingerprint: String
    let builderContractID: String
    let nodeID: String
    let attempt: Int
    let paths: [String]
    let operations: [BuilderMutationOperation]
    let transactionKey: String
    var workspaceDigest: String?
    var merged: Bool
    var workspaceRootIdentity: BuilderWorkspaceRootIdentity? = nil
}

struct BuilderAggregateTransactionState: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let descriptor: BuilderAggregateTransactionDescriptor
    var phase: BuilderAggregateTransactionPhase
    let baseline: BuilderWorkspaceManifest
    var subject: BuilderWorkspaceManifest?
    var children: [BuilderAggregateChildState]
    var pendingChild: BuilderAggregateChildState?
    var commitEpoch: String?
    var promotionIndex: Int
    var createdDirectories: [String]
    var pendingIntent: BuilderWorkspaceMutationIntent?
    var failureReason: String?
    let workspaceRootIdentity: BuilderWorkspaceRootIdentity
    let baselineRootIdentity: BuilderWorkspaceRootIdentity
    var retainedDataReleaseStarted: Bool = false
    var workspaceReleased: Bool = false
    var baselineReleased: Bool = false
}

private struct SealedBuilderAggregateTransactionState: Codable, Equatable {
    let state: BuilderAggregateTransactionState
    let seal: String
}

struct BuilderAggregateRegistration: Codable, Sendable, Equatable {
    let aggregateID: String
    let descriptorBindingDigest: String
}

private struct SealedBuilderAggregateRegistration: Codable, Equatable {
    let registration: BuilderAggregateRegistration
    let seal: String
}

extension BuilderIsolatedWorkspaceTransactionSource {
    public func beginAggregate(
        _ descriptor: BuilderAggregateTransactionDescriptor
    ) async throws {
        try descriptor.validate()
        try FileManager.default.createDirectory(
            at: aggregateBaseURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if var state = try loadAggregate(descriptor.aggregateID) {
            try validateAggregate(state, descriptor: descriptor)
            if !state.workspaceReleased { try validateAggregateRetainedRoots(state) }
            if state.phase == .merging {
                try rebuildAggregate(&state)
            } else if state.phase == .promoting {
                try restoreAggregate(&state, reason: "resume interrupted aggregate promotion")
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "interrupted aggregate promotion was rolled back")
            }
            guard ![.rolledBack, .failed].contains(state.phase) else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate transaction is terminal")
            }
            return
        }
        let directory = aggregateURL(descriptor.aggregateID)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate directory has no valid sealed state")
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let baseline = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, copyTo: aggregateWorkspaceURL(descriptor.aggregateID))
        try FileManager.default.copyItem(
            at: aggregateWorkspaceURL(descriptor.aggregateID),
            to: aggregateBaselineURL(descriptor.aggregateID))
        let workspaceRootIdentity = try BuilderWorkspaceRootIdentity.capture(
            rootPath: aggregateWorkspaceURL(descriptor.aggregateID).path)
        let baselineRootIdentity = try BuilderWorkspaceRootIdentity.capture(
            rootPath: aggregateBaselineURL(descriptor.aggregateID).path)
        _ = try retainedRootLease(workspaceRootIdentity)
        _ = try retainedRootLease(baselineRootIdentity)
        let state = BuilderAggregateTransactionState(
            schemaVersion: 2, descriptor: descriptor, phase: .collecting,
            baseline: baseline, subject: baseline, children: [], pendingChild: nil,
            commitEpoch: nil, promotionIndex: 0, createdDirectories: [],
            pendingIntent: nil, failureReason: nil,
            workspaceRootIdentity: workspaceRootIdentity,
            baselineRootIdentity: baselineRootIdentity)
        try publishAggregate(state)
        try faultInjector?.hit(.afterAggregatePrepared)
    }

    public func registerAggregateChild(
        _ descriptor: BuilderAggregateTransactionDescriptor,
        context: BuilderStageContext
    ) async throws {
        guard context.stage == .build,
              descriptor.expectedNodeIDs.contains(context.node.id) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate child is not an expected build node")
        }
        try await beginAggregate(descriptor)
        var aggregate = try aggregateState(for: descriptor.aggregateID)
        let paths = try context.contract.mutations.map { try safeMutationPath($0.path) }.sorted()
        guard !paths.isEmpty, Set(paths).count == paths.count else {
            throw BuilderWorkspaceTransactionError.invalidConfiguration(
                "aggregate child mutation paths must be nonempty and unique")
        }
        try validateAuthorityAndPreimages(context.contract, baseline: aggregate.baseline)
        let fingerprint = try context.contract.fingerprint()
        let candidate = BuilderAggregateChildState(
            contractFingerprint: fingerprint,
            builderContractID: context.contract.builderContractID,
            nodeID: context.node.id, attempt: context.attempt,
            paths: paths, operations: context.contract.mutations.sorted { $0.path < $1.path },
            transactionKey: transactionURL(context).lastPathComponent,
            workspaceDigest: nil, merged: false)
        if ![.collecting, .ready].contains(aggregate.phase) {
            guard let existing = aggregate.children.first(where: { $0.nodeID == context.node.id }),
                  existing.contractFingerprint == candidate.contractFingerprint,
                  existing.builderContractID == candidate.builderContractID,
                  existing.attempt == candidate.attempt,
                  existing.paths == candidate.paths,
                  existing.operations == candidate.operations,
                  existing.transactionKey == candidate.transactionKey else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate no longer accepts child registrations")
            }
            try publishAggregateRegistration(
                .init(aggregateID: descriptor.aggregateID,
                      descriptorBindingDigest: descriptor.bindingDigest),
                context: context)
            return
        }
        if let index = aggregate.children.firstIndex(where: { $0.nodeID == context.node.id }) {
            let existing = aggregate.children[index]
            if existing != candidate {
                guard !existing.merged, context.attempt > existing.attempt else {
                    throw BuilderWorkspaceTransactionError.stateMismatch(
                        "aggregate child registration is stale or rebound")
                }
                aggregate.children[index] = candidate
            }
        } else {
            let occupied = Set(aggregate.children.flatMap(\.paths))
            guard occupied.isDisjoint(with: paths) else {
                throw BuilderWorkspaceTransactionError.invalidConfiguration(
                    "aggregate child mutation paths overlap")
            }
            aggregate.children.append(candidate)
        }
        aggregate.children.sort { $0.nodeID < $1.nodeID }
        aggregate.phase = .collecting
        try publishAggregate(aggregate)
        try publishAggregateRegistration(
            .init(aggregateID: descriptor.aggregateID,
                  descriptorBindingDigest: descriptor.bindingDigest),
            context: context)
        if var child = try load(context) {
            guard child.aggregateID == nil || child.aggregateID == descriptor.aggregateID else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "existing child has a different aggregate binding")
            }
            child.aggregateID = descriptor.aggregateID
            try publish(child, context: context)
        }
    }

    public func aggregateDescriptor(for context: BuilderStageContext) async throws
        -> BuilderAggregateTransactionDescriptor? {
        guard let registration = try aggregateRegistration(for: context) else { return nil }
        let state = try aggregateState(for: registration.aggregateID)
        guard state.descriptor.bindingDigest == registration.descriptorBindingDigest else {
            throw BuilderWorkspaceTransactionError.tampered
        }
        return state.descriptor
    }

    public func assertAggregateReady(
        _ descriptor: BuilderAggregateTransactionDescriptor
    ) async throws -> BuilderAggregateTransactionReceipt {
        var state = try aggregateState(for: descriptor.aggregateID)
        try validateAggregate(state, descriptor: descriptor)
        if !state.workspaceReleased { try validateAggregateRetainedRoots(state) }
        if state.phase == .merging { try rebuildAggregate(&state) }
        guard [.ready, .reviewApproved, .committed, .finalized].contains(state.phase),
              Set(state.children.map(\.nodeID)) == Set(descriptor.expectedNodeIDs),
              state.children.allSatisfy(\.merged),
              let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate is missing one or more sealed child partitions")
        }
        if state.phase != .finalized {
            let current = try BuilderWorkspaceManifestScanner.scan(
                root: aggregateWorkspaceURL(descriptor.aggregateID), limits: limits)
            guard current == subject else {
                throw BuilderWorkspaceTransactionError.undeclaredMutation(
                    "aggregate staged bytes changed after child sealing")
            }
        }
        return try aggregateReceipt(state)
    }

    public func markAggregateReviewApproved(
        _ descriptor: BuilderAggregateTransactionDescriptor,
        commitEpoch: String
    ) async throws {
        _ = try BuilderExecutionValidation.digest(commitEpoch, field: "aggregate commit epoch")
        var state = try aggregateState(for: descriptor.aggregateID)
        try validateAggregate(state, descriptor: descriptor)
        try validateAggregateRetainedRoots(state)
        if [.reviewApproved, .committed, .finalized].contains(state.phase) {
            guard state.commitEpoch == commitEpoch else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate commit epoch changed")
            }
            return
        }
        _ = try await assertAggregateReady(descriptor)
        state = try aggregateState(for: descriptor.aggregateID)
        state.commitEpoch = commitEpoch
        state.phase = .reviewApproved
        try publishAggregate(state)
    }

    public func finalizeAggregate(
        _ descriptor: BuilderAggregateTransactionDescriptor
    ) async throws -> BuilderAggregateTransactionReceipt {
        var state = try aggregateState(for: descriptor.aggregateID)
        try validateAggregate(state, descriptor: descriptor)
        try validateAggregateRetainedRoots(state)
        if [.committed, .finalized].contains(state.phase) {
            try verifyAggregatePromoted(state)
            return try aggregateReceipt(state)
        }
        guard state.phase == .reviewApproved, state.commitEpoch?.count == 64 else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate finalize requires durable parent review acceptance")
        }
        try promoteAggregate(&state)
        return try aggregateReceipt(state)
    }

    public func completeAggregate(
        _ descriptor: BuilderAggregateTransactionDescriptor
    ) async throws {
        var state = try aggregateState(for: descriptor.aggregateID)
        try validateAggregate(state, descriptor: descriptor)
        if state.phase == .finalized { return }
        guard state.phase == .committed else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate completion requires global commit")
        }
        try verifyAggregatePromoted(state)
        state.phase = .finalized
        try publishAggregate(state)
    }

    public func releaseAggregate(
        _ descriptor: BuilderAggregateTransactionDescriptor
    ) async throws {
        var state = try aggregateState(for: descriptor.aggregateID)
        try validateAggregate(state, descriptor: descriptor)
        guard state.phase == .finalized else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate retained data cannot be released before finalization")
        }
        try verifyAggregatePromoted(state)
        if state.workspaceReleased && state.baselineReleased { return }
        if !state.retainedDataReleaseStarted {
            state.retainedDataReleaseStarted = true
            try publishAggregate(state)
        }
        if !state.workspaceReleased {
            try releaseRetainedRoot(state.workspaceRootIdentity)
            state.workspaceReleased = true
            try publishAggregate(state)
        }
        if !state.baselineReleased {
            try releaseRetainedRoot(state.baselineRootIdentity)
            state.baselineReleased = true
            try publishAggregate(state)
        }
    }

    public func rollbackAggregate(
        _ descriptor: BuilderAggregateTransactionDescriptor,
        reason: String
    ) async throws {
        try descriptor.validate()
        try rollbackAggregateID(descriptor.aggregateID, reason: reason)
    }

    public func verifyAggregateFinalized(
        _ descriptor: BuilderAggregateTransactionDescriptor
    ) async throws -> BuilderAggregateTransactionReceipt {
        let state = try aggregateState(for: descriptor.aggregateID)
        try validateAggregate(state, descriptor: descriptor)
        guard state.phase == .finalized else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate transaction is not finalized")
        }
        try verifyAggregatePromoted(state)
        return try aggregateReceipt(state)
    }

    func aggregateRegistration(
        for context: BuilderStageContext
    ) throws -> BuilderAggregateRegistration? {
        let url = aggregateRegistrationURL(context)
        guard let data = try BuilderDurableIO.readSecure(url) else { return nil }
        let envelope = try JSONDecoder().decode(
            SealedBuilderAggregateRegistration.self, from: data)
        guard try BuilderDurableIO.canonicalData(envelope) == data else {
            throw BuilderWorkspaceTransactionError.tampered
        }
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(
            envelope.registration), as: UTF8.self)
        guard ForgeSeal.verify(canonical, seal: envelope.seal) else {
            throw BuilderWorkspaceTransactionError.tampered
        }
        return envelope.registration
    }

    func validateRegisteredAggregateBaseline(
        registration: BuilderAggregateRegistration,
        manifest: BuilderWorkspaceManifest,
        context: BuilderStageContext
    ) throws {
        let state = try aggregateState(for: registration.aggregateID)
        guard state.descriptor.bindingDigest == registration.descriptorBindingDigest,
              state.descriptor.expectedNodeIDs.contains(context.node.id),
              state.baseline == manifest else {
            throw BuilderWorkspaceTransactionError.preimageMismatch(
                "aggregate baseline changed before child execution")
        }
    }

    func executionTarget(
        context: BuilderStageContext,
        state: BuilderWorkspaceTransactionState
    ) throws -> (root: URL, digest: String?, identity: BuilderWorkspaceRootIdentity) {
        if context.stage != .build, let aggregateID = state.aggregateID,
           [.committed, .reviewApproved, .finalized].contains(state.phase) {
            let aggregate = try aggregateStateReady(for: aggregateID)
            guard !aggregate.workspaceReleased,
                  let subject = aggregate.subject else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "released aggregate no longer exposes an execution workspace")
            }
            try validateAggregateRetainedRoots(aggregate)
            return (aggregateWorkspaceURL(aggregateID), try subject.digest(),
                    aggregate.workspaceRootIdentity)
        }
        guard !state.workspaceReleased else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "released transaction no longer exposes an execution workspace")
        }
        try validateRetainedRoots(state)
        let manifest = state.subject ?? state.baseline
        return (workspaceURL(context), try manifest.digest(), state.workspaceRootIdentity)
    }

    func observationRoot(context: BuilderStageContext,
                         state: BuilderWorkspaceTransactionState) throws -> URL {
        try executionTarget(context: context, state: state).root
    }

    func aggregateStateReady(for aggregateID: String) throws
        -> BuilderAggregateTransactionState {
        let state = try aggregateState(for: aggregateID)
        guard [.ready, .reviewApproved, .committed, .finalized].contains(state.phase),
              state.children.allSatisfy(\.merged),
              Set(state.children.map(\.nodeID)) == Set(state.descriptor.expectedNodeIDs) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate staged workspace is incomplete")
        }
        return state
    }

    func aggregateState(for aggregateID: String) throws
        -> BuilderAggregateTransactionState {
        guard let state = try loadAggregate(aggregateID) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate transaction is missing")
        }
        return state
    }

    func mergeChildIntoAggregate(
        state child: inout BuilderWorkspaceTransactionState,
        context: BuilderStageContext,
        verifiedWorkspaceDigest: String
    ) throws {
        guard let aggregateID = child.aggregateID,
              child.phase == .verified,
              let childSubject = child.subject,
              try childSubject.digest() == verifiedWorkspaceDigest else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate child is not a verified staged subject")
        }
        var aggregate = try aggregateState(for: aggregateID)
        if aggregate.phase == .merging { try rebuildAggregate(&aggregate) }
        guard [.collecting, .ready].contains(aggregate.phase),
              child.baseline == aggregate.baseline,
              let index = aggregate.children.firstIndex(where: {
                  $0.nodeID == child.nodeID && $0.attempt == child.attempt
                    && $0.contractFingerprint == child.contractFingerprint
              }) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate child registration or baseline does not match")
        }
        if aggregate.children[index].merged {
            guard aggregate.children[index].workspaceDigest == verifiedWorkspaceDigest else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate child digest changed after merge")
            }
            child.phase = .committed
            try publish(child, context: context)
            return
        }
        var pending = aggregate.children[index]
        pending.workspaceDigest = verifiedWorkspaceDigest
        pending.workspaceRootIdentity = child.workspaceRootIdentity
        aggregate.pendingChild = pending
        aggregate.phase = .merging
        try publishAggregate(aggregate)
        try faultInjector?.hit(.afterAggregateMergeIntent)
        try applyAggregateChild(pending, baseline: aggregate.baseline)
        let current = try BuilderWorkspaceManifestScanner.scan(
            root: aggregateWorkspaceURL(aggregateID), limits: limits)
        try validateAggregateSubject(
            baseline: aggregate.baseline, subject: current,
            children: aggregate.children.filter(\.merged) + [pending])
        pending.merged = true
        aggregate.children[index] = pending
        aggregate.subject = current
        aggregate.pendingChild = nil
        aggregate.phase = Set(aggregate.children.map(\.nodeID))
            == Set(aggregate.descriptor.expectedNodeIDs)
            && aggregate.children.allSatisfy(\.merged) ? .ready : .collecting
        try publishAggregate(aggregate)
        try faultInjector?.hit(.afterAggregateChildMerged)
        child.phase = .committed
        try publish(child, context: context)
    }

    func rollbackAggregateID(_ aggregateID: String, reason: String) throws {
        var state = try aggregateState(for: aggregateID)
        if state.phase == .rolledBack { return }
        guard !state.retainedDataReleaseStarted else {
            throw BuilderWorkspaceTransactionError.rollbackUnproven(
                "aggregate retained rollback evidence was already released")
        }
        if [.promoting, .committed, .finalized, .rollingBack].contains(state.phase) {
            try restoreAggregate(&state, reason: reason)
            return
        }
        let current = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, mode: .restoration)
        for operation in aggregateOperations(state) where
            current.entry(operation.path) != state.baseline.entry(operation.path) {
            throw BuilderWorkspaceTransactionError.rollbackUnproven(operation.path)
        }
        state.phase = .rolledBack
        state.failureReason = reason
        state.pendingChild = nil
        try publishAggregate(state)
    }

    func verifyAggregatePromoted(_ state: BuilderAggregateTransactionState) throws {
        guard let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate subject is missing")
        }
        for operation in aggregateOperations(state) {
            guard try currentRegularEntry(operation.path) == subject.entry(operation.path) else {
                throw BuilderWorkspaceTransactionError.stateMismatch(
                    "aggregate promoted path drifted: \(operation.path)")
            }
        }
    }

    private func promoteAggregate(_ state: inout BuilderAggregateTransactionState) throws {
        guard let subject = state.subject else {
            throw BuilderWorkspaceTransactionError.stateMismatch("aggregate subject is missing")
        }
        try validateAggregateRetainedRoots(state)
        let operations = aggregateOperations(state)
        let current = try BuilderWorkspaceManifestScanner.scan(root: projectRoot, limits: limits)
        for operation in operations where
            current.entry(operation.path) != state.baseline.entry(operation.path) {
            throw BuilderWorkspaceTransactionError.preimageMismatch(operation.path)
        }
        state.phase = .promoting
        state.promotionIndex = 0
        try publishAggregate(state)
        try faultInjector?.hit(.beforeAggregatePromotion)
        let real = try ConfinedRoot(root: projectRoot.path)
        let staged = try ConfinedRoot(
            root: aggregateWorkspaceURL(state.descriptor.aggregateID).path, readOnly: true)
        for (index, operation) in operations.enumerated() {
            guard try currentRegularEntry(operation.path)
                    == state.baseline.entry(operation.path) else {
                throw BuilderWorkspaceTransactionError.preimageMismatch(operation.path)
            }
            let token = UUID().uuidString.lowercased()
            let temporary = ".kist-builder-aggregate-tmp-\(token)"
            let quarantine = ".kist-builder-aggregate-quarantine-\(token)"
            state.pendingIntent = .init(
                index: index, operation: operation, temporaryLeaf: temporary,
                quarantineLeaf: quarantine,
                preimage: state.baseline.entry(operation.path), phase: .intent)
            try publishAggregate(state)
            switch operation.kind {
            case .create, .modify:
                guard let next = subject.entry(operation.path), next.type == .regular else {
                    throw BuilderWorkspaceTransactionError.operationMismatch(operation.path)
                }
                state.createdDirectories.append(contentsOf: try ensureParents(
                    operation.path, root: real))
                try real.transactionPublish(
                    operation.path,
                    data: staged.readStableData(operation.path, maxBytes: limits.maxFileBytes),
                    mode: next.mode,
                    expected: try transactionPreimage(state.baseline.entry(operation.path)),
                    kind: operation.kind, tempLeaf: temporary,
                    quarantineLeaf: quarantine)
            case .delete:
                let prior = try transactionPreimage(state.baseline.entry(operation.path))
                try real.transactionPublish(
                    operation.path, data: nil, mode: prior?.mode ?? 0,
                    expected: prior, kind: .delete, tempLeaf: temporary,
                    quarantineLeaf: quarantine)
            }
            state.promotionIndex = index + 1
            state.createdDirectories = Array(Set(state.createdDirectories)).sorted()
            state.pendingIntent?.phase = .applied
            try publishAggregate(state)
            try faultInjector?.hit(.afterAggregatePromotedPath)
            state.pendingIntent = nil
            try publishAggregate(state)
        }
        state.phase = .committed
        try publishAggregate(state)
    }

    private func restoreAggregate(
        _ state: inout BuilderAggregateTransactionState,
        reason: String
    ) throws {
        guard !state.retainedDataReleaseStarted else {
            throw BuilderWorkspaceTransactionError.rollbackUnproven(
                "aggregate retained rollback evidence was already released")
        }
        try validateAggregateRetainedRoots(state)
        state.phase = .rollingBack
        state.failureReason = reason
        try publishAggregate(state)
        let operations = aggregateOperations(state)
        let current = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, mode: .restoration)
        let real = try ConfinedRoot(root: projectRoot.path)
        let archive = try ConfinedRoot(
            root: aggregateBaselineURL(state.descriptor.aggregateID).path, readOnly: true)
        for operation in operations {
            let expected = state.baseline.entry(operation.path)
            let found = current.entry(operation.path)
            if found != expected {
                if let found {
                    if found.type == .directory { try real.removeDirectory(operation.path) }
                    else { try real.removeFile(operation.path) }
                }
                if let expected {
                    guard expected.type == .regular else {
                        throw BuilderWorkspaceTransactionError.rollbackUnproven(operation.path)
                    }
                    try real.writeData(
                        operation.path,
                        archive.readStableData(operation.path, maxBytes: limits.maxFileBytes),
                        createParents: true)
                    try real.setModeAndSync(operation.path, mode: expected.mode)
                }
            }
        }
        for path in Set(state.createdDirectories).sorted(by: {
            $0.split(separator: "/").count > $1.split(separator: "/").count
        }) where state.baseline.entry(path) == nil {
            let manifest = try BuilderWorkspaceManifestScanner.scan(
                root: projectRoot, limits: limits, mode: .restoration)
            guard manifest.entry(path)?.type == .directory,
                  !manifest.entries.contains(where: { $0.path.hasPrefix(path + "/") }) else {
                continue
            }
            try real.removeDirectory(path)
        }
        let restored = try BuilderWorkspaceManifestScanner.scan(
            root: projectRoot, limits: limits, mode: .restoration)
        for operation in operations where
            restored.entry(operation.path) != state.baseline.entry(operation.path) {
            throw BuilderWorkspaceTransactionError.rollbackUnproven(operation.path)
        }
        state.phase = .rolledBack
        state.pendingIntent = nil
        state.pendingChild = nil
        try publishAggregate(state)
    }

    private func rebuildAggregate(_ state: inout BuilderAggregateTransactionState) throws {
        let workspace = aggregateWorkspaceURL(state.descriptor.aggregateID)
        try validateAggregateRetainedRoots(state)
        for item in try FileManager.default.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: item)
        }
        for item in try FileManager.default.contentsOfDirectory(
            at: aggregateBaselineURL(state.descriptor.aggregateID),
            includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(
                at: item, to: workspace.appendingPathComponent(item.lastPathComponent))
        }
        try validateAggregateRetainedRoots(state)
        for child in state.children.filter(\.merged).sorted(by: { $0.nodeID < $1.nodeID }) {
            try applyAggregateChild(child, baseline: state.baseline)
        }
        let current = try BuilderWorkspaceManifestScanner.scan(root: workspace, limits: limits)
        try validateAggregateSubject(
            baseline: state.baseline, subject: current,
            children: state.children.filter(\.merged))
        state.subject = current
        state.pendingChild = nil
        state.phase = Set(state.children.map(\.nodeID)) == Set(state.descriptor.expectedNodeIDs)
            && state.children.allSatisfy(\.merged) ? .ready : .collecting
        try publishAggregate(state)
    }

    private func applyAggregateChild(
        _ child: BuilderAggregateChildState,
        baseline: BuilderWorkspaceManifest
    ) throws {
        let aggregateRoot = try ConfinedRoot(root: aggregateWorkspaceURL(
            try aggregateID(for: child)).path)
        let childRootURL = stagingBase.appendingPathComponent(
            child.transactionKey, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        guard let childRootIdentity = child.workspaceRootIdentity,
              childRootIdentity.canonicalPath == childRootURL.path else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate child staged-root identity is missing")
        }
        _ = try retainedRootLease(childRootIdentity)
        let childRoot = try ConfinedRoot(root: childRootURL.path, readOnly: true)
        let childManifest = try BuilderWorkspaceManifestScanner.scan(
            root: childRootURL, limits: limits)
        let current = try BuilderWorkspaceManifestScanner.scan(
            root: aggregateWorkspaceURL(try aggregateID(for: child)), limits: limits)
        for operation in child.operations {
            guard current.entry(operation.path) == baseline.entry(operation.path) else {
                throw BuilderWorkspaceTransactionError.preimageMismatch(operation.path)
            }
            switch operation.kind {
            case .create, .modify:
                guard let next = childManifest.entry(operation.path), next.type == .regular else {
                    throw BuilderWorkspaceTransactionError.operationMismatch(operation.path)
                }
                try aggregateRoot.writeData(
                    operation.path,
                    childRoot.readStableData(operation.path, maxBytes: limits.maxFileBytes),
                    createParents: true)
                try aggregateRoot.setModeAndSync(operation.path, mode: next.mode)
            case .delete:
                try aggregateRoot.removeFile(operation.path)
            }
        }
    }

    private func aggregateID(for child: BuilderAggregateChildState) throws -> String {
        let registrationURL = aggregateRegistrationBaseURL
            .appendingPathComponent("\(child.transactionKey).json")
        guard let data = try BuilderDurableIO.readSecure(registrationURL) else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate child registration is missing")
        }
        let envelope = try JSONDecoder().decode(
            SealedBuilderAggregateRegistration.self, from: data)
        return envelope.registration.aggregateID
    }

    private func validateAggregateSubject(
        baseline: BuilderWorkspaceManifest,
        subject: BuilderWorkspaceManifest,
        children: [BuilderAggregateChildState]
    ) throws {
        let operations = children.flatMap(\.operations)
        let allowed = Set(operations.map(\.path))
        let before = Dictionary(uniqueKeysWithValues: baseline.entries.map { ($0.path, $0) })
        let after = Dictionary(uniqueKeysWithValues: subject.entries.map { ($0.path, $0) })
        for path in Set(before.keys).union(after.keys).filter({ before[$0] != after[$0] }) {
            if allowed.contains(path) { continue }
            if before[path] == nil, after[path]?.type == .directory,
               allowed.contains(where: { $0.hasPrefix(path + "/") }) { continue }
            throw BuilderWorkspaceTransactionError.undeclaredMutation(path)
        }
        for operation in operations {
            let prior = before[operation.path]
            let next = after[operation.path]
            switch operation.kind {
            case .create where prior == nil && next?.type == .regular: break
            case .modify where prior?.type == .regular && next?.type == .regular && prior != next: break
            case .delete where prior?.type == .regular && next == nil: break
            default: throw BuilderWorkspaceTransactionError.operationMismatch(operation.path)
            }
        }
    }

    private func aggregateOperations(
        _ state: BuilderAggregateTransactionState
    ) -> [BuilderMutationOperation] {
        state.children.filter(\.merged).flatMap(\.operations).sorted { $0.path < $1.path }
    }

    private func aggregateReceipt(
        _ state: BuilderAggregateTransactionState
    ) throws -> BuilderAggregateTransactionReceipt {
        let status: BuilderAggregateTransactionStatus
        switch state.phase {
        case .collecting, .merging: status = .collecting
        case .ready: status = .ready
        case .reviewApproved: status = .reviewApproved
        case .promoting, .committed: status = .committed
        case .finalized: status = .finalized
        case .rollingBack, .rolledBack, .failed: status = .rolledBack
        }
        let digest = try (state.subject ?? state.baseline).digest()
        return try .init(
            descriptor: state.descriptor, workspaceDigest: digest,
            childNodeIDs: state.children.filter(\.merged).map(\.nodeID), status: status)
    }

    private func validateAggregate(
        _ state: BuilderAggregateTransactionState,
        descriptor: BuilderAggregateTransactionDescriptor
    ) throws {
        try descriptor.validate()
        guard state.schemaVersion == 2, state.descriptor == descriptor,
              state.workspaceRootIdentity.canonicalPath
                == aggregateWorkspaceURL(descriptor.aggregateID).path,
              state.baselineRootIdentity.canonicalPath
                == aggregateBaselineURL(descriptor.aggregateID).path,
              (!state.workspaceReleased || state.retainedDataReleaseStarted),
              (!state.baselineReleased || state.retainedDataReleaseStarted) else {
            throw BuilderWorkspaceTransactionError.tampered
        }
    }

    func validateAggregateRetainedRoots(
        _ state: BuilderAggregateTransactionState
    ) throws {
        guard !state.workspaceReleased, !state.baselineReleased else {
            throw BuilderWorkspaceTransactionError.stateMismatch(
                "aggregate retained transaction data is incomplete")
        }
        _ = try retainedRootLease(state.workspaceRootIdentity)
        _ = try retainedRootLease(state.baselineRootIdentity)
    }

    private func loadAggregate(_ aggregateID: String) throws
        -> BuilderAggregateTransactionState? {
        guard let data = try BuilderDurableIO.readSecure(aggregateStateURL(aggregateID)) else {
            return nil
        }
        let envelope = try JSONDecoder().decode(
            SealedBuilderAggregateTransactionState.self, from: data)
        guard try BuilderDurableIO.canonicalData(envelope) == data else {
            throw BuilderWorkspaceTransactionError.tampered
        }
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(envelope.state),
                               as: UTF8.self)
        guard ForgeSeal.verify(canonical, seal: envelope.seal) else {
            throw BuilderWorkspaceTransactionError.tampered
        }
        return envelope.state
    }

    private func publishAggregate(_ state: BuilderAggregateTransactionState) throws {
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(state), as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        guard !seal.isEmpty else { throw BuilderWorkspaceTransactionError.tampered }
        try BuilderDurableIO.writeAtomic(
            try BuilderDurableIO.canonicalData(
                SealedBuilderAggregateTransactionState(state: state, seal: seal)),
            to: aggregateStateURL(state.descriptor.aggregateID))
    }

    private func publishAggregateRegistration(
        _ registration: BuilderAggregateRegistration,
        context: BuilderStageContext
    ) throws {
        try FileManager.default.createDirectory(
            at: aggregateRegistrationBaseURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let canonical = String(decoding: try BuilderDurableIO.canonicalData(registration),
                               as: UTF8.self)
        let seal = ForgeSeal.sign(canonical)
        try BuilderDurableIO.writeAtomic(
            try BuilderDurableIO.canonicalData(
                SealedBuilderAggregateRegistration(registration: registration, seal: seal)),
            to: aggregateRegistrationURL(context))
    }

    private var aggregateBaseURL: URL {
        stagingBase.appendingPathComponent(".aggregates", isDirectory: true)
    }
    private var aggregateRegistrationBaseURL: URL {
        stagingBase.appendingPathComponent(".aggregate-registrations", isDirectory: true)
    }
    private func aggregateURL(_ aggregateID: String) -> URL {
        aggregateBaseURL.appendingPathComponent(aggregateID, isDirectory: true)
    }
    private func aggregateWorkspaceURL(_ aggregateID: String) -> URL {
        aggregateURL(aggregateID).appendingPathComponent("workspace", isDirectory: true)
    }
    private func aggregateBaselineURL(_ aggregateID: String) -> URL {
        aggregateURL(aggregateID).appendingPathComponent("baseline", isDirectory: true)
    }
    private func aggregateStateURL(_ aggregateID: String) -> URL {
        aggregateURL(aggregateID).appendingPathComponent("aggregate.json")
    }
    private func aggregateRegistrationURL(_ context: BuilderStageContext) -> URL {
        aggregateRegistrationBaseURL.appendingPathComponent(
            "\(transactionURL(context).lastPathComponent).json")
    }
}
