import XCTest
@testable import AgentCore

final class AuthorizationScopeTests: XCTestCase {

    func testBugBountyWithoutAuthorizationNeedsScopeAndBlocksActiveTesting() {
        let decision = AuthorizationScopeEngine.evaluate("run recon and exploit tests on example.com for bug bounty")

        XCTAssertEqual(decision.kind, .bugBounty)
        XCTAssertEqual(decision.gate, .needsScope)
        XCTAssertTrue(decision.blockedActions.contains { $0.contains("exploit") })
        XCTAssertTrue(decision.requiredEvidence.contains { $0.contains("authorization") || $0.contains("owned") })
    }

    func testAuthorizedBugBountyStillNeedsApprovalForActiveTesting() {
        let decision = AuthorizationScopeEngine.evaluate("authorized bug bounty program scope: my app example.com")

        XCTAssertEqual(decision.kind, .bugBounty)
        XCTAssertEqual(decision.gate, .needsApproval)
        XCTAssertTrue(decision.allowedActions.contains("passive research"))
        XCTAssertTrue(decision.requiredEvidence.contains { $0.contains("safe-harbor") || $0.contains("scope") })
        XCTAssertTrue(decision.requiredEvidence.contains { $0.contains("beyond the prompt text") })
    }

    func testVisualReconstructionRequiresOwnershipOrAuthorization() {
        let decision = AuthorizationScopeEngine.evaluate("reconstruct this app exactly from screenshots")

        XCTAssertEqual(decision.kind, .visualReconstruction)
        XCTAssertEqual(decision.gate, .needsScope)
        XCTAssertTrue(decision.reason.contains("ownership") || decision.reason.contains("authorization"))
    }

    func testServerRemediationNeedsApprovalButDiagnosisIsPlanOnly() {
        let diagnosis = AuthorizationScopeEngine.evaluate("diagnose why my server has high latency")
        let remediation = AuthorizationScopeEngine.evaluate("ssh to production and restart service to fix it")

        XCTAssertEqual(diagnosis.kind, .serverDiagnostics)
        XCTAssertEqual(diagnosis.gate, .planOnly)
        XCTAssertEqual(remediation.kind, .serverDiagnostics)
        XCTAssertEqual(remediation.gate, .needsApproval)
        XCTAssertTrue(remediation.blockedActions.contains { $0.contains("restart") })
    }

    func testDesktopControlRequiresTypedApprovedAction() {
        let decision = AuthorizationScopeEngine.evaluate("open Safari and play me latest hip hop on YouTube")

        XCTAssertEqual(decision.kind, .desktopControl)
        XCTAssertEqual(decision.gate, .needsApproval)
        XCTAssertTrue(decision.allowedActions.contains("youtube_search"))
        XCTAssertTrue(decision.blockedActions.contains { $0.contains("delete") })
    }

    func testDesktopControlRecognizesLaunchAndBrowserPhrases() {
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("launch safari").kind, .desktopControl)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("start chrome").kind, .desktopControl)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("open the browser").kind, .desktopControl)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("open YouTube and play this song").kind, .desktopControl)
    }

    func testScopeKeywordsDoNotMatchAccidentalSubstrings() {
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("reconsider the product roadmap").kind, .normal)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("reproduce the Swift bug").kind, .normal)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("reconstruct this app from my screenshots").kind, .visualReconstruction)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("reconnect the UI after refactor").kind, .normal)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("download youtube-dl source").kind, .normal)
    }

    func testDiagnoseAloneDoesNotTriggerServerScope() {
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("diagnose why my iOS build failed").kind, .normal)
        XCTAssertEqual(AuthorizationScopeEngine.evaluate("diagnose production latency").kind, .serverDiagnostics)
    }

    func testRuntimeScopeUsesRawRequestNotSpecialistContext() {
        let prompt = PromptCompiler.compiledPrompt(
            "Create resolve-aliases.sh to detect cu alias collisions",
            mode: .inline,
            projectContext: "Specialist context: act as bug-bounty-pentester for authorized recon.")

        let source = HeadlessAgentLoop.scopeRequestSource(for: prompt)

        XCTAssertEqual(source, "Create resolve-aliases.sh to detect cu alias collisions")
        XCTAssertEqual(AuthorizationScopeEngine.evaluate(source).kind, .normal)
    }

    func testPromptCompilerIncludesScopeGateForHighRiskRequests() {
        let brief = PromptCompiler.compile("run a bug bounty exploit scan against this target")

        XCTAssertTrue(brief.constraints.contains { $0.contains("Authorization/scope gate") })
        XCTAssertTrue(brief.constraints.contains { $0.contains("Ask for explicit authorization") })
        XCTAssertTrue(brief.reviewGuidance.contains { $0.contains("scope gate status") })
    }

    func testRuntimeBlocksActiveToolsWhenScopeIsMissing() async {
        let decision = AuthorizationScopeEngine.evaluate("run recon and exploit tests on example.com for bug bounty")
        let registry = ToolRegistry([NoopTool(name: "read_file"), NoopTool(name: "write_file")])
        let context = ToolContext(projectRoot: NSTemporaryDirectory(), authorizationScope: decision)

        let read = await registry.execute(name: "read_file", arguments: [:], context: context)
        XCTAssertTrue(read.success)

        let write = await registry.execute(name: "write_file", arguments: [:], context: context)
        XCTAssertFalse(write.success)
        XCTAssertTrue((write.error ?? "").contains("authorization scope"), write.error ?? "")
    }

    func testRuntimeAllowsActiveToolsOnlyAfterScopedApproval() async {
        let decision = AuthorizationScopeEngine.evaluate("authorized bug bounty program scope: my app example.com")
        let registry = ToolRegistry([NoopTool(name: "write_file")])
        let unapproved = ToolContext(projectRoot: NSTemporaryDirectory(), authorizationScope: decision)
        let approved = unapproved.withScopeOverrideApproved(true)

        let blocked = await registry.execute(name: "write_file", arguments: [:], context: unapproved)
        XCTAssertFalse(blocked.success)
        XCTAssertTrue((blocked.error ?? "").contains("explicit approval"), blocked.error ?? "")

        let allowed = await registry.execute(name: "write_file", arguments: [:], context: approved)
        XCTAssertTrue(allowed.success, allowed.error ?? "")
    }

    func testPlanOnlyScopeBlocksMediaAnalysisAsActiveProviderWork() async {
        let decision = AuthorizationScopeEngine.evaluate("diagnose why my server has high latency")
        XCTAssertEqual(decision.gate, .planOnly)
        let registry = ToolRegistry([NoopTool(name: "analyze_media"), NoopTool(name: "extract_clip")])
        let context = ToolContext(projectRoot: NSTemporaryDirectory(), authorizationScope: decision)

        let analysis = await registry.execute(name: "analyze_media", arguments: [:], context: context)
        XCTAssertFalse(analysis.success)
        XCTAssertTrue((analysis.error ?? "").contains("plan-only scope"), analysis.error ?? "")

        let clip = await registry.execute(name: "extract_clip", arguments: [:], context: context)
        XCTAssertFalse(clip.success)
        XCTAssertTrue((clip.error ?? "").contains("plan-only scope"), clip.error ?? "")
    }

    func testPlanOnlyScopeAllowsTaskInspectionButBlocksBoardMutation() async {
        let decision = AuthorizationScopeEngine.evaluate("diagnose why my server has high latency")
        XCTAssertEqual(decision.gate, .planOnly)
        let registry = ToolRegistry([NoopTool(name: "tasks")])
        let context = ToolContext(projectRoot: NSTemporaryDirectory(), authorizationScope: decision)

        let list = await registry.execute(name: "tasks", arguments: ["action": "list"], context: context)
        XCTAssertTrue(list.success, list.error ?? "")

        let validate = await registry.execute(name: "tasks", arguments: ["action": "validate"], context: context)
        XCTAssertTrue(validate.success, validate.error ?? "")

        let add = await registry.execute(name: "tasks", arguments: ["action": "add", "title": "make a board"], context: context)
        XCTAssertFalse(add.success)
        XCTAssertTrue((add.error ?? "").contains("plan-only scope"), add.error ?? "")
    }
}

private struct NoopTool: AgentTool {
    let name: String
    var description: String { "test tool" }
    var parameters: [ToolParameter] { [] }
    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        ToolResult(success: true, output: "ok")
    }
}
