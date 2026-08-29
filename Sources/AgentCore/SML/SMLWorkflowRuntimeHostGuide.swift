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

    public init(
        channel: SMLWorkflowRuntimeHostBindingChannel,
        reference: String,
        authority: SMLWorkflowRuntimeRouteAuthority,
        readOnly: Bool,
        summary: String,
        pathTemplates: [String] = [],
        toolName: String? = nil,
        driverID: String? = nil,
        planningWorkflowID: String? = nil
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
                apiRoutes: apiRoutes,
                modelToolName: descriptor.model.tool.name,
                modelRouterToolName: modelRouterToolName,
                onyxDriverID: onyxDriverID,
                planningWorkflowID: planningWorkflowID,
                metadataEndpoints: metadataEndpoints
            )
        )
    }

    private static func hostBindings(
        workflowID: String,
        apiRoutes: [SMLWorkflowRuntimeAPIMount],
        modelToolName: String,
        modelRouterToolName: String,
        onyxDriverID: String,
        planningWorkflowID: String?,
        metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
    ) -> [SMLWorkflowRuntimeHostBinding] {
        let metadataPathsByResource = Dictionary(
            grouping: metadataEndpoints,
            by: \.resource
        ).mapValues { endpoints in endpoints.map(\.pathTemplate).sorted() }
        return [
            SMLWorkflowRuntimeHostBinding(
                channel: .customREPL,
                reference: #"SMLWorkflowRuntimeApp.replSession(workflowID:)"#,
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Bind this workflow's generated REPL grammar to a host terminal loop."
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .customAPI,
                reference: "SMLWorkflowRuntimeApp.handleRuntimeAPI(_:)",
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Route generated HTTP/API endpoints through the shared runtime dispatcher.",
                pathTemplates: apiRoutes.map(\.pathTemplate)
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .modelTool,
                reference: modelToolName,
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Expose this workflow-local command proposal tool only behind host admission.",
                toolName: modelToolName
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .modelRouter,
                reference: modelRouterToolName,
                authority: .hostCommandGateway,
                readOnly: false,
                summary: "Expose one model-facing router that selects workflow_id plus one REPL line.",
                toolName: modelRouterToolName
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .onyxDriver,
                reference: onyxDriverID,
                authority: .descriptorOnly,
                readOnly: true,
                summary: "Load the provider-neutral Onyx driver descriptor; side effects still cross the gateway.",
                pathTemplates: metadataPathsByResource[.onyxDrivers] ?? [],
                driverID: onyxDriverID
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .planningWorkflow,
                reference: planningWorkflowID ?? workflowID,
                authority: .descriptorOnly,
                readOnly: true,
                summary: "Load the planning graph, tool index, decomposition units, and approval gates.",
                pathTemplates: metadataPathsByResource[.planning] ?? [],
                planningWorkflowID: planningWorkflowID
            ),
            SMLWorkflowRuntimeHostBinding(
                channel: .agentGuide,
                reference: SMLWorkflowRuntimeMetadataResource.agentGuide.rawValue,
                authority: .descriptorOnly,
                readOnly: true,
                summary: "Give the model/operator the canonical operating guide before routing commands.",
                pathTemplates: metadataPathsByResource[.agentGuide] ?? []
            ),
        ]
    }
}

/// Descriptor-only host wiring guide for a generated SML workflow runtime.
///
/// A host can use this one value as its installation checklist for the full source workflow bridge:
/// source package decode, fresh admission, custom REPL/API routing, model router attachment, Onyx
/// driver loading, and planning graph exposure. It carries no actor, lease, credential, runtime
/// handle, provider registry, executable closure, or replay authority.
public struct SMLWorkflowRuntimeHostGuide: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 3

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
