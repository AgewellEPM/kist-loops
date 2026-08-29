import Foundation

/// Descriptor-only operating guide for putting a model or external orchestrator over a mounted
/// workflow runtime.
///
/// The guide is generated from the same catalog/mount/planning surfaces that drive the REPL, API,
/// model router, and Onyx exports. It carries no actor, lease, credentials, runtime handle, replay
/// state, or host authority; mutations still have to cross the runtime command gateway.
public struct SMLWorkflowRuntimeAgentGuide: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let systemPrompt: String
    public let modelRouterTool: SMLWorkflowModelToolDescriptor
    public let workflowGuides: [SMLWorkflowRuntimeWorkflowAgentGuide]
    public let metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]

    public init(catalog: SMLWorkflowRuntimeCatalog) {
        let mountContract = catalog.mountContract
        let mountsByWorkflowID = Dictionary(
            uniqueKeysWithValues: mountContract.workflowMounts.map { ($0.workflowID, $0) }
        )
        let planning = catalog.planningManifest
        let toolsByWorkflowID = Dictionary(grouping: planning.toolIndex, by: \.workflowID)
        let decomposableByWorkflowID = Dictionary(grouping: planning.decomposableUnits, by: \.workflowID)
        let approvalsByWorkflowID = Dictionary(grouping: planning.approvalGates, by: \.workflowID)
        let workflowGuides = catalog.workflows.map { descriptor in
            SMLWorkflowRuntimeWorkflowAgentGuide(
                descriptor: descriptor,
                mount: mountsByWorkflowID[descriptor.workflowID],
                planningToolIndex: toolsByWorkflowID[descriptor.workflowID] ?? [],
                decomposableUnits: decomposableByWorkflowID[descriptor.workflowID] ?? [],
                approvalGates: approvalsByWorkflowID[descriptor.workflowID] ?? []
            )
        }
        let modelRouterTool = catalog.modelRouter.tool
        let metadataEndpoints = catalog.metadataEndpoints
        self.schemaVersion = Self.currentSchemaVersion
        self.modelRouterTool = modelRouterTool
        self.workflowGuides = workflowGuides.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
        self.metadataEndpoints = metadataEndpoints.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            return $0.operationID < $1.operationID
        }
        self.systemPrompt = Self.systemPrompt(
            modelRouterTool: modelRouterTool,
            workflowGuides: self.workflowGuides,
            metadataEndpoints: self.metadataEndpoints
        )
    }

    private static func systemPrompt(
        modelRouterTool: SMLWorkflowModelToolDescriptor,
        workflowGuides: [SMLWorkflowRuntimeWorkflowAgentGuide],
        metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
    ) -> String {
        let workflows = workflowGuides
            .map(\.promptSection)
            .joined(separator: "\n\n")
        let metadata = metadataEndpoints
            .map { "\($0.method.rawValue) \($0.pathTemplate) -> \($0.resource.rawValue)" }
            .joined(separator: "\n")
        return """
        You are operating a mounted SML workflow runtime.
        Your prose is advisory and never proves completion. To request a state transition, call
        \(modelRouterTool.name) exactly once with a mounted workflow_id and one line from that
        workflow's grammar. Never call an unlisted command, never claim a capability step passed,
        and never fabricate a receipt.

        Break work into small contextual workflow steps. Use the planning units, decomposable units,
        approval gates, REPL grammar, API routes, model tools, and Onyx driver IDs below as the
        source of truth. Descriptor-only metadata is safe to inspect; mutations must use
        host_command_gateway routes and still require host authority plus replay admission.

        Model router tool:
        \(modelRouterTool.name)

        Mounted workflows:
        \(workflows)

        Runtime metadata endpoints:
        \(metadata)
        """
    }
}

public struct SMLWorkflowRuntimeWorkflowAgentGuide: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let entrypoint: String
    public let apiBasePath: String
    public let replGrammar: String
    public let schemaSummary: String
    public let graphSummary: String
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelTool: SMLWorkflowModelToolDescriptor
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        entrypoint: String,
        apiBasePath: String,
        replGrammar: String,
        schemaSummary: String,
        graphSummary: String,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelTool: SMLWorkflowModelToolDescriptor,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.entrypoint = entrypoint
        self.apiBasePath = apiBasePath
        self.replGrammar = replGrammar
        self.schemaSummary = schemaSummary
        self.graphSummary = graphSummary
        self.apiRoutes = apiRoutes.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.operationID < $1.operationID
        }
        self.modelTool = modelTool
        self.modelRouterToolName = modelRouterToolName
        self.onyxDriverID = onyxDriverID
        self.planningToolIndex = planningToolIndex.sorted {
            if $0.instructionID != $1.instructionID { return $0.instructionID < $1.instructionID }
            return $0.reference < $1.reference
        }
        self.decomposableUnits = decomposableUnits.sorted {
            $0.instructionID < $1.instructionID
        }
        self.approvalGates = approvalGates.sorted {
            $0.instructionID < $1.instructionID
        }
    }

    public init(
        descriptor: SMLWorkflowRuntimeDescriptor,
        mount: SMLWorkflowRuntimeWorkflowMount?,
        planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    ) {
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            workflowName: descriptor.workflowName,
            role: descriptor.role,
            sourceKind: descriptor.sourceKind,
            sourceReference: descriptor.sourceReference,
            sourceDigest: descriptor.sourceDigest,
            entrypoint: descriptor.onyx.plan.entrypoint,
            apiBasePath: descriptor.api.basePath,
            replGrammar: descriptor.repl.grammar,
            schemaSummary: descriptor.schemaSummary,
            graphSummary: descriptor.graphSummary,
            apiRoutes: mount?.apiRoutes ?? [],
            modelTool: descriptor.model.tool,
            modelRouterToolName: mount?.modelRouterToolName ?? SMLWorkflowRuntimeModelAdapter.toolName,
            onyxDriverID: descriptor.onyx.driverID,
            planningToolIndex: planningToolIndex,
            decomposableUnits: decomposableUnits,
            approvalGates: approvalGates
        )
    }

    var promptSection: String {
        let routes = apiRoutes.isEmpty
            ? "none"
            : apiRoutes.map {
                "\($0.method.rawValue) \($0.pathTemplate) [\($0.authority.rawValue)] -> \($0.operationID)"
            }.joined(separator: "\n")
        let planningUnits = planningToolIndex.isEmpty
            ? "none"
            : planningToolIndex.map {
                "\($0.instructionID):\($0.operation.rawValue) ref:\($0.reference) unit:\($0.unitKind?.rawValue ?? "unknown")"
            }.joined(separator: "\n")
        let decomposable = decomposableUnits.isEmpty
            ? "none"
            : decomposableUnits.map {
                "\($0.instructionID):\($0.unitKind.rawValue) successors:\($0.successors.joined(separator: ","))"
            }.joined(separator: "\n")
        let approvals = approvalGates.isEmpty
            ? "none"
            : approvalGates.map {
                "\($0.instructionID) successors:\($0.successors.joined(separator: ","))"
            }.joined(separator: "\n")
        return """
        \(workflowID)@\(workflowVersion) — \(workflowName)
        role: \(role)
        source: \(sourceKind.rawValue) \(sourceReference)
        entrypoint: \(entrypoint)
        api base path: \(apiBasePath)
        model tool: \(modelTool.name) via \(modelRouterToolName)
        onyx driver: \(onyxDriverID)

        \(schemaSummary)

        Workflow graph:
        \(graphSummary)

        Allowed REPL grammar:
        \(replGrammar)

        API routes:
        \(routes)

        Planning units:
        \(planningUnits)

        Decomposable units:
        \(decomposable)

        Approval gates:
        \(approvals)
        """
    }
}

public extension SMLWorkflowRuntimeCatalog {
    var agentGuide: SMLWorkflowRuntimeAgentGuide {
        SMLWorkflowRuntimeAgentGuide(catalog: self)
    }
}

public extension SMLWorkflowRuntimeExport {
    var agentGuide: SMLWorkflowRuntimeAgentGuide {
        catalog.agentGuide
    }
}
