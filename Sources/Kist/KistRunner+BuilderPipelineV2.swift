import Foundation
import AgentCore

extension KistRunner {
    static let builderStageArtifactKind = "kist.builder-stage-artifact.v2"

    struct BuilderDurableCouncilDecision: Codable, Sendable, Equatable {
        let finalPlan: String
        let builderBrief: String
        let artifactPath: String
        let digest: String

        init(_ value: AutonomyCouncilDecision) {
            finalPlan = value.finalPlan
            builderBrief = value.builderBrief
            artifactPath = value.artifactPath
            digest = value.digest
        }

        var value: AutonomyCouncilDecision {
            .init(finalPlan: finalPlan, builderBrief: builderBrief,
                  artifactPath: artifactPath, digest: digest)
        }
    }

    struct BuilderDurableDossier: Codable, Sendable, Equatable {
        let text: String
        let paths: [String]
        let researchRunID: String?
        let manifestPath: String?
        let reportPath: String?
        let reportDigest: String?
        let peelReceipt: PEELEvidenceReceipt?
        let council: BuilderDurableCouncilDecision?

        init(_ value: AutonomyMissionDossier) {
            text = value.text
            paths = value.paths
            researchRunID = value.researchRunID
            manifestPath = value.manifestPath
            reportPath = value.reportPath
            reportDigest = value.reportDigest
            peelReceipt = value.peelReceipt
            council = value.council.map(BuilderDurableCouncilDecision.init)
        }

        var value: AutonomyMissionDossier {
            .init(text: text, paths: paths, researchRunID: researchRunID,
                  manifestPath: manifestPath, reportPath: reportPath,
                  reportDigest: reportDigest, peelReceipt: peelReceipt,
                  council: council?.value)
        }
    }

    struct BuilderStageArtifactPayload: Codable, Sendable, Equatable {
        let dossier: BuilderDurableDossier
        let advisoryTaskBoard: BuilderTaskBoardLineage?
    }

    struct BuilderStageArtifactEnvelope: Codable, Sendable, Equatable {
        static let currentSchemaVersion = 2
        let schemaVersion: Int
        let builderContractID: String
        let graphFingerprint: String
        let nodeID: String
        let attempt: Int
        let dependencyBindingDigests: [String: String]
        let payload: BuilderStageArtifactPayload
        let bindingDigest: String
        let seal: String

        private struct Binding: Codable {
            let schemaVersion: Int
            let builderContractID: String
            let graphFingerprint: String
            let nodeID: String
            let attempt: Int
            let dependencyBindingDigests: [String: String]
            let payload: BuilderStageArtifactPayload
        }

        init(builderContractID: String, graphFingerprint: String,
             nodeID: String, attempt: Int,
             dependencyBindingDigests: [String: String],
             payload: BuilderStageArtifactPayload) throws {
            let binding = Binding(
                schemaVersion: Self.currentSchemaVersion,
                builderContractID: builderContractID,
                graphFingerprint: graphFingerprint,
                nodeID: nodeID,
                attempt: attempt,
                dependencyBindingDigests: dependencyBindingDigests,
                payload: payload)
            let canonical = try Self.canonical(binding)
            let digest = BuilderEvidenceDigest.sha256(canonical)
            let seal = ForgeSeal.sign(canonical)
            guard !seal.isEmpty else {
                throw BuilderRunError.persistedStateInvalid(
                    "Kist stage artifact seal is unavailable")
            }
            self.schemaVersion = binding.schemaVersion
            self.builderContractID = builderContractID
            self.graphFingerprint = graphFingerprint
            self.nodeID = nodeID
            self.attempt = attempt
            self.dependencyBindingDigests = dependencyBindingDigests
            self.payload = payload
            self.bindingDigest = digest
            self.seal = seal
        }

        func validate(builderContractID: String, graphFingerprint: String,
                      nodeID: String) throws {
            guard schemaVersion == Self.currentSchemaVersion else {
                throw BuilderRunError.persistedStateInvalid(
                    "legacy Kist stage artifact schema \(schemaVersion) is non-resumable")
            }
            guard self.builderContractID == builderContractID,
                  self.graphFingerprint == graphFingerprint,
                  self.nodeID == nodeID,
                  attempt > 0 else {
                throw BuilderRunError.persistedStateMismatch
            }
            let binding = Binding(
                schemaVersion: schemaVersion, builderContractID: self.builderContractID,
                graphFingerprint: self.graphFingerprint, nodeID: self.nodeID,
                attempt: attempt, dependencyBindingDigests: dependencyBindingDigests,
                payload: payload)
            let canonical = try Self.canonical(binding)
            guard BuilderEvidenceDigest.sha256(canonical) == bindingDigest,
                  ForgeSeal.verify(canonical, seal: seal) else {
                throw BuilderRunError.persistedStateInvalid(
                    "Kist stage artifact seal or digest is invalid")
            }
        }

        private static func canonical<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
    }

    struct BuilderCoboloContractEnvelope: Codable, Sendable, Equatable {
        static let currentSchemaVersion = 1
        let schemaVersion: Int
        let builderContractID: String
        let graphFingerprint: String
        let providerFingerprint: String
        let nodeID: String
        let attempt: Int
        let sealedContract: SealedBuilderExecutionContract
        let bindingDigest: String
        let seal: String

        private struct Binding: Codable {
            let schemaVersion: Int
            let builderContractID: String
            let graphFingerprint: String
            let providerFingerprint: String
            let nodeID: String
            let attempt: Int
            let sealedContract: SealedBuilderExecutionContract
        }

        init(builderContractID: String, graphFingerprint: String,
             providerFingerprint: String, nodeID: String, attempt: Int,
             sealedContract: SealedBuilderExecutionContract) throws {
            let binding = Binding(
                schemaVersion: Self.currentSchemaVersion,
                builderContractID: builderContractID,
                graphFingerprint: graphFingerprint,
                providerFingerprint: providerFingerprint,
                nodeID: nodeID, attempt: attempt, sealedContract: sealedContract)
            let canonical = try Self.canonical(binding)
            let seal = ForgeSeal.sign(canonical)
            guard !seal.isEmpty else {
                throw BuilderRunError.persistedStateInvalid(
                    "Cobolo contract artifact seal is unavailable")
            }
            self.schemaVersion = binding.schemaVersion
            self.builderContractID = builderContractID
            self.graphFingerprint = graphFingerprint
            self.providerFingerprint = providerFingerprint
            self.nodeID = nodeID
            self.attempt = attempt
            self.sealedContract = sealedContract
            self.bindingDigest = BuilderEvidenceDigest.sha256(canonical)
            self.seal = seal
        }

        func validate(builderContractID: String, graphFingerprint: String,
                      providerFingerprint: String, nodeID: String,
                      attempt: Int, graphNodeIDs: [String]) throws {
            guard schemaVersion == Self.currentSchemaVersion else {
                throw BuilderRunError.persistedStateInvalid(
                    "legacy Cobolo contract artifact is non-resumable")
            }
            guard self.builderContractID == builderContractID,
                  self.graphFingerprint == graphFingerprint,
                  self.providerFingerprint == providerFingerprint,
                  self.nodeID == nodeID, self.attempt == attempt else {
                throw BuilderRunError.persistedStateMismatch
            }
            let binding = Binding(
                schemaVersion: schemaVersion, builderContractID: self.builderContractID,
                graphFingerprint: self.graphFingerprint,
                providerFingerprint: self.providerFingerprint,
                nodeID: self.nodeID, attempt: self.attempt,
                sealedContract: sealedContract)
            let canonical = try Self.canonical(binding)
            guard BuilderEvidenceDigest.sha256(canonical) == bindingDigest,
                  ForgeSeal.verify(canonical, seal: seal) else {
                throw BuilderRunError.persistedStateInvalid(
                    "Cobolo contract artifact seal or digest is invalid")
            }
            try sealedContract.validate(
                builderContractID: builderContractID, graphNodeIDs: graphNodeIDs)
        }

        private static func canonical<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        }
    }

    actor BuilderCompositionArtifactStore {
        let rootURL: URL
        let builderContractID: String
        let graphFingerprint: String
        private let root: ConfinedRoot
        private let encoder: JSONEncoder
        private let decoder = JSONDecoder()

        init(rootURL: URL, builderContractID: String,
             graphFingerprint: String) throws {
            try FileManager.default.createDirectory(
                at: rootURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
            self.builderContractID = builderContractID
            self.graphFingerprint = graphFingerprint
            self.root = try ConfinedRoot(root: self.rootURL.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            self.encoder = encoder
        }

        func saveStage(nodeID: String, attempt: Int,
                       dependencies: [BuilderAcceptedDependencyResult],
                       dossier: AutonomyMissionDossier,
                       advisoryTaskBoard: BuilderTaskBoardLineage?) throws -> BuilderArtifact {
            let bindings = Dictionary(uniqueKeysWithValues: try dependencies.map { dependency in
                guard let digest = dependency.bindingDigest else {
                    throw BuilderRunError.persistedStateInvalid(
                        "dependency \(dependency.nodeID) has no sealed binding")
                }
                return (dependency.nodeID, digest)
            })
            let envelope = try BuilderStageArtifactEnvelope(
                builderContractID: builderContractID,
                graphFingerprint: graphFingerprint,
                nodeID: nodeID, attempt: attempt,
                dependencyBindingDigests: bindings,
                payload: .init(dossier: BuilderDurableDossier(dossier),
                               advisoryTaskBoard: advisoryTaskBoard))
            let path = stagePath(nodeID: nodeID, attempt: attempt)
            let data = try encoder.encode(envelope)
            try publishExact(data, path: path)
            return BuilderArtifact(
                path: rootURL.appendingPathComponent(path).path,
                kind: builderStageArtifactKind,
                digest: envelope.bindingDigest)
        }

        func loadStage(nodeID: String, attempt: Int) throws
            -> BuilderStageArtifactEnvelope {
            let path = stagePath(nodeID: nodeID, attempt: attempt)
            let data = try root.readStableData(path, maxBytes: 8 * 1_024 * 1_024)
            let envelope = try decoder.decode(BuilderStageArtifactEnvelope.self, from: data)
            try envelope.validate(
                builderContractID: builderContractID,
                graphFingerprint: graphFingerprint, nodeID: nodeID)
            guard envelope.attempt == attempt else {
                throw BuilderRunError.persistedStateMismatch
            }
            return envelope
        }

        func loadDependency(_ dependency: BuilderAcceptedDependencyResult) throws
            -> BuilderStageArtifactEnvelope {
            let artifact = try dependency.worker.artifacts.first {
                $0.kind == builderStageArtifactKind
            }.unwrap(or: BuilderRunError.persistedStateInvalid(
                "dependency \(dependency.nodeID) has no durable Kist stage artifact"))
            let prefix = rootURL.appendingPathComponent(
                "artifacts/\(dependency.nodeID)-").path
            guard artifact.path.hasPrefix(prefix),
                  let attempt = Int(URL(fileURLWithPath: artifact.path)
                    .deletingPathExtension().lastPathComponent
                    .split(separator: "-").last ?? "") else {
                throw BuilderRunError.persistedStateInvalid(
                    "dependency \(dependency.nodeID) artifact attempt is invalid")
            }
            let envelope = try loadStage(nodeID: dependency.nodeID,
                                         attempt: attempt)
            let expectedPath = rootURL.appendingPathComponent(
                stagePath(nodeID: dependency.nodeID, attempt: envelope.attempt)).path
            guard artifact.path == expectedPath,
                  artifact.digest == envelope.bindingDigest else {
                throw BuilderRunError.persistedStateInvalid(
                    "dependency \(dependency.nodeID) artifact descriptor drifted")
            }
            return envelope
        }

        func loadDependency(_ dependency: BuilderCommittedDependencyResult) throws
            -> BuilderStageArtifactEnvelope {
            let artifact = try dependency.worker.artifacts.first {
                $0.kind == builderStageArtifactKind
            }.unwrap(or: BuilderRunError.persistedStateInvalid(
                "dependency \(dependency.node.id) has no durable Kist stage artifact"))
            let prefix = "artifacts/\(dependency.node.id)-"
            guard artifact.path.hasPrefix(rootURL.appendingPathComponent(prefix).path) else {
                throw BuilderRunError.persistedStateInvalid(
                    "dependency \(dependency.node.id) artifact path escaped its durable store")
            }
            let leaf = URL(fileURLWithPath: artifact.path).deletingPathExtension()
                .lastPathComponent
            guard let attempt = Int(leaf.split(separator: "-").last ?? "") else {
                throw BuilderRunError.persistedStateInvalid(
                    "dependency \(dependency.node.id) artifact attempt is invalid")
            }
            let envelope = try loadStage(nodeID: dependency.node.id, attempt: attempt)
            guard artifact.digest == envelope.bindingDigest else {
                throw BuilderRunError.persistedStateInvalid(
                    "dependency \(dependency.node.id) artifact digest drifted")
            }
            return envelope
        }

        func saveContract(_ sealed: SealedBuilderExecutionContract,
                          providerFingerprint: String,
                          nodeID: String, attempt: Int) throws {
            let envelope = try BuilderCoboloContractEnvelope(
                builderContractID: builderContractID,
                graphFingerprint: graphFingerprint,
                providerFingerprint: providerFingerprint,
                nodeID: nodeID, attempt: attempt, sealedContract: sealed)
            try publishExact(encoder.encode(envelope),
                             path: contractPath(nodeID: nodeID, attempt: attempt))
        }

        func loadContract(providerFingerprint: String, nodeID: String,
                          attempt: Int, graphNodeIDs: [String]) throws
            -> SealedBuilderExecutionContract {
            let data = try root.readStableData(
                contractPath(nodeID: nodeID, attempt: attempt), maxBytes: 2 * 1_024 * 1_024)
            let envelope = try decoder.decode(BuilderCoboloContractEnvelope.self, from: data)
            try envelope.validate(
                builderContractID: builderContractID,
                graphFingerprint: graphFingerprint,
                providerFingerprint: providerFingerprint,
                nodeID: nodeID, attempt: attempt, graphNodeIDs: graphNodeIDs)
            return envelope.sealedContract
        }

        func rebindContractForRetry(
            providerFingerprint: String, nodeID: String,
            priorAttempt: Int, retryAttempt: Int, graphNodeIDs: [String]
        ) throws -> SealedBuilderExecutionContract {
            guard priorAttempt > 0, retryAttempt == priorAttempt + 1 else {
                throw BuilderDynamicContractError.invalidAttempt
            }
            let prior = try loadContract(
                providerFingerprint: providerFingerprint, nodeID: nodeID,
                attempt: priorAttempt, graphNodeIDs: graphNodeIDs)
            try saveContract(
                prior, providerFingerprint: providerFingerprint,
                nodeID: nodeID, attempt: retryAttempt)
            return prior
        }

        private func publishExact(_ data: Data, path: String) throws {
            do {
                if try root.fileType(path).exists {
                    let existing = try root.readStableData(path, maxBytes: 8 * 1_024 * 1_024)
                    guard existing == data else {
                        throw BuilderRunError.persistedStateInvalid(
                            "durable Kist artifact drifted at \(path)")
                    }
                    return
                }
            } catch ToolError.notFound {}
            try root.writeData(path, data, createParents: true)
        }

        private func stagePath(nodeID: String, attempt: Int) -> String {
            "artifacts/\(nodeID)-\(attempt).json"
        }

        private func contractPath(nodeID: String, attempt: Int) -> String {
            "contracts/\(nodeID)-\(attempt).json"
        }
    }

    struct BuilderCoboloContractProvider: BuilderNodeExecutionContractProvider {
        let identity: BuilderNodeContractProviderIdentity
        let store: BuilderCompositionArtifactStore
        let projectRoot: String
        let target: String
        let captainDecisionDigest: String
        let identityPlan: CoboloIdentityPlan
        let maxRevisions: Int
        let maxTokens: Int?

        init(store: BuilderCompositionArtifactStore, projectRoot: String,
             target: String, captainDecisionDigest: String,
             identityPlan: CoboloIdentityPlan, maxRevisions: Int,
             maxTokens: Int?) throws {
            self.store = store
            self.projectRoot = projectRoot
            self.target = target
            self.captainDecisionDigest = captainDecisionDigest
            self.identityPlan = identityPlan
            self.maxRevisions = maxRevisions
            self.maxTokens = maxTokens
            self.identity = try BuilderNodeContractProviderIdentity(
                providerID: "kist-cobolo-contract",
                implementationFingerprint: BuilderEvidenceDigest.sha256(
                    "kist.cobolo.dynamic-contract.v2"))
        }

        func sealedContract(for request: BuilderNodeContractRequest) async throws
            -> SealedBuilderExecutionContract {
            guard request.node.id == "cobolo-execution",
                  request.dependencies.count == 1,
                  let dependency = request.dependencies.first else {
                throw BuilderRunError.persistedStateInvalid(
                    "Cobolo contract selection has an invalid dependency set")
            }
            let artifact = try await store.loadDependency(dependency)
            let dossier = artifact.payload.dossier.value
            guard let runID = dossier.researchRunID,
                  dossier.reportDigest != nil,
                  let peel = dossier.peelReceipt,
                  let council = dossier.council else {
                throw BuilderRunError.persistedStateInvalid(
                    "Cobolo dependency artifact lacks research, PEEL, or council lineage")
            }
            let lineage = try BuilderLineageEnvelope(
                captainDecisionDigest: captainDecisionDigest,
                research: BuilderResearchLineage(
                    runID: runID,
                    dossierDigest: builderResearchDossierDigest(dossier)),
                peelReceiptDigest: peel.digest,
                councilArtifactDigest: council.digest,
                taskBoard: artifact.payload.advisoryTaskBoard)
            let sealed = try coboloIssueExecutionContract(
                builderContractID: request.builderContract.id,
                builderNodeID: request.node.id, target: target,
                root: projectRoot, lineage: lineage,
                identityPlan: identityPlan, maxRevisions: maxRevisions,
                maxTokens: maxTokens)
            try await store.saveContract(
                sealed, providerFingerprint: identity.implementationFingerprint,
                nodeID: request.node.id, attempt: request.attempt)
            return sealed
        }
    }

    struct BuilderCoboloObservationProvider: BuilderNodeObservationSourceProvider {
        let source: BuilderIsolatedWorkspaceTransactionSource
        let store: BuilderCompositionArtifactStore
        let providerFingerprint: String

        func source(for request: BuilderNodeObservationSourceRequest) async throws
            -> any BuilderStageObservationSource {
            let sealed = try await store.loadContract(
                providerFingerprint: providerFingerprint,
                nodeID: request.node.id, attempt: request.attempt,
                graphNodeIDs: request.graphNodeIDs)
            guard sealed.fingerprint == request.contractFingerprint,
                  BuilderEvidenceDigest.sha256(sealed.seal)
                    == request.contractSealReference else {
                throw BuilderRunError.persistedStateInvalid(
                    "Cobolo observation source is not bound to the selected contract")
            }
            return source
        }
    }

    struct BuilderProjectReadOnlyObservationProvider: BuilderReadOnlyObservationSourceProvider {
        let projectRoot: String

        func source(for context: BuilderReadOnlyObservationContext) async throws
            -> any BuilderReadOnlyObservationSource {
            BuilderProjectReadOnlyObservationSource(projectRoot: projectRoot)
        }
    }

    actor BuilderProjectReadOnlyObservationSource: BuilderReadOnlyObservationSource {
        let projectRoot: String

        init(projectRoot: String) { self.projectRoot = projectRoot }

        func prepare(_ context: BuilderReadOnlyObservationContext) async throws
            -> BuilderReadOnlyBaseline {
            let digest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: projectRoot)
            guard !digest.hasPrefix("unavailable:") else {
                throw BuilderRunError.persistedStateInvalid(
                    "read-only governed workspace digest is unavailable")
            }
            return try .init(
                builderContractID: context.builderContractID,
                nodeID: context.node.id, attempt: context.attempt,
                workspaceDigest: digest)
        }

        func observe(context: BuilderReadOnlyObservationContext,
                     baseline: BuilderReadOnlyBaseline,
                     worker: BuilderWorkerReceipt) async throws
            -> BuilderReadOnlyObservation {
            let current = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: projectRoot)
            guard !current.hasPrefix("unavailable:") else {
                throw BuilderRunError.persistedStateInvalid(
                    "read-only governed workspace digest is unavailable")
            }
            return try .init(
                builderContractID: context.builderContractID,
                nodeID: context.node.id, attempt: context.attempt,
                workspaceDigestBefore: baseline.workspaceDigest,
                workspaceDigestAfter: current,
                observedChangedPaths: current == baseline.workspaceDigest
                    ? [] : ["workspace-digest"])
        }

        func rollback(_ request: BuilderReadOnlyRollbackRequest) async throws
            -> BuilderReadOnlyRollbackObservation {
            let current = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: projectRoot)
            guard current == request.baseline.workspaceDigest else {
                throw BuilderReadOnlyObservationError.rollbackUnproven
            }
            return try .init(
                builderContractID: request.context.builderContractID,
                nodeID: request.context.node.id,
                attempt: request.context.attempt,
                workspaceDigestAfter: current,
                restoredPathStates: request.baseline.pathStates)
        }
    }

    static func builderDurableStateDirectory(projectRoot: String,
                                             contractID: String) -> URL {
        let canonical = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
        let projectKey = BuilderEvidenceDigest.sha256(canonical)
        return URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("kist-builder-v2", isDirectory: true)
            .appendingPathComponent(projectKey, isDirectory: true)
            .appendingPathComponent(contractID, isDirectory: true)
    }

    static func builderGraphFingerprint(_ graph: BuilderGraph) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return BuilderEvidenceDigest.sha256(
            String(decoding: try encoder.encode(graph), as: UTF8.self))
    }

    static func builderCoboloGraphPolicy() -> BuilderGraphExecutionPolicy {
        .init(nodeClasses: [
            "research": .readOnly,
            "symbolic-peel": .readOnly,
            "council": .readOnly,
            "task-board-projection": .readOnly,
            "cobolo-execution": .mutation,
        ])
    }

    static func builderRebasedToolContext(_ context: ToolContext,
                                          projectRoot: String,
                                          governedExecutionWorkspace: Bool = false) -> ToolContext {
        ToolContext(
            projectRoot: projectRoot, shell: context.shell,
            // BuilderExecutionGovernance installs the contract-bound OS sandbox around the
            // entire build callback. Applying ToolContext's generic sandbox inside that scope
            // nests sandbox-exec and fails legitimate model-invoked commands with exit 71.
            // Disable only that redundant inner layer; ProcessGroupRunner still discovers the
            // registered Builder scope and emits builder_os_sandboxed=true evidence.
            sandbox: governedExecutionWorkspace ? .disabled : context.sandbox,
            authorizationScope: context.authorizationScope,
            scopeOverrideApproved: context.scopeOverrideApproved,
            skillLocations: context.skillLocations,
            skillTracker: context.skillTracker,
            auditLog: context.auditLog,
            externalReadRoots: context.externalReadRoots)
    }

    static func builderWorker(_ worker: BuilderWorkerReceipt,
                              adding artifact: BuilderArtifact) -> BuilderWorkerReceipt {
        BuilderWorkerReceipt(
            nodeID: worker.nodeID, provider: worker.provider, model: worker.model,
            artifacts: worker.artifacts + [artifact], changedPaths: [],
            checks: worker.checks, unresolvedRisks: worker.unresolvedRisks,
            usage: worker.usage, commandEvidence: worker.commandEvidence,
            requiredSupportingObligations: worker.requiredSupportingObligations,
            supportingCommandReceipts: worker.supportingCommandReceipts,
            planFinalVerificationReceipt: worker.planFinalVerificationReceipt,
            missionInstanceID: worker.missionInstanceID)
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let self else { throw error() }
        return self
    }
}
