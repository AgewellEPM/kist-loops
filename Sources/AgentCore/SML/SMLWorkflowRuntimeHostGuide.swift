import Foundation

public enum SMLWorkflowRuntimeHostBindingChannel: String, Sendable, Codable, Equatable {
    case customREPL = "custom_repl"
    case customAPI = "custom_api"
    case modelTool = "model_tool"
    case modelRouter = "model_router"
    case onyxDriver = "onyx_driver"
    case planningWorkflow = "planning_workflow"
    case agentGuide = "agent_guide"
}

public struct SMLWorkflowRuntimeModelToolCallExample: Sendable, Codable, Equatable {
    public let toolName: String
    public let workflowID: String?
    public let line: String
    public let arguments: SMLObject
    public let summary: String

    public init(
        toolName: String,
        workflowID: String? = nil,
        line: String,
        summary: String
    ) {
        var arguments: SMLObject = ["line": .string(line)]
        if let workflowID {
            arguments["workflow_id"] = .string(workflowID)
        }
        self.init(
            toolName: toolName,
            workflowID: workflowID,
            line: line,
            arguments: arguments,
            summary: summary
        )
    }

    public init(
        toolName: String,
        workflowID: String?,
        line: String,
        arguments: SMLObject,
        summary: String
    ) {
        self.toolName = toolName
        self.workflowID = workflowID
        self.line = line
        self.arguments = arguments
        self.summary = summary
    }
}

public struct SMLWorkflowRuntimeHostBinding: Sendable, Codable, Equatable {
    public let channel: SMLWorkflowRuntimeHostBindingChannel
    public let reference: String
    public let authority: SMLWorkflowRuntimeRouteAuthority
    public let readOnly: Bool
    public let summary: String
    public let pathTemplates: [String]
    public let toolName: String?
    public let driverID: String?
    public let planningWorkflowID: String?
    public let replExamples: [SMLWorkflowREPLExample]
    public let apiExamples: [SMLWorkflowAPIRequestExample]
    public let modelToolExamples: [SMLWorkflowRuntimeModelToolCallExample]

    public init(
        channel: SMLWorkflowRuntimeHostBindingChannel,
        reference: String,
        authority: SMLWorkflowRuntimeRouteAuthority,
        readOnly: Bool,
        summary: String,
        pathTemplates: [String] = [],
        toolName: String? = nil,
        driverID: String? = nil,
        planningWorkflowID: String? = nil,
        replExamples: [SMLWorkflowREPLExample] = [],
        apiExamples: [SMLWorkflowAPIRequestExample] = [],
        modelToolExamples: [SMLWorkflowRuntimeModelToolCallExample] = []
    ) {
        self.channel = channel
        self.reference = reference
        self.authority = authority
        self.readOnly = readOnly
        self.summary = summary
        self.pathTemplates = pathTemplates.sorted()
        self.toolName = toolName
        self.driverID = driverID
        self.planningWorkflowID = planningWorkflowID
        self.replExamples = replExamples.sorted {
            if $0.verb != $1.verb { return $0.verb < $1.verb }
            return $0.line < $1.line
        }
        self.apiExamples = apiExamples.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.method.rawValue != $1.method.rawValue {
                return $0.method.rawValue < $1.method.rawValue
            }
            return $0.summary < $1.summary
        }
        self.modelToolExamples = modelToolExamples.sorted {
            if ($0.workflowID ?? "") != ($1.workflowID ?? "") {
                return ($0.workflowID ?? "") < ($1.workflowID ?? "")
            }
            if $0.line != $1.line { return $0.line < $1.line }
            if $0.toolName != $1.toolName { return $0.toolName < $1.toolName }
            return $0.summary < $1.summary
        }
    }

    enum CodingKeys: String, CodingKey {
        case channel
        case reference
        case authority
        case readOnly
        case summary
        case pathTemplates
        case toolName
        case driverID
        case planningWorkflowID
        case replExamples
        case apiExamples
        case modelToolExamples
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            channel: try container.decode(SMLWorkflowRuntimeHostBindingChannel.self, forKey: .channel),
            reference: try container.decode(String.self, forKey: .reference),
            authority: try container.decode(
                SMLWorkflowRuntimeRouteAuthority.self,
                forKey: .authority
            ),
            readOnly: try container.decode(Bool.self, forKey: .readOnly),
            summary: try container.decode(String.self, forKey: .summary),
            pathTemplates: try container.decodeIfPresent(
                [String].self,
                forKey: .pathTemplates
            ) ?? [],
            toolName: try container.decodeIfPresent(String.self, forKey: .toolName),
            driverID: try container.decodeIfPresent(String.self, forKey: .driverID),
            planningWorkflowID: try container.decodeIfPresent(
                String.self,
                forKey: .planningWorkflowID
            ),
            replExamples: try container.decodeIfPresent(
                [SMLWorkflowREPLExample].self,
                forKey: .replExamples
            ) ?? [],
            apiExamples: try container.decodeIfPresent(
                [SMLWorkflowAPIRequestExample].self,
                forKey: .apiExamples
            ) ?? [],
            modelToolExamples: try container.decodeIfPresent(
                [SMLWorkflowRuntimeModelToolCallExample].self,
                forKey: .modelToolExamples
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(channel, forKey: .channel)
        try container.encode(reference, forKey: .reference)
        try container.encode(authority, forKey: .authority)
        try container.encode(readOnly, forKey: .readOnly)
        try container.encode(summary, forKey: .summary)
        try container.encode(pathTemplates, forKey: .pathTemplates)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(driverID, forKey: .driverID)
        try container.encodeIfPresent(planningWorkflowID, forKey: .planningWorkflowID)
        try container.encode(replExamples, forKey: .replExamples)
        try container.encode(apiExamples, forKey: .apiExamples)
        try container.encode(modelToolExamples, forKey: .modelToolExamples)
    }
}

public struct SMLWorkflowRuntimeHostLaunchStep: Sendable, Codable, Equatable {
    public let id: String
    public let entrypoint: String
    public let authority: SMLWorkflowRuntimeRouteAuthority
    public let summary: String

    public init(
        id: String,
        entrypoint: String,
        authority: SMLWorkflowRuntimeRouteAuthority,
        summary: String
    ) {
        self.id = id
        self.entrypoint = entrypoint
        self.authority = authority
        self.summary = summary
    }
}

public struct SMLWorkflowRuntimeWorkflowHostGuide: Sendable, Codable, Equatable {
    public let workflowID: String
    public let workflowVersion: String
    public let workflowName: String
    public let role: String
    public let sourceKind: SMLWorkflowSourceKind
    public let sourceReference: String
    public let sourceDigest: String?
    public let apiBasePath: String
    public let replMount: SMLWorkflowRuntimeREPLMount
    public let apiRoutes: [SMLWorkflowRuntimeAPIMount]
    public let modelTool: SMLWorkflowModelToolDescriptor
    public let modelRouterToolName: String
    public let onyxDriverID: String
    public let planningWorkflowID: String?
    public let plannerEntrypoint: String
    public let toolReferences: [String]
    public let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
    public let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
    public let hostBindings: [SMLWorkflowRuntimeHostBinding]

    public init(
        workflowID: String,
        workflowVersion: String,
        workflowName: String,
        role: String,
        sourceKind: SMLWorkflowSourceKind,
        sourceReference: String,
        sourceDigest: String?,
        apiBasePath: String,
        replMount: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelTool: SMLWorkflowModelToolDescriptor,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        plannerEntrypoint: String,
        toolReferences: [String],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        hostBindings: [SMLWorkflowRuntimeHostBinding]
    ) {
        self.workflowID = workflowID
        self.workflowVersion = workflowVersion
        self.workflowName = workflowName
        self.role = role
        self.sourceKind = sourceKind
        self.sourceReference = sourceReference
        self.sourceDigest = sourceDigest
        self.apiBasePath = apiBasePath
        self.replMount = replMount
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
        self.planningWorkflowID = planningWorkflowID
        self.plannerEntrypoint = plannerEntrypoint
        self.toolReferences = Array(Set(toolReferences)).sorted()
        self.decomposableUnits = decomposableUnits.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.approvalGates = approvalGates.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.instructionID < $1.instructionID
        }
        self.hostBindings = hostBindings.sorted {
            if $0.channel.rawValue != $1.channel.rawValue {
                return $0.channel.rawValue < $1.channel.rawValue
            }
            return $0.reference < $1.reference
        }
    }

    public init(
        descriptor: SMLWorkflowRuntimeDescriptor,
        mount: SMLWorkflowRuntimeWorkflowMount?,
        planningWorkflow: SMLWorkflowRuntimePlanningWorkflow?,
        planningToolIndex: [SMLWorkflowRuntimePlanningToolIndexEntry],
        decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit],
        approvalGates: [SMLWorkflowRuntimePlanningApprovalGate],
        metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
    ) {
        let replMount = mount?.repl ?? SMLWorkflowRuntimeREPLMount(descriptor)
        let apiRoutes = mount?.apiRoutes ?? []
        let modelRouterToolName = mount?.modelRouterToolName ?? SMLWorkflowRuntimeModelAdapter.toolName
        let planningWorkflowID = mount?.planningWorkflowID
        let onyxDriverID = mount?.onyxDriverID ?? descriptor.onyx.driverID
        let plannerEntrypoint = planningWorkflow?.entrypoint ?? descriptor.onyx.plan.entrypoint
        self.init(
            workflowID: descriptor.workflowID,
            workflowVersion: descriptor.workflowVersion,
            workflowName: descriptor.workflowName,
            role: descriptor.role,
            sourceKind: descriptor.sourceKind,
            sourceReference: descriptor.sourceReference,
            sourceDigest: descriptor.sourceDigest,
            apiBasePath: descriptor.api.basePath,
            replMount: replMount,
            apiRoutes: apiRoutes,
            modelTool: descriptor.model.tool,
            modelRouterToolName: modelRouterToolName,
            onyxDriverID: onyxDriverID,
            planningWorkflowID: planningWorkflowID,
            plannerEntrypoint: plannerEntrypoint,
            toolReferences: planningToolIndex.map(\.reference),
            decomposableUnits: decomposableUnits,
            approvalGates: approvalGates,
            hostBindings: Self.hostBindings(
                workflowID: descriptor.workflowID,
                replMount: replMount,
                apiRoutes: apiRoutes,
                modelToolName: descriptor.model.tool.name,
                modelRouterToolName: modelRouterToolName,
                modelAllowedActions: descriptor.model.allowedActions,
                onyxDriverID: onyxDriverID,
                planningWorkflowID: planningWorkflowID,
                metadataEndpoints: metadataEndpoints
            )
        )
    }

    private static func hostBindings(
        workflowID: String,
        replMount: SMLWorkflowRuntimeREPLMount,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        modelRouterToolName: String,
        modelAllowedActions: [SMLWorkflowControlAction],
        onyxDriverID: String,
        planningWorkflowID: String?,
        metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
    ) -> [SMLWorkflowRuntimeHostBinding] {
        let metadataPathsByResource = Dictionary(
            grouping: metadataEndpoints,
            by: \.resource
        ).mapValues { endpoints in endpoints.map(\.pathTemplate).sorted() }
        let metadataExamplesByResource = Dictionary(
            grouping: metadataEndpoints,
            by: \.resource
        ).mapValues { endpoints in
            endpoints.map {
                SMLWorkflowAPIRequestExample(
                    method: $0.method,
                    path: $0.pathTemplate,
                    summary: $0.summary
                )
            }
        }
        let workflowAPIExamples = apiRoutes.flatMap(\.examples)
        let modelToolExamples = Self.modelExamples(
            toolName: modelToolName,
            workflowID: nil,
            replMount: replMount,
            allowedActions: modelAllowedActions
        )
        let modelRouterExamples = Self.modelExamples(
            toolName: modelRouterToolName,
            workflowID: workflowID,
            replMount: replMount,
            allowedActions: modelAllowedActions
        )
        return [
            SMLWorkflowRuntimeHostBinding(
                channel: .customREPL,
                reference: #"SMLWorkflowRuntimeApp.replSession(workflowID:)"#,
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Bind this workflow's generated REPL grammar to a host terminal loop.",
                replExamples: replMount.examples
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .customAPI,
                reference: "SMLWorkflowRuntimeApp.handleRuntimeAPI(_:)",
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Route generated HTTP/API endpoints through the shared runtime dispatcher.",
                pathTemplates: apiRoutes.map(\.pathTemplate),
                apiExamples: workflowAPIExamples
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .modelTool,
                reference: modelToolName,
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Expose this workflow-local command proposal tool only behind host admission.",
                toolName: modelToolName,
                modelToolExamples: modelToolExamples
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .modelRouter,
                reference: modelRouterToolName,
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Expose one model-facing router that selects workflow_id plus one REPL line.",
                toolName: modelRouterToolName,
                modelToolExamples: modelRouterExamples
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .onyxDriver,
                reference: onyxDriverID,
                authority: .descriptorOnly,
                readOnly: true,
                summary: "Load the provider-neutral Onyx driver descriptor; side effects still cross the gateway.",
                pathTemplates: metadataPathsByResource[.onyxDrivers] ?? [],
                driverID: onyxDriverID,
                apiExamples: metadataExamplesByResource[.onyxDrivers] ?? []
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .planningWorkflow,
                reference: planningWorkflowID ?? workflowID,
                authority: .descriptorOnly,
                readOnly: true,
                summary: "Load the planning graph, tool index, decomposition units, and approval gates.",
                pathTemplates: metadataPathsByResource[.planning] ?? [],
                planningWorkflowID: planningWorkflowID,
                apiExamples: metadataExamplesByResource[.planning] ?? []
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .agentGuide,
                reference: SMLWorkflowRuntimeMetadataResource.agentGuide.rawValue,
                authority: .descriptorOnly,
                readOnly: true,
                summary: "Give the model/operator the canonical operating guide before routing commands.",
                pathTemplates: metadataPathsByResource[.agentGuide] ?? [],
                apiExamples: metadataExamplesByResource[.agentGuide] ?? []
            ),
        ]
    }

    private static func modelExamples(
        toolName: String,
        workflowID: String?,
        replMount: SMLWorkflowRuntimeREPLMount,
        allowedActions: [SMLWorkflowControlAction]
    ) -> [SMLWorkflowRuntimeModelToolCallExample] {
        let allowed = Set(allowedActions)
        let verbs = Set(replMount.commands.compactMap { command -> String? in
            guard command.kind == .runtime,
                  let action = command.action,
                  allowed.contains(action) else { return nil }
            return command.verb
        })
        return replMount.examples
            .filter { verbs.contains($0.verb) }
            .map {
                SMLWorkflowRuntimeModelToolCallExample(
                    toolName: toolName,
                    workflowID: workflowID,
                    line: $0.line,
                    summary: $0.summary
                )
            }
    }
}

/// Descriptor-only host wiring guide for a generated SML workflow runtime.
///
/// A host can use this one value as its installation checklist for the full source workflow bridge:
/// source package decode, fresh admission, custom REPL/API routing, model router attachment, Onyx
/// driver loading, and planning graph exposure. It carries no actor, lease, credential, runtime
/// handle, provider registry, executable closure, or replay authority.
public struct SMLWorkflowRuntimeHostGuide: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 5

    public let schemaVersion: Int
    public let requiredHostServices: [String]
    public let launchSteps: [SMLWorkflowRuntimeHostLaunchStep]
    public let metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
    public let modelRouterTool: SMLWorkflowModelToolDescriptor
    public let workflowBindings: [SMLWorkflowRuntimeWorkflowHostGuide]

    public init(catalog: SMLWorkflowRuntimeCatalog) {
        let mountContract = catalog.mountContract
        let mountsByWorkflowID = Dictionary(
            uniqueKeysWithValues: mountContract.workflowMounts.map { ($0.workflowID, $0) }
        )
        let planning = catalog.planningManifest
        let planningByWorkflowID = Dictionary(
            uniqueKeysWithValues: planning.workflows.map { ($0.workflowID, $0) }
        )
        let toolsByWorkflowID = Dictionary(grouping: planning.toolIndex, by: \.workflowID)
        let decomposableByWorkflowID = Dictionary(grouping: planning.decomposableUnits, by: \.workflowID)
        let approvalsByWorkflowID = Dictionary(grouping: planning.approvalGates, by: \.workflowID)
        let metadataEndpoints = catalog.metadataEndpoints
        self.schemaVersion = Self.currentSchemaVersion
        self.requiredHostServices = [
            "bounded_source_decoder",
            "fresh_admission_catalog",
            "sml_runtime_store",
            "sml_command_replay_guard",
            "authority_resolver",
            "host_command_gateway",
            "provider_registry_for_model_router",
            "transport_router_for_repl_and_api",
        ]
        self.launchSteps = Self.launchSteps
        self.metadataEndpoints = metadataEndpoints.sorted {
            if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
            return $0.operationID < $1.operationID
        }
        self.modelRouterTool = catalog.modelRouter.tool
        self.workflowBindings = catalog.workflows.map { descriptor in
            SMLWorkflowRuntimeWorkflowHostGuide(
                descriptor: descriptor,
                mount: mountsByWorkflowID[descriptor.workflowID],
                planningWorkflow: planningByWorkflowID[descriptor.workflowID],
                planningToolIndex: toolsByWorkflowID[descriptor.workflowID] ?? [],
                decomposableUnits: decomposableByWorkflowID[descriptor.workflowID] ?? [],
                approvalGates: approvalsByWorkflowID[descriptor.workflowID] ?? [],
                metadataEndpoints: metadataEndpoints
            )
        }.sorted {
            if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
            return $0.workflowVersion < $1.workflowVersion
        }
    }

    public var hostBindingCount: Int {
        workflowBindings.reduce(0) { $0 + $1.hostBindings.count }
    }

    private static let launchSteps: [SMLWorkflowRuntimeHostLaunchStep] = [
        SMLWorkflowRuntimeHostLaunchStep(
            id: "decode_source_package",
            entrypoint: "SMLWorkflowSourceImporter.runtimePackage(from:)",
            authority: .descriptorOnly,
            summary: "Decode or build the portable source package without executing raw workflow code."
        ),
        SMLWorkflowRuntimeHostLaunchStep(
            id: "fresh_host_admission",
            entrypoint: "SMLWorkflowRuntimeRegistry.compile(package:admissionCatalog:actor:)",
            authority: .hostCommandGateway,
            summary: "Re-admit packaged workflows against the host's current capability catalog."
        ),
        SMLWorkflowRuntimeHostLaunchStep(
            id: "launch_runtime_app",
            entrypoint: "SMLWorkflowRuntimeApp.launch(package:admissionCatalog:actor:runtime:replayGuard:authorityResolver:)",
            authority: .hostCommandGateway,
            summary: "Install workflows, bind replay protection, and build the custom runtime app facade."
        ),
        SMLWorkflowRuntimeHostLaunchStep(
            id: "serve_descriptor_metadata",
            entrypoint: "SMLWorkflowRuntimeAPI.handleMetadata(_:)",
            authority: .descriptorOnly,
            summary: "Serve catalog, mount, OpenAPI, planning, agent, host, model-router, and Onyx metadata."
        ),
        SMLWorkflowRuntimeHostLaunchStep(
            id: "route_repl_and_api",
            entrypoint: "SMLWorkflowRuntimeApp.replSession(workflowID:) + handleRuntimeAPI(_:)",
            authority: .hostCommandGateway,
            summary: "Route human REPL lines and HTTP/API requests through the same generated compilers."
        ),
        SMLWorkflowRuntimeHostLaunchStep(
            id: "attach_model_router",
            entrypoint: "SMLWorkflowRuntimeApp.modelRouterSession(binding:providers:)",
            authority: .hostCommandGateway,
            summary: "Give the model only the router tool and guides; it proposes workflow_id plus one REPL line."
        ),
        SMLWorkflowRuntimeHostLaunchStep(
            id: "attach_onyx_and_planning",
            entrypoint: "SMLWorkflowRuntimePlanningManifest + SMLOnyxDriverManifest",
            authority: .descriptorOnly,
            summary: "Load skill trees, tools, decomposable units, and approval gates as planning descriptors."
        ),
    ]
}

public extension SMLWorkflowRuntimeCatalog {
    var hostGuide: SMLWorkflowRuntimeHostGuide {
        SMLWorkflowRuntimeHostGuide(catalog: self)
    }
}
