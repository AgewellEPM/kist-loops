import Foundation
import AgentCore

extension KistRunner {
    /// Offline export needs an admission catalog only to prove the generated surfaces are structurally
    /// mountable. This catalog is derived from the already-imported workflow references and is not
    /// serialized; live execution still requires the host's fresh admission catalog and authority resolver.
    static func derivedSMLAdmissionCatalog(
        for workflows: [SMLWorkflow]
    ) -> SMLExecutionAdmissionCatalog {
        var observationSources = Set<String>()
        var retrievalSources = Set<String>()
        var toolCapabilities = Set<String>()
        var modelPurposes = Set<String>()
        var modelOutputSchemas = Set<String>()
        var vCards = Set<String>()
        var workflowIDs = Set(workflows.map(\.id))
        var verifiers = Set<String>()
        var rollbackProcedures = Set<String>()
        var approvalAuthorities = Set<String>()

        for workflow in workflows {
            for instruction in workflow.instructions {
                switch instruction.op {
                case .observe:
                    insert(instruction.source, into: &observationSources)
                case .retrieve:
                    insert(instruction.source, into: &retrievalSources)
                case .callTool:
                    insert(instruction.capability, into: &toolCapabilities)
                case .callModel:
                    insert(instruction.purpose, into: &modelPurposes)
                    insert(instruction.outputSchema, into: &modelOutputSchemas)
                case .invokeVCard:
                    insert(instruction.capability, into: &vCards)
                    insert(instruction.verifier, into: &verifiers)
                case .runWorkflow:
                    insert(instruction.workflow, into: &workflowIDs)
                case .verify, .commit:
                    insert(instruction.verifier, into: &verifiers)
                case .waitApproval:
                    insert(instruction.owner, into: &approvalAuthorities)
                case .runPlugin:
                    insert(instruction.plugin?.verifier, into: &verifiers)
                    insert(instruction.plugin?.rollback, into: &rollbackProcedures)
                case .branch, .assert, .checkpoint, .retry, .rollback, .escalate,
                     .emitReceipt, .complete:
                    break
                }
            }
        }

        return SMLExecutionAdmissionCatalog(
            observationSources: observationSources,
            retrievalSources: retrievalSources,
            toolCapabilities: toolCapabilities,
            modelPurposes: modelPurposes,
            modelOutputSchemas: modelOutputSchemas,
            vCards: vCards,
            workflows: workflowIDs,
            verifiers: verifiers,
            rollbackProcedures: rollbackProcedures,
            approvalAuthorities: approvalAuthorities
        )
    }

    private static func insert(_ value: String?, into values: inout Set<String>) {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        values.insert(value)
    }
}
