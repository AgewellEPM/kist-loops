import Foundation

/// Descriptor-only operating guide for putting a model or external orchestrator over a mounted
/// workflow runtime.
///
/// The guide is generated from the same catalog/mount/planning surfaces that drive the REPL, API,
/// model router, and Onyx exports. It carries no actor, lease, credentials, runtime handle, replay
/// state, or host authority; mutations still have to cross the runtime command gateway.
public struct SMLWorkflowRuntimeAgentGuide: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 6

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
        let commandsByWorkflowID = Dictionary(grouping: planning.commandBindings, by: \.workflowID)
        let workflowGuides = catalog.workflows.map { descriptor in
            SMLWorkflowRuntimeWorkflowAgentGuide(
                descriptor: descriptor,
                mount: mountsByWorkflowID[descriptor.workflowID],
                planningToolIndex: toolsByWorkflowID[descriptor.workflowID] ?? [],
                decomposableUnits: decomposableByWorkflowID[descriptor.workflowID] ?? [],
                approvalGates: approvalsByWorkflowID[descriptor.workflowID] ?? [],
                commandBindings: commandsByWorkflowID[descriptor.workflowID] ?? []
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
    public let replCommands: [SMLWorkflowREPLCommandDescriptor]
    public let replExamples: [SMLWorkflowREPLExample]
    public let schemaSummary: String
    public let graphSummary: String
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelTool: SMLWorkflowModelToolDescriptor
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]

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
        replCommands: [SMLWorkflowREPLCommandDescriptor] = [],
        replExamples: [SMLWorkflowREPLExample] = [],
        schemaSummary: String,
        graphSummary: String,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelTool: SMLWorkflowModelToolDescriptor,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding] = []
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
        self.replCommands = replCommands.sorted {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.verb < $1.verb
        }
        self.replExamples = replExamples.sorted {
            if $0.verb != $1.verb { return $0.verb < $1.verb }
            return $0.line < $1.line
        }
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
        self.commandBindings = Self.sortedCommandBindings(commandBindings)
    }

    public init(
        descriptor: SMLWorkflowRuntimeDescriptor,
        mount: SMLWorkflowRuntimeWorkflowMount?,
        planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        commandBindings: [SMLWorkflowRuntimePlanningCommandBinding]
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
            replCommands: descriptor.repl.commands,
            replExamples: descriptor.repl.examples,
            schemaSummary: descriptor.schemaSummary,
            graphSummary: descriptor.graphSummary,
            apiRoutes: mount?.apiRoutes ?? [],
            modelTool: descriptor.model.tool,
            modelRouterToolName: mount?.modelRouterToolName ?? SMLWorkflowRuntimeModelAdapter.toolName,
            onyxDriverID: descriptor.onyx.driverID,
            planningToolIndex: planningToolIndex,
            decomposableUnits: decomposableUnits,
            approvalGates: approvalGates,
            commandBindings: commandBindings
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
        let commandBindings = commandBindings.isEmpty
            ? "none"
            : commandBindings.map { binding in
                let model = binding.modelEligible ? "model:eligible" : "model:blocked"
                let replFields = binding.replJSONFields.map(\.name).joined(separator: ",")
                let apiFields = binding.apiBodyFields.map(\.name).joined(separator: ",")
                return [
                    "\(binding.action.rawValue):",
                    #"repl="\#(binding.replLineTemplate)""#,
                    "json:\(binding.replJSONBodyKind.rawValue)",
                    "replFields:\(replFields.isEmpty ? "none" : replFields)",
                    "api:\(binding.apiMethod.rawValue) \(binding.apiPathTemplate)",
                    "body:\(binding.apiBodyKind.rawValue)",
                    "apiFields:\(apiFields.isEmpty ? "none" : apiFields)",
                    model,
                ].joined(separator: " ")
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

        \(SMLWorkflowREPLDescriptorFormatter.commandIndex(
            commands: replCommands,
            examples: replExamples
        ))

        API routes:
        \(routes)

        Planning units:
        \(planningUnits)

        Decomposable units:
        \(decomposable)

        Approval gates:
        \(approvals)

        Command bindings:
        \(commandBindings)
        """
    }

    enum CodingKeys: String, CodingKey {
        case workflowID
        case workflowVersion
        case workflowName
        case role
        case sourceKind
        case sourceReference
        case sourceDigest
        case entrypoint
        case apiBasePath
        case replGrammar
        case replCommands
        case replExamples
        case schemaSummary
        case graphSummary
        case apiRoutes
        case modelTool
        case modelRouterToolName
        case onyxDriverID
        case planningToolIndex
        case decomposableUnits
        case approvalGates
        case commandBindings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            workflowID: try container.decode(String.self, forKey: .workflowID),
            workflowVersion: try container.decode(String.self, forKey: .workflowVersion),
            workflowName: try container.decode(String.self, forKey: .workflowName),
            role: try container.decode(String.self, forKey: .role),
            sourceKind: try container.decode(SMLWorkflowSourceKind.self, forKey: .sourceKind),
            sourceReference: try container.decode(String.self, forKey: .sourceReference),
            sourceDigest: try container.decodeIfPresent(String.self, forKey: .sourceDigest),
            entrypoint: try container.decode(String.self, forKey: .entrypoint),
            apiBasePath: try container.decode(String.self, forKey: .apiBasePath),
            replGrammar: try container.decode(String.self, forKey: .replGrammar),
            replCommands: try container.decodeIfPresent(
                [SMLWorkflowREPLCommandDescriptor].self,
                forKey: .replCommands
            ) ?? [],
            replExamples: try container.decodeIfPresent(
                [SMLWorkflowREPLExample].self,
                forKey: .replExamples
            ) ?? [],
            schemaSummary: try container.decode(String.self, forKey: .schemaSummary),
            graphSummary: try container.decode(String.self, forKey: .graphSummary),
            apiRoutes: try container.decode([SMLWorkflowRuntimeAPIMount].self, forKey: .apiRoutes),
            modelTool: try container.decode(SMLWorkflowModelToolDescriptor.self, forKey: .modelTool),
            modelRouterToolName: try container.decode(String.self, forKey: .modelRouterToolName),
            onyxDriverID: try container.decode(String.self, forKey: .onyxDriverID),
            planningToolIndex: try container.decode(
                [SMLWorkflowRuntimePlanningToolIndexEntry].self,
                forKey: .planningToolIndex
            ),
            decomposableUnits: try container.decode(
                [SMLWorkflowRuntimePlanningDecompositionUnit].self,
                forKey: .decomposableUnits
            ),
            approvalGates: try container.decode(
                [SMLWorkflowRuntimePlanningApprovalGate].self,
                forKey: .approvalGates
            ),
            commandBindings: try container.decodeIfPresent(
                [SMLWorkflowRuntimePlanningCommandBinding].self,
                forKey: .commandBindings
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workflowID, forKey: .workflowID)
        try container.encode(workflowVersion, forKey: .workflowVersion)
        try container.encode(workflowName, forKey: .workflowName)
        try container.encode(role, forKey: .role)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(sourceReference, forKey: .sourceReference)
        try container.encodeIfPresent(sourceDigest, forKey: .sourceDigest)
        try container.encode(entrypoint, forKey: .entrypoint)
        try container.encode(apiBasePath, forKey: .apiBasePath)
        try container.encode(replGrammar, forKey: .replGrammar)
        try container.encode(replCommands, forKey: .replCommands)
        try container.encode(replExamples, forKey: .replExamples)
        try container.encode(schemaSummary, forKey: .schemaSummary)
        try container.encode(graphSummary, forKey: .graphSummary)
        try container.encode(apiRoutes, forKey: .apiRoutes)
        try container.encode(modelTool, forKey: .modelTool)
        try container.encode(modelRouterToolName, forKey: .modelRouterToolName)
        try container.encode(onyxDriverID, forKey: .onyxDriverID)
        try container.encode(planningToolIndex, forKey: .planningToolIndex)
        try container.encode(decomposableUnits, forKey: .decomposableUnits)
        try container.encode(approvalGates, forKey: .approvalGates)
        try container.encode(commandBindings, forKey: .commandBindings)
    }

    private static func sortedCommandBindings(
        _ bindings: [SMLWorkflowRuntimePlanningCommandBinding]
    ) -> [SMLWorkflowRuntimePlanningCommandBinding] {
        bindings.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            if $0.action.rawValue != $1.action.rawValue {
                return $0.action.rawValue < $1.action.rawValue
            }
            return $0.replVerb < $1.replVerb
        }
    }
}

public extension SMLWorkflowRuntimeCatalog {
    var agentGuide: SMLWorkflowRuntimeAgentGuide {
        SMLWorkflowRuntimeAgentGuide(catalog: self)
    }
}
