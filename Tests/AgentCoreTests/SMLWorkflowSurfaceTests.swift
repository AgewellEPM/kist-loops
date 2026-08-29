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

        let modelTool = surface.modelCommandTool()
        XCTAssertEqual(modelTool.name, SMLWorkflowModelAdapter.toolName)
        XCTAssertEqual(modelTool.parameters.map(\.name), ["line"])
        XCTAssertFalse(modelTool.description.contains("approve TASK_ID"))
        XCTAssertFalse(modelTool.description.contains("rollback TASK_ID"))

        let api = SMLWorkflowAPICatalog(surface: surface)
        XCTAssertEqual(api.endpoints.count, 7)
        XCTAssertEqual(api.endpoints.first { $0.action == .start }?.bodyFields.map(\.name), ["target"])

        let onyx = SMLOnyxDriverCompiler.compile(surface: surface)
        XCTAssertEqual(onyx.providerFamily, "onyx")
        XCTAssertEqual(onyx.plan.entrypoint, "plan")
        XCTAssertEqual(onyx.tools.map(\.reference), ["content.plan", "artifact_verified", "repository.write"])
        XCTAssertEqual(onyx.skillTree.first { $0.id == "write" }?.prerequisites, ["plan"])
        XCTAssertEqual(onyx.skillTree.first { $0.id == "verify" }?.successors, ["approval", "rollback"])
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
            issuedAtEpoch: 2_002
        )) {
            XCTAssertEqual($0 as? SMLWorkflowAPIError, .unknownBodyField("actor"))
        }
        XCTAssertThrowsError(try api.compile(
            SMLWorkflowAPIRequest(method: .get, path: "/v1/workflows/other/tasks/TASK-API"),
            issuedAtEpoch: 2_003
        ))
        XCTAssertThrowsError(try api.compile(
            SMLWorkflowAPIRequest(method: .get, path: "/v1/workflows/content.release/%2e%2e"),
            issuedAtEpoch: 2_004
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
            issuedAtEpoch: 2_005
        )) {
            XCTAssertEqual($0 as? SMLWorkflowSurfaceError, .invalidTask("runtime"))
        }
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
