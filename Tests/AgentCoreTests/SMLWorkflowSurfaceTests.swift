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

        let modelTool = surface.modelCommandTool()
        XCTAssertEqual(modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(modelTool.parameters.map(\.name), ["line"])
        XCTAssertFalse(modelTool.description.contains("approve TASK_ID"))
        XCTAssertFalse(modelTool.description.contains("rollback TASK_ID"))

        let api = SMLWorkflowAPICatalog(surface: surface)
        XCTAssertEqual(api.endpoints.count, 7)
        XCTAssertEqual(api.endpoints.first { $0.action == .start }?.bodyKind, .startTask)
        XCTAssertEqual(api.endpoints.first { $0.action == .approve }?.bodyKind, .expectedState)
        XCTAssertEqual(api.endpoints.first { $0.action == .start }?.bodyFields.map(\.name), ["target"])

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
        XCTAssertEqual(api.compiler.catalog.basePath, "/automation")
        XCTAssertEqual(modelAdapter.surface.workflowID, "content.release")
        XCTAssertEqual(modelAdapter.allowedActions, SMLWorkflowSurface.modelDefaultActions)
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
        XCTAssertEqual(
            decoded.onyx.skillTree.first { $0.id == "plan" }?.planning?.unitKind,
            .modelReasoning
        )
        XCTAssertEqual(
            decoded.api.endpoints.first { $0.action == .approve }?.bodyKind,
            .expectedState
        )
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
        XCTAssertEqual(registry.catalog.apiEndpoints.count, 14)
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
        XCTAssertEqual(decoded.planningManifest.workflowIDs, ["content.release"])
        XCTAssertEqual(decoded.planningManifest.workflows.map(\.entrypoint), ["plan"])
        XCTAssertEqual(
            decoded.planningManifest.toolIndex.map(\.reference),
            ["content.plan", "artifact_verified", "repository.write"]
        )
        XCTAssertEqual(
            decoded.planningManifest.approvalGates.map(\.instructionID),
            ["approval"]
        )
        XCTAssertEqual(decoded.apiBasePaths, ["/automation"])
        XCTAssertEqual(
            decoded.metadataEndpoints.map(\.pathTemplate),
            [
                "/automation/runtime/catalog",
                "/automation/runtime/export",
                "/automation/runtime/openapi",
                "/automation/runtime/planning",
                "/automation/runtime/model-router",
                "/automation/runtime/onyx-drivers",
            ]
        )
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
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
        XCTAssertEqual(export.modelTools.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(export.modelTools.map(\.tool.name), [
            SMLWorkflowModelAdapter.toolName,
            SMLWorkflowModelAdapter.toolName,
        ])
        XCTAssertTrue(export.modelRouter.requiresNativeTools)
        XCTAssertEqual(export.modelRouter.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.modelRouter.tool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.modelRouter.tool.parameters.map(\.name), ["workflow_id", "line"])
        XCTAssertEqual(export.modelRouter.maximumCommandRounds, 4)
        XCTAssertEqual(export.onyxDrivers.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(export.planning.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(export.planning.workflows.map(\.workflowID), ["content.release", "content.review"])
        XCTAssertEqual(export.planning.workflows.map(\.entrypoint), ["plan", "plan"])
        XCTAssertEqual(export.planning.toolIndex.count, 6)
        XCTAssertEqual(export.planning.decomposableUnits, [])
        XCTAssertEqual(
            export.planning.approvalGates.map { "\($0.workflowID):\($0.instructionID)" },
            ["content.release:approval", "content.review:approval"]
        )

        let info = try object(export.openAPI["info"])
        XCTAssertEqual(info["title"], .string("Automation"))
        XCTAssertEqual(info["version"], .string("2026.08"))

        let paths = try object(export.openAPI["paths"])
        let runtimePlanningPath = try object(paths["/automation/runtime/planning"])
        let runtimePlanning = try object(runtimePlanningPath["get"])
        XCTAssertEqual(
            runtimePlanning["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.planning.operationID)
        )
        XCTAssertEqual(runtimePlanning["x-sml-runtime-resource"], .string("planning"))
        XCTAssertEqual(runtimePlanning["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimePlanning["x-sml-authority"], .string("descriptor-only"))

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

        let startPath = try object(paths["/automation/workflows/content.release/tasks"])
        let start = try object(startPath["post"])
        XCTAssertEqual(start["operationId"], .string("start_workflow_task_ContentRelease"))
        let requestBody = try object(start["requestBody"])
        XCTAssertEqual(requestBody["required"], .bool(true))

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
        let metadataEndpoints = try array(runtime["metadataEndpoints"])
        XCTAssertEqual(metadataEndpoints.count, 6)
        let metadataPlanningEndpoint = try object(metadataEndpoints[3])
        XCTAssertEqual(metadataPlanningEndpoint["pathTemplate"], .string("/automation/runtime/planning"))
        XCTAssertEqual(metadataPlanningEndpoint["resource"], .string("planning"))
        XCTAssertEqual(
            runtime["planningManifestSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimePlanningManifest.currentSchemaVersion))
        )
        XCTAssertEqual(
            try array(runtime["planningWorkflowIDs"]),
            [.string("content.release"), .string("content.review")]
        )
        XCTAssertEqual(try array(runtime["planningToolIndex"]).count, 6)
        XCTAssertEqual(try array(runtime["planningDecomposableUnits"]), [])
        XCTAssertEqual(try array(runtime["planningApprovalGates"]).count, 2)

        let data = try JSONEncoder().encode(export)
        let decoded = try JSONDecoder().decode(SMLWorkflowRuntimeExport.self, from: data)
        let encoded = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(decoded, export)
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
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
        XCTAssertEqual(app.metadataEndpoints.count, 6)
        XCTAssertEqual(app.runtimeAPI.catalog.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(app.runtimeAPI.metadataEndpoints.map(\.resource), [
            .catalog, .export, .openAPI, .planning, .modelRouter, .onyxDrivers,
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

        let started = try await app.handleAPI(
            SMLWorkflowAPIRequest(
                method: .post,
                path: "/automation/workflows/content.review/tasks",
                body: [
                    "task_id": .string("TASK-APP"),
                    "input": .object(["target": .string("app-review.md")]),
                ]
            )
        )
        XCTAssertEqual(started.statusCode, 201)
        XCTAssertEqual(started.command.op, SMLRuntimeCommandOperation.workflowRun)
        XCTAssertEqual(started.result.task?.workflowID, "content.review")

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
        XCTAssertEqual(try array(planningBody["toolIndex"]).count, 6)

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
}
