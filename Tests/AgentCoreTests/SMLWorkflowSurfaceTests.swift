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
        let candidate = try SMLWorkflowValidator.requireValidForImport(
            workflow(version: version)
        )
        let admitted = try SMLWorkflowAdmission.admitForExecution(
            candidate,
            catalog: SMLExecutionAdmissionCatalog(
                toolCapabilities: ["repository.write"],
                modelPurposes: ["content.plan"],
                modelOutputSchemas: ["content.plan.v1"],
                verifiers: ["artifact_verified"],
                approvalAuthorities: ["release_approver"]
            )
        )
        return try SMLWorkflowSurface.compile(admitted: admitted, role: "release-manager")
    }

    private func workflow(version: String = "1.0.0") -> SMLWorkflow {
        SMLWorkflow(
            id: "content.release",
            version: version,
            name: "Content release",
            source: .init(kind: .langGraph, reference: "graphs/content_release.py"),
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
}
