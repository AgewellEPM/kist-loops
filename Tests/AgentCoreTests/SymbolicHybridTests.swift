import XCTest
@testable import AgentCore

/// R6 (2026-07-29): the symbolic-first hybrid wiring — the symbolic brain is reachable, the plan-execute
/// done-gate is symbolic-first, and the Jeeves wheel is a first-class grounding tool.
final class SymbolicHybridTests: XCTestCase {

    // MARK: - #2 · jeeves-floor symbolic READ tools are reachable (were silently denied in --loop)

    /// The floor's read tools name their read intent in the SECOND leaf token, so the first-token verb
    /// gate mis-classified them .dangerous → NonDestructiveInteractor denied them in autonomous loops.
    /// One assertion per tool (multi-site rule): each must now classify .safe.
    func testSymbolicBrainReadToolsAreSafe() {
        let readTools = ["symbolic_query", "proof_score", "check_contradiction",
                         "explain", "ibm_cobol_oracle", "engineering_rules"]
        for leaf in readTools {
            let name = "jeeves-floor__\(leaf)"
            XCTAssertEqual(ReversibilityClassifier.assess(tool: name, args: [:], projectRoot: "/tmp"), .safe,
                           "\(name) must be reachable (was silently denied in --loop)")
            XCTAssertTrue(ReversibilityClassifier.isReadOnlyMCPTool(name), name)
        }
    }

    /// teach_relation MUTATES the symbolic floor and must STAY gated — the allowlist is read-only-only.
    func testTeachRelationStaysDangerous() {
        let name = "jeeves-floor__teach_relation"
        XCTAssertEqual(ReversibilityClassifier.assess(tool: name, args: [:], projectRoot: "/tmp"), .dangerous)
        XCTAssertFalse(ReversibilityClassifier.isReadOnlyMCPTool(name))
    }

    /// A FOREIGN server can't borrow the trust by reusing a leaf name — the allowlist is per-server.
    func testForeignServerCannotBorrowSymbolicTrust() {
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "evil__symbolic_query", args: [:], projectRoot: "/tmp"),
                       .dangerous, "only jeeves-floor's proof/symbolic leaves are trusted, not any server's")
        XCTAssertFalse(ReversibilityClassifier.isTrustedReadOnlyMCPTool("evil__proof_score"))
    }

    // MARK: - perslis gateway build-cycle READ leaves (2026-08-19)

    /// Perslis's read leaves (build_status, artifact_read, gateway_capabilities, …) let an autonomous
    /// loop POLL a build cycle. One assertion per leaf (multi-site rule): each must classify .safe.
    func testPerslisGatewayReadLeavesAreSafe() {
        let readLeaves = ["build_status", "artifact_status", "artifact_read",
                          "gateway_capabilities", "gateway_identity",
                          "qualification_report", "perslis_info", "perslis_identity"]
        for leaf in readLeaves {
            let name = "perslis__\(leaf)"
            XCTAssertEqual(ReversibilityClassifier.assess(tool: name, args: [:], projectRoot: "/tmp"), .safe,
                           "\(name) must be pollable in --loop without a prompt")
            XCTAssertTrue(ReversibilityClassifier.isReadOnlyMCPTool(name), name)
        }
    }

    /// Perslis MUTATING verbs stay gated — submitting a build compiles inside a VM and writes
    /// artifacts. One assertion per verb class: submit, artifact writes, VM actuation, launch, cancel.
    func testPerslisMutatingVerbsStayDangerous() {
        for name in ["perslis__build_submit", "perslis__artifact_begin", "perslis__artifact_chunk",
                     "perslis__artifact_commit", "perslis__vm_type", "perslis__vm_click",
                     "perslis__legacy_launch", "perslis__build_cancel"] {
            XCTAssertEqual(ReversibilityClassifier.assess(tool: name, args: [:], projectRoot: "/tmp"),
                           .dangerous, "\(name) mutates gateway/VM state and must keep requiring approval")
            XCTAssertFalse(ReversibilityClassifier.isTrustedReadOnlyMCPTool(name), name)
        }
    }

    /// A foreign server can't borrow the perslis trust either — the allowlist stays per-server.
    func testForeignServerCannotBorrowPerslisTrust() {
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "evil__build_status", args: [:], projectRoot: "/tmp"),
                       .dangerous, "only the perslis server's read leaves are trusted")
        XCTAssertFalse(ReversibilityClassifier.isTrustedReadOnlyMCPTool("evil__gateway_capabilities"))
    }

    // MARK: - #1 · plan-execute symbolic done-gate (build/test must confirm a code change)

    /// A plan that edits code then runs a real build/test is symbolically verified.
    func testPlanTrajectoryVerifiedWhenBuildRanAfterEdit() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "edit", tool: "edit_file", argumentsJSON: #"{"path":"a.swift"}"#),
            PlanStep(id: "E2", intent: "build", tool: "run_command",
                     argumentsJSON: #"{"command":"swift build"}"#, dependsOn: ["E1"]),
        ])
        let exec = PlanExecution(success: true, stepResults: [
            StepResult(stepId: "E1", tool: "edit_file", success: true, output: "", error: nil),
            StepResult(stepId: "E2", tool: "run_command", success: true, output: "Build complete", error: nil),
        ], outputs: [:], failedStepId: nil)
        let traj = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertEqual(CompletionVerifier().check(trajectory: traj, canRunCommands: true), .accept)
    }

    /// A plan that edits code but never runs a build/test is NOT verified — the LLM critic must not be
    /// able to launder it into "done".
    func testPlanTrajectoryUnverifiedWhenNoBuildAfterEdit() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "edit", tool: "edit_file", argumentsJSON: #"{"path":"a.swift"}"#),
            PlanStep(id: "E2", intent: "peek", tool: "run_command",
                     argumentsJSON: #"{"command":"ls"}"#, dependsOn: ["E1"]),   // ls proves nothing
        ])
        let exec = PlanExecution(success: true, stepResults: [
            StepResult(stepId: "E1", tool: "edit_file", success: true, output: "", error: nil),
            StepResult(stepId: "E2", tool: "run_command", success: true, output: "a.swift", error: nil),
        ], outputs: [:], failedStepId: nil)
        let traj = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        guard case .needsVerification = CompletionVerifier().check(trajectory: traj, canRunCommands: true) else {
            return XCTFail("an unbuilt code change must not pass the symbolic gate")
        }
    }

    /// Review catch: a real build behind a `cd <long path> &&` preamble must be recognized — the
    /// generic 40-char fingerprint clipped the build verb and wrongly failed a genuinely-built run.
    func testLongCdPrefixedBuildIsRecognized() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "edit", tool: "edit_file", argumentsJSON: #"{"path":"a.swift"}"#),
            PlanStep(id: "E2", intent: "build", tool: "run_command",
                     argumentsJSON: #"{"command":"cd packages/backend/deep/service && npm run build"}"#, dependsOn: ["E1"]),
        ])
        let exec = PlanExecution(success: true, stepResults: [
            StepResult(stepId: "E1", tool: "edit_file", success: true, output: "", error: nil),
            StepResult(stepId: "E2", tool: "run_command", success: true, output: "built", error: nil),
        ], outputs: [:], failedStepId: nil)
        let traj = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertEqual(CompletionVerifier().check(trajectory: traj, canRunCommands: true), .accept,
                       "a real build behind a long cd-preamble must pass, not be clipped away")
    }

    /// Review catch: a `${id}`-chained build command must be RESOLVED before classification — the raw
    /// template `${E1}` is not a build verb, so an unresolved fingerprint over-blocked a built run.
    func testResolvedBuildCommandIsRecognized() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "pick cmd", tool: "read_file", argumentsJSON: #"{"path":"cmd.txt"}"#),
            PlanStep(id: "E2", intent: "edit", tool: "edit_file", argumentsJSON: #"{"path":"a.swift"}"#, dependsOn: ["E1"]),
            PlanStep(id: "E3", intent: "run it", tool: "run_command",
                     argumentsJSON: #"{"command":"${E1}"}"#, dependsOn: ["E2"]),
        ])
        let exec = PlanExecution(success: true, stepResults: [
            StepResult(stepId: "E1", tool: "read_file", success: true, output: "swift test", error: nil),
            StepResult(stepId: "E2", tool: "edit_file", success: true, output: "", error: nil),
            StepResult(stepId: "E3", tool: "run_command", success: true, output: "Test Suite passed", error: nil),
        ], outputs: ["E1": "swift test"], failedStepId: nil)
        let traj = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertEqual(CompletionVerifier().check(trajectory: traj, canRunCommands: true), .accept,
                       "${E1} → 'swift test' must be resolved + recognized as a build/test")
    }

    /// The scrubbed env for the Jeeves subprocess carries NO provider/API secrets (least privilege).
    func testJeevesSubprocessEnvIsScrubbed() {
        let env = JeevesResearchTool.scrubbedEnvironment()
        for secret in ["DEEPSEEK_API_KEY", "TAVILY_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "DASHSCOPE_API_KEY"] {
            XCTAssertNil(env[secret], "\(secret) must NOT leak into the research subprocess")
        }
    }

    /// A read-only plan (no code mutation) is trivially verified — the gate doesn't demand a pointless build.
    func testReadOnlyPlanNeedsNoBuild() {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "read", tool: "read_file", argumentsJSON: #"{"path":"a.swift"}"#),
        ])
        let exec = PlanExecution(success: true, stepResults: [
            StepResult(stepId: "E1", tool: "read_file", success: true, output: "…", error: nil),
        ], outputs: [:], failedStepId: nil)
        let traj = PlanExecuteLoop.verifyTrajectory(plan: plan, exec: exec)
        XCTAssertEqual(CompletionVerifier().check(trajectory: traj, canRunCommands: true), .accept)
    }

    // MARK: - #3 · Jeeves research is a first-class, fail-closed grounding tool

    func testJeevesResearchIsRegisteredAndReachable() {
        let reg = ToolRegistry.headless()
        XCTAssertNotNil(reg.all().first { $0.name == "jeeves_research" }, "the symbolic wheel must be a tool every loop sees")
        XCTAssertEqual(ReversibilityClassifier.assess(tool: "jeeves_research", args: ["query": "what is X"], projectRoot: "/tmp"),
                       .safe, "grounding a normal question is reachable (exfil-gated like web_search)")
    }

    func testJeevesResearchReturnsGroundedOutputFromTheWheel() async throws {
        let tool = JeevesResearchTool(runner: { q in
            ToolResult(success: true, output: "grounded: \(q) → 42", metadata: ["grounded": "true"]) })
        let r = try await tool.execute(arguments: ["query": "the answer"], context: ToolContext(projectRoot: "/tmp"))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.output, "grounded: the answer → 42")
        XCTAssertEqual(r.metadata["grounded"], "true")
    }

    func testJeevesResearchNeedsAQuery() async throws {
        let tool = JeevesResearchTool(runner: { _ in XCTFail("must not run the wheel on an empty query"); return .failure("x") })
        let r = try await tool.execute(arguments: [:], context: ToolContext(projectRoot: "/tmp"))
        XCTAssertFalse(r.success)
    }
}
