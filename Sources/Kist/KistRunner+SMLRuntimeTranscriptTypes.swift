import Foundation
import AgentCore

extension KistRunner {
    struct SMLRuntimeHostAttachments: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 5

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

}
