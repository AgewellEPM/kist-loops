import Foundation
import AgentCore

extension KistRunner {
    enum SMLRuntimeHostExportSourceFormat: String, Sendable, Codable, Equatable {
        case runtimeSourcePackage = "runtime_source_package"
        case runtimeScaffold = "runtime_scaffold"
        case langGraphManifest = "langgraph_manifest"
        case smlWorkflowJSON = "sml_workflow_json"
    }

    struct SMLRuntimeHostExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 10

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

    struct SMLRuntimeHostScaffoldFile: Sendable, Codable, Equatable {
        let relativePath: String
        let path: String
        let resource: SMLWorkflowRuntimeMetadataResource?
        let byteCount: Int
        let sha256: String
        let summary: String

        init(
            relativePath: String,
            path: String,
            resource: SMLWorkflowRuntimeMetadataResource? = nil,
            byteCount: Int,
            sha256: String,
            summary: String
        ) {
            self.relativePath = relativePath
            self.path = path
            self.resource = resource
            self.byteCount = byteCount
            self.sha256 = sha256
            self.summary = summary
        }
    }

    struct SMLRuntimeHostScaffold: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let outputDirectory: String
        let indexPath: String
        let workflowIDs: [String]
        let apiBasePaths: [String]
        let files: [SMLRuntimeHostScaffoldFile]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostScaffold.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            outputDirectory: String,
            indexPath: String = "scaffold.json",
            workflowIDs: [String],
            apiBasePaths: [String],
            files: [SMLRuntimeHostScaffoldFile],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.outputDirectory = outputDirectory
            self.indexPath = indexPath
            self.workflowIDs = workflowIDs.sorted()
            self.apiBasePaths = apiBasePaths.sorted()
            self.files = files.sorted {
                if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
                return $0.sha256 < $1.sha256
            }
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostAttachments: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 4

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String?
        let availableWorkflowIDs: [String]
        let apiBasePaths: [String]
        let attachmentEndpoint: SMLWorkflowRuntimeMetadataEndpoint?
        let attachments: [SMLWorkflowRuntimeWorkflowAttachmentManifest]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAttachments.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String?,
            availableWorkflowIDs: [String],
            apiBasePaths: [String],
            attachmentEndpoint: SMLWorkflowRuntimeMetadataEndpoint?,
            attachments: [SMLWorkflowRuntimeWorkflowAttachmentManifest],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs.sorted()
            self.apiBasePaths = apiBasePaths.sorted()
            self.attachmentEndpoint = attachmentEndpoint
            self.attachments = attachments.sorted {
                if $0.workflowID != $1.workflowID { return $0.workflowID < $1.workflowID }
                return $0.workflowVersion < $1.workflowVersion
            }
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostREPLCommand: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String
        let availableWorkflowIDs: [String]
        let line: String
        let output: String
        let shouldExit: Bool
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostREPLCommand.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String,
            availableWorkflowIDs: [String],
            line: String,
            output: String,
            shouldExit: Bool,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs
            self.line = line
            self.output = output
            self.shouldExit = shouldExit
            self.command = command
            self.result = result
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostREPLTranscriptTurn: Sendable, Codable, Equatable {
        let index: Int
        let line: String
        let output: String
        let shouldExit: Bool
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?

        init(
            index: Int,
            line: String,
            output: String,
            shouldExit: Bool,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?
        ) {
            self.index = index
            self.line = line
            self.output = output
            self.shouldExit = shouldExit
            self.command = command
            self.result = result
        }
    }

    struct SMLRuntimeHostREPLTranscript: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let workflowID: String
        let availableWorkflowIDs: [String]
        let scriptPath: String
        let requestedLineCount: Int
        let executedLineCount: Int
        let stoppedAtExit: Bool
        let turns: [SMLRuntimeHostREPLTranscriptTurn]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostREPLTranscript.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            workflowID: String,
            availableWorkflowIDs: [String],
            scriptPath: String,
            requestedLineCount: Int,
            stoppedAtExit: Bool,
            turns: [SMLRuntimeHostREPLTranscriptTurn],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.workflowID = workflowID
            self.availableWorkflowIDs = availableWorkflowIDs
            self.scriptPath = scriptPath
            self.requestedLineCount = requestedLineCount
            self.executedLineCount = turns.count
            self.stoppedAtExit = stoppedAtExit
            self.turns = turns
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostAPIExchange: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let method: SMLWorkflowAPIMethod
        let path: String
        let requestBody: SMLObject
        let statusCode: Int
        let kind: SMLWorkflowRuntimeAPIResponseKind
        let responseBody: SMLValue
        let route: SMLWorkflowRuntimeAPIMount?
        let pathParameters: [String: String]
        let metadataResource: SMLWorkflowRuntimeMetadataResource?
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAPIExchange.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            method: SMLWorkflowAPIMethod,
            path: String,
            requestBody: SMLObject,
            statusCode: Int,
            kind: SMLWorkflowRuntimeAPIResponseKind,
            responseBody: SMLValue,
            route: SMLWorkflowRuntimeAPIMount?,
            pathParameters: [String: String],
            metadataResource: SMLWorkflowRuntimeMetadataResource?,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.method = method
            self.path = path
            self.requestBody = requestBody
            self.statusCode = statusCode
            self.kind = kind
            self.responseBody = responseBody
            self.route = route
            self.pathParameters = pathParameters
            self.metadataResource = metadataResource
            self.command = command
            self.result = result
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostAPIRequestSpec: Sendable, Codable, Equatable {
        let method: SMLWorkflowAPIMethod
        let path: String
        let body: SMLObject

        init(
            method: SMLWorkflowAPIMethod,
            path: String,
            body: SMLObject = [:]
        ) {
            self.method = method
            self.path = path
            self.body = body
        }

        enum CodingKeys: String, CodingKey {
            case method
            case path
            case body
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                method: try container.decode(SMLWorkflowAPIMethod.self, forKey: .method),
                path: try container.decode(String.self, forKey: .path),
                body: try container.decodeIfPresent(SMLObject.self, forKey: .body) ?? [:]
            )
        }
    }

    struct SMLRuntimeHostAPITranscriptExchange: Sendable, Codable, Equatable {
        let index: Int
        let method: SMLWorkflowAPIMethod
        let path: String
        let requestBody: SMLObject
        let statusCode: Int
        let kind: SMLWorkflowRuntimeAPIResponseKind
        let responseBody: SMLValue
        let route: SMLWorkflowRuntimeAPIMount?
        let pathParameters: [String: String]
        let metadataResource: SMLWorkflowRuntimeMetadataResource?
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?

        init(
            index: Int,
            method: SMLWorkflowAPIMethod,
            path: String,
            requestBody: SMLObject,
            statusCode: Int,
            kind: SMLWorkflowRuntimeAPIResponseKind,
            responseBody: SMLValue,
            route: SMLWorkflowRuntimeAPIMount?,
            pathParameters: [String: String],
            metadataResource: SMLWorkflowRuntimeMetadataResource?,
            command: SMLCommandEnvelope?,
            result: SMLCommandResult?
        ) {
            self.index = index
            self.method = method
            self.path = path
            self.requestBody = requestBody
            self.statusCode = statusCode
            self.kind = kind
            self.responseBody = responseBody
            self.route = route
            self.pathParameters = pathParameters
            self.metadataResource = metadataResource
            self.command = command
            self.result = result
        }
    }

    struct SMLRuntimeHostAPITranscript: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let scriptPath: String
        let requestedRequestCount: Int
        let executedRequestCount: Int
        let exchanges: [SMLRuntimeHostAPITranscriptExchange]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostAPITranscript.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            scriptPath: String,
            requestedRequestCount: Int,
            exchanges: [SMLRuntimeHostAPITranscriptExchange],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.scriptPath = scriptPath
            self.requestedRequestCount = requestedRequestCount
            self.executedRequestCount = exchanges.count
            self.exchanges = exchanges
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostModelStep: Sendable, Codable, Equatable {
        let disposition: SMLWorkflowModelStepDisposition
        let advisoryText: String
        let toolCallID: String?
        let command: SMLCommandEnvelope?
        let result: SMLCommandResult?

        init(_ step: SMLWorkflowModelStep) {
            disposition = step.disposition
            advisoryText = step.advisoryText
            toolCallID = step.toolCallID
            command = step.command
            result = step.result
        }
    }

    struct SMLRuntimeHostModelTurn: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let prompt: String
        let providerBinding: ProviderBinding
        let maximumCommandRounds: Int
        let providerRequestLimit: Int
        let providerRequestsConsumed: Int
        let advisoryText: String
        let steps: [SMLRuntimeHostModelStep]
        let taskIDsByWorkflowID: [String: String]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostModelTurn.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            prompt: String,
            providerBinding: ProviderBinding,
            maximumCommandRounds: Int,
            providerRequestLimit: Int,
            providerRequestsConsumed: Int,
            advisoryText: String,
            steps: [SMLRuntimeHostModelStep],
            taskIDsByWorkflowID: [String: String],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.prompt = prompt
            self.providerBinding = providerBinding
            self.maximumCommandRounds = maximumCommandRounds
            self.providerRequestLimit = providerRequestLimit
            self.providerRequestsConsumed = providerRequestsConsumed
            self.advisoryText = advisoryText
            self.steps = steps
            self.taskIDsByWorkflowID = taskIDsByWorkflowID
            self.launchDescriptor = launchDescriptor
        }
    }

    struct SMLRuntimeHostModelTranscriptTurn: Sendable, Codable, Equatable {
        let index: Int
        let prompt: String
        let providerRequestsBefore: Int
        let providerRequestsAfter: Int
        let providerRequestsConsumed: Int
        let advisoryText: String
        let steps: [SMLRuntimeHostModelStep]
        let taskIDsByWorkflowID: [String: String]

        init(
            index: Int,
            prompt: String,
            providerRequestsBefore: Int,
            providerRequestsAfter: Int,
            advisoryText: String,
            steps: [SMLRuntimeHostModelStep],
            taskIDsByWorkflowID: [String: String]
        ) {
            self.index = index
            self.prompt = prompt
            self.providerRequestsBefore = providerRequestsBefore
            self.providerRequestsAfter = providerRequestsAfter
            self.providerRequestsConsumed = providerRequestsAfter - providerRequestsBefore
            self.advisoryText = advisoryText
            self.steps = steps
            self.taskIDsByWorkflowID = taskIDsByWorkflowID
        }
    }

    struct SMLRuntimeHostModelTranscript: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let scriptPath: String
        let providerBinding: ProviderBinding
        let maximumCommandRounds: Int
        let promptCount: Int
        let providerRequestLimit: Int
        let providerRequestsConsumed: Int
        let turns: [SMLRuntimeHostModelTranscriptTurn]
        let taskIDsByWorkflowID: [String: String]
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostModelTranscript.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            scriptPath: String,
            providerBinding: ProviderBinding,
            maximumCommandRounds: Int,
            promptCount: Int,
            providerRequestLimit: Int,
            providerRequestsConsumed: Int,
            turns: [SMLRuntimeHostModelTranscriptTurn],
            taskIDsByWorkflowID: [String: String],
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            self.schemaVersion = schemaVersion
            self.sourcePath = sourcePath
            self.sourceFormat = sourceFormat
            self.scriptPath = scriptPath
            self.providerBinding = providerBinding
            self.maximumCommandRounds = maximumCommandRounds
            self.promptCount = promptCount
            self.providerRequestLimit = providerRequestLimit
            self.providerRequestsConsumed = providerRequestsConsumed
            self.turns = turns
            self.taskIDsByWorkflowID = taskIDsByWorkflowID
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
                return "--sml-runtime-export/--sml-runtime-launch/--sml-runtime-openapi/--sml-runtime-model-router/--sml-runtime-onyx/--sml-runtime-planning/--sml-runtime-catalog/--sml-runtime-mount/--sml-runtime-agent-guide/--sml-runtime-host-guide/--sml-runtime-host-wiring/--sml-runtime-scaffold/--sml-runtime-attachments/--sml-runtime-repl/--sml-runtime-repl-script/--sml-runtime-api/--sml-runtime-api-script/--sml-runtime-model/--sml-runtime-model-script requires <source.json>"
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
            case .invalidScaffold(let path, let reason):
                return "invalid SML runtime scaffold '\(path)': \(reason)"
            case .readFailed(let path, let reason):
                return "could not read SML runtime source '\(path)': \(reason)"
            case .unsupportedSource(let path, let diagnostics):
                return """
                unsupported SML runtime source '\(path)'. Expected a runtime source package, runtime scaffold, LangGraph manifest, or SML workflow JSON.
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

    static func runSMLRuntimeExport(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostExport(
                sourcePath: opts.smlRuntimeExport,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeLaunch(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostLaunchDescriptor(
                sourcePath: opts.smlRuntimeLaunch,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeOpenAPI(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostOpenAPI(
                sourcePath: opts.smlRuntimeOpenAPI,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeModelRouter(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelRouter(
                sourcePath: opts.smlRuntimeModelRouter,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeOnyx(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostOnyxDrivers(
                sourcePath: opts.smlRuntimeOnyx,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimePlanning(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostPlanning(
                sourcePath: opts.smlRuntimePlanning,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeCatalog(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostCatalog(
                sourcePath: opts.smlRuntimeCatalog,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeMount(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostMount(
                sourcePath: opts.smlRuntimeMount,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAgentGuide(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAgentGuide(
                sourcePath: opts.smlRuntimeAgentGuide,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeHostGuide(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostGuide(
                sourcePath: opts.smlRuntimeHostGuide,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeHostWiring(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostWiring(
                sourcePath: opts.smlRuntimeHostWiring,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeScaffold(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostScaffold(
                sourcePath: opts.smlRuntimeScaffold,
                outputDirectory: opts.smlRuntimeOutputDirectory,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAttachments(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAttachments(
                sourcePath: opts.smlRuntimeAttachments,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeREPL(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostREPLCommand(
                sourcePath: opts.smlRuntimeREPL,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                line: opts.smlRuntimeREPLLine,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeREPLScript(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostREPLTranscript(
                sourcePath: opts.smlRuntimeREPLScript,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                scriptPath: opts.smlRuntimeREPLScriptPath,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAPI(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAPIExchange(
                sourcePath: opts.smlRuntimeAPI,
                projectRoot: opts.project,
                method: opts.smlRuntimeAPIMethod,
                path: opts.smlRuntimeAPIPath,
                bodyJSON: opts.smlRuntimeAPIBody,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAPIScript(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAPITranscript(
                sourcePath: opts.smlRuntimeAPIScript,
                projectRoot: opts.project,
                scriptPath: opts.smlRuntimeAPIScriptPath,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeModel(
        _ opts: KistOptions,
        registry: ProviderRegistry,
        providerId: String,
        model: String?,
        projectRoot: String
    ) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelTurn(
                sourcePath: opts.smlRuntimeModel,
                projectRoot: projectRoot,
                prompt: opts.smlRuntimeModelPrompt ?? opts.goal,
                binding: ProviderBinding(providerId: providerId, model: model),
                providers: registry,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeModelScript(
        _ opts: KistOptions,
        registry: ProviderRegistry,
        providerId: String,
        model: String?,
        projectRoot: String
    ) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelTranscript(
                sourcePath: opts.smlRuntimeModelScript,
                projectRoot: projectRoot,
                scriptPath: opts.smlRuntimeModelScriptPath,
                binding: ProviderBinding(providerId: providerId, model: model),
                providers: registry,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func renderSMLRuntimeHostExport(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let export = try await makeSMLRuntimeHostExport(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(export), as: UTF8.self)
    }

    static func renderSMLRuntimeHostLaunchDescriptor(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let launch = try await makeSMLRuntimeHostLaunchDescriptor(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(launch), as: UTF8.self)
    }

    static func renderSMLRuntimeHostOpenAPI(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let openAPI = try await makeSMLRuntimeHostOpenAPI(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(openAPI), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelRouter(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let modelRouter = try await makeSMLRuntimeHostModelRouter(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(modelRouter), as: UTF8.self)
    }

    static func renderSMLRuntimeHostOnyxDrivers(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let onyxDrivers = try await makeSMLRuntimeHostOnyxDrivers(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(onyxDrivers), as: UTF8.self)
    }

    static func renderSMLRuntimeHostPlanning(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let planning = try await makeSMLRuntimeHostPlanning(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(planning), as: UTF8.self)
    }

    static func renderSMLRuntimeHostCatalog(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let catalog = try await makeSMLRuntimeHostCatalog(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(catalog), as: UTF8.self)
    }

    static func renderSMLRuntimeHostMount(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let mount = try await makeSMLRuntimeHostMount(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(mount), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAgentGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let guide = try await makeSMLRuntimeHostAgentGuide(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(guide), as: UTF8.self)
    }

    static func renderSMLRuntimeHostGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let guide = try await makeSMLRuntimeHostGuide(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(guide), as: UTF8.self)
    }

    static func renderSMLRuntimeHostWiring(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let wiring = try await makeSMLRuntimeHostWiring(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(wiring), as: UTF8.self)
    }

    static func renderSMLRuntimeHostScaffold(
        sourcePath: String?,
        outputDirectory: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let scaffold = try await writeSMLRuntimeHostScaffold(
            sourcePath: sourcePath,
            outputDirectory: outputDirectory,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(scaffold), as: UTF8.self)
    }

    static func renderSMLRuntimeHostREPLCommand(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        line: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let command = try await makeSMLRuntimeHostREPLCommand(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            line: line,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(command), as: UTF8.self)
    }

    static func renderSMLRuntimeHostREPLTranscript(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostREPLTranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            scriptPath: scriptPath,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAttachments(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let attachments = try await makeSMLRuntimeHostAttachments(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(attachments), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAPIExchange(
        sourcePath: String?,
        projectRoot: String,
        method: SMLWorkflowAPIMethod = .get,
        path: String?,
        bodyJSON: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let exchange = try await makeSMLRuntimeHostAPIExchange(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            method: method,
            path: path,
            bodyJSON: bodyJSON,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(exchange), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAPITranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostAPITranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            scriptPath: scriptPath,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelTurn(
        sourcePath: String?,
        projectRoot: String,
        prompt: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let turn = try await makeSMLRuntimeHostModelTurn(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            prompt: prompt,
            binding: binding,
            providers: providers,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(turn), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelTranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostModelTranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            scriptPath: scriptPath,
            binding: binding,
            providers: providers,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func makeSMLRuntimeHostExport(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                runtimePackage: host.runtimePackage,
                hostWiring: host.runtimePackage.runtime.hostWiring,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostLaunchDescriptor(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostLaunchDescriptor {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostLaunchDescriptor(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                launchEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .launch
                },
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostOpenAPI(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostOpenAPIExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostOpenAPIExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                openAPIEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .openAPI
                },
                openAPI: host.runtimePackage.runtime.openAPI,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostModelRouter(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostModelRouterExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostModelRouterExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                modelRouterEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .modelRouter
                },
                modelRouter: host.runtimePackage.runtime.modelRouter,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostOnyxDrivers(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostOnyxDrivers {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            let selectedWorkflowID = try selectSMLRuntimeOptionalWorkflowID(
                workflowID,
                availableWorkflowIDs: launchDescriptor.workflowIDs
            )
            let drivers = host.runtimePackage.runtime.onyxDrivers.filter { driver in
                selectedWorkflowID.map { $0 == driver.workflowID } ?? true
            }
            return SMLRuntimeHostOnyxDrivers(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: launchDescriptor.workflowIDs,
                apiBasePaths: launchDescriptor.apiBasePaths,
                onyxDriversEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .onyxDrivers
                },
                onyxDrivers: drivers,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostPlanning(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostPlanningExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostPlanningExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                planningEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .planning
                },
                planning: host.runtimePackage.runtime.planning,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostCatalog(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostCatalogExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostCatalogExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                catalogEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .catalog
                },
                catalog: host.runtimePackage.runtime.catalog,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostMount(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostMountExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostMountExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                mountEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .mount
                },
                mountContract: host.runtimePackage.runtime.mountContract,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostAgentGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAgentGuideExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostAgentGuideExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                agentGuideEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .agentGuide
                },
                agentGuide: host.runtimePackage.runtime.agentGuide,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostGuideExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostGuideExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                hostGuideEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .hostGuide
                },
                hostGuide: host.runtimePackage.runtime.hostGuide,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostWiring(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostWiringExport {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            return SMLRuntimeHostWiringExport(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                apiBasePaths: launchDescriptor.apiBasePaths,
                hostWiringEndpoint: launchDescriptor.metadataEndpoints.first {
                    $0.resource == .hostWiring
                },
                hostWiring: host.runtimePackage.runtime.hostWiring,
                launchDescriptor: launchDescriptor
            )
        }
    }

    static func writeSMLRuntimeHostScaffold(
        sourcePath: String?,
        outputDirectory: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostScaffold {
        let outputURL = try smlRuntimeScaffoldOutputURL(
            outputDirectory,
            projectRoot: projectRoot
        )
        try validateSMLRuntimeScaffoldOutputDirectory(
            outputURL,
            projectRoot: projectRoot
        )
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            try prepareSMLRuntimeScaffoldOutputDirectory(
                outputURL,
                projectRoot: projectRoot
            )
            let runtime = host.runtimePackage.runtime
            let launchDescriptor = host.launch.launchDescriptor
            var files: [SMLRuntimeHostScaffoldFile] = []
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "catalog.json",
                outputDirectory: outputURL,
                resource: .catalog,
                summary: "Mounted workflow runtime catalog.",
                payload: runtime.catalog
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "mount.json",
                outputDirectory: outputURL,
                resource: .mount,
                summary: "Host mount contract for generated REPL/API/model/Onyx/planning surfaces.",
                payload: runtime.mountContract
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "launch.json",
                outputDirectory: outputURL,
                resource: .launch,
                summary: "Launch descriptor proving the wrapped source mounted cleanly.",
                payload: launchDescriptor
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "runtime-export.json",
                outputDirectory: outputURL,
                resource: .export,
                summary: "Complete descriptor-only runtime export.",
                payload: runtime
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "runtime-source-package.json",
                outputDirectory: outputURL,
                summary: "Portable source package plus generated runtime export.",
                payload: host.runtimePackage
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "openapi.json",
                outputDirectory: outputURL,
                resource: .openAPI,
                summary: "Generated OpenAPI document for custom runtime API endpoints.",
                payload: runtime.openAPI
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "model-tools.json",
                outputDirectory: outputURL,
                summary: "Per-workflow model tool descriptors.",
                payload: runtime.modelTools
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "model-router.json",
                outputDirectory: outputURL,
                resource: .modelRouter,
                summary: "Native model-router tool descriptor for selecting and driving mounted workflows.",
                payload: runtime.modelRouter
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "onyx-drivers.json",
                outputDirectory: outputURL,
                resource: .onyxDrivers,
                summary: "Generated Onyx driver manifests with skill trees, tools, and plans.",
                payload: runtime.onyxDrivers
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "planning.json",
                outputDirectory: outputURL,
                resource: .planning,
                summary: "Aggregate planning manifest with skill index, tool index, graph units, and gates.",
                payload: runtime.planning
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "agent-guide.json",
                outputDirectory: outputURL,
                resource: .agentGuide,
                summary: "Canonical model/agent operating guide.",
                payload: runtime.agentGuide
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "host-guide.json",
                outputDirectory: outputURL,
                resource: .hostGuide,
                summary: "Canonical host integration checklist.",
                payload: runtime.hostGuide
            ))
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "host-wiring.json",
                outputDirectory: outputURL,
                resource: .hostWiring,
                summary: "Compact host wiring map for dashboards, CLIs, HTTP routers, model hosts, and Onyx bridges.",
                payload: runtime.hostWiring
            ))
            let attachments = runtime.hostWiring.attachmentManifests
            files.append(try writeSMLRuntimeScaffoldJSONFile(
                relativePath: "attachments.json",
                outputDirectory: outputURL,
                resource: .attachments,
                summary: "All per-workflow attachment manifests.",
                payload: attachments
            ))
            for attachment in attachments {
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "attachments/\(smlRuntimeScaffoldSafeFileStem(attachment.workflowID)).json",
                    outputDirectory: outputURL,
                    resource: .workflowAttachment,
                    summary: "Attachment manifest for \(attachment.workflowID).",
                    payload: attachment
                ))
                files.append(try writeSMLRuntimeScaffoldJSONFile(
                    relativePath: "api-scripts/\(smlRuntimeScaffoldSafeFileStem(attachment.workflowID)).json",
                    outputDirectory: outputURL,
                    summary: "Runnable generated API request script template for \(attachment.workflowID).",
                    payload: smlRuntimeScaffoldAPIScript(for: attachment)
                ))
                files.append(try writeSMLRuntimeScaffoldTextFile(
                    relativePath: "repl-scripts/\(smlRuntimeScaffoldSafeFileStem(attachment.workflowID)).repl",
                    outputDirectory: outputURL,
                    summary: "Runnable generated REPL script template for \(attachment.workflowID).",
                    text: smlRuntimeScaffoldREPLScript(for: attachment)
                ))
                files.append(try writeSMLRuntimeScaffoldTextFile(
                    relativePath: "model-scripts/\(smlRuntimeScaffoldSafeFileStem(attachment.workflowID)).prompts",
                    outputDirectory: outputURL,
                    summary: "Runnable generated model-router prompt script template for \(attachment.workflowID).",
                    text: smlRuntimeScaffoldModelScript(for: attachment)
                ))
            }
            files.append(try writeSMLRuntimeScaffoldTextFile(
                relativePath: "README.md",
                outputDirectory: outputURL,
                summary: "Human-readable scaffold usage guide.",
                text: smlRuntimeScaffoldReadme(
                    sourcePath: host.sourcePath,
                    sourceFormat: host.sourceFormat,
                    outputDirectory: outputURL.standardizedFileURL.path,
                    launchDescriptor: launchDescriptor,
                    files: files
                )
            ))
            let scaffold = SMLRuntimeHostScaffold(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                outputDirectory: outputURL.standardizedFileURL.path,
                workflowIDs: launchDescriptor.workflowIDs,
                apiBasePaths: launchDescriptor.apiBasePaths,
                files: files,
                launchDescriptor: launchDescriptor
            )
            try writeSMLRuntimeScaffoldJSONData(
                relativePath: scaffold.indexPath,
                outputDirectory: outputURL,
                payload: scaffold
            )
            return scaffold
        }
    }

    private static func smlRuntimeScaffoldOutputURL(
        _ outputDirectory: String?,
        projectRoot: String
    ) throws -> URL {
        guard let outputDirectory else {
            throw SMLRuntimeHostExportError.missingOutputDirectory
        }
        let trimmed = outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SMLRuntimeHostExportError.missingOutputDirectory
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(trimmed, isDirectory: true)
            .standardizedFileURL
    }

    private static func validateSMLRuntimeScaffoldOutputDirectory(
        _ outputURL: URL,
        projectRoot: String
    ) throws {
        let manager = FileManager.default
        let path = normalizedDirectoryPath(outputURL)
        let projectPath = normalizedDirectoryPath(
            URL(fileURLWithPath: projectRoot, isDirectory: true).standardizedFileURL
        )
        let homePath = normalizedDirectoryPath(manager.homeDirectoryForCurrentUser.standardizedFileURL)
        guard path != "/", path != projectPath, path != homePath else {
            throw SMLRuntimeHostExportError.outputDirectoryNotAllowed(path)
        }
        if (try? manager.destinationOfSymbolicLink(atPath: path)) != nil {
            throw SMLRuntimeHostExportError.outputDirectoryNotAllowed(path)
        }
        var isDirectory = ObjCBool(false)
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw SMLRuntimeHostExportError.outputDirectoryIsFile(path)
        }
        do {
            if try !manager.contentsOfDirectory(atPath: path).isEmpty {
                throw SMLRuntimeHostExportError.outputDirectoryNotEmpty(path)
            }
        } catch let error as SMLRuntimeHostExportError {
            throw error
        } catch {
            throw SMLRuntimeHostExportError.writeFailed(
                path: path,
                reason: String(describing: error)
            )
        }
    }

    private static func prepareSMLRuntimeScaffoldOutputDirectory(
        _ outputURL: URL,
        projectRoot: String
    ) throws {
        try validateSMLRuntimeScaffoldOutputDirectory(
            outputURL,
            projectRoot: projectRoot
        )
        do {
            try FileManager.default.createDirectory(
                at: outputURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw SMLRuntimeHostExportError.writeFailed(
                path: outputURL.standardizedFileURL.path,
                reason: String(describing: error)
            )
        }
    }

    private static func normalizedDirectoryPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    @discardableResult
    private static func writeSMLRuntimeScaffoldJSONData<T: Encodable>(
        relativePath: String,
        outputDirectory: URL,
        payload: T
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try writeSMLRuntimeScaffoldData(
            data,
            relativePath: relativePath,
            outputDirectory: outputDirectory
        )
        return data
    }

    private static func writeSMLRuntimeScaffoldJSONFile<T: Encodable>(
        relativePath: String,
        outputDirectory: URL,
        resource: SMLWorkflowRuntimeMetadataResource? = nil,
        summary: String,
        payload: T
    ) throws -> SMLRuntimeHostScaffoldFile {
        let data = try writeSMLRuntimeScaffoldJSONData(
            relativePath: relativePath,
            outputDirectory: outputDirectory,
            payload: payload
        )
        return smlRuntimeScaffoldFileRecord(
            relativePath: relativePath,
            outputDirectory: outputDirectory,
            resource: resource,
            summary: summary,
            data: data
        )
    }

    private static func writeSMLRuntimeScaffoldTextFile(
        relativePath: String,
        outputDirectory: URL,
        summary: String,
        text: String
    ) throws -> SMLRuntimeHostScaffoldFile {
        let data = Data(text.utf8)
        try writeSMLRuntimeScaffoldData(
            data,
            relativePath: relativePath,
            outputDirectory: outputDirectory
        )
        return smlRuntimeScaffoldFileRecord(
            relativePath: relativePath,
            outputDirectory: outputDirectory,
            summary: summary,
            data: data
        )
    }

    private static func writeSMLRuntimeScaffoldData(
        _ data: Data,
        relativePath: String,
        outputDirectory: URL
    ) throws {
        let targetURL = outputDirectory.appendingPathComponent(relativePath, isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                throw SMLRuntimeHostExportError.writeFailed(
                    path: targetURL.path,
                    reason: "target already exists"
                )
            }
            try data.write(to: targetURL, options: [.atomic])
        } catch let error as SMLRuntimeHostExportError {
            throw error
        } catch {
            throw SMLRuntimeHostExportError.writeFailed(
                path: targetURL.path,
                reason: String(describing: error)
            )
        }
    }

    private static func smlRuntimeScaffoldFileRecord(
        relativePath: String,
        outputDirectory: URL,
        resource: SMLWorkflowRuntimeMetadataResource? = nil,
        summary: String,
        data: Data
    ) -> SMLRuntimeHostScaffoldFile {
        SMLRuntimeHostScaffoldFile(
            relativePath: relativePath,
            path: outputDirectory
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
                .path,
            resource: resource,
            byteCount: data.count,
            sha256: BuilderEvidenceDigest.sha256(String(decoding: data, as: UTF8.self)),
            summary: summary
        )
    }

    private static func smlRuntimeScaffoldSafeFileStem(_ workflowID: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let stem = String(workflowID.map { allowed.contains($0) ? $0 : "_" })
        return stem.isEmpty ? "workflow" : stem
    }

    private static func smlRuntimeScaffoldReadme(
        sourcePath: String,
        sourceFormat: SMLRuntimeHostExportSourceFormat,
        outputDirectory: String,
        launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor,
        files: [SMLRuntimeHostScaffoldFile]
    ) -> String {
        let workflowList = launchDescriptor.workflowIDs.map { "- \($0)" }.joined(separator: "\n")
        let apiBaseList = launchDescriptor.apiBasePaths.map { "- \($0)" }.joined(separator: "\n")
        let fileList = files.sorted {
            if $0.relativePath != $1.relativePath { return $0.relativePath < $1.relativePath }
            return $0.sha256 < $1.sha256
        }.map {
            "- `\($0.relativePath)` — \($0.summary) SHA-256: `\($0.sha256)`"
        }.joined(separator: "\n")
        return """
        # SML runtime scaffold

        Source: `\(sourcePath)`
        Source format: `\(sourceFormat.rawValue)`
        Output directory: `\(outputDirectory)`
        Launch complete: `\(launchDescriptor.launchComplete)`

        ## Mounted workflows

        \(workflowList.isEmpty ? "- none" : workflowList)

        ## API base paths

        \(apiBaseList.isEmpty ? "- none" : apiBaseList)

        ## Files

        \(fileList)

        ## Host wiring order

        1. Decode `runtime-source-package.json` or inspect `runtime-export.json`.
        2. Mount routes from `mount.json` and `openapi.json`.
        3. Attach `model-router.json` as the native tool exposed to the selected model.
        4. Load `onyx-drivers.json` for skill trees, tool bindings, and plans.
        5. Use `planning.json`, `agent-guide.json`, and `host-guide.json` as the agent/host operating contract.
        6. Use `host-wiring.json` or `attachments/*.json` when a dashboard, CLI adapter, or Onyx bridge needs one workflow-specific map.
        7. Run `repl-scripts/*.repl` with `kist --sml-runtime-repl-script <this directory> --sml-script <script>` to produce a multi-turn workflow REPL transcript.
        8. Run `api-scripts/*.json` with `kist --sml-runtime-api-script <this directory> --sml-api-script <script>` to produce a multi-request generated API transcript.
        9. Run `model-scripts/*.prompts` with `kist --sml-runtime-model-script <this directory> --sml-model-script <script>` plus a native-tool provider/model to produce a multi-turn model-router transcript.

        Descriptor files do not carry actor identity, leases, credentials, provider registries, runtime handles, or completion authority. State changes still have to cross the generated host command gateway and replay/admission checks.
        """
    }

    private static func smlRuntimeScaffoldAPIScript(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> [SMLRuntimeHostAPIRequestSpec] {
        return [SMLWorkflowControlAction.describe, .start, .watch, .receipts].compactMap { action in
            let matchingEndpoints = attachment.apiRoutes.filter {
                $0.action == action
            }.sorted {
                if $0.pathTemplate != $1.pathTemplate { return $0.pathTemplate < $1.pathTemplate }
                return $0.method.rawValue < $1.method.rawValue
            }
            guard let endpoint = matchingEndpoints.first,
                  let example = endpoint.examples.first else {
                return nil
            }
            return SMLRuntimeHostAPIRequestSpec(
                method: example.method,
                path: example.path.replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD"),
                body: smlRuntimeReplaceTaskID(in: example.body)
            )
        }
    }

    private static func smlRuntimeScaffoldREPLScript(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> String {
        let examplesByVerb = Dictionary(
            grouping: attachment.replExamples,
            by: \.verb
        ).mapValues { examples in
            examples.sorted { $0.line < $1.line }.first?.line ?? ""
        }
        let startLine = examplesByVerb["start"]?
            .replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD")
        let watchLine = examplesByVerb["watch"]?
            .replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD")
        let runtimeLines = [startLine, watchLine].compactMap { $0 }
        return ([
            "# Generated SML workflow REPL script for \(attachment.workflowID)",
            "# Run from the scaffold directory with:",
            "# kist --sml-runtime-repl-script . --sml-script repl-scripts/\(smlRuntimeScaffoldSafeFileStem(attachment.workflowID)).repl --sml-workflow \(attachment.workflowID)",
            "help",
            "schema",
            "api",
            "model",
            "onyx",
            "planning",
            "attachment",
        ] + runtimeLines + [
            "# Approval/refusal/rollback commands require the latest task_revision returned by watch.",
            "exit",
            "",
        ]).joined(separator: "\n")
    }

    private static func smlRuntimeScaffoldModelScript(
        for attachment: SMLWorkflowRuntimeWorkflowAttachmentManifest
    ) -> String {
        ([
            "# Generated SML workflow model-router prompt script for \(attachment.workflowID)",
            "# Run from the scaffold directory with a native-tool provider/model:",
            "# kist --sml-runtime-model-script . --sml-model-script model-scripts/\(smlRuntimeScaffoldSafeFileStem(attachment.workflowID)).prompts --provider <provider> --model <model>",
            "Start \(attachment.workflowID) as task TASK-SCAFFOLD with the declared sample input.",
            "Watch the current \(attachment.workflowID) task and summarize the waiting instruction.",
            "List receipts for \(attachment.workflowID); treat only accepted or sealed receipts as proof.",
            "",
        ]).joined(separator: "\n")
    }

    private static func smlRuntimeReplaceTaskID(in object: SMLObject) -> SMLObject {
        object.mapValues(smlRuntimeReplaceTaskID(in:))
    }

    private static func smlRuntimeReplaceTaskID(in value: SMLValue) -> SMLValue {
        switch value {
        case .null, .bool, .number:
            return value
        case .string(let string):
            return .string(string.replacingOccurrences(of: "TASK-ID", with: "TASK-SCAFFOLD"))
        case .array(let array):
            return .array(array.map(smlRuntimeReplaceTaskID(in:)))
        case .object(let object):
            return .object(smlRuntimeReplaceTaskID(in: object))
        }
    }

    static func makeSMLRuntimeHostAPIExchange(
        sourcePath: String?,
        projectRoot: String,
        method: SMLWorkflowAPIMethod = .get,
        path: String?,
        bodyJSON: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAPIExchange {
        guard let path,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingAPIPath
        }
        let requestBody = try decodeSMLRuntimeOpenObject(
            bodyJSON,
            flag: "--sml-body"
        )
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let request = SMLWorkflowAPIRequest(
                method: method,
                path: path,
                body: requestBody
            )
            let response = try await host.launch.app.handleRuntimeAPI(request)
            return SMLRuntimeHostAPIExchange(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                method: method,
                path: path,
                requestBody: requestBody,
                statusCode: response.statusCode,
                kind: response.kind,
                responseBody: response.body,
                route: response.route,
                pathParameters: response.pathParameters,
                metadataResource: response.metadataResource,
                command: response.command,
                result: response.result,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostAPITranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAPITranscript {
        let script = try loadSMLRuntimeAPIScript(
            scriptPath: scriptPath,
            projectRoot: projectRoot
        )
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            var exchanges: [SMLRuntimeHostAPITranscriptExchange] = []
            for (offset, spec) in script.requests.enumerated() {
                let request = SMLWorkflowAPIRequest(
                    method: spec.method,
                    path: spec.path,
                    body: spec.body
                )
                let response = try await host.launch.app.handleRuntimeAPI(request)
                exchanges.append(SMLRuntimeHostAPITranscriptExchange(
                    index: offset + 1,
                    method: spec.method,
                    path: spec.path,
                    requestBody: spec.body,
                    statusCode: response.statusCode,
                    kind: response.kind,
                    responseBody: response.body,
                    route: response.route,
                    pathParameters: response.pathParameters,
                    metadataResource: response.metadataResource,
                    command: response.command,
                    result: response.result
                ))
            }
            return SMLRuntimeHostAPITranscript(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                scriptPath: script.path,
                requestedRequestCount: script.requests.count,
                exchanges: exchanges,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostAttachments(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostAttachments {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let hostWiring = host.runtimePackage.runtime.hostWiring
            let availableWorkflowIDs = host.runtimePackage.workflowIDs
            let selectedWorkflowID = try selectSMLRuntimeOptionalWorkflowID(
                workflowID,
                availableWorkflowIDs: availableWorkflowIDs
            )
            let attachmentManifests = selectedWorkflowID.map { selected in
                hostWiring.attachmentManifests.filter { $0.workflowID == selected }
            } ?? hostWiring.attachmentManifests
            return SMLRuntimeHostAttachments(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: availableWorkflowIDs,
                apiBasePaths: hostWiring.apiBasePaths,
                attachmentEndpoint: hostWiring.metadataEndpoints.first {
                    $0.resource == .attachments
                },
                attachments: attachmentManifests,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostModelTurn(
        sourcePath: String?,
        projectRoot: String,
        prompt: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostModelTurn {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingModelPrompt
        }
        let maximumCommandRounds = modelMaximumCommandRoundsOverride.map {
            min(max(1, $0), 8)
        } ?? 4
        let requestBudget = ProviderRequestBudget(limit: maximumCommandRounds)
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: maximumCommandRounds
        ) { host in
            let session = host.launch.app.modelRouterSession(
                binding: binding,
                providers: providers,
                maximumCommandRounds: maximumCommandRounds
            )
            let turn = try await session.submit(
                prompt,
                requestBudget: requestBudget
            )
            let consumed = await requestBudget.consumedCount()
            return SMLRuntimeHostModelTurn(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                prompt: prompt,
                providerBinding: binding,
                maximumCommandRounds: maximumCommandRounds,
                providerRequestLimit: maximumCommandRounds,
                providerRequestsConsumed: consumed,
                advisoryText: turn.advisoryText,
                steps: turn.steps.map(SMLRuntimeHostModelStep.init),
                taskIDsByWorkflowID: turn.taskIDsByWorkflowID,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostModelTranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostModelTranscript {
        let script = try loadSMLRuntimeModelScript(
            scriptPath: scriptPath,
            projectRoot: projectRoot
        )
        let maximumCommandRounds = modelMaximumCommandRoundsOverride.map {
            min(max(1, $0), 8)
        } ?? 4
        let providerRequestLimit = maximumCommandRounds * script.prompts.count
        let requestBudget = ProviderRequestBudget(limit: providerRequestLimit)
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: maximumCommandRounds
        ) { host in
            let session = host.launch.app.modelRouterSession(
                binding: binding,
                providers: providers,
                maximumCommandRounds: maximumCommandRounds
            )
            var turns: [SMLRuntimeHostModelTranscriptTurn] = []
            for (offset, prompt) in script.prompts.enumerated() {
                let before = await requestBudget.consumedCount()
                let turn = try await session.submit(
                    prompt,
                    requestBudget: requestBudget
                )
                let after = await requestBudget.consumedCount()
                turns.append(SMLRuntimeHostModelTranscriptTurn(
                    index: offset + 1,
                    prompt: prompt,
                    providerRequestsBefore: before,
                    providerRequestsAfter: after,
                    advisoryText: turn.advisoryText,
                    steps: turn.steps.map(SMLRuntimeHostModelStep.init),
                    taskIDsByWorkflowID: turn.taskIDsByWorkflowID
                ))
            }
            let consumed = await requestBudget.consumedCount()
            return SMLRuntimeHostModelTranscript(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                scriptPath: script.path,
                providerBinding: binding,
                maximumCommandRounds: maximumCommandRounds,
                promptCount: script.prompts.count,
                providerRequestLimit: providerRequestLimit,
                providerRequestsConsumed: consumed,
                turns: turns,
                taskIDsByWorkflowID: await session.taskIDs(),
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostREPLCommand(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        line: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostREPLCommand {
        guard let line,
              !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingREPLLine
        }
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let availableWorkflowIDs = host.runtimePackage.workflowIDs
            let selectedWorkflowID = try selectSMLRuntimeREPLWorkflowID(
                workflowID,
                availableWorkflowIDs: availableWorkflowIDs
            )
            let session = try host.launch.app.replSession(workflowID: selectedWorkflowID)
            let response = try await session.submit(line)
            return SMLRuntimeHostREPLCommand(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: availableWorkflowIDs,
                line: line,
                output: response.output,
                shouldExit: response.shouldExit,
                command: response.command,
                result: response.result,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    static func makeSMLRuntimeHostREPLTranscript(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostREPLTranscript {
        let script = try loadSMLRuntimeREPLScript(
            scriptPath: scriptPath,
            projectRoot: projectRoot
        )
        return try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let availableWorkflowIDs = host.runtimePackage.workflowIDs
            let selectedWorkflowID = try selectSMLRuntimeREPLWorkflowID(
                workflowID,
                availableWorkflowIDs: availableWorkflowIDs
            )
            let session = try host.launch.app.replSession(workflowID: selectedWorkflowID)
            var turns: [SMLRuntimeHostREPLTranscriptTurn] = []
            var stoppedAtExit = false
            for (offset, line) in script.lines.enumerated() {
                let response = try await session.submit(line)
                turns.append(SMLRuntimeHostREPLTranscriptTurn(
                    index: offset + 1,
                    line: line,
                    output: response.output,
                    shouldExit: response.shouldExit,
                    command: response.command,
                    result: response.result
                ))
                if response.shouldExit {
                    stoppedAtExit = true
                    break
                }
            }
            return SMLRuntimeHostREPLTranscript(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                workflowID: selectedWorkflowID,
                availableWorkflowIDs: availableWorkflowIDs,
                scriptPath: script.path,
                requestedLineCount: script.lines.count,
                stoppedAtExit: stoppedAtExit,
                turns: turns,
                launchDescriptor: host.launch.launchDescriptor
            )
        }
    }

    private struct SMLRuntimeHostLaunch {
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let launch: SMLWorkflowRuntimeLaunch
    }

    private final class SMLRuntimeSequentialIDSource: @unchecked Sendable {
        private let lock = NSLock()
        private let prefix: String
        private var nextValue = 0

        init(prefix: String) {
            self.prefix = prefix
        }

        func nextID() -> String {
            lock.lock()
            defer { lock.unlock() }
            nextValue += 1
            return "\(prefix)-\(nextValue)"
        }
    }

    private static func withSMLRuntimeHostLaunch<T>(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil,
        _ body: (SMLRuntimeHostLaunch) async throws -> T
    ) async throws -> T {
        guard let sourcePath,
              !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingSourcePath
        }
        let requestedSourceURL = smlRuntimeSourceURL(sourcePath, projectRoot: projectRoot)
        let sourceURL = smlRuntimeReadableSourceURL(requestedSourceURL)
        let sourceData: Data
        do {
            sourceData = try Data(contentsOf: sourceURL)
        } catch {
            throw SMLRuntimeHostExportError.readFailed(
                path: sourceURL.path,
                reason: String(describing: error)
            )
        }

        let loaded = try loadSMLRuntimeSource(data: sourceData, path: sourceURL.path)
        let role = roleOverride ?? (loaded.package == nil ? "workflow-agent" : nil)
        let actor = actor ?? "sml-runtime-exporter"
        let title = title ?? "SML Workflow Runtime API"
        let version = version ?? "1.0.0"
        let modelRounds = modelMaximumCommandRoundsOverride.map { min(max(1, $0), 8) }
        let admissionCatalog = derivedSMLAdmissionCatalog(for: loaded.workflows)
        let commandIDSource = SMLRuntimeSequentialIDSource(prefix: "sml-runtime-export-command")
        let taskIDSource = SMLRuntimeSequentialIDSource(prefix: "TASK-SML-RUNTIME-EXPORT")
        let registry: SMLWorkflowRuntimeRegistry
        if let package = loaded.package {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                package: package,
                admissionCatalog: admissionCatalog,
                actor: actor,
                roleOverride: role,
                apiBasePathOverride: apiBasePathOverride,
                modelMaximumCommandRoundsOverride: modelRounds,
                commandID: { commandIDSource.nextID() },
                taskID: { taskIDSource.nextID() }
            )
        } else {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                workflows: loaded.workflows,
                admissionCatalog: admissionCatalog,
                role: role ?? "workflow-agent",
                actor: actor,
                apiBasePath: apiBasePathOverride ?? "/sml",
                modelMaximumCommandRounds: modelRounds ?? 4,
                commandID: { commandIDSource.nextID() },
                taskID: { taskIDSource.nextID() }
            )
        }

        let runtimePackage = try SMLWorkflowRuntimeSourcePackage(
            normalizedWorkflows: loaded.workflows,
            runtime: registry.export(title: title, version: version)
        )
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-sml-runtime-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let store = SMLRuntimeStore(
            fileURL: tempDirectory.appendingPathComponent("runtime.json"),
            clock: { 0 }
        )
        let runtime = SMLRuntime(store: store, clock: { 0 })
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = {
            command in
            SMLCommandAuthority(
                authenticatedActor: actor,
                leaseID: "sml-runtime-export-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }
        let launch = try await SMLWorkflowRuntimeApp.launch(
            registry: registry,
            runtime: runtime,
            replayGuard: store,
            authorityResolver: authority,
            sourcePackage: runtimePackage,
            clock: { 0 }
        )
        let host = SMLRuntimeHostLaunch(
            sourcePath: sourceURL.standardizedFileURL.path,
            sourceFormat: loaded.format,
            runtimePackage: runtimePackage,
            launch: launch
        )
        return try await body(host)
    }

    private static func selectSMLRuntimeREPLWorkflowID(
        _ workflowID: String?,
        availableWorkflowIDs: [String]
    ) throws -> String {
        guard !availableWorkflowIDs.isEmpty else {
            throw SMLRuntimeHostExportError.noREPLWorkflows
        }
        if let workflowID,
           !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard availableWorkflowIDs.contains(workflowID) else {
                throw SMLRuntimeHostExportError.unknownREPLWorkflow(
                    requested: workflowID,
                    available: availableWorkflowIDs
                )
            }
            return workflowID
        }
        guard availableWorkflowIDs.count == 1, let only = availableWorkflowIDs.first else {
            throw SMLRuntimeHostExportError.ambiguousREPLWorkflow(availableWorkflowIDs)
        }
        return only
    }

    private static func selectSMLRuntimeOptionalWorkflowID(
        _ workflowID: String?,
        availableWorkflowIDs: [String]
    ) throws -> String? {
        guard let workflowID,
              !workflowID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard availableWorkflowIDs.contains(workflowID) else {
            throw SMLRuntimeHostExportError.unknownREPLWorkflow(
                requested: workflowID,
                available: availableWorkflowIDs
            )
        }
        return workflowID
    }

    private static func decodeSMLRuntimeOpenObject(
        _ json: String?,
        flag: String
    ) throws -> SMLObject {
        guard let json,
              !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        guard let data = json.data(using: .utf8) else {
            throw SMLRuntimeHostExportError.invalidJSONObject(
                flag: flag,
                reason: "input is not UTF-8"
            )
        }
        do {
            return try SMLWireCodec.decodeOpenObject(
                from: data,
                limits: .init(maximumBytes: 256 * 1_024, maximumDepth: 16, maximumNodes: 8_192)
            )
        } catch {
            throw SMLRuntimeHostExportError.invalidJSONObject(
                flag: flag,
                reason: String(describing: error)
            )
        }
    }

    private static func loadSMLRuntimeREPLScript(
        scriptPath: String?,
        projectRoot: String
    ) throws -> (path: String, lines: [String]) {
        guard let scriptPath,
              !scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingREPLScriptPath
        }
        let scriptURL = smlRuntimeSourceURL(scriptPath, projectRoot: projectRoot)
            .standardizedFileURL
        let scriptText: String
        do {
            scriptText = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw SMLRuntimeHostExportError.readREPLScriptFailed(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        let lines = scriptText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else {
            throw SMLRuntimeHostExportError.emptyREPLScript(path: scriptURL.path)
        }
        return (scriptURL.path, lines)
    }

    private static func loadSMLRuntimeAPIScript(
        scriptPath: String?,
        projectRoot: String
    ) throws -> (path: String, requests: [SMLRuntimeHostAPIRequestSpec]) {
        guard let scriptPath,
              !scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingAPIScriptPath
        }
        let scriptURL = smlRuntimeSourceURL(scriptPath, projectRoot: projectRoot)
            .standardizedFileURL
        let data: Data
        do {
            data = try Data(contentsOf: scriptURL)
        } catch {
            throw SMLRuntimeHostExportError.readAPIScriptFailed(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        let requests: [SMLRuntimeHostAPIRequestSpec]
        do {
            requests = try JSONDecoder().decode([SMLRuntimeHostAPIRequestSpec].self, from: data)
        } catch {
            throw SMLRuntimeHostExportError.invalidAPIScript(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        guard !requests.isEmpty else {
            throw SMLRuntimeHostExportError.emptyAPIScript(path: scriptURL.path)
        }
        for request in requests where request.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SMLRuntimeHostExportError.invalidAPIScript(
                path: scriptURL.path,
                reason: "request path must be nonempty"
            )
        }
        return (scriptURL.path, requests)
    }

    private static func loadSMLRuntimeModelScript(
        scriptPath: String?,
        projectRoot: String
    ) throws -> (path: String, prompts: [String]) {
        guard let scriptPath,
              !scriptPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SMLRuntimeHostExportError.missingModelScriptPath
        }
        let scriptURL = smlRuntimeSourceURL(scriptPath, projectRoot: projectRoot)
            .standardizedFileURL
        let scriptText: String
        do {
            scriptText = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw SMLRuntimeHostExportError.readModelScriptFailed(
                path: scriptURL.path,
                reason: String(describing: error)
            )
        }
        let prompts = scriptText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !prompts.isEmpty else {
            throw SMLRuntimeHostExportError.emptyModelScript(path: scriptURL.path)
        }
        return (scriptURL.path, prompts)
    }

    private struct LoadedSMLRuntimeSource {
        let format: SMLRuntimeHostExportSourceFormat
        let package: SMLWorkflowRuntimeSourcePackage?
        let workflows: [SMLWorkflow]
    }

    private static func smlRuntimeSourceURL(
        _ sourcePath: String,
        projectRoot: String
    ) -> URL {
        if sourcePath.hasPrefix("/") {
            return URL(fileURLWithPath: sourcePath)
        }
        return URL(fileURLWithPath: projectRoot, isDirectory: true)
            .appendingPathComponent(sourcePath)
    }

    private static func smlRuntimeReadableSourceURL(_ sourceURL: URL) -> URL {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: sourceURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return sourceURL
        }
        return sourceURL.appendingPathComponent("scaffold.json", isDirectory: false)
    }

    private static func loadSMLRuntimeSource(
        data: Data,
        path: String
    ) throws -> LoadedSMLRuntimeSource {
        var diagnostics: [String] = []
        do {
            let package = try JSONDecoder().decode(SMLWorkflowRuntimeSourcePackage.self, from: data)
            return LoadedSMLRuntimeSource(
                format: .runtimeSourcePackage,
                package: package,
                workflows: package.normalizedWorkflows
            )
        } catch {
            diagnostics.append("runtime source package: \(error)")
        }
        do {
            let scaffold = try JSONDecoder().decode(SMLRuntimeHostScaffold.self, from: data)
            let package = try loadSMLRuntimePackage(from: scaffold, indexPath: path)
            return LoadedSMLRuntimeSource(
                format: .runtimeScaffold,
                package: package,
                workflows: package.normalizedWorkflows
            )
        } catch {
            diagnostics.append("runtime scaffold: \(error)")
        }
        do {
            let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: data)
            return LoadedSMLRuntimeSource(
                format: .langGraphManifest,
                package: nil,
                workflows: [workflow]
            )
        } catch {
            diagnostics.append("LangGraph manifest: \(error)")
        }
        do {
            let workflow = try SMLWorkflowSourceImporter.workflow(from: .smlWorkflowJSON(data))
            return LoadedSMLRuntimeSource(
                format: .smlWorkflowJSON,
                package: nil,
                workflows: [workflow]
            )
        } catch {
            diagnostics.append("SML workflow JSON: \(error)")
        }
        throw SMLRuntimeHostExportError.unsupportedSource(
            path: path,
            diagnostics: diagnostics
        )
    }

    private static func loadSMLRuntimePackage(
        from scaffold: SMLRuntimeHostScaffold,
        indexPath: String
    ) throws -> SMLWorkflowRuntimeSourcePackage {
        guard let packageFile = scaffold.files.first(where: {
            $0.relativePath == "runtime-source-package.json"
        }) else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "missing runtime-source-package.json file record"
            )
        }
        let indexURL = URL(fileURLWithPath: indexPath)
        let packageURL = indexURL
            .deletingLastPathComponent()
            .appendingPathComponent(packageFile.relativePath, isDirectory: false)
            .standardizedFileURL
        let packageData: Data
        do {
            packageData = try Data(contentsOf: packageURL)
        } catch {
            throw SMLRuntimeHostExportError.readFailed(
                path: packageURL.path,
                reason: String(describing: error)
            )
        }
        guard packageData.count == packageFile.byteCount else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "runtime-source-package.json byte count changed"
            )
        }
        let packageText = String(decoding: packageData, as: UTF8.self)
        guard BuilderEvidenceDigest.sha256(packageText) == packageFile.sha256 else {
            throw SMLRuntimeHostExportError.invalidScaffold(
                path: indexPath,
                reason: "runtime-source-package.json digest changed"
            )
        }
        return try JSONDecoder().decode(SMLWorkflowRuntimeSourcePackage.self, from: packageData)
    }

    /// Offline export needs an admission catalog only to prove the generated surfaces are structurally
    /// mountable. This catalog is derived from the already-imported workflow references and is not
    /// serialized; live execution still requires the host's fresh admission catalog and authority resolver.
    private static func derivedSMLAdmissionCatalog(
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
