import XCTest
import AgentCore
@testable import Kist

final class KistSMLRuntimeExportTests: XCTestCase {
    func testRuntimeExportAndREPLDispatchBeforeProviderRegistryStartup() throws {
        let source = kistRunnerFamilySource()
        let apiDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAPI != nil"))
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
        XCTAssertEqual(agentGuideWorkflow.commandBindings.count, 7)
        XCTAssertEqual(
            agentGuideWorkflow.commandBindings.first { $0.action == .start }?.replJSONFields.map(\.name),
            ["topic"]
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
        XCTAssertEqual(openAPIRuntime["hostGuideCommandBindingCount"], .number(7))
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
        XCTAssertEqual(wiring.attachment.skillTree.map(\.id), ["plan", "write", "receipt"])
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
        XCTAssertEqual(attachment.channels, [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow,
        ])
        XCTAssertEqual(attachment.skillTree.map(\.id), ["plan", "write", "receipt"])
        XCTAssertEqual(attachment.skillTree.first { $0.id == "write" }?.planning?.unitKind, .externalCapability)
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
        XCTAssertEqual(try array(workflowAttachment["skillTree"]).count, 3)
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
