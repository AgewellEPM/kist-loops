import XCTest
import AgentCore
@testable import Kist

final class KistSMLRuntimeExportTests: XCTestCase {
    func testRuntimeExportAndREPLDispatchBeforeProviderRegistryStartup() throws {
        let source = kistRunnerFamilySource()
        let apiDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAPI != nil"))
        let replDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeREPL != nil"))
        let exportDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeExport != nil"))
        let modelDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeModel != nil"))
        let configLoad = try XCTUnwrap(source.range(of: "let config = KistConfig.load()"))
        let buildTools = try XCTUnwrap(source.range(of: "let extraTools = Self.buildExtraTools"))

        XCTAssertLessThan(
            apiDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime API must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            replDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime REPL must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            exportDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertGreaterThan(
            modelDispatch.lowerBound,
            configLoad.lowerBound,
            "SML runtime model mode intentionally resolves a real provider/model before execution"
        )
        XCTAssertLessThan(
            modelDispatch.lowerBound,
            buildTools.lowerBound,
            "SML runtime model mode must use the generated model-router tool, not the normal agent tool registry"
        )
    }

    func testLangGraphManifestExportPrintsHostRuntimePackage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostExport(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let export = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostExport.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(export.schemaVersion, KistRunner.SMLRuntimeHostExport.currentSchemaVersion)
        XCTAssertEqual(export.sourceFormat, .langGraphManifest)
        XCTAssertEqual(export.runtimePackage.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(export.runtimePackage.runtime.schemaVersion, SMLWorkflowRuntimeExport.currentSchemaVersion)
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/source"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.role), ["reviewer"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.workflowMounts.map(\.apiRoutes.count), [7])
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.maximumCommandRounds, 3)
        XCTAssertEqual(export.runtimePackage.runtime.modelTools.map(\.tool.name), [SMLWorkflowModelAdapter.toolName])
        XCTAssertEqual(
            export.runtimePackage.runtime.onyxDrivers.map(\.driverID),
            export.runtimePackage.runtime.mountContract.onyxDriverIDs
        )
        XCTAssertEqual(export.runtimePackage.runtime.planning.workflowIDs, ["langgraph.review"])

        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/source/workflows/langgraph.review/tasks"])
        XCTAssertNotNil(paths["/source/runtime/model-router"])
        XCTAssertNotNil(paths["/source/runtime/onyx-drivers"])
        XCTAssertNotNil(paths["/source/runtime/planning"])

        XCTAssertEqual(export.launchDescriptor.sourcePackageSchemaVersion, SMLWorkflowRuntimeSourcePackage.currentSchemaVersion)
        XCTAssertEqual(export.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(export.launchDescriptor.installedWorkflowIDs, ["langgraph.review"])
        XCTAssertTrue(export.launchDescriptor.launchComplete)
        XCTAssertEqual(export.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertEqual(export.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.launchDescriptor.planningWorkflowIDs, ["langgraph.review"])
        let launched = try XCTUnwrap(export.launchDescriptor.workflows.first)
        XCTAssertEqual(launched.replMount.workflowID, "langgraph.review")
        XCTAssertEqual(launched.apiRoutes.count, 7)
        XCTAssertEqual(launched.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(launched.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(
            Set(launched.hostBindingChannels),
            [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow,
            ]
        )

        XCTAssertEqual(export.hostWiring.schemaVersion, KistRunner.SMLRuntimeHostWiring.currentSchemaVersion)
        XCTAssertEqual(export.hostWiring.apiBasePaths, ["/source"])
        XCTAssertEqual(export.hostWiring.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.hostWiring.modelRouter.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(
            export.hostWiring.onyxDriverIDs,
            export.runtimePackage.runtime.onyxDrivers.map(\.driverID)
        )
        XCTAssertEqual(export.hostWiring.planningWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(export.hostWiring.requiredHostServices, export.launchDescriptor.requiredHostServices)
        XCTAssertEqual(export.hostWiring.launchSteps, export.launchDescriptor.launchSteps)

        let metadataPaths = export.hostWiring.metadataEndpoints.map(\.pathTemplate)
        XCTAssertTrue(metadataPaths.contains("/source/runtime/planning"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/onyx-drivers"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/host-guide"))

        let wiring = try XCTUnwrap(export.hostWiring.workflows.first)
        XCTAssertEqual(wiring.workflowID, "langgraph.review")
        XCTAssertEqual(wiring.role, "reviewer")
        XCTAssertEqual(wiring.apiBasePath, "/source")
        XCTAssertEqual(wiring.replMount.workflowID, "langgraph.review")
        XCTAssertEqual(wiring.apiRoutes.count, 7)
        XCTAssertEqual(wiring.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(wiring.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(wiring.onyxDriverID, export.runtimePackage.runtime.onyxDrivers.first?.driverID)
        XCTAssertEqual(wiring.planningWorkflowID, "langgraph.review")
        XCTAssertTrue(wiring.toolReferences.contains("review.plan"))
        XCTAssertTrue(wiring.toolReferences.contains("repository.write"))
        XCTAssertEqual(
            Set(wiring.hostBindings.map(\.channel)),
            [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow,
            ]
        )
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .customAPI
                && $0.pathTemplates.contains("/source/workflows/langgraph.review/tasks")
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .onyxDriver && $0.driverID == wiring.onyxDriverID
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .planningWorkflow && $0.planningWorkflowID == wiring.planningWorkflowID
        })

        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestAPIHandlesMetadataEndpointThroughLaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/planning",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let api = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(api.schemaVersion, KistRunner.SMLRuntimeHostAPIExchange.currentSchemaVersion)
        XCTAssertEqual(api.sourceFormat, .langGraphManifest)
        XCTAssertEqual(api.method, .get)
        XCTAssertEqual(api.path, "/source/runtime/planning")
        XCTAssertEqual(api.requestBody, [:])
        XCTAssertEqual(api.statusCode, 200)
        XCTAssertEqual(api.kind, .metadata)
        XCTAssertEqual(api.metadataResource, .planning)
        XCTAssertNil(api.command)
        XCTAssertNil(api.result)
        XCTAssertEqual(api.route?.handlerKind, .metadata)
        XCTAssertEqual(api.route?.authority, .descriptorOnly)
        let planning = try object(api.responseBody)
        XCTAssertEqual(planning["workflowIDs"], .array([.string("langgraph.review")]))
        XCTAssertEqual(api.launchDescriptor.apiBasePaths, ["/source"])

        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestAPIStartsWorkflowTaskThroughLaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .post,
            path: "/source/workflows/langgraph.review/tasks",
            bodyJSON: #"{"task_id":"TASK-API","input":{"topic":"runtime"}}"#,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let api = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(api.schemaVersion, KistRunner.SMLRuntimeHostAPIExchange.currentSchemaVersion)
        XCTAssertEqual(api.statusCode, 201)
        XCTAssertEqual(api.kind, .workflow)
        XCTAssertEqual(api.route?.handlerKind, .workflow)
        XCTAssertEqual(api.route?.authority, .hostCommandGateway)
        XCTAssertEqual(api.route?.workflowID, "langgraph.review")
        XCTAssertEqual(api.route?.action, .start)
        XCTAssertNil(api.metadataResource)
        XCTAssertEqual(api.pathParameters, [:])
        let requestInput = try object(api.requestBody["input"])
        XCTAssertEqual(api.requestBody["task_id"], .string("TASK-API"))
        XCTAssertEqual(requestInput["topic"], .string("runtime"))

        let command = try XCTUnwrap(api.command)
        XCTAssertEqual(command.actor, "operator.test")
        XCTAssertEqual(command.role, "reviewer")
        XCTAssertEqual(command.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(command.task, "TASK-API")
        XCTAssertEqual(command.arguments["workflow_id"], .string("langgraph.review"))
        let initialState = try object(command.arguments["initial_state"])
        XCTAssertEqual(initialState["topic"], .string("runtime"))

        let result = try XCTUnwrap(api.result)
        XCTAssertEqual(result.kind, .task)
        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.taskID, "TASK-API")
        XCTAssertEqual(task.status, .waitingCapability)
        XCTAssertEqual(task.currentInstructionID, "plan")
        XCTAssertEqual(task.currentOperation, .callModel)
        let response = try object(api.responseBody)
        XCTAssertEqual(response["kind"], .string("task"))
        XCTAssertEqual(api.launchDescriptor.workflowIDs, ["langgraph.review"])

        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestModelRoutesThroughGeneratedRuntimeTool() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)
        let provider = ScriptedSMLRuntimeProvider([
            .textAndCall(
                "Routing the wrapped workflow.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"start TASK-MODEL {\"topic\":\"runtime\"}"}"#
            ),
        ])
        let registry = ProviderRegistry(
            providers: [provider],
            retryDelaysNanoseconds: []
        )

        let json = try await KistRunner.renderSMLRuntimeHostModelTurn(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            prompt: "start the review workflow",
            binding: ProviderBinding(providerId: provider.id, model: provider.defaultModel),
            providers: registry,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let model = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelTurn.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(model.schemaVersion, KistRunner.SMLRuntimeHostModelTurn.currentSchemaVersion)
        XCTAssertEqual(model.sourceFormat, .langGraphManifest)
        XCTAssertEqual(model.prompt, "start the review workflow")
        XCTAssertEqual(model.providerBinding, ProviderBinding(providerId: "sml-scripted", model: "scripted-1"))
        XCTAssertEqual(model.maximumCommandRounds, 3)
        XCTAssertEqual(model.providerRequestLimit, 3)
        XCTAssertEqual(model.providerRequestsConsumed, 1)
        XCTAssertEqual(model.advisoryText, "Routing the wrapped workflow.")
        XCTAssertEqual(model.steps.count, 1)
        let step = try XCTUnwrap(model.steps.first)
        XCTAssertEqual(step.disposition, .commandExecuted)
        XCTAssertEqual(step.advisoryText, "Routing the wrapped workflow.")
        XCTAssertEqual(step.toolCallID, "call-1")

        let command = try XCTUnwrap(step.command)
        XCTAssertEqual(command.actor, "operator.test")
        XCTAssertEqual(command.role, "reviewer")
        XCTAssertEqual(command.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(command.task, "TASK-MODEL")
        XCTAssertEqual(command.arguments["workflow_id"], .string("langgraph.review"))
        let initialState = try object(command.arguments["initial_state"])
        XCTAssertEqual(initialState["topic"], .string("runtime"))

        let result = try XCTUnwrap(step.result)
        XCTAssertEqual(result.kind, .task)
        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.taskID, "TASK-MODEL")
        XCTAssertEqual(task.workflowID, "langgraph.review")
        XCTAssertEqual(task.status, .waitingCapability)
        XCTAssertEqual(task.currentInstructionID, "plan")
        XCTAssertEqual(task.currentOperation, .callModel)
        XCTAssertEqual(model.taskIDsByWorkflowID["langgraph.review"], "TASK-MODEL")
        XCTAssertEqual(model.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)

        let capture = provider.capture()
        XCTAssertEqual(capture.toolNames, [SMLWorkflowRuntimeModelAdapter.toolName])
        XCTAssertEqual(capture.toolChoice, .any)
        XCTAssertFalse(capture.geminiBuiltins)
        XCTAssertTrue(capture.systemPrompt.contains("mounted workflow_id"))
        XCTAssertTrue(capture.systemPrompt.contains("langgraph.review@1.0.0"))
        XCTAssertTrue(capture.systemPrompt.contains("Allowed REPL grammar:"))
        XCTAssertTrue(capture.systemPrompt.contains("API routes:"))
        XCTAssertTrue(capture.systemPrompt.contains("onyx driver: onyx.langgraph.review."))
        XCTAssertTrue(capture.systemPrompt.contains("workflows/langgraph.review/tasks"))

        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestREPLRunsGeneratedWorkflowCommandThroughLaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let line = #"start TASK-CLI --state {"topic":"runtime"}"#
        let json = try await KistRunner.renderSMLRuntimeHostREPLCommand(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            workflowID: nil,
            line: line,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let repl = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostREPLCommand.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(repl.schemaVersion, KistRunner.SMLRuntimeHostREPLCommand.currentSchemaVersion)
        XCTAssertEqual(repl.sourceFormat, .langGraphManifest)
        XCTAssertEqual(repl.workflowID, "langgraph.review")
        XCTAssertEqual(repl.availableWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(repl.line, line)
        XCTAssertFalse(repl.shouldExit)

        let command = try XCTUnwrap(repl.command)
        XCTAssertEqual(command.actor, "operator.test")
        XCTAssertEqual(command.role, "reviewer")
        XCTAssertEqual(command.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(command.task, "TASK-CLI")
        XCTAssertEqual(command.arguments["workflow_id"], .string("langgraph.review"))
        let initialState = try object(command.arguments["initial_state"])
        XCTAssertEqual(initialState["topic"], .string("runtime"))

        let result = try XCTUnwrap(repl.result)
        XCTAssertEqual(result.kind, .task)
        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.taskID, "TASK-CLI")
        XCTAssertEqual(task.role, "reviewer")
        XCTAssertEqual(task.workflowID, "langgraph.review")
        XCTAssertEqual(task.status, .waitingCapability)
        XCTAssertEqual(task.currentInstructionID, "plan")
        XCTAssertEqual(task.currentOperation, .callModel)
        XCTAssertEqual(task.state["topic"], .string("runtime"))
        XCTAssertTrue(repl.output.contains("TASK-CLI waiting_capability"))
        XCTAssertTrue(repl.output.contains("workflow: langgraph.review 1.0.0"))
        XCTAssertEqual(repl.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(repl.launchDescriptor.apiBasePaths, ["/source"])

        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testRuntimeAPIRejectsInvalidBodyJSON() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        do {
            _ = try await KistRunner.makeSMLRuntimeHostAPIExchange(
                sourcePath: "review.langgraph.json",
                projectRoot: directory.path,
                method: .post,
                path: "/source/workflows/langgraph.review/tasks",
                bodyJSON: #"{"task_id":"TASK-API""#
            )
            XCTFail("invalid API body JSON should fail")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("--sml-body must be a valid SML JSON object"))
        }
    }

    func testRuntimeREPLRejectsUnknownWorkflowID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        do {
            _ = try await KistRunner.makeSMLRuntimeHostREPLCommand(
                sourcePath: "review.langgraph.json",
                projectRoot: directory.path,
                workflowID: "langgraph.missing",
                line: "help",
                roleOverride: "reviewer"
            )
            XCTFail("unknown workflow ID should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("unknown --sml-workflow 'langgraph.missing'"))
            XCTAssertTrue(message.contains("langgraph.review"))
        }
    }

    func testRuntimePackageInputUsesLiveHostOverridesInExportAndDescriptor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)
        let sourceExport = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let packageURL = directory.appendingPathComponent("review.package.json")
        try JSONEncoder().encode(sourceExport.runtimePackage).write(to: packageURL)

        let export = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "review.package.json",
            projectRoot: directory.path,
            roleOverride: "override-reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/override",
            title: "Override Runtime",
            version: "2026.09",
            modelMaximumCommandRoundsOverride: 2
        )

        XCTAssertEqual(export.sourceFormat, .runtimeSourcePackage)
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/override"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.maximumCommandRounds, 2)
        XCTAssertEqual(export.launchDescriptor.sourceSummaries.map(\.apiBasePath), ["/override"])
        XCTAssertEqual(export.launchDescriptor.workflows.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.launchDescriptor.modelRouter.maximumCommandRounds, 2)
        XCTAssertEqual(export.hostWiring.apiBasePaths, ["/override"])
        XCTAssertEqual(export.hostWiring.workflows.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.hostWiring.modelRouter.maximumCommandRounds, 2)

        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/override/workflows/langgraph.review/tasks"])
        XCTAssertNil(paths["/source/workflows/langgraph.review/tasks"])

        let wiring = try XCTUnwrap(export.hostWiring.workflows.first)
        XCTAssertEqual(wiring.apiBasePath, "/override")
        XCTAssertTrue(wiring.apiRoutes.contains {
            $0.pathTemplate == "/override/workflows/langgraph.review/tasks"
        })
        XCTAssertFalse(wiring.apiRoutes.contains {
            $0.pathTemplate == "/source/workflows/langgraph.review/tasks"
        })
    }

    func testUnsupportedRuntimeSourceFailsClosed() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("unknown.json")
        try Data(#"{"hello":"world"}"#.utf8).write(to: sourceURL)

        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "unknown.json",
                projectRoot: directory.path
            )
            XCTFail("unsupported runtime source should fail")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("Expected a runtime source package, LangGraph manifest, or SML workflow JSON"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-sml-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func langGraphReviewManifest() -> Data {
        Data("""
        {
          "manifest_version": 1,
          "id": "langgraph.review",
          "version": "1.0.0",
          "name": "LangGraph review",
          "source_reference": "graphs/review.py",
          "source_digest": "\(String(repeating: "a", count: 64))",
          "state_schema": [
            {"name":"topic","type":"string"},
            {"name":"draft","type":"string","required":false}
          ],
          "input_fields": ["topic"],
          "output_fields": ["draft"],
          "entrypoint": "plan",
          "nodes": [
            {
              "id": "plan",
              "kind": "model",
              "purpose": "review.plan",
              "output_schema": "review.plan.v1",
              "next": "write"
            },
            {
              "id": "write",
              "kind": "tool",
              "capability": "repository.write",
              "next": "receipt"
            },
            {
              "id": "receipt",
              "kind": "receipt",
              "receipt_fields": ["draft"]
            }
          ]
        }
        """.utf8)
    }

    private func object(
        _ value: SMLValue?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SMLObject {
        guard case .object(let object) = value else {
            XCTFail("expected object", file: file, line: line)
            return [:]
        }
        return object
    }
}

private final class ScriptedSMLRuntimeProvider: ChatProvider, @unchecked Sendable {
    enum Step {
        case textAndCall(String, name: String, arguments: String)
    }

    struct Capture {
        let toolNames: [String]
        let toolChoice: ToolChoice
        let geminiBuiltins: Bool
        let systemPrompt: String
    }

    let id = "sml-scripted"
    let name = "SML Scripted"
    let iconName = "cpu"
    let requiresAPIKey = false
    let keyAccount = "sml-scripted"
    let defaultModel = "scripted-1"
    let availableModels = [AIModel(id: "scripted-1")]
    var supportsNativeTools: Bool { true }

    private let lock = NSLock()
    private var steps: [Step]
    private var lastCapture = Capture(
        toolNames: [],
        toolChoice: .auto,
        geminiBuiltins: true,
        systemPrompt: ""
    )

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func stream(
        messages: [ChatMessage],
        model: String,
        settings: ModelSettings,
        apiKey: String?
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func streamTools(
        messages: [ChatMessage],
        model: String,
        settings: ModelSettings,
        apiKey: String?,
        tools: [ToolSpec]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let step = nextStep(settings: settings, tools: tools)
        return AsyncThrowingStream { continuation in
            switch step {
            case .textAndCall(let text, let name, let arguments):
                continuation.yield(.delta(text))
                continuation.yield(.toolCall(
                    id: "call-1",
                    name: name,
                    argumentsJSON: arguments
                ))
                continuation.yield(.finish(reason: "stop"))
                continuation.finish()
            }
        }
    }

    func capture() -> Capture {
        lock.lock()
        defer { lock.unlock() }
        return lastCapture
    }

    private func nextStep(settings: ModelSettings, tools: [ToolSpec]) -> Step {
        lock.lock()
        defer { lock.unlock() }
        let step = steps.isEmpty
            ? .textAndCall(
                "No scripted step.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"help"}"#
            )
            : steps.removeFirst()
        lastCapture = Capture(
            toolNames: tools.map(\.name),
            toolChoice: settings.toolChoice,
            geminiBuiltins: settings.geminiBuiltins,
            systemPrompt: settings.systemPrompt
        )
        return step
    }
}
