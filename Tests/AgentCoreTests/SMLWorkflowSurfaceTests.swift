import Foundation
import XCTest
@testable import AgentCore

final class SMLWorkflowSurfaceTests: XCTestCase {
    func testLangGraphWorkflowCompilesOneTypedSurfaceForREPLModelAPIAndOnyx() throws {
        let surface = try makeSurface()

        XCTAssertEqual(surface.workflowID, "content.release")
        XCTAssertEqual(surface.sourceKind, .langGraph)
        XCTAssertEqual(surface.inputs.map(\.name), ["target"])
        XCTAssertEqual(surface.outputs.map(\.name), ["artifact"])
        XCTAssertTrue(surface.grammar().contains("start [TASK_ID] [JSON_INPUT_OBJECT]"))
        XCTAssertTrue(surface.graphSummary.contains("plan CALL_MODEL [content.plan] -> write"))
        XCTAssertTrue(surface.graphSummary.contains("verify VERIFY [artifact_verified] -> pass:approval failure:rollback"))

        let replCommands = surface.replCommandDescriptors()
        XCTAssertEqual(
            Set(replCommands.map(\.verb)),
            [
                "api", "api-mount", "approve", "attachment", "describe", "exit", "help",
                "model", "model-tool", "onyx", "onyx-driver", "planning", "planning-bundle",
                "receipts", "reconcile", "refuse", "repl-mount", "rollback", "schema", "skill-tree",
                "skill-tree-json", "start", "tool-bindings", "tool-bindings-json", "watch",
            ]
        )
        let replStart = try XCTUnwrap(replCommands.first { $0.verb == "start" })
        XCTAssertEqual(replStart.kind, .runtime)
        XCTAssertEqual(replStart.action, .start)
        XCTAssertEqual(replStart.aliases, ["run"])
        XCTAssertEqual(replStart.usage, "start [TASK_ID] [JSON_INPUT_OBJECT]")
        XCTAssertFalse(replStart.requiresTask)
        XCTAssertTrue(replStart.changesTaskState)
        XCTAssertEqual(replStart.jsonBodyKind, .workflowInput)
        XCTAssertEqual(replStart.jsonFields.map(\.name), ["target"])
        let replApprove = try XCTUnwrap(replCommands.first { $0.verb == "approve" })
        XCTAssertEqual(replApprove.jsonBodyKind, .expectedState)
        XCTAssertEqual(replApprove.jsonFields.map(\.name), ["task_revision"])
        let replExit = try XCTUnwrap(replCommands.first { $0.verb == "exit" })
        XCTAssertEqual(replExit.kind, .local)
        XCTAssertEqual(replExit.aliases, ["quit"])
        let replAttachment = try XCTUnwrap(replCommands.first { $0.verb == "attachment" })
        XCTAssertEqual(replAttachment.kind, .local)
        XCTAssertEqual(replAttachment.aliases, ["manifest"])
        let replSkillTree = try XCTUnwrap(replCommands.first { $0.verb == "skill-tree" })
        XCTAssertEqual(replSkillTree.kind, .local)
        XCTAssertEqual(replSkillTree.aliases, ["skills"])
        let replToolBindings = try XCTUnwrap(replCommands.first { $0.verb == "tool-bindings" })
        XCTAssertEqual(replToolBindings.kind, .local)
        XCTAssertEqual(replToolBindings.aliases, ["tools"])
        for verb in [
            "repl-mount", "api-mount", "model-tool", "onyx-driver", "skill-tree-json",
            "tool-bindings-json", "planning-bundle",
        ] {
            let replArtifact = try XCTUnwrap(replCommands.first { $0.verb == verb })
            XCTAssertEqual(replArtifact.kind, .local)
            XCTAssertFalse(replArtifact.requiresTask)
            XCTAssertFalse(replArtifact.changesTaskState)
        }
        let replExamples = surface.replExamples()
        for verb in [
            "api", "model", "onyx", "skill-tree", "tool-bindings", "planning",
            "attachment", "repl-mount", "api-mount", "model-tool", "onyx-driver",
            "skill-tree-json", "tool-bindings-json", "planning-bundle",
        ] {
            XCTAssertTrue(replExamples.contains {
                $0.verb == verb && $0.line == verb
            })
        }
        XCTAssertTrue(replExamples.contains {
            $0.verb == "start" && $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertTrue(replExamples.contains {
            $0.verb == "approve" && $0.line == #"approve TASK-ID {"task_revision":0}"#
        })

        let modelTool = surface.modelCommandTool()
        XCTAssertEqual(modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(modelTool.parameters.map(\.name), ["line"])
        XCTAssertTrue(modelTool.description.contains("Structured REPL commands:"))
        XCTAssertTrue(modelTool.description.contains("json:workflow_input fields:target"))
        XCTAssertTrue(modelTool.description.contains(#"start TASK-ID {"target":"target"}"#))
        XCTAssertFalse(modelTool.description.contains("approve TASK_ID"))
        XCTAssertFalse(modelTool.description.contains("rollback TASK_ID"))
        XCTAssertFalse(modelTool.description.contains("json:expected_state fields:task_revision"))
        XCTAssertFalse(modelTool.description.contains("help [local]"))

        let api = SMLWorkflowAPICatalog(surface: surface)
        XCTAssertEqual(api.endpoints.count, 8)
        XCTAssertEqual(api.endpoints.first { $0.action == .start }?.bodyKind, .startTask)
        XCTAssertEqual(api.endpoints.first { $0.action == .approve }?.bodyKind, .expectedState)
        XCTAssertEqual(api.endpoints.first { $0.action == .start }?.bodyFields.map(\.name), ["target"])
        let apiStart = try XCTUnwrap(api.endpoints.first { $0.action == .start })
        let apiStartExample = try XCTUnwrap(apiStart.examples.first)
        XCTAssertEqual(apiStartExample.method, .post)
        XCTAssertEqual(apiStartExample.path, "/v1/workflows/content.release/tasks")
        XCTAssertEqual(apiStartExample.body["task_id"], .string("TASK-ID"))
        XCTAssertEqual(apiStartExample.body["input"], .object(["target": .string("target")]))
        let apiApprove = try XCTUnwrap(api.endpoints.first { $0.action == .approve })
        XCTAssertEqual(apiApprove.examples.first?.body["task_revision"], .number(0))

        let onyx = SMLOnyxDriverCompiler.compile(surface: surface)
        XCTAssertEqual(onyx.providerFamily, "onyx")
        XCTAssertEqual(onyx.plan.entrypoint, "plan")
        XCTAssertEqual(onyx.tools.map(\.reference), ["content.plan", "artifact_verified", "repository.write"])
        XCTAssertEqual(onyx.skillTree.first { $0.id == "write" }?.prerequisites, ["plan"])
        XCTAssertEqual(onyx.skillTree.first { $0.id == "verify" }?.successors, ["approval", "rollback"])
        XCTAssertEqual(onyx.skillTree.first { $0.id == "plan" }?.planning?.unitKind, .modelReasoning)
        XCTAssertEqual(onyx.skillTree.first { $0.id == "plan" }?.planning?.outputSchema, "content.plan.v1")
        XCTAssertEqual(onyx.skillTree.first { $0.id == "verify" }?.planning?.unitKind, .externalCapability)
        XCTAssertEqual(onyx.skillTree.first { $0.id == "receipt" }?.planning?.declaredOutputs, ["artifact", "task"])
        XCTAssertFalse(onyx.modelActions.contains(.approve))
        XCTAssertEqual(onyx.commandBindings.count, 8)
        let onyxStartBinding = try XCTUnwrap(onyx.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(onyxStartBinding.replLineTemplate, "start [TASK_ID] [JSON_INPUT_OBJECT]")
        XCTAssertEqual(onyxStartBinding.apiPathTemplate, "/v1/workflows/content.release/tasks")
        XCTAssertTrue(onyxStartBinding.modelEligible)
    }

    func testOnyxDriverIDHashesExactSemVerRevisionIntoBoundedIdentifier() throws {
        let longBuild = String(repeating: "build.segment-", count: 20) + "final"
        let version = "12.34.56-alpha.7+\(longBuild)"
        let first = SMLOnyxDriverCompiler.compile(surface: try makeSurface(version: version))
        let again = SMLOnyxDriverCompiler.compile(surface: try makeSurface(version: version))
        let other = SMLOnyxDriverCompiler.compile(
            surface: try makeSurface(version: version + ".other")
        )

        XCTAssertEqual(first.driverID, again.driverID)
        XCTAssertNotEqual(first.driverID, other.driverID)
        XCTAssertLessThanOrEqual(first.driverID.count, 128)
        XCTAssertTrue(SMLValidationSupport.identifierIsValid(first.driverID))
        XCTAssertFalse(first.driverID.contains("+"))
    }

    func testRuntimeBundlePackagesOneAdmittedWorkflowIntoAllGeneratedAdapters() async throws {
        let admitted = try makeAdmitted()
        let bundle = try SMLWorkflowRuntimeBundle.compile(
            admitted: admitted,
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation",
            commandID: { "bundle-command" },
            taskID: { "TASK-BUNDLE" }
        )

        XCTAssertEqual(bundle.surface.workflowID, "content.release")
        XCTAssertEqual(bundle.actor, "operator.luke")
        XCTAssertEqual(bundle.descriptor.workflowID, "content.release")
        XCTAssertEqual(bundle.descriptor.sourceKind, .langGraph)
        XCTAssertEqual(bundle.descriptor.sourceReference, "graphs/content_release.py")
        XCTAssertTrue(bundle.descriptor.graphSummary.contains("plan CALL_MODEL [content.plan] -> write"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("graph:"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("examples:"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("api - Print the generated workflow API endpoints"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("model - Print the generated model tool"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("onyx - Print the generated Onyx driver"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("skill-tree - Print the generated skill tree"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("tool-bindings - Print generated tool bindings"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("planning - Print the generated planning units"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("repl-mount - Print the machine-readable REPL mount descriptor"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("api-mount - Print the machine-readable workflow API mount routes"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("model-tool - Print the machine-readable model tool export"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("onyx-driver - Print the machine-readable Onyx driver manifest"))
        XCTAssertTrue(bundle.descriptor.repl.helpText.contains("planning-bundle - Print the machine-readable planning bundle"))
        XCTAssertTrue(bundle.descriptor.repl.commands.contains {
            $0.verb == "start"
                && $0.jsonBodyKind == .workflowInput
                && $0.jsonFields.map(\.name) == ["target"]
        })
        XCTAssertTrue(bundle.descriptor.repl.examples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertTrue(bundle.descriptor.repl.examples.contains {
            $0.verb == "planning" && $0.line == "planning"
        })
        XCTAssertEqual(bundle.descriptor.api.basePath, "/automation")
        XCTAssertEqual(
            bundle.descriptor.api.endpoints.first { $0.action == .start }?.bodyKind,
            .startTask
        )
        XCTAssertEqual(bundle.descriptor.model.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertTrue(bundle.descriptor.model.requiresNativeTools)
        XCTAssertFalse(bundle.descriptor.model.allowedActions.contains(.approve))
        XCTAssertEqual(bundle.descriptor.onyx.driverID, bundle.onyxDriver.driverID)

        guard case .command(let replStart) = try bundle.replCompiler.compile(
            #"start {"target":"bundle.md"}"#,
            issuedAtEpoch: 3_000
        ) else { return XCTFail("expected bundled REPL command") }
        XCTAssertEqual(replStart.task, "TASK-BUNDLE")
        XCTAssertEqual(replStart.arguments["workflow_id"], .string("content.release"))

        let apiStart = try bundle.apiCompiler.compile(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.release/tasks",
                body: [
                    "task_id": .string("TASK-API"),
                    "input": .object(["target": .string("api.md")]),
                ]
            ),
            issuedAtEpoch: 3_001
        )
        XCTAssertEqual(apiStart.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(apiStart.role, "release-manager")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-bundle-\(UUID().uuidString)", isDirectory: true)
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 3_000 }
        )
        let gateway = SMLCommandGateway(
            runtime: SMLRuntime(store: store, clock: { 3_000 }),
            replayGuard: store
        )
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = { command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "bundle-lease",
                roles: ["release-manager"],
                tasks: [command.task],
                operations: [command.op],
                scope: [:]
            )
        }
        let replSession = bundle.makeREPLSession(
            gateway: gateway,
            authorityResolver: authority,
            clock: { 3_000 }
        )
        let api = bundle.makeAPI(gateway: gateway, authorityResolver: authority, clock: { 3_000 })
        let modelAdapter = bundle.makeModelAdapter(
            binding: ProviderBinding(providerId: "onyx-test", model: "onyx-1"),
            providers: ProviderRegistry(providers: [], retryDelaysNanoseconds: []),
            gateway: gateway,
            authorityResolver: authority,
            clock: { 3_000 }
        )
        _ = bundle.makeModelSession(
            binding: ProviderBinding(providerId: "onyx-test", model: "onyx-1"),
            providers: ProviderRegistry(providers: [], retryDelaysNanoseconds: []),
            gateway: gateway,
            authorityResolver: authority,
            clock: { 3_000 }
        )

        let help = try await replSession.submit("help")
        XCTAssertTrue(help.output.contains("graph:"))
        XCTAssertTrue(help.output.contains("api"))
        XCTAssertTrue(help.output.contains("model"))
        XCTAssertTrue(help.output.contains("onyx"))
        XCTAssertTrue(help.output.contains("skill-tree"))
        XCTAssertTrue(help.output.contains("tool-bindings"))
        XCTAssertTrue(help.output.contains("planning"))
        XCTAssertTrue(help.output.contains("attachment"))
        let apiInfo = try await replSession.submit("api")
        XCTAssertNil(apiInfo.command)
        XCTAssertTrue(apiInfo.output.contains("base path: /automation"))
        XCTAssertTrue(apiInfo.output.contains("workflow path: /workflows/content.release"))
        XCTAssertTrue(apiInfo.output.contains("POST /automation/workflows/content.release/tasks"))
        XCTAssertTrue(apiInfo.output.contains(#"{"input":{"target":"target"},"task_id":"TASK-ID"}"#))
        XCTAssertTrue(apiInfo.output.contains("workflow metadata:"))
        XCTAssertTrue(apiInfo.output.contains("attachment: GET /automation/runtime/attachments/content.release"))
        XCTAssertTrue(apiInfo.output.contains("repl mount: GET /automation/runtime/repl-mounts/content.release"))
        XCTAssertTrue(apiInfo.output.contains("api mount: GET /automation/runtime/api-mounts/content.release"))
        XCTAssertTrue(apiInfo.output.contains("model tool: GET /automation/runtime/model-tools/content.release"))
        XCTAssertTrue(apiInfo.output.contains("onyx driver: GET /automation/runtime/onyx-drivers/content.release"))
        XCTAssertTrue(apiInfo.output.contains("skill tree: GET /automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(apiInfo.output.contains("tool bindings: GET /automation/runtime/tool-bindings/content.release"))
        XCTAssertTrue(apiInfo.output.contains("planning bundle: GET /automation/runtime/planning/content.release"))
        let modelInfo = try await replSession.submit("model")
        XCTAssertNil(modelInfo.command)
        XCTAssertTrue(modelInfo.output.contains(SMLWorkflowModelAdapter.toolName))
        XCTAssertTrue(modelInfo.output.contains(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertTrue(modelInfo.output.contains("model metadata:"))
        XCTAssertTrue(modelInfo.output.contains("model tool: GET /automation/runtime/model-tools/content.release"))
        XCTAssertTrue(modelInfo.output.contains("planning bundle: GET /automation/runtime/planning/content.release"))
        XCTAssertTrue(modelInfo.output.contains("onyx driver: GET /automation/runtime/onyx-drivers/content.release"))
        XCTAssertTrue(modelInfo.output.contains("skill tree: GET /automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(modelInfo.output.contains("tool bindings: GET /automation/runtime/tool-bindings/content.release"))
        let onyxInfo = try await replSession.submit("onyx")
        XCTAssertNil(onyxInfo.command)
        XCTAssertTrue(onyxInfo.output.contains(bundle.onyxDriver.driverID))
        XCTAssertTrue(onyxInfo.output.contains("onyx metadata:"))
        XCTAssertTrue(onyxInfo.output.contains("onyx driver: GET /automation/runtime/onyx-drivers/content.release"))
        XCTAssertTrue(onyxInfo.output.contains("skill tree: GET /automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(onyxInfo.output.contains("tool bindings: GET /automation/runtime/tool-bindings/content.release"))
        XCTAssertTrue(onyxInfo.output.contains("planning bundle: GET /automation/runtime/planning/content.release"))
        XCTAssertTrue(onyxInfo.output.contains("model tool: GET /automation/runtime/model-tools/content.release"))
        XCTAssertTrue(onyxInfo.output.contains("skill tree:"))
        let skillTreeInfo = try await replSession.submit("skill-tree")
        XCTAssertNil(skillTreeInfo.command)
        XCTAssertTrue(skillTreeInfo.output.contains("skill tree metadata:"))
        XCTAssertTrue(skillTreeInfo.output.contains("skill tree: GET /automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(skillTreeInfo.output.contains("tool bindings: GET /automation/runtime/tool-bindings/content.release"))
        XCTAssertTrue(skillTreeInfo.output.contains("planning bundle: GET /automation/runtime/planning/content.release"))
        XCTAssertTrue(skillTreeInfo.output.contains("plan:CALL_MODEL"))
        let toolBindingsInfo = try await replSession.submit("tool-bindings")
        XCTAssertNil(toolBindingsInfo.command)
        XCTAssertTrue(toolBindingsInfo.output.contains("tool binding metadata:"))
        XCTAssertTrue(toolBindingsInfo.output.contains("tool bindings: GET /automation/runtime/tool-bindings/content.release"))
        XCTAssertTrue(toolBindingsInfo.output.contains("skill tree: GET /automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(toolBindingsInfo.output.contains("planning bundle: GET /automation/runtime/planning/content.release"))
        XCTAssertTrue(toolBindingsInfo.output.contains("write:CALL_TOOL"))
        XCTAssertTrue(toolBindingsInfo.output.contains("ref:repository.write"))
        let planningInfo = try await replSession.submit("planning")
        XCTAssertNil(planningInfo.command)
        XCTAssertTrue(planningInfo.output.contains("planning metadata:"))
        XCTAssertTrue(planningInfo.output.contains("planning bundle: GET /automation/runtime/planning/content.release"))
        XCTAssertTrue(planningInfo.output.contains("skill tree: GET /automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(planningInfo.output.contains("tool bindings: GET /automation/runtime/tool-bindings/content.release"))
        XCTAssertTrue(planningInfo.output.contains("model tool: GET /automation/runtime/model-tools/content.release"))
        XCTAssertTrue(planningInfo.output.contains("api mount: GET /automation/runtime/api-mounts/content.release"))
        XCTAssertTrue(planningInfo.output.contains("repl mount: GET /automation/runtime/repl-mounts/content.release"))
        XCTAssertTrue(planningInfo.output.contains("unit:model_reasoning"))
        XCTAssertTrue(planningInfo.output.contains("unit:external_capability"))
        let planningManifest = SMLWorkflowRuntimePlanningManifest(descriptors: [bundle.descriptor])
        XCTAssertEqual(planningManifest.schemaVersion, SMLWorkflowRuntimePlanningManifest.currentSchemaVersion)
        XCTAssertEqual(planningManifest.commandBindings.count, 8)
        let workflowMetadata = SMLWorkflowRuntimeWorkflowMetadataLinks(bundle.descriptor)
        let replMountInfo = try await replSession.submit("repl-mount")
        XCTAssertNil(replMountInfo.command)
        let replMount = try JSONDecoder().decode(
            SMLWorkflowRuntimeREPLMount.self,
            from: Data(replMountInfo.output.utf8)
        )
        XCTAssertEqual(replMount.workflowID, "content.release")
        XCTAssertEqual(replMount.workflowMetadata, workflowMetadata)
        XCTAssertEqual(replMount.commandBindings, planningManifest.commandBindings)
        XCTAssertTrue(replMount.commands.contains { $0.verb == "api-mount" })
        let apiMountInfo = try await replSession.submit("api-mount")
        XCTAssertNil(apiMountInfo.command)
        let apiMounts = try JSONDecoder().decode(
            [SMLWorkflowRuntimeAPIMount].self,
            from: Data(apiMountInfo.output.utf8)
        )
        XCTAssertEqual(apiMounts.count, 8)
        let apiStartMount = try XCTUnwrap(apiMounts.first { $0.action == .start })
        XCTAssertEqual(apiStartMount.operationID, "start_workflow_task_ContentRelease")
        XCTAssertEqual(apiStartMount.authority, .hostCommandGateway)
        XCTAssertEqual(apiStartMount.pathTemplate, "/automation/workflows/content.release/tasks")
        let modelToolInfo = try await replSession.submit("model-tool")
        XCTAssertNil(modelToolInfo.command)
        let modelToolExport = try JSONDecoder().decode(
            SMLWorkflowRuntimeModelToolExport.self,
            from: Data(modelToolInfo.output.utf8)
        )
        XCTAssertEqual(modelToolExport.workflowID, "content.release")
        XCTAssertEqual(modelToolExport.tool, bundle.descriptor.model.tool)
        XCTAssertEqual(modelToolExport.allowedActions, bundle.descriptor.model.allowedActions)
        XCTAssertEqual(modelToolExport.maximumCommandRounds, bundle.descriptor.model.maximumCommandRounds)
        XCTAssertEqual(modelToolExport.workflowMetadata, workflowMetadata)
        let onyxDriverInfo = try await replSession.submit("onyx-driver")
        XCTAssertNil(onyxDriverInfo.command)
        let onyxDriver = try JSONDecoder().decode(
            SMLOnyxDriverManifest.self,
            from: Data(onyxDriverInfo.output.utf8)
        )
        XCTAssertEqual(onyxDriver, bundle.onyxDriver)
        let skillTreeJSONInfo = try await replSession.submit("skill-tree-json")
        XCTAssertNil(skillTreeJSONInfo.command)
        let skillTreeJSON = try JSONDecoder().decode(
            [SMLOnyxSkillNode].self,
            from: Data(skillTreeJSONInfo.output.utf8)
        )
        XCTAssertEqual(skillTreeJSON, bundle.onyxDriver.skillTree)
        let toolBindingsJSONInfo = try await replSession.submit("tool-bindings-json")
        XCTAssertNil(toolBindingsJSONInfo.command)
        let toolBindingsJSON = try JSONDecoder().decode(
            [SMLOnyxToolBinding].self,
            from: Data(toolBindingsJSONInfo.output.utf8)
        )
        XCTAssertEqual(toolBindingsJSON, bundle.onyxDriver.tools)
        let planningBundleInfo = try await replSession.submit("planning-bundle")
        XCTAssertNil(planningBundleInfo.command)
        let planningBundle = try JSONDecoder().decode(
            SMLWorkflowRuntimePlanningWorkflowBundle.self,
            from: Data(planningBundleInfo.output.utf8)
        )
        XCTAssertEqual(planningBundle.workflowID, "content.release")
        XCTAssertEqual(planningBundle.workflowMetadata, workflowMetadata)
        XCTAssertEqual(planningBundle.skillIndex, planningManifest.skillIndex)
        XCTAssertEqual(planningBundle.toolBindings, bundle.onyxDriver.tools)
        XCTAssertEqual(planningBundle.commandBindings, planningManifest.commandBindings)
        let startBinding = try XCTUnwrap(planningManifest.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(startBinding.workflowID, "content.release")
        XCTAssertEqual(startBinding.replVerb, "start")
        XCTAssertEqual(startBinding.replAliases, ["run"])
        XCTAssertEqual(startBinding.replLineTemplate, "start [TASK_ID] [JSON_INPUT_OBJECT]")
        XCTAssertEqual(startBinding.replJSONBodyKind, .workflowInput)
        XCTAssertEqual(startBinding.replJSONFields.map(\.name), ["target"])
        XCTAssertEqual(startBinding.apiMethod, .post)
        XCTAssertEqual(startBinding.apiPathTemplate, "/automation/workflows/content.release/tasks")
        XCTAssertEqual(startBinding.apiOperationID, "start_workflow_task_ContentRelease")
        XCTAssertEqual(startBinding.apiBodyKind, .startTask)
        XCTAssertEqual(startBinding.apiBodyFields.map(\.name), ["target"])
        XCTAssertFalse(startBinding.readOnly)
        XCTAssertFalse(startBinding.requiresTask)
        XCTAssertTrue(startBinding.changesTaskState)
        XCTAssertTrue(startBinding.modelEligible)
        XCTAssertEqual(startBinding.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(startBinding.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(startBinding.modelRouterArgumentsTemplate, [
            "workflow_id": .string("content.release"),
            "line": .string("start [TASK_ID] [JSON_INPUT_OBJECT]"),
        ])
        XCTAssertEqual(startBinding.exampleReplLine, #"start TASK-ID {"target":"target"}"#)
        XCTAssertEqual(startBinding.exampleAPIPath, "/automation/workflows/content.release/tasks")
        let startExampleBody = try XCTUnwrap(startBinding.exampleAPIBody)
        XCTAssertEqual(startExampleBody["input"], .object(["target": .string("target")]))
        XCTAssertEqual(startBinding.exampleModelRouterArguments, [
            "workflow_id": .string("content.release"),
            "line": .string(#"start TASK-ID {"target":"target"}"#),
        ])
        XCTAssertEqual(bundle.onyxDriver.commandBindings, planningManifest.commandBindings)
        XCTAssertEqual(bundle.descriptor.onyx.commandBindings, planningManifest.commandBindings)
        let approveBinding = try XCTUnwrap(planningManifest.commandBindings.first {
            $0.action == .approve
        })
        XCTAssertEqual(approveBinding.replJSONBodyKind, .expectedState)
        XCTAssertEqual(approveBinding.apiPathTemplate, "/automation/workflows/content.release/tasks/{task_id}/approve")
        XCTAssertFalse(approveBinding.readOnly)
        XCTAssertTrue(approveBinding.requiresTask)
        XCTAssertTrue(approveBinding.changesTaskState)
        XCTAssertFalse(approveBinding.modelEligible)
        XCTAssertNil(approveBinding.exampleModelRouterArguments)
        let attachmentInfo = try await replSession.submit("attachment")
        XCTAssertNil(attachmentInfo.command)
        XCTAssertNil(attachmentInfo.result)
        let attachmentDescriptor = try JSONDecoder().decode(
            SMLWorkflowREPLAttachmentDescriptor.self,
            from: Data(attachmentInfo.output.utf8)
        )
        XCTAssertEqual(attachmentDescriptor.schemaVersion, SMLWorkflowREPLAttachmentDescriptor.currentSchemaVersion)
        XCTAssertEqual(attachmentDescriptor.workflowID, "content.release")
        XCTAssertEqual(attachmentDescriptor.sourceReference, "graphs/content_release.py")
        XCTAssertEqual(attachmentDescriptor.apiBasePath, "/automation")
        XCTAssertEqual(attachmentDescriptor.runtimeAttachmentsPath, "/automation/runtime/attachments")
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowAttachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowREPLMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowAPIMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowModelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowOnyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowSkillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowToolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertEqual(
            attachmentDescriptor.runtimeWorkflowPlanningPath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertEqual(attachmentDescriptor.workflowMetadata.workflowID, "content.release")
        XCTAssertEqual(attachmentDescriptor.workflowMetadata.workflowVersion, "1.0.0")
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.attachmentPath,
            attachmentDescriptor.runtimeWorkflowAttachmentPath
        )
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.replMountPath,
            attachmentDescriptor.runtimeWorkflowREPLMountPath
        )
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.apiMountPath,
            attachmentDescriptor.runtimeWorkflowAPIMountPath
        )
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.modelToolPath,
            attachmentDescriptor.runtimeWorkflowModelToolPath
        )
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.onyxDriverPath,
            attachmentDescriptor.runtimeWorkflowOnyxDriverPath
        )
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.skillTreePath,
            attachmentDescriptor.runtimeWorkflowSkillTreePath
        )
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.toolBindingsPath,
            attachmentDescriptor.runtimeWorkflowToolBindingsPath
        )
        XCTAssertEqual(
            attachmentDescriptor.workflowMetadata.planningBundlePath,
            attachmentDescriptor.runtimeWorkflowPlanningPath
        )
        let legacyAttachmentData = try JSONEncoder().encode(attachmentDescriptor)
        var legacyAttachmentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyAttachmentData) as? [String: Any]
        )
        legacyAttachmentObject.removeValue(forKey: "workflowMetadata")
        legacyAttachmentObject.removeValue(forKey: "runtimeWorkflowOnyxDriverPath")
        legacyAttachmentObject.removeValue(forKey: "runtimeWorkflowREPLMountPath")
        legacyAttachmentObject.removeValue(forKey: "runtimeWorkflowAPIMountPath")
        legacyAttachmentObject.removeValue(forKey: "runtimeWorkflowModelToolPath")
        legacyAttachmentObject.removeValue(forKey: "runtimeWorkflowSkillTreePath")
        legacyAttachmentObject.removeValue(forKey: "runtimeWorkflowToolBindingsPath")
        legacyAttachmentObject.removeValue(forKey: "runtimeWorkflowPlanningPath")
        let legacyAttachmentDecoded = try JSONDecoder().decode(
            SMLWorkflowREPLAttachmentDescriptor.self,
            from: JSONSerialization.data(withJSONObject: legacyAttachmentObject, options: [.sortedKeys])
        )
        XCTAssertEqual(
            legacyAttachmentDecoded.runtimeWorkflowREPLMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            legacyAttachmentDecoded.runtimeWorkflowAPIMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            legacyAttachmentDecoded.runtimeWorkflowModelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            legacyAttachmentDecoded.runtimeWorkflowOnyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            legacyAttachmentDecoded.runtimeWorkflowSkillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            legacyAttachmentDecoded.runtimeWorkflowToolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertEqual(
            legacyAttachmentDecoded.runtimeWorkflowPlanningPath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertEqual(legacyAttachmentDecoded.workflowMetadata, attachmentDescriptor.workflowMetadata)
        XCTAssertEqual(attachmentDescriptor.replCommands.first { $0.verb == "attachment" }?.aliases, ["manifest"])
        XCTAssertEqual(attachmentDescriptor.apiCatalog.endpoints.count, 8)
        XCTAssertEqual(attachmentDescriptor.modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(attachmentDescriptor.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(attachmentDescriptor.onyxDriverID, bundle.onyxDriver.driverID)
        XCTAssertEqual(attachmentDescriptor.skillTree.map(\.id), bundle.onyxDriver.skillTree.map(\.id))
        XCTAssertEqual(attachmentDescriptor.toolBindings.map(\.reference), [
            "content.plan", "artifact_verified", "repository.write",
        ])
        XCTAssertEqual(attachmentDescriptor.plan.entrypoint, "plan")
        XCTAssertEqual(attachmentDescriptor.commandBindings, planningManifest.commandBindings)
        let manifestInfo = try await replSession.submit("manifest")
        XCTAssertNil(manifestInfo.command)
        XCTAssertEqual(manifestInfo.output, attachmentInfo.output)
        XCTAssertEqual(api.compiler.catalog.basePath, "/automation")
        XCTAssertEqual(modelAdapter.surface.workflowID, "content.release")
        XCTAssertEqual(modelAdapter.allowedActions, SMLWorkflowSurface.modelDefaultActions)
    }

    func testRuntimeBundleSupportsCustomWorkflowAPIPathAcrossCompilerOnyxAndMountContract() throws {
        let admitted = try makeAdmitted()
        let bundle = try SMLWorkflowRuntimeBundle.compile(
            admitted: admitted,
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation",
            apiWorkflowPath: "/review",
            commandID: { "custom-route-command" },
            taskID: { "TASK-CUSTOM" }
        )

        XCTAssertEqual(bundle.descriptor.api.basePath, "/automation")
        XCTAssertEqual(bundle.descriptor.api.workflowPath, "/review")
        let startEndpoint = try XCTUnwrap(bundle.descriptor.api.endpoints.first {
            $0.action == .start
        })
        XCTAssertEqual(startEndpoint.pathTemplate, "/automation/review/tasks")
        XCTAssertEqual(startEndpoint.examples.first?.path, "/automation/review/tasks")

        guard case .local(let apiInfo) = try bundle.replCompiler.compile(
            "api",
            issuedAtEpoch: 3_049
        ) else { return XCTFail("expected local API REPL output") }
        XCTAssertTrue(apiInfo.contains("base path: /automation"))
        XCTAssertTrue(apiInfo.contains("workflow path: /review"))
        XCTAssertTrue(apiInfo.contains("POST /automation/review/tasks"))
        XCTAssertFalse(apiInfo.contains("POST /automation/workflows/content.release/tasks"))
        XCTAssertTrue(apiInfo.contains("api mount: GET /automation/runtime/api-mounts/content.release"))

        let command = try bundle.apiCompiler.compile(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/review/tasks",
                body: [
                    "task_id": .string("TASK-API"),
                    "input": .object(["target": .string("api.md")]),
                ]
            ),
            issuedAtEpoch: 3_050
        )
        XCTAssertEqual(command.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(command.role, "release-manager")
        XCTAssertEqual(command.arguments["workflow_id"], .string("content.release"))

        XCTAssertThrowsError(try bundle.apiCompiler.compile(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.release/tasks",
                body: [
                    "task_id": .string("TASK-API"),
                    "input": .object(["target": .string("api.md")]),
                ]
            ),
            issuedAtEpoch: 3_051
        )) {
            XCTAssertEqual(
                $0 as? SMLWorkflowAPIError,
                .routeNotFound(method: "POST", path: "/automation/workflows/content.release/tasks")
            )
        }

        XCTAssertEqual(bundle.onyxDriver.api.basePath, "/automation")
        XCTAssertEqual(bundle.onyxDriver.api.workflowPath, "/review")
        let onyxStartBinding = try XCTUnwrap(bundle.onyxDriver.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(onyxStartBinding.apiPathTemplate, "/automation/review/tasks")
        XCTAssertEqual(onyxStartBinding.exampleAPIPath, "/automation/review/tasks")

        let registry = try SMLWorkflowRuntimeRegistry(bundles: [bundle])
        let replMount = try XCTUnwrap(registry.mountContract.replMounts.first)
        XCTAssertEqual(replMount.apiWorkflowPath, "/review")
        XCTAssertEqual(
            replMount.workflowMetadata.replMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.modelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.planningBundlePath,
            "/automation/runtime/planning/content.release"
        )
        let workflowMount = try XCTUnwrap(registry.mountContract.workflowMounts.first)
        XCTAssertEqual(workflowMount.apiWorkflowPath, "/review")
        XCTAssertEqual(workflowMount.workflowMetadata, replMount.workflowMetadata)
        XCTAssertEqual(workflowMount.repl.apiWorkflowPath, "/review")
        let workflowMountStartRoute = try XCTUnwrap(workflowMount.apiRoutes.first {
            $0.action == .start
        })
        XCTAssertEqual(workflowMountStartRoute.workflowMetadata, workflowMount.workflowMetadata)
        XCTAssertEqual(
            workflowMountStartRoute.workflowMetadata?.apiMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        let mountContractStartRoute = try XCTUnwrap(registry.mountContract.apiRoutes.first {
            $0.workflowID == "content.release" && $0.action == .start
        })
        XCTAssertEqual(mountContractStartRoute.workflowMetadata, workflowMount.workflowMetadata)
        let metadataRoute = try XCTUnwrap(registry.mountContract.apiRoutes.first {
            $0.handlerKind == .metadata && $0.metadataResource == .workflowAPIMount
        })
        XCTAssertNil(metadataRoute.workflowMetadata)
        XCTAssertEqual(registry.catalog.planningManifest.workflows.first?.apiWorkflowPath, "/review")
        XCTAssertEqual(registry.catalog.agentGuide.workflowGuides.first?.apiWorkflowPath, "/review")
        XCTAssertEqual(registry.catalog.hostGuide.workflowBindings.first?.apiWorkflowPath, "/review")
        let hostWorkflow = try XCTUnwrap(registry.hostWiring.workflows.first)
        XCTAssertEqual(hostWorkflow.apiWorkflowPath, "/review")
        XCTAssertEqual(hostWorkflow.apiRoutes.first { $0.action == .start }?.workflowMetadata, workflowMount.workflowMetadata)
        XCTAssertEqual(registry.hostWiring.attachmentManifests.first?.apiWorkflowPath, "/review")
        XCTAssertEqual(
            registry.hostWiring.attachmentManifests.first?.apiRoutes.first {
                $0.action == .start
            }?.workflowMetadata,
            workflowMount.workflowMetadata
        )
        let launchDescriptor = SMLWorkflowRuntimeLaunchDescriptor(
            registry: registry,
            installedWorkflows: [],
            sourcePackage: try SMLWorkflowRuntimeSourcePackage(
                normalizedWorkflows: [workflow()],
                runtime: registry.export()
            )
        )
        XCTAssertEqual(launchDescriptor.workflows.first?.apiWorkflowPath, "/review")
        XCTAssertEqual(
            launchDescriptor.workflows.first?.apiRoutes.first { $0.action == .start }?.workflowMetadata,
            workflowMount.workflowMetadata
        )
        XCTAssertEqual(launchDescriptor.sourceSummaries.first?.apiWorkflowPath, "/review")
        let legacyMountData = try JSONEncoder().encode(workflowMount)
        var legacyMountObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyMountData) as? [String: Any]
        )
        legacyMountObject.removeValue(forKey: "apiWorkflowPath")
        let decodedLegacyMount = try JSONDecoder().decode(
            SMLWorkflowRuntimeWorkflowMount.self,
            from: JSONSerialization.data(withJSONObject: legacyMountObject, options: [.sortedKeys])
        )
        XCTAssertEqual(decodedLegacyMount.apiWorkflowPath, "/review")
        var legacyRouteObject = try XCTUnwrap(
            (legacyMountObject["apiRoutes"] as? [[String: Any]])?.first
        )
        legacyRouteObject.removeValue(forKey: "workflowMetadata")
        let decodedLegacyRoute = try JSONDecoder().decode(
            SMLWorkflowRuntimeAPIMount.self,
            from: JSONSerialization.data(withJSONObject: legacyRouteObject, options: [.sortedKeys])
        )
        XCTAssertNil(decodedLegacyRoute.workflowMetadata)

        let start = try registry.mountContract.resolveAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/review/tasks",
                body: [
                    "task_id": .string("TASK-START"),
                    "input": .object(["target": .string("notes.md")]),
                ]
            )
        )
        XCTAssertEqual(start.route.workflowID, "content.release")
        XCTAssertEqual(start.route.action, .start)
        XCTAssertEqual(start.route.pathTemplate, "/automation/review/tasks")
        XCTAssertEqual(start.route.workflowMetadata, workflowMount.workflowMetadata)

        XCTAssertThrowsError(try registry.mountContract.resolveAPI(
            method: .post,
            path: "/automation/workflows/content.release/tasks"
        )) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeMountContractError,
                .routeNotFound(method: "POST", path: "/automation/workflows/content.release/tasks")
            )
        }

        XCTAssertThrowsError(try SMLWorkflowAPICompiler(
            surface: bundle.surface,
            actor: "operator.luke",
            basePath: "/automation",
            workflowPath: "relative"
        )) {
            XCTAssertEqual($0 as? SMLWorkflowAPIError, .invalidPath("relative"))
        }
    }

    func testRuntimeBundleDescriptorRoundTripsWithoutActorOrAuthority() throws {
        let bundle = try SMLWorkflowRuntimeBundle.compile(
            admitted: try makeAdmitted(),
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        )

        let data = try JSONEncoder().encode(bundle.descriptor)
        let decoded = try JSONDecoder().decode(SMLWorkflowRuntimeDescriptor.self, from: data)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded, bundle.descriptor)
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
        XCTAssertFalse(encoded.contains("model-lease"))
        XCTAssertTrue(encoded.contains("\"commands\""))
        XCTAssertTrue(encoded.contains("\"examples\""))
        XCTAssertEqual(
            decoded.repl.commands.first { $0.verb == "start" }?.jsonFields.map(\.name),
            ["target"]
        )
        XCTAssertTrue(decoded.repl.examples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertEqual(
            decoded.onyx.skillTree.first { $0.id == "plan" }?.planning?.unitKind,
            .modelReasoning
        )
        XCTAssertEqual(
            decoded.api.endpoints.first { $0.action == .approve }?.bodyKind,
            .expectedState
        )

        var descriptorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var replObject = try XCTUnwrap(descriptorObject["repl"] as? [String: Any])
        replObject.removeValue(forKey: "commands")
        replObject.removeValue(forKey: "examples")
        descriptorObject["repl"] = replObject
        let legacyData = try JSONSerialization.data(withJSONObject: descriptorObject, options: [.sortedKeys])
        let legacyDecoded = try JSONDecoder().decode(SMLWorkflowRuntimeDescriptor.self, from: legacyData)
        XCTAssertEqual(legacyDecoded.repl.commands, [])
        XCTAssertEqual(legacyDecoded.repl.examples, [])
    }

    func testRuntimeRegistryMountsAdmittedWorkflowsAndRoutesGeneratedSurfaces() async throws {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [
                makeAdmitted(),
                makeAdmitted(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation",
            commandID: { "registry-command" },
            taskID: { "TASK-REGISTRY-GENERATED" }
        )

        XCTAssertEqual(registry.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(registry.catalog.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(registry.catalog.apiEndpoints.count, 16)
        XCTAssertEqual(
            try registry.descriptor(workflowID: "content.review").sourceReference,
            "graphs/content_review.py"
        )
        XCTAssertEqual(
            try registry.onyxDriver(workflowID: "content.review").plan.entrypoint,
            "plan"
        )

        guard case .command(let replStart) = try registry.compileREPL(
            #"start TASK-REVIEW {"target":"review.md"}"#,
            workflowID: "content.review",
            issuedAtEpoch: 4_000
        ) else { return XCTFail("expected registry-routed REPL command") }
        XCTAssertEqual(replStart.task, "TASK-REVIEW")
        XCTAssertEqual(replStart.arguments["workflow_id"], .string("content.review"))

        let apiDescribe = try registry.compileAPI(
            SMLWorkflowAPIRequest(
                method: .get,
                path: "/automation/workflows/content.release"
            ),
            issuedAtEpoch: 4_001
        )
        XCTAssertEqual(apiDescribe.op, SMLRuntimeCommandOperation.workflowInspect)
        XCTAssertEqual(apiDescribe.arguments["workflow_id"], .string("content.release"))

        XCTAssertEqual(
            try registry.route(
                for: SMLWorkflowAPIRequest(
                    method: .get,
                    path: "/automation/runtime/launch"
                )
            ),
            .metadata(.launch)
        )
        let workflowStartRequest = SMLWorkflowAPIRequest(
            method: .post,
            path: "/automation/workflows/content.review/tasks",
            body: [
                "task_id": .string("TASK-ROUTE"),
                "input": .object(["target": .string("route.md")]),
            ]
        )
        XCTAssertEqual(
            try registry.route(for: workflowStartRequest),
            .workflow(workflowID: "content.review")
        )
        XCTAssertThrowsError(try registry.metadataResource(for: workflowStartRequest)) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .routeNotFound(method: "POST", path: "/automation/workflows/content.review/tasks")
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-registry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 4_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 4_000 })
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        let installed = try await registry.installAll(into: runtime)
        XCTAssertEqual(installed.map(\.id), ["content.release", "content.review"])

        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = { command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "registry-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }
        let runtimeAPI = registry.makeAPI(
            gateway: gateway,
            authorityResolver: authority,
            clock: { 4_000 }
        )
        XCTAssertEqual(runtimeAPI.catalog.workflowIDs, ["content.release", "content.review"])

        let started = try await runtimeAPI.handle(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.review/tasks",
                body: [
                    "task_id": .string("TASK-REGISTRY"),
                    "input": .object(["target": .string("review.md")]),
                ]
            )
        )
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertEqual(started.command.arguments["workflow_id"], .string("content.review"))
        XCTAssertEqual(started.result.task?.workflowID, "content.review")

        let replSession = try registry.makeREPLSession(
            workflowID: "content.release",
            gateway: gateway,
            authorityResolver: authority,
            clock: { 4_000 }
        )
        let help = try await replSession.submit("help")
        XCTAssertTrue(help.output.contains("content.release"))

        let modelAdapter = try registry.makeModelAdapter(
            workflowID: "content.review",
            binding: ProviderBinding(providerId: "onyx-test", model: "onyx-1"),
            providers: ProviderRegistry(providers: [], retryDelaysNanoseconds: []),
            gateway: gateway,
            authorityResolver: authority,
            clock: { 4_000 }
        )
        XCTAssertEqual(modelAdapter.surface.workflowID, "content.review")
        _ = try registry.makeModelSession(
            workflowID: "content.release",
            binding: ProviderBinding(providerId: "onyx-test", model: "onyx-1"),
            providers: ProviderRegistry(providers: [], retryDelaysNanoseconds: []),
            gateway: gateway,
            authorityResolver: authority,
            clock: { 4_000 }
        )

        XCTAssertThrowsError(
            try registry.descriptor(workflowID: "missing.workflow")
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .unknownWorkflow("missing.workflow")
            )
        }
        XCTAssertThrowsError(
            try registry.compileAPI(
                SMLWorkflowAPIRequest(
                    method: .get,
                    path: "/automation/workflows/content.review/%2e%2e"
                ),
                issuedAtEpoch: 4_002
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .invalidAPIPath("/automation/workflows/content.review/%2e%2e")
            )
        }
        XCTAssertThrowsError(
            try registry.compileAPI(
                SMLWorkflowAPIRequest(
                    method: .get,
                    path: "/automation/workflows/content.review/tasks/TASK-REGISTRY/unknown"
                ),
                issuedAtEpoch: 4_003
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .routeNotFound(
                    method: "GET",
                    path: "/automation/workflows/content.review/tasks/TASK-REGISTRY/unknown"
                )
            )
        }
        XCTAssertThrowsError(
            try registry.compileAPI(
                SMLWorkflowAPIRequest(
                    method: .get,
                    path: "/automation/runtime/mount"
                ),
                issuedAtEpoch: 4_004
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .routeNotFound(method: "GET", path: "/automation/runtime/mount")
            )
        }
    }

    func testRuntimeRegistryRejectsEmptyAndDuplicateWorkflowMounts() throws {
        XCTAssertThrowsError(try SMLWorkflowRuntimeRegistry(bundles: [])) {
            XCTAssertEqual($0 as? SMLWorkflowRuntimeRegistryError, .emptyRegistry)
        }
        XCTAssertThrowsError(try SMLWorkflowRuntimeRegistry.compile(
            admitted: [makeAdmitted(), makeAdmitted(version: "1.0.1")],
            role: "release-manager",
            actor: "operator.luke"
        )) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .duplicateWorkflowID("content.release")
            )
        }
        XCTAssertThrowsError(try SMLWorkflowRuntimeRegistry.compile(
            mounts: [
                SMLWorkflowRuntimeMount(
                    admitted: makeAdmitted(),
                    role: "release-manager",
                    actor: "operator.luke",
                    apiBasePath: "/automation",
                    apiWorkflowPath: "/collide"
                ),
                SMLWorkflowRuntimeMount(
                    admitted: makeAdmitted(
                        id: "content.review",
                        name: "Content review",
                        sourceReference: "graphs/content_review.py"
                    ),
                    role: "release-manager",
                    actor: "operator.luke",
                    apiBasePath: "/automation",
                    apiWorkflowPath: "/collide"
                ),
            ]
        )) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .ambiguousAPIRoute(method: "GET", path: "/automation/collide")
            )
        }
    }

    func testRuntimeRegistryAdmitsCandidateWorkflowsIntoMountedSurfaces() throws {
        let catalog = SMLExecutionAdmissionCatalog(
            toolCapabilities: ["repository.write"],
            modelPurposes: ["content.plan"],
            modelOutputSchemas: ["content.plan.v1"],
            verifiers: ["artifact_verified"],
            approvalAuthorities: ["release_approver"]
        )
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            workflows: [
                workflow(),
                workflow(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            admissionCatalog: catalog,
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation",
            commandID: { "candidate-command" },
            taskID: { "TASK-CANDIDATE" }
        )

        XCTAssertEqual(registry.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(try registry.descriptor(workflowID: "content.review").sourceKind, .langGraph)
        XCTAssertEqual(
            try registry.resolveWorkflowMount(workflowID: "content.review").apiRoutes.count,
            8
        )
        guard case .command(let replStart) = try registry.compileREPL(
            #"start {"target":"candidate.md"}"#,
            workflowID: "content.review",
            issuedAtEpoch: 4_100
        ) else { return XCTFail("expected candidate workflow REPL command") }
        XCTAssertEqual(replStart.task, "TASK-CANDIDATE")
        XCTAssertEqual(replStart.arguments["workflow_id"], .string("content.review"))

        let apiStart = try registry.compileAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.review/tasks",
                body: [
                    "task_id": .string("TASK-CANDIDATE-API"),
                    "input": .object(["target": .string("candidate-api.md")]),
                ]
            ),
            issuedAtEpoch: 4_101
        )
        XCTAssertEqual(apiStart.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(apiStart.arguments["workflow_id"], .string("content.review"))
        XCTAssertEqual(registry.export().mountContract.workflowMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])

        XCTAssertThrowsError(
            try SMLWorkflowRuntimeRegistry.compile(
                workflows: [workflow()],
                admissionCatalog: SMLExecutionAdmissionCatalog(),
                role: "release-manager",
                actor: "operator.luke",
                apiBasePath: "/automation"
            )
        ) {
            guard let error = $0 as? SMLWorkflowAdmissionError else {
                return XCTFail("expected admission failure, got \($0)")
            }
            XCTAssertTrue(
                error.diagnostics.contains { $0.code == "unregistered_model_purpose" }
            )
            XCTAssertTrue(
                error.diagnostics.contains { $0.code == "unregistered_tool" }
            )
        }
    }

    func testRuntimeAppLaunchesCandidateWorkflowsIntoBoundFacade() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 4_200 }
        )
        let runtime = SMLRuntime(store: store, clock: { 4_200 })
        let catalog = SMLExecutionAdmissionCatalog(
            toolCapabilities: ["repository.write"],
            modelPurposes: ["content.plan"],
            modelOutputSchemas: ["content.plan.v1"],
            verifiers: ["artifact_verified"],
            approvalAuthorities: ["release_approver"]
        )
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = { command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "launch-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }

        let launch = try await SMLWorkflowRuntimeApp.launch(
            workflows: [
                workflow(),
                workflow(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            admissionCatalog: catalog,
            runtime: runtime,
            replayGuard: store,
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation",
            authorityResolver: authority,
            commandID: { "launch-command" },
            taskID: { "TASK-LAUNCH-GENERATED" },
            clock: { 4_200 }
        )

        XCTAssertEqual(launch.installedWorkflows.map(\.id), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(launch.app.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(launch.mountContract.workflowMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(launch.hostWiring, launch.registry.hostWiring)
        XCTAssertEqual(launch.app.hostWiring, launch.hostWiring)
        XCTAssertEqual(launch.hostWiring.workflows.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(
            try launch.app.resolveWorkflowMount(workflowID: "content.review").apiRoutes.count,
            8
        )
        XCTAssertNil(launch.sourcePackage)

        let launchDescriptor = launch.launchDescriptor
        XCTAssertEqual(
            launchDescriptor.schemaVersion,
            SMLWorkflowRuntimeLaunchDescriptor.currentSchemaVersion
        )
        XCTAssertNil(launchDescriptor.sourcePackageSchemaVersion)
        XCTAssertEqual(
            launchDescriptor.runtimeExportSchemaVersion,
            SMLWorkflowRuntimeExport.currentSchemaVersion
        )
        XCTAssertEqual(launchDescriptor.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(launchDescriptor.installedWorkflowIDs, ["content.release", "content.review"])
        XCTAssertTrue(launchDescriptor.missingInstalledWorkflowIDs.isEmpty)
        XCTAssertTrue(launchDescriptor.unexpectedInstalledWorkflowIDs.isEmpty)
        XCTAssertTrue(launchDescriptor.launchComplete)
        XCTAssertEqual(launchDescriptor.apiBasePaths, ["/automation"])
        XCTAssertEqual(launchDescriptor.metadataEndpoints.count, 20)
        XCTAssertEqual(launch.app.launchDescriptor, launchDescriptor)
        XCTAssertEqual(launch.app.runtimeAPI.launchDescriptor, launchDescriptor)
        XCTAssertEqual(launchDescriptor.hostWiring, launch.hostWiring)
        XCTAssertEqual(
            launchDescriptor.modelRouter.tool.name,
            SMLWorkflowRuntimeModelAdapter.toolName
        )
        XCTAssertEqual(launchDescriptor.planningWorkflowIDs, [
            "content.release", "content.review",
        ])
        XCTAssertTrue(
            launchDescriptor.requiredHostServices.contains("transport_router_for_repl_and_api")
        )
        XCTAssertEqual(launchDescriptor.launchSteps.map(\.id), [
            "decode_source_package",
            "fresh_host_admission",
            "launch_runtime_app",
            "serve_descriptor_metadata",
            "route_repl_and_api",
            "attach_model_router",
            "attach_onyx_and_planning",
        ])
        let reviewLaunch = try XCTUnwrap(
            launchDescriptor.workflows.first { $0.workflowID == "content.review" }
        )
        XCTAssertTrue(reviewLaunch.installed)
        XCTAssertEqual(reviewLaunch.installedInstructionCount, 7)
        XCTAssertEqual(reviewLaunch.replMount.workflowID, "content.review")
        XCTAssertEqual(reviewLaunch.apiRoutes.count, 8)
        XCTAssertEqual(reviewLaunch.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(reviewLaunch.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(reviewLaunch.planningWorkflowID, "content.review")
        XCTAssertEqual(Set(reviewLaunch.hostBindingChannels), [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
        ])
        XCTAssertEqual(reviewLaunch.commandBindings, reviewLaunch.replMount.commandBindings)
        XCTAssertEqual(reviewLaunch.commandBindings.count, 8)
        XCTAssertEqual(reviewLaunch.skillIndex.count, 7)
        XCTAssertEqual(
            reviewLaunch.skillIndex.first { $0.instructionID == "plan" }?.reference,
            "content.plan"
        )
        let reviewLaunchAttachment = try XCTUnwrap(reviewLaunch.attachment)
        XCTAssertEqual(
            reviewLaunchAttachment,
            launchDescriptor.hostWiring.attachmentManifests.first {
                $0.workflowID == "content.review"
            }
        )
        XCTAssertEqual(reviewLaunchAttachment.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(reviewLaunchAttachment.model?.maximumCommandRounds, 4)
        XCTAssertEqual(reviewLaunchAttachment.skillIndex, reviewLaunch.skillIndex)
        XCTAssertEqual(reviewLaunchAttachment.commandBindings, reviewLaunch.commandBindings)
        XCTAssertEqual(reviewLaunchAttachment.plan?.entrypoint, "plan")
        XCTAssertEqual(reviewLaunchAttachment.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)

        var legacyLaunchWorkflowObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(reviewLaunch)
            ) as? [String: Any]
        )
        legacyLaunchWorkflowObject.removeValue(forKey: "commandBindings")
        legacyLaunchWorkflowObject.removeValue(forKey: "skillIndex")
        legacyLaunchWorkflowObject.removeValue(forKey: "attachment")
        let legacyLaunchWorkflowData = try JSONSerialization.data(
            withJSONObject: legacyLaunchWorkflowObject,
            options: [.sortedKeys]
        )
        let legacyLaunchWorkflow = try JSONDecoder().decode(
            SMLWorkflowRuntimeLaunchWorkflow.self,
            from: legacyLaunchWorkflowData
        )
        XCTAssertEqual(legacyLaunchWorkflow.commandBindings, reviewLaunch.replMount.commandBindings)
        XCTAssertEqual(legacyLaunchWorkflow.skillIndex, [])
        XCTAssertNil(legacyLaunchWorkflow.attachment)

        let encodedLaunchDescriptor = String(
            decoding: try JSONEncoder().encode(launchDescriptor),
            as: UTF8.self
        )
        XCTAssertFalse(encodedLaunchDescriptor.contains("operator.luke"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("launch-lease"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("authenticatedActor"))

        let started = try await launch.app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.review/tasks",
                body: [
                    "task_id": .string("TASK-LAUNCH"),
                    "input": .object(["target": .string("launch.md")]),
                ]
            )
        )
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertEqual(started.route?.operationID, "start_workflow_task_ContentReview")
        XCTAssertEqual(started.command?.role, "release-manager")
        XCTAssertEqual(started.result?.task?.workflowID, "content.review")

        let exported = launch.export(title: "Launched Runtime", version: "2026.08")
        XCTAssertEqual(exported.mountContract.workflowMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])
        let encodedExport = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        XCTAssertFalse(encodedExport.contains("operator.luke"))
        XCTAssertFalse(encodedExport.contains("launch-lease"))
    }

    func testRuntimeRegistryCatalogRoundTripsWithoutActorsOrLeases() throws {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [makeAdmitted()],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        )

        let data = try JSONEncoder().encode(registry.catalog)
        let decoded = try JSONDecoder().decode(SMLWorkflowRuntimeCatalog.self, from: data)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded, registry.catalog)
        XCTAssertEqual(decoded.workflowIDs, ["content.release"])
        XCTAssertEqual(decoded.onyxDrivers.map(\.workflowID), ["content.release"])
        XCTAssertEqual(decoded.modelRouter.workflowIDs, ["content.release"])
        XCTAssertEqual(decoded.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(decoded.modelRouter.tool.parameters.map(\.name), ["workflow_id", "line"])
        let decodedRouterMetadata = try XCTUnwrap(decoded.modelRouter.workflowMetadata.first)
        XCTAssertEqual(decodedRouterMetadata.workflowID, "content.release")
        XCTAssertEqual(
            decodedRouterMetadata.attachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            decodedRouterMetadata.replMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            decodedRouterMetadata.apiMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            decodedRouterMetadata.modelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            decodedRouterMetadata.onyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            decodedRouterMetadata.planningBundlePath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertTrue(decoded.modelRouter.examples.contains {
            $0.toolName == SMLWorkflowRuntimeModelAdapter.toolName
                && $0.workflowID == "content.release"
                && $0.arguments == [
                    "workflow_id": .string("content.release"),
                    "line": .string(#"start TASK-ID {"target":"target"}"#),
                ]
        })
        let legacyRouterData = try JSONEncoder().encode(decoded.modelRouter)
        var legacyRouterObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyRouterData) as? [String: Any]
        )
        legacyRouterObject.removeValue(forKey: "workflowMetadata")
        let legacyRouter = try JSONDecoder().decode(
            SMLWorkflowRuntimeModelRouterDescriptor.self,
            from: JSONSerialization.data(withJSONObject: legacyRouterObject, options: [.sortedKeys])
        )
        XCTAssertEqual(legacyRouter.workflowMetadata, [])
        XCTAssertEqual(decoded.planningManifest.workflowIDs, ["content.release"])
        XCTAssertEqual(decoded.planningManifest.workflows.map(\.entrypoint), ["plan"])
        let planningWorkflow = try XCTUnwrap(decoded.planningManifest.workflows.first)
        XCTAssertEqual(
            planningWorkflow.workflowMetadata.attachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            planningWorkflow.workflowMetadata.replMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            planningWorkflow.workflowMetadata.modelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            planningWorkflow.workflowMetadata.planningBundlePath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertEqual(
            decoded.planningManifest.toolIndex.map(\.reference),
            ["content.plan", "artifact_verified", "repository.write"]
        )
        XCTAssertEqual(
            decoded.planningManifest.approvalGates.map(\.instructionID),
            ["approval"]
        )
        let mount = decoded.mountContract
        XCTAssertEqual(mount.schemaVersion, SMLWorkflowRuntimeMountContract.currentSchemaVersion)
        XCTAssertEqual(mount.workflowIDs, ["content.release"])
        XCTAssertEqual(mount.apiBasePaths, ["/automation"])
        XCTAssertEqual(mount.replMounts.map(\.workflowID), ["content.release"])
        XCTAssertEqual(mount.replMounts.map(\.modelRouterToolName), [
            SMLWorkflowRuntimeModelAdapter.toolName,
        ])
        let replMount = try XCTUnwrap(mount.replMounts.first)
        XCTAssertEqual(
            replMount.commands.first { $0.verb == "start" }?.jsonBodyKind,
            .workflowInput
        )
        XCTAssertEqual(
            replMount.commands.first { $0.verb == "start" }?.jsonFields.map(\.name),
            ["target"]
        )
        XCTAssertTrue(replMount.examples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertEqual(
            replMount.workflowMetadata.attachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.replMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.apiMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.modelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.onyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.skillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.toolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertEqual(
            replMount.workflowMetadata.planningBundlePath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertEqual(replMount.commandBindings.count, 8)
        let replStartBinding = try XCTUnwrap(replMount.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(replStartBinding.replLineTemplate, "start [TASK_ID] [JSON_INPUT_OBJECT]")
        XCTAssertEqual(
            replStartBinding.apiPathTemplate,
            "/automation/workflows/content.release/tasks"
        )
        XCTAssertEqual(replStartBinding.exampleModelRouterArguments, [
            "workflow_id": .string("content.release"),
            "line": .string(#"start TASK-ID {"target":"target"}"#),
        ])
        XCTAssertEqual(mount.apiRoutes.count, 28)
        let startRoute = try XCTUnwrap(mount.apiRoutes.first {
            $0.workflowID == "content.release" && $0.action == .start
        })
        XCTAssertEqual(
            startRoute.examples.first?.body["input"],
            .object(["target": .string("target")])
        )
        XCTAssertEqual(mount.workflowMounts.map(\.workflowID), ["content.release"])
        XCTAssertEqual(mount.workflowMounts.first?.apiRoutes.count, 8)
        XCTAssertEqual(mount.workflowMounts.first?.workflowMetadata, replMount.workflowMetadata)
        XCTAssertEqual(
            mount.workflowMounts.first?.repl.commands.first {
                $0.verb == "start"
            }?.jsonFields.map(\.name),
            ["target"]
        )
        XCTAssertEqual(mount.workflowMounts.first?.commandBindings, replMount.commandBindings)
        XCTAssertEqual(mount.workflowMounts.first?.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(
            mount.workflowMounts.first?.modelRouterToolName,
            SMLWorkflowRuntimeModelAdapter.toolName
        )
        XCTAssertEqual(
            mount.workflowMounts.first?.onyxDriverID,
            decoded.onyxDrivers.first?.driverID
        )
        XCTAssertEqual(mount.workflowMounts.first?.planningWorkflowID, "content.release")
        XCTAssertEqual(mount.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(mount.onyxDriverIDs, decoded.onyxDrivers.map(\.driverID).sorted())
        XCTAssertEqual(mount.planningWorkflowIDs, ["content.release"])
        XCTAssertEqual(decoded.apiBasePaths, ["/automation"])
        XCTAssertEqual(
            decoded.metadataEndpoints.map(\.pathTemplate),
            [
                "/automation/runtime/catalog",
                "/automation/runtime/mount",
                "/automation/runtime/launch",
                "/automation/runtime/export",
                "/automation/runtime/openapi",
                "/automation/runtime/planning",
                "/automation/runtime/agent-guide",
                "/automation/runtime/host-guide",
                "/automation/runtime/host-wiring",
                "/automation/runtime/attachments",
                "/automation/runtime/attachments/{workflow_id}",
                "/automation/runtime/repl-mounts/{workflow_id}",
                "/automation/runtime/api-mounts/{workflow_id}",
                "/automation/runtime/model-tools/{workflow_id}",
                "/automation/runtime/onyx-drivers/{workflow_id}",
                "/automation/runtime/skill-trees/{workflow_id}",
                "/automation/runtime/tool-bindings/{workflow_id}",
                "/automation/runtime/planning/{workflow_id}",
                "/automation/runtime/model-router",
                "/automation/runtime/onyx-drivers",
            ]
        )
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))

        var legacyMountObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(replMount)) as? [String: Any]
        )
        legacyMountObject.removeValue(forKey: "commands")
        legacyMountObject.removeValue(forKey: "examples")
        legacyMountObject.removeValue(forKey: "commandBindings")
        legacyMountObject.removeValue(forKey: "workflowMetadata")
        let legacyMountData = try JSONSerialization.data(
            withJSONObject: legacyMountObject,
            options: [.sortedKeys]
        )
        let legacyMount = try JSONDecoder().decode(
            SMLWorkflowRuntimeREPLMount.self,
            from: legacyMountData
        )
        XCTAssertEqual(legacyMount.commands, [])
        XCTAssertEqual(legacyMount.examples, [])
        XCTAssertEqual(legacyMount.commandBindings, [])
        XCTAssertEqual(legacyMount.workflowMetadata, replMount.workflowMetadata)

        var legacyWorkflowMountObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(try XCTUnwrap(mount.workflowMounts.first))
            ) as? [String: Any]
        )
        legacyWorkflowMountObject.removeValue(forKey: "commandBindings")
        legacyWorkflowMountObject.removeValue(forKey: "workflowMetadata")
        let legacyWorkflowMountData = try JSONSerialization.data(
            withJSONObject: legacyWorkflowMountObject,
            options: [.sortedKeys]
        )
        let legacyWorkflowMount = try JSONDecoder().decode(
            SMLWorkflowRuntimeWorkflowMount.self,
            from: legacyWorkflowMountData
        )
        XCTAssertEqual(legacyWorkflowMount.commandBindings, replMount.commandBindings)
        XCTAssertEqual(legacyWorkflowMount.workflowMetadata, replMount.workflowMetadata)

        var legacyPlanningWorkflowObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(planningWorkflow)) as? [String: Any]
        )
        legacyPlanningWorkflowObject.removeValue(forKey: "workflowMetadata")
        let legacyPlanningWorkflowData = try JSONSerialization.data(
            withJSONObject: legacyPlanningWorkflowObject,
            options: [.sortedKeys]
        )
        let legacyPlanningWorkflow = try JSONDecoder().decode(
            SMLWorkflowRuntimePlanningWorkflow.self,
            from: legacyPlanningWorkflowData
        )
        XCTAssertEqual(legacyPlanningWorkflow.workflowMetadata, planningWorkflow.workflowMetadata)

        var legacyRouteObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(startRoute)) as? [String: Any]
        )
        legacyRouteObject.removeValue(forKey: "examples")
        let legacyRouteData = try JSONSerialization.data(
            withJSONObject: legacyRouteObject,
            options: [.sortedKeys]
        )
        let legacyRoute = try JSONDecoder().decode(
            SMLWorkflowRuntimeAPIMount.self,
            from: legacyRouteData
        )
        XCTAssertEqual(legacyRoute.examples, [])
    }

    func testRuntimeAgentGuideExportsModelREPLAPIOnyxAndPlanningInstructions() throws {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [
                makeAdmitted(),
                makeAdmitted(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        )

        let guide = registry.catalog.agentGuide

        XCTAssertEqual(guide.schemaVersion, SMLWorkflowRuntimeAgentGuide.currentSchemaVersion)
        XCTAssertEqual(guide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(guide.modelRouterTool.parameters.map(\.name), ["workflow_id", "line"])
        XCTAssertEqual(guide.workflowGuides.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(guide.metadataEndpoints.map(\.resource), [
            .agentGuide, .workflowAPIMount, .attachments, .workflowAttachment,
            .catalog, .export, .hostGuide, .hostWiring, .launch, .modelRouter,
            .workflowModelTool, .mount, .onyxDrivers, .workflowOnyxDriver,
            .openAPI, .planning, .workflowPlanning, .workflowREPLMount,
            .workflowSkillTree, .workflowToolBindings,
        ])
        XCTAssertTrue(guide.systemPrompt.contains("Break work into small contextual workflow steps"))
        XCTAssertTrue(guide.systemPrompt.contains("host_command_gateway"))
        XCTAssertTrue(guide.systemPrompt.contains(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertTrue(guide.systemPrompt.contains("content.release@1.0.0"))
        XCTAssertTrue(guide.systemPrompt.contains("Allowed REPL grammar:"))
        XCTAssertTrue(guide.systemPrompt.contains("start [TASK_ID] [JSON_INPUT_OBJECT]"))
        XCTAssertTrue(guide.systemPrompt.contains("Structured REPL commands:"))
        XCTAssertTrue(guide.systemPrompt.contains("json:workflow_input fields:target"))
        XCTAssertTrue(guide.systemPrompt.contains("REPL examples:"))
        XCTAssertTrue(guide.systemPrompt.contains(#"start TASK-ID {"target":"target"}"#))
        XCTAssertTrue(guide.systemPrompt.contains("API routes:"))
        XCTAssertTrue(
            guide.systemPrompt.contains(
                "POST /automation/workflows/content.release/tasks [host_command_gateway] body:start_task -> start_workflow_task_ContentRelease"
            )
        )
        XCTAssertTrue(
            guide.systemPrompt.contains(
                "GET /automation/workflows/content.release/tasks/{task_id} [host_command_gateway] body:none -> watch_workflow_task_ContentRelease"
            )
        )
        XCTAssertTrue(guide.systemPrompt.contains("workflow metadata:"))
        XCTAssertTrue(guide.systemPrompt.contains("attachment: GET /automation/runtime/attachments/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("repl mount: GET /automation/runtime/repl-mounts/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("api mount: GET /automation/runtime/api-mounts/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("model tool: GET /automation/runtime/model-tools/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("onyx driver: GET /automation/runtime/onyx-drivers/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("skill tree: GET /automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("tool bindings: GET /automation/runtime/tool-bindings/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("planning bundle: GET /automation/runtime/planning/content.release"))
        XCTAssertTrue(guide.systemPrompt.contains("Onyx driver"))
        XCTAssertTrue(guide.systemPrompt.contains("Skill tree:"))
        XCTAssertTrue(guide.systemPrompt.contains("plan:CALL_MODEL kind:reasoning"))
        XCTAssertTrue(guide.systemPrompt.contains("Planning units:"))
        XCTAssertTrue(guide.systemPrompt.contains("Command bindings:"))
        XCTAssertTrue(guide.systemPrompt.contains(#"start: repl="start [TASK_ID] [JSON_INPUT_OBJECT]""#))
        XCTAssertTrue(guide.systemPrompt.contains("api:POST /automation/workflows/content.release/tasks"))

        let release = try XCTUnwrap(
            guide.workflowGuides.first { $0.workflowID == "content.release" }
        )
        XCTAssertEqual(release.apiBasePath, "/automation")
        XCTAssertEqual(release.runtimeWorkflowAttachmentPath, "/automation/runtime/attachments/content.release")
        XCTAssertEqual(release.runtimeWorkflowOnyxDriverPath, "/automation/runtime/onyx-drivers/content.release")
        XCTAssertEqual(release.runtimeWorkflowSkillTreePath, "/automation/runtime/skill-trees/content.release")
        XCTAssertEqual(release.runtimeWorkflowToolBindingsPath, "/automation/runtime/tool-bindings/content.release")
        XCTAssertEqual(release.runtimeWorkflowPlanningPath, "/automation/runtime/planning/content.release")
        XCTAssertEqual(release.apiRoutes.count, 8)
        XCTAssertEqual(release.modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(release.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(release.model?.maximumCommandRounds, 4)
        XCTAssertEqual(
            Set(release.model?.allowedActions ?? []),
            SMLWorkflowSurface.modelDefaultActions
        )
        XCTAssertEqual(release.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(
            release.replCommands.first { $0.verb == "start" }?.jsonBodyKind,
            .workflowInput
        )
        XCTAssertEqual(
            release.replCommands.first { $0.verb == "start" }?.jsonFields.map(\.name),
            ["target"]
        )
        XCTAssertEqual(
            release.replCommands.first { $0.verb == "approve" }?.jsonBodyKind,
            .expectedState
        )
        XCTAssertTrue(release.replExamples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertEqual(release.skillIndex.count, 7)
        let releaseSkill = try XCTUnwrap(release.skillIndex.first {
            $0.instructionID == "plan"
        })
        XCTAssertEqual(releaseSkill.kind, .reasoning)
        XCTAssertEqual(releaseSkill.unitKind, .modelReasoning)
        XCTAssertEqual(releaseSkill.reference, "content.plan")
        XCTAssertEqual(releaseSkill.successors, ["write"])
        XCTAssertEqual(releaseSkill.outputSchema, "content.plan.v1")
        XCTAssertEqual(release.planningToolIndex.map(\.reference), [
            "content.plan", "artifact_verified", "repository.write",
        ])
        XCTAssertEqual(release.approvalGates.map(\.instructionID), ["approval"])
        XCTAssertTrue(release.decomposableUnits.isEmpty)
        XCTAssertEqual(release.commandBindings.count, 8)
        let releaseStartCommandBinding = try XCTUnwrap(release.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(releaseStartCommandBinding.replJSONFields.map(\.name), ["target"])
        XCTAssertEqual(releaseStartCommandBinding.apiBodyFields.map(\.name), ["target"])
        XCTAssertEqual(
            releaseStartCommandBinding.apiPathTemplate,
            "/automation/workflows/content.release/tasks"
        )
        XCTAssertTrue(releaseStartCommandBinding.modelEligible)
        XCTAssertFalse(release.onyxDriverID.isEmpty)
        let legacyAgentWorkflowData = try JSONEncoder().encode(release)
        var legacyAgentWorkflowObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyAgentWorkflowData) as? [String: Any]
        )
        legacyAgentWorkflowObject.removeValue(forKey: "runtimeWorkflowAttachmentPath")
        legacyAgentWorkflowObject.removeValue(forKey: "runtimeWorkflowOnyxDriverPath")
        legacyAgentWorkflowObject.removeValue(forKey: "runtimeWorkflowSkillTreePath")
        legacyAgentWorkflowObject.removeValue(forKey: "runtimeWorkflowToolBindingsPath")
        legacyAgentWorkflowObject.removeValue(forKey: "runtimeWorkflowPlanningPath")
        let legacyAgentWorkflow = try JSONDecoder().decode(
            SMLWorkflowRuntimeWorkflowAgentGuide.self,
            from: JSONSerialization.data(withJSONObject: legacyAgentWorkflowObject, options: [.sortedKeys])
        )
        XCTAssertEqual(
            legacyAgentWorkflow.runtimeWorkflowAttachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            legacyAgentWorkflow.runtimeWorkflowOnyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            legacyAgentWorkflow.runtimeWorkflowSkillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            legacyAgentWorkflow.runtimeWorkflowToolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertEqual(
            legacyAgentWorkflow.runtimeWorkflowPlanningPath,
            "/automation/runtime/planning/content.release"
        )

        let encoded = String(decoding: try JSONEncoder().encode(guide), as: UTF8.self)
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
        XCTAssertTrue(encoded.contains("\"replCommands\""))
        XCTAssertTrue(encoded.contains("\"replExamples\""))
        XCTAssertTrue(encoded.contains("\"skillIndex\""))
        XCTAssertTrue(encoded.contains("\"commandBindings\""))

        let encodedData = try JSONEncoder().encode(guide)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        )
        legacyObject["schemaVersion"] = 1
        var legacyWorkflowGuides = try XCTUnwrap(
            legacyObject["workflowGuides"] as? [[String: Any]]
        )
        for index in legacyWorkflowGuides.indices {
            legacyWorkflowGuides[index].removeValue(forKey: "replCommands")
            legacyWorkflowGuides[index].removeValue(forKey: "replExamples")
            legacyWorkflowGuides[index].removeValue(forKey: "skillIndex")
            legacyWorkflowGuides[index].removeValue(forKey: "model")
            legacyWorkflowGuides[index].removeValue(forKey: "commandBindings")
        }
        legacyObject["workflowGuides"] = legacyWorkflowGuides
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        let legacyGuide = try JSONDecoder().decode(SMLWorkflowRuntimeAgentGuide.self, from: legacyData)
        XCTAssertEqual(legacyGuide.schemaVersion, 1)
        XCTAssertEqual(legacyGuide.workflowGuides.map(\.replCommands), [[], []])
        XCTAssertEqual(legacyGuide.workflowGuides.map(\.replExamples), [[], []])
        XCTAssertEqual(legacyGuide.workflowGuides.map(\.skillIndex), [[], []])
        XCTAssertTrue(legacyGuide.workflowGuides.allSatisfy { $0.model == nil })
        XCTAssertEqual(legacyGuide.workflowGuides.map(\.commandBindings), [[], []])
    }

    func testRuntimeHostGuideExportsLaunchBindingsWithoutAuthority() throws {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [
                makeAdmitted(),
                makeAdmitted(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        )

        let guide = registry.catalog.hostGuide

        XCTAssertEqual(guide.schemaVersion, SMLWorkflowRuntimeHostGuide.currentSchemaVersion)
        XCTAssertEqual(guide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(guide.workflowBindings.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(guide.requiredHostServices, [
            "bounded_source_decoder",
            "fresh_admission_catalog",
            "sml_runtime_store",
            "sml_command_replay_guard",
            "authority_resolver",
            "host_command_gateway",
            "provider_registry_for_model_router",
            "transport_router_for_repl_and_api",
        ])
        XCTAssertEqual(guide.launchSteps.map(\.id), [
            "decode_source_package",
            "fresh_host_admission",
            "launch_runtime_app",
            "serve_descriptor_metadata",
            "route_repl_and_api",
            "attach_model_router",
            "attach_onyx_and_planning",
        ])
        XCTAssertTrue(
            guide.launchSteps.contains {
                $0.entrypoint.contains("SMLWorkflowRuntimeApp.launch(package:")
                    && $0.authority == .hostCommandGateway
            }
        )
        XCTAssertEqual(
            guide.metadataEndpoints.map(\.resource),
            [
                .agentGuide, .workflowAPIMount, .attachments, .workflowAttachment,
                .catalog, .export, .hostGuide, .hostWiring, .launch, .modelRouter,
                .workflowModelTool, .mount, .onyxDrivers, .workflowOnyxDriver,
                .openAPI, .planning, .workflowPlanning, .workflowREPLMount,
                .workflowSkillTree, .workflowToolBindings,
            ]
        )
        XCTAssertEqual(guide.hostBindingCount, 18)

        let release = try XCTUnwrap(
            guide.workflowBindings.first { $0.workflowID == "content.release" }
        )
        XCTAssertEqual(release.apiBasePath, "/automation")
        XCTAssertEqual(release.replMount.workflowID, "content.release")
        XCTAssertEqual(
            release.replMount.commands.first { $0.verb == "start" }?.jsonBodyKind,
            .workflowInput
        )
        XCTAssertTrue(release.replMount.examples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertEqual(release.apiRoutes.count, 8)
        XCTAssertEqual(release.modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(release.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(release.model?.maximumCommandRounds, 4)
        XCTAssertEqual(
            Set(release.model?.allowedActions ?? []),
            SMLWorkflowSurface.modelDefaultActions
        )
        XCTAssertEqual(release.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(release.planningWorkflowID, "content.release")
        XCTAssertEqual(release.plannerEntrypoint, "plan")
        XCTAssertEqual(release.toolReferences, [
            "artifact_verified", "content.plan", "repository.write",
        ])
        XCTAssertEqual(release.skillIndex.count, 7)
        XCTAssertEqual(
            release.skillIndex.first { $0.instructionID == "plan" }?.reference,
            "content.plan"
        )
        XCTAssertEqual(release.approvalGates.map(\.instructionID), ["approval"])
        XCTAssertEqual(release.commandBindings.count, 8)
        let releaseStartCommand = try XCTUnwrap(release.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(releaseStartCommand.replJSONFields.map(\.name), ["target"])
        XCTAssertEqual(releaseStartCommand.apiBodyFields.map(\.name), ["target"])
        XCTAssertEqual(
            releaseStartCommand.apiPathTemplate,
            "/automation/workflows/content.release/tasks"
        )
        XCTAssertTrue(releaseStartCommand.modelEligible)
        XCTAssertEqual(
            Set(release.hostBindings.map(\.channel)),
            [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
            ]
        )
        let apiBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .customAPI }
        )
        XCTAssertEqual(apiBinding.authority, .hostCommandGateway)
        XCTAssertFalse(apiBinding.readOnly)
        XCTAssertTrue(apiBinding.pathTemplates.contains("/automation/workflows/content.release/tasks"))
        XCTAssertTrue(apiBinding.pathTemplates.contains("/automation/runtime/api-mounts/content.release"))
        XCTAssertTrue(apiBinding.apiExamples.contains {
            $0.method == .post
                && $0.path == "/automation/workflows/content.release/tasks"
                && $0.body["input"] == .object(["target": .string("target")])
        })
        XCTAssertTrue(apiBinding.apiExamples.contains {
            $0.method == .get
                && $0.path == "/automation/runtime/api-mounts/content.release"
        })
        let replBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .customREPL }
        )
        XCTAssertTrue(replBinding.pathTemplates.contains("/automation/runtime/repl-mounts/content.release"))
        XCTAssertTrue(replBinding.replExamples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertTrue(replBinding.apiExamples.contains {
            $0.method == .get
                && $0.path == "/automation/runtime/repl-mounts/content.release"
        })
        let modelToolBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .modelTool }
        )
        XCTAssertTrue(modelToolBinding.pathTemplates.contains("/automation/runtime/model-tools/content.release"))
        XCTAssertTrue(modelToolBinding.apiExamples.contains {
            $0.method == .get
                && $0.path == "/automation/runtime/model-tools/content.release"
        })
        XCTAssertTrue(modelToolBinding.modelToolExamples.contains {
            $0.toolName == SMLWorkflowModelAdapter.toolName
                && $0.workflowID == nil
                && $0.arguments == ["line": .string(#"start TASK-ID {"target":"target"}"#)]
        })
        let modelRouterBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .modelRouter }
        )
        XCTAssertTrue(modelRouterBinding.modelToolExamples.contains {
            $0.toolName == SMLWorkflowRuntimeModelAdapter.toolName
                && $0.workflowID == "content.release"
                && $0.arguments == [
                    "workflow_id": .string("content.release"),
                    "line": .string(#"start TASK-ID {"target":"target"}"#),
                ]
        })
        let onyxBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .onyxDriver }
        )
        XCTAssertEqual(onyxBinding.authority, .descriptorOnly)
        XCTAssertTrue(onyxBinding.readOnly)
        XCTAssertEqual(onyxBinding.driverID, release.onyxDriverID)
        XCTAssertTrue(onyxBinding.pathTemplates.contains("/automation/runtime/onyx-drivers/content.release"))
        XCTAssertTrue(onyxBinding.apiExamples.contains {
            $0.path == "/automation/runtime/onyx-drivers/content.release"
        })
        let planningBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .planningWorkflow }
        )
        XCTAssertTrue(planningBinding.pathTemplates.contains("/automation/runtime/planning/content.release"))
        XCTAssertTrue(planningBinding.apiExamples.contains {
            $0.path == "/automation/runtime/planning/content.release"
        })
        let skillTreeBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .skillTree }
        )
        XCTAssertEqual(skillTreeBinding.authority, .descriptorOnly)
        XCTAssertTrue(skillTreeBinding.readOnly)
        XCTAssertTrue(skillTreeBinding.pathTemplates.contains("/automation/runtime/skill-trees/content.release"))
        XCTAssertTrue(skillTreeBinding.apiExamples.contains {
            $0.path == "/automation/runtime/skill-trees/content.release"
        })
        let toolBindingsBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .toolBindings }
        )
        XCTAssertEqual(toolBindingsBinding.authority, .descriptorOnly)
        XCTAssertTrue(toolBindingsBinding.readOnly)
        XCTAssertTrue(toolBindingsBinding.pathTemplates.contains("/automation/runtime/tool-bindings/content.release"))
        XCTAssertTrue(toolBindingsBinding.apiExamples.contains {
            $0.path == "/automation/runtime/tool-bindings/content.release"
        })

        let encoded = String(decoding: try JSONEncoder().encode(guide), as: UTF8.self)
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
        XCTAssertFalse(encoded.contains("authenticatedActor"))

        let encodedData = try JSONEncoder().encode(guide)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedData) as? [String: Any]
        )
        legacyObject["schemaVersion"] = 3
        var legacyWorkflowBindings = try XCTUnwrap(
            legacyObject["workflowBindings"] as? [[String: Any]]
        )
        for workflowIndex in legacyWorkflowBindings.indices {
            var hostBindings = try XCTUnwrap(
                legacyWorkflowBindings[workflowIndex]["hostBindings"] as? [[String: Any]]
            )
            legacyWorkflowBindings[workflowIndex].removeValue(forKey: "skillIndex")
            legacyWorkflowBindings[workflowIndex].removeValue(forKey: "model")
            legacyWorkflowBindings[workflowIndex].removeValue(forKey: "commandBindings")
            for bindingIndex in hostBindings.indices {
                hostBindings[bindingIndex].removeValue(forKey: "replExamples")
                hostBindings[bindingIndex].removeValue(forKey: "apiExamples")
                hostBindings[bindingIndex].removeValue(forKey: "modelToolExamples")
            }
            legacyWorkflowBindings[workflowIndex]["hostBindings"] = hostBindings
        }
        legacyObject["workflowBindings"] = legacyWorkflowBindings
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        let legacyGuide = try JSONDecoder().decode(SMLWorkflowRuntimeHostGuide.self, from: legacyData)
        XCTAssertEqual(legacyGuide.schemaVersion, 3)
        XCTAssertTrue(legacyGuide.workflowBindings.allSatisfy { workflow in
            workflow.skillIndex.isEmpty
                && workflow.model == nil
                && workflow.commandBindings.isEmpty
                && workflow.hostBindings.allSatisfy {
                $0.replExamples.isEmpty
                    && $0.apiExamples.isEmpty
                    && $0.modelToolExamples.isEmpty
            }
        })
    }

    func testRuntimeExportContainsOpenAPIModelToolsAndOnyxDriversWithoutAuthority() throws {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [
                makeAdmitted(),
                makeAdmitted(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        )

        let export = registry.export(title: "Automation", version: "2026.08")

        XCTAssertEqual(export.schemaVersion, SMLWorkflowRuntimeExport.currentSchemaVersion)
        XCTAssertEqual(export.catalog.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.mountContract.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.mountContract.apiBasePaths, ["/automation"])
        XCTAssertEqual(export.mountContract.replMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.mountContract.replMounts.map(\.modelRouterToolName), [
            SMLWorkflowRuntimeModelAdapter.toolName,
            SMLWorkflowRuntimeModelAdapter.toolName,
        ])
        let releaseReplMount = try XCTUnwrap(
            export.mountContract.replMounts.first { $0.workflowID == "content.release" }
        )
        XCTAssertEqual(
            releaseReplMount.commands.first { $0.verb == "start" }?.jsonFields.map(\.name),
            ["target"]
        )
        XCTAssertTrue(releaseReplMount.examples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertEqual(releaseReplMount.commandBindings.count, 8)
        XCTAssertEqual(
            releaseReplMount.commandBindings.first { $0.action == .start }?.apiPathTemplate,
            "/automation/workflows/content.release/tasks"
        )
        XCTAssertEqual(export.mountContract.apiRoutes.count, 36)
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.apiRoutes.count), [8, 8])
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.commandBindings.count), [8, 8])
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.modelToolName), [
            SMLWorkflowModelAdapter.toolName,
            SMLWorkflowModelAdapter.toolName,
        ])
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.modelRouterToolName), [
            SMLWorkflowRuntimeModelAdapter.toolName,
            SMLWorkflowRuntimeModelAdapter.toolName,
        ])
        XCTAssertEqual(
            export.mountContract.workflowMounts.map(\.onyxDriverID),
            export.onyxDrivers.map(\.driverID).sorted()
        )
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.planningWorkflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.mountContract.modelRouter.workflowIDs, [
            "content.release", "content.review",
        ])
        XCTAssertEqual(
            export.mountContract.onyxDriverIDs,
            export.onyxDrivers.map(\.driverID).sorted()
        )
        XCTAssertEqual(export.mountContract.planningWorkflowIDs, [
            "content.release", "content.review",
        ])
        let mountMetadataRoute = try XCTUnwrap(
            export.mountContract.apiRoutes.first { $0.metadataResource == .mount }
        )
        XCTAssertEqual(mountMetadataRoute.method, .get)
        XCTAssertEqual(mountMetadataRoute.pathTemplate, "/automation/runtime/mount")
        XCTAssertEqual(mountMetadataRoute.handlerKind, .metadata)
        XCTAssertEqual(mountMetadataRoute.authority, .descriptorOnly)
        XCTAssertTrue(mountMetadataRoute.readOnly)
        XCTAssertNil(mountMetadataRoute.workflowID)
        XCTAssertNil(mountMetadataRoute.action)
        XCTAssertEqual(mountMetadataRoute.bodyKind, .none)
        XCTAssertEqual(mountMetadataRoute.bodyFields, [])
        let startMountRoute = try XCTUnwrap(
            export.mountContract.apiRoutes.first {
                $0.workflowID == "content.release" && $0.action == .start
            }
        )
        XCTAssertEqual(startMountRoute.pathTemplate, "/automation/workflows/content.release/tasks")
        XCTAssertEqual(startMountRoute.operationID, "start_workflow_task_ContentRelease")
        XCTAssertEqual(startMountRoute.handlerKind, .workflow)
        XCTAssertEqual(startMountRoute.authority, .hostCommandGateway)
        XCTAssertFalse(startMountRoute.readOnly)
        XCTAssertNil(startMountRoute.metadataResource)
        XCTAssertEqual(startMountRoute.bodyKind, .startTask)
        XCTAssertEqual(startMountRoute.bodyFields.map(\.name), ["target"])
        let describeMountRoute = try XCTUnwrap(
            export.mountContract.apiRoutes.first {
                $0.workflowID == "content.release" && $0.action == .describe
            }
        )
        XCTAssertTrue(describeMountRoute.readOnly)
        XCTAssertEqual(describeMountRoute.operationID, "describe_workflow_ContentRelease")
        XCTAssertEqual(describeMountRoute.bodyKind, .none)
        let mountOperationIDs = export.mountContract.apiRoutes.map(\.operationID)
        XCTAssertEqual(Set(mountOperationIDs).count, mountOperationIDs.count)
        XCTAssertEqual(export.modelTools.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(export.modelTools.map(\.tool.name), [
            SMLWorkflowModelAdapter.toolName,
            SMLWorkflowModelAdapter.toolName,
        ])
        let releaseModelTool = try XCTUnwrap(export.modelTools.first {
            $0.workflowID == "content.release"
        })
        XCTAssertEqual(
            releaseModelTool.workflowMetadata.attachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            releaseModelTool.workflowMetadata.replMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            releaseModelTool.workflowMetadata.apiMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            releaseModelTool.workflowMetadata.modelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            releaseModelTool.workflowMetadata.skillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            releaseModelTool.workflowMetadata.toolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertTrue(export.modelRouter.requiresNativeTools)
        XCTAssertEqual(export.modelRouter.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.modelRouter.tool.parameters.map(\.name), ["workflow_id", "line"])
        let releaseRouterMetadata = try XCTUnwrap(export.modelRouter.workflowMetadata.first {
            $0.workflowID == "content.release"
        })
        XCTAssertEqual(
            releaseRouterMetadata.attachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            releaseRouterMetadata.replMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            releaseRouterMetadata.apiMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            releaseRouterMetadata.modelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            releaseRouterMetadata.onyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            releaseRouterMetadata.skillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            releaseRouterMetadata.toolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertEqual(
            releaseRouterMetadata.planningBundlePath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertEqual(export.modelRouter.maximumCommandRounds, 4)
        XCTAssertTrue(export.modelRouter.examples.contains {
            $0.workflowID == "content.release"
                && $0.arguments == [
                    "workflow_id": .string("content.release"),
                    "line": .string(#"start TASK-ID {"target":"target"}"#),
                ]
        })
        XCTAssertTrue(export.mountContract.modelRouter.examples.contains {
            $0.workflowID == "content.release"
                && $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertEqual(export.onyxDrivers.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(export.catalog.onyxDrivers, export.onyxDrivers)
        let releaseOnyxDriver = try XCTUnwrap(export.onyxDrivers.first {
            $0.workflowID == "content.release"
        })
        XCTAssertEqual(releaseOnyxDriver.commandBindings.count, 8)
        XCTAssertEqual(
            releaseOnyxDriver.commandBindings,
            export.planning.commandBindings.filter { $0.workflowID == "content.release" }
        )
        XCTAssertEqual(export.planning.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.planning.workflows.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(export.planning.workflows.map(\.entrypoint), ["plan", "plan"])
        XCTAssertEqual(export.planning.skillIndex.count, 14)
        let releaseSkillIndex = export.planning.skillIndex.filter {
            $0.workflowID == "content.release"
        }
        XCTAssertEqual(releaseSkillIndex.map(\.instructionID), [
            "approval", "escalate", "plan", "receipt", "rollback", "verify", "write",
        ])
        let releasePlanningSkill = try XCTUnwrap(releaseSkillIndex.first {
            $0.instructionID == "plan"
        })
        XCTAssertEqual(releasePlanningSkill.kind, .reasoning)
        XCTAssertEqual(releasePlanningSkill.unitKind, .modelReasoning)
        XCTAssertEqual(releasePlanningSkill.reference, "content.plan")
        XCTAssertEqual(releasePlanningSkill.successors, ["write"])
        XCTAssertEqual(releasePlanningSkill.outputSchema, "content.plan.v1")
        XCTAssertFalse(releasePlanningSkill.canDecomposeFurther)
        let releaseApprovalSkill = try XCTUnwrap(releaseSkillIndex.first {
            $0.instructionID == "approval"
        })
        XCTAssertEqual(releaseApprovalSkill.unitKind, .approvalGate)
        XCTAssertTrue(releaseApprovalSkill.requiresApproval)
        XCTAssertFalse(releaseApprovalSkill.terminal)
        XCTAssertEqual(export.planning.toolIndex.count, 6)
        XCTAssertEqual(export.planning.decomposableUnits, [])
        XCTAssertEqual(
            export.planning.approvalGates.map { "\($0.workflowID):\($0.instructionID)" },
            ["content.release:approval", "content.review:approval"]
        )
        XCTAssertEqual(export.agentGuide.workflowGuides.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.agentGuide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.hostGuide.workflowBindings.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.hostGuide.hostBindingCount, 18)
        XCTAssertEqual(export.hostWiring.schemaVersion, SMLWorkflowRuntimeHostWiring.currentSchemaVersion)
        XCTAssertEqual(export.hostWiring.apiBasePaths, ["/automation"])
        XCTAssertEqual(export.hostWiring.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.hostWiring.modelRouter.workflowIDs, [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.hostWiring.onyxDriverIDs, export.mountContract.onyxDriverIDs)
        XCTAssertEqual(export.hostWiring.planningWorkflowIDs, [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.hostWiring.workflows.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.hostWiring.hostBindingCount, 18)
        XCTAssertEqual(export.hostWiring.workflows.map(\.apiRoutes.count), [8, 8])
        XCTAssertEqual(export.hostWiring.workflows.map(\.modelRouterToolName), [
            SMLWorkflowRuntimeModelAdapter.toolName,
            SMLWorkflowRuntimeModelAdapter.toolName,
        ])
        XCTAssertEqual(
            export.hostWiring.workflows.compactMap { $0.model?.tool.name },
            [SMLWorkflowModelAdapter.toolName, SMLWorkflowModelAdapter.toolName]
        )
        XCTAssertTrue(export.hostWiring.workflows.allSatisfy {
            Set($0.hostBindings.map(\.channel)) == [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
            ]
        })
        let releaseWiring = try XCTUnwrap(
            export.hostWiring.workflows.first { $0.workflowID == "content.release" }
        )
        XCTAssertTrue(releaseWiring.hostBindings.contains {
            $0.channel == .customREPL
                && $0.pathTemplates.contains("/automation/runtime/repl-mounts/content.release")
                && $0.replExamples.contains { $0.line == #"start TASK-ID {"target":"target"}"# }
        })
        XCTAssertTrue(releaseWiring.hostBindings.contains {
            $0.channel == .customAPI
                && $0.pathTemplates.contains("/automation/runtime/api-mounts/content.release")
                && $0.apiExamples.contains {
                    $0.path == "/automation/workflows/content.release/tasks"
                        && $0.body["input"] == .object(["target": .string("target")])
                }
        })
        XCTAssertTrue(releaseWiring.hostBindings.contains {
            $0.channel == .modelTool
                && $0.pathTemplates.contains("/automation/runtime/model-tools/content.release")
                && $0.apiExamples.contains {
                    $0.path == "/automation/runtime/model-tools/content.release"
                }
        })
        XCTAssertTrue(releaseWiring.hostBindings.contains {
            $0.channel == .modelRouter
                && $0.modelToolExamples.contains {
                    $0.arguments == [
                        "workflow_id": .string("content.release"),
                        "line": .string(#"start TASK-ID {"target":"target"}"#),
                    ]
                }
        })
        XCTAssertEqual(releaseWiring.commandBindings.count, 8)
        XCTAssertEqual(releaseWiring.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(releaseWiring.model?.maximumCommandRounds, 4)
        XCTAssertEqual(
            Set(releaseWiring.model?.allowedActions ?? []),
            SMLWorkflowSurface.modelDefaultActions
        )
        XCTAssertEqual(releaseWiring.skillIndex.count, 7)
        XCTAssertEqual(
            releaseWiring.skillIndex.first { $0.instructionID == "plan" }?.reference,
            "content.plan"
        )
        XCTAssertEqual(releaseWiring.workflowMetadata, releaseWiring.replMount.workflowMetadata)
        XCTAssertEqual(
            releaseWiring.workflowMetadata.planningBundlePath,
            "/automation/runtime/planning/content.release"
        )
        let releaseStartBinding = try XCTUnwrap(releaseWiring.commandBindings.first {
            $0.action == .start
        })
        XCTAssertEqual(releaseStartBinding.replVerb, "start")
        XCTAssertEqual(releaseStartBinding.replLineTemplate, "start [TASK_ID] [JSON_INPUT_OBJECT]")
        XCTAssertEqual(releaseStartBinding.apiPathTemplate, "/automation/workflows/content.release/tasks")
        XCTAssertEqual(releaseStartBinding.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertTrue(releaseStartBinding.modelEligible)
        XCTAssertEqual(releaseStartBinding.exampleModelRouterArguments, [
            "workflow_id": .string("content.release"),
            "line": .string(#"start TASK-ID {"target":"target"}"#),
        ])
        let releaseAttachment = releaseWiring.attachment
        XCTAssertEqual(releaseAttachment.workflowID, "content.release")
        XCTAssertEqual(releaseAttachment.workflowVersion, "1.0.0")
        XCTAssertEqual(releaseAttachment.workflowName, "Content release")
        XCTAssertEqual(releaseAttachment.sourceReference, "graphs/content_release.py")
        XCTAssertEqual(releaseAttachment.apiBasePath, "/automation")
        XCTAssertEqual(releaseAttachment.runtimeAttachmentsPath, "/automation/runtime/attachments")
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowAttachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowREPLMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowAPIMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowModelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowOnyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowSkillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowToolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertEqual(
            releaseAttachment.runtimeWorkflowPlanningPath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertEqual(releaseAttachment.workflowMetadata, releaseWiring.workflowMetadata)
        XCTAssertEqual(
            releaseAttachment.workflowMetadata.attachmentPath,
            releaseAttachment.runtimeWorkflowAttachmentPath
        )
        XCTAssertEqual(
            releaseAttachment.workflowMetadata.modelToolPath,
            releaseAttachment.runtimeWorkflowModelToolPath
        )
        XCTAssertEqual(
            releaseAttachment.workflowMetadata.planningBundlePath,
            releaseAttachment.runtimeWorkflowPlanningPath
        )
        XCTAssertEqual(releaseAttachment.plannerEntrypoint, "plan")
        XCTAssertEqual(releaseAttachment.channels, [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
        ])
        XCTAssertTrue(releaseAttachment.replExamples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
        })
        XCTAssertTrue(releaseAttachment.apiExamples.contains {
            $0.path == "/automation/workflows/content.release/tasks"
                && $0.body["input"] == .object(["target": .string("target")])
        })
        XCTAssertTrue(releaseAttachment.modelRouterExamples.contains {
            $0.toolName == SMLWorkflowRuntimeModelAdapter.toolName
                && $0.workflowID == "content.release"
                && $0.arguments == [
                    "workflow_id": .string("content.release"),
                    "line": .string(#"start TASK-ID {"target":"target"}"#),
                ]
        })
        XCTAssertEqual(releaseAttachment.commandBindings, releaseWiring.commandBindings)
        XCTAssertEqual(releaseAttachment.model, releaseWiring.model)
        XCTAssertEqual(releaseAttachment.skillIndex, releaseWiring.skillIndex)
        XCTAssertEqual(releaseAttachment.onyxDriverID, releaseWiring.onyxDriverID)
        XCTAssertEqual(releaseAttachment.planningWorkflowID, "content.release")
        let legacyRuntimeAttachmentData = try JSONEncoder().encode(releaseAttachment)
        var legacyRuntimeAttachmentObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: legacyRuntimeAttachmentData) as? [String: Any]
        )
        legacyRuntimeAttachmentObject.removeValue(forKey: "workflowMetadata")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeAttachmentsPath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowAttachmentPath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowREPLMountPath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowAPIMountPath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowModelToolPath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowOnyxDriverPath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowSkillTreePath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowToolBindingsPath")
        legacyRuntimeAttachmentObject.removeValue(forKey: "runtimeWorkflowPlanningPath")
        let legacyRuntimeAttachmentDecoded = try JSONDecoder().decode(
            SMLWorkflowRuntimeWorkflowAttachmentManifest.self,
            from: JSONSerialization.data(withJSONObject: legacyRuntimeAttachmentObject, options: [.sortedKeys])
        )
        XCTAssertEqual(legacyRuntimeAttachmentDecoded.runtimeAttachmentsPath, "/automation/runtime/attachments")
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowAttachmentPath,
            "/automation/runtime/attachments/content.release"
        )
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowREPLMountPath,
            "/automation/runtime/repl-mounts/content.release"
        )
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowAPIMountPath,
            "/automation/runtime/api-mounts/content.release"
        )
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowModelToolPath,
            "/automation/runtime/model-tools/content.release"
        )
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowOnyxDriverPath,
            "/automation/runtime/onyx-drivers/content.release"
        )
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowSkillTreePath,
            "/automation/runtime/skill-trees/content.release"
        )
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowToolBindingsPath,
            "/automation/runtime/tool-bindings/content.release"
        )
        XCTAssertEqual(
            legacyRuntimeAttachmentDecoded.runtimeWorkflowPlanningPath,
            "/automation/runtime/planning/content.release"
        )
        XCTAssertEqual(legacyRuntimeAttachmentDecoded.workflowMetadata, releaseAttachment.workflowMetadata)
        XCTAssertEqual(releaseAttachment.toolReferences, [
            "artifact_verified", "content.plan", "repository.write",
        ])

        let info = try object(export.openAPI["info"])
        XCTAssertEqual(info["title"], .string("Automation"))
        XCTAssertEqual(info["version"], .string("2026.08"))

        let paths = try object(export.openAPI["paths"])
        let runtimeMountPath = try object(paths["/automation/runtime/mount"])
        let runtimeMount = try object(runtimeMountPath["get"])
        XCTAssertEqual(
            runtimeMount["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.mount.operationID)
        )
        XCTAssertEqual(runtimeMount["x-sml-runtime-resource"], .string("mount"))
        let runtimeLaunchPath = try object(paths["/automation/runtime/launch"])
        let runtimeLaunch = try object(runtimeLaunchPath["get"])
        XCTAssertEqual(
            runtimeLaunch["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.launch.operationID)
        )
        XCTAssertEqual(runtimeLaunch["x-sml-runtime-resource"], .string("launch"))
        XCTAssertEqual(runtimeLaunch["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimeLaunch["x-sml-authority"], .string("descriptor-only"))
        let runtimePlanningPath = try object(paths["/automation/runtime/planning"])
        let runtimePlanning = try object(runtimePlanningPath["get"])
        XCTAssertEqual(
            runtimePlanning["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.planning.operationID)
        )
        XCTAssertEqual(runtimePlanning["x-sml-runtime-resource"], .string("planning"))
        XCTAssertEqual(runtimePlanning["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimePlanning["x-sml-authority"], .string("descriptor-only"))
        XCTAssertNil(runtimePlanning["x-sml-command-binding"])
        let runtimeAgentGuidePath = try object(paths["/automation/runtime/agent-guide"])
        let runtimeAgentGuide = try object(runtimeAgentGuidePath["get"])
        XCTAssertEqual(
            runtimeAgentGuide["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.agentGuide.operationID)
        )
        XCTAssertEqual(runtimeAgentGuide["x-sml-runtime-resource"], .string("agent-guide"))
        XCTAssertEqual(runtimeAgentGuide["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimeAgentGuide["x-sml-authority"], .string("descriptor-only"))
        let runtimeHostGuidePath = try object(paths["/automation/runtime/host-guide"])
        let runtimeHostGuide = try object(runtimeHostGuidePath["get"])
        XCTAssertEqual(
            runtimeHostGuide["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.hostGuide.operationID)
        )
        XCTAssertEqual(runtimeHostGuide["x-sml-runtime-resource"], .string("host-guide"))
        XCTAssertEqual(runtimeHostGuide["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimeHostGuide["x-sml-authority"], .string("descriptor-only"))
        let runtimeHostWiringPath = try object(paths["/automation/runtime/host-wiring"])
        let runtimeHostWiring = try object(runtimeHostWiringPath["get"])
        XCTAssertEqual(
            runtimeHostWiring["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.hostWiring.operationID)
        )
        XCTAssertEqual(runtimeHostWiring["x-sml-runtime-resource"], .string("host-wiring"))
        XCTAssertEqual(runtimeHostWiring["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimeHostWiring["x-sml-authority"], .string("descriptor-only"))
        let runtimeAttachmentsPath = try object(paths["/automation/runtime/attachments"])
        let runtimeAttachments = try object(runtimeAttachmentsPath["get"])
        XCTAssertEqual(
            runtimeAttachments["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.attachments.operationID)
        )
        XCTAssertEqual(runtimeAttachments["x-sml-runtime-resource"], .string("attachments"))
        XCTAssertEqual(runtimeAttachments["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimeAttachments["x-sml-authority"], .string("descriptor-only"))
        let runtimeWorkflowAttachmentPath = try object(
            paths["/automation/runtime/attachments/{workflow_id}"]
        )
        let runtimeWorkflowAttachment = try object(runtimeWorkflowAttachmentPath["get"])
        XCTAssertEqual(
            runtimeWorkflowAttachment["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.workflowAttachment.operationID)
        )
        XCTAssertEqual(
            runtimeWorkflowAttachment["x-sml-runtime-resource"],
            .string("workflow-attachment")
        )
        XCTAssertEqual(runtimeWorkflowAttachment["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimeWorkflowAttachment["x-sml-authority"], .string("descriptor-only"))
        let workflowAttachmentParameter = try object(
            try array(runtimeWorkflowAttachment["parameters"]).first
        )
        XCTAssertEqual(workflowAttachmentParameter["name"], .string("workflow_id"))
        XCTAssertEqual(workflowAttachmentParameter["in"], .string("path"))

        let workflowMetadataOperationChecks: [(String, SMLWorkflowRuntimeMetadataResource)] = [
            ("/automation/runtime/repl-mounts/{workflow_id}", .workflowREPLMount),
            ("/automation/runtime/api-mounts/{workflow_id}", .workflowAPIMount),
            ("/automation/runtime/model-tools/{workflow_id}", .workflowModelTool),
        ]
        for (pathTemplate, resource) in workflowMetadataOperationChecks {
            let path = try object(paths[pathTemplate])
            let operation = try object(path["get"])
            XCTAssertEqual(operation["operationId"], .string(resource.operationID))
            XCTAssertEqual(operation["x-sml-runtime-resource"], .string(resource.rawValue))
            XCTAssertEqual(operation["x-sml-read-only"], .bool(true))
            XCTAssertEqual(operation["x-sml-authority"], .string("descriptor-only"))
            let parameter = try object(try array(operation["parameters"]).first)
            XCTAssertEqual(parameter["name"], .string("workflow_id"))
            XCTAssertEqual(parameter["in"], .string("path"))
        }

        let releasePath = try object(paths["/automation/workflows/content.release"])
        let describe = try object(releasePath["get"])
        XCTAssertEqual(describe["operationId"], .string("describe_workflow_ContentRelease"))
        XCTAssertEqual(describe["x-sml-workflow-id"], .string("content.release"))
        XCTAssertEqual(describe["x-sml-model-tool"], .string(SMLWorkflowModelAdapter.toolName))
        XCTAssertEqual(
            describe["x-sml-model-router-tool"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        XCTAssertNotNil(describe["x-sml-onyx-driver-id"])
        let describeMetadata = try object(describe["x-sml-workflow-runtime-metadata"])
        XCTAssertEqual(
            describeMetadata["attachment"],
            .string("/automation/runtime/attachments/content.release")
        )
        XCTAssertEqual(
            describeMetadata["replMount"],
            .string("/automation/runtime/repl-mounts/content.release")
        )
        XCTAssertEqual(
            describeMetadata["apiMount"],
            .string("/automation/runtime/api-mounts/content.release")
        )
        XCTAssertEqual(
            describeMetadata["modelTool"],
            .string("/automation/runtime/model-tools/content.release")
        )
        XCTAssertEqual(
            describeMetadata["onyxDriver"],
            .string("/automation/runtime/onyx-drivers/content.release")
        )
        XCTAssertEqual(
            describeMetadata["skillTree"],
            .string("/automation/runtime/skill-trees/content.release")
        )
        XCTAssertEqual(
            describeMetadata["toolBindings"],
            .string("/automation/runtime/tool-bindings/content.release")
        )
        XCTAssertEqual(
            describeMetadata["planningBundle"],
            .string("/automation/runtime/planning/content.release")
        )

        let startPath = try object(paths["/automation/workflows/content.release/tasks"])
        let start = try object(startPath["post"])
        XCTAssertEqual(start["operationId"], .string("start_workflow_task_ContentRelease"))
        XCTAssertEqual(
            try object(start["x-sml-workflow-runtime-metadata"]),
            describeMetadata
        )
        let startCommandBinding = try object(start["x-sml-command-binding"])
        XCTAssertEqual(startCommandBinding["workflowID"], .string("content.release"))
        XCTAssertEqual(startCommandBinding["workflowVersion"], .string("1.0.0"))
        XCTAssertEqual(startCommandBinding["action"], .string("start"))
        XCTAssertEqual(
            startCommandBinding["replLineTemplate"],
            .string("start [TASK_ID] [JSON_INPUT_OBJECT]")
        )
        XCTAssertEqual(
            startCommandBinding["apiPathTemplate"],
            .string("/automation/workflows/content.release/tasks")
        )
        XCTAssertEqual(
            startCommandBinding["apiOperationID"],
            .string("start_workflow_task_ContentRelease")
        )
        XCTAssertEqual(startCommandBinding["apiBodyKind"], .string("start_task"))
        XCTAssertEqual(startCommandBinding["modelEligible"], .bool(true))
        XCTAssertEqual(
            startCommandBinding["modelRouterToolName"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        let startCommandREPLFields = try array(startCommandBinding["replJSONFields"])
        XCTAssertEqual(try object(startCommandREPLFields.first)["name"], .string("target"))
        XCTAssertEqual(try object(startCommandREPLFields.first)["type"], .string("string"))
        let startCommandAPIFields = try array(startCommandBinding["apiBodyFields"])
        XCTAssertEqual(try object(startCommandAPIFields.first)["name"], .string("target"))
        XCTAssertEqual(try object(startCommandAPIFields.first)["nullable"], .bool(false))
        let startModelArguments = try object(startCommandBinding["modelRouterArgumentsTemplate"])
        XCTAssertEqual(startModelArguments["workflow_id"], .string("content.release"))
        XCTAssertEqual(
            startModelArguments["line"],
            .string("start [TASK_ID] [JSON_INPUT_OBJECT]")
        )
        let openAPIExamples = try array(start["x-sml-request-examples"])
        let openAPIStartExample = try object(openAPIExamples.first)
        XCTAssertEqual(openAPIStartExample["method"], .string("POST"))
        XCTAssertEqual(openAPIStartExample["path"], .string("/automation/workflows/content.release/tasks"))
        XCTAssertEqual(
            try object(openAPIStartExample["body"])["input"],
            .object(["target": .string("target")])
        )
        let requestBody = try object(start["requestBody"])
        XCTAssertEqual(requestBody["required"], .bool(true))
        let requestBodyContent = try object(requestBody["content"])
        let jsonRequestBody = try object(requestBodyContent["application/json"])
        let requestBodyExamples = try object(jsonRequestBody["examples"])
        let requestBodyExample = try object(requestBodyExamples["example1"])
        XCTAssertEqual(
            try object(requestBodyExample["value"])["input"],
            .object(["target": .string("target")])
        )

        let components = try object(export.openAPI["components"])
        let schemas = try object(components["schemas"])
        let runtimeMetadataSchema = try object(schemas["SMLRuntimeMetadata"])
        XCTAssertEqual(runtimeMetadataSchema["type"], .array([.string("object"), .string("array")]))
        let startSchema = try object(schemas["WorkflowStart_ContentRelease"])
        XCTAssertEqual(startSchema["additionalProperties"], .bool(false))
        XCTAssertEqual(
            try array(startSchema["required"]),
            [.string("task_id"), .string("input")]
        )
        let inputSchema = try object(schemas["WorkflowInput_ContentRelease"])
        let inputProperties = try object(inputSchema["properties"])
        let target = try object(inputProperties["target"])
        XCTAssertEqual(target["type"], .array([.string("string")]))
        XCTAssertEqual(target["description"], .string("Source document"))

        let runtime = try object(export.openAPI["x-sml-runtime"])
        XCTAssertEqual(
            try array(runtime["workflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )
        XCTAssertEqual(
            runtime["mountContractSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeMountContract.currentSchemaVersion))
        )
        XCTAssertEqual(runtime["mountAPIRouteCount"], .number(36))
        XCTAssertEqual(runtime["mountREPLCount"], .number(2))
        XCTAssertEqual(runtime["mountREPLCommandBindingCount"], .number(16))
        XCTAssertEqual(runtime["mountWorkflowCommandBindingCount"], .number(16))
        XCTAssertEqual(
            try array(runtime["modelToolNames"]),
            [.string(SMLWorkflowModelAdapter.toolName), .string(SMLWorkflowModelAdapter.toolName)]
        )
        XCTAssertEqual(
            runtime["modelRouterToolName"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        XCTAssertEqual(runtime["modelRouterMaximumCommandRounds"], .number(4))
        let routerTool = try object(runtime["modelRouterTool"])
        XCTAssertEqual(routerTool["name"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        let routerParameters = try array(routerTool["parameters"])
        XCTAssertEqual(routerParameters.count, 2)
        let routerExamples = try array(runtime["modelRouterExamples"])
        let releaseRouterExample = try object(routerExamples.first {
            if case .object(let object) = $0 {
                guard object["workflowID"] == .string("content.release"),
                      case .object(let arguments)? = object["arguments"] else {
                    return false
                }
                return arguments["line"] == .string(#"start TASK-ID {"target":"target"}"#)
            }
            return false
        })
        XCTAssertEqual(
            try object(releaseRouterExample["arguments"])["workflow_id"],
            .string("content.release")
        )
        XCTAssertEqual(
            try object(releaseRouterExample["arguments"])["line"],
            .string(#"start TASK-ID {"target":"target"}"#)
        )
        let routerWorkflowMetadata = try array(runtime["modelRouterWorkflowMetadata"])
        let releaseRuntimeMetadata = try XCTUnwrap(
            routerWorkflowMetadata.compactMap { try? object($0) }.first {
                $0["workflowID"] == .string("content.release")
            }
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["attachmentPath"],
            .string("/automation/runtime/attachments/content.release")
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["replMountPath"],
            .string("/automation/runtime/repl-mounts/content.release")
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["apiMountPath"],
            .string("/automation/runtime/api-mounts/content.release")
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["modelToolPath"],
            .string("/automation/runtime/model-tools/content.release")
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["onyxDriverPath"],
            .string("/automation/runtime/onyx-drivers/content.release")
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["skillTreePath"],
            .string("/automation/runtime/skill-trees/content.release")
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["toolBindingsPath"],
            .string("/automation/runtime/tool-bindings/content.release")
        )
        XCTAssertEqual(
            releaseRuntimeMetadata["planningBundlePath"],
            .string("/automation/runtime/planning/content.release")
        )
        let metadataEndpoints = try array(runtime["metadataEndpoints"])
        XCTAssertEqual(metadataEndpoints.count, 20)
        let metadataLaunchEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("launch")
            }
            return false
        })
        XCTAssertEqual(metadataLaunchEndpoint["pathTemplate"], .string("/automation/runtime/launch"))
        XCTAssertEqual(metadataLaunchEndpoint["resource"], .string("launch"))
        let metadataPlanningEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("planning")
            }
            return false
        })
        XCTAssertEqual(metadataPlanningEndpoint["pathTemplate"], .string("/automation/runtime/planning"))
        XCTAssertEqual(metadataPlanningEndpoint["resource"], .string("planning"))
        let metadataGuideEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("agent-guide")
            }
            return false
        })
        XCTAssertEqual(metadataGuideEndpoint["pathTemplate"], .string("/automation/runtime/agent-guide"))
        XCTAssertEqual(metadataGuideEndpoint["resource"], .string("agent-guide"))
        let metadataHostGuideEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("host-guide")
            }
            return false
        })
        XCTAssertEqual(
            metadataHostGuideEndpoint["pathTemplate"],
            .string("/automation/runtime/host-guide")
        )
        XCTAssertEqual(metadataHostGuideEndpoint["resource"], .string("host-guide"))
        let metadataHostWiringEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("host-wiring")
            }
            return false
        })
        XCTAssertEqual(
            metadataHostWiringEndpoint["pathTemplate"],
            .string("/automation/runtime/host-wiring")
        )
        XCTAssertEqual(metadataHostWiringEndpoint["resource"], .string("host-wiring"))
        let metadataAttachmentsEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("attachments")
            }
            return false
        })
        XCTAssertEqual(
            metadataAttachmentsEndpoint["pathTemplate"],
            .string("/automation/runtime/attachments")
        )
        XCTAssertEqual(metadataAttachmentsEndpoint["resource"], .string("attachments"))
        let metadataWorkflowAttachmentEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("workflow-attachment")
            }
            return false
        })
        XCTAssertEqual(
            metadataWorkflowAttachmentEndpoint["pathTemplate"],
            .string("/automation/runtime/attachments/{workflow_id}")
        )
        XCTAssertEqual(
            metadataWorkflowAttachmentEndpoint["resource"],
            .string("workflow-attachment")
        )
        let metadataWorkflowOnyxEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("workflow-onyx-driver")
            }
            return false
        })
        XCTAssertEqual(
            metadataWorkflowOnyxEndpoint["pathTemplate"],
            .string("/automation/runtime/onyx-drivers/{workflow_id}")
        )
        XCTAssertEqual(
            metadataWorkflowOnyxEndpoint["resource"],
            .string("workflow-onyx-driver")
        )
        let metadataWorkflowPlanningEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("workflow-planning")
            }
            return false
        })
        XCTAssertEqual(
            metadataWorkflowPlanningEndpoint["pathTemplate"],
            .string("/automation/runtime/planning/{workflow_id}")
        )
        XCTAssertEqual(
            metadataWorkflowPlanningEndpoint["resource"],
            .string("workflow-planning")
        )
        let metadataWorkflowSkillTreeEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("workflow-skill-tree")
            }
            return false
        })
        XCTAssertEqual(
            metadataWorkflowSkillTreeEndpoint["pathTemplate"],
            .string("/automation/runtime/skill-trees/{workflow_id}")
        )
        XCTAssertEqual(
            metadataWorkflowSkillTreeEndpoint["resource"],
            .string("workflow-skill-tree")
        )
        let metadataWorkflowToolBindingsEndpoint = try object(metadataEndpoints.first {
            if case .object(let object) = $0 {
                return object["resource"] == .string("workflow-tool-bindings")
            }
            return false
        })
        XCTAssertEqual(
            metadataWorkflowToolBindingsEndpoint["pathTemplate"],
            .string("/automation/runtime/tool-bindings/{workflow_id}")
        )
        XCTAssertEqual(
            metadataWorkflowToolBindingsEndpoint["resource"],
            .string("workflow-tool-bindings")
        )
        XCTAssertEqual(
            runtime["agentGuideSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeAgentGuide.currentSchemaVersion))
        )
        XCTAssertEqual(runtime["agentGuideWorkflowCount"], .number(2))
        XCTAssertEqual(
            runtime["agentGuideModelRouterToolName"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        XCTAssertEqual(runtime["agentGuideCommandBindingCount"], .number(16))
        XCTAssertEqual(runtime["agentGuideModelDescriptorCount"], .number(2))
        XCTAssertEqual(runtime["agentGuideSkillIndexCount"], .number(14))
        XCTAssertEqual(
            runtime["hostGuideSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeHostGuide.currentSchemaVersion))
        )
        XCTAssertEqual(runtime["hostGuideWorkflowCount"], .number(2))
        XCTAssertEqual(runtime["hostGuideBindingCount"], .number(18))
        XCTAssertEqual(runtime["hostGuideCommandBindingCount"], .number(16))
        XCTAssertEqual(runtime["hostGuideModelDescriptorCount"], .number(2))
        XCTAssertEqual(runtime["hostGuideSkillIndexCount"], .number(14))
        XCTAssertEqual(
            runtime["hostWiringSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeHostWiring.currentSchemaVersion))
        )
        XCTAssertEqual(runtime["hostWiringWorkflowCount"], .number(2))
        XCTAssertEqual(runtime["hostWiringBindingCount"], .number(18))
        XCTAssertEqual(runtime["hostWiringModelDescriptorCount"], .number(2))
        XCTAssertEqual(runtime["hostWiringSkillIndexCount"], .number(14))
        XCTAssertEqual(runtime["attachmentManifestCount"], .number(2))
        XCTAssertEqual(
            try array(runtime["attachmentWorkflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )
        XCTAssertEqual(runtime["attachmentModelDescriptorCount"], .number(2))
        XCTAssertEqual(runtime["attachmentSkillTreeNodeCount"], .number(14))
        XCTAssertEqual(runtime["attachmentSkillIndexCount"], .number(14))
        XCTAssertEqual(runtime["attachmentToolBindingCount"], .number(6))
        XCTAssertEqual(runtime["attachmentCommandBindingCount"], .number(16))
        XCTAssertEqual(runtime["attachmentPlanCount"], .number(2))
        XCTAssertEqual(
            runtime["planningManifestSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimePlanningManifest.currentSchemaVersion))
        )
        XCTAssertEqual(
            try array(runtime["planningWorkflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )
        XCTAssertEqual(runtime["planningSkillIndexCount"], .number(14))
        let planningSkillIndex = try array(runtime["planningSkillIndex"])
        XCTAssertEqual(planningSkillIndex.count, 14)
        let openAPIPlanningSkill = try XCTUnwrap(
            planningSkillIndex.compactMap { try? object($0) }.first {
                $0["workflowID"] == .string("content.release")
                    && $0["instructionID"] == .string("plan")
            }
        )
        XCTAssertEqual(openAPIPlanningSkill["kind"], .string("reasoning"))
        XCTAssertEqual(openAPIPlanningSkill["unitKind"], .string("model_reasoning"))
        XCTAssertEqual(openAPIPlanningSkill["reference"], .string("content.plan"))
        XCTAssertEqual(openAPIPlanningSkill["successors"], .array([.string("write")]))
        XCTAssertEqual(openAPIPlanningSkill["outputSchema"], .string("content.plan.v1"))
        XCTAssertEqual(try array(runtime["planningToolIndex"]).count, 6)
        XCTAssertEqual(try array(runtime["planningDecomposableUnits"]), [])
        XCTAssertEqual(try array(runtime["planningApprovalGates"]).count, 2)
        let openAPICommandBindings = try array(runtime["planningCommandBindings"])
        XCTAssertEqual(openAPICommandBindings.count, 16)
        let openAPIStartBinding = try XCTUnwrap(
            openAPICommandBindings.compactMap { try? object($0) }.first {
                $0["workflowID"] == .string("content.release")
                    && $0["action"] == .string("start")
            }
        )
        XCTAssertEqual(
            openAPIStartBinding["apiPathTemplate"],
            .string("/automation/workflows/content.release/tasks")
        )
        let openAPIStartREPLFields = try array(openAPIStartBinding["replJSONFields"])
        XCTAssertEqual(try object(openAPIStartREPLFields.first)["name"], .string("target"))
        XCTAssertEqual(try object(openAPIStartREPLFields.first)["type"], .string("string"))
        XCTAssertEqual(try object(openAPIStartREPLFields.first)["required"], .bool(true))
        XCTAssertEqual(
            try object(openAPIStartREPLFields.first)["description"],
            .string("Source document")
        )
        let openAPIStartAPIFields = try array(openAPIStartBinding["apiBodyFields"])
        XCTAssertEqual(try object(openAPIStartAPIFields.first)["name"], .string("target"))
        XCTAssertEqual(try object(openAPIStartAPIFields.first)["type"], .string("string"))
        XCTAssertEqual(try object(openAPIStartAPIFields.first)["nullable"], .bool(false))
        XCTAssertEqual(openAPIStartBinding["modelEligible"], .bool(true))

        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(SMLWorkflowRuntimeExport.self, from: data)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded, export)
        XCTAssertTrue(encoded.contains("\"agentGuide\""))
        XCTAssertTrue(encoded.contains("\"hostGuide\""))
        XCTAssertTrue(encoded.contains("\"hostWiring\""))
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
    }

    func testRuntimeExportDecodesLegacyGuideOmittedPayloadsFromCatalog() throws {
        let export = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [makeAdmitted()],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        ).export(title: "Automation", version: "2026.08")
        let currentData = try JSONEncoder().encode(export)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyObject["schemaVersion"] = 2
        legacyObject.removeValue(forKey: "agentGuide")
        legacyObject.removeValue(forKey: "hostGuide")
        legacyObject.removeValue(forKey: "hostWiring")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(SMLWorkflowRuntimeExport.self, from: legacyData)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.catalog.workflowIDs, ["content.release"])
        XCTAssertEqual(decoded.modelRouter, decoded.catalog.modelRouter)
        XCTAssertEqual(decoded.agentGuide, decoded.catalog.agentGuide)
        XCTAssertEqual(decoded.hostGuide, decoded.catalog.hostGuide)
        XCTAssertEqual(decoded.hostWiring, decoded.catalog.hostWiring)
        XCTAssertEqual(decoded.agentGuide.workflowGuides.map(\.workflowID), ["content.release"])
        XCTAssertEqual(decoded.hostGuide.workflowBindings.map(\.workflowID), ["content.release"])
        XCTAssertEqual(decoded.hostWiring.workflows.map(\.workflowID), ["content.release"])

        var legacy22Object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacy22Object["schemaVersion"] = 22
        var legacy22ModelTools = try XCTUnwrap(
            legacy22Object["modelTools"] as? [[String: Any]]
        )
        for index in legacy22ModelTools.indices {
            legacy22ModelTools[index].removeValue(forKey: "workflowMetadata")
        }
        legacy22Object["modelTools"] = legacy22ModelTools
        var legacy22ModelRouter = try XCTUnwrap(legacy22Object["modelRouter"] as? [String: Any])
        legacy22ModelRouter.removeValue(forKey: "workflowMetadata")
        legacy22Object["modelRouter"] = legacy22ModelRouter
        var legacy22OpenAPI = try XCTUnwrap(legacy22Object["openAPI"] as? [String: Any])
        var legacy22Runtime = try XCTUnwrap(legacy22OpenAPI["x-sml-runtime"] as? [String: Any])
        legacy22Runtime.removeValue(forKey: "modelRouterWorkflowMetadata")
        legacy22OpenAPI["x-sml-runtime"] = legacy22Runtime
        var legacy22Paths = try XCTUnwrap(legacy22OpenAPI["paths"] as? [String: Any])
        var legacy22StartPath = try XCTUnwrap(
            legacy22Paths["/automation/workflows/content.release/tasks"] as? [String: Any]
        )
        var legacy22StartPost = try XCTUnwrap(legacy22StartPath["post"] as? [String: Any])
        legacy22StartPost.removeValue(forKey: "x-sml-workflow-runtime-metadata")
        legacy22StartPath["post"] = legacy22StartPost
        legacy22Paths["/automation/workflows/content.release/tasks"] = legacy22StartPath
        legacy22OpenAPI["paths"] = legacy22Paths
        legacy22Object["openAPI"] = legacy22OpenAPI
        let legacy22Data = try JSONSerialization.data(
            withJSONObject: legacy22Object,
            options: [.sortedKeys]
        )
        let legacy22Decoded = try JSONDecoder().decode(
            SMLWorkflowRuntimeExport.self,
            from: legacy22Data
        )
        XCTAssertEqual(legacy22Decoded.schemaVersion, 22)
        XCTAssertEqual(legacy22Decoded.modelTools, legacy22Decoded.catalog.modelTools)
        XCTAssertEqual(legacy22Decoded.modelRouter, legacy22Decoded.catalog.modelRouter)
        let legacy22DecodedRuntime = try object(legacy22Decoded.openAPI["x-sml-runtime"])
        XCTAssertNotNil(legacy22DecodedRuntime["modelRouterWorkflowMetadata"])
        let legacy22DecodedPaths = try object(legacy22Decoded.openAPI["paths"])
        let legacy22DecodedStartPath = try object(
            legacy22DecodedPaths["/automation/workflows/content.release/tasks"]
        )
        let legacy22DecodedStartPost = try object(legacy22DecodedStartPath["post"])
        XCTAssertNotNil(legacy22DecodedStartPost["x-sml-workflow-runtime-metadata"])

        var nestedLegacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        nestedLegacyObject["schemaVersion"] = 7
        var legacyMountContract = try XCTUnwrap(nestedLegacyObject["mountContract"] as? [String: Any])
        legacyMountContract["schemaVersion"] = 5
        let legacyAPIRoutes = try XCTUnwrap(
            legacyMountContract["apiRoutes"] as? [[String: Any]]
        ).filter {
            !(($0["pathTemplate"] as? String)?.hasPrefix("/automation/runtime/attachments") ?? false)
        }
        legacyMountContract["apiRoutes"] = legacyAPIRoutes
        nestedLegacyObject["mountContract"] = legacyMountContract
        var legacyOpenAPI = try XCTUnwrap(nestedLegacyObject["openAPI"] as? [String: Any])
        var legacyOpenAPIPaths = try XCTUnwrap(legacyOpenAPI["paths"] as? [String: Any])
        legacyOpenAPIPaths.removeValue(forKey: "/automation/runtime/attachments")
        legacyOpenAPIPaths.removeValue(forKey: "/automation/runtime/attachments/{workflow_id}")
        var legacyStartPath = try XCTUnwrap(
            legacyOpenAPIPaths["/automation/workflows/content.release/tasks"] as? [String: Any]
        )
        var legacyStartPost = try XCTUnwrap(legacyStartPath["post"] as? [String: Any])
        legacyStartPost.removeValue(forKey: "x-sml-command-binding")
        legacyStartPath["post"] = legacyStartPost
        legacyOpenAPIPaths["/automation/workflows/content.release/tasks"] = legacyStartPath
        legacyOpenAPI["paths"] = legacyOpenAPIPaths
        nestedLegacyObject["openAPI"] = legacyOpenAPI
        var legacyOnyxDrivers = try XCTUnwrap(nestedLegacyObject["onyxDrivers"] as? [[String: Any]])
        for index in legacyOnyxDrivers.indices {
            legacyOnyxDrivers[index]["schemaVersion"] = 1
            legacyOnyxDrivers[index].removeValue(forKey: "commandBindings")
        }
        nestedLegacyObject["onyxDrivers"] = legacyOnyxDrivers
        var legacyCatalog = try XCTUnwrap(nestedLegacyObject["catalog"] as? [String: Any])
        var legacyCatalogWorkflows = try XCTUnwrap(legacyCatalog["workflows"] as? [[String: Any]])
        for workflowIndex in legacyCatalogWorkflows.indices {
            var legacyOnyx = try XCTUnwrap(
                legacyCatalogWorkflows[workflowIndex]["onyx"] as? [String: Any]
            )
            legacyOnyx["schemaVersion"] = 1
            legacyOnyx.removeValue(forKey: "commandBindings")
            legacyCatalogWorkflows[workflowIndex]["onyx"] = legacyOnyx
        }
        legacyCatalog["workflows"] = legacyCatalogWorkflows
        nestedLegacyObject["catalog"] = legacyCatalog
        var legacyModelRouter = try XCTUnwrap(nestedLegacyObject["modelRouter"] as? [String: Any])
        legacyModelRouter.removeValue(forKey: "examples")
        nestedLegacyObject["modelRouter"] = legacyModelRouter
        var legacyAgentGuide = try XCTUnwrap(nestedLegacyObject["agentGuide"] as? [String: Any])
        legacyAgentGuide["schemaVersion"] = 2
        legacyAgentGuide["metadataEndpoints"] = try XCTUnwrap(
            legacyAgentGuide["metadataEndpoints"] as? [[String: Any]]
        ).filter {
            !(($0["pathTemplate"] as? String)?.hasPrefix("/automation/runtime/attachments") ?? false)
        }
        nestedLegacyObject["agentGuide"] = legacyAgentGuide
        var legacyHostGuide = try XCTUnwrap(nestedLegacyObject["hostGuide"] as? [String: Any])
        legacyHostGuide["schemaVersion"] = 3
        legacyHostGuide["metadataEndpoints"] = try XCTUnwrap(
            legacyHostGuide["metadataEndpoints"] as? [[String: Any]]
        ).filter {
            !(($0["pathTemplate"] as? String)?.hasPrefix("/automation/runtime/attachments") ?? false)
        }
        var legacyHostGuideWorkflows = try XCTUnwrap(
            legacyHostGuide["workflowBindings"] as? [[String: Any]]
        )
        for workflowIndex in legacyHostGuideWorkflows.indices {
            var hostBindings = try XCTUnwrap(
                legacyHostGuideWorkflows[workflowIndex]["hostBindings"] as? [[String: Any]]
            )
            for bindingIndex in hostBindings.indices {
                hostBindings[bindingIndex].removeValue(forKey: "replExamples")
                hostBindings[bindingIndex].removeValue(forKey: "apiExamples")
                hostBindings[bindingIndex].removeValue(forKey: "modelToolExamples")
            }
            legacyHostGuideWorkflows[workflowIndex]["hostBindings"] = hostBindings
        }
        legacyHostGuide["workflowBindings"] = legacyHostGuideWorkflows
        nestedLegacyObject["hostGuide"] = legacyHostGuide

        var legacyHostWiring = try XCTUnwrap(nestedLegacyObject["hostWiring"] as? [String: Any])
        legacyHostWiring["schemaVersion"] = 3
        legacyHostWiring["metadataEndpoints"] = try XCTUnwrap(
            legacyHostWiring["metadataEndpoints"] as? [[String: Any]]
        ).filter {
            !(($0["pathTemplate"] as? String)?.hasPrefix("/automation/runtime/attachments") ?? false)
        }
        var legacyHostWiringWorkflows = try XCTUnwrap(
            legacyHostWiring["workflows"] as? [[String: Any]]
        )
        for workflowIndex in legacyHostWiringWorkflows.indices {
            var hostBindings = try XCTUnwrap(
                legacyHostWiringWorkflows[workflowIndex]["hostBindings"] as? [[String: Any]]
            )
            legacyHostWiringWorkflows[workflowIndex].removeValue(forKey: "plannerEntrypoint")
            legacyHostWiringWorkflows[workflowIndex].removeValue(forKey: "attachment")
            for bindingIndex in hostBindings.indices {
                hostBindings[bindingIndex].removeValue(forKey: "replExamples")
                hostBindings[bindingIndex].removeValue(forKey: "apiExamples")
                hostBindings[bindingIndex].removeValue(forKey: "modelToolExamples")
            }
            legacyHostWiringWorkflows[workflowIndex]["hostBindings"] = hostBindings
        }
        legacyHostWiring["workflows"] = legacyHostWiringWorkflows
        nestedLegacyObject["hostWiring"] = legacyHostWiring

        let nestedLegacyData = try JSONSerialization.data(
            withJSONObject: nestedLegacyObject,
            options: [.sortedKeys]
        )
        let nestedDecoded = try JSONDecoder().decode(
            SMLWorkflowRuntimeExport.self,
            from: nestedLegacyData
        )
        XCTAssertEqual(nestedDecoded.schemaVersion, 7)
        XCTAssertEqual(nestedDecoded.mountContract, nestedDecoded.catalog.mountContract)
        XCTAssertEqual(nestedDecoded.agentGuide, nestedDecoded.catalog.agentGuide)
        XCTAssertEqual(nestedDecoded.modelRouter, nestedDecoded.catalog.modelRouter)
        XCTAssertEqual(nestedDecoded.planning, nestedDecoded.catalog.planningManifest)
        XCTAssertEqual(nestedDecoded.planning.skillIndex.count, 7)
        XCTAssertEqual(nestedDecoded.hostGuide, nestedDecoded.catalog.hostGuide)
        XCTAssertEqual(nestedDecoded.hostWiring, nestedDecoded.catalog.hostWiring)
        XCTAssertTrue(nestedDecoded.mountContract.apiRoutes.contains {
            $0.pathTemplate == "/automation/runtime/attachments"
                && $0.metadataResource == .attachments
        })
        XCTAssertTrue(nestedDecoded.mountContract.apiRoutes.contains {
            $0.pathTemplate == "/automation/runtime/attachments/{workflow_id}"
                && $0.metadataResource == .workflowAttachment
        })
        let nestedDecodedPaths = try object(nestedDecoded.openAPI["paths"])
        XCTAssertNotNil(nestedDecodedPaths["/automation/runtime/attachments"])
        XCTAssertNotNil(nestedDecodedPaths["/automation/runtime/attachments/{workflow_id}"])
        let nestedDecodedStartPath = try object(
            nestedDecodedPaths["/automation/workflows/content.release/tasks"]
        )
        let nestedDecodedStartPost = try object(nestedDecodedStartPath["post"])
        XCTAssertNotNil(nestedDecodedStartPost["x-sml-command-binding"])
        let nestedDecodedInfo = try object(nestedDecoded.openAPI["info"])
        XCTAssertEqual(nestedDecodedInfo["title"], .string("Automation"))
        XCTAssertEqual(nestedDecodedInfo["version"], .string("2026.08"))
        XCTAssertTrue(nestedDecoded.agentGuide.metadataEndpoints.contains {
            $0.resource == .attachments
                && $0.pathTemplate == "/automation/runtime/attachments"
        })
        XCTAssertTrue(nestedDecoded.agentGuide.metadataEndpoints.contains {
            $0.resource == .workflowAttachment
                && $0.pathTemplate == "/automation/runtime/attachments/{workflow_id}"
        })
        XCTAssertTrue(nestedDecoded.hostWiring.workflows.first?.hostBindings.contains {
            $0.channel == .modelRouter
                && !$0.modelToolExamples.isEmpty
        } ?? false)
        XCTAssertEqual(nestedDecoded.hostWiring.workflows.first?.skillIndex.count, 7)
        XCTAssertEqual(nestedDecoded.hostWiring.workflows.first?.commandBindings.count, 8)
        XCTAssertEqual(nestedDecoded.hostWiring.attachmentManifests.first?.skillIndex.count, 7)
        XCTAssertEqual(nestedDecoded.hostWiring.attachmentManifests.first?.commandBindings.count, 8)
        XCTAssertEqual(nestedDecoded.onyxDrivers, nestedDecoded.catalog.onyxDrivers)
        XCTAssertEqual(
            nestedDecoded.onyxDrivers.first?.schemaVersion,
            SMLOnyxDriverManifest.currentSchemaVersion
        )
        XCTAssertEqual(nestedDecoded.onyxDrivers.first?.commandBindings.count, 8)
    }

    func testHostWiringDerivesAttachmentManifestWhenLegacyWorkflowOmitsIt() throws {
        let hostWiring = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [makeAdmitted()],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        ).catalog.hostWiring
        let currentData = try JSONEncoder().encode(hostWiring)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyObject["schemaVersion"] = 5
        var workflows = try XCTUnwrap(legacyObject["workflows"] as? [[String: Any]])
        for workflowIndex in workflows.indices {
            workflows[workflowIndex].removeValue(forKey: "plannerEntrypoint")
            workflows[workflowIndex].removeValue(forKey: "model")
            workflows[workflowIndex].removeValue(forKey: "attachment")
        }
        legacyObject["workflows"] = workflows
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(SMLWorkflowRuntimeHostWiring.self, from: legacyData)
        let workflow = try XCTUnwrap(decoded.workflows.first)

        XCTAssertEqual(decoded.schemaVersion, 5)
        XCTAssertNil(workflow.plannerEntrypoint)
        XCTAssertEqual(workflow.attachment.workflowID, "content.release")
        XCTAssertNil(workflow.attachment.plannerEntrypoint)
        XCTAssertNil(workflow.model)
        XCTAssertNil(workflow.attachment.model)
        XCTAssertEqual(
            workflow.attachment.channels,
            [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow, .skillTree, .toolBindings,
            ]
        )
        XCTAssertTrue(workflow.attachment.modelRouterExamples.contains {
            $0.arguments == [
                "workflow_id": .string("content.release"),
                "line": .string(#"start TASK-ID {"target":"target"}"#),
            ]
        })
        XCTAssertEqual(workflow.commandBindings.count, 8)
        XCTAssertEqual(workflow.skillIndex.count, 7)
        XCTAssertEqual(workflow.attachment.skillIndex, workflow.skillIndex)
        XCTAssertEqual(workflow.attachment.commandBindings, workflow.commandBindings)

        let currentWorkflow = try XCTUnwrap(hostWiring.workflows.first)
        XCTAssertEqual(
            currentWorkflow.attachment.skillTree.map(\.id),
            ["plan", "write", "verify", "approval", "rollback", "receipt", "escalate"]
        )
        XCTAssertEqual(
            currentWorkflow.attachment.toolBindings.map(\.reference),
            ["content.plan", "artifact_verified", "repository.write"]
        )
        XCTAssertEqual(currentWorkflow.attachment.plan?.entrypoint, "plan")
        XCTAssertEqual(currentWorkflow.attachment.plan?.nodes.count, 7)
        XCTAssertEqual(currentWorkflow.model?.tool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(currentWorkflow.attachment.model, currentWorkflow.model)
        XCTAssertEqual(currentWorkflow.attachment.skillIndex, currentWorkflow.skillIndex)
        XCTAssertEqual(currentWorkflow.attachment.commandBindings.count, 8)

        var legacyNestedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyNestedObject["schemaVersion"] = 7
        var nestedWorkflows = try XCTUnwrap(
            legacyNestedObject["workflows"] as? [[String: Any]]
        )
        for workflowIndex in nestedWorkflows.indices {
            var attachment = try XCTUnwrap(
                nestedWorkflows[workflowIndex]["attachment"] as? [String: Any]
            )
            attachment.removeValue(forKey: "skillTree")
            attachment.removeValue(forKey: "skillIndex")
            attachment.removeValue(forKey: "model")
            attachment.removeValue(forKey: "toolBindings")
            attachment.removeValue(forKey: "plan")
            nestedWorkflows[workflowIndex]["attachment"] = attachment
        }
        legacyNestedObject["workflows"] = nestedWorkflows
        let legacyNestedData = try JSONSerialization.data(
            withJSONObject: legacyNestedObject,
            options: [.sortedKeys]
        )
        let legacyNestedDecoded = try JSONDecoder().decode(
            SMLWorkflowRuntimeHostWiring.self,
            from: legacyNestedData
        )
        let legacyNestedWorkflow = try XCTUnwrap(legacyNestedDecoded.workflows.first)
        XCTAssertEqual(legacyNestedDecoded.schemaVersion, 7)
        XCTAssertEqual(legacyNestedWorkflow.attachment.skillTree, [])
        XCTAssertEqual(legacyNestedWorkflow.attachment.skillIndex, [])
        XCTAssertNil(legacyNestedWorkflow.attachment.model)
        XCTAssertEqual(legacyNestedWorkflow.attachment.toolBindings, [])
        XCTAssertNil(legacyNestedWorkflow.attachment.plan)
    }

    func testRuntimeMountContractResolvesRequestsToExactMountedRoutes() throws {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [
                makeAdmitted(),
                makeAdmitted(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation"
        )
        let contract = registry.mountContract

        let workflowMount = try contract.resolveWorkflow(workflowID: "content.review")
        XCTAssertEqual(workflowMount.workflowID, "content.review")
        XCTAssertEqual(workflowMount.workflowName, "Content review")
        XCTAssertEqual(workflowMount.apiBasePath, "/automation")
        XCTAssertEqual(workflowMount.repl.workflowID, "content.review")
        XCTAssertEqual(workflowMount.apiRoutes.count, 8)
        XCTAssertEqual(workflowMount.apiRoutes.map(\.handlerKind), Array(repeating: .workflow, count: 8))
        XCTAssertEqual(workflowMount.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(workflowMount.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertTrue(contract.onyxDriverIDs.contains(workflowMount.onyxDriverID))
        XCTAssertEqual(workflowMount.planningWorkflowID, "content.review")

        let start = try contract.resolveAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.release/tasks",
                body: [
                    "task_id": .string("TASK-START"),
                    "input": .object(["target": .string("notes.md")]),
                ]
            )
        )
        XCTAssertEqual(start.route.operationID, "start_workflow_task_ContentRelease")
        XCTAssertEqual(start.route.handlerKind, .workflow)
        XCTAssertEqual(start.route.authority, .hostCommandGateway)
        XCTAssertEqual(start.route.workflowID, "content.release")
        XCTAssertEqual(start.route.action, .start)
        XCTAssertEqual(start.route.bodyKind, .startTask)
        XCTAssertEqual(start.route.bodyFields.map(\.name), ["target"])
        let startExample = try XCTUnwrap(start.route.examples.first)
        XCTAssertEqual(startExample.method, .post)
        XCTAssertEqual(startExample.path, "/automation/workflows/content.release/tasks")
        XCTAssertEqual(startExample.body["task_id"], .string("TASK-ID"))
        XCTAssertEqual(startExample.body["input"], .object(["target": .string("target")]))
        XCTAssertEqual(start.pathParameters, [:])

        let receipts = try contract.resolveAPI(
            method: .get,
            path: "/automation/workflows/content.review/tasks/TASK-77/receipts"
        )
        XCTAssertEqual(receipts.route.operationID, "list_workflow_task_receipts_ContentReview")
        XCTAssertEqual(receipts.route.workflowID, "content.review")
        XCTAssertEqual(receipts.route.action, .receipts)
        XCTAssertTrue(receipts.route.readOnly)
        XCTAssertEqual(receipts.pathParameters, ["task_id": "TASK-77"])

        let metadata = try contract.resolveAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/mount")
        )
        XCTAssertEqual(metadata.route.operationID, SMLWorkflowRuntimeMetadataResource.mount.operationID)
        XCTAssertEqual(metadata.route.handlerKind, .metadata)
        XCTAssertEqual(metadata.route.authority, .descriptorOnly)
        XCTAssertEqual(metadata.route.metadataResource, .mount)
        XCTAssertTrue(metadata.route.readOnly)
        XCTAssertEqual(metadata.route.examples.first?.path, "/automation/runtime/mount")
        XCTAssertEqual(metadata.pathParameters, [:])

        let routedWatch = try registry.resolveMount(
            for: SMLWorkflowAPIRequest(
                method: .get,
                path: "/automation/workflows/content.release/tasks/TASK-1"
            )
        )
        XCTAssertEqual(routedWatch.route.operationID, "watch_workflow_task_ContentRelease")
        XCTAssertEqual(routedWatch.pathParameters, ["task_id": "TASK-1"])
        XCTAssertEqual(
            try registry.route(
                for: SMLWorkflowAPIRequest(
                    method: .get,
                    path: "/automation/workflows/content.release/tasks/TASK-1"
                )
            ),
            .workflow(workflowID: "content.release")
        )

        XCTAssertThrowsError(
            try contract.resolveAPI(
                SMLWorkflowAPIRequest(
                    method: .post,
                    path: "/automation/runtime/mount",
                    body: ["ignored": .bool(true)]
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeMountContractError,
                .metadataRequestMustBeReadOnly
            )
        }
        XCTAssertThrowsError(
            try registry.route(
                for: SMLWorkflowAPIRequest(
                    method: .post,
                    path: "/automation/runtime/mount",
                    body: ["ignored": .bool(true)]
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .metadataRequestMustBeReadOnly
            )
        }
        XCTAssertThrowsError(
            try contract.resolveAPI(
                method: .get,
                path: "/automation/workflows/content.review/%2e%2e"
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeMountContractError,
                .invalidAPIPath("/automation/workflows/content.review/%2e%2e")
            )
        }
        XCTAssertThrowsError(
            try contract.resolveAPI(
                method: .get,
                path: "/automation/workflows/content.review/tasks/TASK-77/unknown"
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeMountContractError,
                .routeNotFound(
                    method: "GET",
                    path: "/automation/workflows/content.review/tasks/TASK-77/unknown"
                )
            )
        }
        XCTAssertThrowsError(try contract.resolveWorkflow(workflowID: "missing.workflow")) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeMountContractError,
                .workflowNotMounted("missing.workflow")
            )
        }
    }

    func testRuntimeAppBindsCatalogAPIREPLModelRouterAndOnyxFacade() async throws {
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [
                makeAdmitted(),
                makeAdmitted(
                    id: "content.review",
                    name: "Content review",
                    sourceReference: "graphs/content_review.py"
                ),
            ],
            role: "release-manager",
            actor: "operator.luke",
            apiBasePath: "/automation",
            commandID: { "app-command" },
            taskID: { "TASK-APP-GENERATED" }
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 5_000 }
        )
        let runtime = SMLRuntime(store: store, clock: { 5_000 })
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: store)
        _ = try await registry.installAll(into: runtime)

        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = { command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "app-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }
        let app = registry.makeApp(
            gateway: gateway,
            authorityResolver: authority,
            clock: { 5_000 }
        )

        XCTAssertEqual(app.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(app.catalog.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(app.planningManifest.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(app.planningManifest.toolIndex.count, 6)
        XCTAssertEqual(app.mountContract.apiRoutes.count, 36)
        XCTAssertEqual(app.mountContract.replMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(app.metadataEndpoints.count, 20)
        XCTAssertEqual(app.runtimeAPI.catalog.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(app.runtimeAPI.mountContract.apiRoutes.count, 36)
        XCTAssertEqual(app.hostWiring, registry.hostWiring)
        XCTAssertEqual(app.runtimeAPI.hostWiring, registry.hostWiring)
        XCTAssertEqual(app.hostWiring.workflows.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(app.runtimeAPI.metadataEndpoints.map(\.resource), [
            .catalog, .mount, .launch, .export, .openAPI, .planning, .agentGuide, .hostGuide,
            .hostWiring, .attachments, .workflowAttachment, .workflowREPLMount,
            .workflowAPIMount, .workflowModelTool, .workflowOnyxDriver, .workflowSkillTree,
            .workflowToolBindings, .workflowPlanning, .modelRouter, .onyxDrivers,
        ])
        XCTAssertEqual(try app.descriptor(workflowID: "content.review").workflowName, "Content review")
        XCTAssertEqual(try app.onyxDriver(workflowID: "content.release").plan.entrypoint, "plan")

        let export = app.export(title: "Runtime App", version: "2026.08")
        XCTAssertEqual(export.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        let encodedExport = String(decoding: try JSONEncoder().encode(export), as: UTF8.self)
        XCTAssertFalse(encodedExport.contains("operator.luke"))
        XCTAssertFalse(encodedExport.contains("app-lease"))

        let repl = try app.replSession(workflowID: "content.release")
        let help = try await repl.submit("help")
        XCTAssertTrue(help.output.contains("content.release"))

        let started = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.review/tasks",
                body: [
                    "task_id": .string("TASK-APP"),
                    "input": .object(["target": .string("app-review.md")]),
                ]
            )
        )
        XCTAssertEqual(started.kind, .workflow)
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertNil(started.metadataResource)
        XCTAssertEqual(started.route?.operationID, "start_workflow_task_ContentReview")
        XCTAssertEqual(started.route?.workflowID, "content.review")
        XCTAssertEqual(started.pathParameters, [:])
        XCTAssertEqual(started.command?.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(started.result?.task?.workflowID, "content.review")
        let startedBody = try object(started.body)
        XCTAssertEqual(startedBody["kind"], .string(SMLCommandResultKind.task.rawValue))

        let planningMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/planning")
        )
        XCTAssertEqual(planningMetadata.statusCode, 200)
        XCTAssertEqual(planningMetadata.resource, .planning)
        let planningBody = try object(planningMetadata.body)
        XCTAssertEqual(
            try array(planningBody["workflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )
        XCTAssertEqual(try array(planningBody["skillIndex"]).count, 14)
        XCTAssertEqual(try array(planningBody["toolIndex"]).count, 6)
        XCTAssertEqual(try array(planningBody["commandBindings"]).count, 16)

        let workflowPlanningMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/planning/content.release")
        )
        XCTAssertEqual(workflowPlanningMetadata.statusCode, 200)
        XCTAssertEqual(workflowPlanningMetadata.resource, .workflowPlanning)
        let workflowPlanningBody = try object(workflowPlanningMetadata.body)
        XCTAssertEqual(
            workflowPlanningBody["schemaVersion"],
            .number(Decimal(SMLWorkflowRuntimePlanningWorkflowBundle.currentSchemaVersion))
        )
        XCTAssertEqual(workflowPlanningBody["workflowID"], .string("content.release"))
        XCTAssertEqual(workflowPlanningBody["apiBasePath"], .string("/automation"))
        XCTAssertEqual(
            workflowPlanningBody["apiWorkflowPath"],
            .string("/workflows/content.release")
        )
        let workflowPlanningLinks = try object(workflowPlanningBody["workflowMetadata"])
        XCTAssertEqual(
            workflowPlanningLinks["attachmentPath"],
            .string("/automation/runtime/attachments/content.release")
        )
        XCTAssertEqual(
            workflowPlanningLinks["modelToolPath"],
            .string("/automation/runtime/model-tools/content.release")
        )
        XCTAssertEqual(
            workflowPlanningLinks["planningBundlePath"],
            .string("/automation/runtime/planning/content.release")
        )
        let nestedWorkflowPlanningLinks = try object(
            try object(workflowPlanningBody["workflow"])["workflowMetadata"]
        )
        XCTAssertEqual(
            nestedWorkflowPlanningLinks["toolBindingsPath"],
            .string("/automation/runtime/tool-bindings/content.release")
        )
        XCTAssertEqual(try array(workflowPlanningBody["skillIndex"]).count, 7)
        XCTAssertEqual(try array(workflowPlanningBody["toolIndex"]).count, 3)
        XCTAssertEqual(try array(workflowPlanningBody["toolBindings"]).count, 3)
        XCTAssertEqual(try array(workflowPlanningBody["commandBindings"]).count, 8)

        let workflowREPLMountMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/repl-mounts/content.release")
        )
        XCTAssertEqual(workflowREPLMountMetadata.statusCode, 200)
        XCTAssertEqual(workflowREPLMountMetadata.resource, .workflowREPLMount)
        let workflowREPLMountBody = try object(workflowREPLMountMetadata.body)
        XCTAssertEqual(workflowREPLMountBody["workflowID"], .string("content.release"))
        XCTAssertEqual(
            workflowREPLMountBody["apiWorkflowPath"],
            .string("/workflows/content.release")
        )
        XCTAssertEqual(
            try object(workflowREPLMountBody["workflowMetadata"])["modelToolPath"],
            .string("/automation/runtime/model-tools/content.release")
        )
        XCTAssertTrue(try array(workflowREPLMountBody["commands"]).contains {
            guard case .object(let command) = $0 else { return false }
            return command["verb"] == .string("start")
        })

        let workflowAPIMountMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/api-mounts/content.release")
        )
        XCTAssertEqual(workflowAPIMountMetadata.statusCode, 200)
        XCTAssertEqual(workflowAPIMountMetadata.resource, .workflowAPIMount)
        let workflowAPIMountBody = try array(workflowAPIMountMetadata.body)
        XCTAssertEqual(workflowAPIMountBody.count, 8)
        XCTAssertTrue(workflowAPIMountBody.contains {
            guard case .object(let route) = $0 else { return false }
            return route["pathTemplate"] == .string("/automation/workflows/content.release/tasks")
                && route["operationID"] == .string("start_workflow_task_ContentRelease")
                && (try? object(route["workflowMetadata"]))?["apiMountPath"]
                    == .string("/automation/runtime/api-mounts/content.release")
        })

        let workflowModelToolMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/model-tools/content.release")
        )
        XCTAssertEqual(workflowModelToolMetadata.statusCode, 200)
        XCTAssertEqual(workflowModelToolMetadata.resource, .workflowModelTool)
        let workflowModelToolBody = try object(workflowModelToolMetadata.body)
        XCTAssertEqual(workflowModelToolBody["workflowID"], .string("content.release"))
        XCTAssertEqual(
            try object(workflowModelToolBody["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(
            try object(workflowModelToolBody["workflowMetadata"])["modelToolPath"],
            .string("/automation/runtime/model-tools/content.release")
        )

        let workflowOnyxMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/onyx-drivers/content.release")
        )
        XCTAssertEqual(workflowOnyxMetadata.statusCode, 200)
        XCTAssertEqual(workflowOnyxMetadata.resource, .workflowOnyxDriver)
        let workflowOnyxBody = try object(workflowOnyxMetadata.body)
        XCTAssertEqual(workflowOnyxBody["workflowID"], .string("content.release"))
        XCTAssertEqual(
            try object(workflowOnyxBody["api"])["workflowPath"],
            .string("/workflows/content.release")
        )
        XCTAssertEqual(try array(workflowOnyxBody["skillTree"]).count, 7)
        XCTAssertEqual(try array(workflowOnyxBody["tools"]).count, 3)
        XCTAssertEqual(try array(workflowOnyxBody["commandBindings"]).count, 8)

        let workflowSkillTreeMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/skill-trees/content.release")
        )
        XCTAssertEqual(workflowSkillTreeMetadata.statusCode, 200)
        XCTAssertEqual(workflowSkillTreeMetadata.resource, .workflowSkillTree)
        XCTAssertEqual(try array(workflowSkillTreeMetadata.body).count, 7)

        let workflowToolBindingsMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/tool-bindings/content.release")
        )
        XCTAssertEqual(workflowToolBindingsMetadata.statusCode, 200)
        XCTAssertEqual(workflowToolBindingsMetadata.resource, .workflowToolBindings)
        XCTAssertEqual(try array(workflowToolBindingsMetadata.body).count, 3)

        let mountMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/mount")
        )
        XCTAssertEqual(mountMetadata.statusCode, 200)
        XCTAssertEqual(mountMetadata.resource, .mount)
        let mountBody = try object(mountMetadata.body)
        XCTAssertEqual(try array(mountBody["workflowIDs"]), [
            .string("content.release"), .string("content.review"),
        ])
        XCTAssertEqual(try array(mountBody["apiRoutes"]).count, 36)
        let mountBodyREPLMounts = try array(mountBody["replMounts"])
        XCTAssertEqual(mountBodyREPLMounts.count, 2)
        XCTAssertEqual(
            try array(try object(mountBodyREPLMounts.first)["commandBindings"]).count,
            8
        )
        let mountBodyWorkflowMounts = try array(mountBody["workflowMounts"])
        XCTAssertEqual(mountBodyWorkflowMounts.count, 2)
        XCTAssertEqual(
            try array(try object(mountBodyWorkflowMounts.first)["commandBindings"]).count,
            8
        )

        let guideMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/agent-guide")
        )
        XCTAssertEqual(guideMetadata.statusCode, 200)
        XCTAssertEqual(guideMetadata.resource, .agentGuide)
        let guideBody = try object(guideMetadata.body)
        XCTAssertEqual(
            guideBody["schemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeAgentGuide.currentSchemaVersion))
        )
        XCTAssertEqual(
            try object(guideBody["modelRouterTool"])["name"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        XCTAssertTrue(
            try string(guideBody["systemPrompt"]).contains("Break work into small contextual workflow steps")
        )
        XCTAssertEqual(try array(guideBody["workflowGuides"]).count, 2)
        let agentGuideWorkflows = try array(guideBody["workflowGuides"])
        let releaseAgentGuide = try object(agentGuideWorkflows.first {
            if case .object(let object) = $0 {
                return object["workflowID"] == .string("content.release")
            }
            return false
        })
        XCTAssertEqual(
            try object(try object(releaseAgentGuide["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(try object(releaseAgentGuide["model"])["maximumCommandRounds"], .number(4))

        let hostGuideMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/host-guide")
        )
        XCTAssertEqual(hostGuideMetadata.statusCode, 200)
        XCTAssertEqual(hostGuideMetadata.resource, .hostGuide)
        let hostGuideBody = try object(hostGuideMetadata.body)
        XCTAssertEqual(
            hostGuideBody["schemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeHostGuide.currentSchemaVersion))
        )
        XCTAssertEqual(
            try object(hostGuideBody["modelRouterTool"])["name"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        XCTAssertEqual(try array(hostGuideBody["workflowBindings"]).count, 2)
        let hostGuideWorkflows = try array(hostGuideBody["workflowBindings"])
        let releaseHostGuide = try object(hostGuideWorkflows.first {
            if case .object(let object) = $0 {
                return object["workflowID"] == .string("content.release")
            }
            return false
        })
        XCTAssertEqual(
            try object(try object(releaseHostGuide["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(try object(releaseHostGuide["model"])["maximumCommandRounds"], .number(4))
        XCTAssertEqual(try array(releaseHostGuide["commandBindings"]).count, 8)
        XCTAssertEqual(try array(hostGuideBody["launchSteps"]).count, 7)

        let hostWiringMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/host-wiring")
        )
        XCTAssertEqual(hostWiringMetadata.statusCode, 200)
        XCTAssertEqual(hostWiringMetadata.resource, .hostWiring)
        let hostWiringBody = try object(hostWiringMetadata.body)
        XCTAssertEqual(
            hostWiringBody["schemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeHostWiring.currentSchemaVersion))
        )
        XCTAssertEqual(
            try object(hostWiringBody["modelRouter"])["maximumCommandRounds"],
            .number(4)
        )
        XCTAssertEqual(try array(hostWiringBody["workflows"]).count, 2)
        let hostWiringWorkflows = try array(hostWiringBody["workflows"])
        let releaseWiring = try object(hostWiringWorkflows.first {
            if case .object(let object) = $0 {
                return object["workflowID"] == .string("content.release")
            }
            return false
        })
        XCTAssertEqual(releaseWiring["apiBasePath"], .string("/automation"))
        XCTAssertEqual(try array(releaseWiring["apiRoutes"]).count, 8)
        XCTAssertEqual(releaseWiring["modelRouterToolName"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertEqual(
            try object(try object(releaseWiring["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(
            try object(releaseWiring["model"])["maximumCommandRounds"],
            .number(4)
        )
        XCTAssertNotNil(releaseWiring["onyxDriverID"])
        XCTAssertEqual(releaseWiring["planningWorkflowID"], .string("content.release"))
        let releaseWiringCommandBindings = try array(releaseWiring["commandBindings"])
        XCTAssertEqual(releaseWiringCommandBindings.count, 8)
        let releaseWiringStartBinding = try XCTUnwrap(
            releaseWiringCommandBindings.compactMap { try? object($0) }.first {
                $0["action"] == .string("start")
            }
        )
        XCTAssertEqual(
            releaseWiringStartBinding["apiPathTemplate"],
            .string("/automation/workflows/content.release/tasks")
        )
        XCTAssertEqual(releaseWiringStartBinding["modelEligible"], .bool(true))
        let releaseAttachment = try object(releaseWiring["attachment"])
        XCTAssertEqual(releaseAttachment["workflowID"], .string("content.release"))
        XCTAssertEqual(releaseAttachment["modelRouterToolName"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertEqual(
            try object(try object(releaseAttachment["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(try array(releaseAttachment["commandBindings"]).count, 8)
        XCTAssertTrue(try array(releaseAttachment["modelRouterExamples"]).contains {
            guard case .object(let example) = $0 else { return false }
            return example["workflowID"] == .string("content.release")
                && example["toolName"] == .string(SMLWorkflowRuntimeModelAdapter.toolName)
                && example["arguments"] == .object([
                    "workflow_id": .string("content.release"),
                    "line": .string(#"start TASK-ID {"target":"target"}"#),
                ])
        })

        let routedPlanning = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/planning")
        )
        XCTAssertEqual(routedPlanning.kind, .metadata)
        XCTAssertEqual(routedPlanning.statusCode, 200)
        XCTAssertEqual(routedPlanning.metadataResource, .planning)
        XCTAssertEqual(routedPlanning.route?.operationID, SMLWorkflowRuntimeMetadataResource.planning.operationID)
        XCTAssertEqual(routedPlanning.pathParameters, [:])
        XCTAssertNil(routedPlanning.command)
        XCTAssertNil(routedPlanning.result)
        XCTAssertEqual(
            try array(try object(routedPlanning.body)["workflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )

        let routedMount = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/mount")
        )
        XCTAssertEqual(routedMount.kind, .metadata)
        XCTAssertEqual(routedMount.metadataResource, .mount)
        XCTAssertEqual(routedMount.route?.operationID, SMLWorkflowRuntimeMetadataResource.mount.operationID)
        XCTAssertNil(routedMount.command)
        XCTAssertNil(routedMount.result)
        XCTAssertEqual(try array(try object(routedMount.body)["apiRoutes"]).count, 36)

        let launchMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/launch")
        )
        XCTAssertEqual(launchMetadata.statusCode, 200)
        XCTAssertEqual(launchMetadata.resource, .launch)
        let launchMetadataBody = try object(launchMetadata.body)
        XCTAssertEqual(launchMetadataBody["launchComplete"], .bool(false))
        XCTAssertEqual(
            try array(launchMetadataBody["installedWorkflowIDs"]),
            []
        )
        XCTAssertEqual(
            try array(launchMetadataBody["missingInstalledWorkflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )
        XCTAssertNil(app.launchDescriptor)

        let routedLaunch = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/launch")
        )
        XCTAssertEqual(routedLaunch.kind, .metadata)
        XCTAssertEqual(routedLaunch.metadataResource, .launch)
        XCTAssertEqual(routedLaunch.route?.operationID, SMLWorkflowRuntimeMetadataResource.launch.operationID)
        XCTAssertNil(routedLaunch.command)
        XCTAssertNil(routedLaunch.result)
        XCTAssertEqual(try object(routedLaunch.body)["launchComplete"], .bool(false))

        let routedGuide = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/agent-guide")
        )
        XCTAssertEqual(routedGuide.kind, .metadata)
        XCTAssertEqual(routedGuide.metadataResource, .agentGuide)
        XCTAssertEqual(
            routedGuide.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.agentGuide.operationID
        )
        XCTAssertNil(routedGuide.command)
        XCTAssertNil(routedGuide.result)

        let routedHostGuide = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/host-guide")
        )
        XCTAssertEqual(routedHostGuide.kind, .metadata)
        XCTAssertEqual(routedHostGuide.metadataResource, .hostGuide)
        XCTAssertEqual(
            routedHostGuide.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.hostGuide.operationID
        )
        XCTAssertNil(routedHostGuide.command)
        XCTAssertNil(routedHostGuide.result)

        let routedHostWiring = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/host-wiring")
        )
        XCTAssertEqual(routedHostWiring.kind, .metadata)
        XCTAssertEqual(routedHostWiring.metadataResource, .hostWiring)
        XCTAssertEqual(
            routedHostWiring.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.hostWiring.operationID
        )
        XCTAssertNil(routedHostWiring.command)
        XCTAssertNil(routedHostWiring.result)
        XCTAssertEqual(try array(try object(routedHostWiring.body)["workflows"]).count, 2)

        let attachmentsMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/attachments")
        )
        XCTAssertEqual(attachmentsMetadata.statusCode, 200)
        XCTAssertEqual(attachmentsMetadata.resource, .attachments)
        let attachmentBodies = try array(attachmentsMetadata.body)
        XCTAssertEqual(attachmentBodies.count, 2)
        let releaseAttachmentBody = try object(attachmentBodies.first {
            if case .object(let object) = $0 {
                return object["workflowID"] == .string("content.release")
            }
            return false
        })
        XCTAssertEqual(releaseAttachmentBody["apiBasePath"], .string("/automation"))
        XCTAssertEqual(releaseAttachmentBody["modelRouterToolName"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertEqual(
            try object(try object(releaseAttachmentBody["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(try array(releaseAttachmentBody["commandBindings"]).count, 8)
        XCTAssertTrue(try array(releaseAttachmentBody["modelRouterExamples"]).contains {
            guard case .object(let example) = $0 else { return false }
            return example["workflowID"] == .string("content.release")
                && example["toolName"] == .string(SMLWorkflowRuntimeModelAdapter.toolName)
                && example["arguments"] == .object([
                    "workflow_id": .string("content.release"),
                    "line": .string(#"start TASK-ID {"target":"target"}"#),
                ])
        })

        let workflowAttachmentMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(
                method: .get,
                path: "/automation/runtime/attachments/content.release"
            )
        )
        XCTAssertEqual(workflowAttachmentMetadata.statusCode, 200)
        XCTAssertEqual(workflowAttachmentMetadata.resource, .workflowAttachment)
        let workflowAttachmentBody = try object(workflowAttachmentMetadata.body)
        XCTAssertEqual(workflowAttachmentBody["workflowID"], .string("content.release"))
        XCTAssertEqual(
            try object(try object(workflowAttachmentBody["model"])["tool"])["name"],
            .string(SMLWorkflowModelAdapter.toolName)
        )
        XCTAssertEqual(try array(workflowAttachmentBody["skillTree"]).count, 7)
        XCTAssertEqual(try array(workflowAttachmentBody["toolBindings"]).count, 3)
        XCTAssertEqual(try array(workflowAttachmentBody["commandBindings"]).count, 8)
        XCTAssertEqual(try object(workflowAttachmentBody["plan"])["entrypoint"], .string("plan"))

        let routedAttachments = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/attachments")
        )
        XCTAssertEqual(routedAttachments.kind, .metadata)
        XCTAssertEqual(routedAttachments.metadataResource, .attachments)
        XCTAssertEqual(
            routedAttachments.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.attachments.operationID
        )
        XCTAssertNil(routedAttachments.command)
        XCTAssertNil(routedAttachments.result)
        XCTAssertEqual(try array(routedAttachments.body).count, 2)

        let routedWorkflowAttachment = try await app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(
                method: .get,
                path: "/automation/runtime/attachments/content.review"
            )
        )
        XCTAssertEqual(routedWorkflowAttachment.kind, .metadata)
        XCTAssertEqual(routedWorkflowAttachment.metadataResource, .workflowAttachment)
        XCTAssertEqual(
            routedWorkflowAttachment.route?.operationID,
            SMLWorkflowRuntimeMetadataResource.workflowAttachment.operationID
        )
        XCTAssertEqual(routedWorkflowAttachment.pathParameters, ["workflow_id": "content.review"])
        XCTAssertNil(routedWorkflowAttachment.command)
        XCTAssertNil(routedWorkflowAttachment.result)
        XCTAssertEqual(try object(routedWorkflowAttachment.body)["workflowID"], .string("content.review"))

        let appResolvedWatch = try app.resolveMount(
            for: SMLWorkflowAPIRequest(
                method: .get,
                path: "/automation/workflows/content.review/tasks/TASK-APP/receipts"
            )
        )
        XCTAssertEqual(appResolvedWatch.route.operationID, "list_workflow_task_receipts_ContentReview")
        XCTAssertEqual(appResolvedWatch.pathParameters, ["task_id": "TASK-APP"])
        let appWorkflowMount = try app.resolveWorkflowMount(workflowID: "content.review")
        XCTAssertEqual(appWorkflowMount.repl.workflowID, "content.review")
        XCTAssertEqual(appWorkflowMount.apiRoutes.map(\.workflowID), Array(repeating: "content.review", count: 8))
        XCTAssertEqual(appWorkflowMount.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(appWorkflowMount.planningWorkflowID, "content.review")

        let routerMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/model-router")
        )
        let routerMetadataBody = try object(routerMetadata.body)
        XCTAssertEqual(
            try array(routerMetadataBody["workflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )
        let onyxMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/onyx-drivers")
        )
        XCTAssertEqual(onyxMetadata.resource, .onyxDrivers)
        XCTAssertEqual(try array(onyxMetadata.body).count, 2)

        XCTAssertThrowsError(
            try app.handleMetadata(
                SMLWorkflowAPIRequest(
                    method: .post,
                    path: "/automation/runtime/planning",
                    body: ["ignored": .bool(true)]
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeRegistryError,
                .metadataRequestMustBeReadOnly
            )
        }

        let providers = ProviderRegistry(providers: [], retryDelaysNanoseconds: [])
        let router = app.modelRouter(
            binding: ProviderBinding(providerId: "onyx-test", model: "onyx-1"),
            providers: providers
        )
        XCTAssertEqual(router.modelCommandTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertTrue(router.modelCommandTool.description.contains("content.release"))
        XCTAssertTrue(router.modelCommandTool.description.contains("content.review"))

        let routerSession = app.modelRouterSession(
            binding: ProviderBinding(providerId: "onyx-test", model: "onyx-1"),
            providers: providers
        )
        let routerTaskIDs = await routerSession.taskIDs()
        XCTAssertEqual(routerTaskIDs, [:])

        let model = try app.modelAdapter(
            workflowID: "content.release",
            binding: ProviderBinding(providerId: "onyx-test", model: "onyx-1"),
            providers: providers
        )
        XCTAssertEqual(model.surface.workflowID, "content.release")
    }

    func testWorkflowScopedREPLBindsWorkflowInputsAndExpectedState() throws {
        let surface = try makeSurface()
        let repl = SMLWorkflowREPLCompiler(
            surface: surface,
            actor: "operator.luke",
            commandID: { "command-fixed" },
            taskID: { "TASK-GENERATED" }
        )

        guard case .command(let describe) = try repl.compile(
            "describe", issuedAtEpoch: 999
        ) else { return XCTFail("expected describe command") }
        XCTAssertEqual(describe.task, "runtime")
        XCTAssertEqual(describe.op, SMLRuntimeCommandOperation.workflowInspect)

        guard case .command(let start) = try repl.compile(
            #"start TASK-42 {"target":"release-notes.md"}"#,
            issuedAtEpoch: 1_000
        ) else { return XCTFail("expected command") }
        XCTAssertEqual(start.task, "TASK-42")
        XCTAssertEqual(start.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(start.arguments["workflow_id"], .string("content.release"))
        XCTAssertEqual(start.arguments["workflow_version"], .string("1.0.0"))
        XCTAssertEqual(
            start.arguments["initial_state"],
            .object(["target": .string("release-notes.md")])
        )

        guard case .command(let approve) = try repl.compile(
            #"approve TASK-42 {"task_revision":1,"instruction_id":"approval","workflow_version":"1.0.0"}"#,
            issuedAtEpoch: 1_001
        ) else { return XCTFail("expected command") }
        XCTAssertEqual(approve.op, SMLRuntimeCommandOperation.taskApprove)
        XCTAssertEqual(approve.arguments["workflow_id"], .string("content.release"))
        XCTAssertEqual(approve.arguments["workflow_version"], .string("1.0.0"))
        XCTAssertEqual(approve.expectedState["instruction_id"], .string("approval"))
        XCTAssertEqual(approve.expectedState["task_revision"], .number(1))

        guard case .local(let schema) = try repl.compile("schema", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local schema")
        }
        XCTAssertTrue(schema.contains("target:string"))
        guard case .local(let apiInfo) = try repl.compile("api", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local API metadata")
        }
        XCTAssertTrue(apiInfo.contains("POST /v1/workflows/content.release/tasks"))
        guard case .local(let modelInfo) = try repl.compile("model", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local model metadata")
        }
        XCTAssertTrue(modelInfo.contains(SMLWorkflowModelAdapter.toolName))
        guard case .local(let onyxInfo) = try repl.compile("onyx", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local Onyx metadata")
        }
        XCTAssertTrue(onyxInfo.contains("onyx metadata:"))
        XCTAssertTrue(onyxInfo.contains("onyx driver: GET /v1/runtime/onyx-drivers/content.release"))
        XCTAssertTrue(onyxInfo.contains("planning bundle: GET /v1/runtime/planning/content.release"))
        XCTAssertTrue(onyxInfo.contains("skill tree:"))
        guard case .local(let skillTreeInfo) = try repl.compile("skills", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local skill tree metadata")
        }
        XCTAssertTrue(skillTreeInfo.contains("skill tree metadata:"))
        XCTAssertTrue(skillTreeInfo.contains("skill tree: GET /v1/runtime/skill-trees/content.release"))
        guard case .local(let toolBindingsInfo) = try repl.compile("tools", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local tool binding metadata")
        }
        XCTAssertTrue(toolBindingsInfo.contains("tool binding metadata:"))
        XCTAssertTrue(toolBindingsInfo.contains("tool bindings: GET /v1/runtime/tool-bindings/content.release"))
        guard case .local(let planningInfo) = try repl.compile("planning", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local planning metadata")
        }
        XCTAssertTrue(planningInfo.contains("planning metadata:"))
        XCTAssertTrue(planningInfo.contains("planning bundle: GET /v1/runtime/planning/content.release"))
        XCTAssertTrue(planningInfo.contains("api mount: GET /v1/runtime/api-mounts/content.release"))
        XCTAssertTrue(planningInfo.contains("repl mount: GET /v1/runtime/repl-mounts/content.release"))
        XCTAssertTrue(planningInfo.contains("entrypoint: plan"))

        XCTAssertThrowsError(try repl.compile("start TASK-42 {}", issuedAtEpoch: 1_003)) {
            XCTAssertEqual($0 as? SMLWorkflowSurfaceError, .missingInput("target"))
        }
        XCTAssertThrowsError(
            try repl.compile(#"start TASK-42 {"unknown":true}"#, issuedAtEpoch: 1_004)
        ) {
            XCTAssertEqual($0 as? SMLWorkflowSurfaceError, .unknownInput("unknown"))
        }
        XCTAssertThrowsError(
            try repl.compile(#"start TASK-42 {"target":1}"#, issuedAtEpoch: 1_005)
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSurfaceError,
                .invalidInput(name: "target", expected: .string)
            )
        }
        XCTAssertThrowsError(
            try repl.compile("approve TASK-42", issuedAtEpoch: 1_006)
        ) {
            XCTAssertEqual($0 as? SMLWorkflowSurfaceError, .taskRevisionRequired)
        }
    }

    func testAPICompilerRoutesOnlyItsOwnWorkflowAndClosedBodyShape() throws {
        let surface = try makeSurface()
        let api = try SMLWorkflowAPICompiler(
            surface: surface,
            actor: "service.release",
            commandID: { "api-command" }
        )

        let start = try api.compile(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/v1/workflows/content.release/tasks",
                body: [
                    "task_id": .string("TASK-API"),
                    "input": .object(["target": .string("notes.md")]),
                ]
            ),
            issuedAtEpoch: 2_000
        )
        XCTAssertEqual(start.task, "TASK-API")
        XCTAssertEqual(start.op, SMLRuntimeCommandOperation.workflowRun)

        let watch = try api.compile(
            SMLWorkflowAPIRequest(
                method: .get,
                path: "/v1/workflows/content.release/tasks/TASK-API",
                expectedState: ["workflow_version": .string("1.0.0")]
            ),
            issuedAtEpoch: 2_001
        )
        XCTAssertEqual(watch.op, SMLRuntimeCommandOperation.taskWatch)
        XCTAssertEqual(watch.expectedState["workflow_version"], .string("1.0.0"))

        let approve = try api.compile(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/v1/workflows/content.release/tasks/TASK-API/approve",
                body: [
                    "task_revision": .number(1),
                    "instruction_id": .string("approval"),
                    "workflow_version": .string("1.0.0"),
                ]
            ),
            issuedAtEpoch: 2_002
        )
        XCTAssertEqual(approve.op, SMLRuntimeCommandOperation.taskApprove)
        XCTAssertEqual(approve.expectedState["task_revision"], .number(1))
        XCTAssertEqual(approve.expectedState["instruction_id"], .string("approval"))

        XCTAssertThrowsError(try api.compile(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/v1/workflows/content.release/tasks",
                body: [
                    "task_id": .string("TASK-API"),
                    "input": .object(["target": .string("notes.md")]),
                    "actor": .string("forged"),
                ]
            ),
            issuedAtEpoch: 2_003
        )) {
            XCTAssertEqual($0 as? SMLWorkflowAPIError, .unknownBodyField("actor"))
        }
        XCTAssertThrowsError(try api.compile(
            SMLWorkflowAPIRequest(method: .get, path: "/v1/workflows/other/tasks/TASK-API"),
            issuedAtEpoch: 2_004
        ))
        XCTAssertThrowsError(try api.compile(
            SMLWorkflowAPIRequest(method: .get, path: "/v1/workflows/content.release/%2e%2e"),
            issuedAtEpoch: 2_005
        )) {
            guard case .invalidPath = $0 as? SMLWorkflowAPIError else {
                return XCTFail("expected invalid path, got \($0)")
            }
        }
        XCTAssertThrowsError(try api.compile(
            SMLWorkflowAPIRequest(
                method: .get,
                path: "/v1/workflows/content.release/tasks/runtime/receipts"
            ),
            issuedAtEpoch: 2_006
        )) {
            XCTAssertEqual($0 as? SMLWorkflowSurfaceError, .invalidTask("runtime"))
        }
        XCTAssertThrowsError(try api.compile(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/v1/workflows/content.release/tasks/TASK-API/refuse",
                body: ["task_revision": .number(1)],
                expectedState: ["task_revision": .number(2)]
            ),
            issuedAtEpoch: 2_007
        )) {
            XCTAssertEqual($0 as? SMLWorkflowAPIError, .invalidBodyField("expected_state"))
        }
    }

    func testOldAPIEndpointCatalogsDecodeWithNoBodyKind() throws {
        let data = Data(
            #"{"method":"GET","pathTemplate":"/v1/workflows/x","operationID":"describe","action":"describe","summary":"old"}"#.utf8
        )

        let endpoint = try JSONDecoder().decode(SMLWorkflowAPIEndpoint.self, from: data)

        XCTAssertEqual(endpoint.bodyKind, .none)
        XCTAssertTrue(endpoint.bodyFields.isEmpty)
        XCTAssertTrue(endpoint.examples.isEmpty)
    }

    func testOldAPICatalogsDecodeWithDefaultWorkflowPath() throws {
        let data = Data(
            """
            {
              "workflowID": "content.release",
              "workflowVersion": "1.0.0",
              "basePath": "/automation",
              "endpoints": [
                {
                  "method": "GET",
                  "pathTemplate": "/automation/workflows/content.release",
                  "operationID": "describe_workflow",
                  "action": "describe",
                  "summary": "Describe workflow"
                }
              ]
            }
            """.utf8
        )

        let catalog = try JSONDecoder().decode(SMLWorkflowAPICatalog.self, from: data)

        XCTAssertEqual(catalog.workflowID, "content.release")
        XCTAssertEqual(catalog.workflowPath, "/workflows/content.release")
        XCTAssertEqual(catalog.endpoints.first?.bodyKind, SMLWorkflowAPIRequestBodyKind.none)
    }

    func testOnyxPlanningContractsExposeControlsRetryPluginsAndNestedWorkflows() throws {
        let condition = SMLCondition(clauses: [
            .init(field: "ready", op: .equals, value: .bool(true)),
        ])
        let plugin = SMLPluginContract(
            id: "invoice_processor",
            reads: ["invoice"],
            writes: ["status"],
            sideEffectLevel: .reversibleInternal,
            preconditions: ["invoice_present"],
            postconditions: ["status_written"],
            rollback: "invoice_rollback",
            verifier: "invoice_verified"
        )
        let workflow = SMLWorkflow(
            id: "ops.invoice",
            version: "1.0.0",
            name: "Invoice operation",
            source: .init(kind: .langGraph, reference: "graphs/invoice.py"),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "ready", type: .boolean),
                .init(name: "invoice", type: .object),
                .init(name: "status", type: .string, required: false),
            ],
            interface: .init(inputFields: ["ready", "invoice"], outputFields: ["status"]),
            entrypoint: "decide",
            instructions: [
                .init(id: "decide", op: .branch, condition: condition,
                      trueTarget: "plugin", falseTarget: "nested"),
                .init(id: "plugin", op: .runPlugin,
                      expectedState: ["ready": .bool(true)],
                      plugin: plugin, next: "retry"),
                .init(id: "retry", op: .retry,
                      retryPolicy: .init(target: "plugin", maximumAttempts: 2, backoffSeconds: 1),
                      onFailure: "receipt"),
                .init(id: "nested", op: .runWorkflow, workflow: "ops.fallback", next: "receipt"),
                .init(id: "receipt", op: .emitReceipt, receiptFields: ["status"]),
            ]
        )
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(workflow),
            catalog: SMLExecutionAdmissionCatalog(
                workflows: ["ops.fallback"],
                verifiers: ["invoice_verified"],
                rollbackProcedures: ["invoice_rollback"],
                plugins: [
                    plugin.id: SMLPluginAttestation(
                        contract: plugin,
                        trustLevel: .contracted,
                        isolation: .sandboxed,
                        attestedBy: "test"
                    ),
                ]
            )
        )
        let surface = try SMLWorkflowSurface.compile(admitted: admitted, role: "ops-role")
        let manifest = SMLOnyxDriverCompiler.compile(surface: surface)

        let decide: SMLOnyxSkillNode = try XCTUnwrap(
            manifest.skillTree.first { $0.id == "decide" }
        )
        XCTAssertEqual(decide.planning?.unitKind, .control)
        XCTAssertEqual(decide.planning?.statePreconditions, ["ready"])
        XCTAssertEqual(decide.planning?.condition, condition)

        let pluginNode: SMLOnyxSkillNode = try XCTUnwrap(
            manifest.skillTree.first { $0.id == "plugin" }
        )
        XCTAssertEqual(pluginNode.planning?.unitKind, .pluginContract)
        XCTAssertEqual(pluginNode.planning?.statePreconditions, ["ready"])
        XCTAssertEqual(pluginNode.planning?.declaredOutputs, ["status"])
        XCTAssertEqual(pluginNode.planning?.plugin, plugin)
        XCTAssertEqual(pluginNode.planning?.canDecomposeFurther, true)

        let retry: SMLOnyxSkillNode = try XCTUnwrap(
            manifest.skillTree.first { $0.id == "retry" }
        )
        XCTAssertEqual(retry.planning?.unitKind, .boundedRetry)
        XCTAssertEqual(retry.planning?.retryPolicy?.maximumAttempts, 2)

        let nested: SMLOnyxSkillNode = try XCTUnwrap(
            manifest.skillTree.first { $0.id == "nested" }
        )
        XCTAssertEqual(nested.planning?.unitKind, .nestedWorkflow)
        XCTAssertEqual(nested.planning?.canDecomposeFurther, true)

        let registry = try SMLWorkflowRuntimeRegistry.compile(
            admitted: [admitted],
            role: "ops-role",
            actor: "operator.luke",
            apiBasePath: "/automation"
        )
        let planning = registry.planningManifest

        XCTAssertEqual(planning.workflowIDs, ["ops.invoice"])
        XCTAssertEqual(planning.workflows.first?.workflowName, "Invoice operation")
        XCTAssertEqual(planning.workflows.first?.entrypoint, "decide")
        XCTAssertEqual(
            planning.decomposableUnits.map { "\($0.instructionID):\($0.unitKind.rawValue)" },
            ["nested:nested_workflow", "plugin:plugin_contract"]
        )
        let pluginIndex: SMLWorkflowRuntimePlanningToolIndexEntry = try XCTUnwrap(
            planning.toolIndex.first { $0.instructionID == "plugin" }
        )
        XCTAssertEqual(pluginIndex.reference, "invoice_processor")
        XCTAssertEqual(pluginIndex.unitKind, .pluginContract)
        XCTAssertEqual(pluginIndex.statePreconditions, ["ready"])
        XCTAssertEqual(pluginIndex.declaredOutputs, ["status"])
        XCTAssertEqual(pluginIndex.verifier, "invoice_verified")
        XCTAssertEqual(pluginIndex.sideEffectLevel, .reversibleInternal)
        XCTAssertEqual(
            planning.toolIndex.first { $0.instructionID == "nested" }?.unitKind,
            .nestedWorkflow
        )
        XCTAssertEqual(planning.approvalGates, [])

        let encoded = String(decoding: try JSONEncoder().encode(planning), as: UTF8.self)
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("lease"))
    }

    func testInterfaceValidationRejectsUnknownDuplicateAndUnpublishedFields() throws {
        let base = workflow()
        let invalid = SMLWorkflow(
            id: base.id,
            version: base.version,
            name: base.name,
            source: base.source,
            trigger: base.trigger,
            stateSchema: base.stateSchema,
            interface: .init(
                inputFields: ["target", "target", "missing"],
                outputFields: ["target"]
            ),
            entrypoint: base.entrypoint,
            instructions: base.instructions
        )
        let report = SMLWorkflowValidator.validate(invalid)
        XCTAssertTrue(report.errors.contains { $0.code == "duplicate_interface_field" })
        XCTAssertTrue(report.errors.contains { $0.code == "unknown_interface_field" })
        XCTAssertTrue(report.errors.contains { $0.code == "unpublished_output_field" })
    }

    func testRuntimeControlStateNamesAreReserved() {
        for name in SMLWorkflowValidator.reservedStateFields {
            let candidate = SMLWorkflow(
                id: "reserved.field",
                version: "1.0.0",
                name: "Reserved field",
                source: .init(kind: .native, reference: "test"),
                trigger: .init(kind: .manual),
                stateSchema: [.init(name: name, type: .string)],
                entrypoint: "done",
                instructions: [.init(id: "done", op: .complete)]
            )
            XCTAssertTrue(
                SMLWorkflowValidator.validate(candidate).errors.contains {
                    $0.code == "reserved_state_field"
                },
                "\(name) must not shadow runtime expected_state controls"
            )
        }
    }

    private func makeSurface(version: String = "1.0.0") throws -> SMLWorkflowSurface {
        try SMLWorkflowSurface.compile(admitted: makeAdmitted(version: version), role: "release-manager")
    }

    private func makeAdmitted(
        id: String = "content.release",
        version: String = "1.0.0",
        name: String = "Content release",
        sourceReference: String = "graphs/content_release.py"
    ) throws -> SMLAdmittedWorkflow {
        try SMLWorkflowAdmission.admitForExecution(
            SMLWorkflowValidator.requireValidForImport(
                workflow(
                    id: id,
                    version: version,
                    name: name,
                    sourceReference: sourceReference
                )
            ),
            catalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["repository.write"],
                modelPurposes: ["content.plan"],
                modelOutputSchemas: ["content.plan.v1"],
                verifiers: ["artifact_verified"],
                approvalAuthorities: ["release_approver"]
            )
        )
    }

    private func workflow(
        id: String = "content.release",
        version: String = "1.0.0",
        name: String = "Content release",
        sourceReference: String = "graphs/content_release.py"
    ) -> SMLWorkflow {
        SMLWorkflow(
            id: id,
            version: version,
            name: name,
            source: .init(kind: .langGraph, reference: sourceReference),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "target", type: .string, description: "Source document"),
                .init(name: "artifact", type: .string, required: false, description: "Published artifact"),
            ],
            interface: .init(inputFields: ["target"], outputFields: ["artifact"]),
            entrypoint: "plan",
            instructions: [
                .init(id: "plan", op: .callModel, purpose: "content.plan",
                      outputSchema: "content.plan.v1", next: "write"),
                .init(id: "write", op: .callTool, capability: "repository.write", next: "verify"),
                .init(id: "verify", op: .verify, verifier: "artifact_verified",
                      onPass: "approval", onFailure: "rollback"),
                .init(id: "approval", op: .waitApproval, reason: "release",
                      owner: "release_approver", next: "receipt", onFailure: "escalate"),
                .init(id: "rollback", op: .rollback, reason: "verification_failed", next: "escalate"),
                .init(id: "receipt", op: .emitReceipt,
                      receiptFields: ["task", "artifact"]),
                .init(id: "escalate", op: .escalate,
                      reason: "release_failed", owner: "release_approver"),
            ]
        )
    }

    private func object(
        _ value: SMLValue?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> SMLObject {
        guard case .object(let object)? = value else {
            XCTFail("expected SML object", file: file, line: line)
            return [:]
        }
        return object
    }

    private func array(
        _ value: SMLValue?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [SMLValue] {
        guard case .array(let array)? = value else {
            XCTFail("expected SML array", file: file, line: line)
            return []
        }
        return array
    }

    private func string(
        _ value: SMLValue?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        guard case .string(let string)? = value else {
            XCTFail("expected SML string", file: file, line: line)
            return ""
        }
        return string
    }
}
