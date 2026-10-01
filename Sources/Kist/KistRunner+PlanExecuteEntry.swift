import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// plan-execute entry points — extracted from KistRunner.swift to keep the core orchestration file under the
// size limit. Part of `enum KistRunner`.
extension KistRunner {
    struct PlanExecuteCorrelationBundle {
        let missionID: PlanExecuteMissionID
        let recorder: TraceRecorder
        let runReplay: RunReplayStore
        let context: ToolContext
    }

    static func makePlanExecuteCorrelation(
        launchMode: PlanExecuteLaunchMode,
        freshMissionInstanceID: PlanExecuteMissionID?,
        projectRoot: String,
        providerID: String,
        model: String?,
        context: ToolContext
    ) -> PlanExecuteCorrelationBundle {
        let missionID: PlanExecuteMissionID
        switch launchMode {
        case .fresh: missionID = freshMissionInstanceID ?? .fresh()
        case .resume(let resumed): missionID = resumed
        }
        let recorder = TraceRecorder(traceId: missionID.rawValue)
        return PlanExecuteCorrelationBundle(
            missionID: missionID,
            recorder: recorder,
            runReplay: RunReplayStore(projectRoot: projectRoot, provider: providerID,
                                      model: model, runID: missionID.rawValue,
                                      executionRoot: context.projectRoot),
            context: context.withPlanExecuteMission(missionID, traceRecorder: recorder))
    }

    /// Run a plan→execute: the planner emits a typed DAG, you approve it (unless --yolo), then the team
    /// builds it. Shared by the `--plan-execute` one-shot and the REPL's `/plan-execute` escalation.
    static func runPlanExecute(_ opts: KistOptions, goal: String, registry: ProviderRegistry,
                                       root: String, tools: ToolRegistry, context: ToolContext,
                                       providerId: String, model: String?,
                                       rolesOverride: RoleBindings? = nil,
                                       budgetOverride: BudgetLedger? = nil,
                                       launchMode: PlanExecuteLaunchMode = .fresh,
                                       freshMissionInstanceID: PlanExecuteMissionID? = nil,
                                       // The string the SAFETY gates keyword-classify for risk. Defaults to the
                                       // executed goal, but council-execute passes the USER'S ORIGINAL goal here
                                       // (dogfood 2026-08-06: the builder brief embeds the whole council markdown
                                       // transcript, so an incidental "auth"/"safety"/"exploit" word — or an
                                       // org-store domain mislabel — flipped a COBOL report tweak to CRITICAL and
                                       // hard-blocked a user-requested build. Risk must reflect what the USER asked).
                                       riskObjective: String? = nil,
                                       checkpointGoal: String? = nil,
                                       hostOwnedFinalReview: Bool = false,
                                       functionalObjective: String? = nil,
                                       canonicalFunctionalObjective: String? = nil,
                                       hostContractID: String? = nil,
                                       memoryRoot: String? = nil,
                                       auditRoot: String? = nil,
                                       persistMemoryEpisode: Bool = true,
                                       outcomeCapture: (@Sendable (PlanOutcome) -> Void)? = nil) async -> Int32 {
        guard let roles = rolesOverride ?? resolveRoles(opts, registry, providerId: providerId, model: model) else { return 2 }
        // A Builder adapter executes inside a sealed transaction root. Read planning memory from the
        // caller-owned host root, but do not let the nested loop append an episode before the outer
        // Builder receipt is accepted; that hidden `.mythos` write would be undeclared output.
        let memoryReadRoot = memoryRoot ?? root
        let auditProjectRoot = auditRoot ?? root
        let memory = opts.noMemory || !persistMemoryEpisode
            ? nil
            : ProjectMemory(root: memoryReadRoot)
        let memNote = (memory?.hasContent ?? false) ? " · memory \(memory!.recentEpisodes(limit: 100).count) runs" : ""
        note("kist · plan→execute · \(roles.summary) · \(root)\(roles.isHeterogeneous ? " · team" : "")\(opts.budgetTokens.map { " · budget \($0)" } ?? "")\(memNote)")
        // CAPTAIN SAFETY GATES (preserved across the origin/main merge): both must accept before any side
        // effect. Pinned by KistRunnerSafetyTests. Fail-closed. c7 splice: --no-memory is threaded to the
        // simulation gate so it suppresses the .kist disk write while still computing + enforcing the verdict.
        let gateObjective = canonicalPlanExecuteRiskObjective(goal: goal,
                                                              riskObjective: riskObjective)
        // Route and requested effect are orthogonal. Freeze the contract from the canonical raw request
        // BEFORE cortex/council/builder context is wrapped around the planner goal below.
        let completionContract = PlanExecuteCompletionContract.derive(canonicalRequest: gateObjective)
        let domainPreflight = CaptainDomainLearningEnforcer.preflight(mode: .planExecute,
                                                                      objective: gateObjective,
                                                                      projectRoot: root,
                                                                      evidenceMode: opts.noMemory ? .redacted : .full)
        for line in domainPreflight.terminalLines { note(line) }
        guard domainPreflight.canExecute else {
            err("captain refused to execute: domain-learning gate did not accept this plan.")
            return 1
        }
        // Plan-execute is reachable only from EXPLICIT user commands (/build, /pe, --plan-execute,
        // council-execute) — the human already decided, so a sub-threshold estimate is advisory,
        // not a veto. Critical-risk signals and failed evidence writes still hard-block.
        let planPreflight = CaptainSimulationEnforcer.preflight(mode: .planExecute,
                                                                objective: gateObjective,
                                                                projectRoot: root,
                                                                evidenceMode: opts.noMemory ? .redacted : .full,
                                                                noMemory: opts.noMemory,
                                                                initiator: .userRequest)
        for line in planPreflight.terminalLines { note(line) }
        guard planPreflight.canExecute else {
            err("captain refused to execute: simulation gate did not accept this plan.")
            return 1
        }
        let correlation = makePlanExecuteCorrelation(
            launchMode: launchMode,
            freshMissionInstanceID: freshMissionInstanceID,
            projectRoot: auditProjectRoot,
            providerID: providerId,
            model: model,
            context: context)
        let recorder = correlation.recorder
        // Reuse the caller's ledger when handed one (e.g. --council-execute) so the whole run shares a
        // single cap; otherwise create this run's own (Codex gate C3#1).
        let budget = budgetOverride ?? opts.makeBudget()
        let runReplay = correlation.runReplay
        let proofStore = TurnProofStore(replayStore: runReplay)
        proofStore.startTurn(goal: goal)
        // R2a: plan-execute is the LONGEST-running surface — typing must render there too, not
        // just queue invisibly (review catch: "my typing disappeared" for a 20-minute plan run).
        let planSink = TerminalEventSink(style: .calm, proofStore: proofStore,
                                         typedInput: { TurnInputQueue.shared.preview() })
        TurnInputQueue.shared.addOnChange { planSink.refreshLiveStatus() }
        // Fold cortex (who Luke is + this project) into the planner's goal so plan→execute (and
        // --council-execute, which routes here) plans WITH your preferences, not just ProjectMemory.
        let sessionContext = Self.sessionMemory(root: memoryReadRoot, opts: opts)
        func withSessionContext(_ objective: String) -> String {
            sessionContext.map {
                "MEMORY — what kist knows about you & this project:\n\($0)\n\n---\nGOAL:\n\(objective)"
            } ?? objective
        }
        let planGoal = withSessionContext(goal)
        let functionalPlanGoal = functionalObjective.map(withSessionContext)
        let canonicalFunctionalPlanGoal = canonicalFunctionalObjective
            ?? PlanExecuteCompletionContract.functionalObjective(from: checkpointGoal ?? goal)
        let pxl = PlanExecuteLoop(providers: registry, roles: roles, tools: tools,
                                  context: correlation.context,
                                  sink: planSink,
                                  interactor: opts.yolo ? AutoApproveInteractor() : terminalInteractor(for: opts),
                                  requireApproval: !opts.yolo,
                                  planSearch: PlanSearchPolicy(candidateLimit: opts.planCandidates), recorder: recorder, budget: budget, memory: memory,
                                  launchMode: launchMode,
                                  freshMissionInstanceID: correlation.missionID,
                                  completionContract: completionContract,
                                  hostOwnedFinalReview: hostOwnedFinalReview,
                                  functionalObjective: functionalPlanGoal,
                                  canonicalFunctionalObjective: canonicalFunctionalPlanGoal,
                                  hostContractID: hostContractID)
        let missionToken = pxl.missionInstanceID.rawValue
        note("plan-execute mission · \(missionToken)")
        if let quotedGoal = planExecuteResumeGoalArgument(checkpointGoal ?? goal) {
            note("resume · kist --plan-execute-resume \(missionToken) \(quotedGoal)")
        } else {
            note("resume · kist --plan-execute-resume \(missionToken) <same-goal>")
        }
        let pOut = await pxl.run(goal: planGoal, checkpointGoal: checkpointGoal ?? goal)
        outcomeCapture?(pOut)
        let missionSpans = await recorder.all()
        for line in await recorder.summary().terminalLines() { note(line) }
        // Persist both LLM and tool spans. Their traceId is the mission/run root, so the dashboard can
        // join usage activity to the matching `.kist/runs/<mission>/` replay without a second id.
        printUsageDelta(from: [], to: missionSpans, label: "plan-execute usage", projectRoot: auditProjectRoot)
        note(pOut.success ? "✓ \(pOut.message)" : "✗ \(pOut.message)")
        note("replay · kist --replay \(runReplay.manifest.runID)")
        // Learn from the VERIFIED outcome: plan-execute success is critic-verified, so it's a PROVEN
        // lesson (with a real source); a failure is an obstacle. Memory stays advisory.
        if !opts.noMemory,
           let projectIdentity = try? AcceptedRunReceipt.computeProjectIdentity(
               projectRoot: root) {
            let store = LessonStore(); let at = Date().timeIntervalSince1970
            let lessonSource = "plan-execute:\(missionToken):\(projectIdentity)"
            if pOut.success {
                store.record(Lesson(kind: .proven, text: "accomplished via plan→execute: \(goal.prefix(120))",
                                    source: lessonSource, at: at))
            } else if !pOut.interrupted {
                // R1: an ESC'd run must NOT book an obstacle lesson — a user cancel is zero
                // evidence the goal fails, and obstacle lessons outrank proven ones in retrieval.
                store.record(Lesson(kind: .obstacle, text: "plan→execute failed: \(goal.prefix(120))",
                                    source: lessonSource, at: at))
            }
        }
        return pOut.success ? 0 : 1
    }

    /// Render a terminal-safe, exact POSIX shell argument when the goal has no control characters.
    /// Control-bearing goals still expose the exact mission token and resume syntax without terminal injection.
    static func planExecuteResumeGoalArgument(_ goal: String) -> String? {
        guard goal.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            return nil
        }
        return "'" + goal.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// PlanExecute may receive a compiled TaskBrief as its execution goal. Generated constraints
    /// are useful instructions for the model but are not user-requested effects, so the safety gate
    /// must recover and classify the brief's typed original request.
    static func canonicalPlanExecuteRiskObjective(goal: String,
                                                  riskObjective: String?) -> String {
        let gateObjective = riskObjective ?? goal
        return PromptCompiler.originalRequest(fromCompiledPrompt: gateObjective) ?? gateObjective
    }

}
