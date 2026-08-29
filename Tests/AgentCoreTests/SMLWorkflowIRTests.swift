import XCTest
@testable import AgentCore

final class SMLWorkflowIRTests: XCTestCase {
    func testCommandEnvelopeRoundTripsWithCanonicalWireKeys() throws {
        let envelope = SMLCommandEnvelope(
            commandID: "command-1842",
            actor: "operator.luke",
            role: "digital-presence-manager",
            task: "TASK-1842",
            op: "workflow.run_matching",
            arguments: [
                "filters": .object([
                    "category": .string("website"),
                    "risk_max": .string("R1"),
                    "public_side_effect": .bool(false),
                ]),
            ],
            scope: ["repository": .string("staging")],
            expectedState: ["status": .string("awaiting_approval")],
            issuedAtEpoch: 1_777_000_000
        )

        XCTAssertTrue(envelope.validate().isValid)
        let data = try JSONEncoder().encode(envelope)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"command_id\""))
        XCTAssertTrue(json.contains("\"expected_state\""))
        XCTAssertEqual(try JSONDecoder().decode(SMLCommandEnvelope.self, from: data), envelope)
    }

    func testCommandEnvelopeRejectsInvalidAuthorityNeutralShape() {
        let envelope = SMLCommandEnvelope(
            schemaVersion: 99,
            commandID: "bad command",
            actor: "",
            role: "role",
            task: "task",
            op: "workflow.run",
            issuedAtEpoch: -1
        )
        let codes = Set(envelope.validate().errors.map(\.code))
        XCTAssertTrue(codes.contains("unsupported_schema"))
        XCTAssertTrue(codes.contains("invalid_identifier"))
        XCTAssertTrue(codes.contains("invalid_timestamp"))
    }

    func testWebsiteRepairWorkflowCoversModelToolApprovalRollbackAndReceipt() throws {
        let workflow = websiteRepairWorkflow()
        let report = SMLWorkflowValidator.validate(workflow)
        XCTAssertTrue(report.isValid, report.diagnostics.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(report.warnings.isEmpty)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(workflow)
        let decoded = try JSONDecoder().decode(SMLWorkflow.self, from: data)
        XCTAssertEqual(decoded, workflow)
        XCTAssertEqual(decoded.instructions.first?.op, .observe)
        XCTAssertEqual(decoded.instructions.last?.op, .escalate)
    }

    func testUnknownInstructionOpcodeFailsClosedDuringDecode() {
        let data = Data(#"{"id":"x","op":"DO_MAGIC","arguments":{},"scope":{},"expected_state":{},"receipt_fields":[]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SMLInstruction.self, from: data))
    }

    func testDanglingAndUnreachableInstructionsAreCompilerErrors() {
        let workflow = SMLWorkflow(
            id: "broken.workflow",
            version: "1.0.0",
            name: "Broken",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "start",
            instructions: [
                .init(id: "start", op: .observe, source: "system", next: "missing"),
                .init(id: "orphan", op: .complete),
            ]
        )
        let codes = Set(SMLWorkflowValidator.validate(workflow).errors.map(\.code))
        XCTAssertTrue(codes.contains("unknown_transition"))
        XCTAssertTrue(codes.contains("unreachable_instruction"))
        XCTAssertTrue(codes.contains("no_terminal_path"))
    }

    func testCycleRequiresAnExplicitBoundedRetry() {
        let unbounded = SMLWorkflow(
            id: "loop.unbounded",
            version: "1.0.0",
            name: "Unbounded",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "again",
            instructions: [
                .init(id: "again", op: .observe, source: "system", next: "again"),
            ]
        )
        let unboundedCodes = Set(SMLWorkflowValidator.validate(unbounded).errors.map(\.code))
        XCTAssertTrue(unboundedCodes.contains("unbounded_cycle"))
        XCTAssertTrue(unboundedCodes.contains("no_terminal_path"))

        let condition = SMLCondition(clauses: [
            .init(field: "healthy", op: .equals, value: .bool(true)),
        ])
        let bounded = SMLWorkflow(
            id: "loop.bounded",
            version: "1.0.0",
            name: "Bounded",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "healthy", type: .boolean)],
            entrypoint: "observe",
            instructions: [
                .init(id: "observe", op: .observe, source: "system", next: "decide"),
                .init(id: "decide", op: .branch, condition: condition,
                      trueTarget: "done", falseTarget: "retry"),
                .init(id: "retry", op: .retry,
                      retryPolicy: .init(target: "observe", maximumAttempts: 2),
                      onFailure: "failed"),
                .init(id: "done", op: .complete),
                .init(id: "failed", op: .escalate, reason: "retry budget exhausted", owner: "operator"),
            ]
        )
        let report = SMLWorkflowValidator.validate(bounded)
        XCTAssertTrue(report.isValid, report.diagnostics.map(\.description).joined(separator: "\n"))
    }

    func testCycleCannotBypassRetryBudgetThroughAlternateEdges() {
        let workflow = SMLWorkflow(
            id: "loop.retry_bypass",
            version: "1.0.0",
            name: "Retry bypass",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "use_retry", type: .boolean)],
            entrypoint: "a",
            instructions: [
                .init(id: "a", op: .branch,
                      condition: .init(clauses: [
                        .init(field: "use_retry", op: .equals, value: .bool(true)),
                      ]),
                      trueTarget: "retry", falseTarget: "b"),
                .init(id: "b", op: .observe, source: "system", next: "a"),
                .init(id: "retry", op: .retry,
                      retryPolicy: .init(target: "a", maximumAttempts: 2),
                      onFailure: "done"),
                .init(id: "done", op: .complete),
            ]
        )

        XCTAssertTrue(SMLWorkflowValidator.validate(workflow).errors.contains {
            $0.code == "unbounded_cycle"
        })
    }

    func testOpaquePluginImportsOnlyAsNonExecutableCandidate() {
        let safeOpaque = pluginWorkflow(plugin: .init(id: "process_invoice"))
        let safeReport = SMLWorkflowValidator.validate(safeOpaque)
        XCTAssertTrue(safeReport.isValid, safeReport.diagnostics.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(safeReport.warnings.contains { $0.code == "plugin_unclassified" })
    }

    func testContractedReversiblePluginRequiresVerifierAndRollback() {
        let plugin = SMLPluginContract(
            id: "process_invoice",
            reads: ["invoice_record"],
            writes: ["invoice_status"],
            sideEffectLevel: .reversibleInternal,
            preconditions: ["invoice_exists"],
            postconditions: ["invoice_status_updated"]
        )
        let codes = Set(SMLWorkflowValidator.validate(pluginWorkflow(plugin: plugin)).errors.map(\.code))
        XCTAssertTrue(codes.contains("missing_plugin_verifier"))
        XCTAssertTrue(codes.contains("missing_plugin_rollback"))
    }

    func testRetrieveVCardNestedWorkflowAssertAndCheckpointHaveValidTypedShapes() {
        let condition = SMLCondition(clauses: [
            .init(field: "ready", op: .equals, value: .bool(true)),
        ])
        let workflow = SMLWorkflow(
            id: "typed.remaining_operations",
            version: "1.0.0",
            name: "Remaining typed operations",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "ready", type: .boolean),
                .init(name: "status", type: .string),
            ],
            entrypoint: "retrieve",
            instructions: [
                .init(id: "retrieve", op: .retrieve, source: "memory.semantic", next: "assert"),
                .init(id: "assert", op: .assert, condition: condition,
                      onPass: "vcard", onFailure: "failed"),
                .init(id: "vcard", op: .invokeVCard,
                      capability: "customer.lookup", verifier: "customer_found",
                      expectedState: ["status": .string("found")], next: "nested"),
                .init(id: "nested", op: .runWorkflow,
                      workflow: "customer.enrich", next: "checkpoint"),
                .init(id: "checkpoint", op: .checkpoint, next: "done"),
                .init(id: "done", op: .complete),
                .init(id: "failed", op: .escalate,
                      reason: "assertion_failed", owner: "role_owner"),
            ]
        )

        let report = SMLWorkflowValidator.validate(workflow)
        XCTAssertTrue(report.isValid, report.diagnostics.map(\.description).joined(separator: "\n"))
    }

    func testIrrelevantPayloadAndStateTypeMismatchesFailClosed() {
        let workflow = SMLWorkflow(
            id: "typed.invalid_payload",
            version: "1.0.0",
            name: "Invalid payload",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "count", type: .integer)],
            entrypoint: "done",
            instructions: [
                .init(
                    id: "done",
                    op: .complete,
                    capability: "tool.should_not_be_here",
                    expectedState: ["count": .string("not-an-integer")],
                    plugin: .init(id: "also_not_allowed")
                ),
            ]
        )

        let codes = Set(SMLWorkflowValidator.validate(workflow).errors.map(\.code))
        XCTAssertTrue(codes.contains("unexpected_field"))
        XCTAssertTrue(codes.contains("expected_state_type_mismatch"))
    }

    func testConditionValuesShareTheWorkflowValueBudget() {
        let oversized = SMLValue.array(Array(
            repeating: .null,
            count: SMLValidationSupport.maximumArrayEntries + 1
        ))
        let workflow = SMLWorkflow(
            id: "condition.oversized",
            version: "1.0.0",
            name: "Oversized condition",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [.init(name: "payload", type: .array)],
            entrypoint: "branch",
            instructions: [
                .init(
                    id: "branch",
                    op: .branch,
                    condition: .init(clauses: [
                        .init(field: "payload", op: .equals, value: oversized),
                    ]),
                    trueTarget: "yes",
                    falseTarget: "no"
                ),
                .init(id: "yes", op: .complete),
                .init(id: "no", op: .complete),
            ]
        )

        XCTAssertTrue(SMLWorkflowValidator.validate(workflow).errors.contains {
            $0.code == "array_too_large"
        })
    }

    func testWarningSaturationCannotHideALaterStructuralError() {
        var instructions = (0..<SMLWorkflowValidator.maximumDiagnostics).map { index in
            SMLInstruction(
                id: "plugin_\(index)",
                op: .runPlugin,
                plugin: .init(id: "opaque_\(index)"),
                next: index + 1 == SMLWorkflowValidator.maximumDiagnostics
                    ? "done"
                    : "plugin_\(index + 1)"
            )
        }
        instructions.append(.init(
            id: "done",
            op: .complete,
            capability: "forbidden.on.complete"
        ))
        let workflow = SMLWorkflow(
            id: "diagnostics.warning_saturation",
            version: "1.0.0",
            name: "Warning saturation",
            source: .init(kind: .native, reference: "test"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "plugin_0",
            instructions: instructions
        )

        let report = SMLWorkflowValidator.validate(workflow)
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.diagnostics.count, SMLWorkflowValidator.maximumDiagnostics)
        XCTAssertTrue(report.errors.contains { $0.code == "unexpected_field" })
        XCTAssertThrowsError(try SMLWorkflowValidator.requireValidForImport(workflow))
    }

    private func pluginWorkflow(plugin: SMLPluginContract) -> SMLWorkflow {
        SMLWorkflow(
            id: "invoice.imported",
            version: "1.0.0",
            name: "Imported invoice workflow",
            source: .init(kind: .langGraph, reference: "invoice_agent.py#invoice_graph"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "plugin",
            instructions: [
                .init(id: "plugin", op: .runPlugin, plugin: plugin, next: "done"),
                .init(id: "done", op: .complete),
            ]
        )
    }

    private func websiteRepairWorkflow() -> SMLWorkflow {
        let metricTooHigh = SMLCondition(clauses: [
            .init(field: "current_metric", op: .greaterThan, value: .number(0.10)),
        ])
        return SMLWorkflow(
            id: "website.performance_repair",
            version: "1.0.0",
            name: "Website performance repair",
            source: .init(kind: .jobDescription, reference: "digital-presence-manager"),
            trigger: .init(kind: .event, value: "performance_regression"),
            stateSchema: [
                .init(name: "current_metric", type: .number),
                .init(name: "diagnosed_cause", type: .string, nullable: true),
                .init(name: "patch_reference", type: .string, nullable: true),
                .init(name: "verification_status", type: .string),
            ],
            entrypoint: "observe",
            instructions: [
                .init(id: "observe", op: .observe, source: "website.mobile_metrics", next: "decide"),
                .init(id: "decide", op: .branch, condition: metricTooHigh,
                      trueTarget: "diagnose", falseTarget: "no_action_receipt"),
                .init(id: "diagnose", op: .callModel,
                      purpose: "diagnose_performance_regression",
                      outputSchema: "PerformanceDiagnosis", next: "patch"),
                .init(id: "patch", op: .callTool, capability: "repository.apply_patch",
                      scope: ["write": .string("staging_only")], next: "build"),
                .init(id: "build", op: .callTool, capability: "build.run", next: "verify_build"),
                .init(id: "verify_build", op: .verify, verifier: "build_passed",
                      onPass: "visual", onFailure: "rollback"),
                .init(id: "visual", op: .callTool, capability: "visual_regression.run",
                      next: "verify_visual"),
                .init(id: "verify_visual", op: .verify, verifier: "unrelated_ui_unchanged",
                      onPass: "measure", onFailure: "rollback"),
                .init(id: "measure", op: .callTool, capability: "performance.measure",
                      next: "verify_metric"),
                .init(id: "verify_metric", op: .verify, verifier: "metric_below_target",
                      onPass: "approval", onFailure: "retry_repair"),
                .init(id: "retry_repair", op: .retry,
                      retryPolicy: .init(target: "diagnose", maximumAttempts: 2, backoffSeconds: 1),
                      onFailure: "rollback"),
                .init(id: "approval", op: .waitApproval, reason: "production_deployment",
                      owner: "production_approver",
                      next: "deploy", onFailure: "rollback"),
                .init(id: "deploy", op: .callTool, capability: "production.deploy", next: "verify_production"),
                .init(id: "verify_production", op: .verify, verifier: "production_metric_below_target",
                      onPass: "commit", onFailure: "rollback"),
                .init(id: "commit", op: .commit, verifier: "production_metric_below_target",
                      next: "receipt"),
                .init(id: "receipt", op: .emitReceipt,
                      receiptFields: ["actor", "task", "before_hash", "after_hash", "verification"]),
                .init(id: "no_action_receipt", op: .emitReceipt,
                      receiptFields: ["task", "observed_metric", "verification"]),
                .init(id: "rollback", op: .rollback, reason: "verification_failed", next: "escalate"),
                .init(id: "escalate", op: .escalate, reason: "repair_failed", owner: "role_owner"),
            ]
        )
    }
}
