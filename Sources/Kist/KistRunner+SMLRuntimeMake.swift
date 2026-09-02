import Foundation
import AgentCore

extension KistRunner {
    static func makeSMLRuntimeHostExport(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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

    static func makeSMLRuntimeHostRunbook(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> SMLRuntimeHostScaffoldRunbook {
        try await withSMLRuntimeHostLaunch(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        ) { host in
            let launchDescriptor = host.launch.launchDescriptor
            let selectedWorkflowID = try selectSMLRuntimeOptionalWorkflowID(
                workflowID,
                availableWorkflowIDs: launchDescriptor.workflowIDs
            )
            let attachments = host.runtimePackage.runtime.hostWiring.attachmentManifests.filter { attachment in
                selectedWorkflowID.map { $0 == attachment.workflowID } ?? true
            }
            return smlRuntimeScaffoldRunbook(
                sourcePath: host.sourcePath,
                sourceFormat: host.sourceFormat,
                outputDirectory: smlRuntimeRunbookOutputDirectory(
                    for: host,
                    projectRoot: projectRoot
                ),
                artifactsMaterialized: host.sourceFormat == .runtimeScaffold,
                launchDescriptor: launchDescriptor,
                attachments: attachments
            )
        }
    }

    static func makeSMLRuntimeHostAPIExchange(
        sourcePath: String?,
        projectRoot: String,
        mode: SMLRuntimeHostMode = .ephemeralExport,
        method: SMLWorkflowAPIMethod = .get,
        path: String?,
        bodyJSON: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
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
            mode: mode,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        mode: SMLRuntimeHostMode = .ephemeralExport,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
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
            mode: mode,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        apiWorkflowPathOverrides: [String: String] = [:],
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
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        mode: SMLRuntimeHostMode = .ephemeralExport,
        workflowID: String? = nil,
        line: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
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
            mode: mode,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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
        mode: SMLRuntimeHostMode = .ephemeralExport,
        workflowID: String? = nil,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
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
            mode: mode,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
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

    struct SMLRuntimeHostLaunch {
        let sourcePath: String
        let sourceFormat: SMLRuntimeHostExportSourceFormat
        let runtimePackage: SMLWorkflowRuntimeSourcePackage
        let launch: SMLWorkflowRuntimeLaunch
    }

    final class SMLRuntimeSequentialIDSource: @unchecked Sendable {
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

}
