import XCTest
@testable import AgentCore
@testable import Kist

/// R3 (2026-07-28): missions + micro-tasks. A lumpy plan never executes (PlanLint reject → planner
/// re-split), a failed step self-repairs once instead of failing the mission, and the terminal
/// always shows WHERE the mission is (`w2 · E3/8 write_file`) plus a 5-minute stall alarm.
final class R3MicroTaskTests: XCTestCase {

    private func step(_ id: String, tool: String = "list_files", intent: String = "do one thing",
                      args: String = "{}", deps: [String] = []) -> PlanStep {
        PlanStep(id: id, intent: intent, tool: tool, argumentsJSON: args, dependsOn: deps)
    }

    // MARK: - PlanLint: the singular-step contract

    func testChainedSegmentCounting() {
        XCTAssertEqual(PlanLint.chainedSegments(""), 0)
        XCTAssertEqual(PlanLint.chainedSegments("make test"), 1)
        XCTAssertEqual(PlanLint.chainedSegments("cd x && make"), 2, "a cd+cmd pair is allowed")
        XCTAssertEqual(PlanLint.chainedSegments("a && b && c"), 3)
        XCTAssertEqual(PlanLint.chainedSegments("a; b; c"), 3)
    }

    func testChainedSegmentsIsQuoteAware() {
        // Separators inside quotes are DATA, not chained work — a false positive burns a
        // plan-repair slot with misdiagnosing feedback (review catch).
        XCTAssertEqual(PlanLint.chainedSegments(#"git commit -m "fix && polish; cleanup""#), 1)
        XCTAssertEqual(PlanLint.chainedSegments("echo 'a; b; c'"), 1)
        XCTAssertEqual(PlanLint.chainedSegments(#"find . -name '*.tmp' -exec rm {} \;"#), 1, "escaped ; is find syntax")
        XCTAssertEqual(PlanLint.chainedSegments(#"awk '{print $1};1' data.txt"#), 1)
    }

    func testChainedSegmentsCatchesNewlineAndOrChains() {
        // The && spelling's SIBLING bypasses (review catch: the planner prompt steers models
        // toward newlines) — every separator spelling of the contract gets its own pin.
        XCTAssertEqual(PlanLint.chainedSegments("mkdir x\ncd x\nnpm init\nnpm test"), 4, "newline chain")
        XCTAssertEqual(PlanLint.chainedSegments("a || b || c"), 3, "|| chain")
        XCTAssertEqual(PlanLint.chainedSegments("grep x f.txt | sort | uniq"), 1, "a pipeline is ONE unit")
        XCTAssertEqual(PlanLint.chainedSegments("server --daemon &"), 1, "background & is not a chain")
    }

    func testShellPayloadLinting() {
        XCTAssertEqual(PlanLint.shellPayloadSegments("sh -c 'a && b && c'"), 3, "sh -c must not launder a chain")
        XCTAssertEqual(PlanLint.shellPayloadSegments("bash -lc \"make && make test && make install\""), 3)
        XCTAssertEqual(PlanLint.shellPayloadSegments("sh -c 'for i in a b; do echo $i; done'"), 1,
                       "a control structure is ONE unit of work")
        XCTAssertNil(PlanLint.shellPayloadSegments("make test"), "not a shell -c invocation")
    }

    func testLumpyRunCommandStepIsRejected() {
        let plan = ExecutablePlan(goal: "g", steps: [
            step("E1", tool: "run_command", args: #"{"command":"mkdir x && cd x && npm init && npm test"}"#),
        ])
        let findings = PlanLint.findings(for: plan)
        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(findings[0].contains("chains 4 shell commands"), findings[0])
    }

    func testSingularPlanPassesAndPairIsAllowed() {
        let plan = ExecutablePlan(goal: "g", steps: [
            step("E1", tool: "run_command", args: #"{"command":"cd x && make"}"#),
            step("E2", tool: "write_file"),
        ])
        XCTAssertTrue(PlanLint.findings(for: plan).isEmpty)
    }

    func testEmptyIntentAndOverDecompositionFlagged() {
        let empty = ExecutablePlan(goal: "g", steps: [step("E1", intent: "  ")])
        XCTAssertTrue(PlanLint.findings(for: empty).contains { $0.contains("empty intent") })
        let huge = ExecutablePlan(goal: "g", steps: (1...25).map { step("E\($0)") })
        XCTAssertTrue(PlanLint.findings(for: huge).contains { $0.contains("over-decomposed") })
    }

    func testPlannerPromptCarriesTheContractAndLoopEnforcesIt() throws {
        let prompt = PlanExecuteLoop.plannerSystemPrompt(tools: .headless(), projectRoot: "/tmp")
        XCTAssertTrue(prompt.contains("SINGULAR STEPS"), "the planner must be TOLD the contract, not just linted")
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loop = try String(contentsOf: repo.appendingPathComponent("Sources/AgentCore/PlanExecuteLoop.swift"), encoding: .utf8)
        XCTAssertTrue(loop.contains("PlanLint.findings"), "obtainPlan no longer lints — lumpy plans execute again")
    }

    // MARK: - per-step self-repair

    /// Fails unless arguments contain ok=true — the shape of an arg-fixable failure.
    private struct FlakyTool: AgentTool {
        let name = "flaky"
        let description = "test tool"
        let parameters: [ToolParameter] = []
        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            (arguments["ok"] as? Bool) == true
                ? ToolResult(success: true, output: "fixed and done")
                : .failure("bad arguments: ok must be true")
        }
    }

    private func tmpContext() throws -> ToolContext {
        let tmp = NSTemporaryDirectory() + "r3-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        return ToolContext(projectRoot: tmp)
    }

    func testFailedStepIsRepairedOnceAndMissionContinues() async throws {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "flaky work", tool: "flaky", argumentsJSON: #"{"ok":false}"#),
        ])
        let exec = await PlanExecutor(tools: ToolRegistry([FlakyTool()]), context: try tmpContext(),
                                      repairStep: { step, ranArgs, failure in
                                          XCTAssertEqual(step.id, "E1")
                                          XCTAssertEqual(ranArgs["ok"] as? Bool, false, "repairer sees the args that RAN")
                                          XCTAssertTrue(failure.error?.contains("bad arguments") == true)
                                          return ["ok": true]
                                      }).execute(plan)
        XCTAssertTrue(exec.success, "a repaired step must not fail the mission: \(exec.stepResults)")
        XCTAssertEqual(exec.outputs["E1"], "fixed and done")
    }

    func testWithoutRepairerTheStepStillFails() async throws {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "flaky work", tool: "flaky", argumentsJSON: #"{"ok":false}"#),
        ])
        let exec = await PlanExecutor(tools: ToolRegistry([FlakyTool()]), context: try tmpContext()).execute(plan)
        XCTAssertFalse(exec.success)
        XCTAssertEqual(exec.failedStepId, "E1")
    }

    func testHopelessRepairDoesNotLoop() async throws {
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "flaky work", tool: "flaky", argumentsJSON: #"{"ok":false}"#),
        ])
        let calls = MutableBox(0)
        let exec = await PlanExecutor(tools: ToolRegistry([FlakyTool()]), context: try tmpContext(),
                                      repairStep: { _, _, _ in calls.value += 1; return ["ok": false] }).execute(plan)
        XCTAssertFalse(exec.success)
        XCTAssertEqual(calls.value, 1, "exactly ONE repair attempt per step")
        XCTAssertTrue(exec.stepResults.last?.error?.contains("repaired-args retry also failed") == true,
                      "the FINAL state (retry failed too) is recorded, not the stale original error")
    }

    func testRepairBudgetIsThreePerPlanRun() async throws {
        // maxStepRepairs pins the per-RUN cap — one-per-step alone would allow unbounded repair
        // spend on a wide wave (review catch: the 3-cap had zero assertions).
        let plan = ExecutablePlan(goal: "g", steps: (1...4).map {
            PlanStep(id: "E\($0)", intent: "flaky \($0)", tool: "flaky", argumentsJSON: #"{"ok":false}"#)
        })
        let calls = MutableBox(0)
        _ = await PlanExecutor(tools: ToolRegistry([FlakyTool()]), context: try tmpContext(),
                               repairStep: { _, _, _ in calls.value += 1; return ["ok": false] }).execute(plan)
        XCTAssertEqual(calls.value, 3, "exactly maxStepRepairs total repair attempts per plan run")
    }

    func testRepairerSeesResolvedArgsNotTheTemplate() async throws {
        // E2's args reference ${E1}. The repairer must be shown the RESOLVED values that actually
        // ran — diagnosing against the template is diagnosing args that never executed (review
        // catch: the prompt previously printed step.argumentsJSON verbatim).
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "produce", tool: "flaky", argumentsJSON: #"{"ok":true}"#),
            PlanStep(id: "E2", intent: "consume", tool: "flaky",
                     argumentsJSON: #"{"ok":false,"ref":"${E1}"}"#, dependsOn: ["E1"]),
        ])
        let seen = MutableBox("")
        _ = await PlanExecutor(tools: ToolRegistry([FlakyTool()]), context: try tmpContext(),
                               repairStep: { step, ranArgs, _ in
                                   if step.id == "E2" { seen.value = ranArgs["ref"] as? String ?? "" }
                                   return nil
                               }).execute(plan)
        XCTAssertEqual(seen.value, "fixed and done", "the ${E1} reference arrives RESOLVED")
    }

    /// Fails unless ok=true; counts executions; classifier-relevant name (`write_file` + escaping
    /// path = dangerous) so the RETRY gate is exercised with model-invented args.
    private final class CountingWriteTool: AgentTool, @unchecked Sendable {
        let name = "write_file"
        let description = "test tool"
        let parameters: [ToolParameter] = []
        let lock = NSLock(); var executions = 0
        func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
            lock.lock(); executions += 1; lock.unlock()
            return (arguments["ok"] as? Bool) == true
                ? ToolResult(success: true, output: "wrote it")
                : .failure("bad arguments: ok must be true")
        }
    }

    // Approval-gate sites are a MULTI-SITE surface: site 1 = wave launch (pinned in
    // PlanExecutorTests), site 2 = repaired-args retry (pinned HERE). The retry runs model-invented
    // arguments, so it re-classifies on the NEW args and must clear the same gate.

    func testRepairedRetryThatTurnsDangerousIsGatedAndDeclineStopsIt() async throws {
        let tool = CountingWriteTool()
        let gateCalls = MutableBox(0)
        let plan = ExecutablePlan(goal: "g", steps: [
            // Launch args are project-confined (NOT dangerous) → no launch gate. The "repair"
            // rewrites the path to escape the project → retry classifies dangerous → gate → decline.
            PlanStep(id: "E1", intent: "write", tool: "write_file",
                     argumentsJSON: #"{"ok":false,"path":"inside.txt"}"#),
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([tool]), context: try tmpContext(),
            approveDangerous: { _, args in
                gateCalls.value += 1
                XCTAssertEqual(args["path"] as? String, "/tmp/escaped-elsewhere.txt",
                               "the gate must see the REPAIRED args, not the originals")
                return false
            },
            repairStep: { _, _, _ in ["ok": true, "path": "/tmp/escaped-elsewhere.txt"] }).execute(plan)
        XCTAssertFalse(exec.success, "declined retry must leave the step failed")
        XCTAssertEqual(gateCalls.value, 1, "retry with dangerous repaired args consults the gate")
        XCTAssertEqual(tool.executions, 1, "the declined retry must NOT execute the tool again")
    }

    func testRepairedRetryApprovedAtGateRunsAndSucceeds() async throws {
        let tool = CountingWriteTool()
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "write", tool: "write_file",
                     argumentsJSON: #"{"ok":false,"path":"inside.txt"}"#),
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([tool]), context: try tmpContext(),
            approveDangerous: { _, _ in true },
            repairStep: { _, _, _ in ["ok": true, "path": "/tmp/escaped-elsewhere.txt"] }).execute(plan)
        XCTAssertTrue(exec.success, "an approved repaired retry completes the mission: \(exec.stepResults)")
        XCTAssertEqual(tool.executions, 2, "original attempt + approved retry")
    }

    func testLaunchDeclinedStepIsNeverRepaired() async throws {
        // The decline was a DECISION, not a malfunction — repair must not resurrect it (review
        // catch: this guard had zero coverage; it's flag-checked now, not error-string-sniffed).
        let tool = CountingWriteTool()
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "write outside", tool: "write_file",
                     argumentsJSON: #"{"ok":true,"path":"/tmp/escaped-elsewhere.txt"}"#),   // dangerous at LAUNCH
        ])
        let exec = await PlanExecutor(
            tools: ToolRegistry([tool]), context: try tmpContext(),
            approveDangerous: { _, _ in false },
            repairStep: { _, _, _ in XCTFail("a gate-declined step must not reach the repairer"); return nil }
        ).execute(plan)
        XCTAssertFalse(exec.success)
        XCTAssertEqual(exec.stepResults.first?.declinedAtGate, true)
        XCTAssertEqual(tool.executions, 0, "declined at launch — never executed at all")
    }

    func testDeclinedStepEmitsExactlyOneActionFinished() async throws {
        // PRE-EXISTING double-emit (review catch): the gate preempt emitted actionFinished inline
        // AND the wave merge loop emitted it again — one decline printed two ✗ lines.
        final class CountingSink: RuntimeEventSink, @unchecked Sendable {
            let lock = NSLock(); var finishes = 0
            func emit(_ event: RuntimeEvent) {
                if case .actionFinished = event { lock.lock(); finishes += 1; lock.unlock() }
            }
        }
        let sink = CountingSink()
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "write outside", tool: "write_file",
                     argumentsJSON: #"{"ok":true,"path":"/tmp/escaped-elsewhere.txt"}"#),
        ])
        _ = await PlanExecutor(tools: ToolRegistry([CountingWriteTool()]), context: try tmpContext(),
                               sink: sink, approveDangerous: { _, _ in false }).execute(plan)
        XCTAssertEqual(sink.finishes, 1, "one declined step = ONE ✗ line")
    }

    // MARK: - repair prompt plumbing

    func testParseArgumentsObject() {
        XCTAssertEqual(PlanExecuteLoop.parseArgumentsObject(#"{"path":"a.txt"}"#)?["path"] as? String, "a.txt")
        XCTAssertEqual(PlanExecuteLoop.parseArgumentsObject("Here you go:\n```json\n{\"n\": 2}\n```")?["n"] as? Int, 2)
        XCTAssertNil(PlanExecuteLoop.parseArgumentsObject("{}"), "empty object = cannot fix = no retry")
        XCTAssertNil(PlanExecuteLoop.parseArgumentsObject("no json here"))
        XCTAssertNil(PlanExecuteLoop.parseArgumentsObject(#"{"path":"${E1}/out.txt"}"#),
                     "an echoed ${id} would execute LITERALLY (no re-resolution) — must abstain")
    }

    func testStepRepairPromptShowsResolvedArgsNotTemplate() {
        let p = PlanExecuteLoop.stepRepairPrompt(
            step: PlanStep(id: "E2", intent: "write it", tool: "write_file",
                           argumentsJSON: #"{"path":"${E1}"}"#),
            ranArgs: ["path": "real-resolved.txt"],
            failure: StepResult(stepId: "E2", tool: "write_file", success: false, output: "", error: "missing path"))
        XCTAssertTrue(p.contains("write_file"))
        XCTAssertTrue(p.contains("missing path"))
        XCTAssertTrue(p.contains("LITERAL values only"))
        XCTAssertTrue(p.contains("real-resolved.txt"), "the prompt shows what actually RAN")
        XCTAssertFalse(p.contains("${E1}"), "the unresolved template must not leak into the ask")
    }

    // 2026-08-04 dogfood: run_command set error="exit code 1" while nasm's REAL diagnostic lived in
    // `output`; the repair prompt read only `error ?? output` so the coder retried blind. Both must show.
    func testStepRepairPromptSurfacesCapturedOutputNotJustTerseError() {
        let p = PlanExecuteLoop.stepRepairPrompt(
            step: PlanStep(id: "E3", intent: "assemble", tool: "run_command",
                           argumentsJSON: #"{"command":"nasm hello.asm"}"#),
            ranArgs: ["command": "nasm -f bin hello.asm -o hello.com"],
            failure: StepResult(stepId: "E3", tool: "run_command", success: false,
                                output: "hello.asm:1: error: label or instruction expected, found `'",
                                error: "exit code 1"))
        XCTAssertTrue(p.contains("exit code 1"), "the terse error is still shown")
        XCTAssertTrue(p.contains("hello.asm:1: error"), "the REAL captured diagnostic must reach the repairer")
    }

    func testDangerousStepSummaryShowsTheArgsBeingApproved() {
        // A repaired retry runs model-invented args nobody has reviewed — approving on the tool
        // name alone is uninformed consent (review catch: the gate prompt dropped the args).
        let s = PlanExecuteLoop.dangerousStepSummary(tool: "write_file",
                                                     args: ["path": "/tmp/escaped-elsewhere.txt", "ok": true])
        XCTAssertTrue(s.contains("write_file"))
        XCTAssertTrue(s.contains("/tmp/escaped-elsewhere.txt"), "the human must SEE the path they approve")
        let long = PlanExecuteLoop.compactArgs(["k": String(repeating: "x", count: 500)])
        XCTAssertLessThan(long.count, 260, "args preview stays bounded")
        XCTAssertTrue(PlanExecuteLoop.compactArgs([:]).isEmpty)
    }

    // MARK: - live progress rendering

    func testStepPositionFormatting() {
        // "step 3/8", not "E3/8" — a fabricated E-id can contradict the plan's REAL step ids
        // shown in the plan map (review catch).
        XCTAssertEqual(TerminalEventSink.stepPosition(wave: 2, index: 3, total: 8), "w2 · step 3/8")
        XCTAssertEqual(TerminalEventSink.stepPosition(wave: 0, index: 1, total: 4), "step 1/4")
    }

    func testCompactPlanLineFromRenderedSummary() {
        let summary = """
        Plan for: build the thing
          E1. read the config — read_file
          E2. produce the code — generate (after E1)
          E3. write it out — write_file (after E2)
        """
        XCTAssertEqual(TerminalEventSink.compactPlanLine(summary: summary),
                       "E1 read_file → E2 generate → E3 write_file")
        XCTAssertNil(TerminalEventSink.compactPlanLine(summary: "Plan for: nothing"))
    }

    func testCompactPlanLineCrossPinnedAgainstRealRenderOutput() {
        // DRIFT TRAP (review catch): the hand-written fixture above proves nothing about the
        // actual producer. This pin crosses the seam — if PlanExecuteLoop.render changes shape,
        // the plan map must not silently vanish with a green suite.
        let plan = ExecutablePlan(goal: "build the thing", steps: [
            PlanStep(id: "E1", intent: "read the config", tool: "read_file", argumentsJSON: "{}"),
            PlanStep(id: "E2", intent: "produce the code", tool: "generate", argumentsJSON: "{}", dependsOn: ["E1"]),
            PlanStep(id: "E3", intent: "write it out", tool: "write_file", argumentsJSON: "{}", dependsOn: ["E2"]),
        ])
        XCTAssertEqual(TerminalEventSink.compactPlanLine(summary: PlanExecuteLoop.render(plan)),
                       "E1 read_file → E2 generate → E3 write_file")
    }

    func testCompactPlanLineSurvivesEmDashInsideIntent() {
        // Intents are model-written free text — " — " inside one must not corrupt the tool name
        // (the parser splits on the LAST separator, review catch).
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "read the config — the main one", tool: "read_file", argumentsJSON: "{}"),
        ])
        XCTAssertEqual(TerminalEventSink.compactPlanLine(summary: PlanExecuteLoop.render(plan)), "E1 read_file")
    }

    func testCompactPlanLineSkipsAppendedProseSections() {
        // planSummary can carry scope-approval / lint-warning prose after the step lines — those
        // lines must not parse as steps.
        let summary = """
        Plan for: g
          E1. write — write_file

        ⚠ lumpy steps accepted after 3 re-split attempts:
        - step E1 chains 4 shell commands — split into singular steps (at most two chained commands per step, e.g. `cd X && make`)
        """
        XCTAssertEqual(TerminalEventSink.compactPlanLine(summary: summary), "E1 write_file")
    }

    // MARK: - stall alarm (pure decision, unit-tested — review catch: only the constant was pinned)

    func testStallWarningFiresOncePerStretchAndResetsOnProgress() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let after6m = t0.addingTimeInterval(360)
        // 1) past threshold + not yet warned → warns, naming what it's stuck on
        let w = TerminalEventSink.stallWarning(lastProgressAt: t0, now: after6m, alreadyWarned: false,
                                               what: "w2 · step 3/8 write_file")
        XCTAssertTrue(w?.contains("w2 · step 3/8 write_file") == true, "\(String(describing: w))")
        XCTAssertTrue(w?.contains("ESC") == true, "the warning teaches the escape hatch")
        // 2) already warned this stretch → stays quiet (no bell spam)
        XCTAssertNil(TerminalEventSink.stallWarning(lastProgressAt: t0, now: after6m,
                                                    alreadyWarned: true, what: "x"))
        // 3) fresh progress (any event resets lastProgressAt/alreadyWarned) → quiet until the
        //    NEXT full stretch, then warns again
        XCTAssertNil(TerminalEventSink.stallWarning(lastProgressAt: after6m, now: after6m.addingTimeInterval(60),
                                                    alreadyWarned: false, what: "x"))
        XCTAssertNotNil(TerminalEventSink.stallWarning(lastProgressAt: after6m, now: after6m.addingTimeInterval(301),
                                                       alreadyWarned: false, what: "x"))
    }

    // MARK: - per-site pins: the R3 sink state resets (multi-site rule)

    /// The reset `planStepCount = 0; currentWave = 0; liveDetail = nil` lives at THREE sites.
    /// One assertion per site, each naming its case — a `replace_all` that misses one sibling
    /// fails HERE with the site's name (the exact 4-times-bitten failure shape in CLAUDE.md).
    func testPlanStateResetIsPinnedPerTerminalCase() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sink = try String(contentsOf: repo.appendingPathComponent("Sources/Kist/TerminalEventSink.swift"),
                              encoding: .utf8)
        let reset = "state.planStepCount = 0; state.currentWave = 0; state.liveDetail = nil"
        // The destructuring patterns are unique to the RENDERING switch (bare `.completed` also
        // appears in the watchdog-lifecycle switch, which owns no state resets).
        for terminalCase in ["case .completed(let", "case .failed(let", "case .cancelled:"] {
            guard let caseRange = sink.range(of: terminalCase) else {
                XCTFail("\(terminalCase) not found in TerminalEventSink"); continue
            }
            let after = String(sink[caseRange.upperBound...]).prefix(400)
            XCTAssertTrue(after.contains(reset),
                          "\(terminalCase) no longer clears the R3 plan state — stale `w·step` positions will haunt the next turn")
        }
    }

    func testStepWaveEventIsEmittedPerWave() async throws {
        final class RecordingSink: RuntimeEventSink, @unchecked Sendable {
            let lock = NSLock(); var waves: [Int] = []
            func emit(_ event: RuntimeEvent) {
                if case .stepWave(let w, _) = event { lock.lock(); waves.append(w); lock.unlock() }
            }
        }
        let plan = ExecutablePlan(goal: "g", steps: [
            PlanStep(id: "E1", intent: "one", tool: "flaky", argumentsJSON: #"{"ok":true}"#),
            PlanStep(id: "E2", intent: "two", tool: "flaky", argumentsJSON: #"{"ok":true}"#, dependsOn: ["E1"]),
        ])
        let sink = RecordingSink()
        _ = await PlanExecutor(tools: ToolRegistry([FlakyTool()]), context: try tmpContext(), sink: sink).execute(plan)
        XCTAssertEqual(sink.waves, [1, 2], "each dependency wave announces itself")
    }

    func testStallThresholdIsFiveMinutes() {
        XCTAssertEqual(TerminalEventSink.stallThresholdSeconds, 300)
    }
}
