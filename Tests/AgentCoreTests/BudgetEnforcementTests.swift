import XCTest
import Foundation
@testable import AgentCore

/// The cost-cap enforcement the council flagged as the #1 production objection: the standard
/// HeadlessAgentLoop must HALT at the token ceiling (not just the plan-execute loop), accounting
/// must accumulate at the single recordLLMSpan chokepoint, and a SHARED ledger must reach spawned
/// agents so one rogue teammate can't blow the whole budget.
final class BudgetEnforcementTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "budget-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
    }

    private func loop(_ responses: [String], budget: BudgetLedger?, maxIterations: Int = 6) -> HeadlessAgentLoop {
        let registry = ProviderRegistry(providers: [ScriptedProvider(responses)], keyStore: NullKeyStore())
        return HeadlessAgentLoop(providers: registry, providerId: "scripted", model: nil,
                                 tools: .headless(), context: ToolContext(projectRoot: root),
                                 sink: NullEventSink(), maxIterations: maxIterations, budget: budget)
    }

    // SITE 1 — a run whose ledger is already over the cap halts on the FIRST iteration, before any
    // model call, with an honest budget-exceeded failure.
    func testRunHaltsWhenBudgetAlreadyExceeded() async {
        let budget = BudgetLedger(maxTokens: 100)
        await budget.add(500)                                  // already over the ceiling
        // The scripted response would SUCCEED if reached — proving the halt fires before the model call.
        let l = loop([#"{"thinking":"x","done":true,"summary":"should-not-reach"}"#], budget: budget)
        let outcome = await l.run(goal: "go")
        XCTAssertFalse(outcome.success, "an over-budget run must fail, not complete")
        XCTAssertTrue(outcome.summary.contains("budget exceeded"), "summary names the budget halt: \(outcome.summary)")
        XCTAssertNotEqual(outcome.summary, "should-not-reach", "must halt BEFORE consuming the model response")
    }

    // SITE 2 — accounting accumulates at the recordLLMSpan chokepoint (estimate fallback when the
    // scripted provider reports no usage), so the ledger actually tracks spend.
    func testBudgetAccumulatesAcrossModelCalls() async {
        let budget = BudgetLedger(maxTokens: 10_000_000)        // generous: won't halt
        let l = loop([#"{"thinking":"done","done":true,"summary":"ok"}"#], budget: budget)
        let outcome = await l.run(goal: "summarize something with enough text to estimate tokens")
        XCTAssertTrue(outcome.success)
        let spent = await budget.spentTokens()
        XCTAssertGreaterThan(spent, 0, "recordLLMSpan must feed the ledger (measured or estimated)")
    }

    // SITE 3 — uncapped (nil ledger) behaves exactly as before: no halt.
    func testUncappedRunCompletesNormally() async {
        let l = loop([#"{"thinking":"done","done":true,"summary":"finished"}"#], budget: nil)
        let outcome = await l.run(goal: "go")
        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.summary, "finished")
    }

    // SITE 4 — the SHARED ledger reaches a spawned sub-agent: a pre-exceeded shared budget makes the
    // sub-agent halt immediately, so spawn_agent returns a budget failure (global cap, not per-agent).
    func testSharedBudgetPropagatesToSpawnedAgent() async {
        let shared = BudgetLedger(maxTokens: 50)
        await shared.add(999)                                  // whole tree is already over budget
        let registry = ProviderRegistry(providers: [ScriptedProvider([
            #"{"thinking":"x","done":true,"summary":"sub-should-not-reach"}"#
        ])], keyStore: NullKeyStore())
        let spawn = SpawnAgentTool(providers: registry, providerId: "scripted", model: nil,
                                   baseTools: .headless(), sink: NullEventSink(),
                                   maxIterations: 4, delegationDepth: 0, budget: shared)
        let result = try? await spawn.execute(arguments: ["task": "do something"],
                                              context: ToolContext(projectRoot: root))
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.success, "sub-agent under an exhausted shared budget must fail")
        XCTAssertTrue((result!.output + (result!.error ?? "")).contains("budget exceeded"),
                      "the shared cap halted the sub-agent: \(result!.output) / \(result!.error ?? "")")
    }

    // SITE 5 — the FLEET path honors the budget. The council's unanimous CRITICAL: the fleet doesn't
    // go through makeLoop, so its workers were uncapped. PlanExecuteLoop's budget halt is already
    // proven (PlanExecuteLoopTests); the fix is pure WIRING across two sites, so — per the multi-site
    // discipline — pin each site by name so a regression says exactly which link broke.
    //   A) PlanExecuteFleetSpawner.make must pass the budget INTO the PlanExecuteLoop it builds.
    //   B) runFleet (KistRunner) must pass a shared budget INTO PlanExecuteFleetSpawner.make.
    func testFleetBudgetWiringPinned() throws {
        let spawnerSrc = try source("Sources/AgentCore/PlanExecuteFleetSpawner.swift")
        XCTAssertTrue(spawnerSrc.contains("budget: BudgetLedger? = nil"),
                      "A: make() must accept a budget")
        XCTAssertTrue(spawnerSrc.contains("verifyGoal: verifyGoal,\n                budget: budget)")
            || spawnerSrc.replacingOccurrences(of: " ", with: "").contains("budget:budget)"),
                      "A: make() must pass budget into PlanExecuteLoop")

        let runnerSrc = try source("Sources/Kist/KistRunner.swift")
        let compactRunner = runnerSrc.replacingOccurrences(of: " ", with: "")
                                      .replacingOccurrences(of: "\n", with: "")
        XCTAssertTrue((compactRunner.contains("PlanExecuteFleetSpawner.make(")
                       || compactRunner.contains("PlanExecuteFleetSpawner.makeAssigned("))
                      && compactRunner
                          .contains("budget:fleetBudget"),
                      "B: runFleet must pass a shared fleetBudget into the spawner")
        XCTAssertTrue(runnerSrc.contains("let fleetBudget = opts.makeBudget()"),
                      "B: runFleet must derive the shared fleet budget (tokens + $) from the helper")
    }

    // SITE 6 (Codex) — the FLEET PLANNER counts against the same fleet budget: an exhausted budget
    // makes it return no subtasks WITHOUT spending a planner call (total fleet spend ≈ --budget, not
    // planning + N×budget).
    func testFleetPlannerHaltsOnExhaustedBudget() async {
        let exhausted = BudgetLedger(maxTokens: 0)
        let registry = ProviderRegistry(providers: [ScriptedProvider([
            #"[{"title":"t","intent":"i","scopeGlobs":["A/*"],"acceptanceCriterion":"c"}]"#
        ])], keyStore: NullKeyStore())
        let planner = FleetPlanner(providers: registry, binding: ProviderBinding(providerId: "scripted", model: nil))
        let subtasks = await planner.plan(goal: "build", scopeContext: "A/", maxAgents: 3, budget: exhausted)
        XCTAssertTrue(subtasks.isEmpty, "an exhausted budget must skip planning entirely")
    }

    // SITE 7 (Codex) — pre-commit evolution is deliberately non-executable. Candidate-authored code
    // reaches only the later exact-commit attested verifier; generation receives concrete in-process
    // file tools, denied shell, strict confinement, and no external/media read bridge.
    func testEvolutionCandidatesUseStrictNonExecutableGenerationEnvelope() throws {
        let src = try source("Sources/Kist/KistEvolutionCommand.swift")
        let compact = src.replacingOccurrences(of: " ", with: "")
        XCTAssertTrue(src.contains("shell: .denied"),
                      "pre-commit candidate shell must remain denied")
        XCTAssertTrue(src.contains("sandbox: .strictAutonomous(forbiddenReadPaths: [root])"),
                      "candidate context must hide the host repository behind strict confinement")
        XCTAssertTrue(compact.contains("externalReadRoots:[],allowMediaDropInbox:false"),
                      "candidate context must expose no external or media read bridge")
        XCTAssertFalse(compact.contains("ShellPolicy(enabled:true"),
                       "pre-commit candidates must not regain raw shell")
        XCTAssertFalse(src.contains("approval: { _ in true }"),
                       "pre-commit candidates must not auto-approve raw shell")
    }

    func testEvolutionSharedLedgerPinned() throws {
        // The `--evolve` command lives in its own file now (extracted from KistRunner). The shared ledger
        // must be created BEFORE the OUTERMOST (generation) loop, so ONE ledger caps the whole open-ended
        // run — generations × variants — not each candidate (a per-candidate ledger would allow N×budget).
        let src = try source("Sources/Kist/KistEvolutionCommand.swift")
        // `let evolveBudget = budgetOverride ?? opts.budgetTokens.map { … }` — the injected-ledger form
        // (a cross-session session passes its own capped ledger); either way it's the ONE shared ledger.
        guard let ledgerPos = src.range(of: "let evolveBudget = budgetOverride ?? opts.budgetTokens.map"),
              let genLoopPos = src.range(of: "for generation in 1...generations"),
              let candidateLoopPos = src.range(of: "for index in 1...variantCount"),
              let worktreePos = src.range(of: "EvolutionLineageWorkspace.createChild") else {
            return XCTFail("evolution budget/loop markers not found")
        }
        XCTAssertTrue(ledgerPos.lowerBound < genLoopPos.lowerBound,
                      "evolveBudget must be created BEFORE the generation loop (one ledger for the whole run)")
        guard let candidateBudgetCheck = src.range(of: "if let budget = evolveBudget, await budget.isExceeded()",
                                                   range: candidateLoopPos.upperBound..<worktreePos.lowerBound) else {
            return XCTFail("the candidate loop must check the shared budget before creating another worktree")
        }
        XCTAssertTrue(candidateLoopPos.lowerBound < candidateBudgetCheck.lowerBound)
        XCTAssertTrue(src.contains("budget: evolveBudget"), "each candidate's PlanExecuteLoop must use the shared ledger")
    }

    /// Read a repo source file relative to this test's location (worktree-agnostic).
    private func source(_ rel: String) throws -> String {
        // #filePath: <repo>/Tests/AgentCoreTests/BudgetEnforcementTests.swift → up 3 to <repo>.
        let here = URL(fileURLWithPath: #filePath)
        let repo = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // KistRunner's logic is split across KistRunner.swift + KistRunner+*.swift extension files;
        // a request for the core file returns the whole family so location-pins survive extraction.
        if rel == "Sources/Kist/KistRunner.swift" {
            let dir = repo.appendingPathComponent("Sources/Kist")
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0 == "KistRunner.swift" || $0.hasPrefix("KistRunner+") }
                .sorted()
            return try files
                .map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
                .joined(separator: "\n")
        }
        return try String(contentsOf: repo.appendingPathComponent(rel), encoding: .utf8)
    }
}

// MARK: - Local test doubles (file-private, mirrors HeadlessAgentLoopTests)

private struct NullKeyStore: KeyStore {
    func key(forAccount account: String) -> String? { nil }
    func setKey(_ key: String, forAccount account: String) throws {}
    func deleteKey(forAccount account: String) throws {}
}

private final class ScriptedProvider: ChatProvider {
    let id = "scripted", name = "Scripted", iconName = "cpu"
    let requiresAPIKey = false, keyAccount = "scripted", defaultModel = "scripted-1"
    let availableModels = [AIModel(id: "scripted-1")]
    private let responses: ScriptedResponses
    init(_ responses: [String]) { self.responses = ScriptedResponses(responses) }
    func stream(messages: [ChatMessage], model: String, settings: ModelSettings, apiKey: String?) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        let r = await responses.next()
        return AsyncThrowingStream { cont in cont.yield(.delta(r)); cont.finish() }
    }
}

private actor ScriptedResponses {
    private let responses: [String]
    private var idx = 0
    init(_ responses: [String]) { self.responses = responses }
    func next() -> String {
        defer { idx += 1 }
        return idx < responses.count ? responses[idx] : #"{"done":true,"summary":"(out of script)"}"#
    }
}
