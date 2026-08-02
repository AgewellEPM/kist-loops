import XCTest
import Foundation
@testable import AgentCore

/// The closed plan→execute loop: propose → validate(+repair) → approve → execute, driven by a
/// scripted planner so it's deterministic and offline.
final class PlanExecuteLoopTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "pxl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    private func loop(_ responses: [String], interactor: RuntimeInteractor = AutoApproveInteractor(),
                      requireApproval: Bool = false, maxReplans: Int = 2, verifyGoal: Bool = false,
                      sink: RuntimeEventSink = NullEventSink()) -> PlanExecuteLoop {
        let registry = ProviderRegistry(providers: [PlanScriptedProvider(responses)], keyStore: PXLNullKeys())
        return PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                               tools: .headless(), context: ToolContext(projectRoot: root),
                               sink: sink, interactor: interactor, requireApproval: requireApproval,
                               maxReplans: maxReplans, verifyGoal: verifyGoal)
    }

    private func writePlan(id: String, path: String, content: String) -> String {
        #"{"steps":[{"id":"\#(id)","intent":"write","tool":"write_file","arguments":{"path":"\#(path)","content":"\#(content)"}}]}"#
    }

    private let validPlan = """
    {"goal":"write then read","steps":[
      {"id":"E1","intent":"write","tool":"write_file","arguments":{"path":"a.txt","content":"hi"},"dependsOn":[]},
      {"id":"E2","intent":"read","tool":"read_file","arguments":{"path":"a.txt"},"dependsOn":["E1"]}
    ]}
    """

    func testValidPlanIsProposedAndExecuted() async {
        let out = await loop([validPlan]).run(goal: "write a.txt then read it")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.plan?.steps.count, 2)
        XCTAssertTrue(out.execution?.success ?? false)
        XCTAssertEqual(try? String(contentsOfFile: root + "/a.txt", encoding: .utf8), "hi")
    }

    func testInvalidPlanGetsRepairedThenExecutes() async {
        let cyclic = #"{"goal":"g","steps":[{"id":"A","tool":"list_files","dependsOn":["B"]},{"id":"B","tool":"list_files","dependsOn":["A"]}]}"#
        let out = await loop([cyclic, validPlan]).run(goal: "do it")
        XCTAssertTrue(out.success, out.message)   // recovered on the 2nd (repaired) attempt
        XCTAssertEqual(out.plan?.steps.map(\.id), ["E1", "E2"])
    }

    func testUnparseableThenValid() async {
        let out = await loop(["I think we should start by exploring the repo.", validPlan]).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
    }

    func testNeverValidFailsAfterRepairs() async {
        let cyclic = #"{"goal":"g","steps":[{"id":"A","tool":"list_files","dependsOn":["B"]},{"id":"B","tool":"list_files","dependsOn":["A"]}]}"#
        // maxPlanRepairs defaults to 2 → 3 attempts, all invalid.
        let out = await loop([cyclic, cyclic, cyclic]).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertNil(out.execution)                       // never reached execution
        XCTAssertTrue(out.message.contains("could not produce"), out.message)
    }

    func testDeclinedPlanIsNotExecuted() async {
        let sink = PXLRecordingSink()
        let out = await loop([validPlan], interactor: PXLDeclining(), requireApproval: true, sink: sink).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertNotNil(out.plan)                          // a plan WAS produced…
        XCTAssertNil(out.execution)                        // …but never executed
        XCTAssertTrue(out.message.contains("declined"), out.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/a.txt"))
        // R3 (review catch): planReady armed the sink's per-step state — a silent return left the
        // live line claiming a plan was executing. The decline is a TERMINAL event.
        XCTAssertTrue(sink.saw { if case .cancelled = $0 { return true }; return false },
                      "declining the plan must emit a terminal event")
    }

    // MARK: - R3: the singular-step lint drives a re-split through the loop (behavioral, not grep)

    func testLumpyPlanIsResplitThroughTheLoop() async {
        // Attempt 1 chains 4 commands → lint feedback → attempt 2 is singular and EXECUTES.
        let lumpy = #"{"steps":[{"id":"E1","intent":"do everything","tool":"run_command","arguments":{"command":"mkdir x && cd x && npm init && npm test"}}]}"#
        let capt = CapturingProvider(id: "capt", responses: [lumpy, validPlan])
        let registry = ProviderRegistry(providers: [capt], keyStore: PXLNullKeys())
        let out = await PlanExecuteLoop(providers: registry, providerId: "capt", model: nil,
                                        tools: .headless(), context: ToolContext(projectRoot: root),
                                        requireApproval: false, verifyGoal: false).run(goal: "do it")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.plan?.steps.map(\.id), ["E1", "E2"], "the RE-SPLIT plan executed, not the lumpy one")
        let feedback = capt.lastMessages.contains {
            $0.content.contains("SINGULAR-STEP contract") && $0.content.contains("chains 4 shell commands")
        }
        XCTAssertTrue(feedback, "the planner must be told WHICH step was lumpy and why")
    }

    func testLintExhaustionExecutesLastValidPlanWithVisibleWarning() async {
        // ADVISORY at exhaustion (review catch): a lint false positive must never brick a run.
        // Every attempt trips the empty-intent lint; the plan is structurally valid — after the
        // repair budget it executes anyway, with the findings surfaced on the planReady summary.
        let lintOnly = #"{"steps":[{"id":"E1","intent":"  ","tool":"write_file","arguments":{"path":"ok.txt","content":"done"}}]}"#
        let sink = PXLRecordingSink()
        let out = await loop([lintOnly, lintOnly, lintOnly], sink: sink).run(goal: "write ok.txt")
        XCTAssertTrue(out.success, "lint-only findings must degrade, not fail: \(out.message)")
        XCTAssertEqual(try? String(contentsOfFile: root + "/ok.txt", encoding: .utf8), "done")
        XCTAssertTrue(sink.planReadySummaries.contains { $0.contains("lumpy steps accepted") },
                      "the degraded acceptance must be VISIBLE, not silent")
    }

    func testGoalNotMetWithReplansExhaustedEmitsFailed() async {
        // R3 (review catch): this exit returned silently while its step-failed sibling emitted
        // .failed — the sink's plan state stayed armed and the run ended with no verdict line.
        let sink = PXLRecordingSink()
        let notDone = #"{"done":false,"reason":"missing tests"}"#
        let out = await loop([validPlan, notDone], maxReplans: 0, verifyGoal: true, sink: sink).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("goal not fully met"), out.message)
        XCTAssertTrue(sink.saw { if case .failed(let r) = $0 { return r.contains("goal not fully met") }; return false },
                      "replans-exhausted must emit the same terminal .failed as its step-failed sibling")
    }

    func testApprovedPlanExecutes() async {
        let out = await loop([validPlan], interactor: AutoApproveInteractor(), requireApproval: true).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(try? String(contentsOfFile: root + "/a.txt", encoding: .utf8), "hi")
    }

    func testPlannerErrorIsReported() async {
        let registry = ProviderRegistry(providers: [PXLFailingProvider()], keyStore: PXLNullKeys())
        let l = PlanExecuteLoop(providers: registry, providerId: "pxlfail", model: nil,
                                tools: .headless(), context: ToolContext(projectRoot: root))
        let out = await l.run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("planner error"), out.message)
    }

    func testPlannerPromptDocumentsSchemaAndTools() {
        let p = PlanExecuteLoop.plannerSystemPrompt(tools: .headless(), projectRoot: "/tmp")
        XCTAssertTrue(p.contains("\"steps\""))
        XCTAssertTrue(p.contains("${E1}"))          // documents the ref syntax
        XCTAssertTrue(p.contains("Capability negotiation:"))
        XCTAssertTrue(p.contains("CAPABILITY NEGOTIATION"))
        XCTAssertTrue(p.contains("Filesystem"))
        XCTAssertTrue(p.contains("write_file"))     // advertises tools
    }

    // MARK: - Phase 1.4b: replan on failure + verify-the-goal gate

    func testReplanAfterFailureSucceeds() async {
        // Plan A reads a missing file (runtime failure) → R3 step-repair abstains ("{}") → replan →
        // Plan B writes a real file. Each failed step consumes one repair response from the script.
        let planA = #"{"steps":[{"id":"E1","intent":"read missing","tool":"read_file","arguments":{"path":"missing.txt"}}]}"#
        let planB = writePlan(id: "E1", path: "ok.txt", content: "recovered")
        let out = await loop([planA, "{}", planB]).run(goal: "produce ok.txt")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1)                                  // recovered after one replan
        XCTAssertEqual(try? String(contentsOfFile: root + "/ok.txt", encoding: .utf8), "recovered")
    }

    func testFailedPlanSideEffectsRemainInVerificationHistoryAcrossReplan() async {
        // Plan 1 leaves a source file behind and fails. Its repaired retry also fails. Plan 2 only
        // writes a README. Verifying plan 2 in isolation would accept and launder the source side effect;
        // the turn-scoped attempt history must keep it incomplete.
        let plan1 = #"{"steps":[{"id":"E1","intent":"partial source write","tool":"run_command","arguments":{"command":"printf broken > Sources/ReplanLeak.swift"}}]}"#
        let plan2 = writePlan(id: "E1", path: "README.md", content: "done")
        let done = #"{"done":true,"reason":"looks complete"}"#
        let provider = PlanScriptedProvider([plan1, "{}", plan2, done])
        let registry = ProviderRegistry(providers: [provider], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(
            providers: registry, providerId: "planscript", model: nil,
            tools: ToolRegistry([ReplanPartialFailureRunCommandTool(), WriteFileTool()]),
            context: ToolContext(projectRoot: root), requireApproval: false,
            maxReplans: 1, verifyGoal: true
        )

        let out = await loop.run(goal: "make the requested source change")

        XCTAssertFalse(out.success, "the clean-looking final plan must not erase prior-plan side effects")
        XCTAssertTrue(out.message.contains("source mutation failed"), out.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/Sources/ReplanLeak.swift"),
                      "the failed prior plan really changed the workspace")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/README.md"),
                      "the final successful non-source plan did run")
    }

    func testVerifyNotDoneTriggersReplan() async {
        // Plan 1 succeeds, but the verify gate says NOT done → replan → Plan 2 adds the missing file.
        let plan1 = writePlan(id: "E1", path: "one.txt", content: "1")
        let verdictNotDone = #"{"done":false,"reason":"two.txt is still missing"}"#
        let plan2 = writePlan(id: "E1", path: "two.txt", content: "2")
        let verdictDone = #"{"done":true,"reason":"both files exist"}"#
        let out = await loop([plan1, verdictNotDone, plan2, verdictDone], verifyGoal: true).run(goal: "create one.txt and two.txt")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/one.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/two.txt"))   // the replan-added file
    }

    func testReplanBudgetExhaustedReturnsFailure() async {
        // Both attempts fail at runtime (each followed by an abstaining "{}" R3 step-repair);
        // maxReplans=1 → one replan, then give up.
        let failA = #"{"steps":[{"id":"E1","intent":"read","tool":"read_file","arguments":{"path":"nope1.txt"}}]}"#
        let failB = #"{"steps":[{"id":"E1","intent":"read","tool":"read_file","arguments":{"path":"nope2.txt"}}]}"#
        let out = await loop([failA, "{}", failB, "{}"], maxReplans: 1).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertEqual(out.replansUsed, 1)
        XCTAssertTrue(out.message.contains("plan failed"), out.message)
    }

    func testVerifyDisabledSkipsGate() async {
        // verifyGoal:false → a mechanically-successful plan is done immediately (no verify call).
        let out = await loop([writePlan(id: "E1", path: "v.txt", content: "x")], verifyGoal: false).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 0)
    }

    func testVerifyGoalNotMetWithoutBudgetReturnsHonestFailure() async {
        // Plan succeeds but verify says not done, and there's no replan budget → honest partial fail.
        let plan = writePlan(id: "E1", path: "p.txt", content: "x")
        let notDone = #"{"done":false,"reason":"missing the summary"}"#
        let out = await loop([plan, notDone], maxReplans: 0, verifyGoal: true).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("goal not fully met"), out.message)
        XCTAssertTrue(out.message.contains("missing the summary"))
    }

    func testUnparseableVerifyFailsClosed() async {
        let plan = writePlan(id: "E1", path: "p.txt", content: "x")
        let out = await loop([plan, "I am unsure how to evaluate this."], maxReplans: 0, verifyGoal: true).run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("verification unavailable"), out.message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/p.txt"))
    }

    func testParseVerdict() {
        XCTAssertEqual(PlanExecuteLoop.parseVerdict(#"{"done":true,"reason":"ok"}"#)?.done, true)
        XCTAssertEqual(PlanExecuteLoop.parseVerdict(#"{"done":false,"reason":"more"}"#)?.reason, "more")
        XCTAssertEqual(PlanExecuteLoop.parseVerdict("Verdict: NOT_DONE — needs tests")?.done, false)  // NOT_DONE not tricked by substring DONE
        XCTAssertEqual(PlanExecuteLoop.parseVerdict("All good. DONE.")?.done, true)
        XCTAssertNil(PlanExecuteLoop.parseVerdict("I am unsure how to evaluate this."))   // → caller fails closed
    }

    // MARK: - Phase 2: cross-vendor role binding (planner vs critic)

    func testCriticUsesADifferentVendorThanPlanner() async {
        // planner→"plannerco" (emits the plan), critic→"criticco" (emits the verdict). If role
        // binding works, the verify call hits criticco, NOT a 2nd planner call. Proven by call counts.
        let planner = CountingProvider(id: "plannerco", responses: [writePlan(id: "E1", path: "team.txt", content: "x")])
        let critic  = CountingProvider(id: "criticco",  responses: [#"{"done":true,"reason":"looks complete"}"#])
        let registry = ProviderRegistry(providers: [planner, critic], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.critic: ProviderBinding(providerId: "criticco")])
        let loop = PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                   context: ToolContext(projectRoot: root), requireApproval: false, verifyGoal: true)
        let out = await loop.run(goal: "make team.txt")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(planner.count, 1, "planner should be called once (the plan)")
        XCTAssertEqual(critic.count, 1, "critic should be called once (the verify) — proves it's a separate vendor")
    }

    func testCriticVendorCanVetoAndForceReplan() async {
        // A separate critic vendor returns NOT_DONE → the planner vendor replans.
        let planner = CountingProvider(id: "plannerco", responses: [
            writePlan(id: "E1", path: "a.txt", content: "1"),
            writePlan(id: "E1", path: "b.txt", content: "2"),
        ])
        let critic = CountingProvider(id: "criticco", responses: [
            #"{"done":false,"reason":"need b.txt too"}"#,
            #"{"done":true,"reason":"ok now"}"#,
        ])
        let registry = ProviderRegistry(providers: [planner, critic], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.critic: ProviderBinding(providerId: "criticco")])
        let out = await PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                        context: ToolContext(projectRoot: root), requireApproval: false, verifyGoal: true).run(goal: "x")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(out.replansUsed, 1)            // the critic's veto forced one replan
        XCTAssertEqual(planner.count, 2)              // initial plan + replan
        XCTAssertEqual(critic.count, 2)               // verified twice
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/b.txt"))
    }

    func testCoderVendorGeneratesContentThatFlowsIntoAWrite() async {
        // The full team: planner plans a generate→write DAG, the CODER vendor produces the content,
        // ${E1} flows it into write_file. Proves the coder is a real third teammate.
        let plan = """
        {"steps":[
          {"id":"E1","intent":"draft","tool":"generate","arguments":{"prompt":"write a greeting"}},
          {"id":"E2","intent":"save","tool":"write_file","arguments":{"path":"greeting.txt","content":"${E1}"},"dependsOn":["E1"]}
        ]}
        """
        let planner = CountingProvider(id: "plannerco", responses: [plan])
        let coder   = CountingProvider(id: "coderco",   responses: ["Hello from the coder vendor!"])
        let registry = ProviderRegistry(providers: [planner, coder], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.coder: ProviderBinding(providerId: "coderco")])
        let out = await PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                        context: ToolContext(projectRoot: root), requireApproval: false,
                                        verifyGoal: false).run(goal: "make a greeting file")
        XCTAssertTrue(out.success, out.message)
        XCTAssertEqual(coder.count, 1, "the generate step must run on the CODER vendor")
        XCTAssertEqual(try? String(contentsOfFile: root + "/greeting.txt", encoding: .utf8),
                       "Hello from the coder vendor!")   // coder output flowed via ${E1} into the file
    }

    // MARK: - Phase 3: observability + cost governance

    func testZeroBudgetHaltsBeforeAnyWork() async {
        let registry = ProviderRegistry(providers: [PlanScriptedProvider([validPlan])], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, budget: BudgetLedger(maxTokens: 0))
        let out = await loop.run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("budget exceeded"), out.message)
        XCTAssertNil(out.plan)   // halted before producing a plan
    }

    func testBudgetCeilingHaltsReplanLoop() async {
        // A plan that fails at runtime triggers a replan; a tiny budget (exceeded after the first
        // planner call's estimate) makes the next iteration halt with an honest budget failure.
        let failPlan = #"{"steps":[{"id":"E1","intent":"read","tool":"read_file","arguments":{"path":"missing.txt"}}]}"#
        let registry = ProviderRegistry(providers: [PlanScriptedProvider([failPlan, failPlan])], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, verifyGoal: false, budget: BudgetLedger(maxTokens: 5))
        let out = await loop.run(goal: "x")
        XCTAssertFalse(out.success)
        XCTAssertTrue(out.message.contains("budget exceeded"), out.message)
    }

    func testTraceRecordsSpansPerRoleAndVendor() async {
        let planner = CountingProvider(id: "plannerco", responses: [writePlan(id: "E1", path: "t.txt", content: "x")])
        let critic  = CountingProvider(id: "criticco",  responses: [#"{"done":true,"reason":"ok"}"#])
        let registry = ProviderRegistry(providers: [planner, critic], keyStore: PXLNullKeys())
        let roles = RoleBindings(default: ProviderBinding(providerId: "plannerco"),
                                 [.critic: ProviderBinding(providerId: "criticco")])
        let recorder = TraceRecorder(traceId: "t1")
        let out = await PlanExecuteLoop(providers: registry, roles: roles, tools: .headless(),
                                        context: ToolContext(projectRoot: root), requireApproval: false,
                                        verifyGoal: true, recorder: recorder).run(goal: "make t.txt")
        XCTAssertTrue(out.success, out.message)
        let byRole = await recorder.tokensByRole()
        let byVendor = await recorder.tokensByVendor()
        XCTAssertNotNil(byRole["planner"])               // planner span recorded
        XCTAssertNotNil(byRole["critic"])                // critic span recorded (verify gate)
        XCTAssertNotNil(byVendor["plannerco"])           // attributed to the planner vendor
        XCTAssertNotNil(byVendor["criticco"])            // attributed to the critic vendor
    }

    // MARK: - Phase 4: cross-run memory

    func testRunRecordsEpisodeOnCompletion() async {
        let mem = ProjectMemory(root: root)
        let registry = ProviderRegistry(providers: [PlanScriptedProvider([validPlan])], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "planscript", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, verifyGoal: false, memory: mem)
        let out = await loop.run(goal: "write a.txt then read it")
        XCTAssertTrue(out.success, out.message)
        let episodes = mem.recentEpisodes()
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.goal, "write a.txt then read it")
        XCTAssertEqual(episodes.first?.success, true)
    }

    func testMemoryContextInjectedIntoPlanner() async throws {
        try "Build: swift build".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "earlier task", success: false, summary: "it failed", at: Date(timeIntervalSince1970: 1)))
        let capt = CapturingProvider(id: "capt", responses: [validPlan])
        let registry = ProviderRegistry(providers: [capt], keyStore: PXLNullKeys())
        let loop = PlanExecuteLoop(providers: registry, providerId: "capt", model: nil,
                                   tools: .headless(), context: ToolContext(projectRoot: root),
                                   requireApproval: false, verifyGoal: false, memory: mem)
        _ = await loop.run(goal: "do the thing")
        // The planner saw the project facts AND the prior episode as advisory context.
        let injected = capt.lastMessages.contains { $0.content.contains("PROJECT MEMORY") && $0.content.contains("swift build") }
        let sawEpisode = capt.lastMessages.contains { $0.content.contains("[failed] earlier task") }
        XCTAssertTrue(injected, "memory facts must be injected into the planner context")
        XCTAssertTrue(sawEpisode, "recent episodes must be injected")
    }

    func testNoMemoryMeansNoInjectionOrRecord() async {
        // Without a ProjectMemory, behavior is unchanged: no .mythos dir created.
        let out = await loop([validPlan]).run(goal: "x")
        XCTAssertTrue(out.success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/.mythos"))
    }

    func testReplanPromptsCarryContext() {
        let exec = PlanExecution(success: false,
                                 stepResults: [StepResult(stepId: "E1", tool: "read_file", success: false, output: "no such file", error: "no such file")],
                                 outputs: ["E1": "no such file"], failedStepId: "E1")
        let f = PlanExecuteLoop.replanFromFailure(goal: "do it", exec: exec)
        XCTAssertTrue(f.contains("FAILED at step E1"))
        XCTAssertTrue(f.contains("do it"))
        let v = PlanExecuteLoop.replanFromVerify(goal: "do it", reason: "missing x")
        XCTAssertTrue(v.contains("NOT yet fully met"))
        XCTAssertTrue(v.contains("missing x"))
    }

    func testReplanFromValidationFailureCarriesUsefulReason() {
        let exec = PlanExecution(success: false, stepResults: [], outputs: [:], failedStepId: nil)
        let f = PlanExecuteLoop.replanFromFailure(goal: "do it", exec: exec)
        XCTAssertTrue(f.contains("FAILED at step validation"))
        XCTAssertTrue(f.contains("plan validation failed before any executable step"))
        XCTAssertTrue(f.contains("do it"))
    }
}

// MARK: - Test doubles (local to avoid cross-file private collisions)

private struct PXLNullKeys: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private struct PXLDeclining: RuntimeInteractor {
    func requestApproval(planSummary: String) async -> Bool { false }
    func requestInput(question: String) async -> String { "" }
}

/// Thread-safe event recorder — lets tests pin TERMINAL events (the sink contract), not just outcomes.
private final class PXLRecordingSink: RuntimeEventSink, @unchecked Sendable {
    private let lock = NSLock(); private var _events: [RuntimeEvent] = []
    func emit(_ event: RuntimeEvent) { lock.lock(); _events.append(event); lock.unlock() }
    func saw(_ predicate: (RuntimeEvent) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }; return _events.contains(where: predicate)
    }
    var planReadySummaries: [String] {
        lock.lock(); defer { lock.unlock() }
        return _events.compactMap { if case .planReady(let s, _) = $0 { return s }; return nil }
    }
}

private final class PlanScriptedProvider: ChatProvider {
    let id = "planscript", name = "PlanScript", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "planscript", defaultModel = "p1"
    let availableModels = [AIModel(id: "p1")]
    private let responses: PXLResponses
    init(_ responses: [String]) { self.responses = PXLResponses(responses) }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let r = await responses.next()
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

private actor PXLResponses {
    private let responses: [String]; private var idx = 0
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String { defer { idx += 1 }; return idx < responses.count ? responses[idx] : "still not a plan" }
}

private struct ReplanPartialFailureRunCommandTool: AgentTool {
    let name = "run_command"
    let description = "writes source before failing, for replan evidence tests"
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        if arguments["command"] as? String != nil {
            try FileManager.default.createDirectory(atPath: context.projectRoot + "/Sources",
                                                    withIntermediateDirectories: true)
            try "broken".write(toFile: context.projectRoot + "/Sources/ReplanLeak.swift",
                               atomically: true, encoding: .utf8)
            return .failure("failed after partial source write")
        }
        return .failure("repair did not reconcile partial write")
    }
}

/// Scripted provider that records how many times it was streamed — lets a test PROVE which vendor
/// served a given call (planner vs critic).
private final class CountingProvider: ChatProvider, @unchecked Sendable {
    let id: String, name = "Counting", iconName = "cpu"
    let requiresAPIKey = false, keyAccount: String, defaultModel = "c1"
    let availableModels = [AIModel(id: "c1")]
    private let lock = NSLock(); private let responses: [String]; private var idx = 0
    init(id: String, responses: [String]) { self.id = id; self.keyAccount = id; self.responses = responses }
    var count: Int { lock.lock(); defer { lock.unlock() }; return idx }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); let r = idx < responses.count ? responses[idx] : "still not a plan"; idx += 1; lock.unlock()
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

/// Records the messages it was last streamed — lets a test assert what context the planner saw.
private final class CapturingProvider: ChatProvider, @unchecked Sendable {
    let id: String, name = "Capt", iconName = "cpu"
    let requiresAPIKey = false, keyAccount: String, defaultModel = "c1"
    let availableModels = [AIModel(id: "c1")]
    private let lock = NSLock(); private let responses: [String]; private var idx = 0
    private var _last: [ChatMessage] = []
    var lastMessages: [ChatMessage] { lock.lock(); defer { lock.unlock() }; return _last }
    init(id: String, responses: [String]) { self.id = id; self.keyAccount = id; self.responses = responses }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock(); _last = messages; let r = idx < responses.count ? responses[idx] : "still not a plan"; idx += 1; lock.unlock()
        return AsyncThrowingStream { c in c.yield(.delta(r)); c.finish() }
    }
}

private struct PXLFailingProvider: ChatProvider {
    let id = "pxlfail", name = "Fail", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "pxlfail", defaultModel = "x"
    let availableModels = [AIModel(id: "x")]
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        throw AIProviderError.transport("boom")
    }
}
