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
        let runbookDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeRunbook != nil"))
        let scaffoldDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeScaffold != nil"))
        let attachmentsDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAttachments != nil"))
        let serveDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeServe != nil"))
        let replScriptDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeREPLScript != nil"))
        let replDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeREPL != nil"))
        let apiScriptDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeAPIScript != nil"))
        let exportDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeExport != nil"))
        let modelDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeModel != nil"))
        let modelScriptDispatch = try XCTUnwrap(source.range(of: "if opts.smlRuntimeModelScript != nil"))
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
            runbookDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime runbook export must not initialize providers, keychain, MCP, tools, or REPL"
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
            serveDispatch.lowerBound,
            configLoad.lowerBound,
            "SML runtime serve must own its bounded headless driver registry"
        )
        XCTAssertLessThan(
            replScriptDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime REPL script must not initialize providers, keychain, MCP, tools, or REPL"
        )
        XCTAssertLessThan(
            apiScriptDispatch.lowerBound,
            configLoad.lowerBound,
            "offline SML runtime API script must not initialize providers, keychain, MCP, tools, or REPL"
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
        XCTAssertGreaterThan(
            modelScriptDispatch.lowerBound,
            configLoad.lowerBound,
            "SML runtime model-script mode intentionally resolves a real provider/model before execution"
        )
        XCTAssertLessThan(
            modelDispatch.lowerBound,
            buildTools.lowerBound,
            "SML runtime model mode must use the generated model-router tool, not the normal agent tool registry"
        )
        XCTAssertLessThan(
            modelScriptDispatch.lowerBound,
            buildTools.lowerBound,
            "SML runtime model-script mode must use the generated model-router tool, not the normal agent tool registry"
        )

        let workflowPathOverrideForwardCount = source.components(
            separatedBy: "apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides"
        ).count - 1
        let runtimeLaunchCount = source.components(
            separatedBy: "withSMLRuntimeHostLaunch("
        ).count - 1
        XCTAssertEqual(
            workflowPathOverrideForwardCount,
            runtimeLaunchCount,
            "every SML runtime CLI mode must forward --sml-api-workflow-path into the runtime launch helpers"
        )
    }

    func testKistCLIExportsAndRunsLangGraphRuntimeWithCustomWorkflowPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let customWorkflowPath = "/mission-review"
        let customTaskPath = "/source/mission-review/tasks"
        let defaultTaskPath = "/source/workflows/langgraph.review/tasks"

        let exportRun = try runKistCLI(
            arguments: [
                "--sml-runtime-export", "review.langgraph.json",
                "--sml-role", "reviewer",
                "--sml-actor", "operator.test",
                "--sml-api-base", "/source",
                "--sml-api-workflow-path", "langgraph.review=/mission-review",
                "--sml-title", "Source Runtime",
                "--sml-version", "2026.08",
                "--sml-model-rounds", "3",
            ],
            workingDirectory: directory
        )
        XCTAssertEqual(exportRun.exitCode, 0, exportRun.stderr)
        XCTAssertTrue(exportRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(exportRun.stdout.contains(defaultTaskPath))
        let export = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostExport.self,
            from: Data(exportRun.stdout.utf8)
        )
        XCTAssertEqual(export.sourceFormat, .langGraphManifest)
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/source"])
        XCTAssertEqual(export.runtimePackage.sourceSummaries.map(\.apiWorkflowPath), ["/mission-review"])
        XCTAssertEqual(export.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath), ["/mission-review"])
        XCTAssertEqual(export.hostWiring.workflows.map(\.apiWorkflowPath), ["/mission-review"])
        let exportPaths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(exportPaths[customTaskPath])
        XCTAssertNil(exportPaths[defaultTaskPath])
        XCTAssertEqual(
            export.runtimePackage.runtime.onyxDrivers.first?.api.workflowPath,
            "/mission-review"
        )
        XCTAssertEqual(
            export.runtimePackage.runtime.planning.workflows.first?.apiWorkflowPath,
            "/mission-review"
        )

        let apiRun = try runKistCLI(
            arguments: [
                "--sml-runtime-api", "review.langgraph.json",
                "--sml-method", "POST",
                "--sml-path", customTaskPath,
                "--sml-body", #"{"task_id":"TASK-CLI-PROCESS","input":{"topic":"runtime"}}"#,
                "--sml-role", "reviewer",
                "--sml-actor", "operator.test",
                "--sml-api-base", "/source",
                "--sml-api-workflow-path", "langgraph.review=/mission-review",
            ],
            workingDirectory: directory
        )
        XCTAssertEqual(apiRun.exitCode, 0, apiRun.stderr)
        XCTAssertTrue(apiRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(apiRun.stdout.contains(defaultTaskPath))
        let api = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(apiRun.stdout.utf8)
        )
        XCTAssertEqual(api.statusCode, 201)
        XCTAssertEqual(api.path, customTaskPath)
        XCTAssertEqual(api.route?.pathTemplate, customTaskPath)
        XCTAssertEqual(api.route?.workflowID, "langgraph.review")
        XCTAssertEqual(api.route?.action, .start)
        XCTAssertEqual(api.command?.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(api.command?.task, "TASK-CLI-PROCESS")
        XCTAssertEqual(api.result?.task?.workflowID, "langgraph.review")
        XCTAssertEqual(api.result?.task?.currentInstructionID, "plan")

        let replRun = try runKistCLI(
            arguments: [
                "--sml-runtime-repl", "review.langgraph.json",
                "--sml-line", #"start TASK-CLI-REPL {"topic":"runtime"}"#,
                "--sml-role", "reviewer",
                "--sml-actor", "operator.test",
                "--sml-api-base", "/source",
                "--sml-api-workflow-path", "langgraph.review=/mission-review",
            ],
            workingDirectory: directory
        )
        XCTAssertEqual(replRun.exitCode, 0, replRun.stderr)
        XCTAssertTrue(replRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(replRun.stdout.contains(defaultTaskPath))
        let repl = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostREPLCommand.self,
            from: Data(replRun.stdout.utf8)
        )
        XCTAssertEqual(repl.workflowID, "langgraph.review")
        XCTAssertEqual(repl.command?.task, "TASK-CLI-REPL")
        XCTAssertEqual(repl.result?.task?.workflowID, "langgraph.review")
        XCTAssertEqual(
            repl.launchDescriptor.hostWiring.workflows.first?.apiRoutes.first { $0.action == .start }?.pathTemplate,
            customTaskPath
        )

        let modelRouterRun = try runKistCLI(
            arguments: [
                "--sml-runtime-model-router", "review.langgraph.json",
                "--sml-role", "reviewer",
                "--sml-api-base", "/source",
                "--sml-api-workflow-path", "langgraph.review=/mission-review",
                "--sml-model-rounds", "3",
            ],
            workingDirectory: directory
        )
        XCTAssertEqual(modelRouterRun.exitCode, 0, modelRouterRun.stderr)
        XCTAssertTrue(modelRouterRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(modelRouterRun.stdout.contains(defaultTaskPath))
        let modelRouter = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelRouterExport.self,
            from: Data(modelRouterRun.stdout.utf8)
        )
        XCTAssertEqual(modelRouter.modelRouter.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(modelRouter.modelRouter.maximumCommandRounds, 3)
        XCTAssertEqual(
            modelRouter.launchDescriptor.hostWiring.workflows.first?.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )

        let onyxRun = try runKistCLI(
            arguments: [
                "--sml-runtime-onyx", "review.langgraph.json",
                "--sml-workflow", "langgraph.review",
                "--sml-role", "reviewer",
                "--sml-api-base", "/source",
                "--sml-api-workflow-path", "langgraph.review=/mission-review",
            ],
            workingDirectory: directory
        )
        XCTAssertEqual(onyxRun.exitCode, 0, onyxRun.stderr)
        XCTAssertTrue(onyxRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(onyxRun.stdout.contains(defaultTaskPath))
        let onyx = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostOnyxDrivers.self,
            from: Data(onyxRun.stdout.utf8)
        )
        XCTAssertEqual(onyx.workflowID, "langgraph.review")
        XCTAssertEqual(onyx.onyxDrivers.first?.api.workflowPath, "/mission-review")
        XCTAssertEqual(
            onyx.onyxDrivers.first?.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )

        let planningRun = try runKistCLI(
            arguments: [
                "--sml-runtime-planning", "review.langgraph.json",
                "--sml-role", "reviewer",
                "--sml-api-base", "/source",
                "--sml-api-workflow-path", "langgraph.review=/mission-review",
            ],
            workingDirectory: directory
        )
        XCTAssertEqual(planningRun.exitCode, 0, planningRun.stderr)
        XCTAssertTrue(planningRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(planningRun.stdout.contains(defaultTaskPath))
        let planning = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostPlanningExport.self,
            from: Data(planningRun.stdout.utf8)
        )
        XCTAssertEqual(planning.planning.workflows.first?.apiWorkflowPath, "/mission-review")
        XCTAssertEqual(
            planning.planning.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )

        let scaffoldRun = try runKistCLI(
            arguments: [
                "--sml-runtime-scaffold", "review.langgraph.json",
                "--sml-out", "cli-runtime-scaffold",
                "--sml-role", "reviewer",
                "--sml-actor", "operator.test",
                "--sml-api-base", "/source",
                "--sml-api-workflow-path", "langgraph.review=\(customWorkflowPath)",
                "--sml-title", "Source Runtime",
                "--sml-version", "2026.08",
                "--sml-model-rounds", "3",
            ],
            workingDirectory: directory
        )
        XCTAssertEqual(scaffoldRun.exitCode, 0, scaffoldRun.stderr)
        XCTAssertTrue(scaffoldRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(scaffoldRun.stdout.contains(defaultTaskPath))
        let scaffold = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffold.self,
            from: Data(scaffoldRun.stdout.utf8)
        )
        let scaffoldURL = directory.appendingPathComponent("cli-runtime-scaffold", isDirectory: true)
        XCTAssertEqual(scaffold.outputDirectory, scaffoldURL.path)
        XCTAssertEqual(scaffold.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath), [customWorkflowPath])
        XCTAssertEqual(scaffold.runbookPath, "runbook.json")
        XCTAssertEqual(scaffold.workflowAPIMountPathsByWorkflowID, [
            "langgraph.review": "api-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowREPLMountPathsByWorkflowID, [
            "langgraph.review": "repl-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowModelToolPathsByWorkflowID, [
            "langgraph.review": "model-tools/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowOnyxDriverPathsByWorkflowID, [
            "langgraph.review": "onyx-drivers/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowSkillTreePathsByWorkflowID, [
            "langgraph.review": "skill-trees/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowToolBindingPathsByWorkflowID, [
            "langgraph.review": "tool-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowPlanningBundlePathsByWorkflowID, [
            "langgraph.review": "planning/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowRunbookPathsByWorkflowID, [
            "langgraph.review": "workflow-runbooks/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowBindingPathsByWorkflowID, [
            "langgraph.review": "workflow-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowBindingPathsByWorkflowID, [
            "langgraph.review": "workflow-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.replMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.apiMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.toolBindingsPath,
            "/source/runtime/tool-bindings/langgraph.review"
        )
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "onyx-drivers/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "skill-trees/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "tool-bindings/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "planning/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "api-mounts/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "repl-mounts/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "model-tools/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "workflow-runbooks/langgraph.review.json" })
        XCTAssertTrue(scaffold.files.contains { $0.relativePath == "workflow-bindings/langgraph.review.json" })

        let runbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("runbook.json"))
        )
        XCTAssertEqual(runbook.apiWorkflowPathsByWorkflowID, [
            "langgraph.review": customWorkflowPath,
        ])
        XCTAssertEqual(runbook.apiTaskPathsByWorkflowID, [
            "langgraph.review": customTaskPath,
        ])
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.replMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.apiMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.onyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(runbook.workflows.first?.apiWorkflowPath, customWorkflowPath)
        XCTAssertEqual(runbook.workflows.first?.replMountPath, "repl-mounts/langgraph.review.json")
        XCTAssertEqual(runbook.workflows.first?.replMount.apiWorkflowPath, customWorkflowPath)
        XCTAssertEqual(runbook.workflows.first?.replCommands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertEqual(runbook.workflows.first?.apiMountPath, "api-mounts/langgraph.review.json")
        XCTAssertEqual(runbook.workflows.first?.apiMounts.first { $0.action == .start }?.pathTemplate, customTaskPath)
        XCTAssertEqual(runbook.workflows.first?.modelToolPath, "model-tools/langgraph.review.json")
        XCTAssertEqual(runbook.workflows.first?.modelTool.workflowID, "langgraph.review")
        XCTAssertEqual(runbook.workflows.first?.modelTool.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(runbook.workflows.first?.onyxDriverPath, "onyx-drivers/langgraph.review.json")
        XCTAssertEqual(runbook.workflows.first?.skillTreePath, "skill-trees/langgraph.review.json")
        XCTAssertEqual(runbook.workflows.first?.toolBindingsPath, "tool-bindings/langgraph.review.json")
        XCTAssertEqual(runbook.workflows.first?.planningBundlePath, "planning/langgraph.review.json")
        XCTAssertEqual(runbook.workflows.first?.workflowRunbookPath, "workflow-runbooks/langgraph.review.json")
        XCTAssertEqual(
            runbook.workflows.first?.runtimeWorkflowAttachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            runbook.workflows.first?.runtimeWorkflowOnyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            runbook.workflows.first?.runtimeWorkflowSkillTreePath,
            "/source/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(
            runbook.workflows.first?.runtimeWorkflowToolBindingsPath,
            "/source/runtime/tool-bindings/langgraph.review"
        )
        XCTAssertEqual(
            runbook.workflows.first?.runtimeWorkflowPlanningPath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertTrue(runbook.workflows.first?.apiEndpoints.contains {
            $0.action == .start && $0.pathTemplate == customTaskPath
        } == true)

        let workflowOnyx = try JSONDecoder().decode(
            SMLOnyxDriverManifest.self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("onyx-drivers/langgraph.review.json"))
        )
        XCTAssertEqual(workflowOnyx.api.workflowPath, customWorkflowPath)
        XCTAssertEqual(
            workflowOnyx.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )
        let workflowPlanning = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldWorkflowPlanningBundle.self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("planning/langgraph.review.json"))
        )
        XCTAssertEqual(workflowPlanning.apiWorkflowPath, customWorkflowPath)
        XCTAssertEqual(
            workflowPlanning.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )
        let workflowSkillTree = try JSONDecoder().decode(
            [SMLOnyxSkillNode].self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("skill-trees/langgraph.review.json"))
        )
        XCTAssertEqual(workflowSkillTree.map(\.id), ["plan", "write", "receipt"])
        let workflowToolBindings = try JSONDecoder().decode(
            [SMLOnyxToolBinding].self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("tool-bindings/langgraph.review.json"))
        )
        XCTAssertEqual(workflowToolBindings.map(\.reference), ["review.plan", "repository.write"])
        let workflowREPLMount = try JSONDecoder().decode(
            SMLWorkflowRuntimeREPLMount.self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("repl-mounts/langgraph.review.json"))
        )
        XCTAssertEqual(workflowREPLMount.apiWorkflowPath, customWorkflowPath)
        XCTAssertEqual(workflowREPLMount.commands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        let workflowAPIMounts = try JSONDecoder().decode(
            [SMLWorkflowRuntimeAPIMount].self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("api-mounts/langgraph.review.json"))
        )
        XCTAssertTrue(workflowAPIMounts.contains {
            $0.action == .start && $0.pathTemplate == customTaskPath
        })
        let workflowModelTool = try JSONDecoder().decode(
            SMLWorkflowRuntimeModelToolExport.self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("model-tools/langgraph.review.json"))
        )
        XCTAssertEqual(workflowModelTool.workflowID, "langgraph.review")
        XCTAssertEqual(workflowModelTool.workflowMetadata.attachmentPath, "/source/runtime/attachments/langgraph.review")
        XCTAssertEqual(workflowModelTool.workflowMetadata.replMountPath, "/source/runtime/repl-mounts/langgraph.review")
        XCTAssertEqual(workflowModelTool.workflowMetadata.apiMountPath, "/source/runtime/api-mounts/langgraph.review")
        XCTAssertEqual(workflowModelTool.workflowMetadata.modelToolPath, "/source/runtime/model-tools/langgraph.review")

        let readme = try String(contentsOf: scaffoldURL.appendingPathComponent("README.md"))
        XCTAssertTrue(readme.contains("Per-workflow wiring cards"))
        XCTAssertTrue(readme.contains("Task endpoint: `\(customTaskPath)`"))
        XCTAssertTrue(readme.contains("REPL mount: `repl-mounts/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("API mount: `api-mounts/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Model tool descriptor: `model-tools/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Onyx driver: `onyx-drivers/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Skill tree: `skill-trees/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Tool bindings: `tool-bindings/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Planning bundle: `planning/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Workflow runbook: `workflow-runbooks/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Runtime metadata APIs: attachment `GET /source/runtime/attachments/langgraph.review`"))
        XCTAssertTrue(readme.contains("REPL mount `GET /source/runtime/repl-mounts/langgraph.review`"))
        XCTAssertTrue(readme.contains("API mount `GET /source/runtime/api-mounts/langgraph.review`"))
        XCTAssertTrue(readme.contains("model tool `GET /source/runtime/model-tools/langgraph.review`"))
        XCTAssertTrue(readme.contains("planning bundle `GET /source/runtime/planning/langgraph.review`"))
        XCTAssertFalse(readme.contains(defaultTaskPath))
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
        XCTAssertEqual(
            launched.replMount.workflowMetadata.replMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            launched.replMount.workflowMetadata.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            launched.replMount.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
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
                .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
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
        XCTAssertTrue(metadataPaths.contains("/source/runtime/planning/{workflow_id}"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/onyx-drivers"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/onyx-drivers/{workflow_id}"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/host-guide"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/host-wiring"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/launch"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/attachments"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/attachments/{workflow_id}"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/skill-trees/{workflow_id}"))
        XCTAssertTrue(metadataPaths.contains("/source/runtime/tool-bindings/{workflow_id}"))

        let wiring = try XCTUnwrap(export.hostWiring.workflows.first)
        XCTAssertEqual(wiring.workflowID, "langgraph.review")
        XCTAssertEqual(wiring.role, "reviewer")
        XCTAssertEqual(wiring.apiBasePath, "/source")
        XCTAssertEqual(wiring.replMount.workflowID, "langgraph.review")
        XCTAssertTrue(wiring.replMount.examples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertEqual(wiring.workflowMetadata, wiring.replMount.workflowMetadata)
        XCTAssertEqual(
            wiring.replMount.workflowMetadata.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
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
                .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
            ]
        )
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .customAPI
                && $0.pathTemplates.contains("/source/workflows/langgraph.review/tasks")
                && $0.pathTemplates.contains("/source/runtime/api-mounts/langgraph.review")
                && $0.apiExamples.contains {
                    $0.path == "/source/workflows/langgraph.review/tasks"
                        && $0.body["input"] == .object(["topic": .string("topic")])
                }
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .customREPL
                && $0.pathTemplates.contains("/source/runtime/repl-mounts/langgraph.review")
                && $0.replExamples.contains { $0.line == #"start TASK-ID {"topic":"topic"}"# }
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .modelTool
                && $0.pathTemplates.contains("/source/runtime/model-tools/langgraph.review")
                && $0.apiExamples.contains {
                    $0.path == "/source/runtime/model-tools/langgraph.review"
                }
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
            $0.channel == .onyxDriver
                && $0.driverID == wiring.onyxDriverID
                && $0.pathTemplates.contains("/source/runtime/onyx-drivers/langgraph.review")
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .planningWorkflow
                && $0.planningWorkflowID == wiring.planningWorkflowID
                && $0.pathTemplates.contains("/source/runtime/planning/langgraph.review")
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .skillTree
                && $0.authority == .descriptorOnly
                && $0.readOnly
                && $0.pathTemplates.contains("/source/runtime/skill-trees/langgraph.review")
        })
        XCTAssertTrue(wiring.hostBindings.contains {
            $0.channel == .toolBindings
                && $0.authority == .descriptorOnly
                && $0.readOnly
                && $0.pathTemplates.contains("/source/runtime/tool-bindings/langgraph.review")
        })
        XCTAssertEqual(wiring.attachment.workflowID, "langgraph.review")
        XCTAssertEqual(wiring.attachment.apiBasePath, "/source")
        XCTAssertEqual(wiring.attachment.runtimeAttachmentsPath, "/source/runtime/attachments")
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowAttachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowREPLMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowAPIMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowModelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowOnyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowSkillTreePath,
            "/source/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowToolBindingsPath,
            "/source/runtime/tool-bindings/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.runtimeWorkflowPlanningPath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(wiring.attachment.workflowMetadata, wiring.workflowMetadata)
        XCTAssertEqual(
            wiring.attachment.workflowMetadata.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            wiring.attachment.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
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
        let routerMetadata = try XCTUnwrap(modelRouter.modelRouter.workflowMetadata.first)
        XCTAssertEqual(routerMetadata.workflowID, "langgraph.review")
        XCTAssertEqual(
            routerMetadata.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            routerMetadata.onyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            routerMetadata.skillTreePath,
            "/source/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(
            routerMetadata.toolBindingsPath,
            "/source/runtime/tool-bindings/langgraph.review"
        )
        XCTAssertEqual(
            routerMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
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
        let planningWorkflow = try XCTUnwrap(planning.planning.workflows.first)
        XCTAssertEqual(
            planningWorkflow.workflowMetadata.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            planningWorkflow.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
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

    func testParsedCLIWorkflowPathOverrideFlowsAcrossLangGraphRuntimeSurfaces() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)

        let opts = KistOptions.parse([
            "--sml-runtime-export", "review.langgraph.json",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-api-workflow-path", "langgraph.review=/mission-review",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertTrue(opts.optionErrors.isEmpty, opts.optionErrors.joined(separator: "\n"))

        let customWorkflowPath = "/mission-review"
        let customTaskPath = "/source/mission-review/tasks"
        let defaultTaskPath = "/source/workflows/langgraph.review/tasks"
        let sourcePath = try XCTUnwrap(opts.smlRuntimeExport)

        let exportJSON = try await KistRunner.renderSMLRuntimeHostExport(
            sourcePath: sourcePath,
            projectRoot: directory.path,
            roleOverride: opts.smlRuntimeRole,
            actor: opts.smlRuntimeActor,
            apiBasePathOverride: opts.smlRuntimeAPIBasePath,
            apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
            title: opts.smlRuntimeTitle,
            version: opts.smlRuntimeVersion,
            modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
        )
        let export = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostExport.self,
            from: Data(exportJSON.utf8)
        )

        XCTAssertEqual(export.sourceFormat, .langGraphManifest)
        XCTAssertEqual(export.runtimePackage.sourceSummaries.map(\.apiWorkflowPath), [customWorkflowPath])
        XCTAssertEqual(export.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath), [customWorkflowPath])
        XCTAssertEqual(
            export.runtimePackage.sourceSummaries.first?.workflowMetadata.apiMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            export.launchDescriptor.sourceSummaries.first?.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(export.launchDescriptor.workflows.map(\.apiWorkflowPath), [customWorkflowPath])
        XCTAssertEqual(export.hostWiring.workflows.map(\.apiWorkflowPath), [customWorkflowPath])
        XCTAssertEqual(export.hostWiring.attachmentManifests.map(\.apiWorkflowPath), [customWorkflowPath])
        XCTAssertFalse(exportJSON.contains(defaultTaskPath))

        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths[customTaskPath])
        XCTAssertNil(paths[defaultTaskPath])

        let runtimeWorkflow = try XCTUnwrap(export.runtimePackage.runtime.catalog.workflows.first)
        XCTAssertEqual(runtimeWorkflow.api.basePath, "/source")
        XCTAssertEqual(runtimeWorkflow.api.workflowPath, customWorkflowPath)

        let mount = try XCTUnwrap(export.runtimePackage.runtime.mountContract.workflowMounts.first)
        XCTAssertEqual(mount.apiBasePath, "/source")
        XCTAssertEqual(mount.apiWorkflowPath, customWorkflowPath)
        XCTAssertEqual(mount.repl.apiWorkflowPath, customWorkflowPath)
        XCTAssertEqual(
            mount.apiRoutes.first { $0.action == .start }?.pathTemplate,
            customTaskPath
        )
        XCTAssertEqual(
            mount.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )

        let onyxDriver = try XCTUnwrap(export.runtimePackage.runtime.onyxDrivers.first)
        XCTAssertEqual(onyxDriver.api.basePath, "/source")
        XCTAssertEqual(onyxDriver.api.workflowPath, customWorkflowPath)
        XCTAssertEqual(
            onyxDriver.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )

        let planningWorkflow = try XCTUnwrap(export.runtimePackage.runtime.planning.workflows.first)
        XCTAssertEqual(planningWorkflow.apiBasePath, "/source")
        XCTAssertEqual(planningWorkflow.apiWorkflowPath, customWorkflowPath)
        XCTAssertEqual(
            export.runtimePackage.runtime.planning.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )

        let hostWorkflow = try XCTUnwrap(export.hostWiring.workflows.first)
        XCTAssertEqual(hostWorkflow.apiBasePath, "/source")
        XCTAssertEqual(hostWorkflow.apiWorkflowPath, customWorkflowPath)
        XCTAssertTrue(hostWorkflow.hostBindings.contains {
            $0.channel == .customAPI
                && $0.pathTemplates.contains(customTaskPath)
                && $0.pathTemplates.contains("/source/runtime/api-mounts/langgraph.review")
                && !$0.pathTemplates.contains(defaultTaskPath)
                && $0.apiExamples.contains {
                    $0.path == customTaskPath
                        && $0.body["input"] == .object(["topic": .string("topic")])
                }
        })

        let replJSON = try await KistRunner.renderSMLRuntimeHostREPLCommand(
            sourcePath: sourcePath,
            projectRoot: directory.path,
            workflowID: nil,
            line: #"start TASK-CLI --state {"topic":"runtime"}"#,
            roleOverride: opts.smlRuntimeRole,
            actor: opts.smlRuntimeActor,
            apiBasePathOverride: opts.smlRuntimeAPIBasePath,
            apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
            title: opts.smlRuntimeTitle,
            version: opts.smlRuntimeVersion,
            modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
        )
        let repl = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostREPLCommand.self,
            from: Data(replJSON.utf8)
        )
        XCTAssertEqual(repl.result?.task?.taskID, "TASK-CLI")
        XCTAssertEqual(repl.result?.task?.workflowID, "langgraph.review")
        XCTAssertEqual(
            repl.launchDescriptor.hostWiring.workflows.first?.apiRoutes.first { $0.action == .start }?.pathTemplate,
            customTaskPath
        )
        XCTAssertFalse(replJSON.contains(defaultTaskPath))

        let apiJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: sourcePath,
            projectRoot: directory.path,
            method: .post,
            path: customTaskPath,
            bodyJSON: #"{"task_id":"TASK-API","input":{"topic":"runtime"}}"#,
            roleOverride: opts.smlRuntimeRole,
            actor: opts.smlRuntimeActor,
            apiBasePathOverride: opts.smlRuntimeAPIBasePath,
            apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
            title: opts.smlRuntimeTitle,
            version: opts.smlRuntimeVersion,
            modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
        )
        let api = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(apiJSON.utf8)
        )
        XCTAssertEqual(api.statusCode, 201)
        XCTAssertEqual(api.route?.workflowID, "langgraph.review")
        XCTAssertEqual(api.route?.action, .start)
        XCTAssertEqual(api.route?.pathTemplate, customTaskPath)
        XCTAssertEqual(api.command?.task, "TASK-API")
        XCTAssertEqual(api.result?.task?.workflowID, "langgraph.review")
        XCTAssertFalse(apiJSON.contains(defaultTaskPath))

        let provider = ScriptedSMLRuntimeProvider([
            .textAndCall(
                "Routing the custom wrapped workflow.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"start TASK-MODEL {\"topic\":\"runtime\"}"}"#
            ),
        ])
        let registry = ProviderRegistry(providers: [provider], retryDelaysNanoseconds: [])
        let modelJSON = try await KistRunner.renderSMLRuntimeHostModelTurn(
            sourcePath: sourcePath,
            projectRoot: directory.path,
            prompt: "start the review workflow through the generated runtime",
            binding: ProviderBinding(providerId: provider.id, model: provider.defaultModel),
            providers: registry,
            roleOverride: opts.smlRuntimeRole,
            actor: opts.smlRuntimeActor,
            apiBasePathOverride: opts.smlRuntimeAPIBasePath,
            apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
            title: opts.smlRuntimeTitle,
            version: opts.smlRuntimeVersion,
            modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
        )
        let model = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelTurn.self,
            from: Data(modelJSON.utf8)
        )
        XCTAssertEqual(model.steps.first?.disposition, .commandExecuted)
        XCTAssertEqual(model.taskIDsByWorkflowID["langgraph.review"], "TASK-MODEL")
        XCTAssertEqual(
            model.launchDescriptor.hostWiring.workflows.first?.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            customTaskPath
        )

        let capture = provider.capture()
        XCTAssertEqual(capture.toolNames, [SMLWorkflowRuntimeModelAdapter.toolName])
        XCTAssertTrue(capture.systemPrompt.contains("api workflow path: \(customWorkflowPath)"))
        XCTAssertTrue(capture.systemPrompt.contains(customTaskPath))
        XCTAssertFalse(capture.systemPrompt.contains(defaultTaskPath))
        XCTAssertFalse(modelJSON.contains(defaultTaskPath))

        let scaffoldJSON = try await KistRunner.renderSMLRuntimeHostScaffold(
            sourcePath: sourcePath,
            outputDirectory: "custom-runtime-scaffold",
            projectRoot: directory.path,
            roleOverride: opts.smlRuntimeRole,
            actor: opts.smlRuntimeActor,
            apiBasePathOverride: opts.smlRuntimeAPIBasePath,
            apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
            title: opts.smlRuntimeTitle,
            version: opts.smlRuntimeVersion,
            modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
        )
        let scaffold = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffold.self,
            from: Data(scaffoldJSON.utf8)
        )
        let scaffoldURL = directory.appendingPathComponent("custom-runtime-scaffold", isDirectory: true)
        XCTAssertEqual(scaffold.outputDirectory, scaffoldURL.path)
        XCTAssertEqual(scaffold.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath), [customWorkflowPath])

        let scaffoldRunbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("runbook.json"))
        )
        XCTAssertEqual(scaffoldRunbook.apiWorkflowPathsByWorkflowID, [
            "langgraph.review": customWorkflowPath,
        ])
        XCTAssertEqual(scaffoldRunbook.apiTaskPathsByWorkflowID, [
            "langgraph.review": customTaskPath,
        ])
        XCTAssertEqual(scaffoldRunbook.workflows.first?.apiWorkflowPath, customWorkflowPath)
        XCTAssertTrue(scaffoldRunbook.workflows.first?.apiEndpoints.contains {
            $0.action == .start && $0.pathTemplate == customTaskPath
        } == true)

        let scaffoldReadme = try String(
            contentsOf: scaffoldURL.appendingPathComponent("README.md")
        )
        XCTAssertTrue(scaffoldReadme.contains("Workflow API paths"))
        XCTAssertTrue(scaffoldReadme.contains("langgraph.review: `\(customWorkflowPath)` mounted at `\(customTaskPath)`"))
        XCTAssertFalse(scaffoldReadme.contains(defaultTaskPath))

        let scaffoldAPIScript = try JSONDecoder().decode(
            [KistRunner.SMLRuntimeHostAPIRequestSpec].self,
            from: Data(contentsOf: scaffoldURL.appendingPathComponent("api-scripts/langgraph.review.json"))
        )
        XCTAssertEqual(scaffoldAPIScript.map(\.path), [
            "/source/mission-review",
            customTaskPath,
            "\(customTaskPath)/TASK-SCAFFOLD",
            "\(customTaskPath)/TASK-SCAFFOLD/receipts",
            "/source/runtime/attachments/langgraph.review",
            "/source/runtime/repl-mounts/langgraph.review",
            "/source/runtime/api-mounts/langgraph.review",
            "/source/runtime/model-tools/langgraph.review",
            "/source/runtime/onyx-drivers/langgraph.review",
            "/source/runtime/skill-trees/langgraph.review",
            "/source/runtime/tool-bindings/langgraph.review",
            "/source/runtime/planning/langgraph.review",
        ])
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
        XCTAssertEqual(mount.mountContract.apiRoutes.count, 27)
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
        XCTAssertEqual(scaffold.runbookPath, "runbook.json")
        XCTAssertEqual(scaffold.workflowAPIMountPathsByWorkflowID, [
            "langgraph.review": "api-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowREPLMountPathsByWorkflowID, [
            "langgraph.review": "repl-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowModelToolPathsByWorkflowID, [
            "langgraph.review": "model-tools/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowOnyxDriverPathsByWorkflowID, [
            "langgraph.review": "onyx-drivers/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowSkillTreePathsByWorkflowID, [
            "langgraph.review": "skill-trees/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowToolBindingPathsByWorkflowID, [
            "langgraph.review": "tool-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowPlanningBundlePathsByWorkflowID, [
            "langgraph.review": "planning/langgraph.review.json",
        ])
        XCTAssertEqual(scaffold.workflowRunbookPathsByWorkflowID, [
            "langgraph.review": "workflow-runbooks/langgraph.review.json",
        ])
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.replMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.apiMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            scaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )

        let expectedPaths: Set<String> = [
            "README.md",
            "agent-guide.json",
            "api-mounts/langgraph.review.json",
            "api-scripts/langgraph.review.json",
            "attachments.json",
            "attachments/langgraph.review.json",
            "catalog.json",
            "host-guide.json",
            "host-wiring.json",
            "launch.json",
            "model-scripts/langgraph.review.prompts",
            "model-router.json",
            "model-tools/langgraph.review.json",
            "model-tools.json",
            "mount.json",
            "onyx-drivers.json",
            "onyx-drivers/langgraph.review.json",
            "openapi.json",
            "planning/langgraph.review.json",
            "planning.json",
            "repl-mounts/langgraph.review.json",
            "repl-scripts/langgraph.review.repl",
            "runbook.json",
            "runtime-export.json",
            "runtime-source-package.json",
            "skill-trees/langgraph.review.json",
            "tool-bindings/langgraph.review.json",
            "workflow-bindings/langgraph.review.json",
            "workflow-runbooks/langgraph.review.json",
        ]
        XCTAssertEqual(Set(scaffold.files.map(\.relativePath)), expectedPaths)
        let indexURL = outputURL.appendingPathComponent(scaffold.indexPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        let index = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffold.self,
            from: Data(contentsOf: indexURL)
        )
        XCTAssertEqual(index, scaffold)
        var legacyScaffoldObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        )
        legacyScaffoldObject["schemaVersion"] = 2
        legacyScaffoldObject.removeValue(forKey: "runbookPath")
        legacyScaffoldObject.removeValue(forKey: "workflowAPIMountPathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowREPLMountPathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowModelToolPathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowOnyxDriverPathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowSkillTreePathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowToolBindingPathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowPlanningBundlePathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowRunbookPathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "workflowBindingPathsByWorkflowID")
        legacyScaffoldObject.removeValue(forKey: "runtimeWorkflowMetadataByWorkflowID")
        let legacyScaffold = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffold.self,
            from: JSONSerialization.data(withJSONObject: legacyScaffoldObject, options: [.sortedKeys])
        )
        XCTAssertEqual(legacyScaffold.schemaVersion, 2)
        XCTAssertEqual(legacyScaffold.runbookPath, "runbook.json")
        XCTAssertEqual(legacyScaffold.workflowAPIMountPathsByWorkflowID, [
            "langgraph.review": "api-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowREPLMountPathsByWorkflowID, [
            "langgraph.review": "repl-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowModelToolPathsByWorkflowID, [
            "langgraph.review": "model-tools/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowOnyxDriverPathsByWorkflowID, [
            "langgraph.review": "onyx-drivers/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowSkillTreePathsByWorkflowID, [
            "langgraph.review": "skill-trees/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowToolBindingPathsByWorkflowID, [
            "langgraph.review": "tool-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowPlanningBundlePathsByWorkflowID, [
            "langgraph.review": "planning/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowRunbookPathsByWorkflowID, [
            "langgraph.review": "workflow-runbooks/langgraph.review.json",
        ])
        XCTAssertEqual(legacyScaffold.workflowBindingPathsByWorkflowID, [
            "langgraph.review": "workflow-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(
            legacyScaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            legacyScaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.replMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            legacyScaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.apiMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            legacyScaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            legacyScaffold.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )

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
        XCTAssertEqual(mount.apiRoutes.count, 27)
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
        let aggregateModelTool = try XCTUnwrap(modelTools.first)
        XCTAssertEqual(aggregateModelTool.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(
            aggregateModelTool.workflowMetadata.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            aggregateModelTool.workflowMetadata.replMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            aggregateModelTool.workflowMetadata.apiMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            aggregateModelTool.workflowMetadata.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            aggregateModelTool.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
        let workflowModelTool = try JSONDecoder().decode(
            SMLWorkflowRuntimeModelToolExport.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("model-tools/langgraph.review.json"))
        )
        XCTAssertEqual(workflowModelTool, aggregateModelTool)

        let modelRouter = try JSONDecoder().decode(
            SMLWorkflowRuntimeModelRouterDescriptor.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("model-router.json"))
        )
        XCTAssertEqual(modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(modelRouter.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(
            modelRouter.workflowMetadata.first?.onyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(modelRouter.maximumCommandRounds, 3)

        let onyxDrivers = try JSONDecoder().decode(
            [SMLOnyxDriverManifest].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("onyx-drivers.json"))
        )
        XCTAssertEqual(onyxDrivers.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(onyxDrivers.first?.skillTree.map(\.id), ["plan", "write", "receipt"])
        let workflowOnyxDriver = try JSONDecoder().decode(
            SMLOnyxDriverManifest.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("onyx-drivers/langgraph.review.json"))
        )
        XCTAssertEqual(workflowOnyxDriver, onyxDrivers.first)

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
        let expectedHostBindingChannels: [SMLWorkflowRuntimeHostBindingChannel] = [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
        ]
        XCTAssertEqual(attachment.channels, expectedHostBindingChannels)
        let workflowSkillTree = try JSONDecoder().decode(
            [SMLOnyxSkillNode].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("skill-trees/langgraph.review.json"))
        )
        XCTAssertEqual(workflowSkillTree, attachment.skillTree)
        let workflowToolBindings = try JSONDecoder().decode(
            [SMLOnyxToolBinding].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("tool-bindings/langgraph.review.json"))
        )
        XCTAssertEqual(workflowToolBindings, attachment.toolBindings)
        let workflowPlanning = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldWorkflowPlanningBundle.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("planning/langgraph.review.json"))
        )
        XCTAssertEqual(
            workflowPlanning.schemaVersion,
            KistRunner.SMLRuntimeHostScaffoldWorkflowPlanningBundle.currentSchemaVersion
        )
        XCTAssertEqual(workflowPlanning.workflowID, "langgraph.review")
        XCTAssertEqual(workflowPlanning.workflowVersion, attachment.workflowVersion)
        XCTAssertEqual(workflowPlanning.apiBasePath, "/source")
        XCTAssertEqual(workflowPlanning.apiWorkflowPath, "/workflows/langgraph.review")
        XCTAssertEqual(workflowPlanning.planningWorkflowID, attachment.planningWorkflowID)
        XCTAssertEqual(workflowPlanning.plannerEntrypoint, attachment.plannerEntrypoint)
        XCTAssertEqual(workflowPlanning.plan, attachment.plan)
        XCTAssertEqual(workflowPlanning.skillIndex, attachment.skillIndex)
        XCTAssertEqual(workflowPlanning.toolReferences, attachment.toolReferences)
        XCTAssertEqual(workflowPlanning.toolBindings, attachment.toolBindings)
        XCTAssertEqual(workflowPlanning.decomposableUnits, attachment.decomposableUnits)
        XCTAssertEqual(workflowPlanning.approvalGates, attachment.approvalGates)
        XCTAssertEqual(workflowPlanning.commandBindings, attachment.commandBindings)
        let workflowREPLMount = try JSONDecoder().decode(
            SMLWorkflowRuntimeREPLMount.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("repl-mounts/langgraph.review.json"))
        )
        XCTAssertEqual(workflowREPLMount, attachment.replMount)
        let workflowAPIMounts = try JSONDecoder().decode(
            [SMLWorkflowRuntimeAPIMount].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("api-mounts/langgraph.review.json"))
        )
        XCTAssertEqual(workflowAPIMounts, attachment.apiRoutes)
        let workflowBinding = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldWorkflowBinding.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("workflow-bindings/langgraph.review.json"))
        )

        let runbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
        )
        XCTAssertEqual(runbook.schemaVersion, KistRunner.SMLRuntimeHostScaffoldRunbook.currentSchemaVersion)
        XCTAssertEqual(runbook.sourcePath, manifestURL.path)
        XCTAssertEqual(runbook.sourceFormat, .langGraphManifest)
        XCTAssertEqual(runbook.outputDirectory, outputURL.path)
        XCTAssertEqual(runbook.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(runbook.apiBasePaths, ["/source"])
        XCTAssertEqual(runbook.apiWorkflowPathsByWorkflowID, [
            "langgraph.review": "/workflows/langgraph.review",
        ])
        XCTAssertEqual(runbook.apiTaskPathsByWorkflowID, [
            "langgraph.review": "/source/workflows/langgraph.review/tasks",
        ])
        XCTAssertEqual(runbook.workflowAttachmentPathsByWorkflowID, [
            "langgraph.review": "attachments/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowRunbookPathsByWorkflowID, [
            "langgraph.review": "workflow-runbooks/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowREPLScriptPathsByWorkflowID, [
            "langgraph.review": "repl-scripts/langgraph.review.repl",
        ])
        XCTAssertEqual(runbook.workflowREPLMountPathsByWorkflowID, [
            "langgraph.review": "repl-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowAPIScriptPathsByWorkflowID, [
            "langgraph.review": "api-scripts/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowAPIMountPathsByWorkflowID, [
            "langgraph.review": "api-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowModelScriptPathsByWorkflowID, [
            "langgraph.review": "model-scripts/langgraph.review.prompts",
        ])
        XCTAssertEqual(runbook.workflowModelToolPathsByWorkflowID, [
            "langgraph.review": "model-tools/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowOnyxDriverPathsByWorkflowID, [
            "langgraph.review": "onyx-drivers/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowSkillTreePathsByWorkflowID, [
            "langgraph.review": "skill-trees/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowToolBindingPathsByWorkflowID, [
            "langgraph.review": "tool-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowPlanningBundlePathsByWorkflowID, [
            "langgraph.review": "planning/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowBindingPathsByWorkflowID, [
            "langgraph.review": "workflow-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(runbook.workflowHostBindingChannelsByWorkflowID, [
            "langgraph.review": expectedHostBindingChannels,
        ])
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"],
            SMLWorkflowRuntimeWorkflowMetadataLinks(
                workflowID: "langgraph.review",
                workflowVersion: attachment.workflowVersion,
                apiBasePath: "/source"
            )
        )
        XCTAssertTrue(runbook.descriptorOnly)
        XCTAssertTrue(runbook.artifactsMaterialized)
        XCTAssertEqual(runbook.omittedRuntimeState, [
            "actor_identity",
            "completion_authority",
            "credentials",
            "leases",
            "provider_registry",
            "runtime_handles",
        ])
        XCTAssertEqual(runbook.artifacts.scaffoldIndexPath, "scaffold.json")
        XCTAssertEqual(runbook.artifacts.runtimeSourcePackagePath, "runtime-source-package.json")
        XCTAssertEqual(runbook.artifacts.runtimeExportPath, "runtime-export.json")
        XCTAssertEqual(runbook.artifacts.openAPIPath, "openapi.json")
        XCTAssertEqual(runbook.artifacts.modelRouterPath, "model-router.json")
        XCTAssertEqual(runbook.artifacts.onyxDriversPath, "onyx-drivers.json")
        XCTAssertEqual(runbook.artifacts.planningPath, "planning.json")
        XCTAssertEqual(runbook.artifacts.workflowAPIMountsPath, "api-mounts")
        XCTAssertEqual(runbook.artifacts.workflowREPLMountsPath, "repl-mounts")
        XCTAssertEqual(runbook.artifacts.workflowModelToolsPath, "model-tools")
        XCTAssertEqual(runbook.artifacts.workflowOnyxDriversPath, "onyx-drivers")
        XCTAssertEqual(runbook.artifacts.workflowSkillTreesPath, "skill-trees")
        XCTAssertEqual(runbook.artifacts.workflowToolBindingsPath, "tool-bindings")
        XCTAssertEqual(runbook.artifacts.workflowPlanningPath, "planning")
        XCTAssertEqual(runbook.artifacts.workflowRunbooksPath, "workflow-runbooks")
        XCTAssertEqual(runbook.artifacts.workflowBindingsPath, "workflow-bindings")
        XCTAssertEqual(runbook.artifacts.hostWiringPath, "host-wiring.json")
        XCTAssertEqual(runbook.artifacts.attachmentsPath, "attachments.json")
        XCTAssertEqual(runbook.launchDescriptor, scaffold.launchDescriptor)
        let workflowRunbook = try XCTUnwrap(runbook.workflows.first)
        XCTAssertEqual(workflowRunbook.workflowID, "langgraph.review")
        XCTAssertEqual(workflowRunbook.workflowVersion, attachment.workflowVersion)
        XCTAssertEqual(workflowRunbook.workflowName, attachment.workflowName)
        XCTAssertEqual(workflowRunbook.role, "reviewer")
        XCTAssertEqual(workflowRunbook.apiBasePath, "/source")
        XCTAssertEqual(workflowRunbook.apiWorkflowPath, "/workflows/langgraph.review")
        XCTAssertEqual(workflowRunbook.attachmentPath, "attachments/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.replScriptPath, "repl-scripts/langgraph.review.repl")
        XCTAssertEqual(workflowRunbook.replMountPath, "repl-mounts/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.apiScriptPath, "api-scripts/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.apiMountPath, "api-mounts/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.modelScriptPath, "model-scripts/langgraph.review.prompts")
        XCTAssertEqual(workflowRunbook.modelToolPath, "model-tools/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.workflowRunbookPath, "workflow-runbooks/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.onyxDriverPath, "onyx-drivers/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.skillTreePath, "skill-trees/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.toolBindingsPath, "tool-bindings/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.planningBundlePath, "planning/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.workflowBindingPath, "workflow-bindings/langgraph.review.json")
        XCTAssertEqual(workflowRunbook.hostBindingChannels, expectedHostBindingChannels)
        XCTAssertEqual(workflowBinding.schemaVersion, KistRunner.SMLRuntimeHostScaffoldWorkflowBinding.currentSchemaVersion)
        XCTAssertEqual(workflowBinding.workflowID, workflowRunbook.workflowID)
        XCTAssertEqual(workflowBinding.apiTaskPath, "/source/workflows/langgraph.review/tasks")
        XCTAssertEqual(workflowBinding.hostBindingChannels, expectedHostBindingChannels)
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["custom_repl"], "repl-mounts/langgraph.review.json")
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["custom_api"], "api-mounts/langgraph.review.json")
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["model_tool"], "model-tools/langgraph.review.json")
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["model_router"], "model-router.json")
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["onyx_driver"], "onyx-drivers/langgraph.review.json")
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["skill_tree"], "skill-trees/langgraph.review.json")
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["tool_bindings"], "tool-bindings/langgraph.review.json")
        XCTAssertEqual(workflowBinding.localArtifactPathsByChannel["planning_workflow"], "planning/langgraph.review.json")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["custom_repl"], "/source/runtime/repl-mounts/langgraph.review")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["custom_api"], "/source/runtime/api-mounts/langgraph.review")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["model_tool"], "/source/runtime/model-tools/langgraph.review")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["model_router"], "/source/runtime/model-router")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["onyx_driver"], "/source/runtime/onyx-drivers/langgraph.review")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["skill_tree"], "/source/runtime/skill-trees/langgraph.review")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["tool_bindings"], "/source/runtime/tool-bindings/langgraph.review")
        XCTAssertEqual(workflowBinding.runtimeMetadataPathsByChannel["planning_workflow"], "/source/runtime/planning/langgraph.review")
        XCTAssertEqual(workflowBinding.modelToolName, workflowRunbook.modelToolName)
        XCTAssertEqual(workflowBinding.modelRouterToolName, workflowRunbook.modelRouterToolName)
        XCTAssertEqual(workflowBinding.onyxDriverID, workflowRunbook.onyxDriverID)
        XCTAssertEqual(workflowBinding.planningWorkflowID, workflowRunbook.planningWorkflowID)
        XCTAssertEqual(workflowBinding.replTranscriptCommand, workflowRunbook.replTranscriptCommand)
        XCTAssertEqual(workflowBinding.apiTranscriptCommand, workflowRunbook.apiTranscriptCommand)
        XCTAssertEqual(workflowBinding.modelTranscriptCommand, workflowRunbook.modelTranscriptCommand)
        XCTAssertEqual(
            workflowRunbook.runtimeWorkflowMetadata,
            SMLWorkflowRuntimeWorkflowMetadataLinks(
                workflowID: "langgraph.review",
                workflowVersion: attachment.workflowVersion,
                apiBasePath: "/source"
            )
        )
        XCTAssertEqual(workflowRunbook.runtimeWorkflowAttachmentPath, "/source/runtime/attachments/langgraph.review")
        XCTAssertEqual(workflowRunbook.runtimeWorkflowREPLMountPath, "/source/runtime/repl-mounts/langgraph.review")
        XCTAssertEqual(workflowRunbook.runtimeWorkflowAPIMountPath, "/source/runtime/api-mounts/langgraph.review")
        XCTAssertEqual(workflowRunbook.runtimeWorkflowModelToolPath, "/source/runtime/model-tools/langgraph.review")
        XCTAssertEqual(workflowRunbook.runtimeWorkflowOnyxDriverPath, "/source/runtime/onyx-drivers/langgraph.review")
        XCTAssertEqual(workflowRunbook.runtimeWorkflowSkillTreePath, "/source/runtime/skill-trees/langgraph.review")
        XCTAssertEqual(workflowRunbook.runtimeWorkflowToolBindingsPath, "/source/runtime/tool-bindings/langgraph.review")
        XCTAssertEqual(workflowRunbook.runtimeWorkflowPlanningPath, "/source/runtime/planning/langgraph.review")
        XCTAssertEqual(workflowRunbook.replMount, attachment.replMount)
        XCTAssertEqual(workflowRunbook.replGrammar, attachment.replMount.grammar)
        XCTAssertEqual(workflowRunbook.replCommands, attachment.replMount.commands)
        XCTAssertEqual(workflowRunbook.replExamples, attachment.replMount.examples)
        XCTAssertEqual(workflowRunbook.apiMounts, attachment.apiRoutes)
        XCTAssertEqual(workflowRunbook.modelTool, workflowModelTool)
        XCTAssertTrue(workflowRunbook.replScript.contains("kist --sml-runtime-repl-script ."))
        XCTAssertTrue(workflowRunbook.replScript.contains("repl-mount"))
        XCTAssertTrue(workflowRunbook.replScript.contains("api-mount"))
        XCTAssertTrue(workflowRunbook.replScript.contains("model-tool"))
        XCTAssertTrue(workflowRunbook.replScript.contains("onyx-driver"))
        XCTAssertTrue(workflowRunbook.replScript.contains("skill-tree-json"))
        XCTAssertTrue(workflowRunbook.replScript.contains("tool-bindings-json"))
        XCTAssertTrue(workflowRunbook.replScript.contains("planning-bundle"))
        XCTAssertTrue(workflowRunbook.replScript.contains("start TASK-SCAFFOLD"))
        XCTAssertEqual(workflowRunbook.apiScript.count, 12)
        XCTAssertEqual(workflowRunbook.apiScript.map(\.path), [
            "/source/workflows/langgraph.review",
            "/source/workflows/langgraph.review/tasks",
            "/source/workflows/langgraph.review/tasks/TASK-SCAFFOLD",
            "/source/workflows/langgraph.review/tasks/TASK-SCAFFOLD/receipts",
            "/source/runtime/attachments/langgraph.review",
            "/source/runtime/repl-mounts/langgraph.review",
            "/source/runtime/api-mounts/langgraph.review",
            "/source/runtime/model-tools/langgraph.review",
            "/source/runtime/onyx-drivers/langgraph.review",
            "/source/runtime/skill-trees/langgraph.review",
            "/source/runtime/tool-bindings/langgraph.review",
            "/source/runtime/planning/langgraph.review",
        ])
        XCTAssertTrue(workflowRunbook.modelScript.contains("kist --sml-runtime-model-script ."))
        XCTAssertTrue(workflowRunbook.modelScript.contains("Start langgraph.review as task TASK-SCAFFOLD"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("Runtime metadata APIs: attachment GET /source/runtime/attachments/langgraph.review"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("planning bundle GET /source/runtime/planning/langgraph.review"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("Local scaffold artifacts: attachments/langgraph.review.json"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("planning/langgraph.review.json"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("smallest admitted command"))
        XCTAssertEqual(workflowRunbook.replTranscriptCommand.executable, "kist")
        XCTAssertEqual(workflowRunbook.replTranscriptCommand.workingDirectory, outputURL.path)
        XCTAssertEqual(workflowRunbook.replTranscriptCommand.arguments, [
            "--sml-runtime-repl-script", ".",
            "--sml-script", "repl-scripts/langgraph.review.repl",
            "--sml-workflow", "langgraph.review",
        ])
        XCTAssertFalse(workflowRunbook.replTranscriptCommand.requiresProviderBinding)
        XCTAssertEqual(workflowRunbook.apiTranscriptCommand.arguments, [
            "--sml-runtime-api-script", ".",
            "--sml-api-script", "api-scripts/langgraph.review.json",
        ])
        XCTAssertFalse(workflowRunbook.apiTranscriptCommand.requiresProviderBinding)
        XCTAssertEqual(workflowRunbook.modelTranscriptCommand.arguments, [
            "--sml-runtime-model-script", ".",
            "--sml-model-script", "model-scripts/langgraph.review.prompts",
            "--provider", "<provider>",
            "--model", "<model>",
        ])
        XCTAssertTrue(workflowRunbook.modelTranscriptCommand.requiresProviderBinding)
        XCTAssertEqual(workflowRunbook.modelToolName, attachment.modelToolName)
        XCTAssertEqual(workflowRunbook.modelRouterToolName, attachment.modelRouterToolName)
        XCTAssertEqual(workflowRunbook.onyxDriverID, attachment.onyxDriverID)
        XCTAssertEqual(workflowRunbook.planningWorkflowID, attachment.planningWorkflowID)
        XCTAssertEqual(workflowRunbook.plannerEntrypoint, attachment.plannerEntrypoint)
        XCTAssertEqual(workflowRunbook.skillIDs, ["plan", "receipt", "write"])
        XCTAssertEqual(workflowRunbook.toolReferences, attachment.toolReferences)
        XCTAssertEqual(
            workflowRunbook.decomposableUnitIDs,
            Array(Set(attachment.decomposableUnits.map(\.instructionID))).sorted()
        )
        XCTAssertEqual(
            workflowRunbook.approvalGateIDs,
            Array(Set(attachment.approvalGates.map(\.instructionID))).sorted()
        )
        XCTAssertEqual(workflowRunbook.commandActions.count, 7)
        XCTAssertEqual(workflowRunbook.apiEndpoints.count, attachment.apiRoutes.count)
        XCTAssertTrue(workflowRunbook.apiEndpoints.contains {
            $0.method == .post
                && $0.pathTemplate == "/source/workflows/langgraph.review/tasks"
                && $0.action == .start
        })
        XCTAssertTrue(workflowRunbook.apiEndpoints.contains {
            $0.method == .get
                && $0.pathTemplate == "/source/workflows/langgraph.review/tasks/{task_id}/receipts"
                && $0.action == .receipts
        })
        let perWorkflowRunbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldWorkflowRunbook.self,
            from: Data(contentsOf: outputURL.appendingPathComponent("workflow-runbooks/langgraph.review.json"))
        )
        XCTAssertEqual(perWorkflowRunbook, workflowRunbook)

        var staleRunbookPathMapObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
            ) as? [String: Any]
        )
        staleRunbookPathMapObject["workflowPlanningBundlePathsByWorkflowID"] = [
            "langgraph.review": "planning/wrong.json",
        ]
        do {
            _ = try JSONDecoder().decode(
                KistRunner.SMLRuntimeHostScaffoldRunbook.self,
                from: JSONSerialization.data(withJSONObject: staleRunbookPathMapObject, options: [.sortedKeys])
            )
            XCTFail("runbook decode should fail closed when a supplied workflow artifact map is stale")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("workflowPlanningBundlePathsByWorkflowID disagrees with workflow runbook cards"),
                String(describing: error)
            )
        }

        var staleRunbookBindingPathMapObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
            ) as? [String: Any]
        )
        staleRunbookBindingPathMapObject["workflowBindingPathsByWorkflowID"] = [
            "langgraph.review": "workflow-bindings/wrong.json",
        ]
        do {
            _ = try JSONDecoder().decode(
                KistRunner.SMLRuntimeHostScaffoldRunbook.self,
                from: JSONSerialization.data(withJSONObject: staleRunbookBindingPathMapObject, options: [.sortedKeys])
            )
            XCTFail("runbook decode should fail closed when a supplied workflow binding map is stale")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("workflowBindingPathsByWorkflowID disagrees with workflow runbook cards"),
                String(describing: error)
            )
        }

        var staleRunbookWorkflowIDsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
            ) as? [String: Any]
        )
        staleRunbookWorkflowIDsObject["workflowIDs"] = [
            "langgraph.review",
            "ghost.workflow",
        ]
        do {
            _ = try JSONDecoder().decode(
                KistRunner.SMLRuntimeHostScaffoldRunbook.self,
                from: JSONSerialization.data(withJSONObject: staleRunbookWorkflowIDsObject, options: [.sortedKeys])
            )
            XCTFail("runbook decode should fail closed when workflowIDs disagrees with workflow cards")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("workflowIDs disagrees with workflow runbook cards"),
                String(describing: error)
            )
        }

        var staleRunbookChannelMapObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
            ) as? [String: Any]
        )
        staleRunbookChannelMapObject["workflowHostBindingChannelsByWorkflowID"] = [
            "langgraph.review": ["custom_api"],
        ]
        do {
            _ = try JSONDecoder().decode(
                KistRunner.SMLRuntimeHostScaffoldRunbook.self,
                from: JSONSerialization.data(withJSONObject: staleRunbookChannelMapObject, options: [.sortedKeys])
            )
            XCTFail("runbook decode should fail closed when a supplied workflow channel map is stale")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("workflowHostBindingChannelsByWorkflowID disagrees with workflow runbook cards"),
                String(describing: error)
            )
        }

        var staleRunbookWorkflowCardObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
            ) as? [String: Any]
        )
        var staleWorkflowCards = try XCTUnwrap(
            staleRunbookWorkflowCardObject["workflows"] as? [[String: Any]]
        )
        staleWorkflowCards[0]["modelToolName"] = "wrong.model.tool"
        staleRunbookWorkflowCardObject["workflows"] = staleWorkflowCards
        do {
            _ = try JSONDecoder().decode(
                KistRunner.SMLRuntimeHostScaffoldRunbook.self,
                from: JSONSerialization.data(withJSONObject: staleRunbookWorkflowCardObject, options: [.sortedKeys])
            )
            XCTFail("runbook decode should fail closed when a workflow card disagrees with launch wiring")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("disagrees with launchDescriptor host wiring attachment"),
                String(describing: error)
            )
        }

        var duplicateRunbookWorkflowObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
            ) as? [String: Any]
        )
        var duplicatedWorkflowObjects = try XCTUnwrap(
            duplicateRunbookWorkflowObject["workflows"] as? [[String: Any]]
        )
        duplicatedWorkflowObjects.append(duplicatedWorkflowObjects[0])
        duplicateRunbookWorkflowObject["workflows"] = duplicatedWorkflowObjects
        duplicateRunbookWorkflowObject["apiBasePaths"] = ["/source"]
        duplicateRunbookWorkflowObject["workflowIDs"] = ["langgraph.review"]
        do {
            _ = try JSONDecoder().decode(
                KistRunner.SMLRuntimeHostScaffoldRunbook.self,
                from: JSONSerialization.data(withJSONObject: duplicateRunbookWorkflowObject, options: [.sortedKeys])
            )
            XCTFail("runbook decode should fail closed before duplicate workflow cards can corrupt indexes")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("workflows must not contain duplicate workflowID values"),
                String(describing: error)
            )
        }

        var legacyRunbookObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: outputURL.appendingPathComponent("runbook.json"))
            ) as? [String: Any]
        )
        legacyRunbookObject["schemaVersion"] = 5
        [
            "workflowAttachmentPathsByWorkflowID",
            "workflowRunbookPathsByWorkflowID",
            "workflowREPLScriptPathsByWorkflowID",
            "workflowREPLMountPathsByWorkflowID",
            "workflowAPIScriptPathsByWorkflowID",
            "workflowAPIMountPathsByWorkflowID",
            "workflowModelScriptPathsByWorkflowID",
            "workflowModelToolPathsByWorkflowID",
            "workflowOnyxDriverPathsByWorkflowID",
            "workflowSkillTreePathsByWorkflowID",
            "workflowToolBindingPathsByWorkflowID",
            "workflowPlanningBundlePathsByWorkflowID",
            "workflowBindingPathsByWorkflowID",
            "workflowHostBindingChannelsByWorkflowID",
        ].forEach { legacyRunbookObject.removeValue(forKey: $0) }
        legacyRunbookObject.removeValue(forKey: "runtimeWorkflowMetadataByWorkflowID")
        var legacyWorkflowObjects = try XCTUnwrap(
            legacyRunbookObject["workflows"] as? [[String: Any]]
        )
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowMetadata")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowAttachmentPath")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowREPLMountPath")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowAPIMountPath")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowModelToolPath")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowOnyxDriverPath")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowSkillTreePath")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowToolBindingsPath")
        legacyWorkflowObjects[0].removeValue(forKey: "runtimeWorkflowPlanningPath")
        legacyWorkflowObjects[0].removeValue(forKey: "replMountPath")
        legacyWorkflowObjects[0].removeValue(forKey: "replMount")
        legacyWorkflowObjects[0].removeValue(forKey: "replGrammar")
        legacyWorkflowObjects[0].removeValue(forKey: "replCommands")
        legacyWorkflowObjects[0].removeValue(forKey: "replExamples")
        legacyWorkflowObjects[0].removeValue(forKey: "apiMountPath")
        legacyWorkflowObjects[0].removeValue(forKey: "apiMounts")
        legacyWorkflowObjects[0].removeValue(forKey: "modelToolPath")
        legacyWorkflowObjects[0].removeValue(forKey: "modelTool")
        legacyWorkflowObjects[0].removeValue(forKey: "workflowBindingPath")
        legacyWorkflowObjects[0].removeValue(forKey: "hostBindingChannels")
        if var legacyArtifacts = legacyRunbookObject["artifacts"] as? [String: Any] {
            legacyArtifacts.removeValue(forKey: "workflowAPIMountsPath")
            legacyArtifacts.removeValue(forKey: "workflowREPLMountsPath")
            legacyArtifacts.removeValue(forKey: "workflowModelToolsPath")
            legacyArtifacts.removeValue(forKey: "workflowBindingsPath")
            legacyRunbookObject["artifacts"] = legacyArtifacts
        }
        legacyRunbookObject["workflows"] = legacyWorkflowObjects
        let legacyRunbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: JSONSerialization.data(withJSONObject: legacyRunbookObject, options: [.sortedKeys])
        )
        XCTAssertEqual(legacyRunbook.schemaVersion, 5)
        XCTAssertEqual(legacyRunbook.workflowAttachmentPathsByWorkflowID, [
            "langgraph.review": "attachments/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowRunbookPathsByWorkflowID, [
            "langgraph.review": "workflow-runbooks/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowREPLScriptPathsByWorkflowID, [
            "langgraph.review": "repl-scripts/langgraph.review.repl",
        ])
        XCTAssertEqual(legacyRunbook.workflowREPLMountPathsByWorkflowID, [
            "langgraph.review": "repl-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowAPIScriptPathsByWorkflowID, [
            "langgraph.review": "api-scripts/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowAPIMountPathsByWorkflowID, [
            "langgraph.review": "api-mounts/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowModelScriptPathsByWorkflowID, [
            "langgraph.review": "model-scripts/langgraph.review.prompts",
        ])
        XCTAssertEqual(legacyRunbook.workflowModelToolPathsByWorkflowID, [
            "langgraph.review": "model-tools/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowOnyxDriverPathsByWorkflowID, [
            "langgraph.review": "onyx-drivers/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowSkillTreePathsByWorkflowID, [
            "langgraph.review": "skill-trees/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowToolBindingPathsByWorkflowID, [
            "langgraph.review": "tool-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowPlanningBundlePathsByWorkflowID, [
            "langgraph.review": "planning/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowBindingPathsByWorkflowID, [
            "langgraph.review": "workflow-bindings/langgraph.review.json",
        ])
        XCTAssertEqual(legacyRunbook.workflowHostBindingChannelsByWorkflowID, [
            "langgraph.review": [],
        ])
        XCTAssertEqual(
            legacyRunbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            legacyRunbook.runtimeWorkflowMetadataByWorkflowID["langgraph.review"]?.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(
            legacyRunbook.workflows.first?.runtimeWorkflowAttachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            legacyRunbook.workflows.first?.runtimeWorkflowREPLMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            legacyRunbook.workflows.first?.runtimeWorkflowAPIMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            legacyRunbook.workflows.first?.runtimeWorkflowModelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            legacyRunbook.workflows.first?.runtimeWorkflowPlanningPath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(
            legacyRunbook.workflows.first?.replMountPath,
            "repl-mounts/langgraph.review.json"
        )
        XCTAssertEqual(legacyRunbook.workflows.first?.replMount.workflowID, "langgraph.review")
        XCTAssertEqual(legacyRunbook.workflows.first?.replCommands, [])
        XCTAssertEqual(
            legacyRunbook.workflows.first?.apiMountPath,
            "api-mounts/langgraph.review.json"
        )
        XCTAssertEqual(legacyRunbook.workflows.first?.apiMounts, [])
        XCTAssertEqual(
            legacyRunbook.workflows.first?.modelToolPath,
            "model-tools/langgraph.review.json"
        )
        XCTAssertEqual(
            legacyRunbook.workflows.first?.workflowBindingPath,
            "workflow-bindings/langgraph.review.json"
        )
        XCTAssertEqual(legacyRunbook.workflows.first?.modelTool.workflowID, "langgraph.review")
        XCTAssertEqual(legacyRunbook.workflows.first?.modelTool.allowedActions, [])
        XCTAssertEqual(legacyRunbook.artifacts.workflowAPIMountsPath, "api-mounts")
        XCTAssertEqual(legacyRunbook.artifacts.workflowREPLMountsPath, "repl-mounts")
        XCTAssertEqual(legacyRunbook.artifacts.workflowModelToolsPath, "model-tools")
        XCTAssertEqual(legacyRunbook.artifacts.workflowBindingsPath, "workflow-bindings")

        let directManifestRunbookJSON = try await KistRunner.renderSMLRuntimeHostRunbook(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let directManifestRunbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(directManifestRunbookJSON.utf8)
        )
        XCTAssertEqual(directManifestRunbook.sourcePath, manifestURL.path)
        XCTAssertEqual(directManifestRunbook.sourceFormat, .langGraphManifest)
        XCTAssertEqual(directManifestRunbook.outputDirectory, directory.path)
        XCTAssertFalse(directManifestRunbook.artifactsMaterialized)
        XCTAssertEqual(directManifestRunbook.apiWorkflowPathsByWorkflowID, runbook.apiWorkflowPathsByWorkflowID)
        XCTAssertEqual(directManifestRunbook.apiTaskPathsByWorkflowID, runbook.apiTaskPathsByWorkflowID)
        XCTAssertEqual(
            directManifestRunbook.workflowPlanningBundlePathsByWorkflowID,
            runbook.workflowPlanningBundlePathsByWorkflowID
        )
        XCTAssertEqual(
            directManifestRunbook.workflowBindingPathsByWorkflowID,
            runbook.workflowBindingPathsByWorkflowID
        )
        XCTAssertEqual(
            directManifestRunbook.workflowModelToolPathsByWorkflowID,
            runbook.workflowModelToolPathsByWorkflowID
        )
        XCTAssertEqual(directManifestRunbook.workflows.first?.replMountPath, "repl-mounts/langgraph.review.json")
        XCTAssertEqual(directManifestRunbook.workflows.first?.replMount.apiWorkflowPath, "/workflows/langgraph.review")
        XCTAssertEqual(directManifestRunbook.workflows.first?.replCommands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertEqual(directManifestRunbook.workflows.first?.apiMountPath, "api-mounts/langgraph.review.json")
        XCTAssertEqual(directManifestRunbook.workflows.first?.apiMounts.first { $0.action == .start }?.pathTemplate, "/source/workflows/langgraph.review/tasks")
        XCTAssertEqual(directManifestRunbook.workflows.first?.modelToolPath, "model-tools/langgraph.review.json")
        XCTAssertEqual(directManifestRunbook.workflows.first?.modelTool.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(directManifestRunbook.workflows.first?.modelScriptPath, "model-scripts/langgraph.review.prompts")
        XCTAssertEqual(directManifestRunbook.workflows.first?.apiScript.count, 12)
        XCTAssertTrue(directManifestRunbook.workflows.first?.replScript.contains("start TASK-SCAFFOLD") == true)
        XCTAssertTrue(directManifestRunbook.workflows.first?.modelScript.contains("List receipts for langgraph.review") == true)
        XCTAssertTrue(directManifestRunbook.workflows.first?.modelScript.contains("skill tree GET /source/runtime/skill-trees/langgraph.review") == true)
        XCTAssertTrue(directManifestRunbook.workflows.first?.modelScript.contains("tool-bindings/langgraph.review.json") == true)
        XCTAssertEqual(directManifestRunbook.workflows.first?.modelTranscriptCommand.arguments, [
            "--sml-runtime-model-script", ".",
            "--sml-model-script", "model-scripts/langgraph.review.prompts",
            "--provider", "<provider>",
            "--model", "<model>",
        ])
        XCTAssertFalse(directManifestRunbookJSON.contains("operator.test"))
        XCTAssertFalse(directManifestRunbookJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(directManifestRunbookJSON.contains("authenticatedActor"))

        let directScaffoldRunbookJSON = try await KistRunner.renderSMLRuntimeHostRunbook(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let directScaffoldRunbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(directScaffoldRunbookJSON.utf8)
        )
        XCTAssertEqual(directScaffoldRunbook.sourcePath, indexURL.path)
        XCTAssertEqual(directScaffoldRunbook.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(directScaffoldRunbook.outputDirectory, outputURL.path)
        XCTAssertEqual(directScaffoldRunbook.workflowIDs, runbook.workflowIDs)
        XCTAssertEqual(directScaffoldRunbook.apiBasePaths, runbook.apiBasePaths)
        XCTAssertEqual(directScaffoldRunbook.apiWorkflowPathsByWorkflowID, runbook.apiWorkflowPathsByWorkflowID)
        XCTAssertEqual(directScaffoldRunbook.apiTaskPathsByWorkflowID, runbook.apiTaskPathsByWorkflowID)
        XCTAssertEqual(
            directScaffoldRunbook.workflowOnyxDriverPathsByWorkflowID,
            runbook.workflowOnyxDriverPathsByWorkflowID
        )
        XCTAssertEqual(
            directScaffoldRunbook.workflowSkillTreePathsByWorkflowID,
            runbook.workflowSkillTreePathsByWorkflowID
        )
        XCTAssertEqual(
            directScaffoldRunbook.workflowToolBindingPathsByWorkflowID,
            runbook.workflowToolBindingPathsByWorkflowID
        )
        XCTAssertEqual(
            directScaffoldRunbook.workflowPlanningBundlePathsByWorkflowID,
            runbook.workflowPlanningBundlePathsByWorkflowID
        )
        XCTAssertEqual(
            directScaffoldRunbook.workflowBindingPathsByWorkflowID,
            runbook.workflowBindingPathsByWorkflowID
        )
        XCTAssertTrue(directScaffoldRunbook.descriptorOnly)
        XCTAssertTrue(directScaffoldRunbook.artifactsMaterialized)
        XCTAssertEqual(directScaffoldRunbook.artifacts, runbook.artifacts)
        XCTAssertEqual(directScaffoldRunbook.workflows, runbook.workflows)
        XCTAssertEqual(directScaffoldRunbook.launchDescriptor, runbook.launchDescriptor)
        XCTAssertFalse(directScaffoldRunbookJSON.contains("operator.test"))
        XCTAssertFalse(directScaffoldRunbookJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(directScaffoldRunbookJSON.contains("authenticatedActor"))

        let readme = try String(contentsOf: outputURL.appendingPathComponent("README.md"))
        XCTAssertTrue(readme.contains("Host wiring order"))
        XCTAssertTrue(readme.contains("Workflow API paths"))
        XCTAssertTrue(readme.contains("Per-workflow wiring cards"))
        XCTAssertTrue(readme.contains("langgraph.review: `/workflows/langgraph.review` mounted at `/source/workflows/langgraph.review/tasks`"))
        XCTAssertTrue(readme.contains("Task endpoint: `/source/workflows/langgraph.review/tasks`"))
        XCTAssertTrue(readme.contains("Workflow runbook: `workflow-runbooks/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Workflow binding manifest: `workflow-bindings/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("REPL mount: `repl-mounts/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("API mount: `api-mounts/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Model tool descriptor: `model-tools/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Onyx driver: `onyx-drivers/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Skill tree: `skill-trees/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Tool bindings: `tool-bindings/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Planning bundle: `planning/langgraph.review.json`"))
        XCTAssertTrue(readme.contains("Runtime metadata APIs: attachment `GET /source/runtime/attachments/langgraph.review`"))
        XCTAssertTrue(readme.contains("REPL mount `GET /source/runtime/repl-mounts/langgraph.review`"))
        XCTAssertTrue(readme.contains("API mount `GET /source/runtime/api-mounts/langgraph.review`"))
        XCTAssertTrue(readme.contains("model tool `GET /source/runtime/model-tools/langgraph.review`"))
        XCTAssertTrue(readme.contains("tool bindings `GET /source/runtime/tool-bindings/langgraph.review`"))
        XCTAssertTrue(readme.contains("runbook.json"))
        XCTAssertTrue(readme.contains("api-mounts/*.json"))
        XCTAssertTrue(readme.contains("api-scripts/*.json"))
        XCTAssertTrue(readme.contains("model-tools/*.json"))
        XCTAssertTrue(readme.contains("model-scripts/*.prompts"))
        XCTAssertTrue(readme.contains("repl-mounts/*.json"))
        XCTAssertTrue(readme.contains("repl-scripts/*.repl"))
        XCTAssertTrue(readme.contains("--sml-runtime-api-script"))
        XCTAssertTrue(readme.contains("--sml-runtime-model-script"))
        XCTAssertTrue(readme.contains("--sml-runtime-repl-script"))
        XCTAssertTrue(readme.contains("State changes still have to cross the generated host command gateway"))
        let apiScript = try JSONDecoder().decode(
            [KistRunner.SMLRuntimeHostAPIRequestSpec].self,
            from: Data(contentsOf: outputURL.appendingPathComponent("api-scripts/langgraph.review.json"))
        )
        XCTAssertEqual(apiScript.count, 12)
        XCTAssertEqual(apiScript.map(\.method), [
            .get, .post, .get, .get, .get, .get, .get, .get, .get, .get, .get, .get,
        ])
        XCTAssertEqual(apiScript.map(\.path), [
            "/source/workflows/langgraph.review",
            "/source/workflows/langgraph.review/tasks",
            "/source/workflows/langgraph.review/tasks/TASK-SCAFFOLD",
            "/source/workflows/langgraph.review/tasks/TASK-SCAFFOLD/receipts",
            "/source/runtime/attachments/langgraph.review",
            "/source/runtime/repl-mounts/langgraph.review",
            "/source/runtime/api-mounts/langgraph.review",
            "/source/runtime/model-tools/langgraph.review",
            "/source/runtime/onyx-drivers/langgraph.review",
            "/source/runtime/skill-trees/langgraph.review",
            "/source/runtime/tool-bindings/langgraph.review",
            "/source/runtime/planning/langgraph.review",
        ])
        XCTAssertEqual(apiScript[1].body["task_id"], .string("TASK-SCAFFOLD"))
        XCTAssertEqual(try object(apiScript[1].body["input"])["topic"], .string("topic"))
        let scaffoldScript = try String(
            contentsOf: outputURL.appendingPathComponent("repl-scripts/langgraph.review.repl")
        )
        XCTAssertEqual(workflowRunbook.replScript, scaffoldScript)
        XCTAssertTrue(scaffoldScript.contains("kist --sml-runtime-repl-script ."))
        XCTAssertTrue(scaffoldScript.contains("skill-tree"))
        XCTAssertTrue(scaffoldScript.contains("tool-bindings"))
        XCTAssertTrue(scaffoldScript.contains("repl-mount"))
        XCTAssertTrue(scaffoldScript.contains("api-mount"))
        XCTAssertTrue(scaffoldScript.contains("model-tool"))
        XCTAssertTrue(scaffoldScript.contains("onyx-driver"))
        XCTAssertTrue(scaffoldScript.contains("skill-tree-json"))
        XCTAssertTrue(scaffoldScript.contains("tool-bindings-json"))
        XCTAssertTrue(scaffoldScript.contains("planning-bundle"))
        XCTAssertTrue(scaffoldScript.contains("start TASK-SCAFFOLD"))
        XCTAssertTrue(scaffoldScript.contains("watch TASK-SCAFFOLD"))
        let modelPromptScript = try String(
            contentsOf: outputURL.appendingPathComponent("model-scripts/langgraph.review.prompts")
        )
        XCTAssertEqual(workflowRunbook.modelScript, modelPromptScript)
        XCTAssertEqual(workflowRunbook.apiScript, apiScript)
        XCTAssertTrue(modelPromptScript.contains("kist --sml-runtime-model-script ."))
        XCTAssertTrue(modelPromptScript.contains("Start langgraph.review as task TASK-SCAFFOLD"))
        XCTAssertTrue(modelPromptScript.contains("Runtime metadata APIs: attachment GET /source/runtime/attachments/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("REPL mount GET /source/runtime/repl-mounts/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("API mount GET /source/runtime/api-mounts/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("model tool GET /source/runtime/model-tools/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("Onyx driver GET /source/runtime/onyx-drivers/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("skill tree GET /source/runtime/skill-trees/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("tool bindings GET /source/runtime/tool-bindings/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("planning bundle GET /source/runtime/planning/langgraph.review"))
        XCTAssertTrue(modelPromptScript.contains("Local scaffold artifacts: attachments/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("repl-mounts/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("api-mounts/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("model-tools/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("onyx-drivers/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("skill-trees/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("tool-bindings/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("planning/langgraph.review.json"))
        XCTAssertTrue(modelPromptScript.contains("smallest admitted command"))
        XCTAssertTrue(modelPromptScript.contains("same planning/skill/tool/Onyx contract"))
        XCTAssertTrue(modelPromptScript.contains("advisory prose separate from verified completion"))
        XCTAssertTrue(modelPromptScript.contains("Watch the current langgraph.review task"))

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

        let transcriptFromDirectoryJSON = try await KistRunner.renderSMLRuntimeHostREPLTranscript(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            workflowID: "langgraph.review",
            scriptPath: "runtime-scaffold/repl-scripts/langgraph.review.repl",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let transcriptFromDirectory = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostREPLTranscript.self,
            from: Data(transcriptFromDirectoryJSON.utf8)
        )
        XCTAssertEqual(transcriptFromDirectory.sourcePath, indexURL.path)
        XCTAssertEqual(transcriptFromDirectory.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(transcriptFromDirectory.workflowID, "langgraph.review")
        XCTAssertEqual(transcriptFromDirectory.requestedLineCount, 19)
        XCTAssertEqual(transcriptFromDirectory.executedLineCount, 19)
        XCTAssertTrue(transcriptFromDirectory.stoppedAtExit)
        for artifactLine in [
            "skill-tree", "tool-bindings", "repl-mount", "api-mount", "model-tool",
            "onyx-driver", "skill-tree-json", "tool-bindings-json", "planning-bundle",
        ] {
            XCTAssertTrue(transcriptFromDirectory.turns.contains { $0.line == artifactLine })
        }
        func decodeTranscriptTurn<T: Decodable>(
            _ type: T.Type,
            line: String
        ) throws -> T {
            let turn = try XCTUnwrap(transcriptFromDirectory.turns.first {
                $0.line == line
            })
            XCTAssertNil(turn.command)
            XCTAssertNil(turn.result)
            return try JSONDecoder().decode(type, from: Data(turn.output.utf8))
        }
        XCTAssertEqual(
            try decodeTranscriptTurn(SMLWorkflowRuntimeREPLMount.self, line: "repl-mount"),
            workflowREPLMount
        )
        XCTAssertEqual(
            try decodeTranscriptTurn([SMLWorkflowRuntimeAPIMount].self, line: "api-mount"),
            workflowAPIMounts
        )
        XCTAssertEqual(
            try decodeTranscriptTurn(SMLWorkflowRuntimeModelToolExport.self, line: "model-tool"),
            workflowModelTool
        )
        XCTAssertEqual(
            try decodeTranscriptTurn(SMLOnyxDriverManifest.self, line: "onyx-driver"),
            workflowOnyxDriver
        )
        XCTAssertEqual(
            try decodeTranscriptTurn([SMLOnyxSkillNode].self, line: "skill-tree-json"),
            workflowSkillTree
        )
        XCTAssertEqual(
            try decodeTranscriptTurn([SMLOnyxToolBinding].self, line: "tool-bindings-json"),
            workflowToolBindings
        )
        let replPlanningBundle = try decodeTranscriptTurn(
            SMLWorkflowRuntimePlanningWorkflowBundle.self,
            line: "planning-bundle"
        )
        XCTAssertEqual(replPlanningBundle.workflowID, workflowPlanning.workflowID)
        XCTAssertEqual(replPlanningBundle.workflowVersion, workflowPlanning.workflowVersion)
        XCTAssertEqual(replPlanningBundle.apiBasePath, workflowPlanning.apiBasePath)
        XCTAssertEqual(replPlanningBundle.apiWorkflowPath, workflowPlanning.apiWorkflowPath)
        XCTAssertEqual(replPlanningBundle.workflowMetadata, attachment.workflowMetadata)
        XCTAssertEqual(replPlanningBundle.workflow.plan, workflowPlanning.plan)
        XCTAssertEqual(replPlanningBundle.skillIndex, workflowPlanning.skillIndex)
        XCTAssertEqual(replPlanningBundle.toolBindings, workflowPlanning.toolBindings)
        XCTAssertEqual(replPlanningBundle.decomposableUnits, workflowPlanning.decomposableUnits)
        XCTAssertEqual(replPlanningBundle.approvalGates, workflowPlanning.approvalGates)
        XCTAssertEqual(replPlanningBundle.commandBindings, workflowPlanning.commandBindings)
        let scaffoldStart = try XCTUnwrap(transcriptFromDirectory.turns.first {
            $0.command?.op == SMLRuntimeCommandOperation.workflowRun
        })
        XCTAssertEqual(scaffoldStart.command?.task, "TASK-SCAFFOLD")
        let scaffoldWatch = try XCTUnwrap(transcriptFromDirectory.turns.first {
            $0.command?.op == SMLRuntimeCommandOperation.taskWatch
        })
        XCTAssertEqual(scaffoldWatch.command?.task, "TASK-SCAFFOLD")
        XCTAssertEqual(transcriptFromDirectory.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertFalse(transcriptFromDirectoryJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(transcriptFromDirectoryJSON.contains("authenticatedActor"))

        let apiTranscriptFromDirectoryJSON = try await KistRunner.renderSMLRuntimeHostAPITranscript(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            scriptPath: "runtime-scaffold/api-scripts/langgraph.review.json",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let apiTranscriptFromDirectory = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPITranscript.self,
            from: Data(apiTranscriptFromDirectoryJSON.utf8)
        )
        XCTAssertEqual(apiTranscriptFromDirectory.sourcePath, indexURL.path)
        XCTAssertEqual(apiTranscriptFromDirectory.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(apiTranscriptFromDirectory.requestedRequestCount, 12)
        XCTAssertEqual(apiTranscriptFromDirectory.executedRequestCount, 12)
        XCTAssertEqual(apiTranscriptFromDirectory.exchanges.map(\.statusCode), [
            200, 201, 200, 200, 200, 200, 200, 200, 200, 200, 200, 200,
        ])
        XCTAssertEqual(apiTranscriptFromDirectory.exchanges[1].command?.task, "TASK-SCAFFOLD")
        XCTAssertEqual(apiTranscriptFromDirectory.exchanges[2].command?.task, "TASK-SCAFFOLD")
        func decodeAPITranscriptMetadata<T: Decodable>(
            _ type: T.Type,
            resource: SMLWorkflowRuntimeMetadataResource
        ) throws -> T {
            let exchange = try XCTUnwrap(apiTranscriptFromDirectory.exchanges.first {
                $0.metadataResource == resource
            })
            XCTAssertEqual(exchange.statusCode, 200)
            XCTAssertEqual(exchange.kind, .metadata)
            XCTAssertNil(exchange.command)
            XCTAssertNil(exchange.result)
            return try JSONDecoder().decode(
                type,
                from: JSONEncoder().encode(exchange.responseBody)
            )
        }
        XCTAssertEqual(
            try decodeAPITranscriptMetadata(
                SMLWorkflowRuntimeWorkflowAttachmentManifest.self,
                resource: .workflowAttachment
            ),
            attachment
        )
        XCTAssertEqual(
            try decodeAPITranscriptMetadata(
                SMLWorkflowRuntimeREPLMount.self,
                resource: .workflowREPLMount
            ),
            workflowREPLMount
        )
        XCTAssertEqual(
            try decodeAPITranscriptMetadata(
                [SMLWorkflowRuntimeAPIMount].self,
                resource: .workflowAPIMount
            ),
            workflowAPIMounts
        )
        XCTAssertEqual(
            try decodeAPITranscriptMetadata(
                SMLWorkflowRuntimeModelToolExport.self,
                resource: .workflowModelTool
            ),
            workflowModelTool
        )
        XCTAssertEqual(
            try decodeAPITranscriptMetadata(
                SMLOnyxDriverManifest.self,
                resource: .workflowOnyxDriver
            ),
            workflowOnyxDriver
        )
        XCTAssertEqual(
            try decodeAPITranscriptMetadata(
                [SMLOnyxSkillNode].self,
                resource: .workflowSkillTree
            ),
            workflowSkillTree
        )
        XCTAssertEqual(
            try decodeAPITranscriptMetadata(
                [SMLOnyxToolBinding].self,
                resource: .workflowToolBindings
            ),
            workflowToolBindings
        )
        let apiPlanningBundle = try decodeAPITranscriptMetadata(
            SMLWorkflowRuntimePlanningWorkflowBundle.self,
            resource: .workflowPlanning
        )
        XCTAssertEqual(apiPlanningBundle.workflowID, workflowPlanning.workflowID)
        XCTAssertEqual(apiPlanningBundle.workflowVersion, workflowPlanning.workflowVersion)
        XCTAssertEqual(apiPlanningBundle.workflowMetadata, attachment.workflowMetadata)
        XCTAssertEqual(apiPlanningBundle.workflow.plan, workflowPlanning.plan)
        XCTAssertEqual(apiPlanningBundle.skillIndex, workflowPlanning.skillIndex)
        XCTAssertEqual(apiPlanningBundle.toolBindings, workflowPlanning.toolBindings)
        XCTAssertEqual(apiPlanningBundle.decomposableUnits, workflowPlanning.decomposableUnits)
        XCTAssertEqual(apiPlanningBundle.approvalGates, workflowPlanning.approvalGates)
        XCTAssertEqual(apiPlanningBundle.commandBindings, workflowPlanning.commandBindings)
        XCTAssertEqual(apiTranscriptFromDirectory.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertFalse(apiTranscriptFromDirectoryJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(apiTranscriptFromDirectoryJSON.contains("authenticatedActor"))

        let scaffoldModelProvider = ScriptedSMLRuntimeProvider([
            .textAndCall(
                "Starting from scaffold prompt.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"start TASK-SCAFFOLD {\"topic\":\"runtime\"}"}"#
            ),
            .textAndCall(
                "Watching from scaffold prompt.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"watch"}"#
            ),
            .textAndCall(
                "Listing scaffold receipts.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"receipts"}"#
            ),
            .text("Receipt review complete."),
        ])
        let scaffoldModelRegistry = ProviderRegistry(
            providers: [scaffoldModelProvider],
            retryDelaysNanoseconds: []
        )
        let modelTranscriptFromDirectoryJSON = try await KistRunner.renderSMLRuntimeHostModelTranscript(
            sourcePath: "runtime-scaffold",
            projectRoot: directory.path,
            scriptPath: "runtime-scaffold/model-scripts/langgraph.review.prompts",
            binding: ProviderBinding(
                providerId: scaffoldModelProvider.id,
                model: scaffoldModelProvider.defaultModel
            ),
            providers: scaffoldModelRegistry,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let modelTranscriptFromDirectory = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelTranscript.self,
            from: Data(modelTranscriptFromDirectoryJSON.utf8)
        )
        XCTAssertEqual(modelTranscriptFromDirectory.sourcePath, indexURL.path)
        XCTAssertEqual(modelTranscriptFromDirectory.sourceFormat, .runtimeScaffold)
        XCTAssertEqual(modelTranscriptFromDirectory.promptCount, 3)
        XCTAssertEqual(modelTranscriptFromDirectory.providerRequestLimit, 9)
        XCTAssertEqual(modelTranscriptFromDirectory.providerRequestsConsumed, 4)
        XCTAssertEqual(modelTranscriptFromDirectory.turns.map(\.providerRequestsConsumed), [1, 1, 2])
        XCTAssertEqual(modelTranscriptFromDirectory.turns[0].steps.first?.command?.task, "TASK-SCAFFOLD")
        XCTAssertEqual(modelTranscriptFromDirectory.turns[1].steps.first?.command?.task, "TASK-SCAFFOLD")
        XCTAssertEqual(modelTranscriptFromDirectory.turns[2].steps.first?.command?.task, "TASK-SCAFFOLD")
        XCTAssertEqual(modelTranscriptFromDirectory.turns[1].steps.first?.command?.op, SMLRuntimeCommandOperation.taskWatch)
        XCTAssertEqual(modelTranscriptFromDirectory.turns[2].steps.first?.command?.op, SMLRuntimeCommandOperation.receiptsList)
        XCTAssertEqual(modelTranscriptFromDirectory.turns[2].steps.last?.disposition, .advisoryOnly)
        XCTAssertEqual(modelTranscriptFromDirectory.taskIDsByWorkflowID["langgraph.review"], "TASK-SCAFFOLD")
        XCTAssertEqual(modelTranscriptFromDirectory.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertFalse(modelTranscriptFromDirectoryJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(modelTranscriptFromDirectoryJSON.contains("authenticatedActor"))

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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let missingRequiredFileScaffold = KistRunner.SMLRuntimeHostScaffold(
            schemaVersion: scaffold.schemaVersion,
            sourcePath: scaffold.sourcePath,
            sourceFormat: scaffold.sourceFormat,
            outputDirectory: scaffold.outputDirectory,
            indexPath: scaffold.indexPath,
            workflowIDs: scaffold.workflowIDs,
            apiBasePaths: scaffold.apiBasePaths,
            files: scaffold.files.filter { $0.relativePath != "skill-trees/langgraph.review.json" },
            launchDescriptor: scaffold.launchDescriptor
        )
        try encoder.encode(missingRequiredFileScaffold)
            .write(to: indexURL, options: [.atomic])
        do {
            _ = try await KistRunner.renderSMLRuntimeHostPlanning(
                sourcePath: "runtime-scaffold",
                projectRoot: directory.path
            )
            XCTFail("v2 scaffold reuse should fail closed when a required file record is missing")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("missing required file record 'skill-trees/langgraph.review.json'"),
                String(describing: error)
            )
        }
        try encoder.encode(scaffold).write(to: indexURL, options: [.atomic])

        var stalePathMapScaffoldObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any]
        )
        stalePathMapScaffoldObject["workflowSkillTreePathsByWorkflowID"] = [
            "langgraph.review": "skill-trees/wrong.json",
        ]
        try JSONSerialization.data(withJSONObject: stalePathMapScaffoldObject, options: [.sortedKeys])
            .write(to: indexURL, options: [.atomic])
        do {
            _ = try await KistRunner.renderSMLRuntimeHostPlanning(
                sourcePath: "runtime-scaffold",
                projectRoot: directory.path
            )
            XCTFail("current scaffold reuse should fail closed when a workflow path map is stale")
        } catch {
            XCTAssertTrue(
                String(describing: error)
                    .contains("workflowSkillTreePathsByWorkflowID disagrees with generated workflow artifacts"),
                String(describing: error)
            )
        }
        try encoder.encode(scaffold).write(to: indexURL, options: [.atomic])

        let workflowSkillTreeURL = outputURL.appendingPathComponent("skill-trees/langgraph.review.json")
        let originalWorkflowSkillTree = try String(contentsOf: workflowSkillTreeURL)
        try "[]".write(
            to: workflowSkillTreeURL,
            atomically: true,
            encoding: .utf8
        )
        do {
            _ = try await KistRunner.renderSMLRuntimeHostPlanning(
                sourcePath: "runtime-scaffold",
                projectRoot: directory.path
            )
            XCTFail("scaffold reuse should fail closed when a per-workflow artifact drifts")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("skill-trees/langgraph.review.json byte count changed")
                    || String(describing: error).contains("skill-trees/langgraph.review.json digest changed"),
                String(describing: error)
            )
        }
        try originalWorkflowSkillTree.write(
            to: workflowSkillTreeURL,
            atomically: true,
            encoding: .utf8
        )

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
        XCTAssertNotNil(paths["/source/runtime/repl-mounts/{workflow_id}"])
        XCTAssertNotNil(paths["/source/runtime/api-mounts/{workflow_id}"])
        XCTAssertNotNil(paths["/source/runtime/model-tools/{workflow_id}"])
        XCTAssertNotNil(paths["/source/runtime/onyx-drivers/{workflow_id}"])
        XCTAssertNotNil(paths["/source/runtime/planning"])
        XCTAssertNotNil(paths["/source/runtime/planning/{workflow_id}"])
        XCTAssertNotNil(paths["/source/runtime/skill-trees/{workflow_id}"])
        XCTAssertNotNil(paths["/source/runtime/tool-bindings/{workflow_id}"])
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
        let startMetadata = try object(start["x-sml-workflow-runtime-metadata"])
        XCTAssertEqual(
            startMetadata["attachment"],
            .string("/source/runtime/attachments/langgraph.review")
        )
        XCTAssertEqual(
            startMetadata["replMount"],
            .string("/source/runtime/repl-mounts/langgraph.review")
        )
        XCTAssertEqual(
            startMetadata["apiMount"],
            .string("/source/runtime/api-mounts/langgraph.review")
        )
        XCTAssertEqual(
            startMetadata["modelTool"],
            .string("/source/runtime/model-tools/langgraph.review")
        )
        XCTAssertEqual(
            startMetadata["onyxDriver"],
            .string("/source/runtime/onyx-drivers/langgraph.review")
        )
        XCTAssertEqual(
            startMetadata["skillTree"],
            .string("/source/runtime/skill-trees/langgraph.review")
        )
        XCTAssertEqual(
            startMetadata["toolBindings"],
            .string("/source/runtime/tool-bindings/langgraph.review")
        )
        XCTAssertEqual(
            startMetadata["planningBundle"],
            .string("/source/runtime/planning/langgraph.review")
        )
        let runtime = try object(openAPI.openAPI["x-sml-runtime"])
        XCTAssertEqual(runtime["workflowIDs"], .array([.string("langgraph.review")]))
        XCTAssertEqual(runtime["modelRouterToolName"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertEqual(runtime["mountAPIRouteCount"], .number(Decimal(27)))
        XCTAssertEqual(runtime["planningSkillIndexCount"], .number(Decimal(3)))
        let routerWorkflowMetadata = try object(try array(runtime["modelRouterWorkflowMetadata"]).first)
        XCTAssertEqual(routerWorkflowMetadata["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(
            routerWorkflowMetadata["attachmentPath"],
            .string("/source/runtime/attachments/langgraph.review")
        )
        XCTAssertEqual(
            routerWorkflowMetadata["replMountPath"],
            .string("/source/runtime/repl-mounts/langgraph.review")
        )
        XCTAssertEqual(
            routerWorkflowMetadata["apiMountPath"],
            .string("/source/runtime/api-mounts/langgraph.review")
        )
        XCTAssertEqual(
            routerWorkflowMetadata["modelToolPath"],
            .string("/source/runtime/model-tools/langgraph.review")
        )
        XCTAssertEqual(
            routerWorkflowMetadata["planningBundlePath"],
            .string("/source/runtime/planning/langgraph.review")
        )
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
        XCTAssertEqual(launch.launchDescriptor.metadataEndpoints.count, 20)
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
        XCTAssertEqual(attachment.runtimeAttachmentsPath, "/source/runtime/attachments")
        XCTAssertEqual(
            attachment.runtimeWorkflowAttachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowREPLMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowAPIMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowModelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowOnyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowSkillTreePath,
            "/source/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowToolBindingsPath,
            "/source/runtime/tool-bindings/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowPlanningPath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(
            attachment.workflowMetadata.attachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            attachment.workflowMetadata.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            attachment.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(attachment.plannerEntrypoint, "plan")
        XCTAssertEqual(attachment.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(attachment.model?.maximumCommandRounds, 3)
        XCTAssertEqual(attachment.channels, [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
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
        let planningWorkflows = try array(planning["workflows"])
        let planningWorkflow = try XCTUnwrap(planningWorkflows.first)
        let planningWorkflowMetadata = try object(
            try object(planningWorkflow)["workflowMetadata"]
        )
        XCTAssertEqual(
            planningWorkflowMetadata["replMountPath"],
            .string("/source/runtime/repl-mounts/langgraph.review")
        )
        XCTAssertEqual(
            planningWorkflowMetadata["modelToolPath"],
            .string("/source/runtime/model-tools/langgraph.review")
        )
        XCTAssertEqual(
            planningWorkflowMetadata["planningBundlePath"],
            .string("/source/runtime/planning/langgraph.review")
        )
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
        let workflowMetadata = try object(attachment["workflowMetadata"])
        XCTAssertEqual(
            workflowMetadata["attachmentPath"],
            .string("/source/runtime/attachments/langgraph.review")
        )
        XCTAssertEqual(
            workflowMetadata["planningBundlePath"],
            .string("/source/runtime/planning/langgraph.review")
        )
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

        let workflowREPLMountJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/repl-mounts/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowREPLMountAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowREPLMountJSON.utf8)
        )
        XCTAssertEqual(workflowREPLMountAPI.statusCode, 200)
        XCTAssertEqual(workflowREPLMountAPI.kind, .metadata)
        XCTAssertEqual(workflowREPLMountAPI.metadataResource, .workflowREPLMount)
        XCTAssertEqual(
            workflowREPLMountAPI.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.workflowREPLMount.operationID
        )
        XCTAssertEqual(workflowREPLMountAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowREPLMountAPI.command)
        XCTAssertNil(workflowREPLMountAPI.result)
        let workflowREPLMount = try object(workflowREPLMountAPI.responseBody)
        XCTAssertEqual(workflowREPLMount["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(workflowREPLMount["apiWorkflowPath"], .string("/workflows/langgraph.review"))
        XCTAssertTrue(try array(workflowREPLMount["commands"]).contains {
            guard case .object(let command) = $0 else { return false }
            return command["verb"] == .string("start")
        })
        XCTAssertFalse(workflowREPLMountJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowREPLMountJSON.contains("authenticatedActor"))

        let workflowAPIMountJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/api-mounts/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowAPIMountAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowAPIMountJSON.utf8)
        )
        XCTAssertEqual(workflowAPIMountAPI.statusCode, 200)
        XCTAssertEqual(workflowAPIMountAPI.kind, .metadata)
        XCTAssertEqual(workflowAPIMountAPI.metadataResource, .workflowAPIMount)
        XCTAssertEqual(
            workflowAPIMountAPI.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.workflowAPIMount.operationID
        )
        XCTAssertEqual(workflowAPIMountAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowAPIMountAPI.command)
        XCTAssertNil(workflowAPIMountAPI.result)
        let workflowAPIMount = try array(workflowAPIMountAPI.responseBody)
        XCTAssertEqual(workflowAPIMount.count, 7)
        XCTAssertTrue(workflowAPIMount.contains {
            guard case .object(let route) = $0 else { return false }
            return route["pathTemplate"] == .string("/source/workflows/langgraph.review/tasks")
                && route["operationID"] == .string("start_workflow_task_LanggraphReview")
        })
        XCTAssertFalse(workflowAPIMountJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowAPIMountJSON.contains("authenticatedActor"))

        let workflowModelToolJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/model-tools/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowModelToolAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowModelToolJSON.utf8)
        )
        XCTAssertEqual(workflowModelToolAPI.statusCode, 200)
        XCTAssertEqual(workflowModelToolAPI.kind, .metadata)
        XCTAssertEqual(workflowModelToolAPI.metadataResource, .workflowModelTool)
        XCTAssertEqual(
            workflowModelToolAPI.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.workflowModelTool.operationID
        )
        XCTAssertEqual(workflowModelToolAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowModelToolAPI.command)
        XCTAssertNil(workflowModelToolAPI.result)
        let workflowModelTool = try object(workflowModelToolAPI.responseBody)
        XCTAssertEqual(workflowModelTool["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(
            try object(workflowModelTool["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(
            try object(workflowModelTool["workflowMetadata"])["modelToolPath"],
            .string("/source/runtime/model-tools/langgraph.review")
        )
        XCTAssertFalse(workflowModelToolJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowModelToolJSON.contains("authenticatedActor"))

        let workflowOnyxJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/onyx-drivers/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowOnyxAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowOnyxJSON.utf8)
        )
        XCTAssertEqual(workflowOnyxAPI.statusCode, 200)
        XCTAssertEqual(workflowOnyxAPI.kind, .metadata)
        XCTAssertEqual(workflowOnyxAPI.metadataResource, .workflowOnyxDriver)
        XCTAssertEqual(
            workflowOnyxAPI.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.workflowOnyxDriver.operationID
        )
        XCTAssertEqual(workflowOnyxAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowOnyxAPI.command)
        XCTAssertNil(workflowOnyxAPI.result)
        let workflowOnyx = try object(workflowOnyxAPI.responseBody)
        XCTAssertEqual(workflowOnyx["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(try object(workflowOnyx["api"])["workflowPath"], .string("/workflows/langgraph.review"))
        XCTAssertEqual(try array(workflowOnyx["skillTree"]).count, 3)
        XCTAssertEqual(try array(workflowOnyx["tools"]).count, 2)
        XCTAssertEqual(try array(workflowOnyx["commandBindings"]).count, 7)
        XCTAssertFalse(workflowOnyxJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowOnyxJSON.contains("authenticatedActor"))

        let workflowSkillTreeJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/skill-trees/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowSkillTreeAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowSkillTreeJSON.utf8)
        )
        XCTAssertEqual(workflowSkillTreeAPI.statusCode, 200)
        XCTAssertEqual(workflowSkillTreeAPI.kind, .metadata)
        XCTAssertEqual(workflowSkillTreeAPI.metadataResource, .workflowSkillTree)
        XCTAssertEqual(workflowSkillTreeAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowSkillTreeAPI.command)
        XCTAssertNil(workflowSkillTreeAPI.result)
        let workflowSkillTree = try array(workflowSkillTreeAPI.responseBody)
        XCTAssertEqual(workflowSkillTree.count, 3)
        XCTAssertEqual(try object(workflowSkillTree.first)["id"], .string("plan"))
        XCTAssertFalse(workflowSkillTreeJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowSkillTreeJSON.contains("authenticatedActor"))

        let workflowToolBindingsJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/tool-bindings/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowToolBindingsAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowToolBindingsJSON.utf8)
        )
        XCTAssertEqual(workflowToolBindingsAPI.statusCode, 200)
        XCTAssertEqual(workflowToolBindingsAPI.kind, .metadata)
        XCTAssertEqual(workflowToolBindingsAPI.metadataResource, .workflowToolBindings)
        XCTAssertEqual(workflowToolBindingsAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowToolBindingsAPI.command)
        XCTAssertNil(workflowToolBindingsAPI.result)
        let workflowToolBindings = try array(workflowToolBindingsAPI.responseBody)
        XCTAssertEqual(workflowToolBindings.count, 2)
        XCTAssertEqual(
            workflowToolBindings.compactMap { try? object($0)["reference"] },
            [.string("review.plan"), .string("repository.write")]
        )
        XCTAssertFalse(workflowToolBindingsJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowToolBindingsJSON.contains("authenticatedActor"))

        let workflowPlanningJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            method: .get,
            path: "/source/runtime/planning/langgraph.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08"
        )
        let workflowPlanningAPI = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(workflowPlanningJSON.utf8)
        )
        XCTAssertEqual(workflowPlanningAPI.statusCode, 200)
        XCTAssertEqual(workflowPlanningAPI.kind, .metadata)
        XCTAssertEqual(workflowPlanningAPI.metadataResource, .workflowPlanning)
        XCTAssertEqual(workflowPlanningAPI.pathParameters, ["workflow_id": "langgraph.review"])
        XCTAssertNil(workflowPlanningAPI.command)
        XCTAssertNil(workflowPlanningAPI.result)
        let workflowPlanning = try object(workflowPlanningAPI.responseBody)
        XCTAssertEqual(
            workflowPlanning["schemaVersion"],
            .number(Decimal(SMLWorkflowRuntimePlanningWorkflowBundle.currentSchemaVersion))
        )
        XCTAssertEqual(workflowPlanning["workflowID"], .string("langgraph.review"))
        XCTAssertEqual(workflowPlanning["apiBasePath"], .string("/source"))
        XCTAssertEqual(workflowPlanning["apiWorkflowPath"], .string("/workflows/langgraph.review"))
        XCTAssertEqual(try array(workflowPlanning["skillIndex"]).count, 3)
        XCTAssertEqual(try array(workflowPlanning["toolIndex"]).count, 2)
        XCTAssertEqual(try array(workflowPlanning["toolBindings"]).count, 2)
        XCTAssertEqual(try array(workflowPlanning["commandBindings"]).count, 7)
        XCTAssertFalse(workflowPlanningJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(workflowPlanningJSON.contains("authenticatedActor"))

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

    func testLangGraphManifestAPIScriptRunsMultiRequestTranscriptThroughOneLaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)
        let scriptURL = directory.appendingPathComponent("review-api.json")
        try """
        [
          {
            "method": "GET",
            "path": "/source/workflows/langgraph.review"
          },
          {
            "method": "POST",
            "path": "/source/workflows/langgraph.review/tasks",
            "body": {
              "task_id": "TASK-API-SCRIPT",
              "input": {
                "topic": "runtime"
              }
            }
          },
          {
            "method": "GET",
            "path": "/source/workflows/langgraph.review/tasks/TASK-API-SCRIPT"
          },
          {
            "method": "GET",
            "path": "/source/workflows/langgraph.review/tasks/TASK-API-SCRIPT/receipts"
          }
        ]
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let json = try await KistRunner.renderSMLRuntimeHostAPITranscript(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            scriptPath: "review-api.json",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let transcript = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPITranscript.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(transcript.schemaVersion, KistRunner.SMLRuntimeHostAPITranscript.currentSchemaVersion)
        XCTAssertEqual(transcript.sourceFormat, .langGraphManifest)
        XCTAssertEqual(transcript.scriptPath, scriptURL.path)
        XCTAssertEqual(transcript.requestedRequestCount, 4)
        XCTAssertEqual(transcript.executedRequestCount, 4)
        XCTAssertEqual(transcript.exchanges.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(transcript.exchanges.map(\.statusCode), [200, 201, 200, 200])
        XCTAssertEqual(transcript.exchanges.map(\.kind), [.workflow, .workflow, .workflow, .workflow])
        XCTAssertEqual(transcript.exchanges.map(\.route?.authority), [
            .hostCommandGateway,
            .hostCommandGateway,
            .hostCommandGateway,
            .hostCommandGateway,
        ])

        let describe = transcript.exchanges[0]
        XCTAssertEqual(describe.method, .get)
        XCTAssertEqual(describe.path, "/source/workflows/langgraph.review")
        XCTAssertEqual(describe.route?.action, .describe)
        XCTAssertEqual(describe.command?.op, SMLRuntimeCommandOperation.workflowInspect)

        let start = transcript.exchanges[1]
        XCTAssertEqual(start.method, .post)
        XCTAssertEqual(start.path, "/source/workflows/langgraph.review/tasks")
        XCTAssertEqual(start.requestBody["task_id"], .string("TASK-API-SCRIPT"))
        XCTAssertEqual(try object(start.requestBody["input"])["topic"], .string("runtime"))
        XCTAssertEqual(start.route?.action, .start)
        XCTAssertEqual(start.command?.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(start.command?.task, "TASK-API-SCRIPT")
        XCTAssertEqual(start.result?.task?.taskID, "TASK-API-SCRIPT")

        let watch = transcript.exchanges[2]
        XCTAssertEqual(watch.path, "/source/workflows/langgraph.review/tasks/TASK-API-SCRIPT")
        XCTAssertEqual(watch.pathParameters, ["task_id": "TASK-API-SCRIPT"])
        XCTAssertEqual(watch.route?.action, .watch)
        XCTAssertEqual(watch.command?.op, SMLRuntimeCommandOperation.taskWatch)
        XCTAssertEqual(watch.command?.task, "TASK-API-SCRIPT")
        XCTAssertEqual(watch.result?.task?.taskID, "TASK-API-SCRIPT")
        let watchBody = try object(watch.responseBody)
        XCTAssertEqual(watchBody["kind"], .string("task"))

        let receipts = transcript.exchanges[3]
        XCTAssertEqual(receipts.path, "/source/workflows/langgraph.review/tasks/TASK-API-SCRIPT/receipts")
        XCTAssertEqual(receipts.route?.action, .receipts)
        XCTAssertEqual(receipts.command?.op, SMLRuntimeCommandOperation.receiptsList)
        XCTAssertEqual(receipts.command?.task, "TASK-API-SCRIPT")

        let commandIDs = transcript.exchanges.compactMap(\.command?.commandID)
        XCTAssertEqual(commandIDs.count, 4)
        XCTAssertEqual(Set(commandIDs).count, 4)
        XCTAssertEqual(transcript.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(transcript.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertEqual(transcript.launchDescriptor.hostWiring.apiBasePaths, ["/source"])
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

    func testLangGraphManifestModelScriptRunsSessionfulPromptTranscript() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)
        let scriptURL = directory.appendingPathComponent("review.prompts")
        try """
        # generated model-router prompts
        Start the review workflow as TASK-MODEL-SCRIPT.

        Watch the current review task.
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        let provider = ScriptedSMLRuntimeProvider([
            .textAndCall(
                "Starting the wrapped workflow.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"start TASK-MODEL-SCRIPT {\"topic\":\"runtime\"}"}"#
            ),
            .textAndCall(
                "Watching the remembered task.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"langgraph.review","line":"watch"}"#
            ),
        ])
        let registry = ProviderRegistry(
            providers: [provider],
            retryDelaysNanoseconds: []
        )

        let json = try await KistRunner.renderSMLRuntimeHostModelTranscript(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            scriptPath: "review.prompts",
            binding: ProviderBinding(providerId: provider.id, model: provider.defaultModel),
            providers: registry,
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let transcript = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelTranscript.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(transcript.schemaVersion, KistRunner.SMLRuntimeHostModelTranscript.currentSchemaVersion)
        XCTAssertEqual(transcript.sourcePath, manifestURL.path)
        XCTAssertEqual(transcript.sourceFormat, .langGraphManifest)
        XCTAssertEqual(transcript.scriptPath, scriptURL.path)
        XCTAssertEqual(transcript.providerBinding, ProviderBinding(providerId: "sml-scripted", model: "scripted-1"))
        XCTAssertEqual(transcript.maximumCommandRounds, 3)
        XCTAssertEqual(transcript.promptCount, 2)
        XCTAssertEqual(transcript.providerRequestLimit, 6)
        XCTAssertEqual(transcript.providerRequestsConsumed, 2)
        XCTAssertEqual(transcript.turns.map(\.index), [1, 2])
        XCTAssertEqual(transcript.turns.map(\.providerRequestsBefore), [0, 1])
        XCTAssertEqual(transcript.turns.map(\.providerRequestsAfter), [1, 2])
        XCTAssertEqual(transcript.turns.map(\.providerRequestsConsumed), [1, 1])
        XCTAssertEqual(transcript.turns.map(\.prompt), [
            "Start the review workflow as TASK-MODEL-SCRIPT.",
            "Watch the current review task.",
        ])

        let start = transcript.turns[0]
        XCTAssertEqual(start.advisoryText, "Starting the wrapped workflow.")
        XCTAssertEqual(start.steps.count, 1)
        XCTAssertEqual(start.steps.first?.command?.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(start.steps.first?.command?.task, "TASK-MODEL-SCRIPT")
        XCTAssertEqual(start.steps.first?.result?.task?.taskID, "TASK-MODEL-SCRIPT")
        XCTAssertEqual(start.taskIDsByWorkflowID["langgraph.review"], "TASK-MODEL-SCRIPT")

        let watch = transcript.turns[1]
        XCTAssertEqual(watch.advisoryText, "Watching the remembered task.")
        XCTAssertEqual(watch.steps.count, 1)
        XCTAssertEqual(watch.steps.first?.command?.op, SMLRuntimeCommandOperation.taskWatch)
        XCTAssertEqual(watch.steps.first?.command?.task, "TASK-MODEL-SCRIPT")
        XCTAssertEqual(watch.steps.first?.result?.task?.taskID, "TASK-MODEL-SCRIPT")
        XCTAssertEqual(watch.taskIDsByWorkflowID["langgraph.review"], "TASK-MODEL-SCRIPT")
        XCTAssertEqual(transcript.taskIDsByWorkflowID["langgraph.review"], "TASK-MODEL-SCRIPT")
        XCTAssertEqual(transcript.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(transcript.launchDescriptor.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)

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

    func testLangGraphManifestREPLScriptRunsStatefulTranscriptThroughOneLaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: manifestURL)
        let scriptURL = directory.appendingPathComponent("review.repl")
        try """
        # generated workflow REPL script
        help

        start TASK-SCRIPT --state {"topic":"runtime"}
        watch
        attachment
        exit
        watch TASK-SHOULD-NOT-RUN
        """.write(to: scriptURL, atomically: true, encoding: .utf8)

        let json = try await KistRunner.renderSMLRuntimeHostREPLTranscript(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            workflowID: nil,
            scriptPath: "review.repl",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let transcript = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostREPLTranscript.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(transcript.schemaVersion, KistRunner.SMLRuntimeHostREPLTranscript.currentSchemaVersion)
        XCTAssertEqual(transcript.sourceFormat, .langGraphManifest)
        XCTAssertEqual(transcript.workflowID, "langgraph.review")
        XCTAssertEqual(transcript.availableWorkflowIDs, ["langgraph.review"])
        XCTAssertEqual(transcript.scriptPath, scriptURL.path)
        XCTAssertEqual(transcript.requestedLineCount, 6)
        XCTAssertEqual(transcript.executedLineCount, 5)
        XCTAssertTrue(transcript.stoppedAtExit)
        XCTAssertEqual(transcript.turns.map(\.index), [1, 2, 3, 4, 5])
        XCTAssertEqual(transcript.turns.map(\.line), [
            "help",
            #"start TASK-SCRIPT --state {"topic":"runtime"}"#,
            "watch",
            "attachment",
            "exit",
        ])

        XCTAssertTrue(transcript.turns[0].output.contains("commands:"))
        XCTAssertNil(transcript.turns[0].command)
        XCTAssertNil(transcript.turns[0].result)

        let startCommand = try XCTUnwrap(transcript.turns[1].command)
        XCTAssertEqual(startCommand.actor, "operator.test")
        XCTAssertEqual(startCommand.role, "reviewer")
        XCTAssertEqual(startCommand.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(startCommand.task, "TASK-SCRIPT")
        XCTAssertEqual(startCommand.arguments["workflow_id"], .string("langgraph.review"))
        XCTAssertEqual(try object(startCommand.arguments["initial_state"])["topic"], .string("runtime"))
        XCTAssertEqual(transcript.turns[1].result?.task?.taskID, "TASK-SCRIPT")

        let watchCommand = try XCTUnwrap(transcript.turns[2].command)
        XCTAssertEqual(watchCommand.op, SMLRuntimeCommandOperation.taskWatch)
        XCTAssertEqual(
            watchCommand.task,
            "TASK-SCRIPT",
            "script transcript must preserve REPL session state so follow-up lines can omit task IDs"
        )
        XCTAssertEqual(transcript.turns[2].result?.task?.taskID, "TASK-SCRIPT")
        XCTAssertTrue(transcript.turns[2].output.contains("TASK-SCRIPT waiting_capability"))

        let attachment = try JSONDecoder().decode(
            SMLWorkflowREPLAttachmentDescriptor.self,
            from: Data(transcript.turns[3].output.utf8)
        )
        XCTAssertEqual(attachment.workflowID, "langgraph.review")
        XCTAssertEqual(attachment.apiBasePath, "/source")
        XCTAssertEqual(attachment.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(attachment.skillTree.map(\.id), ["plan", "write", "receipt"])

        XCTAssertTrue(transcript.turns[4].shouldExit)
        XCTAssertNil(transcript.turns[4].command)
        XCTAssertNil(transcript.turns[4].result)
        XCTAssertFalse(json.contains("TASK-SHOULD-NOT-RUN"))
        XCTAssertEqual(transcript.launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(transcript.launchDescriptor.apiBasePaths, ["/source"])
        XCTAssertEqual(transcript.launchDescriptor.hostWiring.apiBasePaths, ["/source"])
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
        XCTAssertEqual(
            attachment.runtimeWorkflowREPLMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowAPIMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowModelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowOnyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowSkillTreePath,
            "/source/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowToolBindingsPath,
            "/source/runtime/tool-bindings/langgraph.review"
        )
        XCTAssertEqual(
            attachment.runtimeWorkflowPlanningPath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(
            attachment.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
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

        func renderREPLArtifactLine(
            _ line: String
        ) async throws -> KistRunner.SMLRuntimeHostREPLCommand {
            let artifactJSON = try await KistRunner.renderSMLRuntimeHostREPLCommand(
                sourcePath: "review.langgraph.json",
                projectRoot: directory.path,
                workflowID: "langgraph.review",
                line: line,
                roleOverride: "reviewer",
                actor: "operator.test",
                apiBasePathOverride: "/source",
                title: "Source Runtime",
                version: "2026.08",
                modelMaximumCommandRoundsOverride: 3
            )
            XCTAssertFalse(artifactJSON.contains("sml-runtime-export-lease"))
            XCTAssertFalse(artifactJSON.contains("authenticatedActor"))
            let artifact = try JSONDecoder().decode(
                KistRunner.SMLRuntimeHostREPLCommand.self,
                from: Data(artifactJSON.utf8)
            )
            XCTAssertEqual(artifact.line, line)
            XCTAssertNil(artifact.command)
            XCTAssertNil(artifact.result)
            return artifact
        }

        let replMount = try JSONDecoder().decode(
            SMLWorkflowRuntimeREPLMount.self,
            from: Data(try await renderREPLArtifactLine("repl-mount").output.utf8)
        )
        XCTAssertEqual(replMount.workflowID, attachment.workflowID)
        XCTAssertEqual(replMount.workflowMetadata, attachment.workflowMetadata)
        XCTAssertTrue(replMount.commands.contains { $0.verb == "planning-bundle" })
        let apiMounts = try JSONDecoder().decode(
            [SMLWorkflowRuntimeAPIMount].self,
            from: Data(try await renderREPLArtifactLine("api-mount").output.utf8)
        )
        XCTAssertEqual(apiMounts.count, attachment.apiCatalog.endpoints.count)
        XCTAssertEqual(apiMounts.first { $0.action == .start }?.workflowID, attachment.workflowID)
        XCTAssertEqual(apiMounts.first { $0.action == .start }?.pathTemplate, "/source/workflows/langgraph.review/tasks")
        let modelTool = try JSONDecoder().decode(
            SMLWorkflowRuntimeModelToolExport.self,
            from: Data(try await renderREPLArtifactLine("model-tool").output.utf8)
        )
        XCTAssertEqual(modelTool.workflowID, attachment.workflowID)
        XCTAssertEqual(modelTool.tool, attachment.modelTool)
        XCTAssertEqual(Set(modelTool.allowedActions), SMLWorkflowSurface.modelDefaultActions)
        XCTAssertEqual(modelTool.maximumCommandRounds, 3)
        XCTAssertEqual(modelTool.workflowMetadata, attachment.workflowMetadata)
        let onyxDriver = try JSONDecoder().decode(
            SMLOnyxDriverManifest.self,
            from: Data(try await renderREPLArtifactLine("onyx-driver").output.utf8)
        )
        XCTAssertEqual(onyxDriver.workflowID, attachment.workflowID)
        XCTAssertEqual(onyxDriver.skillTree, attachment.skillTree)
        XCTAssertEqual(onyxDriver.tools, attachment.toolBindings)
        XCTAssertEqual(onyxDriver.plan, attachment.plan)
        let skillTreeJSON = try JSONDecoder().decode(
            [SMLOnyxSkillNode].self,
            from: Data(try await renderREPLArtifactLine("skill-tree-json").output.utf8)
        )
        XCTAssertEqual(skillTreeJSON, attachment.skillTree)
        let toolBindingsJSON = try JSONDecoder().decode(
            [SMLOnyxToolBinding].self,
            from: Data(try await renderREPLArtifactLine("tool-bindings-json").output.utf8)
        )
        XCTAssertEqual(toolBindingsJSON, attachment.toolBindings)
        let planningBundle = try JSONDecoder().decode(
            SMLWorkflowRuntimePlanningWorkflowBundle.self,
            from: Data(try await renderREPLArtifactLine("planning-bundle").output.utf8)
        )
        XCTAssertEqual(planningBundle.workflowID, attachment.workflowID)
        XCTAssertEqual(planningBundle.workflowMetadata, attachment.workflowMetadata)
        XCTAssertEqual(planningBundle.workflow.skillTree, attachment.skillTree)
        XCTAssertEqual(planningBundle.workflow.tools, attachment.toolBindings)
        XCTAssertEqual(planningBundle.workflow.plan, attachment.plan)
        XCTAssertEqual(planningBundle.toolBindings, attachment.toolBindings)
        XCTAssertEqual(planningBundle.commandBindings, attachment.commandBindings)

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

    func testRuntimeRunbookFiltersOneWorkflowFromRuntimePackage() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = try SMLWorkflowSourceImporter.langGraphWorkflow(from: langGraphReviewManifest(
            id: "content.release",
            name: "Content release",
            sourceReference: "graphs/release.py",
            sourceDigest: String(repeating: "b", count: 64)
        ))
        let review = try SMLWorkflowSourceImporter.langGraphWorkflow(from: langGraphReviewManifest(
            id: "content.review",
            name: "Content review",
            sourceReference: "graphs/review.py",
            sourceDigest: String(repeating: "c", count: 64)
        ))
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            workflows: [release, review],
            admissionCatalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["repository.write"],
                modelPurposes: ["review.plan"],
                modelOutputSchemas: ["review.plan.v1"],
                workflows: ["content.release", "content.review"]
            ),
            role: "reviewer",
            actor: "operator.test",
            apiBasePath: "/source",
            modelMaximumCommandRounds: 3
        )
        let package = try SMLWorkflowRuntimeSourcePackage(
            normalizedWorkflows: [release, review],
            runtime: registry.export(title: "Source Runtime", version: "2026.08")
        )
        let packageURL = directory.appendingPathComponent("content.package.json")
        try JSONEncoder().encode(package).write(to: packageURL)

        let json = try await KistRunner.renderSMLRuntimeHostRunbook(
            sourcePath: "content.package.json",
            projectRoot: directory.path,
            workflowID: "content.review",
            roleOverride: "reviewer",
            actor: "operator.test",
            apiBasePathOverride: "/source",
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        let runbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(runbook.sourcePath, packageURL.path)
        XCTAssertEqual(runbook.sourceFormat, .runtimeSourcePackage)
        XCTAssertEqual(runbook.outputDirectory, directory.path)
        XCTAssertEqual(runbook.workflowIDs, ["content.review"])
        XCTAssertEqual(runbook.apiBasePaths, ["/source"])
        XCTAssertFalse(runbook.artifactsMaterialized)
        XCTAssertEqual(runbook.launchDescriptor.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(runbook.workflows.map(\.workflowID), ["content.review"])
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["content.review"]?.attachmentPath,
            "/source/runtime/attachments/content.review"
        )
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["content.review"]?.planningBundlePath,
            "/source/runtime/planning/content.review"
        )
        let workflow = try XCTUnwrap(runbook.workflows.first)
        XCTAssertEqual(workflow.workflowName, "Content review")
        XCTAssertEqual(workflow.attachmentPath, "attachments/content.review.json")
        XCTAssertEqual(workflow.runtimeWorkflowAttachmentPath, "/source/runtime/attachments/content.review")
        XCTAssertEqual(workflow.runtimeWorkflowPlanningPath, "/source/runtime/planning/content.review")
        XCTAssertEqual(workflow.replScriptPath, "repl-scripts/content.review.repl")
        XCTAssertEqual(workflow.replMountPath, "repl-mounts/content.review.json")
        XCTAssertEqual(workflow.replMount.apiBasePath, "/source")
        XCTAssertEqual(workflow.replMount.apiWorkflowPath, "/workflows/content.review")
        XCTAssertEqual(workflow.replCommands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertEqual(workflow.apiScriptPath, "api-scripts/content.review.json")
        XCTAssertEqual(workflow.apiMountPath, "api-mounts/content.review.json")
        XCTAssertEqual(workflow.apiMounts.first { $0.action == .start }?.pathTemplate, "/source/workflows/content.review/tasks")
        XCTAssertEqual(workflow.modelScriptPath, "model-scripts/content.review.prompts")
        XCTAssertEqual(workflow.modelToolPath, "model-tools/content.review.json")
        XCTAssertEqual(workflow.modelTool.workflowID, "content.review")
        XCTAssertEqual(workflow.modelTool.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(workflow.apiScript.count, 12)
        XCTAssertTrue(workflow.replScript.contains("start TASK-SCAFFOLD"))
        XCTAssertTrue(workflow.modelScript.contains("Start content.review as task TASK-SCAFFOLD"))
        XCTAssertTrue(workflow.modelScript.contains("planning bundle GET /source/runtime/planning/content.review"))
        XCTAssertTrue(workflow.modelScript.contains("onyx-drivers/content.review.json"))
        XCTAssertEqual(workflow.modelTranscriptCommand.arguments, [
            "--sml-runtime-model-script", ".",
            "--sml-model-script", "model-scripts/content.review.prompts",
            "--provider", "<provider>",
            "--model", "<model>",
        ])
        XCTAssertEqual(workflow.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertTrue(workflow.apiEndpoints.contains {
            $0.pathTemplate == "/source/workflows/content.review/tasks" && $0.action == .start
        })
        XCTAssertFalse(runbook.workflows.contains { $0.workflowID == "content.release" })
        XCTAssertFalse(json.contains("operator.test"))
        XCTAssertFalse(json.contains("sml-runtime-export-lease"))
        XCTAssertFalse(json.contains("authenticatedActor"))

        do {
            _ = try await KistRunner.makeSMLRuntimeHostRunbook(
                sourcePath: "content.package.json",
                projectRoot: directory.path,
                workflowID: "content.missing",
                roleOverride: "reviewer"
            )
            XCTFail("unknown runbook workflow ID should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("unknown --sml-workflow 'content.missing'"))
            XCTAssertTrue(message.contains("content.release"))
            XCTAssertTrue(message.contains("content.review"))
        }
    }

    func testRuntimeSourceSetWrapsMultipleWorkflowManifestsIntoAllSurfaces() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let releaseURL = directory.appendingPathComponent("release.langgraph.json")
        try langGraphReviewManifest(
            id: "content.release",
            name: "Content release",
            sourceReference: "graphs/release.py",
            sourceDigest: String(repeating: "b", count: 64)
        ).write(to: releaseURL)
        let reviewURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest(
            id: "content.review",
            name: "Content review",
            sourceReference: "graphs/review.py",
            sourceDigest: String(repeating: "c", count: 64)
        ).write(to: reviewURL)
        let sourceSetURL = directory.appendingPathComponent("runtime.sources.json")
        let sourceSet = KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(
                path: "release.langgraph.json",
                role: "release-agent",
                apiBasePath: "/release",
                apiWorkflowPath: "/publish",
                modelMaximumCommandRounds: 2
            ),
            .init(
                path: "review.langgraph.json",
                role: "review-agent",
                apiBasePath: "/review",
                apiWorkflowPath: "/review-flow",
                modelMaximumCommandRounds: 5
            ),
        ])
        try JSONEncoder().encode(sourceSet).write(to: sourceSetURL)

        let export = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "runtime.sources.json",
            projectRoot: directory.path,
            actor: "operator.test",
            title: "Source Runtime",
            version: "2026.08"
        )

        XCTAssertEqual(export.sourcePath, sourceSetURL.path)
        XCTAssertEqual(export.sourceFormat, .runtimeSourceSet)
        XCTAssertEqual(export.runtimePackage.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/release", "/review"])
        XCTAssertEqual(
            export.runtimePackage.runtime.mountContract.replMounts.map(\.workflowID),
            ["content.release", "content.review"]
        )
        XCTAssertEqual(
            export.runtimePackage.runtime.mountContract.replMounts.map(\.role),
            ["release-agent", "review-agent"]
        )
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.maximumCommandRounds, 5)
        XCTAssertEqual(
            export.runtimePackage.runtime.modelTools.map(\.maximumCommandRounds),
            [2, 5]
        )
        XCTAssertEqual(export.runtimePackage.runtime.planning.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(
            export.runtimePackage.runtime.planning.workflows.map(\.apiWorkflowPath),
            ["/publish", "/review-flow"]
        )
        XCTAssertEqual(
            export.runtimePackage.runtime.hostWiring.attachmentManifests.map(\.workflowID),
            ["content.release", "content.review"]
        )
        XCTAssertEqual(
            export.runtimePackage.runtime.hostWiring.attachmentManifests.map(\.apiBasePath),
            ["/release", "/review"]
        )
        XCTAssertEqual(
            export.runtimePackage.runtime.hostWiring.attachmentManifests.map(\.apiWorkflowPath),
            ["/publish", "/review-flow"]
        )
        XCTAssertEqual(
            export.runtimePackage.sourceSummaries.map(\.apiWorkflowPath),
            ["/publish", "/review-flow"]
        )
        XCTAssertEqual(
            export.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath),
            ["/publish", "/review-flow"]
        )
        XCTAssertEqual(
            export.runtimePackage.sourceSummaries.map(\.workflowMetadata.modelToolPath),
            [
                "/release/runtime/model-tools/content.release",
                "/review/runtime/model-tools/content.review",
            ]
        )
        XCTAssertEqual(
            export.launchDescriptor.sourceSummaries.map(\.workflowMetadata.planningBundlePath),
            [
                "/release/runtime/planning/content.release",
                "/review/runtime/planning/content.review",
            ]
        )
        XCTAssertEqual(
            export.launchDescriptor.workflows.map(\.apiWorkflowPath),
            ["/publish", "/review-flow"]
        )
        XCTAssertEqual(
            export.hostWiring.workflows.map(\.apiWorkflowPath),
            ["/publish", "/review-flow"]
        )
        XCTAssertEqual(
            export.runtimePackage.runtime.onyxDrivers.map(\.driverID),
            export.runtimePackage.runtime.mountContract.onyxDriverIDs
        )
        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/release/publish/tasks"])
        XCTAssertNotNil(paths["/review/review-flow/tasks"])
        XCTAssertNil(paths["/release/workflows/content.release/tasks"])
        XCTAssertNil(paths["/review/workflows/content.review/tasks"])
        XCTAssertEqual(export.launchDescriptor.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.launchDescriptor.hostWiring, export.hostWiring)

        let runbookJSON = try await KistRunner.renderSMLRuntimeHostRunbook(
            sourcePath: "runtime.sources.json",
            projectRoot: directory.path,
            workflowID: "content.review",
            actor: "operator.test",
            title: "Source Runtime",
            version: "2026.08"
        )
        let runbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(runbookJSON.utf8)
        )
        XCTAssertEqual(runbook.sourcePath, sourceSetURL.path)
        XCTAssertEqual(runbook.sourceFormat, .runtimeSourceSet)
        XCTAssertEqual(runbook.outputDirectory, directory.path)
        XCTAssertEqual(runbook.workflowIDs, ["content.review"])
        XCTAssertEqual(runbook.apiBasePaths, ["/review"])
        XCTAssertFalse(runbook.artifactsMaterialized)
        XCTAssertEqual(runbook.launchDescriptor.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(runbook.workflows.map(\.workflowID), ["content.review"])
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["content.review"]?.attachmentPath,
            "/review/runtime/attachments/content.review"
        )
        XCTAssertEqual(
            runbook.runtimeWorkflowMetadataByWorkflowID["content.review"]?.skillTreePath,
            "/review/runtime/skill-trees/content.review"
        )
        let workflow = try XCTUnwrap(runbook.workflows.first)
        XCTAssertEqual(workflow.workflowName, "Content review")
        XCTAssertEqual(workflow.role, "review-agent")
        XCTAssertEqual(workflow.apiBasePath, "/review")
        XCTAssertEqual(workflow.apiWorkflowPath, "/review-flow")
        XCTAssertEqual(workflow.runtimeWorkflowAttachmentPath, "/review/runtime/attachments/content.review")
        XCTAssertEqual(workflow.runtimeWorkflowSkillTreePath, "/review/runtime/skill-trees/content.review")
        XCTAssertEqual(workflow.replScriptPath, "repl-scripts/content.review.repl")
        XCTAssertEqual(workflow.replMountPath, "repl-mounts/content.review.json")
        XCTAssertEqual(workflow.replMount.apiBasePath, "/review")
        XCTAssertEqual(workflow.replMount.apiWorkflowPath, "/review-flow")
        XCTAssertEqual(workflow.replCommands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertEqual(workflow.apiScriptPath, "api-scripts/content.review.json")
        XCTAssertEqual(workflow.apiMountPath, "api-mounts/content.review.json")
        XCTAssertEqual(workflow.apiMounts.first { $0.action == .start }?.pathTemplate, "/review/review-flow/tasks")
        XCTAssertEqual(workflow.modelScriptPath, "model-scripts/content.review.prompts")
        XCTAssertEqual(workflow.modelToolPath, "model-tools/content.review.json")
        XCTAssertEqual(workflow.modelTool.workflowID, "content.review")
        XCTAssertEqual(workflow.modelTool.maximumCommandRounds, 5)
        XCTAssertTrue(workflow.replScript.contains("start TASK-SCAFFOLD"))
        XCTAssertTrue(workflow.modelScript.contains("Start content.review as task TASK-SCAFFOLD"))
        XCTAssertTrue(workflow.apiEndpoints.contains {
            $0.pathTemplate == "/review/review-flow/tasks" && $0.action == .start
        })
        XCTAssertFalse(runbook.workflows.contains { $0.workflowID == "content.release" })
        XCTAssertFalse(runbookJSON.contains("operator.test"))
        XCTAssertFalse(runbookJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(runbookJSON.contains("authenticatedActor"))

        let overriddenExport = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "runtime.sources.json",
            projectRoot: directory.path,
            roleOverride: "global-agent",
            actor: "operator.test",
            apiBasePathOverride: "/global",
            apiWorkflowPathOverrides: ["content.review": "/global-review"],
            title: "Source Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 3
        )
        XCTAssertEqual(overriddenExport.runtimePackage.runtime.mountContract.apiBasePaths, ["/global"])
        XCTAssertEqual(
            overriddenExport.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath),
            ["/publish", "/global-review"]
        )
        XCTAssertEqual(
            overriddenExport.runtimePackage.runtime.mountContract.replMounts.map(\.role),
            ["global-agent", "global-agent"]
        )
        XCTAssertEqual(overriddenExport.runtimePackage.runtime.modelRouter.maximumCommandRounds, 3)
        let overriddenPaths = try object(overriddenExport.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(overriddenPaths["/global/publish/tasks"])
        XCTAssertNotNil(overriddenPaths["/global/global-review/tasks"])
        XCTAssertNil(overriddenPaths["/global/review-flow/tasks"])
        XCTAssertNil(overriddenPaths["/global/workflows/content.release/tasks"])
        XCTAssertNil(overriddenPaths["/global/workflows/content.review/tasks"])

        let packageURL = directory.appendingPathComponent("source-set.package.json")
        try JSONEncoder().encode(export.runtimePackage).write(to: packageURL)
        let packageExport = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "source-set.package.json",
            projectRoot: directory.path,
            actor: "operator.test",
            apiBasePathOverride: "/package",
            apiWorkflowPathOverrides: ["content.release": "/package-release"],
            title: "Source Runtime",
            version: "2026.08"
        )
        XCTAssertEqual(packageExport.sourceFormat, .runtimeSourcePackage)
        XCTAssertEqual(packageExport.runtimePackage.runtime.mountContract.apiBasePaths, ["/package"])
        XCTAssertEqual(
            packageExport.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath),
            ["/package-release", "/review-flow"]
        )
        let packagePaths = try object(packageExport.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(packagePaths["/package/package-release/tasks"])
        XCTAssertNotNil(packagePaths["/package/review-flow/tasks"])
        XCTAssertNil(packagePaths["/package/publish/tasks"])
        XCTAssertNil(packagePaths["/package/workflows/content.release/tasks"])
        XCTAssertNil(packagePaths["/package/workflows/content.review/tasks"])
    }

    func testSMLWorkflowJSONWrapsIntoSameRuntimeSurfaces() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workflowURL = directory.appendingPathComponent("native.workflow.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(nativeReviewWorkflow()).write(to: workflowURL)

        let export = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "native.workflow.json",
            projectRoot: directory.path,
            roleOverride: "native-agent",
            actor: "operator.test",
            apiBasePathOverride: "/native",
            apiWorkflowPathOverrides: ["native.review": "/review"],
            title: "Native Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 2
        )

        XCTAssertEqual(export.sourcePath, workflowURL.path)
        XCTAssertEqual(export.sourceFormat, .smlWorkflowJSON)
        XCTAssertEqual(export.runtimePackage.workflowIDs, ["native.review"])
        XCTAssertEqual(export.runtimePackage.normalizedWorkflows, [nativeReviewWorkflow()])
        let summary = try XCTUnwrap(export.runtimePackage.sourceSummaries.first)
        XCTAssertEqual(summary.workflowID, "native.review")
        XCTAssertEqual(summary.sourceKind, .native)
        XCTAssertEqual(summary.apiBasePath, "/native")
        XCTAssertEqual(summary.apiWorkflowPath, "/review")
        XCTAssertEqual(summary.workflowMetadata.planningBundlePath, "/native/runtime/planning/native.review")
        XCTAssertEqual(export.launchDescriptor.sourceSummaries, export.runtimePackage.sourceSummaries)
        let descriptor = try XCTUnwrap(export.runtimePackage.runtime.catalog.workflows.first)
        XCTAssertEqual(descriptor.workflowID, "native.review")
        XCTAssertEqual(descriptor.sourceKind, .native)
        XCTAssertEqual(descriptor.role, "native-agent")
        XCTAssertEqual(descriptor.api.basePath, "/native")
        XCTAssertEqual(descriptor.api.workflowPath, "/review")
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.workflowID), ["native.review"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/native"])
        XCTAssertEqual(export.runtimePackage.runtime.modelTools.map(\.workflowID), ["native.review"])
        XCTAssertEqual(export.runtimePackage.runtime.modelTools.map(\.maximumCommandRounds), [2])
        XCTAssertEqual(export.runtimePackage.runtime.onyxDrivers.map(\.workflowID), ["native.review"])
        XCTAssertEqual(export.runtimePackage.runtime.planning.workflowIDs, ["native.review"])
        XCTAssertEqual(export.hostWiring.attachmentManifests.map(\.workflowID), ["native.review"])
        XCTAssertEqual(
            export.hostWiring.attachmentManifests.first?.workflowMetadata.modelToolPath,
            "/native/runtime/model-tools/native.review"
        )
        XCTAssertEqual(
            export.runtimePackage.runtime.mountContract.apiRoutes.first {
                $0.workflowID == "native.review" && $0.action == .start
            }?.workflowMetadata?.planningBundlePath,
            "/native/runtime/planning/native.review"
        )
        XCTAssertEqual(
            export.hostWiring.workflows.first?.apiRoutes.first {
                $0.action == .start
            }?.workflowMetadata?.apiMountPath,
            "/native/runtime/api-mounts/native.review"
        )
        XCTAssertNil(
            export.runtimePackage.runtime.mountContract.apiRoutes.first {
                $0.handlerKind == .metadata && $0.metadataResource == .workflowPlanning
            }?.workflowMetadata
        )
        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/native/review/tasks"])
        XCTAssertNotNil(paths["/native/runtime/planning"])
        XCTAssertNil(paths["/native/workflows/native.review/tasks"])

        let runbookJSON = try await KistRunner.renderSMLRuntimeHostRunbook(
            sourcePath: "native.workflow.json",
            projectRoot: directory.path,
            workflowID: "native.review",
            roleOverride: "native-agent",
            actor: "operator.test",
            apiBasePathOverride: "/native",
            apiWorkflowPathOverrides: ["native.review": "/review"],
            title: "Native Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 2
        )
        let runbook = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostScaffoldRunbook.self,
            from: Data(runbookJSON.utf8)
        )
        XCTAssertEqual(runbook.sourceFormat, .smlWorkflowJSON)
        XCTAssertEqual(runbook.workflowIDs, ["native.review"])
        let workflowRunbook = try XCTUnwrap(runbook.workflows.first)
        XCTAssertEqual(workflowRunbook.replScriptPath, "repl-scripts/native.review.repl")
        XCTAssertEqual(workflowRunbook.apiScript.count, 12)
        XCTAssertEqual(workflowRunbook.replMount.apiWorkflowPath, "/review")
        XCTAssertEqual(workflowRunbook.apiMounts.first { $0.action == .start }?.pathTemplate, "/native/review/tasks")
        XCTAssertEqual(
            workflowRunbook.apiMounts.first { $0.action == .start }?.workflowMetadata?.apiMountPath,
            "/native/runtime/api-mounts/native.review"
        )
        XCTAssertEqual(workflowRunbook.modelTool.workflowID, "native.review")
        XCTAssertEqual(workflowRunbook.modelTool.maximumCommandRounds, 2)
        XCTAssertTrue(workflowRunbook.replScript.contains("planning-bundle"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("Runtime metadata APIs: attachment GET /native/runtime/attachments/native.review"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("planning bundle GET /native/runtime/planning/native.review"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("Local scaffold artifacts: attachments/native.review.json"))
        XCTAssertTrue(workflowRunbook.modelScript.contains("onyx-drivers/native.review.json"))
        XCTAssertFalse(runbookJSON.contains("operator.test"))
        XCTAssertFalse(runbookJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(runbookJSON.contains("authenticatedActor"))

        let replPlanningJSON = try await KistRunner.renderSMLRuntimeHostREPLCommand(
            sourcePath: "native.workflow.json",
            projectRoot: directory.path,
            workflowID: "native.review",
            line: "planning-bundle",
            roleOverride: "native-agent",
            actor: "operator.test",
            apiBasePathOverride: "/native",
            apiWorkflowPathOverrides: ["native.review": "/review"],
            title: "Native Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 2
        )
        let replPlanningTurn = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostREPLCommand.self,
            from: Data(replPlanningJSON.utf8)
        )
        let replPlanning = try JSONDecoder().decode(
            SMLWorkflowRuntimePlanningWorkflowBundle.self,
            from: Data(replPlanningTurn.output.utf8)
        )
        XCTAssertEqual(replPlanning.workflowID, "native.review")
        XCTAssertEqual(replPlanning.workflowMetadata.planningBundlePath, "/native/runtime/planning/native.review")
        XCTAssertEqual(replPlanning.workflow.sourceKind, .native)
        XCTAssertEqual(replPlanning.workflow.apiWorkflowPath, "/review")
        XCTAssertEqual(replPlanning.workflow.tools.map(\.reference), ["native.plan", "repository.write"])

        let apiPlanningJSON = try await KistRunner.renderSMLRuntimeHostAPIExchange(
            sourcePath: "native.workflow.json",
            projectRoot: directory.path,
            method: .get,
            path: "/native/runtime/planning/native.review",
            roleOverride: "native-agent",
            actor: "operator.test",
            apiBasePathOverride: "/native",
            apiWorkflowPathOverrides: ["native.review": "/review"],
            title: "Native Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 2
        )
        let apiPlanning = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostAPIExchange.self,
            from: Data(apiPlanningJSON.utf8)
        )
        XCTAssertEqual(apiPlanning.statusCode, 200)
        XCTAssertEqual(apiPlanning.kind, .metadata)
        XCTAssertEqual(apiPlanning.metadataResource, .workflowPlanning)
        let apiPlanningBundle = try JSONDecoder().decode(
            SMLWorkflowRuntimePlanningWorkflowBundle.self,
            from: JSONEncoder().encode(apiPlanning.responseBody)
        )
        XCTAssertEqual(apiPlanningBundle, replPlanning)

        let provider = ScriptedSMLRuntimeProvider([
            .textAndCall(
                "Routing the native SML workflow.",
                name: SMLWorkflowRuntimeModelAdapter.toolName,
                arguments: #"{"workflow_id":"native.review","line":"start TASK-NATIVE {\"topic\":\"runtime\"}"}"#
            ),
        ])
        let registry = ProviderRegistry(providers: [provider], retryDelaysNanoseconds: [])
        let modelJSON = try await KistRunner.renderSMLRuntimeHostModelTurn(
            sourcePath: "native.workflow.json",
            projectRoot: directory.path,
            prompt: "start the native review workflow through its generated runtime",
            binding: ProviderBinding(providerId: provider.id, model: provider.defaultModel),
            providers: registry,
            roleOverride: "native-agent",
            actor: "operator.test",
            apiBasePathOverride: "/native",
            apiWorkflowPathOverrides: ["native.review": "/review"],
            title: "Native Runtime",
            version: "2026.08",
            modelMaximumCommandRoundsOverride: 2
        )
        let model = try JSONDecoder().decode(
            KistRunner.SMLRuntimeHostModelTurn.self,
            from: Data(modelJSON.utf8)
        )
        XCTAssertEqual(model.sourceFormat, .smlWorkflowJSON)
        let modelStep = try XCTUnwrap(model.steps.first)
        XCTAssertEqual(modelStep.disposition, .commandExecuted)
        let modelCommand = try XCTUnwrap(modelStep.command)
        XCTAssertEqual(modelCommand.actor, "operator.test")
        XCTAssertEqual(modelCommand.role, "native-agent")
        XCTAssertEqual(modelCommand.task, "TASK-NATIVE")
        XCTAssertEqual(model.taskIDsByWorkflowID["native.review"], "TASK-NATIVE")
        let capture = provider.capture()
        XCTAssertEqual(capture.toolNames, [SMLWorkflowRuntimeModelAdapter.toolName])
        XCTAssertTrue(capture.systemPrompt.contains("native.review@1.0.0"))
        XCTAssertTrue(capture.systemPrompt.contains("source: native native.workflow.json"))
        XCTAssertTrue(capture.systemPrompt.contains("workflow metadata:"))
        XCTAssertTrue(capture.systemPrompt.contains("planning bundle: GET /native/runtime/planning/native.review"))
        XCTAssertTrue(capture.systemPrompt.contains("Skill tree:"))
        XCTAssertTrue(capture.systemPrompt.contains("Onyx driver IDs"))
        XCTAssertFalse(modelJSON.contains("sml-runtime-export-lease"))
        XCTAssertFalse(modelJSON.contains("authenticatedActor"))
    }

    func testRuntimeSourceSetRejectsEmptyDuplicateAndNestedSources() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reviewURL = directory.appendingPathComponent("review.langgraph.json")
        try langGraphReviewManifest().write(to: reviewURL)

        let emptySetURL = directory.appendingPathComponent("empty.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [])).write(to: emptySetURL)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "empty.sources.json",
                projectRoot: directory.path
            )
            XCTFail("empty runtime source set should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("runtime source set"))
            XCTAssertTrue(message.contains("sources must contain at least one workflow source"))
        }

        let duplicateSetURL = directory.appendingPathComponent("duplicate.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(path: "review.langgraph.json"),
            .init(path: "review.langgraph.json"),
        ])).write(to: duplicateSetURL)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "duplicate.sources.json",
                projectRoot: directory.path
            )
            XCTFail("duplicate runtime source set should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("duplicates another source path"), message)
        }

        let reviewCopyURL = directory.appendingPathComponent("review-copy.langgraph.json")
        try langGraphReviewManifest().write(to: reviewCopyURL)
        let duplicateWorkflowSetURL = directory.appendingPathComponent(
            "duplicate-workflow.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(path: "review.langgraph.json"),
            .init(path: "review-copy.langgraph.json"),
        ])).write(to: duplicateWorkflowSetURL)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "duplicate-workflow.sources.json",
                projectRoot: directory.path
            )
            XCTFail("duplicate workflow ids across distinct sources should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("duplicate workflow id 'langgraph.review'"), message)
        }

        let sourceExport = try await KistRunner.makeSMLRuntimeHostExport(
            sourcePath: "review.langgraph.json",
            projectRoot: directory.path,
            roleOverride: "reviewer"
        )
        let packageURL = directory.appendingPathComponent("review.package.json")
        try JSONEncoder().encode(sourceExport.runtimePackage).write(to: packageURL)
        let nestedSetURL = directory.appendingPathComponent("nested.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(path: "review.package.json"),
        ])).write(to: nestedSetURL)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "nested.sources.json",
                projectRoot: directory.path
            )
            XCTFail("nested package runtime source set should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("must be a single LangGraph manifest or SML workflow JSON"))
        }

        let invalidAPIBaseSetURL = directory.appendingPathComponent("invalid-api-base.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(path: "review.langgraph.json", apiBasePath: "relative"),
        ])).write(to: invalidAPIBaseSetURL)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "invalid-api-base.sources.json",
                projectRoot: directory.path
            )
            XCTFail("invalid runtime source set API base path should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("apiBasePath must be an absolute literal path"))
        }

        let invalidAPIWorkflowSetURL = directory.appendingPathComponent("invalid-api-workflow.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(path: "review.langgraph.json", apiWorkflowPath: "relative"),
        ])).write(to: invalidAPIWorkflowSetURL)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "invalid-api-workflow.sources.json",
                projectRoot: directory.path
            )
            XCTFail("invalid runtime source set API workflow path should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("apiWorkflowPath must be an absolute literal path"))
        }

        let invalidRoundsSetURL = directory.appendingPathComponent("invalid-rounds.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(path: "review.langgraph.json", modelMaximumCommandRounds: 9),
        ])).write(to: invalidRoundsSetURL)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "invalid-rounds.sources.json",
                projectRoot: directory.path
            )
            XCTFail("invalid runtime source set model rounds should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("modelMaximumCommandRounds must be between 1 and 8"))
        }
    }

    func testRuntimeSourceLoadingRefusesTraversalAbsoluteAndSymlinkedEntries() async throws {
        let directory = try temporaryDirectory()
        let outside = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        let outsideWorkflow = outside.appendingPathComponent("outside.workflow.json")
        try langGraphReviewManifest().write(to: outsideWorkflow)

        do {
            _ = try await KistRunner.withSMLRuntimeHostLaunch(
                sourcePath: outsideWorkflow.path,
                projectRoot: directory.path,
                mode: .durable
            ) { _ in true }
            XCTFail("a durable host must not mount an external runtime source")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("escapes the project root"),
                "unexpected durable external-source refusal: \(error)")
        }

        let cases: [(name: String, path: String)] = [
            ("traversal", "../\(outside.lastPathComponent)/outside.workflow.json"),
            ("absolute", outsideWorkflow.path),
        ]
        for item in cases {
            let sourceSetURL = directory.appendingPathComponent("\(item.name).sources.json")
            try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
                .init(path: item.path),
            ])).write(to: sourceSetURL)
            do {
                _ = try await KistRunner.makeSMLRuntimeHostExport(
                    sourcePath: sourceSetURL.lastPathComponent,
                    projectRoot: directory.path)
                XCTFail("\(item.name) source-set path should fail closed")
            } catch {
                XCTAssertTrue(
                    String(describing: error).contains("confined relative file path"),
                    "unexpected \(item.name) refusal: \(error)")
            }
        }

        let linked = directory.appendingPathComponent("linked.workflow.json")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outsideWorkflow)
        let linkedSet = directory.appendingPathComponent("linked.sources.json")
        try JSONEncoder().encode(KistRunner.SMLRuntimeHostSourceSet(sources: [
            .init(path: linked.lastPathComponent),
        ])).write(to: linkedSet)
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: linkedSet.lastPathComponent,
                projectRoot: directory.path)
            XCTFail("symlinked source-set entry should fail closed")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("could not read sources[0]"),
                "unexpected linked source-set refusal: \(error)")
        }

        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: linked.lastPathComponent,
                projectRoot: directory.path)
            XCTFail("symlinked top-level source should fail closed")
        } catch {
            XCTAssertTrue(String(describing: error).contains("could not read SML runtime source"))
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
            apiWorkflowPathOverrides: ["langgraph.review": "/override-review"],
            title: "Override Runtime",
            version: "2026.09",
            modelMaximumCommandRoundsOverride: 2
        )

        XCTAssertEqual(export.sourceFormat, .runtimeSourcePackage)
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.apiBasePaths, ["/override"])
        XCTAssertEqual(export.runtimePackage.runtime.mountContract.replMounts.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.runtimePackage.runtime.modelRouter.maximumCommandRounds, 2)
        XCTAssertEqual(export.launchDescriptor.sourceSummaries.map(\.apiBasePath), ["/override"])
        XCTAssertEqual(export.launchDescriptor.sourceSummaries.map(\.apiWorkflowPath), ["/override-review"])
        XCTAssertEqual(
            export.runtimePackage.sourceSummaries.first?.workflowMetadata.replMountPath,
            "/override/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            export.launchDescriptor.sourceSummaries.first?.workflowMetadata.modelToolPath,
            "/override/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(export.launchDescriptor.workflows.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.launchDescriptor.modelRouter.maximumCommandRounds, 2)
        XCTAssertEqual(export.launchDescriptor.hostWiring, export.hostWiring)
        XCTAssertEqual(export.hostWiring.apiBasePaths, ["/override"])
        XCTAssertEqual(export.hostWiring.workflows.map(\.role), ["override-reviewer"])
        XCTAssertEqual(export.hostWiring.modelRouter.maximumCommandRounds, 2)

        let paths = try object(export.runtimePackage.runtime.openAPI["paths"])
        XCTAssertNotNil(paths["/override/override-review/tasks"])
        XCTAssertNil(paths["/override/workflows/langgraph.review/tasks"])
        XCTAssertNil(paths["/source/workflows/langgraph.review/tasks"])

        let wiring = try XCTUnwrap(export.hostWiring.workflows.first)
        XCTAssertEqual(wiring.apiBasePath, "/override")
        XCTAssertEqual(wiring.apiWorkflowPath, "/override-review")
        XCTAssertTrue(wiring.apiRoutes.contains {
            $0.pathTemplate == "/override/override-review/tasks"
        })
        XCTAssertFalse(wiring.apiRoutes.contains {
            $0.pathTemplate == "/source/workflows/langgraph.review/tasks"
        })
        do {
            _ = try await KistRunner.makeSMLRuntimeHostExport(
                sourcePath: "review.package.json",
                projectRoot: directory.path,
                apiWorkflowPathOverrides: ["missing.workflow": "/missing"]
            )
            XCTFail("unknown runtime package API workflow path override should fail closed")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("unknown --sml-api-workflow-path workflow id 'missing.workflow'"))
        }
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
            XCTAssertTrue(message.contains("Expected a runtime source package, runtime scaffold, runtime source set, LangGraph manifest, or SML workflow JSON"))
        }
    }

    private struct KistCLIResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runKistCLI(
        arguments: [String],
        workingDirectory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> KistCLIResult {
        let executable = try kistExecutableURL(file: file)
        let stdoutURL = workingDirectory.appendingPathComponent("kist-cli-\(UUID().uuidString).stdout")
        let stderrURL = workingDirectory.appendingPathComponent("kist-cli-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workingDirectory
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KIST_ACTIVE")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        try stdout.close()
        try stderr.close()
        return KistCLIResult(
            exitCode: process.terminationStatus,
            stdout: try String(contentsOf: stdoutURL, encoding: .utf8),
            stderr: try String(contentsOf: stderrURL, encoding: .utf8)
        )
    }

    private func kistExecutableURL(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let executable = directory
                .appendingPathComponent(".build", isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true)
                .appendingPathComponent("kist")
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable
            }
            directory.deleteLastPathComponent()
        }
        throw XCTSkip("kist executable is not present in the SwiftPM products directory")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-sml-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func langGraphReviewManifest(
        id: String = "langgraph.review",
        name: String = "LangGraph review",
        sourceReference: String = "graphs/review.py",
        sourceDigest: String = String(repeating: "a", count: 64)
    ) -> Data {
        Data("""
        {
          "manifest_version": 1,
          "id": "\(id)",
          "version": "1.0.0",
          "name": "\(name)",
          "source_reference": "\(sourceReference)",
          "source_digest": "\(sourceDigest)",
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

    private func nativeReviewWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "native.review",
            version: "1.0.0",
            name: "Native review",
            source: .init(kind: .native, reference: "native.workflow.json"),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "topic", type: .string, description: "Review topic"),
                .init(name: "report", type: .string, required: false, description: "Review report"),
            ],
            interface: .init(inputFields: ["topic"], outputFields: ["report"]),
            entrypoint: "plan",
            instructions: [
                .init(
                    id: "plan",
                    op: .callModel,
                    purpose: "native.plan",
                    outputSchema: "native.plan.v1",
                    next: "write"
                ),
                .init(
                    id: "write",
                    op: .callTool,
                    capability: "repository.write",
                    next: "receipt"
                ),
                .init(
                    id: "receipt",
                    op: .emitReceipt,
                    receiptFields: ["report"]
                ),
            ]
        )
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
        case text(String)
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
            case .text(let text):
                continuation.yield(.delta(text))
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
