import Foundation
import AgentCore

extension KistRunner {
    enum SMLRuntimeHostExportSourceFormat: String, Sendable, Codable, Equatable {
        case runtimeSourcePackage = "runtime_source_package"
        case runtimeScaffold = "runtime_scaffold"
        case runtimeSourceSet = "runtime_source_set"
        case langGraphManifest = "langgraph_manifest"
        case smlWorkflowJSON = "sml_workflow_json"
    }

    struct SMLRuntimeHostSourceSetEntry: Sendable, Codable, Equatable {
        let path: String
        let role: String?
        let apiBasePath: String?
        let apiWorkflowPath: String?
        let modelMaximumCommandRounds: Int?

        init(
            path: String,
            role: String? = nil,
            apiBasePath: String? = nil,
            apiWorkflowPath: String? = nil,
            modelMaximumCommandRounds: Int? = nil
        ) {
            self.path = path
            self.role = role
            self.apiBasePath = apiBasePath
            self.apiWorkflowPath = apiWorkflowPath
            self.modelMaximumCommandRounds = modelMaximumCommandRounds
        }
    }

    struct SMLRuntimeHostSourceSet: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1
        static let kind = "sml_runtime_source_set"

        let schemaVersion: Int
        let kind: String
        let sources: [SMLRuntimeHostSourceSetEntry]

        init(
            schemaVersion: Int = SMLRuntimeHostSourceSet.currentSchemaVersion,
            kind: String = SMLRuntimeHostSourceSet.kind,
            sources: [SMLRuntimeHostSourceSetEntry]
        ) {
            self.schemaVersion = schemaVersion
            self.kind = kind
            self.sources = sources
        }
    }

    struct SMLRuntimeHostExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 11

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let hostWiring: SMLWorkflowRuntimeHostWiring
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            runtimePackage: SMLWorkflowRuntimeSourcePackage,
            hostWiring: SMLWorkflowRuntimeHostWiring,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.runtimePackage = runtimePackage
            self.hostWiring = hostWiring
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostLaunchDescriptor: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let launchEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostLaunchDescriptor.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            launchEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.launchEndpoint = launchEndpoint
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostOpenAPIExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let openAPIEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let openAPI: SMLObject
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostOpenAPIExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            openAPIEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            openAPI: SMLObject,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.openAPIEndpoint = openAPIEndpoint
            self.openAPI = openAPI
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostModelRouterExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let modelRouterEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostModelRouterExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            modelRouterEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            modelRouter: SMLWorkflowRuntimeModelRouterDescriptor,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.modelRouterEndpoint = modelRouterEndpoint
            self.modelRouter = modelRouter
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostOnyxDrivers: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String?
        let availableWorkflowIDs: [String]
        let apiBasePaths: [String]
        let onyxDriversEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let onyxDrivers: [SMLOnyxDriverManifest]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostOnyxDrivers.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String?,
            availableWorkflowIDs: [String],
            apiBasePaths: [String],
            onyxDriversEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            onyxDrivers: [SMLOnyxDriverManifest],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs.sorted()
            self.apiBasePaths = apiBasePaths.sorted()
            self.onyxDriversEndpoint = onyxDriversEndpoint
            self.onyxDrivers = onyxDrivers.sorted {
                if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
                return $0.workflowVersion < $1.workflowVersion
            }
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostPlanningExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let planningEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let planning: SMLWorkflowRuntimePlanningManifest
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostPlanningExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            planningEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            planning: SMLWorkflowRuntimePlanningManifest,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.planningEndpoint = planningEndpoint
            self.planning = planning
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostCatalogExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let catalogEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let catalog: SMLWorkflowRuntimeCatalog
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostCatalogExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            catalogEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            catalog: SMLWorkflowRuntimeCatalog,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.catalogEndpoint = catalogEndpoint
            self.catalog = catalog
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostMountExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let mountEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let mountContract: SMLWorkflowRuntimeMountContract
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostMountExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            mountEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            mountContract: SMLWorkflowRuntimeMountContract,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.mountEndpoint = mountEndpoint
            self.mountContract = mountContract
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostAgentGuideExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let agentGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let agentGuide: SMLWorkflowRuntimeAgentGuide
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAgentGuideExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            agentGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            agentGuide: SMLWorkflowRuntimeAgentGuide,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.agentGuideEndpoint = agentGuideEndpoint
            self.agentGuide = agentGuide
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostGuideExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let hostGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let hostGuide: SMLWorkflowRuntimeHostGuide
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostGuideExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            hostGuideEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            hostGuide: SMLWorkflowRuntimeHostGuide,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.hostGuideEndpoint = hostGuideEndpoint
            self.hostGuide = hostGuide
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostWiringExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let apiBasePaths: [String]
        let hostWiringEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let hostWiring: SMLWorkflowRuntimeHostWiring
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostWiringExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            apiBasePaths: [String],
            hostWiringEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            hostWiring: SMLWorkflowRuntimeHostWiring,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.apiBasePaths = apiBasePaths.sorted()
            self.hostWiringEndpoint = hostWiringEndpoint
            self.hostWiring = hostWiring
            self.launchDescriptor = launchDescriptor
        }
    }

    enum SMLRuntimeHostExportError: Error, CustomStringConvertible {
        case missingSourcePath
        case missingOutputDirectory
        case missingREPLLine
        case missingREPLScriptPath
        case emptyREPLScript(path: String)
        case readREPLScriptFailed(path: String, reason: String)
        case missingAPIPath
        case missingAPIScriptPath
        case emptyAPIScript(path: String)
        case invalidAPIScript(path: String, reason: String)
        case readAPIScriptFailed(path: String, reason: String)
        case missingModelPrompt
        case missingModelScriptPath
        case emptyModelScript(path: String)
        case readModelScriptFailed(path: String, reason: String)
        case invalidJSONObject(flag: String, reason: String)
        case invalidSourceSet(path: String, reason: String)
        case invalidAPIWorkflowPathOverride(workflowID: String, path: String)
        case duplicateAPIWorkflowPathOverride(String)
        case unknownAPIWorkflowPathOverride(requested: String, available: [String])
        case invalidScaffold(path: String, reason: String)
        case readFailed(path: String, reason: String)
        case unsupportedSource(path: String, diagnostics: [String])
        case noREPLWorkflows
        case ambiguousREPLWorkflow([String])
        case unknownREPLWorkflow(requested: String, available: [String])
        case outputDirectoryNotAllowed(String)
        case outputDirectoryIsFile(String)
        case outputDirectoryNotEmpty(String)
        case writeFailed(path: String, reason: String)

        var description: String {
            switch self {
            case .missingSourcePath:
                return "--sml-runtime-export/--sml-runtime-launch/--sml-runtime-openapi/--sml-runtime-model-router/--sml-runtime-onyx/--sml-runtime-planning/--sml-runtime-catalog/--sml-runtime-mount/--sml-runtime-agent-guide/--sml-runtime-host-guide/--sml-runtime-host-wiring/--sml-runtime-runbook/--sml-runtime-scaffold/--sml-runtime-attachments/--sml-runtime-repl/--sml-runtime-repl-script/--sml-runtime-api/--sml-runtime-api-script/--sml-runtime-model/--sml-runtime-model-script requires <source.json>"
            case .missingOutputDirectory:
                return "--sml-runtime-scaffold requires --sml-out <dir>"
            case .missingREPLLine:
                return "--sml-runtime-repl requires --sml-line <line>"
            case .missingREPLScriptPath:
                return "--sml-runtime-repl-script requires --sml-script <path>"
            case .emptyREPLScript(let path):
                return "--sml-script contains no runnable REPL lines: \(path)"
            case .readREPLScriptFailed(let path, let reason):
                return "could not read SML runtime REPL script '\(path)': \(reason)"
            case .missingAPIPath:
                return "--sml-runtime-api requires --sml-path <path>"
            case .missingAPIScriptPath:
                return "--sml-runtime-api-script requires --sml-api-script <path>"
            case .emptyAPIScript(let path):
                return "--sml-api-script contains no API requests: \(path)"
            case .invalidAPIScript(let path, let reason):
                return "invalid SML runtime API script '\(path)': \(reason)"
            case .readAPIScriptFailed(let path, let reason):
                return "could not read SML runtime API script '\(path)': \(reason)"
            case .missingModelPrompt:
                return "--sml-runtime-model requires --sml-prompt <text> or a positional prompt"
            case .missingModelScriptPath:
                return "--sml-runtime-model-script requires --sml-model-script <path>"
            case .emptyModelScript(let path):
                return "--sml-model-script contains no runnable prompts: \(path)"
            case .readModelScriptFailed(let path, let reason):
                return "could not read SML runtime model script '\(path)': \(reason)"
            case .invalidJSONObject(let flag, let reason):
                return "\(flag) must be a valid SML JSON object: \(reason)"
            case .invalidSourceSet(let path, let reason):
                return "invalid SML runtime source set '\(path)': \(reason)"
            case .invalidAPIWorkflowPathOverride(let workflowID, let path):
                return "--sml-api-workflow-path for workflow '\(workflowID)' must be an absolute literal path, got '\(path)'"
            case .duplicateAPIWorkflowPathOverride(let workflowID):
                return "--sml-api-workflow-path repeats workflow id '\(workflowID)'"
            case .unknownAPIWorkflowPathOverride(let requested, let available):
                return "unknown --sml-api-workflow-path workflow id '\(requested)'. Available workflows: \(available.joined(separator: ", "))"
            case .invalidScaffold(let path, let reason):
                return "invalid SML runtime scaffold '\(path)': \(reason)"
            case .readFailed(let path, let reason):
                return "could not read SML runtime source '\(path)': \(reason)"
            case .unsupportedSource(let path, let diagnostics):
                return """
                unsupported SML runtime source '\(path)'. Expected a runtime source package, runtime scaffold, runtime source set, LangGraph manifest, or SML workflow JSON.
                \(diagnostics.map { "  - \($0)" }.joined(separator: "\n"))
                """
            case .noREPLWorkflows:
                return "SML runtime source contains no workflow REPL mounts"
            case .ambiguousREPLWorkflow(let workflows):
                return "--sml-workflow is required because the runtime source contains multiple workflows: \(workflows.joined(separator: ", "))"
            case .unknownREPLWorkflow(let requested, let available):
                return "unknown --sml-workflow '\(requested)'. Available workflows: \(available.joined(separator: ", "))"
            case .outputDirectoryNotAllowed(let path):
                return "--sml-out refuses broad output directory: \(path)"
            case .outputDirectoryIsFile(let path):
                return "--sml-out path exists and is not a directory: \(path)"
            case .outputDirectoryNotEmpty(let path):
                return "--sml-out refuses to overwrite non-empty directory: \(path)"
            case .writeFailed(let path, let reason):
                return "could not write SML runtime scaffold file '\(path)': \(reason)"
            }
        }
    }

}
