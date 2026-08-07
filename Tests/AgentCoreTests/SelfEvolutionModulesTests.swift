import XCTest
@testable import AgentCore

/// Phase 2/3 backbone: the router (verdict → action), ownership (never-blend-repos guard), and the
/// loop-guard ledger (an unattended self-deployer must not repeat or churn).
final class SelfEvolutionModulesTests: XCTestCase {

    private func verdict(_ cat: FailureCategory, tool: String? = "t", hint: String? = nil)
        -> FailureClassifier.Verdict {
        .init(category: cat, confidence: 0.8, evidence: "\(tool ?? "?"): boom", culpritTool: tool, discoveryHint: hint)
    }

    // MARK: - Router

    func testKnowledgeGapRoutesToDiscoverAndRetry() {
        let p = FailureRouter.plan(for: verdict(.knowledgeGap, tool: "perslis__win98_run_command",
                                                hint: "search: win98_run_commands"))
        XCTAssertEqual(p.kind, .discoverAndRetry)
        XCTAssertTrue(p.brief.contains("do NOT edit code"), "the brief must forbid code edits for a knowledge gap")
        XCTAssertTrue(p.brief.contains("DISCOVER"))
        XCTAssertTrue(p.brief.contains("search: win98_run_commands"), "the tool's own hint is threaded in")
    }

    func testToolLimitRoutesToExtendTool() {
        let p = FailureRouter.plan(for: verdict(.toolLimit, tool: "perslis__win98_run_command"))
        XCTAssertEqual(p.kind, .extendTool)
        XCTAssertTrue(p.brief.contains("EXTEND"))
    }

    func testBlockedRoutesToSurface() {
        let p = FailureRouter.plan(for: verdict(.blocked, tool: "fetch_url"))
        XCTAssertEqual(p.kind, .surfaceBlocked)
        XCTAssertTrue(p.brief.contains("AUTHORITY"))
    }

    func testTaskBugRoutesToRepair() {
        let p = FailureRouter.plan(for: verdict(.taskBug, tool: "run_command"))
        XCTAssertEqual(p.kind, .repairCode)
        XCTAssertTrue(p.brief.contains("REPAIR"))
    }

    // MARK: - Ownership (never blend repos)

    func testNativeToolIsKist() {
        XCTAssertEqual(ToolOwnershipResolver.owner(of: "run_command"), .kist)
        XCTAssertEqual(ToolOwnershipResolver.owner(of: "research_run"), .kist)
        XCTAssertNil(ToolOwnershipResolver.foreignServer(of: "run_command"))
    }

    func testMCPToolIsForeignWithServer() {
        XCTAssertEqual(ToolOwnershipResolver.owner(of: "perslis__win98_run_command"), .foreign)
        XCTAssertEqual(ToolOwnershipResolver.foreignServer(of: "perslis__win98_run_command"), "perslis")
        XCTAssertEqual(ToolOwnershipResolver.owner(of: "lsp-swift__hover"), .foreign)
        XCTAssertEqual(ToolOwnershipResolver.foreignServer(of: "isolated-tester__click"), "isolated-tester")
    }

    // MARK: - Ledger loop-guard

    func testSignatureCollapsesVolatileArgs() {
        let a = SelfEvolutionLedger.signature(tool: "perslis__win98_run_command",
                                              evidence: "unknown Windows 98 run command: C:\\HELLO.VBS")
        let b = SelfEvolutionLedger.signature(tool: "perslis__win98_run_command",
                                              evidence: "unknown Windows 98 run command: C:\\OTHER.VBS")
        XCTAssertEqual(a, b, "different file args collapse to ONE capability signature (don't re-evolve per file)")
    }

    func testDoesNotRepeatAResolvedEvolution() {
        let now = 1000.0
        let sig = "perslis__win98_run_command|unknown … <path>"
        for outcome in ["promoted", "rejected", "spec-handed-off"] {
            let hist = [SelfEvolutionAttempt(tool: "t", category: "toolLimit", signature: sig,
                                             outcome: outcome, atEpoch: now - 10)]
            let d = SelfEvolutionLedger.decideShouldAttempt(signature: sig, now: now, history: hist,
                                                            maxAttemptsPerWindow: 3, windowSeconds: 3600)
            XCTAssertFalse(d.ok, "must not repeat an already-\(outcome) evolution")
        }
    }

    func testRateCapStopsChurn() {
        let now = 1000.0
        let hist = (0..<3).map { SelfEvolutionAttempt(tool: "t", category: "toolLimit", signature: "s\($0)",
                                                      outcome: "attempted", atEpoch: now - Double($0)) }
        let d = SelfEvolutionLedger.decideShouldAttempt(signature: "sNEW", now: now, history: hist,
                                                        maxAttemptsPerWindow: 3, windowSeconds: 3600)
        XCTAssertFalse(d.ok, "3 attempts in the window ⇒ cap reached, no more self-deploys this window")
    }

    func testFreshSignatureIsAllowed() {
        let d = SelfEvolutionLedger.decideShouldAttempt(signature: "brand-new", now: 1000, history: [],
                                                        maxAttemptsPerWindow: 3, windowSeconds: 3600)
        XCTAssertTrue(d.ok)
    }
}
