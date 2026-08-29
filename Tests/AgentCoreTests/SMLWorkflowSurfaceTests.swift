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
                "api", "approve", "describe", "exit", "help", "model", "onyx",
                "planning", "receipts", "refuse", "rollback", "schema", "start", "watch",
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
        let replExamples = surface.replExamples()
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
        XCTAssertEqual(api.endpoints.count, 7)
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
        XCTAssertTrue(bundle.descriptor.repl.commands.contains {
            $0.verb == "start"
                && $0.jsonBodyKind == .workflowInput
                && $0.jsonFields.map(\.name) == ["target"]
        })
        XCTAssertTrue(bundle.descriptor.repl.examples.contains {
            $0.line == #"start TASK-ID {"target":"target"}"#
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
        XCTAssertTrue(help.output.contains("planning"))
        let apiInfo = try await replSession.submit("api")
        XCTAssertNil(apiInfo.command)
        XCTAssertTrue(apiInfo.output.contains("base path: /automation"))
        XCTAssertTrue(apiInfo.output.contains("POST /automation/workflows/content.release/tasks"))
        XCTAssertTrue(apiInfo.output.contains(#"{"input":{"target":"target"},"task_id":"TASK-ID"}"#))
        let modelInfo = try await replSession.submit("model")
        XCTAssertNil(modelInfo.command)
        XCTAssertTrue(modelInfo.output.contains(SMLWorkflowModelAdapter.toolName))
        XCTAssertTrue(modelInfo.output.contains(SMLWorkflowRuntimeModelAdapter.toolName))
        let onyxInfo = try await replSession.submit("onyx")
        XCTAssertNil(onyxInfo.command)
        XCTAssertTrue(onyxInfo.output.contains(bundle.onyxDriver.driverID))
        XCTAssertTrue(onyxInfo.output.contains("skill tree:"))
        let planningInfo = try await replSession.submit("planning")
        XCTAssertNil(planningInfo.command)
        XCTAssertTrue(planningInfo.output.contains("unit:model_reasoning"))
        XCTAssertTrue(planningInfo.output.contains("unit:external_capability"))
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

        XCTAssertEqual(
            try registry.route(
                for: SMLWorkflowAPIRequest(
                    method: .get,
                    path: "/automation/runtime/planning"
                )
            ),
            .metadata(.planning)
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
            7
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
            7
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
        XCTAssertEqual(launchDescriptor.metadataEndpoints.count, 10)
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
        XCTAssertEqual(reviewLaunch.apiRoutes.count, 7)
        XCTAssertEqual(reviewLaunch.modelToolName, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(reviewLaunch.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(reviewLaunch.planningWorkflowID, "content.review")
        XCTAssertEqual(Set(reviewLaunch.hostBindingChannels), [
            .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
            .onyxDriver, .planningWorkflow,
        ])

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
        XCTAssertEqual(mount.apiRoutes.count, 17)
        let startRoute = try XCTUnwrap(mount.apiRoutes.first {
            $0.workflowID == "content.release" && $0.action == .start
        })
        XCTAssertEqual(
            startRoute.examples.first?.body["input"],
            .object(["target": .string("target")])
        )
        XCTAssertEqual(mount.workflowMounts.map(\.workflowID), ["content.release"])
        XCTAssertEqual(mount.workflowMounts.first?.apiRoutes.count, 7)
        XCTAssertEqual(
            mount.workflowMounts.first?.repl.commands.first {
                $0.verb == "start"
            }?.jsonFields.map(\.name),
            ["target"]
        )
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
                "/automation/runtime/export",
                "/automation/runtime/openapi",
                "/automation/runtime/planning",
                "/automation/runtime/agent-guide",
                "/automation/runtime/host-guide",
                "/automation/runtime/host-wiring",
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
            .agentGuide, .catalog, .export, .hostGuide, .hostWiring, .modelRouter, .mount,
            .onyxDrivers, .openAPI, .planning,
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
        XCTAssertTrue(guide.systemPrompt.contains("Onyx driver"))
        XCTAssertTrue(guide.systemPrompt.contains("Planning units:"))

        let release = try XCTUnwrap(
            guide.workflowGuides.first { $0.workflowID == "content.release" }
        )
        XCTAssertEqual(release.apiBasePath, "/automation")
        XCTAssertEqual(release.apiRoutes.count, 7)
        XCTAssertEqual(release.modelTool.name, SMLWorkflowModelAdapter.toolName)
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
        XCTAssertEqual(release.planningToolIndex.map(\.reference), [
            "content.plan", "artifact_verified", "repository.write",
        ])
        XCTAssertEqual(release.approvalGates.map(\.instructionID), ["approval"])
        XCTAssertTrue(release.decomposableUnits.isEmpty)
        XCTAssertFalse(release.onyxDriverID.isEmpty)

        let encoded = String(decoding: try JSONEncoder().encode(guide), as: UTF8.self)
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
        XCTAssertTrue(encoded.contains("\"replCommands\""))
        XCTAssertTrue(encoded.contains("\"replExamples\""))

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
        }
        legacyObject["workflowGuides"] = legacyWorkflowGuides
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        let legacyGuide = try JSONDecoder().decode(SMLWorkflowRuntimeAgentGuide.self, from: legacyData)
        XCTAssertEqual(legacyGuide.schemaVersion, 1)
        XCTAssertEqual(legacyGuide.workflowGuides.map(\.replCommands), [[], []])
        XCTAssertEqual(legacyGuide.workflowGuides.map(\.replExamples), [[], []])
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
                .agentGuide, .catalog, .export, .hostGuide, .hostWiring, .modelRouter, .mount,
                .onyxDrivers, .openAPI, .planning,
            ]
        )
        XCTAssertEqual(guide.hostBindingCount, 14)

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
        XCTAssertEqual(release.apiRoutes.count, 7)
        XCTAssertEqual(release.modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(release.modelRouterToolName, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(release.planningWorkflowID, "content.release")
        XCTAssertEqual(release.plannerEntrypoint, "plan")
        XCTAssertEqual(release.toolReferences, [
            "artifact_verified", "content.plan", "repository.write",
        ])
        XCTAssertEqual(release.approvalGates.map(\.instructionID), ["approval"])
        XCTAssertEqual(
            Set(release.hostBindings.map(\.channel)),
            [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow,
            ]
        )
        let apiBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .customAPI }
        )
        XCTAssertEqual(apiBinding.authority, .hostCommandGateway)
        XCTAssertFalse(apiBinding.readOnly)
        XCTAssertTrue(apiBinding.pathTemplates.contains("/automation/workflows/content.release/tasks"))
        let onyxBinding = try XCTUnwrap(
            release.hostBindings.first { $0.channel == .onyxDriver }
        )
        XCTAssertEqual(onyxBinding.authority, .descriptorOnly)
        XCTAssertTrue(onyxBinding.readOnly)
        XCTAssertEqual(onyxBinding.driverID, release.onyxDriverID)
        XCTAssertTrue(onyxBinding.pathTemplates.contains("/automation/runtime/onyx-drivers"))

        let encoded = String(decoding: try JSONEncoder().encode(guide), as: UTF8.self)
        XCTAssertFalse(encoded.contains("operator.luke"))
        XCTAssertFalse(encoded.contains("leaseID"))
        XCTAssertFalse(encoded.contains("lease_id"))
        XCTAssertFalse(encoded.contains("authenticatedActor"))
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
        XCTAssertEqual(export.mountContract.apiRoutes.count, 24)
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.mountContract.workflowMounts.map(\.apiRoutes.count), [7, 7])
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
        XCTAssertEqual(export.agentGuide.workflowGuides.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.agentGuide.modelRouterTool.name, SMLWorkflowRuntimeModelAdapter.toolName)
        XCTAssertEqual(export.hostGuide.workflowBindings.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(export.hostGuide.hostBindingCount, 14)
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
        XCTAssertEqual(export.hostWiring.hostBindingCount, 14)
        XCTAssertEqual(export.hostWiring.workflows.map(\.apiRoutes.count), [7, 7])
        XCTAssertEqual(export.hostWiring.workflows.map(\.modelRouterToolName), [
            SMLWorkflowRuntimeModelAdapter.toolName,
            SMLWorkflowRuntimeModelAdapter.toolName,
        ])
        XCTAssertTrue(export.hostWiring.workflows.allSatisfy {
            Set($0.hostBindings.map(\.channel)) == [
                .agentGuide, .customAPI, .customREPL, .modelRouter, .modelTool,
                .onyxDriver, .planningWorkflow,
            ]
        })

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
        let runtimePlanningPath = try object(paths["/automation/runtime/planning"])
        let runtimePlanning = try object(runtimePlanningPath["get"])
        XCTAssertEqual(
            runtimePlanning["operationId"],
            .string(SMLWorkflowRuntimeMetadataResource.planning.operationID)
        )
        XCTAssertEqual(runtimePlanning["x-sml-runtime-resource"], .string("planning"))
        XCTAssertEqual(runtimePlanning["x-sml-read-only"], .bool(true))
        XCTAssertEqual(runtimePlanning["x-sml-authority"], .string("descriptor-only"))
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
        XCTAssertEqual(runtime["mountAPIRouteCount"], .number(24))
        XCTAssertEqual(runtime["mountREPLCount"], .number(2))
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
        XCTAssertEqual(metadataEndpoints.count, 10)
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
        XCTAssertEqual(
            runtime["agentGuideSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeAgentGuide.currentSchemaVersion))
        )
        XCTAssertEqual(runtime["agentGuideWorkflowCount"], .number(2))
        XCTAssertEqual(
            runtime["agentGuideModelRouterToolName"],
            .string(SMLWorkflowRuntimeModelAdapter.toolName)
        )
        XCTAssertEqual(
            runtime["hostGuideSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeHostGuide.currentSchemaVersion))
        )
        XCTAssertEqual(runtime["hostGuideWorkflowCount"], .number(2))
        XCTAssertEqual(runtime["hostGuideBindingCount"], .number(14))
        XCTAssertEqual(
            runtime["hostWiringSchemaVersion"],
            .number(Decimal(SMLWorkflowRuntimeHostWiring.currentSchemaVersion))
        )
        XCTAssertEqual(runtime["hostWiringWorkflowCount"], .number(2))
        XCTAssertEqual(runtime["hostWiringBindingCount"], .number(14))
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
        XCTAssertEqual(decoded.agentGuide, decoded.catalog.agentGuide)
        XCTAssertEqual(decoded.hostGuide, decoded.catalog.hostGuide)
        XCTAssertEqual(decoded.hostWiring, decoded.catalog.hostWiring)
        XCTAssertEqual(decoded.agentGuide.workflowGuides.map(\.workflowID), ["content.release"])
        XCTAssertEqual(decoded.hostGuide.workflowBindings.map(\.workflowID), ["content.release"])
        XCTAssertEqual(decoded.hostWiring.workflows.map(\.workflowID), ["content.release"])
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
        XCTAssertEqual(workflowMount.apiRoutes.count, 7)
        XCTAssertEqual(workflowMount.apiRoutes.map(\.handlerKind), Array(repeating: .workflow, count: 7))
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
        XCTAssertEqual(app.mountContract.apiRoutes.count, 24)
        XCTAssertEqual(app.mountContract.replMounts.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(app.metadataEndpoints.count, 10)
        XCTAssertEqual(app.runtimeAPI.catalog.workflowIDs, ["content.release", "content.review"])
        XCTAssertEqual(app.runtimeAPI.mountContract.apiRoutes.count, 24)
        XCTAssertEqual(app.hostWiring, registry.hostWiring)
        XCTAssertEqual(app.runtimeAPI.hostWiring, registry.hostWiring)
        XCTAssertEqual(app.hostWiring.workflows.map(\.workflowID), [
            "content.release", "content.review",
        ])
        XCTAssertEqual(app.runtimeAPI.metadataEndpoints.map(\.resource), [
            .catalog, .mount, .export, .openAPI, .planning, .agentGuide, .hostGuide,
            .hostWiring, .modelRouter, .onyxDrivers,
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
        XCTAssertEqual(try array(planningBody["toolIndex"]).count, 6)

        let mountMetadata = try app.handleMetadata(
            SMLWorkflowAPIRequest(method: .get, path: "/automation/runtime/mount")
        )
        XCTAssertEqual(mountMetadata.statusCode, 200)
        XCTAssertEqual(mountMetadata.resource, .mount)
        let mountBody = try object(mountMetadata.body)
        XCTAssertEqual(try array(mountBody["workflowIDs"]), [
            .string("content.release"), .string("content.review"),
        ])
        XCTAssertEqual(try array(mountBody["apiRoutes"]).count, 24)
        XCTAssertEqual(try array(mountBody["replMounts"]).count, 2)

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
        XCTAssertEqual(try array(releaseWiring["apiRoutes"]).count, 7)
        XCTAssertEqual(releaseWiring["modelRouterToolName"], .string(SMLWorkflowRuntimeModelAdapter.toolName))
        XCTAssertNotNil(releaseWiring["onyxDriverID"])
        XCTAssertEqual(releaseWiring["planningWorkflowID"], .string("content.release"))

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
        XCTAssertEqual(try array(try object(routedMount.body)["apiRoutes"]).count, 24)

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
        XCTAssertEqual(appWorkflowMount.apiRoutes.map(\.workflowID), Array(repeating: "content.review", count: 7))
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
        XCTAssertTrue(onyxInfo.contains("skill tree:"))
        guard case .local(let planningInfo) = try repl.compile("planning", issuedAtEpoch: 1_002) else {
            return XCTFail("expected local planning metadata")
        }
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
