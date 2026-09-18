import XCTest
import Foundation
@testable import AgentCore

/// The shared ToolGate (scope + audit) that BOTH ToolRegistry.execute and composite sub-actions
/// (research_run / visual_verify) pass through — closing the council/Codex composite-bypass.
final class ToolGateTests: XCTestCase {

    private struct SchemaProbeTool: AgentTool {
        let name = "schema_probe"
        let description = "schema validation probe"
        let parameters = [
            ToolParameter(name: "value", type: "string", description: "value", required: true),
            ToolParameter(name: "enabled", type: "boolean", description: "enabled", required: false),
            ToolParameter(name: "count", type: "integer", description: "count", required: false),
            ToolParameter(name: "payload", type: "object", description: "structured payload", required: false),
        ]
        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            .init(success: true, output: "ran")
        }
    }

    private struct HostBoundProbeTool: AgentTool {
        let name = "host_bound_probe"
        let description = "host-bound validation probe"
        let parameters = [
            ToolParameter(name: "value", type: "string", description: "public value", required: true),
        ]
        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            .init(success: true, output: arguments["_host_authority"] as? String ?? "missing")
        }
    }

    private var root: String!
    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() + "gate-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(dir) ?? dir
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    // A restrictive skill scope BLOCKS an out-of-scope sub-action BEFORE the body runs, and audits it.
    func testGateBlocksOutOfScopeSubActionAndAudits() async {
        let log = AuditLog(path: root + "/audit.jsonl")
        let scoped = Skill(name: "ro", description: "d", allowedTools: ["read_file"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [scoped]); await tracker.markLoaded("ro", trusted: true)
        let ctx = ToolContext(projectRoot: root).withSkills(locations: [:], tracker: tracker).withAuditLog(log)

        var bodyRan = false
        let result = await ToolGate.run(name: "fetch_url", arguments: ["url": "http://evil"], context: ctx) {
            bodyRan = true; return .init(success: true, output: "fetched")
        }
        XCTAssertFalse(bodyRan, "an out-of-scope composite sub-action must NOT run its body")
        XCTAssertFalse(result.success)
        XCTAssertTrue((result.error ?? "").contains("capability scope"))
        let entries = await log.entries()
        XCTAssertEqual(entries.last?.tool, "fetch_url")
        XCTAssertEqual(entries.last?.outcome, "blocked_scope")
    }

    // With no restrictive scope, the gate runs the body and audits the outcome.
    func testGateRunsAndAuditsWhenAllowed() async {
        let log = AuditLog(path: root + "/audit.jsonl")
        let ctx = ToolContext(projectRoot: root).withAuditLog(log)
        let result = await ToolGate.run(name: "web_search", arguments: ["q": "x"], context: ctx) {
            .init(success: true, output: "results")
        }
        XCTAssertTrue(result.success)
        let entries = await log.entries()
        XCTAssertEqual(entries.last?.tool, "web_search")
        XCTAssertEqual(entries.last?.outcome, "ok")
    }

    // DeepSeek LOW: a caller (ToolRegistry.execute) that already read the allow-list can forward it so
    // the gate uses the SAME value — no second read, no disagreement window. `.some(set)` is honored as
    // the decision basis; `.some(nil)` means "no skill loaded" (body runs).
    func testPrecomputedAllowlistIsUsedWithoutReReading() async {
        // No skillTracker on the context — so if the gate re-read it would see nil and ALLOW. The
        // precomputed restrictive set must still BLOCK, proving the forwarded value drives the decision.
        let ctx = ToolContext(projectRoot: root)
        var bodyRan = false
        let blocked = await ToolGate.run(name: "fetch_url", arguments: ["url": "http://x"], context: ctx,
                                         precomputedAllowlist: .some(Set(["read_file"]))) {
            bodyRan = true; return .init(success: true, output: "fetched")
        }
        XCTAssertFalse(bodyRan, "the forwarded restrictive allow-list must block, not a fresh (nil) read")
        XCTAssertTrue((blocked.error ?? "").contains("capability scope"))
        // `.some(nil)` = explicitly no skill loaded → body runs.
        var ranWhenNil = false
        _ = await ToolGate.run(name: "fetch_url", arguments: [:], context: ctx, precomputedAllowlist: .some(nil)) {
            ranWhenNil = true; return .init(success: true, output: "ok")
        }
        XCTAssertTrue(ranWhenNil, ".some(nil) means no skill loaded — the body runs")
    }

    // The gate masks secrets in the body's output (same as execute).
    func testGateMasksSecrets() async {
        let ctx = ToolContext(projectRoot: root)
        let result = await ToolGate.run(name: "x", arguments: [:], context: ctx) {
            .init(success: true, output: "token sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        }
        XCTAssertFalse(result.output.contains("sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"), "secrets masked")
    }

    func testRegistryRejectsMissingMistypedAndUnknownArguments() async {
        let registry = ToolRegistry([SchemaProbeTool()])
        let context = ToolContext(projectRoot: root)
        let missing = await registry.execute(name: "schema_probe", arguments: [:], context: context)
        XCTAssertFalse(missing.success)
        XCTAssertTrue((missing.error ?? "").contains("missing required field 'value'"))

        let mistyped = await registry.execute(name: "schema_probe", arguments: ["value": 7], context: context)
        XCTAssertFalse(mistyped.success)
        XCTAssertTrue((mistyped.error ?? "").contains("must be string"))

        let unknown = await registry.execute(name: "schema_probe", arguments: ["value": "ok", "surprise": true], context: context)
        XCTAssertFalse(unknown.success)
        XCTAssertTrue((unknown.error ?? "").contains("unknown field 'surprise'"))

        let valid = await registry.execute(name: "schema_probe", arguments: ["value": "ok", "enabled": true], context: context)
        XCTAssertTrue(valid.success, valid.error ?? "")
    }

    func testRegistryAcceptsNestedObjectsAndRejectsOtherObjectParameterTypes() async throws {
        let registry = ToolRegistry([SchemaProbeTool()])
        let context = ToolContext(projectRoot: root)
        let arguments = try XCTUnwrap(JSONSerialization.jsonObject(with:
            Data(#"{"value":"ok","payload":{"nested":{"message":"hello"},"values":[1,true]}}"#.utf8)) as? [String: Any])
        let accepted = await registry.execute(name: "schema_probe", arguments: arguments, context: context)
        XCTAssertTrue(accepted.success, accepted.error ?? "")
        let invalidValues: [Any] = ["text", [1, 2], 4]
        for invalid in invalidValues {
            let result = await registry.execute(name: "schema_probe",
                arguments: ["value": "ok", "payload": invalid], context: context)
            XCTAssertFalse(result.success)
            XCTAssertTrue((result.error ?? "").contains("must be object"))
        }
    }

    func testHostBoundArgumentsRemainUnadvertisedAndUnforgeable() async {
        let registry = ToolRegistry([HostBoundProbeTool()])
        let context = ToolContext(projectRoot: root)

        let directForgery = await registry.execute(
            name: "host_bound_probe",
            arguments: ["value": "ok", "_host_authority": "forged"], context: context)
        XCTAssertFalse(directForgery.success)
        XCTAssertTrue((directForgery.error ?? "").contains("unknown field '_host_authority'"))

        let trusted = await registry.executeHostBound(
            name: "host_bound_probe", arguments: ["value": "ok"],
            hostArguments: ["_host_authority": "trusted"], context: context)
        XCTAssertTrue(trusted.success, trusted.error ?? "")
        XCTAssertEqual(trusted.output, "trusted")

        let forgedEvenOnHostPath = await registry.executeHostBound(
            name: "host_bound_probe",
            arguments: ["value": "ok", "_host_authority": "forged"],
            hostArguments: ["_host_authority": "trusted"], context: context)
        XCTAssertFalse(forgedEvenOnHostPath.success,
                       "caller-supplied private fields must fail public-schema validation")
    }

    func testJSONNSNumberOneIsAnIntegerNotABoolean() async throws {
        let registry = ToolRegistry([SchemaProbeTool()])
        let context = ToolContext(projectRoot: root)
        let integer = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"value":"ok","count":1}"#.utf8)) as? [String: Any])
        let accepted = await registry.execute(name: "schema_probe", arguments: integer, context: context)
        XCTAssertTrue(accepted.success, accepted.error ?? "")

        let boolean = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(#"{"value":"ok","count":true}"#.utf8)) as? [String: Any])
        let rejected = await registry.execute(name: "schema_probe", arguments: boolean, context: context)
        XCTAssertFalse(rejected.success)
        XCTAssertTrue((rejected.error ?? "").contains("must be integer"), rejected.error ?? "")
    }

    func testPermissionDeniedErrorIsExplicit() {
        XCTAssertEqual(ToolError.permissionDenied("scope").description, "permission denied: scope")
    }

    // Codex HIGH: the gate enforces AUTHORIZATION scope (plan-only / needs-approval), not just the
    // skill allow-list — so a composite sub-action gets the same action-class gate as a top-level call.
    // A `.planOnly` scope must block a state-changing sub-action (fetch_url) BEFORE its body runs.
    func testGateEnforcesAuthorizationScopeForSubAction() async {
        let log = AuditLog(path: root + "/audit.jsonl")
        let planOnly = ScopeDecision(kind: .normal, gate: .planOnly, reason: "investigate first",
                                     allowedActions: [], blockedActions: [], requiredEvidence: [])
        let ctx = ToolContext(projectRoot: root).withAuthorizationScope(planOnly).withAuditLog(log)
        var bodyRan = false
        let result = await ToolGate.run(name: "fetch_url", arguments: ["url": "http://x"], context: ctx) {
            bodyRan = true; return .init(success: true, output: "fetched")
        }
        XCTAssertFalse(bodyRan, "plan-only must block a state-changing sub-action before its body runs")
        XCTAssertTrue((result.error ?? "").contains("authorization scope"), result.error ?? "")
        let entries = await log.entries()
        XCTAssertEqual(entries.last?.tool, "fetch_url")
        XCTAssertEqual(entries.last?.outcome, "blocked_auth")
        // A PASSIVE sub-action (web_search) is still allowed under plan-only.
        var passiveRan = false
        _ = await ToolGate.run(name: "web_search", arguments: ["q": "x"], context: ctx) {
            passiveRan = true; return .init(success: true, output: "ok")
        }
        XCTAssertTrue(passiveRan, "a passive sub-action stays allowed under plan-only")
    }

    // Codex HIGH: research_run(action="visual") now re-enters the gate under the REAL `visual_verify`
    // name — so it is authorization-scoped + audited like the other sub-actions (was passed raw before).
    func testVisualSubActionIsGatedUnderRealName() async {
        let log = AuditLog(path: root + "/audit.jsonl")
        var visualRan = false
        let research = ResearchRunTool(allowedHosts: [], visual: { _, _ in
            visualRan = true; return .init(success: true, output: "compared")
        })
        let planOnly = ScopeDecision(kind: .normal, gate: .planOnly, reason: "plan first",
                                     allowedActions: [], blockedActions: [], requiredEvidence: [])
        let ctx = ToolContext(projectRoot: root).withAuthorizationScope(planOnly).withAuditLog(log)
        let result = try? await research.execute(arguments: ["action": "visual", "goal": "compare ui"], context: ctx)
        XCTAssertFalse(visualRan, "the injected visual runner must NOT run when the gate blocks it")
        XCTAssertEqual(result?.success, false)
        let entries = await log.entries()
        XCTAssertEqual(entries.last?.tool, "visual_verify", "the sub-action audits under its REAL name, not research_run")
        XCTAssertEqual(entries.last?.outcome, "blocked_auth")
    }

    // Wiring pins: composite tools route sub-actions through the gate (not bare execute).
    func testCompositesUseGatePin() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let research = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/Tools/ResearchRunTool.swift"), encoding: .utf8)
        XCTAssertTrue(research.contains("ToolGate.run(name: searchTool.name"), "research_run search via gate")
        XCTAssertTrue(research.contains("ToolGate.run(name: fetchTool.name"), "research_run fetch via gate")
        XCTAssertTrue(research.contains("ToolGate.run(name: browserTool.name"), "research_run browse via gate")
        let visual = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/Tools/VisualVerifyTool.swift"), encoding: .utf8)
        XCTAssertTrue(visual.contains("ToolGate.run(name: browser.name"), "visual_verify browser via gate")
        // research_run's INJECTED visual runner re-enters the gate under the real visual_verify name (Codex HIGH).
        XCTAssertTrue(research.contains("ToolGate.run(name: \"visual_verify\""), "research_run visual via gate")
        // ToolRegistry.execute also delegates to the shared gate (one enforcement path).
        let registry = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/Tools/ToolRegistry.swift"), encoding: .utf8)
        XCTAssertTrue(registry.contains("ToolGate.run(name: name"), "execute delegates to the shared gate")
        // The authorization-scope check lives in the SHARED gate now (so composites enforce it), and is
        // NO LONGER a separate pre-check in execute (Codex HIGH — one enforcement site, no bypass).
        let gate = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/Tools/ToolGate.swift"), encoding: .utf8)
        XCTAssertTrue(gate.contains("authorizationScope?.toolBlockReason"), "ToolGate enforces authorization scope")
        XCTAssertFalse(registry.contains("authorizationScope?.toolBlockReason"), "execute must NOT separately pre-check authz (gate owns it)")
        // execute forwards its already-read allow-list to the gate (no double read — DeepSeek LOW).
        XCTAssertTrue(registry.replacingOccurrences(of: " ", with: "").contains("precomputedAllowlist:.some(activeAllowlist)"),
                      "execute forwards its read allow-list to the gate")
    }
}
