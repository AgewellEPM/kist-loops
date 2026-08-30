import XCTest
@testable import AgentCore

final class SMLWorkflowSourceImporterTests: XCTestCase {
    func testLangGraphManifestImportsLaunchesAndExposesRuntimeSurfaces() async throws {
        let manifest = langGraphReviewManifest()

        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: manifest)

        XCTAssertEqual(workflow.id, "langgraph.review")
        XCTAssertEqual(workflow.source.kind, .langGraph)
        XCTAssertEqual(workflow.source.reference, "graphs/review.py")
        XCTAssertEqual(workflow.source.digest, String(repeating: "a", count: 64))
        XCTAssertEqual(workflow.instructions.map(\.op), [.callModel, .callTool, .emitReceipt])
        XCTAssertEqual(workflow.interface.inputFields, ["topic"])
        XCTAssertEqual(workflow.interface.outputFields, ["draft"])

        let catalog = SMLExecutionAdmissionCatalog(
            toolCapabilities: ["repository.write"],
            modelPurposes: ["review.plan"],
            modelOutputSchemas: ["review.plan.v1"]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-source-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 4_400 }
        )
        let runtime = SMLRuntime(store: store, clock: { 4_400 })
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = {
            command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "source-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }

        let sourceMount = SMLWorkflowRuntimeSourceMount(
            document: .langGraphManifest(manifest),
            admissionCatalog: catalog,
            role: "reviewer",
            actor: "operator.luke",
            apiBasePath: "/source"
        )
        let launch = try await SMLWorkflowRuntimeApp.launch(
            sourceMounts: [sourceMount],
            runtime: runtime,
            replayGuard: store,
            authorityResolver: authority,
            commandID: { "source-command" },
            taskID: { "TASK-SOURCE-GENERATED" },
            clock: { 4_400 }
        )

        XCTAssertEqual(launch.installedWorkflows.map(\.id), ["langgraph.review"])
        XCTAssertEqual(launch.sourcePackage?.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(launch.launchDescriptor.sourceSummaries.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(launch.launchDescriptor.hostWiring, launch.hostWiring)
        XCTAssertEqual(launch.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(
            launch.launchDescriptor.sourcePackageSchemaVersion,
            SMLWorkflowRuntimeSourcePackage.currentSchemaVersion
        )
        XCTAssertTrue(launch.launchDescriptor.launchComplete)
        let encodedLaunchDescriptor = String(
            decoding: try JSONEncoder().encode(launch.launchDescriptor),
            as: UTF8.self
        )
        XCTAssertFalse(encodedLaunchDescriptor.contains("operator.luke"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("source-lease"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("authenticatedActor"))
        XCTAssertEqual(launch.mountContract.workflowMounts.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(
            try launch.app.resolveWorkflowMount(workflowID: "langgraph.review").apiRoutes.count,
            7
        )

        let started = try await launch.app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/source/workflows/langgraph.review/tasks",
                body: [
                    "task_id": .string("TASK-SOURCE"),
                    "input": .object(["topic": .string("release")]),
                ]
            )
        )
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertEqual(started.kind, .workflow)
        XCTAssertEqual(started.route?.operationID, "start_workflow_task_LanggraphReview")
        XCTAssertEqual(started.command?.role, "reviewer")
        XCTAssertEqual(started.result?.task?.workflowID, "langgraph.review")
    }

    func testLangGraphManifestImportsSeparateEdgesIntoPlanningAndOnyx() throws {
        let manifest = langGraphReviewEdgeManifest()
        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: manifest)

        XCTAssertEqual(workflow.instructions.first { $0.id == "plan" }?.next, "write")
        XCTAssertEqual(workflow.instructions.first { $0.id == "write" }?.next, "receipt")
        XCTAssertNil(workflow.instructions.first { $0.id == "receipt" }?.next)

        let registry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(manifest),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke",
                    apiBasePath: "/source"
                ),
            ],
            commandID: { "edge-command" },
            taskID: { "TASK-EDGE-GENERATED" }
        )
        let descriptor = try registry.descriptor(workflowID: "langgraph.review")
        XCTAssertTrue(descriptor.graphSummary.contains("plan CALL_MODEL [review.plan] -> write"))
        XCTAssertEqual(descriptor.api.basePath, "/source")

        let planNode = try XCTUnwrap(
            try registry.onyxDriver(workflowID: "langgraph.review")
                .plan.nodes.first { $0.id == "plan" }
        )
        XCTAssertEqual(planNode.normalTarget, "write")
    }

    func testRuntimePackageWrapsSourceWorkflowAndAllGeneratedSurfaces() throws {
        let package = try reviewSourcePackage()

        XCTAssertEqual(package.schemaVersion, SMLWorkflowRuntimeSourcePackage.currentSchemaVersion)
        XCTAssertEqual(package.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(package.normalizedWorkflows.map(\.source.kind), [.langGraph])
        XCTAssertEqual(package.runtime.catalog.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(package.runtime.mountContract.workflowMounts.map(\.workflowID), [
            "langgraph.review",
        ])
        XCTAssertEqual(package.runtime.mountContract.workflowMounts.map(\.apiRoutes.count), [7])
        XCTAssertEqual(package.runtime.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(package.runtime.modelRouter.workflowIDs, ["langgraph.review"])
        XCTAssertTrue(package.runtime.modelRouter.examples.contains {
            $0.workflowID == "langgraph.review"
                && $0.arguments == [
                    "workflow_id": .string("langgraph.review"),
                    "line": .string(#"start TASK-ID {"topic":"topic"}"#),
                ]
        })
        XCTAssertEqual(package.runtime.onyxDrivers.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(package.runtime.onyxDrivers.first?.plan.entrypoint, "plan")
        XCTAssertEqual(package.runtime.planning.workflowIDs, ["langgraph.review"])
        let sourceReplMount = try XCTUnwrap(package.runtime.mountContract.replMounts.first)
        XCTAssertEqual(sourceReplMount.commands.first { $0.verb == "start" }?.jsonBodyKind, .workflowInput)
        XCTAssertEqual(sourceReplMount.commands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertTrue(sourceReplMount.examples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertEqual(package.runtime.agentGuide.workflowGuides.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(package.runtime.hostGuide.workflowBindings.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(package.runtime.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(package.runtime.hostWiring.apiBasePaths, ["/source"])
        let workflowWiring = try XCTUnwrap(package.runtime.hostWiring.workflows.first)
        XCTAssertEqual(workflowWiring.apiRoutes.count, 7)
        let workflowStartRoute = try XCTUnwrap(workflowWiring.apiRoutes.first {
            $0.action == .start
        })
        XCTAssertEqual(
            workflowStartRoute.examples.first?.body["input"],
            .object(["topic": .string("topic")])
        )
        XCTAssertEqual(workflowWiring.replMount.commands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertTrue(workflowWiring.replMount.examples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertEqual(workflowWiring.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(
            Set(workflowWiring.hostBindings.map(\.channel)),
            Set([
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow,
            ])
        )
        XCTAssertTrue(workflowWiring.hostBindings.contains {
            $0.channel == .customAPI
                && $0.apiExamples.contains {
                    $0.path == "/source/workflows/langgraph.review/tasks"
                        && $0.body["input"] == .object(["topic": .string("topic")])
                }
        })
        XCTAssertTrue(workflowWiring.hostBindings.contains {
            $0.channel == .modelRouter
                && $0.modelToolExamples.contains {
                    $0.arguments == [
                        "workflow_id": .string("langgraph.review"),
                        "line": .string(#"start TASK-ID {"topic":"topic"}"#),
                    ]
                }
        })
        XCTAssertEqual(workflowWiring.attachment.workflowID, "langgraph.review")
        XCTAssertEqual(workflowWiring.attachment.apiBasePath, "/source")
        XCTAssertEqual(workflowWiring.attachment.plannerEntrypoint, "plan")
        XCTAssertTrue(workflowWiring.attachment.replExamples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertTrue(workflowWiring.attachment.apiExamples.contains {
            $0.path == "/source/workflows/langgraph.review/tasks"
                && $0.body["input"] == .object(["topic": .string("topic")])
        })
        XCTAssertTrue(workflowWiring.attachment.modelRouterExamples.contains {
            $0.arguments == [
                "workflow_id": .string("langgraph.review"),
                "line": .string(#"start TASK-ID {"topic":"topic"}"#),
            ]
        })
        XCTAssertEqual(package.runtime.hostGuide.launchSteps.map(\.id), [
            "decode_source_package",
            "fresh_host_admission",
            "launch_runtime_app",
            "serve_descriptor_metadata",
            "route_repl_and_api",
            "attach_model_router",
            "attach_onyx_and_planning",
        ])
        XCTAssertEqual(package.runtime.hostGuide.hostBindingCount, 7)
        XCTAssertTrue(
            package.runtime.agentGuide.systemPrompt.contains(
                "Break work into small contextual workflow steps"
            )
        )
        let agentWorkflow = try XCTUnwrap(package.runtime.agentGuide.workflowGuides.first)
        XCTAssertEqual(agentWorkflow.replCommands.first { $0.verb == "start" }?.jsonBodyKind, .workflowInput)
        XCTAssertEqual(agentWorkflow.replCommands.first { $0.verb == "start" }?.jsonFields.map(\.name), ["topic"])
        XCTAssertTrue(agentWorkflow.replExamples.contains {
            $0.line == #"start TASK-ID {"topic":"topic"}"#
        })
        XCTAssertTrue(package.runtime.agentGuide.systemPrompt.contains("Structured REPL commands:"))
        XCTAssertTrue(package.runtime.agentGuide.systemPrompt.contains("json:workflow_input fields:topic"))
        XCTAssertEqual(
            package.runtime.agentGuide.modelRouterTool.name,
            SMLWorkflowRuntimeModelAdapter.toolName
        )

        let summary = try XCTUnwrap(package.sourceSummaries.first)
        XCTAssertEqual(summary.workflowID, "langgraph.review")
        XCTAssertEqual(summary.sourceKind, .langGraph)
        XCTAssertEqual(summary.sourceReference, "graphs/review.py")
        XCTAssertEqual(summary.apiBasePath, "/source")
        XCTAssertEqual(summary.apiWorkflowPath, "/workflows/langgraph.review")
        XCTAssertTrue(summary.apiRoutePaths.contains("/source/workflows/langgraph.review/tasks"))
        XCTAssertTrue(
            summary.apiRoutePaths.contains(
                "/source/workflows/langgraph.review/tasks/{task_id}"
            )
        )
        XCTAssertEqual(
            summary.runtimeWorkflowAttachmentPath,
            "/source/runtime/attachments/langgraph.review"
        )
        XCTAssertEqual(
            summary.runtimeWorkflowREPLMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            summary.runtimeWorkflowAPIMountPath,
            "/source/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            summary.runtimeWorkflowModelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            summary.runtimeWorkflowOnyxDriverPath,
            "/source/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            summary.runtimeWorkflowSkillTreePath,
            "/source/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(
            summary.runtimeWorkflowToolBindingsPath,
            "/source/runtime/tool-bindings/langgraph.review"
        )
        XCTAssertEqual(
            summary.runtimeWorkflowPlanningPath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(summary.workflowMetadata.workflowID, "langgraph.review")
        XCTAssertEqual(summary.workflowMetadata.workflowVersion, "1.0.0")
        XCTAssertEqual(summary.workflowMetadata.attachmentPath, summary.runtimeWorkflowAttachmentPath)
        XCTAssertEqual(summary.workflowMetadata.replMountPath, summary.runtimeWorkflowREPLMountPath)
        XCTAssertEqual(summary.workflowMetadata.apiMountPath, summary.runtimeWorkflowAPIMountPath)
        XCTAssertEqual(summary.workflowMetadata.modelToolPath, summary.runtimeWorkflowModelToolPath)
        XCTAssertEqual(summary.workflowMetadata.onyxDriverPath, summary.runtimeWorkflowOnyxDriverPath)
        XCTAssertEqual(summary.workflowMetadata.skillTreePath, summary.runtimeWorkflowSkillTreePath)
        XCTAssertEqual(summary.workflowMetadata.toolBindingsPath, summary.runtimeWorkflowToolBindingsPath)
        XCTAssertEqual(summary.workflowMetadata.planningBundlePath, summary.runtimeWorkflowPlanningPath)
        var legacySourceSummaryObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(summary)
            ) as? [String: Any]
        )
        legacySourceSummaryObject.removeValue(forKey: "workflowMetadata")
        let legacySourceSummaryData = try JSONSerialization.data(
            withJSONObject: legacySourceSummaryObject,
            options: [.sortedKeys]
        )
        let legacySourceSummary = try JSONDecoder().decode(
            SMLWorkflowRuntimeSourceSummary.self,
            from: legacySourceSummaryData
        )
        XCTAssertEqual(legacySourceSummary.workflowMetadata, summary.workflowMetadata)
        XCTAssertTrue(summary.replGrammar.contains("start [TASK_ID] [JSON_INPUT_OBJECT]"))
        XCTAssertEqual(summary.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(summary.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(summary.planningWorkflowID, "langgraph.review")

        let openAPIPaths = try object(package.runtime.openAPI["paths"])
        XCTAssertNotNil(openAPIPaths["/source/workflows/langgraph.review/tasks"])
        XCTAssertNotNil(openAPIPaths["/source/runtime/agent-guide"])
        XCTAssertNotNil(openAPIPaths["/source/runtime/host-guide"])
        XCTAssertNotNil(openAPIPaths["/source/runtime/host-wiring"])
        XCTAssertNotNil(openAPIPaths["/source/runtime/launch"])
        XCTAssertNotNil(openAPIPaths["/source/runtime/attachments"])
        XCTAssertNotNil(openAPIPaths["/source/runtime/model-router"])
        XCTAssertNotNil(openAPIPaths["/source/runtime/onyx-drivers"])
        let sourceStartPath = try object(openAPIPaths["/source/workflows/langgraph.review/tasks"])
        let sourceStart = try object(sourceStartPath["post"])
        guard case .array(let sourceStartExamples)? = sourceStart["x-sml-request-examples"] else {
            return XCTFail("expected request examples")
        }
        XCTAssertEqual(
            try object(try object(sourceStartExamples.first)["body"])["input"],
            .object(["topic": .string("topic")])
        )

        let encoded = try JSONEncoder().encode(package)
        let encodedString = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(encodedString.contains("\"agentGuide\""))
        XCTAssertTrue(encodedString.contains("\"hostGuide\""))
        XCTAssertTrue(encodedString.contains("\"hostWiring\""))
        XCTAssertFalse(encodedString.contains("operator.luke"))
        XCTAssertFalse(encodedString.contains("source-lease"))
        XCTAssertFalse(encodedString.contains("authenticatedActor"))
        XCTAssertFalse(encodedString.contains("\"toolCapabilities\""))
        XCTAssertFalse(encodedString.contains("\"modelPurposes\""))
        XCTAssertFalse(encodedString.contains("\"modelOutputSchemas\""))

        let decoded = try JSONDecoder().decode(SMLWorkflowRuntimeSourcePackage.self, from: encoded)
        XCTAssertEqual(decoded, package)
        XCTAssertEqual(decoded.sourceSummaries, package.sourceSummaries)
    }

    func testRuntimePackageLaunchesDecodedPackageIntoHostRuntime() async throws {
        let encoded = try JSONEncoder().encode(try reviewSourcePackage())
        let package = try JSONDecoder().decode(SMLWorkflowRuntimeSourcePackage.self, from: encoded)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-package-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 4_500 }
        )
        let runtime = SMLRuntime(store: store, clock: { 4_500 })
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = {
            command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "package-launch-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }

        let launch = try await SMLWorkflowRuntimeApp.launch(
            package: package,
            admissionCatalog: reviewCatalog(),
            actor: "operator.luke",
            runtime: runtime,
            replayGuard: store,
            authorityResolver: authority,
            commandID: { "package-launch-command" },
            taskID: { "TASK-PACKAGE-LAUNCH-GENERATED" },
            clock: { 4_500 }
        )

        XCTAssertEqual(launch.installedWorkflows.map(\.id), ["langgraph.review"])
        XCTAssertEqual(launch.sourcePackage, package)
        let launchDescriptor = launch.launchDescriptor
        XCTAssertEqual(
            launchDescriptor.sourcePackageSchemaVersion,
            SMLWorkflowRuntimeSourcePackage.currentSchemaVersion
        )
        XCTAssertEqual(
            launchDescriptor.runtimeExportSchemaVersion,
            SMLWorkflowRuntimeExport.currentSchemaVersion
        )
        XCTAssertEqual(launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(launchDescriptor.installedWorkflowIDs, ["langgraph.review"])
        XCTAssertTrue(launchDescriptor.missingInstalledWorkflowIDs.isEmpty)
        XCTAssertTrue(launchDescriptor.unexpectedInstalledWorkflowIDs.isEmpty)
        XCTAssertTrue(launchDescriptor.launchComplete)
        XCTAssertEqual(launch.app.launchDescriptor, launchDescriptor)
        XCTAssertEqual(launch.app.runtimeAPI.launchDescriptor, launchDescriptor)
        XCTAssertEqual(launchDescriptor.sourceSummaries.map(\.workflowID), ["langgraph.review"])
        XCTAssertEqual(launchDescriptor.sourceSummaries.first?.sourceKind, .langGraph)
        XCTAssertEqual(launchDescriptor.sourceSummaries.first?.apiBasePath, "/source")
        XCTAssertTrue(
            try XCTUnwrap(launchDescriptor.sourceSummaries.first)
                .apiRoutePaths.contains("/source/workflows/langgraph.review/tasks")
        )
        XCTAssertEqual(
            launchDescriptor.sourceSummaries.first?.runtimeWorkflowREPLMountPath,
            "/source/runtime/repl-mounts/langgraph.review"
        )
        XCTAssertEqual(
            launchDescriptor.sourceSummaries.first?.runtimeWorkflowModelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(
            launchDescriptor.sourceSummaries.first?.runtimeWorkflowPlanningPath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(
            launchDescriptor.sourceSummaries.first?.workflowMetadata.planningBundlePath,
            "/source/runtime/planning/langgraph.review"
        )
        XCTAssertEqual(
            launchDescriptor.sourceSummaries.first?.workflowMetadata.modelToolPath,
            "/source/runtime/model-tools/langgraph.review"
        )
        XCTAssertEqual(launchDescriptor.hostWiring, launch.hostWiring)
        XCTAssertEqual(launchDescriptor.hostWiring.workflows.map(\.workflowID), ["langgraph.review"])
        let launchedWorkflow = try XCTUnwrap(launchDescriptor.workflows.first)
        XCTAssertTrue(launchedWorkflow.installed)
        XCTAssertEqual(launchedWorkflow.installedInstructionCount, 3)
        XCTAssertEqual(launchedWorkflow.replMount.workflowID, "langgraph.review")
        XCTAssertEqual(launchedWorkflow.apiRoutes.count, 7)
        XCTAssertEqual(launchedWorkflow.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(launchedWorkflow.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(launchedWorkflow.planningWorkflowID, "langgraph.review")
        XCTAssertEqual(Set(launchedWorkflow.hostBindingChannels), [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow,
        ])
        let encodedLaunchDescriptor = String(
            decoding: try JSONEncoder().encode(launchDescriptor),
            as: UTF8.self
        )
        XCTAssertFalse(encodedLaunchDescriptor.contains("operator.luke"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("package-launch-lease"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("authenticatedActor"))

        let mount = try launch.app.resolveWorkflowMount(workflowID: "langgraph.review")
        XCTAssertEqual(mount.role, "reviewer")
        XCTAssertEqual(mount.apiBasePath, "/source")
        XCTAssertEqual(mount.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(mount.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(try launch.app.onyxDriver(workflowID: "langgraph.review").plan.entrypoint, "plan")
        XCTAssertEqual(launch.app.planningManifest.workflowIDs, ["langgraph.review"])

        let started = try await launch.app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/source/workflows/langgraph.review/tasks",
                body: [
                    "task_id": .string("TASK-PACKAGE-LAUNCH"),
                    "input": .object(["topic": .string("release")]),
                ]
            )
        )
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertEqual(started.command?.actor, "operator.luke")
        XCTAssertEqual(started.command?.role, "reviewer")
        XCTAssertEqual(started.result?.task?.workflowID, "langgraph.review")
    }

    func testRuntimePackageLaunchDescriptorUsesLiveHostOverridesForSourceSummaries() async throws {
        let package = try reviewSourcePackage()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-package-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SMLRuntimeStore(
            fileURL: directory.appendingPathComponent("runtime.json"),
            clock: { 4_600 }
        )
        let runtime = SMLRuntime(store: store, clock: { 4_600 })
        let authority: @Sendable (SMLCommandEnvelope) async throws -> SMLCommandAuthority = {
            command in
            SMLCommandAuthority(
                authenticatedActor: "operator.luke",
                leaseID: "package-override-lease",
                roles: [command.role],
                tasks: [command.task],
                operations: [command.op],
                scope: command.scope
            )
        }

        let launch = try await SMLWorkflowRuntimeApp.launch(
            package: package,
            admissionCatalog: reviewCatalog(),
            actor: "operator.luke",
            runtime: runtime,
            replayGuard: store,
            authorityResolver: authority,
            roleOverride: "override-reviewer",
            apiBasePathOverride: "/override",
            apiWorkflowPathOverrides: ["langgraph.review": "/retargeted-review"],
            modelMaximumCommandRoundsOverride: 2,
            commandID: { "package-override-command" },
            taskID: { "TASK-PACKAGE-OVERRIDE-GENERATED" },
            clock: { 4_600 }
        )

        let launchDescriptor = launch.launchDescriptor
        XCTAssertEqual(launch.sourcePackage, package)
        XCTAssertEqual(launchDescriptor.workflowIDs, ["langgraph.review"])
        XCTAssertEqual(launchDescriptor.installedWorkflowIDs, ["langgraph.review"])
        XCTAssertTrue(launchDescriptor.launchComplete)
        XCTAssertEqual(launchDescriptor.apiBasePaths, ["/override"])
        XCTAssertEqual(launchDescriptor.sourceSummaries.map(\.apiBasePath), ["/override"])
        XCTAssertEqual(launchDescriptor.sourceSummaries.map(\.apiWorkflowPath), ["/retargeted-review"])
        let sourceSummary = try XCTUnwrap(launchDescriptor.sourceSummaries.first)
        XCTAssertTrue(sourceSummary.apiRoutePaths.contains("/override/retargeted-review/tasks"))
        XCTAssertFalse(
            sourceSummary.apiRoutePaths.contains("/source/workflows/langgraph.review/tasks")
        )
        XCTAssertEqual(
            sourceSummary.runtimeWorkflowAPIMountPath,
            "/override/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            sourceSummary.runtimeWorkflowOnyxDriverPath,
            "/override/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            sourceSummary.runtimeWorkflowSkillTreePath,
            "/override/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(
            sourceSummary.workflowMetadata.apiMountPath,
            "/override/runtime/api-mounts/langgraph.review"
        )
        XCTAssertEqual(
            sourceSummary.workflowMetadata.onyxDriverPath,
            "/override/runtime/onyx-drivers/langgraph.review"
        )
        XCTAssertEqual(
            sourceSummary.workflowMetadata.skillTreePath,
            "/override/runtime/skill-trees/langgraph.review"
        )
        XCTAssertEqual(launchDescriptor.hostWiring, launch.hostWiring)
        XCTAssertEqual(launchDescriptor.hostWiring.apiBasePaths, ["/override"])

        let launchedWorkflow = try XCTUnwrap(launchDescriptor.workflows.first)
        XCTAssertEqual(launchedWorkflow.role, "override-reviewer")
        XCTAssertEqual(launchedWorkflow.apiBasePath, "/override")
        XCTAssertEqual(launchedWorkflow.apiWorkflowPath, "/retargeted-review")
        XCTAssertEqual(launchedWorkflow.replMount.apiBasePath, "/override")
        XCTAssertEqual(launchedWorkflow.replMount.apiWorkflowPath, "/retargeted-review")
        XCTAssertEqual(launchedWorkflow.installedInstructionCount, 3)
        XCTAssertEqual(launchDescriptor.modelRouter.maximumCommandRounds, 2)
        let hostWiringWorkflow = try XCTUnwrap(launchDescriptor.hostWiring.workflows.first)
        XCTAssertEqual(hostWiringWorkflow.role, "override-reviewer")
        XCTAssertEqual(hostWiringWorkflow.apiBasePath, "/override")
        XCTAssertEqual(hostWiringWorkflow.apiWorkflowPath, "/retargeted-review")
        XCTAssertEqual(hostWiringWorkflow.attachment.apiWorkflowPath, "/retargeted-review")
        XCTAssertEqual(hostWiringWorkflow.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        let mount = try launch.app.resolveWorkflowMount(workflowID: "langgraph.review")
        XCTAssertEqual(mount.apiBasePath, "/override")
        XCTAssertEqual(mount.apiWorkflowPath, "/retargeted-review")
        let openAPIPaths = try object(launch.export().openAPI["paths"])
        XCTAssertNotNil(openAPIPaths["/override/retargeted-review/tasks"])
        XCTAssertNil(openAPIPaths["/override/workflows/langgraph.review/tasks"])
        XCTAssertNil(openAPIPaths["/source/workflows/langgraph.review/tasks"])

        let started = try await launch.app.handleRuntimeAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/override/retargeted-review/tasks",
                body: [
                    "task_id": .string("TASK-PACKAGE-OVERRIDE"),
                    "input": .object(["topic": .string("retargeted")]),
                ]
            )
        )
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertEqual(started.result?.task?.workflowID, "langgraph.review")
        XCTAssertEqual(started.route?.pathTemplate, "/override/retargeted-review/tasks")

        let encodedLaunchDescriptor = String(
            decoding: try JSONEncoder().encode(launchDescriptor),
            as: UTF8.self
        )
        XCTAssertFalse(encodedLaunchDescriptor.contains("operator.luke"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("package-override-lease"))
        XCTAssertFalse(encodedLaunchDescriptor.contains("authenticatedActor"))

        XCTAssertThrowsError(
            try SMLWorkflowRuntimeRegistry.compile(
                package: package,
                admissionCatalog: reviewCatalog(),
                actor: "operator.luke",
                apiWorkflowPathOverrides: ["missing.workflow": "/missing"]
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeSourcePackageError,
                .unknownAPIWorkflowPathOverride("missing.workflow")
            )
        }
    }

    func testRuntimePackageRelaunchFailsClosedWithoutFreshHostAdmissionCatalog() throws {
        let package = try reviewSourcePackage()

        XCTAssertThrowsError(
            try SMLWorkflowRuntimeRegistry.compile(
                package: package,
                admissionCatalog: SMLExecutionAdmissionCatalog(),
                actor: "operator.luke"
            )
        ) {
            guard let error = $0 as? SMLWorkflowAdmissionError else {
                return XCTFail("expected workflow admission failure, got \($0)")
            }
            XCTAssertTrue(
                error.diagnostics.contains { $0.code == "unregistered_model_purpose" }
            )
            XCTAssertTrue(
                error.diagnostics.contains { $0.code == "unregistered_output_schema" }
            )
            XCTAssertTrue(
                error.diagnostics.contains { $0.code == "unregistered_tool" }
            )
        }
    }

    func testRuntimePackageFailsClosedWhenSourceAndRuntimeExportDisagree() throws {
        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: langGraphReviewManifest())
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke"
                ),
            ]
        )
        let wrongWorkflow = SMLWorkflow(
            id: "langgraph.other",
            version: workflow.version,
            name: "Different source workflow",
            source: workflow.source,
            trigger: workflow.trigger,
            stateSchema: workflow.stateSchema,
            interface: workflow.interface,
            entrypoint: workflow.entrypoint,
            instructions: workflow.instructions
        )

        XCTAssertThrowsError(
            try SMLWorkflowRuntimeSourcePackage(
                normalizedWorkflows: [wrongWorkflow],
                runtime: registry.export()
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeSourcePackageError,
                .runtimeExportMismatch(
                    field: "runtime.catalog.workflowIDs",
                    expected: ["langgraph.other"],
                    actual: ["langgraph.review"]
                )
            )
        }
    }

    func testRuntimePackageFailsClosedWhenSameWorkflowIDHasDifferentRuntimeVersion() throws {
        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: langGraphReviewManifest())
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke"
                ),
            ]
        )
        let wrongVersion = SMLWorkflow(
            id: workflow.id,
            version: "2.0.0",
            name: workflow.name,
            source: workflow.source,
            trigger: workflow.trigger,
            stateSchema: workflow.stateSchema,
            interface: workflow.interface,
            entrypoint: workflow.entrypoint,
            instructions: workflow.instructions
        )

        XCTAssertThrowsError(
            try SMLWorkflowRuntimeSourcePackage(
                normalizedWorkflows: [wrongVersion],
                runtime: registry.export()
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeSourcePackageError,
                .runtimeWorkflowMismatch(
                    workflowID: "langgraph.review",
                    field: "runtime.catalog.workflowVersion",
                    expected: "2.0.0",
                    actual: "1.0.0"
                )
            )
        }
    }

    func testRuntimePackageFailsClosedWhenNormalizedSourceGraphDriftsFromRuntimeDescriptor() throws {
        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: langGraphReviewManifest())
        let plan = try XCTUnwrap(workflow.instructions.first { $0.id == "plan" })
        let receipt = try XCTUnwrap(workflow.instructions.first { $0.id == "receipt" })
        let graphDriftWorkflow = SMLWorkflow(
            id: workflow.id,
            version: workflow.version,
            name: workflow.name,
            source: workflow.source,
            trigger: workflow.trigger,
            stateSchema: workflow.stateSchema,
            interface: workflow.interface,
            entrypoint: workflow.entrypoint,
            instructions: [
                SMLInstruction(
                    id: plan.id,
                    op: plan.op,
                    purpose: plan.purpose,
                    outputSchema: plan.outputSchema,
                    next: receipt.id
                ),
                receipt,
            ]
        )
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke"
                ),
            ]
        )

        XCTAssertThrowsError(
            try SMLWorkflowRuntimeSourcePackage(
                normalizedWorkflows: [graphDriftWorkflow],
                runtime: registry.export()
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeSourcePackageError,
                .runtimeSourceDescriptorMismatch(workflowID: "langgraph.review")
            )
        }
    }

    func testRuntimePackageFailsClosedWhenSerializedGuidesDisagreeWithCatalog() throws {
        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: langGraphReviewManifest())
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke",
                    apiBasePath: "/source"
                ),
            ]
        )
        let driftedRegistry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke",
                    apiBasePath: "/drifted"
                ),
            ]
        )
        let runtime = registry.export()

        let wrongAgentGuideRuntime = SMLWorkflowRuntimeExport(
            schemaVersion: runtime.schemaVersion,
            catalog: runtime.catalog,
            mountContract: runtime.mountContract,
            openAPI: runtime.openAPI,
            modelTools: runtime.modelTools,
            modelRouter: runtime.modelRouter,
            onyxDrivers: runtime.onyxDrivers,
            planning: runtime.planning,
            agentGuide: driftedRegistry.catalog.agentGuide,
            hostGuide: runtime.hostGuide
        )
        XCTAssertThrowsError(
            try SMLWorkflowRuntimeSourcePackage(
                normalizedWorkflows: [workflow],
                runtime: wrongAgentGuideRuntime
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeSourcePackageError,
                .runtimeDerivedPayloadMismatch(field: "runtime.agentGuide")
            )
        }

        let wrongHostGuideRuntime = SMLWorkflowRuntimeExport(
            schemaVersion: runtime.schemaVersion,
            catalog: runtime.catalog,
            mountContract: runtime.mountContract,
            openAPI: runtime.openAPI,
            modelTools: runtime.modelTools,
            modelRouter: runtime.modelRouter,
            onyxDrivers: runtime.onyxDrivers,
            planning: runtime.planning,
            agentGuide: runtime.agentGuide,
            hostGuide: driftedRegistry.catalog.hostGuide
        )
        XCTAssertThrowsError(
            try SMLWorkflowRuntimeSourcePackage(
                normalizedWorkflows: [workflow],
                runtime: wrongHostGuideRuntime
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeSourcePackageError,
                .runtimeDerivedPayloadMismatch(field: "runtime.hostGuide")
            )
        }

        let wrongHostWiringRuntime = SMLWorkflowRuntimeExport(
            schemaVersion: runtime.schemaVersion,
            catalog: runtime.catalog,
            mountContract: runtime.mountContract,
            openAPI: runtime.openAPI,
            modelTools: runtime.modelTools,
            modelRouter: runtime.modelRouter,
            onyxDrivers: runtime.onyxDrivers,
            planning: runtime.planning,
            agentGuide: runtime.agentGuide,
            hostGuide: runtime.hostGuide,
            hostWiring: driftedRegistry.catalog.hostWiring
        )
        XCTAssertThrowsError(
            try SMLWorkflowRuntimeSourcePackage(
                normalizedWorkflows: [workflow],
                runtime: wrongHostWiringRuntime
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowRuntimeSourcePackageError,
                .runtimeDerivedPayloadMismatch(field: "runtime.hostWiring")
            )
        }
    }

    func testRuntimePackageFailsClosedWhenGeneratedRuntimePayloadsDisagreeWithCatalog() throws {
        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: langGraphReviewManifest())
        let registry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke",
                    apiBasePath: "/source"
                ),
            ]
        )
        let driftedPathRegistry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke",
                    apiBasePath: "/drifted"
                ),
            ]
        )
        let driftedRoundsRegistry = try SMLWorkflowRuntimeRegistry.compile(
            sourceMounts: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke",
                    apiBasePath: "/source",
                    modelMaximumCommandRounds: 2
                ),
            ]
        )
        let runtime = registry.export(title: "Source Runtime", version: "2026.08")
        let driftedPathRuntime = driftedPathRegistry.export(title: "Source Runtime", version: "2026.08")
        let driftedRoundsRuntime = driftedRoundsRegistry.export(title: "Source Runtime", version: "2026.08")

        func makeRuntime(
            mountContract: SMLWorkflowRuntimeMountContract? = nil,
            openAPI: SMLObject? = nil,
            modelTools: [SMLWorkflowRuntimeModelToolExport]? = nil,
            modelRouter: SMLWorkflowRuntimeModelRouterDescriptor? = nil,
            onyxDrivers: [SMLOnyxDriverManifest]? = nil,
            planning: SMLWorkflowRuntimePlanningManifest? = nil
        ) -> SMLWorkflowRuntimeExport {
            SMLWorkflowRuntimeExport(
                schemaVersion: runtime.schemaVersion,
                catalog: runtime.catalog,
                mountContract: mountContract ?? runtime.mountContract,
                openAPI: openAPI ?? runtime.openAPI,
                modelTools: modelTools ?? runtime.modelTools,
                modelRouter: modelRouter ?? runtime.modelRouter,
                onyxDrivers: onyxDrivers ?? runtime.onyxDrivers,
                planning: planning ?? runtime.planning,
                agentGuide: runtime.agentGuide,
                hostGuide: runtime.hostGuide,
                hostWiring: runtime.hostWiring
            )
        }

        let cases: [(field: String, runtime: SMLWorkflowRuntimeExport)] = [
            (
                "runtime.mountContract",
                makeRuntime(mountContract: driftedPathRuntime.mountContract)
            ),
            (
                "runtime.openAPI",
                makeRuntime(openAPI: driftedPathRuntime.openAPI)
            ),
            (
                "runtime.modelTools",
                makeRuntime(modelTools: driftedRoundsRuntime.modelTools)
            ),
            (
                "runtime.modelRouter",
                makeRuntime(modelRouter: driftedRoundsRuntime.modelRouter)
            ),
            (
                "runtime.onyxDrivers",
                makeRuntime(onyxDrivers: driftedPathRuntime.onyxDrivers)
            ),
            (
                "runtime.planning",
                makeRuntime(planning: driftedPathRuntime.planning)
            ),
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try SMLWorkflowRuntimeSourcePackage(
                    normalizedWorkflows: [workflow],
                    runtime: testCase.runtime
                ),
                "expected \(testCase.field) drift to fail closed"
            ) {
                XCTAssertEqual(
                    $0 as? SMLWorkflowRuntimeSourcePackageError,
                    .runtimeDerivedPayloadMismatch(field: testCase.field)
                )
            }
        }
    }

    func testLangGraphManifestImportsConditionalEdgesForBranchNodes() throws {
        let manifest = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.branch",
          "version": "1.0.0",
          "name": "LangGraph branch",
          "source_reference": "graphs/branch.py",
          "state_schema": [
            {"name":"approved","type":"boolean"}
          ],
          "input_fields": ["approved"],
          "output_fields": [],
          "entrypoint": "decide",
          "nodes": [
            {
              "id": "decide",
              "kind": "branch",
              "condition": {
                "clauses": [{"field":"approved","op":"equals","value":true}]
              }
            },
            {"id":"yes","kind":"complete"},
            {"id":"no","kind":"complete"}
          ],
          "conditional_edges": [
            {"from":"decide","true":"yes","false":"no"}
          ]
        }
        """)

        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: manifest)
        let decide = try XCTUnwrap(workflow.instructions.first { $0.id == "decide" })

        XCTAssertEqual(decide.trueTarget, "yes")
        XCTAssertEqual(decide.falseTarget, "no")
        XCTAssertNil(decide.next)
    }

    func testLangGraphEndEdgeGeneratesCompleteTerminalWhenNoOutputsAreDeclared() throws {
        let manifest = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.end",
          "version": "1.0.0",
          "name": "LangGraph end",
          "source_reference": "graphs/end.py",
          "state_schema": [],
          "input_fields": [],
          "output_fields": [],
          "entrypoint": "plan",
          "nodes": [
            {
              "id": "plan",
              "kind": "model",
              "purpose": "review.plan",
              "output_schema": "review.plan.v1"
            }
          ],
          "edges": [
            {"from":"START","to":"plan"},
            {"from":"plan","to":"END"}
          ]
        }
        """)

        let workflow = try SMLWorkflowSourceImporter.langGraphWorkflow(from: manifest)

        XCTAssertEqual(workflow.instructions.map(\.id), ["plan", "__sml_end"])
        XCTAssertEqual(workflow.instructions.first { $0.id == "plan" }?.next, "__sml_end")
        XCTAssertEqual(workflow.instructions.first { $0.id == "__sml_end" }?.op, .complete)
    }

    func testLangGraphManifestFailsClosedOnUnknownKeysAndRawPython() throws {
        let unknownRootKey = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.review",
          "version": "1.0.0",
          "name": "LangGraph review",
          "source_reference": "graphs/review.py",
          "state_schema": [],
          "input_fields": [],
          "output_fields": [],
          "entrypoint": "done",
          "nodes": [{"id":"done","kind":"complete"}],
          "python": "print('not allowed')"
        }
        """)

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(from: .langGraphManifest(unknownRootKey))
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .unknownKey(path: "$", key: "python")
            )
        }

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(
                from: .langGraphPython(
                    reference: "graphs/review.py",
                    source: Data("print('raw graph')".utf8)
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .unsupportedSource(
                    "raw LangGraph Python import requires an explicit langgraph_manifest; code is referenced and digested, not executed"
                )
            )
        }
    }

    func testLangGraphManifestFailsClosedOnConflictingEdgeTransitions() throws {
        let conflict = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.review",
          "version": "1.0.0",
          "name": "LangGraph review",
          "source_reference": "graphs/review.py",
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
            {"id":"write","kind":"tool","capability":"repository.write","next":"receipt"},
            {"id":"receipt","kind":"receipt","receipt_fields":["draft"]}
          ],
          "edges": [{"from":"plan","to":"receipt"}]
        }
        """)

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(from: .langGraphManifest(conflict))
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .invalidField(
                    path: "$.edges[0].to",
                    reason: "edge conflicts with existing next transition write"
                )
            )
        }
    }

    func testLangGraphManifestFailsClosedWhenEndEdgeWouldBypassDeclaredOutputs() throws {
        let unsafeEnd = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.unsafe_end",
          "version": "1.0.0",
          "name": "LangGraph unsafe end",
          "source_reference": "graphs/unsafe_end.py",
          "state_schema": [
            {"name":"draft","type":"string","required":false}
          ],
          "input_fields": [],
          "output_fields": ["draft"],
          "entrypoint": "plan",
          "nodes": [
            {
              "id": "plan",
              "kind": "model",
              "purpose": "review.plan",
              "output_schema": "review.plan.v1"
            }
          ],
          "edges": [{"from":"plan","to":"END"}]
        }
        """)

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(from: .langGraphManifest(unsafeEnd))
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .invalidField(
                    path: "$.edges[0].to",
                    reason: "END edge from non-terminal node requires an explicit receipt node when output_fields are declared"
                )
            )
        }
    }

    func testLangGraphManifestFailsClosedOnUnknownNodeKind() throws {
        let unknownKind = data("""
        {
          "manifest_version": 1,
          "id": "langgraph.review",
          "version": "1.0.0",
          "name": "LangGraph review",
          "source_reference": "graphs/review.py",
          "state_schema": [],
          "input_fields": [],
          "output_fields": [],
          "entrypoint": "shell",
          "nodes": [{"id":"shell","kind":"shell"}]
        }
        """)

        XCTAssertThrowsError(
            try SMLWorkflowSourceImporter.workflow(from: .langGraphManifest(unknownKind))
        ) {
            XCTAssertEqual(
                $0 as? SMLWorkflowSourceImportError,
                .invalidField(path: "$.nodes[0].kind", reason: "unknown LangGraph node kind shell")
            )
        }
    }

    private func langGraphReviewManifest() -> Data {
        data("""
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
        """)
    }

    private func langGraphReviewEdgeManifest() -> Data {
        data("""
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
              "output_schema": "review.plan.v1"
            },
            {
              "id": "write",
              "kind": "tool",
              "capability": "repository.write"
            },
            {
              "id": "receipt",
              "kind": "receipt",
              "receipt_fields": ["draft"]
            }
          ],
          "edges": [
            {"from":"START","to":"plan"},
            {"from":"plan","to":"write"},
            {"from":"write","to":"receipt"},
            {"from":"receipt","to":"END"}
          ]
        }
        """)
    }

    private func reviewCatalog() -> SMLExecutionAdmissionCatalog {
        SMLExecutionAdmissionCatalog(
            toolCapabilities: ["repository.write"],
            modelPurposes: ["review.plan"],
            modelOutputSchemas: ["review.plan.v1"]
        )
    }

    private func reviewSourcePackage() throws -> SMLWorkflowRuntimeSourcePackage {
        try SMLWorkflowSourceImporter.runtimePackage(
            from: [
                SMLWorkflowRuntimeSourceMount(
                    document: .langGraphManifest(langGraphReviewEdgeManifest()),
                    admissionCatalog: reviewCatalog(),
                    role: "reviewer",
                    actor: "operator.luke",
                    apiBasePath: "/source"
                ),
            ],
            title: "Source Runtime",
            version: "2026.08",
            commandID: { "package-command" },
            taskID: { "TASK-PACKAGE-GENERATED" }
        )
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
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
