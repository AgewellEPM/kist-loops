import Foundation

/// Host-owned trust state. It is intentionally not Codable and never appears in imported SML.
public enum SMLPluginTrustLevel: Sendable, Equatable {
    case contracted
    case verified
}

public enum SMLPluginIsolation: Sendable, Equatable {
    case sandboxed
    case trustedProcess
}

/// An attestation loaded by the host from its trusted registry, bound to one exact imported claim.
/// A payload cannot promote itself by adding trust fields because those fields are not part of the IR.
public struct SMLPluginAttestation: Sendable, Equatable {
    public let contract: SMLPluginContract
    public let trustLevel: SMLPluginTrustLevel
    public let isolation: SMLPluginIsolation
    public let attestedBy: String

    public init(
        contract: SMLPluginContract,
        trustLevel: SMLPluginTrustLevel,
        isolation: SMLPluginIsolation,
        attestedBy: String
    ) {
        self.contract = contract
        self.trustLevel = trustLevel
        self.isolation = isolation
        self.attestedBy = attestedBy
    }
}

/// Registry snapshot supplied by the daemon, never decoded from the workflow being admitted.
public struct SMLExecutionAdmissionCatalog: Sendable {
    public let observationSources: Set<String>
    public let retrievalSources: Set<String>
    public let toolCapabilities: Set<String>
    public let modelPurposes: Set<String>
    public let modelOutputSchemas: Set<String>
    public let vCards: Set<String>
    public let workflows: Set<String>
    public let verifiers: Set<String>
    public let rollbackProcedures: Set<String>
    public let approvalAuthorities: Set<String>
    public let plugins: [String: SMLPluginAttestation]

    public init(
        observationSources: Set<String> = [],
        retrievalSources: Set<String> = [],
        toolCapabilities: Set<String> = [],
        modelPurposes: Set<String> = [],
        modelOutputSchemas: Set<String> = [],
        vCards: Set<String> = [],
        workflows: Set<String> = [],
        verifiers: Set<String> = [],
        rollbackProcedures: Set<String> = [],
        approvalAuthorities: Set<String> = [],
        plugins: [String: SMLPluginAttestation] = [:]
    ) {
        self.observationSources = observationSources
        self.retrievalSources = retrievalSources
        self.toolCapabilities = toolCapabilities
        self.modelPurposes = modelPurposes
        self.modelOutputSchemas = modelOutputSchemas
        self.vCards = vCards
        self.workflows = workflows
        self.verifiers = verifiers
        self.rollbackProcedures = rollbackProcedures
        self.approvalAuthorities = approvalAuthorities
        self.plugins = plugins
    }
}

public struct SMLWorkflowAdmissionError: Error, Sendable, Equatable, CustomStringConvertible {
    public let diagnostics: [SMLDiagnostic]

    public var description: String {
        diagnostics.map(\.description).joined(separator: "\n")
    }
}

/// Opaque proof that structural validation and host-owned registry admission both succeeded.
/// The raw workflow stays internal so execution entry points can require this type.
public struct SMLAdmittedWorkflow: Sendable {
    let workflow: SMLWorkflow
    let pluginAttestations: [String: SMLPluginAttestation]

    public var id: String { workflow.id }
    public var version: String { workflow.version }
}

public enum SMLWorkflowAdmission {
    public static func admitForExecution(
        _ candidate: SMLWorkflowCandidate,
        catalog: SMLExecutionAdmissionCatalog
    ) throws -> SMLAdmittedWorkflow {
        let workflow = candidate.workflow
        var diagnostics: [SMLDiagnostic] = []

        func reject(_ code: String, _ path: String, _ message: String) {
            guard diagnostics.count < SMLWorkflowValidator.maximumDiagnostics else { return }
            diagnostics.append(SMLValidationSupport.error(code, path, message))
        }
        func requireReference(
            _ value: String?, in allowed: Set<String>, code: String, path: String
        ) {
            guard let value, allowed.contains(value) else {
                reject(code, path, "reference is not present in the host admission catalog")
                return
            }
        }

        var admittedPlugins: [String: SMLPluginAttestation] = [:]
        for (index, instruction) in workflow.instructions.enumerated() {
            let path = "instructions[\(index)]"
            switch instruction.op {
            case .observe:
                requireReference(instruction.source, in: catalog.observationSources,
                                 code: "unregistered_observation_source", path: "\(path).source")
            case .retrieve:
                requireReference(instruction.source, in: catalog.retrievalSources,
                                 code: "unregistered_retrieval_source", path: "\(path).source")
            case .callTool:
                requireReference(instruction.capability, in: catalog.toolCapabilities,
                                 code: "unregistered_tool", path: "\(path).capability")
            case .callModel:
                requireReference(instruction.purpose, in: catalog.modelPurposes,
                                 code: "unregistered_model_purpose", path: "\(path).purpose")
                requireReference(instruction.outputSchema, in: catalog.modelOutputSchemas,
                                 code: "unregistered_output_schema", path: "\(path).output_schema")
            case .invokeVCard:
                requireReference(instruction.capability, in: catalog.vCards,
                                 code: "unregistered_vcard", path: "\(path).capability")
                requireReference(instruction.verifier, in: catalog.verifiers,
                                 code: "unregistered_verifier", path: "\(path).verifier")
            case .runPlugin:
                guard let claim = instruction.plugin else { continue }
                guard let attestation = catalog.plugins[claim.id] else {
                    reject("unattested_plugin", "\(path).plugin",
                           "plugin has no host-owned attestation")
                    continue
                }
                guard attestation.contract == claim else {
                    reject("plugin_attestation_mismatch", "\(path).plugin",
                           "host attestation does not match the imported contract exactly")
                    continue
                }
                if claim.sideEffectLevel == .unknown {
                    reject("unclassified_plugin", "\(path).plugin.side_effect_level",
                           "execution requires a classified side-effect level")
                }
                if attestation.isolation == .trustedProcess
                    && attestation.trustLevel != .verified {
                    reject("plugin_requires_sandbox", "\(path).plugin",
                           "only verified plugins may leave sandbox isolation")
                }
                if let verifier = claim.verifier, !catalog.verifiers.contains(verifier) {
                    reject("unregistered_plugin_verifier", "\(path).plugin.verifier",
                           "plugin verifier is not registered by the host")
                }
                if let rollback = claim.rollback,
                   !catalog.rollbackProcedures.contains(rollback) {
                    reject("unregistered_plugin_rollback", "\(path).plugin.rollback",
                           "plugin rollback procedure is not registered by the host")
                }
                admittedPlugins[claim.id] = attestation
            case .runWorkflow:
                requireReference(instruction.workflow, in: catalog.workflows,
                                 code: "unregistered_workflow", path: "\(path).workflow")
            case .verify, .commit:
                requireReference(instruction.verifier, in: catalog.verifiers,
                                 code: "unregistered_verifier", path: "\(path).verifier")
            case .waitApproval:
                requireReference(instruction.owner, in: catalog.approvalAuthorities,
                                 code: "unregistered_approval_authority", path: "\(path).owner")
            case .branch, .assert, .checkpoint, .retry, .rollback, .escalate,
                 .emitReceipt, .complete:
                break
            }
        }

        guard diagnostics.isEmpty else {
            throw SMLWorkflowAdmissionError(diagnostics: diagnostics)
        }
        return SMLAdmittedWorkflow(workflow: workflow, pluginAttestations: admittedPlugins)
    }
}
