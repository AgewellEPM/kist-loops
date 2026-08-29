import Foundation
import AgentCore

extension KistRunner {
    enum SMLRuntimeHostExportSourceFormat: String, Sendable, Codable, Equatable {
        case runtimeSourcePackage = "runtime_source_package"
        case langGraphManifest = "langgraph_manifest"
        case smlWorkflowJSON = "sml_workflow_json"
    }

    struct SMLRuntimeHostExport: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 2

        let schemaVersion: Int
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let hostWiring: SMLRuntimeHostWiring
        let launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor

        init(
            schemaVersion: Int = SMLRuntimeHostExport.currentSchemaVersion,
            sourcePath: String,
            sourceFormat: SMLRuntimeHostExportSourceFormat,
            runtimePackage: SMLWorkflowRuntimeSourcePackage,
            hostWiring: SMLRuntimeHostWiring,
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

    struct SMLRuntimeHostWorkflowWiring: Sendable, Codable, Equatable {
        let workflowID: String
        let workflowVersion: String
        let role: String
        let apiBasePath: String
        let replMount: SMLWorkflowRuntimeREPLMount
        let apiRoutes: [SMLWorkflowRuntimeAPIMount]
        let modelToolName: String
        let modelRouterToolName: String
        let onyxDriverID: String
        let planningWorkflowID: String?
        let toolReferences: [String]
        let decomposableUnits: [SMLWorkflowRuntimePlanningDecompositionUnit]
        let approvalGates: [SMLWorkflowRuntimePlanningApprovalGate]
        let hostBindings: [SMLWorkflowRuntimeHostBinding]

        init(
            launchWorkflow: SMLWorkflowRuntimeLaunchWorkflow,
            hostGuide: SMLWorkflowRuntimeWorkflowHostGuide?
        ) {
            workflowID = launchWorkflow.workflowID
            workflowVersion = launchWorkflow.workflowVersion
            role = launchWorkflow.role
            apiBasePath = launchWorkflow.apiBasePath
            replMount = launchWorkflow.replMount
            apiRoutes = launchWorkflow.apiRoutes
            modelToolName = launchWorkflow.modelToolName
            modelRouterToolName = launchWorkflow.modelRouterToolName
            onyxDriverID = launchWorkflow.onyxDriverID
            planningWorkflowID = launchWorkflow.planningWorkflowID
            toolReferences = hostGuide?.toolReferences ?? []
            decomposableUnits = hostGuide?.decomposableUnits ?? []
            approvalGates = hostGuide?.approvalGates ?? []
            hostBindings = hostGuide?.hostBindings ?? []
        }
    }

    struct SMLRuntimeHostWiring: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let apiBasePaths: [String]
        let metadataEndpoints: [SMLWorkflowRuntimeMetadataEndpoint]
        let requiredHostServices: [String]
        let launchSteps: [SMLWorkflowRuntimeHostLaunchStep]
        let modelRouter: SMLWorkflowRuntimeModelRouterDescriptor
        let onyxDriverIDs: [String]
        let planningWorkflowIDs: [String]
        let workflows: [SMLRuntimeHostWorkflowWiring]

        init(
            schemaVersion: Int = SMLRuntimeHostWiring.currentSchemaVersion,
            runtimePackage: SMLWorkflowRuntimeSourcePackage,
            launchDescriptor: SMLWorkflowRuntimeLaunchDescriptor
        ) {
            let hostGuidesByWorkflowID = Dictionary(
                uniqueKeysWithValues: runtimePackage.runtime.hostGuide.workflowBindings.map {
                    ($0.workflowID, $0)
                }
            )
            self.schemaVersion = schemaVersion
            apiBasePaths = launchDescriptor.apiBasePaths
            metadataEndpoints = launchDescriptor.metadataEndpoints
            requiredHostServices = launchDescriptor.requiredHostServices
            launchSteps = launchDescriptor.launchSteps
            modelRouter = launchDescriptor.modelRouter
            onyxDriverIDs = launchDescriptor.onyxDriverIDs
            planningWorkflowIDs = launchDescriptor.planningWorkflowIDs
            workflows = launchDescriptor.workflows.map {
                SMLRuntimeHostWorkflowWiring(
                    launchWorkflow: $0,
                    hostGuide: hostGuidesByWorkflowID[$0.workflowID]
                )
            }
        }
    }

    struct SMLRuntimeHostREPLCommand: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

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

    struct SMLRuntimeHostAPIExchange: Sendable, Codable, Equatable {
        static let currentSchemaVersion = 1

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

    enum SMLRuntimeHostExportError: Error, CustomStringConvertible {
        case missingSourcePath
        case missingREPLLine
        case missingAPIPath
        case missingModelPrompt
        case invalidJSONObject(flag: String, reason: String)
        case readFailed(path: String, reason: String)
        case unsupportedSource(path: String, diagnostics: [String])
        case noREPLWorkflows
        case ambiguousREPLWorkflow([String])
        case unknownREPLWorkflow(requested: String, available: [String])

        var description: String {
            switch self {
            case .missingSourcePath:
                return "--sml-runtime-export/--sml-runtime-repl/--sml-runtime-api requires <source.json>"
            case .missingREPLLine:
                return "--sml-runtime-repl requires --sml-line <line>"
            case .missingAPIPath:
                return "--sml-runtime-api requires --sml-path <path>"
            case .missingModelPrompt:
                return "--sml-runtime-model requires --sml-prompt <text> or a positional prompt"
            case .invalidJSONObject(let flag, let reason):
                return "\(flag) must be a valid SML JSON object: \(reason)"
            case .readFailed(let path, let reason):
                return "could not read SML runtime source '\(path)': \(reason)"
            case .unsupportedSource(let path, let diagnostics):
                return """
                unsupported SML runtime source '\(path)'. Expected a runtime source package, LangGraph manifest, or SML workflow JSON.
                \(diagnostics.map { "  - \($0)" }.joined(separator: "\n"))
                """
            case .noREPLWorkflows:
                return "SML runtime source contains no workflow REPL mounts"
            case .ambiguousREPLWorkflow(let workflows):
                return "--sml-workflow is required because the runtime source contains multiple workflows: \(workflows.joined(separator: ", "))"
            case .unknownREPLWorkflow(let requested, let available):
                return "unknown --sml-workflow '\(requested)'. Available workflows: \(available.joined(separator: ", "))"
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
                hostWiring: SMLRuntimeHostWiring(
                    runtimePackage: host.runtimePackage,
                    launchDescriptor: launchDescriptor
                ),
                launchDescriptor: launchDescriptor
            )
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

    private struct SMLRuntimeHostLaunch {
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let launch: SMLWorkflowRuntimeLaunch
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
        let sourceURL = smlRuntimeSourceURL(sourcePath, projectRoot: projectRoot)
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
        let registry: SMLWorkflowRuntimeRegistry
        if let package = loaded.package {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                package: package,
                admissionCatalog: admissionCatalog,
                actor: actor,
                roleOverride: role,
                apiBasePathOverride: apiBasePathOverride,
                modelMaximumCommandRoundsOverride: modelRounds,
                commandID: { "sml-runtime-export-command" },
                taskID: { "TASK-SML-RUNTIME-EXPORT" }
            )
        } else {
            registry = try SMLWorkflowRuntimeRegistry.compile(
                workflows: loaded.workflows,
                admissionCatalog: admissionCatalog,
                role: role ?? "workflow-agent",
                actor: actor,
                apiBasePath: apiBasePathOverride ?? "/sml",
                modelMaximumCommandRounds: modelRounds ?? 4,
                commandID: { "sml-runtime-export-command" },
                taskID: { "TASK-SML-RUNTIME-EXPORT" }
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
