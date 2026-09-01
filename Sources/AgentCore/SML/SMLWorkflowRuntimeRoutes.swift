import Foundation

public enum SMLWorkflowRuntimeMetadataResource: String, Sendable, Codable, Equatable, CaseIterable {
    case catalog
    case mount
    case launch
    case export
    case openAPI = "openapi"
    case planning
    case agentGuide = "agent-guide"
    case hostGuide = "host-guide"
    case hostWiring = "host-wiring"
    case attachments
    case workflowAttachment = "workflow-attachment"
    case workflowREPLMount = "workflow-repl-mount"
    case workflowAPIMount = "workflow-api-mount"
    case workflowModelTool = "workflow-model-tool"
    case workflowOnyxDriver = "workflow-onyx-driver"
    case workflowSkillTree = "workflow-skill-tree"
    case workflowToolBindings = "workflow-tool-bindings"
    case workflowPlanning = "workflow-planning"
    case modelRouter = "model-router"
    case onyxDrivers = "onyx-drivers"

    public var operationID: String {
        if self == .workflowAttachment {
            return "get_sml_runtime_workflow_attachment"
        }
        return "get_sml_runtime_" + rawValue.replacingOccurrences(of: "-", with: "_")
    }

    public var pathSuffix: String {
        switch self {
        case .workflowAttachment:
            return "attachments/{workflow_id}"
        case .workflowREPLMount:
            return "repl-mounts/{workflow_id}"
        case .workflowAPIMount:
            return "api-mounts/{workflow_id}"
        case .workflowModelTool:
            return "model-tools/{workflow_id}"
        case .workflowOnyxDriver:
            return "onyx-drivers/{workflow_id}"
        case .workflowSkillTree:
            return "skill-trees/{workflow_id}"
        case .workflowToolBindings:
            return "tool-bindings/{workflow_id}"
        case .workflowPlanning:
            return "planning/{workflow_id}"
        case .catalog, .mount, .launch, .export, .openAPI, .planning, .agentGuide,
             .hostGuide, .hostWiring, .attachments, .modelRouter, .onyxDrivers:
            return rawValue
        }
    }

    public var summary: String {
        switch self {
        case .catalog:
            return "List the mounted SML workflow runtime catalog"
        case .mount:
            return "Return the host mount contract for this SML workflow runtime"
        case .launch:
            return "Return the launch receipt for mounted SML workflow runtime adapters"
        case .export:
            return "Return the complete authority-neutral SML workflow runtime export"
        case .openAPI:
            return "Return the generated OpenAPI document for this SML workflow runtime"
        case .planning:
            return "Return the aggregate planner manifest for mounted SML workflows"
        case .agentGuide:
            return "Return the canonical model and agent operating guide for mounted SML workflows"
        case .hostGuide:
            return "Return the canonical host wiring guide for mounting SML workflow runtimes"
        case .hostWiring:
            return "Return the compact host adapter wiring map for mounted SML workflow runtimes"
        case .attachments:
            return "Return per-workflow attachment manifests for REPL/API/model/Onyx/planning adapters"
        case .workflowAttachment:
            return "Return one workflow attachment manifest for REPL/API/model/Onyx/planning adapters"
        case .workflowREPLMount:
            return "Return one workflow REPL mount descriptor for a mounted SML workflow"
        case .workflowAPIMount:
            return "Return one workflow API mount descriptor list for a mounted SML workflow"
        case .workflowModelTool:
            return "Return one workflow native model tool descriptor for a mounted SML workflow"
        case .workflowOnyxDriver:
            return "Return one provider-neutral Onyx driver manifest for a mounted SML workflow"
        case .workflowSkillTree:
            return "Return one workflow skill tree for model, Onyx, and planner adapters"
        case .workflowToolBindings:
            return "Return one workflow tool binding list for model, Onyx, and planner adapters"
        case .workflowPlanning:
            return "Return one workflow planning bundle with skill, tool, decomposition, gate, and command indexes"
        case .modelRouter:
            return "Return the native model-router tool descriptor for mounted SML workflows"
        case .onyxDrivers:
            return "Return provider-neutral Onyx driver manifests for mounted SML workflows"
        }
    }
}

public struct SMLWorkflowRuntimeMetadataEndpoint: Sendable, Codable, Equatable {
    public let method: SMLWorkflowAPIMethod
    public let pathTemplate: String
    public let operationID: String
    public let resource: SMLWorkflowRuntimeMetadataResource
    public let summary: String

    public init(
        method: SMLWorkflowAPIMethod,
        pathTemplate: String,
        operationID: String,
        resource: SMLWorkflowRuntimeMetadataResource,
        summary: String
    ) {
        self.method = method
        self.pathTemplate = pathTemplate
        self.operationID = operationID
        self.resource = resource
        self.summary = summary
    }
}

public enum SMLWorkflowRuntimeAPIRoute: Sendable, Equatable {
    case metadata(SMLWorkflowRuntimeMetadataResource)
    case workflow(workflowID: String)
}

public enum SMLWorkflowRuntimeRouteHandlerKind: String, Sendable, Codable, Equatable {
    case metadata
    case workflow
}

public enum SMLWorkflowRuntimeRouteAuthority: String, Sendable, Codable, Equatable {
    case descriptorOnly = "descriptor_only"
    case hostCommandGateway = "host_command_gateway"
}

