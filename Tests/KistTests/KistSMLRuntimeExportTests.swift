import XCTest
import AgentCore
@testable import Kist

final class KistSMLRuntimeExportTests: XCTestCase {
    func testRuntimeExportAndREPLDispatchBeforeProviderRegistryStartup() throws {
        let source = kistRunnerFamilySource()
        let apiDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAPI != nil"))
        let launchDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeLaunch != nil"))
        let openAPIDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeOpenAPI != nil"))
        let modelRouterDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeModelRouter != nil"))
        let onyxDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeOnyx != nil"))
        let planningDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimePlanning != nil"))
        let catalogDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeCatalog != nil"))
        let mountDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeMount != nil"))
        let agentGuideDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAgentGuide != nil"))
        let hostGuideDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeHostGuide != nil"))
        let hostWiringDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeHostWiring != nil"))
        let scaffoldDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeScaffold != nil"))
        let attachmentsDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAttachments != nil"))
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
            openAPIDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime OpenAPI export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            modelRouterDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime model-router export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            onyxDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime Onyx export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            planningDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime planning export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            catalogDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime catalog export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            mountDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime mount export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            agentGuideDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime agent guide export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            hostGuideDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime host guide export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            hostWiringDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime host wiring export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            scaffoldDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime scaffold export must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            launchDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime launch descriptor must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            attachmentsDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime attachments must not initialize providers, keychain, MCP, tools, or REPL"
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
        let runtimeReplMount = try XCTUnwrap(export.runtimePackage.runtime.mountContract.replMounts.first)
        XCTAssertEqual(runtimeReplMount.commands.first { $0.verb == "start" }?.jsonBodyKind, .workflowInput)
        XCTAssertEqual(runtimeReplMount.commands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertTrue(runtimeReplMount.examples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertEqual(runtimeReplMount.commandBindings.count, 7)
        XCTAssertEqual(
            runtimeReplMount.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            "/source/workflows/langgraph.review/tasks"
        )
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.workflowMounts.map(\.apiRoutes.count), [7])
        XCTAssertEqual(
            export.runtimePackage.runtime.mountContract.workflowMounts.map(\.commandBindings.count),
            [7]
        )
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.maximumCommandRounds, 3)
        XCTAssertTrue(export.runtimePackage.runtime.modelRouter.examples.contains {
            $0.workflowID == "langgraph.review"
                && $0.arguments == [
                    "workflow_id": .string("langgraph.review"),
                    "line": .string(#"start TASK-ID {"topic":"topic"}"#),
                ]
        })
        XCTAssertEqual(export.runtimePackage.runtime.modelTools.map(\.tool.name), [SMLWorkflowModelAdapter.toolName])
        XCTAssertEqual(
            export.runtimePackage.runtime.onyxDrivers.map(\.driverID),
            export.runtimePackage.runtime.mountContract.onyxDriverIDs
        )
        let runtimeOnyxDriver = try XCTUnwrap(export.runtimePackage.runtime.onyxDrivers.first)
        XCTAssertEqual(runtimeOnyxDriver.commandBindings.count, 7)
        XCTAssertEqual(
            runtimeOnyxDriver.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            "/source/workflows/langgraph.review/tasks"
        )
        XCTAssertEqual(export.runtimePackage.runtime.planning.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(export.runtimePackage.runtime.planning.skillIndex.count, 3)
        let runtimePlanningSkill = try XCTUnwrap(
            export.runtimePackage.runtime.planning.skillIndex.first {
                $0.instructionID == "plan"
            }
        )
        XCTAssertEqual(runtimePlanningSkill.kind, .reasoning)
        XCTAssertEqual(runtimePlanningSkill.unitKind, .modelReasoning)
        XCTAssertEqual(runtimePlanningSkill.reference, "review.plan")
        XCTAssertEqual(runtimePlanningSkill.successors, ["write"])
        XCTAssertEqual(runtimePlanningSkill.outputSchema, "review.plan.v1")
        XCTAssertEqual(export.runtimePackage.runtime.planning.commandBindings.count, 7)
        let startBinding = try XCTUnwrap(export.runtimePackage.runtime.planning.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(startBinding.workflowID, "langgraph.review")
        XCTAssertEqual(startBinding.replLineTemplate, "start [TASK_ID] [JSON_INPUT_OBJECT]")
        XCTAssertEqual(startBinding.replJSONBodyKind, .workflowInput)
        XCTAssertEqual(startBinding.replJSONFields.map(\.name), ["topic"])
        XCTAssertEqual(startBinding.apiMethod, .post)
        XCTAssertEqual(startBinding.apiPathTemplate, "/source/workflows/langgraph.review/tasks")
        XCTAssertEqual(startBinding.apiOperationID, "start_workflow_task_LanggraphReview")
        XCTAssertEqual(startBinding.apiBodyKind, .startTask)
        XCTAssertTrue(startBinding.modelEligible)
        XCTAssertEqual(startBinding.modelRouterArgumentsTemplate, [
            "workflow_id": .string("langgraph.review"),
            "line": .string("start [TASK_ID] [JSON_INPUT_OBJECT]"),
        ])
        XCTAssertEqual(startBinding.exampleModelRouterArguments, [
            "workflow_id": .string("langgraph.review"),
            "line": .string(#"start TASK-ID {"topic":"topic"}"#),
        ])
        let approvalBinding = try XCTUnwrap(export.runtimePackage.runtime.planning.commandBindings.first {
            $0.action == .approve
        })
        XCTAssertEqual(approvalBinding.apiPathTemplate, "/source/workflows/langgraph.review/tasks/{task_id}/approve")
        XCTAssertEqual(approvalBinding.replJSONBodyKind, .expectedState)
        XCTAssertFalse(approvalBinding.modelEligible)
        XCTAssertNil(approvalBinding.exampleModelRouterArguments)
        let hostGuideWorkflow = try XCTUnwrap(
            export.runtimePackage.runtime.hostGuide.workflowBindings.first
        )
        XCTAssertEqual(hostGuideWorkflow.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(hostGuideWorkflow.model?.maximumCommandRounds, 3)
        XCTAssertEqual(hostGuideWorkflow.skillIndex.count, 3)
        XCTAssertEqual(
            hostGuideWorkflow.skillIndex.first { $0.instructionID == "plan" }?.reference,
            "review.plan"
        )
        XCTAssertEqual(hostGuideWorkflow.commandBindings.count, 7)
        XCTAssertEqual(
            hostGuideWorkflow.commandBindings.first { $0.action == .start }?.replJSONFields.map(\.name),
            ["topic"]
        )
        XCTAssertEqual(
            hostGuideWorkflow.commandBindings.first { $0.action == .start }?.apiBodyFields.map(\.name),
            ["topic"]
        )
        let agentGuideWorkflow = try XCTUnwrap(
            export.runtimePackage.runtime.agentGuide.workflowGuides.first
        )
        XCTAssertEqual(agentGuideWorkflow.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(agentGuideWorkflow.model?.maximumCommandRounds, 3)
        XCTAssertEqual(agentGuideWorkflow.skillIndex.count, 3)
        XCTAssertEqual(
            agentGuideWorkflow.skillIndex.first { $0.instructionID == "plan" }?.reference,
            "review.plan"
        )
        XCTAssertEqual(agentGuideWorkflow.commandBindings.count, 7)
        XCTAssertEqual(
            agentGuideWorkflow.commandBindings.first { $0.action == .start }?.replJSONFields.map(\.name),
            ["topic"]
        )
        XCTAssertTrue(
            export.runtimePackage.runtime.agentGuide.systemPrompt.contains("Skill tree:")
        )
        XCTAssertTrue(
            export.runtimePackage.runtime.agentGuide.systemPrompt.contains("Command bindings:")
        )
        let runtimeWorkflow = try XCTUnwrap(export.runtimePackage.runtime.catalog.workflows.first)
        XCTAssertEqual(runtimeWorkflow.repl.commands.first { $0.verb == "start" }?.jsonBodyKind, .workflowInput)
        XCTAssertEqual(runtimeWorkflow.repl.commands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertTrue(runtimeWorkflow.repl.examples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        let runtimeStartEndpoint = try XCTUnwrap(runtimeWorkflow.api.endpoints.first {
            $0.action == .start
        })
        XCTAssertEqual(
            runtimeStartEndpoint.examples.first?.body["input"],
            .object(["topic": .string("topic")])
        )

        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/source/workflows/langgraph.review/tasks"])
        XCTAssertNotNil(paths["/source/runtime/model-router"])
        XCTAssertNotNil(paths["/source/runtime/onyx-drivers"])
        XCTAssertNotNil(paths["/source/runtime/launch"])
        XCTAssertNotNil(paths["/source/runtime/planning"])
        XCTAssertNotNil(paths["/source/runtime/host-wiring"])
        XCTAssertNotNil(paths["/source/runtime/attachments"])
        XCTAssertNotNil(paths["/source/runtime/attachments/{workflow_id}"])
        let openAPIStartPath = try object(paths["/source/workflows/langgraph.review/tasks"])
        let openAPIStartOperation = try object(openAPIStartPath["post"])
        let openAPIOperationBinding = try object(openAPIStartOperation["x-sml-command-binding"])
        XCTAssertEqual(openAPIOperationBinding["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(openAPIOperationBinding["action"], .string("start"))
        XCTAssertEqual(
            openAPIOperationBinding["replLineTemplate"],
            .string("start [TASK_ID] [JSON_INPUT_OBJECT]")
        )
        XCTAssertEqual(
            openAPIOperationBinding["apiPathTemplate"],
            .string("/source/workflows/langgraph.review/tasks")
        )
        XCTAssertEqual(
            openAPIOperationBinding["apiOperationID"],
            .string("start_workflow_task_LanggraphReview")
        )
        XCTAssertEqual(openAPIOperationBinding["modelEligible"], .bool(true))
        XCTAssertEqual(
            openAPIOperationBinding["modelRouterToolName"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        let openAPIOperationREPLFields = try array(openAPIOperationBinding["replJSONFields"])
        XCTAssertEqual(try object(openAPIOperationREPLFields.first)["name"], .string("topic"))
        let openAPIOperationAPIFields = try array(openAPIOperationBinding["apiBodyFields"])
        XCTAssertEqual(try object(openAPIOperationAPIFields.first)["name"], .string("topic"))
        let openAPIOperationModelArguments = try object(
            openAPIOperationBinding["modelRouterArgumentsTemplate"]
        )
        XCTAssertEqual(openAPIOperationModelArguments["workflow_id"], .string("langgraph.review"))
        XCTAssertEqual(
            openAPIOperationModelArguments["line"],
            .string("start [TASK_ID] [JSON_INPUT_OBJECT]")
        )
        let openAPIRuntime = try object(export.runtimePackage.runtime.openAPI["x-sml-runtime"])
        XCTAssertEqual(openAPIRuntime["mountREPLCommandBindingCount"], .number(7))
        XCTAssertEqual(openAPIRuntime["mountWorkflowCommandBindingCount"], .number(7))
        XCTAssertEqual(openAPIRuntime["attachmentCommandBindingCount"], .number(7))
        XCTAssertEqual(openAPIRuntime["agentGuideCommandBindingCount"], .number(7))
        XCTAssertEqual(openAPIRuntime["agentGuideModelDescriptorCount"], .number(1))
        XCTAssertEqual(openAPIRuntime["agentGuideSkillIndexCount"], .number(3))
        XCTAssertEqual(openAPIRuntime["hostGuideCommandBindingCount"], .number(7))
        XCTAssertEqual(openAPIRuntime["hostGuideModelDescriptorCount"], .number(1))
        XCTAssertEqual(openAPIRuntime["hostGuideSkillIndexCount"], .number(3))
        XCTAssertEqual(openAPIRuntime["hostWiringModelDescriptorCount"], .number(1))
        XCTAssertEqual(openAPIRuntime["hostWiringSkillIndexCount"], .number(3))
        XCTAssertEqual(openAPIRuntime["attachmentModelDescriptorCount"], .number(1))
        XCTAssertEqual(openAPIRuntime["attachmentSkillIndexCount"], .number(3))
        XCTAssertEqual(openAPIRuntime["planningSkillIndexCount"], .number(3))
        let openAPIPlanningSkillIndex = try array(openAPIRuntime["planningSkillIndex"])
        XCTAssertEqual(openAPIPlanningSkillIndex.count, 3)
        let openAPIPlanningSkill = try XCTUnwrap(
            openAPIPlanningSkillIndex.compactMap { try? object($0) }.first {
                $0["instructionID"] == .string("plan")
            }
        )
        XCTAssertEqual(openAPIPlanningSkill["kind"], .string("reasoning"))
        XCTAssertEqual(openAPIPlanningSkill["reference"], .string("review.plan"))
        XCTAssertEqual(openAPIPlanningSkill["unitKind"], .string("model_reasoning"))
        let openAPICommandBindings = try array(openAPIRuntime["planningCommandBindings"])
        XCTAssertEqual(openAPICommandBindings.count, 7)
        let openAPIStartBinding = try XCTUnwrap(
            openAPICommandBindings.compactMap { try? object($0) }.first {
                $0["action"] == .string("start")
            }
        )
        XCTAssertEqual(openAPIStartBinding["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(openAPIStartBinding["action"], .string("start"))
        XCTAssertEqual(openAPIStartBinding["apiPathTemplate"], .string("/source/workflows/langgraph.review/tasks"))
        let openAPIStartREPLFields = try array(openAPIStartBinding["replJSONFields"])
        XCTAssertEqual(try object(openAPIStartREPLFields.first)["name"], .string("topic"))
        XCTAssertEqual(try object(openAPIStartREPLFields.first)["type"], .string("string"))
        XCTAssertEqual(try object(openAPIStartREPLFields.first)["required"], .bool(true))
        let openAPIStartAPIFields = try array(openAPIStartBinding["apiBodyFields"])
        XCTAssertEqual(try object(openAPIStartAPIFields.first)["name"], .string("topic"))
        XCTAssertEqual(try object(openAPIStartAPIFields.first)["type"], .string("string"))
        XCTAssertEqual(try object(openAPIStartAPIFields.first)["nullable"], .bool(false))
        XCTAssertEqual(openAPIStartBinding["modelEligible"], .bool(true))

        XCTAssertEqual(export.launchDescriptor.sourcePackageSchemaVersion, SMLWorkflowRuntimeSourcePackage.currentSchemaVersion)
        XCTAssertEqual(export.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(export.launchDescriptor.installedWorkflowIDs, ["langgraph.review"])
        XCTAssertTrue(export.launchDescriptor.launchComplete)
        XCTAssertEqual(export.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertEqual(export.launchDescriptor.hostWiring, export.hostWiring)
        XCTAssertEqual(export.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.launchDescriptor.planningWorkflowIDs, ["langgraph.review"])
        let launched = try XCTUnwrap(export.launchDescriptor.workflows.first)
        XCTAssertEqual(launched.replMount.workflowID, "langgraph.review")
        XCTAssertEqual(launched.replMount.commands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertEqual(launched.replMount.commandBindings.count, 7)
        XCTAssertEqual(launched.commandBindings, launched.replMount.commandBindings)
        XCTAssertEqual(launched.skillIndex.count, 3)
        XCTAssertEqual(launched.skillIndex.first { $0.instructionID == "plan" }?.reference, "review.plan")
        let launchedAttachment = try XCTUnwrap(launched.attachment)
        XCTAssertEqual(launchedAttachment, export.hostWiring.attachmentManifests.first)
        XCTAssertEqual(launchedAttachment.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(launchedAttachment.model?.maximumCommandRounds, 3)
        XCTAssertEqual(launchedAttachment.skillIndex, launched.skillIndex)
        XCTAssertEqual(launchedAttachment.commandBindings, launched.commandBindings)
        XCTAssertEqual(launched.apiRoutes.count, 7)
        XCTAssertEqual(
            launched.apiRoutes.first { $0.action == .start }?.examples.first?.body["input"],
            .object(["topic": .string("topic")])
        )
        XCTAssertEqual(launched.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(launched.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(
            Set(launched.hostBindingChannels),
            [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow,
            ]
        )

        XCTAssertEqual(export.hostWiring.schemaVersion, SMLWorkflowRuntimeHostWiring.currentSchemaVersion)
        XCTAssertEqual(export.hostWiring, export.runtimePackage.runtime.hostWiring)
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
        XCTAssertTrue(metadataPaths.contains("/source/runtime/host-wiring"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/launch"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/attachments"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/attachments/{workflow_id}"))

        let wiring = try XCTUnwrap(export.hostWiring.workflows.first)
        XCTAssertEqual(wiring.workflowID, "langgraph.review")
        XCTAssertEqual(wiring.role, "reviewer")
        XCTAssertEqual(wiring.apiBasePath, "/source")
        XCTAssertEqual(wiring.replMount.workflowID, "langgraph.review")
        XCTAssertTrue(wiring.replMount.examples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertEqual(wiring.replMount.commandBindings.count, 7)
        XCTAssertEqual(wiring.apiRoutes.count, 7)
        XCTAssertEqual(
            wiring.apiRoutes.first { $0.action == .start }?.examples.first?.body["input"],
            .object(["topic": .string("topic")])
        )
        XCTAssertEqual(wiring.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(wiring.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(wiring.model?.maximumCommandRounds, 3)
        XCTAssertEqual(wiring.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(wiring.onyxDriverID, export.runtimePackage.runtime.onyxDrivers.first?.driverID)
        XCTAssertEqual(wiring.planningWorkflowID, "langgraph.review")
        XCTAssertTrue(wiring.toolReferences.contains("review.plan"))
        XCTAssertTrue(wiring.toolReferences.contains("repository.write"))
        XCTAssertEqual(wiring.skillIndex.count, 3)
        XCTAssertEqual(
            wiring.skillIndex.first { $0.instructionID == "plan" }?.reference,
            "review.plan"
        )
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
                && $0.apiExamples.contains {
                    $0.path == "/source/workflows/langgraph.review/tasks"
                        && $0.body["input"] == .object(["topic": .string("topic")])
                }
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .customREPL
                && $0.replExamples.contains { $0.line == #"start TASK-ID {"topic":"topic"}"# }
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .modelRouter
                && $0.modelToolExamples.contains {
                    $0.toolName == SMLWorkflowRuntimeModelAdapter.toolName
                        && $0.workflowID == "langgraph.review"
                        && $0.arguments == [
                            "workflow_id": .string("langgraph.review"),
                            "line": .string(#"start TASK-ID {"topic":"topic"}"#),
                        ]
                }
        })
        XCTAssertEqual(wiring.commandBindings.count, 7)
        XCTAssertEqual(wiring.commandBindings, wiring.replMount.commandBindings)
        let wiringStartBinding = try XCTUnwrap(wiring.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(wiringStartBinding.replLineTemplate, "start [TASK_ID] [JSON_INPUT_OBJECT]")
        XCTAssertEqual(wiringStartBinding.apiPathTemplate, "/source/workflows/langgraph.review/tasks")
        XCTAssertEqual(wiringStartBinding.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertTrue(wiringStartBinding.modelEligible)
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .onyxDriver && $0.driverID == wiring.onyxDriverID
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .planningWorkflow && $0.planningWorkflowID == wiring.planningWorkflowID
        })
        XCTAssertEqual(wiring.attachment.workflowID, "langgraph.review")
        XCTAssertEqual(wiring.attachment.apiBasePath, "/source")
        XCTAssertEqual(wiring.attachment.plannerEntrypoint, "plan")
        XCTAssertEqual(wiring.attachment.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(wiring.attachment.model, wiring.model)
        XCTAssertEqual(wiring.attachment.skillTree.map(\.id), ["plan", "write", "receipt"])
        XCTAssertEqual(wiring.attachment.skillIndex, wiring.skillIndex)
        XCTAssertEqual(wiring.attachment.toolBindings.map(\.reference), [
            "review.plan", "repository.write",
        ])
        XCTAssertEqual(wiring.attachment.plan?.entrypoint, "plan")
        XCTAssertEqual(wiring.attachment.plan?.nodes.count, 3)
        XCTAssertEqual(wiring.attachment.commandBindings, wiring.commandBindings)
        XCTAssertTrue(wiring.attachment.apiExamples.contains {
            $0.path == "/source/workflows/langgraph.review/tasks"
                && $0.body["input"] == .object(["topic": .string("topic")])
        })
        XCTAssertTrue(wiring.attachment.modelRouterExamples.contains {
            $0.toolName == SMLWorkflowRuntimeModelAdapter.toolName
                && $0.workflowID == "langgraph.review"
                && $0.arguments == [
                    "workflow_id": .string("langgraph.review"),
                    "line": .string(#"start TASK-ID {"topic":"topic"}"#),
                ]
        })
        XCTAssertEqual(wiring.attachment.onyxDriverID, wiring.onyxDriverID)

        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestPrintsModelRouterOnyxAndPlanningDescriptors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let modelRouterJSON = try await KistRunner.renderSMLRuntimeHostModelRouter(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let modelRouter = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelRouterExport.self,
            from: Data(modelRouterJSON.utf8)
        )
        XCTAssertEqual(modelRouter.schemaVersion, KistRunner.SMLRuntimeHostModelRouterExport.currentSchemaVersion)
        XCTAssertEqual(modelRouter.sourcePath, manifestURL.path)
        XCTAssertEqual(modelRouter.sourceFormat, .langGraphManifest)
        XCTAssertEqual(modelRouter.apiBasePaths, ["/source"])
        XCTAssertEqual(modelRouter.modelRouterEndpoint?.pathTemplate, "/source/runtime/model-router")
        XCTAssertEqual(modelRouter.modelRouterEndpoint?.resource, .modelRouter)
        XCTAssertTrue(modelRouter.modelRouter.requiresNativeTools)
        XCTAssertEqual(modelRouter.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(modelRouter.modelRouter.tool.parameters.map(\.name), ["workflow_id", "line"])
        XCTAssertEqual(modelRouter.modelRouter.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(modelRouter.modelRouter.maximumCommandRounds, 3)
        XCTAssertTrue(modelRouter.modelRouter.examples.contains {
            $0.toolName == SMLWorkflowRuntimeModelAdapter.toolName
                && $0.workflowID == "langgraph.review"
                && $0.arguments == [
                    "workflow_id": .string("langgraph.review"),
                    "line": .string(#"start TASK-ID {"topic":"topic"}"#),
                ]
        })
        XCTAssertEqual(modelRouter.launchDescriptor.modelRouter, modelRouter.modelRouter)
        XCTAssertTrue(modelRouter.launchDescriptor.launchComplete)
        XCTAssertFalse(modelRouterJSON.contains("operator.test"))
        XCTAssertFalse(modelRouterJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(modelRouterJSON.contains("authenticatedActor"))

        let onyxJSON = try await KistRunner.renderSMLRuntimeHostOnyxDrivers(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            workflowID: "langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let onyx = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostOnyxDrivers.self,
            from: Data(onyxJSON.utf8)
        )
        XCTAssertEqual(onyx.schemaVersion, KistRunner.SMLRuntimeHostOnyxDrivers.currentSchemaVersion)
        XCTAssertEqual(onyx.sourcePath, manifestURL.path)
        XCTAssertEqual(onyx.workflowID, "langgraph.review")
        XCTAssertEqual(onyx.availableWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(onyx.apiBasePaths, ["/source"])
        XCTAssertEqual(onyx.onyxDriversEndpoint?.pathTemplate, "/source/runtime/onyx-drivers")
        XCTAssertEqual(onyx.onyxDriversEndpoint?.resource, .onyxDrivers)
        XCTAssertEqual(onyx.onyxDrivers.map(\.workflowID), ["langgraph.review"])
        let driver = try XCTUnwrap(onyx.onyxDrivers.first)
        XCTAssertEqual(driver.schemaVersion, SMLOnyxDriverManifest.currentSchemaVersion)
        XCTAssertEqual(driver.providerFamily, "onyx")
        XCTAssertEqual(driver.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(driver.api.basePath, "/source")
        XCTAssertEqual(driver.skillTree.map(\.id), ["plan", "write", "receipt"])
        XCTAssertEqual(driver.tools.map(\.reference), ["review.plan", "repository.write"])
        XCTAssertEqual(driver.plan.entrypoint, "plan")
        XCTAssertEqual(driver.commandBindings.count, 7)
        XCTAssertEqual(onyx.launchDescriptor.onyxDriverIDs, onyx.onyxDrivers.map(\.driverID))
        XCTAssertFalse(onyxJSON.contains("operator.test"))
        XCTAssertFalse(onyxJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(onyxJSON.contains("authenticatedActor"))

        let planningJSON = try await KistRunner.renderSMLRuntimeHostPlanning(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let planning = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostPlanningExport.self,
            from: Data(planningJSON.utf8)
        )
        XCTAssertEqual(planning.schemaVersion, KistRunner.SMLRuntimeHostPlanningExport.currentSchemaVersion)
        XCTAssertEqual(planning.sourcePath, manifestURL.path)
        XCTAssertEqual(planning.sourceFormat, .langGraphManifest)
        XCTAssertEqual(planning.apiBasePaths, ["/source"])
        XCTAssertEqual(planning.planningEndpoint?.pathTemplate, "/source/runtime/planning")
        XCTAssertEqual(planning.planningEndpoint?.resource, .planning)
        XCTAssertEqual(planning.planning.schemaVersion, SMLWorkflowRuntimePlanningManifest.currentSchemaVersion)
        XCTAssertEqual(planning.planning.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(planning.planning.workflows.map(\.entrypoint), ["plan"])
        XCTAssertEqual(planning.planning.skillIndex.count, 3)
        XCTAssertEqual(planning.planning.toolIndex.map(\.reference), ["review.plan", "repository.write"])
        XCTAssertTrue(planning.planning.decomposableUnits.isEmpty)
        XCTAssertTrue(planning.planning.approvalGates.isEmpty)
        XCTAssertEqual(planning.planning.commandBindings.count, 7)
        XCTAssertEqual(planning.launchDescriptor.planningWorkflowIDs, planning.planning.workflowIDs)
        XCTAssertTrue(planning.launchDescriptor.launchComplete)
        XCTAssertFalse(planningJSON.contains("operator.test"))
        XCTAssertFalse(planningJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(planningJSON.contains("authenticatedActor"))
    }

    func testLangGraphManifestPrintsCatalogMountAndGuideDescriptors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        func assertDescriptorOnly(_ json: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(json.contains("operator.test"), file: file, line: line)
            XCTAssertFalse(json.contains("sml-runtime-export-lease"), file: file, line: line)
            XCTAssertFalse(json.contains("authenticatedActor"), file: file, line: line)
        }

        let catalogJSON = try await KistRunner.renderSMLRuntimeHostCatalog(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let catalog = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostCatalogExport.self,
            from: Data(catalogJSON.utf8)
        )
        XCTAssertEqual(catalog.schemaVersion, KistRunner.SMLRuntimeHostCatalogExport.currentSchemaVersion)
        XCTAssertEqual(catalog.sourcePath, manifestURL.path)
        XCTAssertEqual(catalog.sourceFormat, .langGraphManifest)
        XCTAssertEqual(catalog.apiBasePaths, ["/source"])
        XCTAssertEqual(catalog.catalogEndpoint?.pathTemplate, "/source/runtime/catalog")
        XCTAssertEqual(catalog.catalogEndpoint?.resource, .catalog)
        XCTAssertEqual(catalog.catalog.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(catalog.catalog.onyxDrivers.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(catalog.launchDescriptor.workflowIDs, catalog.catalog.workflowIDs)
        XCTAssertEqual(catalog.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertTrue(catalog.launchDescriptor.launchComplete)
        assertDescriptorOnly(catalogJSON)

        let mountJSON = try await KistRunner.renderSMLRuntimeHostMount(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let mount = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostMountExport.self,
            from: Data(mountJSON.utf8)
        )
        XCTAssertEqual(mount.schemaVersion, KistRunner.SMLRuntimeHostMountExport.currentSchemaVersion)
        XCTAssertEqual(mount.sourcePath, manifestURL.path)
        XCTAssertEqual(mount.sourceFormat, .langGraphManifest)
        XCTAssertEqual(mount.apiBasePaths, ["/source"])
        XCTAssertEqual(mount.mountEndpoint?.pathTemplate, "/source/runtime/mount")
        XCTAssertEqual(mount.mountEndpoint?.resource, .mount)
        XCTAssertEqual(mount.mountContract.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(mount.mountContract.apiBasePaths, ["/source"])
        XCTAssertEqual(mount.mountContract.apiRoutes.count, 20)
        XCTAssertEqual(mount.mountContract.replMounts.first?.workflowID, "langgraph.review")
        XCTAssertEqual(mount.mountContract.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(mount.mountContract.planningWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(mount.launchDescriptor.apiBasePaths, mount.mountContract.apiBasePaths)
        XCTAssertTrue(mount.launchDescriptor.launchComplete)
        assertDescriptorOnly(mountJSON)

        let agentGuideJSON = try await KistRunner.renderSMLRuntimeHostAgentGuide(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let agentGuide = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAgentGuideExport.self,
            from: Data(agentGuideJSON.utf8)
        )
        XCTAssertEqual(
            agentGuide.schemaVersion,
            KistRunner.SMLRuntimeHostAgentGuideExport.currentSchemaVersion
        )
        XCTAssertEqual(agentGuide.sourcePath, manifestURL.path)
        XCTAssertEqual(agentGuide.sourceFormat, .langGraphManifest)
        XCTAssertEqual(agentGuide.apiBasePaths, ["/source"])
        XCTAssertEqual(agentGuide.agentGuideEndpoint?.pathTemplate, "/source/runtime/agent-guide")
        XCTAssertEqual(agentGuide.agentGuideEndpoint?.resource, .agentGuide)
        XCTAssertEqual(agentGuide.agentGuide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(agentGuide.agentGuide.workflowGuides.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(agentGuide.agentGuide.workflowGuides.first?.commandBindings.count, 7)
        XCTAssertEqual(agentGuide.agentGuide.workflowGuides.first?.skillIndex.count, 3)
        XCTAssertTrue(agentGuide.agentGuide.systemPrompt.contains("Skill tree:"))
        XCTAssertTrue(agentGuide.launchDescriptor.launchComplete)
        assertDescriptorOnly(agentGuideJSON)

        let hostGuideJSON = try await KistRunner.renderSMLRuntimeHostGuide(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let hostGuide = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostGuideExport.self,
            from: Data(hostGuideJSON.utf8)
        )
        XCTAssertEqual(hostGuide.schemaVersion, KistRunner.SMLRuntimeHostGuideExport.currentSchemaVersion)
        XCTAssertEqual(hostGuide.sourcePath, manifestURL.path)
        XCTAssertEqual(hostGuide.sourceFormat, .langGraphManifest)
        XCTAssertEqual(hostGuide.apiBasePaths, ["/source"])
        XCTAssertEqual(hostGuide.hostGuideEndpoint?.pathTemplate, "/source/runtime/host-guide")
        XCTAssertEqual(hostGuide.hostGuideEndpoint?.resource, .hostGuide)
        XCTAssertEqual(hostGuide.hostGuide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(hostGuide.hostGuide.workflowBindings.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(hostGuide.hostGuide.workflowBindings.first?.commandBindings.count, 7)
        XCTAssertEqual(hostGuide.hostGuide.workflowBindings.first?.skillIndex.count, 3)
        XCTAssertTrue(hostGuide.hostGuide.requiredHostServices.contains("host_command_gateway"))
        XCTAssertFalse(hostGuide.hostGuide.launchSteps.isEmpty)
        XCTAssertTrue(hostGuide.launchDescriptor.launchComplete)
        assertDescriptorOnly(hostGuideJSON)

        let hostWiringJSON = try await KistRunner.renderSMLRuntimeHostWiring(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let hostWiring = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostWiringExport.self,
            from: Data(hostWiringJSON.utf8)
        )
        XCTAssertEqual(hostWiring.schemaVersion, KistRunner.SMLRuntimeHostWiringExport.currentSchemaVersion)
        XCTAssertEqual(hostWiring.sourcePath, manifestURL.path)
        XCTAssertEqual(hostWiring.sourceFormat, .langGraphManifest)
        XCTAssertEqual(hostWiring.apiBasePaths, ["/source"])
        XCTAssertEqual(hostWiring.hostWiringEndpoint?.pathTemplate, "/source/runtime/host-wiring")
        XCTAssertEqual(hostWiring.hostWiringEndpoint?.resource, .hostWiring)
        XCTAssertEqual(hostWiring.hostWiring.apiBasePaths, ["/source"])
        XCTAssertEqual(hostWiring.hostWiring.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(hostWiring.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(hostWiring.hostWiring.workflows.first?.commandBindings.count, 7)
        XCTAssertEqual(hostWiring.hostWiring.workflows.first?.skillIndex.count, 3)
        XCTAssertEqual(hostWiring.hostWiring.attachmentManifests.first?.workflowID, "langgraph.review")
        XCTAssertEqual(hostWiring.launchDescriptor.hostWiring, hostWiring.hostWiring)
        XCTAssertTrue(hostWiring.launchDescriptor.launchComplete)
        assertDescriptorOnly(hostWiringJSON)
    }

    func testLangGraphManifestScaffoldWritesHostConsumableRuntimeDirectory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)
        let outputURL = directory.appendingPathComponent("runtime-scaffold", isDirectory: true)

        let json = try await KistRunner.renderSMLRuntimeHostScaffold(
            sourcePath: "review.langgraph.json",
            outputDirectory: "runtime-scaffold",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let scaffold = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffold.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(scaffold.schemaVersion, KistRunner.SMLRuntimeHostScaffold.currentSchemaVersion)
        XCTAssertEqual(scaffold.sourcePath, manifestURL.path)
        XCTAssertEqual(scaffold.sourceFormat, .langGraphManifest)
        XCTAssertEqual(scaffold.outputDirectory, outputURL.path)
        XCTAssertEqual(scaffold.indexPath, "scaffold.json")
        XCTAssertEqual(scaffold.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(scaffold.apiBasePaths, ["/source"])
        XCTAssertTrue(scaffold.launchDescriptor.launchComplete)

        let expectedPaths: Set<String> = [
            "README.md",
            "agent-guide.json",
            "attachments.json",
            "attachments/langgraph.review.json",
            "catalog.json",
            "host-guide.json",
            "host-wiring.json",
            "launch.json",
            "model-router.json",
            "model-tools.json",
            "mount.json",
            "onyx-drivers.json",
            "openapi.json",
            "planning.json",
            "runtime-export.json",
            "runtime-source-package.json",
        ]
        XCTAssertEqual(Set(scaffold.files.map(\.relativePath)), expectedPaths)
        let indexURL = outputURL.appendingPathComponent(scaffold.indexPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        let index = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffold.self,
            from: Data(contentsOf: indexURL)
        )
        XCTAssertEqual(index, scaffold)

        for file in scaffold.files {
            let fileURL = outputURL.appendingPathComponent(file.relativePath)
            let data = try Data(contentsOf: fileURL)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertEqual(file.path, fileURL.path)
            XCTAssertEqual(file.byteCount, data.count)
            XCTAssertEqual(file.sha256, BuilderEvidenceDigest.sha256(text))
            XCTAssertFalse(text.contains("operator.test"), file.relativePath)
            XCTAssertFalse(text.contains("sml-runtime-export-lease"), file.relativePath)
            XCTAssertFalse(text.contains("authenticatedActor"), file.relativePath)
        }
        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))

        let catalog = try JSONDecoder().decode(
            SMLWorkflowRuntimeCatalog.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("catalog.json"))
        )
        XCTAssertEqual(catalog.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(catalog.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)

        let mount = try JSONDecoder().decode(
            SMLWorkflowRuntimeMountContract.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("mount.json"))
        )
        XCTAssertEqual(mount.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(mount.apiRoutes.count, 20)
        XCTAssertEqual(mount.modelRouter.maximumCommandRounds, 3)

        let runtimeExport = try JSONDecoder().decode(
            SMLWorkflowRuntimeExport.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("runtime-export.json"))
        )
        XCTAssertEqual(runtimeExport.catalog.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(runtimeExport.mountContract, mount)

        let runtimePackage = try JSONDecoder().decode(
            SMLWorkflowRuntimeSourcePackage.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("runtime-source-package.json"))
        )
        XCTAssertEqual(runtimePackage.normalizedWorkflows.map(\.id), ["langgraph.review"])
        XCTAssertEqual(runtimePackage.runtime.catalog.workflowIDs, ["langgraph.review"])

        let openAPI = try JSONDecoder().decode(
            SMLObject.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("openapi.json"))
        )
        XCTAssertEqual(openAPI["openapi"], .string("3.1.0"))
        let paths = try object(openAPI["paths"])
        XCTAssertNotNil(paths["/source/workflows/langgraph.review/tasks"])
        XCTAssertNotNil(paths["/source/runtime/host-wiring"])

        let modelTools = try JSONDecoder().decode(
            [SMLWorkflowRuntimeModelToolExport].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("model-tools.json"))
        )
        XCTAssertEqual(modelTools.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(modelTools.first?.tool.name, SMLWorkflowModelAdapter.toolName)

        let modelRouter = try JSONDecoder().decode(
            SMLWorkflowRuntimeModelRouterDescriptor.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("model-router.json"))
        )
        XCTAssertEqual(modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(modelRouter.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(modelRouter.maximumCommandRounds, 3)

        let onyxDrivers = try JSONDecoder().decode(
            [SMLOnyxDriverManifest].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("onyx-drivers.json"))
        )
        XCTAssertEqual(onyxDrivers.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(onyxDrivers.first?.skillTree.map(\.id), ["plan", "write", "receipt"])

        let planning = try JSONDecoder().decode(
            SMLWorkflowRuntimePlanningManifest.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("planning.json"))
        )
        XCTAssertEqual(planning.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(planning.skillIndex.count, 3)
        XCTAssertEqual(planning.commandBindings.count, 7)

        let agentGuide = try JSONDecoder().decode(
            SMLWorkflowRuntimeAgentGuide.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("agent-guide.json"))
        )
        XCTAssertEqual(agentGuide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(agentGuide.workflowGuides.map(\.workflowID), ["langgraph.review"])

        let hostGuide = try JSONDecoder().decode(
            SMLWorkflowRuntimeHostGuide.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("host-guide.json"))
        )
        XCTAssertEqual(hostGuide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(hostGuide.workflowBindings.map(\.workflowID), ["langgraph.review"])

        let hostWiring = try JSONDecoder().decode(
            SMLWorkflowRuntimeHostWiring.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("host-wiring.json"))
        )
        XCTAssertEqual(hostWiring.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(hostWiring.workflows.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(hostWiring.attachmentManifests.first?.workflowID, "langgraph.review")

        let attachments = try JSONDecoder().decode(
            [SMLWorkflowRuntimeWorkflowAttachmentManifest].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("attachments.json"))
        )
        let attachment = try JSONDecoder().decode(
            SMLWorkflowRuntimeWorkflowAttachmentManifest.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("attachments/langgraph.review.json"))
        )
        XCTAssertEqual(attachments, [attachment])
        XCTAssertEqual(attachment.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(attachment.skillIndex.count, 3)
        XCTAssertEqual(attachment.commandBindings.count, 7)

        let readme = try String(contentsOf: outputURL.appendingPathComponent("README.md"))
        XCTAssertTrue(readme.contains("Host wiring order"))
        XCTAssertTrue(readme.contains("State changes still have to cross the generated host command gateway"))

        let replFromDirectoryJSON = try await KistRunner.renderSMLRuntimeHostREPLCommand(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            line: #"start TASK-SCAFFOLD {"topic":"runtime"}"#,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let replFromDirectory = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostREPLCommand.self,
            from: Data(replFromDirectoryJSON.utf8)
        )
        XCTAssertEqual(replFromDirectory.sourcePath, indexURL.path)
        XCTAssertEqual(replFromDirectory.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(replFromDirectory.workflowID, "langgraph.review")
        XCTAssertEqual(replFromDirectory.command?.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(replFromDirectory.result?.kind, .task)
        XCTAssertEqual(replFromDirectory.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertFalse(replFromDirectoryJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(replFromDirectoryJSON.contains("authenticatedActor"))

        let apiFromIndexJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "runtime-scaffold/scaffold.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/host-wiring",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let apiFromIndex = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(apiFromIndexJSON.utf8)
        )
        XCTAssertEqual(apiFromIndex.sourcePath, indexURL.path)
        XCTAssertEqual(apiFromIndex.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(apiFromIndex.statusCode, 200)
        XCTAssertEqual(apiFromIndex.metadataResource, .hostWiring)
        let apiWiringBody = try object(apiFromIndex.responseBody)
        XCTAssertEqual(apiWiringBody["apiBasePaths"], .array([.string("/source")]))
        XCTAssertFalse(apiFromIndexJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(apiFromIndexJSON.contains("authenticatedActor"))

        let modelRouterFromDirectoryJSON = try await KistRunner.renderSMLRuntimeHostModelRouter(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let modelRouterFromDirectory = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelRouterExport.self,
            from: Data(modelRouterFromDirectoryJSON.utf8)
        )
        XCTAssertEqual(modelRouterFromDirectory.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(modelRouterFromDirectory.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(modelRouterFromDirectory.modelRouter.workflowIDs, ["langgraph.review"])

        let onyxFromDirectoryJSON = try await KistRunner.renderSMLRuntimeHostOnyxDrivers(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            workflowID: "langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let onyxFromDirectory = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostOnyxDrivers.self,
            from: Data(onyxFromDirectoryJSON.utf8)
        )
        XCTAssertEqual(onyxFromDirectory.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(onyxFromDirectory.onyxDrivers.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(onyxFromDirectory.onyxDrivers.first?.skillTree.map(\.id), ["plan", "write", "receipt"])

        let planningFromDirectoryJSON = try await KistRunner.renderSMLRuntimeHostPlanning(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let planningFromDirectory = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostPlanningExport.self,
            from: Data(planningFromDirectoryJSON.utf8)
        )
        XCTAssertEqual(planningFromDirectory.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(planningFromDirectory.planning.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(planningFromDirectory.planning.commandBindings.count, 7)

        try "{}".write(
            to: outputURL.appendingPathComponent("runtime-source-package.json"),
            atomically: true,
            encoding: .utf8
        )
        do {
            _ = try await KistRunner.renderSMLRuntimeHostPlanning(
                sourcePath: "runtime-scaffold",
                projectRoot: directory.path
            )
            XCTFail("scaffold reuse should fail closed when runtime-source-package.json drifts")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("runtime-source-package.json byte count changed"),
                String(describing: error)
            )
        }

        let occupiedURL = directory.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: occupiedURL, withIntermediateDirectories: true)
        try "keep".write(
            to: occupiedURL.appendingPathComponent("keep.txt"),
            atomically: true,
            encoding: .utf8
        )
        do {
            _ = try await KistRunner.renderSMLRuntimeHostScaffold(
                sourcePath: "review.langgraph.json",
                outputDirectory: "occupied",
                projectRoot: directory.path
            )
            XCTFail("scaffold should fail closed rather than overwrite a non-empty output directory")
        } catch {
            XCTAssertTrue(String(describing: error).contains("refuses to overwrite non-empty directory"))
        }
    }

    func testLangGraphManifestOpenAPIPrintsAPIDocument() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostOpenAPI(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let openAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostOpenAPIExport.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(openAPI.schemaVersion, KistRunner.SMLRuntimeHostOpenAPIExport.currentSchemaVersion)
        XCTAssertEqual(openAPI.sourcePath, manifestURL.path)
        XCTAssertEqual(openAPI.sourceFormat, .langGraphManifest)
        XCTAssertEqual(openAPI.apiBasePaths, ["/source"])
        XCTAssertEqual(openAPI.openAPIEndpoint?.pathTemplate, "/source/runtime/openapi")
        XCTAssertEqual(openAPI.openAPIEndpoint?.resource, .openAPI)
        XCTAssertEqual(openAPI.openAPI["openapi"], .string("3.1.0"))
        let info = try object(openAPI.openAPI["info"])
        XCTAssertEqual(info["title"], .string("Source Runtime"))
        XCTAssertEqual(info["version"], .string("2026.08"))
        let paths = try object(openAPI.openAPI["paths"])
        XCTAssertNotNil(paths["/source/runtime/openapi"])
        XCTAssertNotNil(paths["/source/runtime/launch"])
        XCTAssertNotNil(paths["/source/runtime/model-router"])
        XCTAssertNotNil(paths["/source/runtime/onyx-drivers"])
        XCTAssertNotNil(paths["/source/runtime/planning"])
        XCTAssertNotNil(paths["/source/workflows/langgraph.review/tasks"])
        let openAPIPath = try object(paths["/source/runtime/openapi"])
        let getOpenAPI = try object(openAPIPath["get"])
        XCTAssertEqual(
            getOpenAPI["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.openAPI.operationID)
        )
        XCTAssertEqual(getOpenAPI["x-sml-runtime-resource"], .string("openapi"))
        XCTAssertEqual(getOpenAPI["x-sml-read-only"], .bool(true))
        let startPath = try object(paths["/source/workflows/langgraph.review/tasks"])
        let start = try object(startPath["post"])
        XCTAssertEqual(start["operationId"], .string("start_workflow_task_LanggraphReview"))
        XCTAssertEqual(start["x-sml-model-router-tool"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertEqual(start["x-sml-action"], .string("start"))
        let runtime = try object(openAPI.openAPI["x-sml-runtime"])
        XCTAssertEqual(runtime["workflowIDs"], .array([.string("langgraph.review")]))
        XCTAssertEqual(runtime["modelRouterToolName"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertEqual(runtime["mountAPIRouteCount"], .number(Decimal(20)))
        XCTAssertEqual(runtime["planningSkillIndexCount"], .number(Decimal(3)))
        XCTAssertEqual(openAPI.launchDescriptor.launchComplete, true)
        XCTAssertEqual(openAPI.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(openAPI.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestLaunchPrintsLaunchDescriptor() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostLaunchDescriptor(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let launch = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostLaunchDescriptor.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(launch.schemaVersion, KistRunner.SMLRuntimeHostLaunchDescriptor.currentSchemaVersion)
        XCTAssertEqual(launch.sourcePath, manifestURL.path)
        XCTAssertEqual(launch.sourceFormat, .langGraphManifest)
        XCTAssertEqual(launch.apiBasePaths, ["/source"])
        XCTAssertEqual(launch.launchEndpoint?.pathTemplate, "/source/runtime/launch")
        XCTAssertEqual(launch.launchEndpoint?.resource, .launch)
        XCTAssertEqual(
            launch.launchDescriptor.sourcePackageSchemaVersion,
            SMLWorkflowRuntimeSourcePackage.currentSchemaVersion
        )
        XCTAssertEqual(
            launch.launchDescriptor.runtimeExportSchemaVersion,
            SMLWorkflowRuntimeExport.currentSchemaVersion
        )
        XCTAssertEqual(launch.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(launch.launchDescriptor.installedWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(launch.launchDescriptor.missingInstalledWorkflowIDs, [])
        XCTAssertEqual(launch.launchDescriptor.unexpectedInstalledWorkflowIDs, [])
        XCTAssertTrue(launch.launchDescriptor.launchComplete)
        XCTAssertEqual(launch.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertEqual(launch.launchDescriptor.metadataEndpoints.count, 13)
        XCTAssertEqual(
            launch.launchDescriptor.metadataEndpoints.first { $0.resource == .launch }?.pathTemplate,
            "/source/runtime/launch"
        )
        XCTAssertEqual(launch.launchDescriptor.workflows.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(launch.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(launch.launchDescriptor.planningWorkflowIDs, ["langgraph.review"])
        XCTAssertFalse(launch.launchDescriptor.requiredHostServices.isEmpty)
        XCTAssertFalse(launch.launchDescriptor.launchSteps.isEmpty)
        XCTAssertEqual(launch.launchDescriptor.sourceSummaries.map(\.workflowID), ["langgraph.review"])
        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestAttachmentsPrintsWorkflowAttachmentPackage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostAttachments(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let attachments = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAttachments.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(attachments.schemaVersion, KistRunner.SMLRuntimeHostAttachments.currentSchemaVersion)
        XCTAssertEqual(attachments.sourceFormat, .langGraphManifest)
        XCTAssertNil(attachments.workflowID)
        XCTAssertEqual(attachments.availableWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(attachments.apiBasePaths, ["/source"])
        XCTAssertEqual(attachments.attachmentEndpoint?.pathTemplate, "/source/runtime/attachments")
        XCTAssertEqual(attachments.attachmentEndpoint?.resource, .attachments)
        XCTAssertEqual(attachments.attachments.map(\.workflowID), ["langgraph.review"])
        let attachment = try XCTUnwrap(attachments.attachments.first)
        XCTAssertEqual(attachment.workflowName, "LangGraph review")
        XCTAssertEqual(attachment.apiBasePath, "/source")
        XCTAssertEqual(attachment.plannerEntrypoint, "plan")
        XCTAssertEqual(attachment.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(attachment.model?.maximumCommandRounds, 3)
        XCTAssertEqual(attachment.channels, [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow,
        ])
        XCTAssertEqual(attachment.skillTree.map(\.id), ["plan", "write", "receipt"])
        XCTAssertEqual(attachment.skillTree.first { $0.id == "write" }?.planning?.unitKind, .externalCapability)
        XCTAssertEqual(attachment.skillIndex.count, 3)
        XCTAssertEqual(attachment.skillIndex.first { $0.instructionID == "plan" }?.reference, "review.plan")
        XCTAssertEqual(attachment.toolBindings.map(\.reference), [
            "review.plan", "repository.write",
        ])
        XCTAssertEqual(attachment.plan?.entrypoint, "plan")
        XCTAssertEqual(attachment.plan?.nodes.map(\.id), ["plan", "write", "receipt"])
        XCTAssertEqual(attachment.commandBindings.count, 7)
        XCTAssertEqual(
            attachment.commandBindings.first { $0.action == .start }?.apiBodyFields.map(\.name),
            ["topic"]
        )
        XCTAssertTrue(attachment.replExamples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertTrue(attachment.apiExamples.contains {
            $0.path == "/source/workflows/langgraph.review/tasks"
                && $0.body["input"] == .object(["topic": .string("topic")])
        })
        XCTAssertTrue(attachment.modelRouterExamples.contains {
            $0.arguments == [
                "workflow_id": .string("langgraph.review"),
                "line": .string(#"start TASK-ID {"topic":"topic"}"#),
            ]
        })
        XCTAssertEqual(attachments.launchDescriptor.hostWiring.attachmentManifests, attachments.attachments)
        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))

        let filteredJSON = try await KistRunner.renderSMLRuntimeHostAttachments(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            workflowID: "langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let filtered = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAttachments.self,
            from: Data(filteredJSON.utf8)
        )
        XCTAssertEqual(filtered.workflowID, "langgraph.review")
        XCTAssertEqual(filtered.availableWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(filtered.attachments.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(filtered.attachments.first?.skillTree.map(\.id), ["plan", "write", "receipt"])
        XCTAssertEqual(filtered.attachments.first?.skillIndex.count, 3)
        XCTAssertFalse(filteredJSON.contains("operator.test"))
        XCTAssertFalse(filteredJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(filteredJSON.contains("authenticatedActor"))
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
        let skillIndex = try array(planning["skillIndex"])
        XCTAssertEqual(skillIndex.count, 3)
        let metadataPlanningSkill = try XCTUnwrap(
            skillIndex.compactMap { try? object($0) }.first {
                $0["instructionID"] == .string("plan")
            }
        )
        XCTAssertEqual(metadataPlanningSkill["kind"], .string("reasoning"))
        XCTAssertEqual(metadataPlanningSkill["unitKind"], .string("model_reasoning"))
        XCTAssertEqual(metadataPlanningSkill["successors"], .array([.string("write")]))
        let commandBindings = try array(planning["commandBindings"])
        XCTAssertEqual(commandBindings.count, 7)
        let metadataStartBinding = try XCTUnwrap(
            commandBindings.compactMap { try? object($0) }.first {
                $0["action"] == .string("start")
            }
        )
        XCTAssertEqual(
            metadataStartBinding["replLineTemplate"],
            .string("start [TASK_ID] [JSON_INPUT_OBJECT]")
        )
        XCTAssertEqual(
            metadataStartBinding["apiPathTemplate"],
            .string("/source/workflows/langgraph.review/tasks")
        )
        XCTAssertEqual(metadataStartBinding["modelEligible"], .bool(true))
        XCTAssertEqual(api.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertEqual(api.launchDescriptor.hostWiring.apiBasePaths, ["/source"])
        XCTAssertEqual(api.launchDescriptor.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])

        let launchJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/launch",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let launchAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(launchJSON.utf8)
        )
        XCTAssertEqual(launchAPI.statusCode, 200)
        XCTAssertEqual(launchAPI.kind, .metadata)
        XCTAssertEqual(launchAPI.metadataResource, .launch)
        XCTAssertEqual(launchAPI.route?.operationID, SMLWorkflowRuntimeMetadataResource.launch.operationID)
        XCTAssertNil(launchAPI.command)
        XCTAssertNil(launchAPI.result)
        let launchBody = try object(launchAPI.responseBody)
        XCTAssertEqual(launchBody["launchComplete"], .bool(true))
        XCTAssertEqual(try array(launchBody["workflowIDs"]), [.string("langgraph.review")])
        XCTAssertEqual(try array(launchBody["installedWorkflowIDs"]), [.string("langgraph.review")])
        XCTAssertTrue(try array(launchBody["missingInstalledWorkflowIDs"]).isEmpty)
        XCTAssertEqual(try array(launchBody["workflows"]).count, 1)
        XCTAssertFalse(launchJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(launchJSON.contains("authenticatedActor"))

        let wiringJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/host-wiring",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let wiringAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(wiringJSON.utf8)
        )
        XCTAssertEqual(wiringAPI.statusCode, 200)
        XCTAssertEqual(wiringAPI.kind, .metadata)
        XCTAssertEqual(wiringAPI.metadataResource, .hostWiring)
        XCTAssertEqual(wiringAPI.route?.operationID, SMLWorkflowRuntimeMetadataResource.hostWiring.operationID)
        XCTAssertNil(wiringAPI.command)
        XCTAssertNil(wiringAPI.result)
        let wiringBody = try object(wiringAPI.responseBody)
        XCTAssertEqual(
            wiringBody["schemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeHostWiring.currentSchemaVersion))
        )
        XCTAssertEqual(wiringBody["apiBasePaths"], .array([.string("/source")]))
        if case .array(let workflows) = wiringBody["workflows"] {
            XCTAssertEqual(workflows.count, 1)
            let workflow = try object(workflows.first)
            XCTAssertEqual(try array(workflow["skillIndex"]).count, 3)
            XCTAssertEqual(
                try object(try object(workflow["model"])["tool"])["name"],
                .string(SMLWorkflowModelAdapter.toolName)
            )
            XCTAssertEqual(try array(workflow["commandBindings"]).count, 7)
        } else {
            XCTFail("expected host-wiring workflows array")
        }
        XCTAssertFalse(wiringJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(wiringJSON.contains("authenticatedActor"))

        let attachmentsJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/attachments",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let attachmentsAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(attachmentsJSON.utf8)
        )
        XCTAssertEqual(attachmentsAPI.statusCode, 200)
        XCTAssertEqual(attachmentsAPI.kind, .metadata)
        XCTAssertEqual(attachmentsAPI.metadataResource, .attachments)
        XCTAssertEqual(
            attachmentsAPI.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.attachments.operationID
        )
        XCTAssertNil(attachmentsAPI.command)
        XCTAssertNil(attachmentsAPI.result)
        let attachmentsBody = try array(attachmentsAPI.responseBody)
        XCTAssertEqual(attachmentsBody.count, 1)
        let attachment = try object(attachmentsBody.first)
        XCTAssertEqual(attachment["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(attachment["apiBasePath"], .string("/source"))
        XCTAssertEqual(attachment["modelRouterToolName"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertEqual(
            try object(try object(attachment["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(try array(attachment["skillIndex"]).count, 3)
        XCTAssertEqual(try array(attachment["commandBindings"]).count, 7)
        XCTAssertFalse(attachmentsJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(attachmentsJSON.contains("authenticatedActor"))

        let workflowAttachmentJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/attachments/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowAttachmentAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowAttachmentJSON.utf8)
        )
        XCTAssertEqual(workflowAttachmentAPI.statusCode, 200)
        XCTAssertEqual(workflowAttachmentAPI.kind, .metadata)
        XCTAssertEqual(workflowAttachmentAPI.metadataResource, .workflowAttachment)
        XCTAssertEqual(
            workflowAttachmentAPI.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.workflowAttachment.operationID
        )
        XCTAssertEqual(workflowAttachmentAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowAttachmentAPI.command)
        XCTAssertNil(workflowAttachmentAPI.result)
        let workflowAttachment = try object(workflowAttachmentAPI.responseBody)
        XCTAssertEqual(workflowAttachment["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(
            try object(try object(workflowAttachment["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(try array(workflowAttachment["skillTree"]).count, 3)
        XCTAssertEqual(try array(workflowAttachment["skillIndex"]).count, 3)
        XCTAssertEqual(try array(workflowAttachment["toolBindings"]).count, 2)
        XCTAssertEqual(try array(workflowAttachment["commandBindings"]).count, 7)
        XCTAssertFalse(workflowAttachmentJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowAttachmentJSON.contains("authenticatedActor"))

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
        XCTAssertEqual(api.launchDescriptor.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])

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
        XCTAssertEqual(model.launchDescriptor.hostWiring.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(model.launchDescriptor.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])

        let capture = provider.capture()
        XCTAssertEqual(capture.toolNames, [SMLWorkflowRuntimeModelAdapter.toolName])
        XCTAssertEqual(capture.toolChoice, .any)
        XCTAssertFalse(capture.geminiBuiltins)
        XCTAssertTrue(capture.systemPrompt.contains("mounted workflow_id"))
        XCTAssertTrue(capture.systemPrompt.contains("langgraph.review@1.0.0"))
        XCTAssertTrue(capture.systemPrompt.contains("Allowed REPL grammar:"))
        XCTAssertTrue(capture.systemPrompt.contains("API routes:"))
        XCTAssertTrue(capture.systemPrompt.contains("Skill tree:"))
        XCTAssertTrue(capture.systemPrompt.contains("plan:CALL_MODEL kind:reasoning"))
        XCTAssertTrue(capture.systemPrompt.contains("Command bindings:"))
        XCTAssertTrue(capture.systemPrompt.contains(#"start: repl="start [TASK_ID] [JSON_INPUT_OBJECT]""#))
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
        XCTAssertEqual(repl.launchDescriptor.hostWiring.apiBasePaths, ["/source"])
        XCTAssertEqual(repl.launchDescriptor.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])

        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))
    }

    func testLangGraphManifestREPLPrintsMachineReadableAttachment() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let json = try await KistRunner.renderSMLRuntimeHostREPLCommand(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            workflowID: "langgraph.review",
            line: "attachment",
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
        XCTAssertEqual(repl.workflowID, "langgraph.review")
        XCTAssertEqual(repl.availableWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(repl.line, "attachment")
        XCTAssertFalse(repl.shouldExit)
        XCTAssertNil(repl.command)
        XCTAssertNil(repl.result)

        let attachment = try JSONDecoder().decode(
            SMLWorkflowREPLAttachmentDescriptor.self,
            from: Data(repl.output.utf8)
        )
        XCTAssertEqual(attachment.workflowID, "langgraph.review")
        XCTAssertEqual(attachment.sourceReference, "graphs/review.py")
        XCTAssertEqual(attachment.apiBasePath, "/source")
        XCTAssertEqual(attachment.runtimeAttachmentsPath, "/source/runtime/attachments")
        XCTAssertEqual(
            attachment.runtimeWorkflowAttachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(attachment.replCommands.first { $0.verb == "attachment" }?.aliases, ["manifest"])
        XCTAssertEqual(attachment.replExamples.first { $0.verb == "attachment" }?.line, "attachment")
        XCTAssertEqual(attachment.apiCatalog.endpoints.count, 7)
        XCTAssertEqual(attachment.modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(attachment.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(attachment.skillTree.map(\.id), ["plan", "write", "receipt"])
        XCTAssertEqual(attachment.toolBindings.map(\.reference), [
            "review.plan", "repository.write",
        ])
        XCTAssertEqual(attachment.plan.entrypoint, "plan")
        XCTAssertEqual(attachment.commandBindings.count, 7)
        XCTAssertEqual(
            attachment.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            "/source/workflows/langgraph.review/tasks"
        )
        XCTAssertEqual(repl.launchDescriptor.hostWiring.attachmentManifests.first?.workflowID, "langgraph.review")

        XCTAssertFalse(json.contains("operator.test"))
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

    func testRuntimeAttachmentsRejectsUnknownWorkflowID() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        do {
            _ = try await KistRunner.makeSMLRuntimeHostAttachments(
                sourcePath: "review.langgraph.json",
                projectRoot: directory.path,
                workflowID: "langgraph.missing",
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
        XCTAssertEqual(export.launchDescriptor.hostWiring, export.hostWiring)
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
            XCTAssertTrue(message.contains("Expected a runtime source package, runtime scaffold, LangGraph manifest, or SML workflow JSON"))
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

    private func array(
        _ value: SMLValue?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [SMLValue] {
        guard case .array(let array) = value else {
            XCTFail("expected array", file: file, line: line)
            return []
        }
        return array
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
