import XCTest
@testable import AgentCore

/// Pins the approve-everything IR transform. The load-bearing invariant (multi-site discipline):
/// in a gated workflow, EVERY inbound edge of every externally advanced instruction — computed by
/// walking every target-bearing field of every op (entrypoint, next, on_pass, on_failure, true,
/// false, retry_policy.target) — is exactly its injected gate. One edge-field audit covers all
/// seven sites so a rewriter that misses one field names itself here, not in production.
final class SMLWorkflowApprovalGatingTests: XCTestCase {
    // MARK: - Edge audit helpers (independent re-implementation of the edge walk)

    private struct Edge: Hashable {
        let from: String  // instruction id, or "«entrypoint»"
        let field: String
    }

    private func inboundEdges(of target: String, in workflow: SMLWorkflow) -> Set<Edge> {
        var edges: Set<Edge> = []
        if workflow.entrypoint == target {
            edges.insert(Edge(from: "«entrypoint»", field: "entrypoint"))
        }
        for instruction in workflow.instructions {
            let fields: [(String, String?)] = [
                ("next", instruction.next),
                ("on_pass", instruction.onPass),
                ("on_failure", instruction.onFailure),
                ("true", instruction.trueTarget),
                ("false", instruction.falseTarget),
                ("retry_policy.target", instruction.retryPolicy?.target),
            ]
            for (field, value) in fields where value == target {
                edges.insert(Edge(from: instruction.id, field: field))
            }
        }
        return edges
    }

    /// A workflow exercising ALL SEVEN edge sites into gated instructions: entrypoint→observe,
    /// branch true/false→two tools, assert on_pass/on_failure→model & retrieve, retry target→tool,
    /// wait_approval next is exercised by gating itself.
    private func sevenEdgeWorkflow() -> SMLWorkflow {
        SMLWorkflow(
            id: "gating.audit",
            version: "1.0.0",
            name: "Edge audit",
            source: .init(kind: .native, reference: "tests://gating"),
            trigger: .init(kind: .manual),
            stateSchema: [
                .init(name: "flag", type: .boolean),
                .init(name: "result", type: .string, required: false),
            ],
            interface: .init(inputFields: ["flag"], outputFields: ["result"]),
            entrypoint: "look",
            instructions: [
                // entrypoint edge → OBSERVE (gated)
                .init(id: "look", op: .observe, source: "sensor.a", next: "decide"),
                // BRANCH true/false edges → two gated tools
                .init(id: "decide", op: .branch,
                      condition: .init(clauses: [.init(field: "flag", op: .equals, value: .bool(true))]),
                      trueTarget: "tool-a", falseTarget: "tool-b"),
                .init(id: "tool-a", op: .callTool, capability: "cap.a", next: "check"),
                .init(id: "tool-b", op: .callTool, capability: "cap.b", next: "check"),
                // ASSERT on_pass/on_failure edges → gated model & gated retrieve
                .init(id: "check", op: .assert,
                      condition: .init(clauses: [.init(field: "flag", op: .exists)]),
                      onPass: "summarize", onFailure: "refetch"),
                .init(id: "summarize", op: .callModel, purpose: "summary",
                      outputSchema: "schema.summary", next: "emit"),
                .init(id: "refetch", op: .retrieve, source: "kb.notes", next: "again"),
                // RETRY retry_policy.target edge → gated tool-a; on_failure → escalate
                .init(id: "again", op: .retry,
                      retryPolicy: .init(target: "tool-a", maximumAttempts: 3),
                      onFailure: "gave-up"),
                .init(id: "gave-up", op: .escalate, reason: "retry budget exhausted",
                      owner: "ops-lead"),
                .init(id: "emit", op: .emitReceipt, receiptFields: ["result"]),
            ]
        )
    }

    private let externallyAdvanced = SMLWorkflowApprovalGating.externallyAdvancedOperations

    // MARK: - The load-bearing invariant

    func testEveryInboundEdgeOfEveryExternalInstructionIsExactlyItsGate() throws {
        let gated = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        let externalIDs = gated.instructions
            .filter { externallyAdvanced.contains($0.op) }
            .map(\.id)
        XCTAssertEqual(
            Set(externalIDs), ["look", "tool-a", "tool-b", "summarize", "refetch"],
            "fixture must cover observe/callTool/callModel/retrieve"
        )
        for id in externalIDs {
            let edges = inboundEdges(of: id, in: gated)
            XCTAssertEqual(
                edges,
                [Edge(from: SMLWorkflowApprovalGating.gateID(for: id), field: "next")],
                "external instruction '\(id)' must be reachable ONLY through its gate; got \(edges)"
            )
        }
    }

    func testGatedGraphStillPassesTheFullStructuralValidator() throws {
        let gated = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        XCTAssertNoThrow(
            try SMLWorkflowValidator.requireValidForImport(gated),
            "the DAG/terminal-path/transition proofs must hold for the GATED graph"
        )
    }

    func testEveryGateHasARefusalPathTerminatingInEscalate() throws {
        let gated = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        let byID = Dictionary(uniqueKeysWithValues: gated.instructions.map { ($0.id, $0) })
        for gate in gated.instructions where gate.op == .waitApproval {
            let refusalID = try XCTUnwrap(gate.onFailure, "gate '\(gate.id)' has no refusal path")
            let refusal = try XCTUnwrap(byID[refusalID])
            XCTAssertEqual(refusal.op, .escalate,
                           "refusal of '\(gate.id)' must terminate in a visible ESCALATE")
            XCTAssertEqual(refusal.owner, gate.owner)
        }
    }

    // MARK: - Determinism / idempotence

    func testGatingIsDeterministic() throws {
        let first = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        let second = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        XCTAssertEqual(first, second)
    }

    func testGatingAnAlreadyGatedWorkflowChangesNothing() throws {
        let once = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        let twice = try SMLWorkflowApprovalGating.gate(once)
        XCTAssertEqual(once, twice,
                       "author-gated (= previously gated) instructions must not be double-gated")
    }

    func testAuthorSuppliedGateIsRespected() throws {
        let workflow = SMLWorkflow(
            id: "gating.author",
            version: "1.0.0",
            name: "Author gate",
            source: .init(kind: .native, reference: "tests://gating"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            interface: .init(),
            entrypoint: "ask",
            instructions: [
                .init(id: "ask", op: .waitApproval, reason: "author gate", owner: "ops-lead",
                      next: "tool", onFailure: "no"),
                .init(id: "tool", op: .callTool, capability: "cap.a", next: "done"),
                .init(id: "no", op: .escalate, reason: "refused", owner: "ops-lead"),
                .init(id: "done", op: .complete),
            ]
        )
        let gated = try SMLWorkflowApprovalGating.gate(workflow)
        XCTAssertNil(
            gated.instructions.first { $0.id == SMLWorkflowApprovalGating.gateID(for: "tool") },
            "an instruction whose only inbound edge is an author WAIT_APPROVAL must not be re-gated"
        )
        XCTAssertEqual(gated.version, "1.0.0", "an unchanged workflow keeps its version unstamped")
    }

    // MARK: - Policy knobs (designed now, shipped locked)

    func testApproveSideEffectsSkipsReadOnlyOpsOnly() throws {
        let policy = SMLApprovalPolicy(defaultMode: .approveSideEffects)
        let gated = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow(), policy: policy)
        XCTAssertNil(gated.instructions.first { $0.id == "gate-look" },
                     "observe is read-only under approve_side_effects")
        XCTAssertNil(gated.instructions.first { $0.id == "gate-refetch" },
                     "retrieve is read-only under approve_side_effects")
        XCTAssertNotNil(gated.instructions.first { $0.id == "gate-tool-a" })
        XCTAssertNotNil(gated.instructions.first { $0.id == "gate-summarize" })
    }

    func testPerReferenceFreeRunOverrideUngatesExactlyThatCapability() throws {
        let policy = SMLApprovalPolicy(overrides: ["CALL_TOOL:cap.b": .freeRun])
        let gated = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow(), policy: policy)
        XCTAssertNil(gated.instructions.first { $0.id == "gate-tool-b" })
        XCTAssertNotNil(gated.instructions.first { $0.id == "gate-tool-a" },
                        "the override must not leak to the sibling capability")
    }

    func testPolicyChangeChangesTheStampedVersion() throws {
        let locked = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        let relaxed = try SMLWorkflowApprovalGating.gate(
            sevenEdgeWorkflow(),
            policy: SMLApprovalPolicy(overrides: ["CALL_TOOL:cap.b": .freeRun])
        )
        XCTAssertTrue(locked.version.hasPrefix("1.0.0+g"))
        XCTAssertNotEqual(locked.version, relaxed.version,
                          "a policy change must yield a distinct admitted workflow version")
        XCTAssertNoThrow(try SMLWorkflowValidator.requireValidForImport(locked),
                         "the stamped version must remain valid semver")
    }

    // MARK: - Failure modes

    func testReservedGateIdentifierCollisionFailsClosed() {
        let colliding = SMLWorkflow(
            id: "gating.collision",
            version: "1.0.0",
            name: "Collision",
            source: .init(kind: .native, reference: "tests://gating"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            interface: .init(),
            entrypoint: "gate-tool",
            instructions: [
                .init(id: "gate-tool", op: .checkpoint, next: "tool"),
                .init(id: "tool", op: .callTool, capability: "cap.a", next: "done"),
                .init(id: "done", op: .complete),
            ]
        )
        XCTAssertThrowsError(try SMLWorkflowApprovalGating.gate(colliding)) { error in
            XCTAssertEqual(
                error as? SMLWorkflowApprovalGating.GatingError,
                .gateIdentifierCollision("gate-tool")
            )
        }
    }

    func testPolicyFileAbsentIsApproveAlwaysButBrokenFileFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sml-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".kist/sml", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let absent = try SMLApprovalPolicy.load(projectRoot: root.path)
        XCTAssertEqual(absent, SMLApprovalPolicy(),
                       "no policy file IS the locked approve-everything default")

        try "{not json".write(
            to: root.appendingPathComponent(".kist/sml/policy.json"),
            atomically: true, encoding: .utf8
        )
        XCTAssertThrowsError(try SMLApprovalPolicy.load(projectRoot: root.path)) { error in
            guard case SMLApprovalPolicy.LoadError.malformed = error else {
                return XCTFail("a broken policy file must fail closed, got \(error)")
            }
        }
    }

    func testRetryReentersThroughTheGateSoEveryAttemptIsReapproved() throws {
        let gated = try SMLWorkflowApprovalGating.gate(sevenEdgeWorkflow())
        let retry = try XCTUnwrap(gated.instructions.first { $0.id == "again" })
        XCTAssertEqual(retry.retryPolicy?.target, SMLWorkflowApprovalGating.gateID(for: "tool-a"),
                       "the retry edge must route through the gate, not around it")
    }
}
