import Foundation
import AgentCore

extension KistRunner {
    static func interactiveBuildOptions(_ opts: KistOptions, goal: String,
                                        missionID: PlanExecuteMissionID?, forcePlanned: Bool) -> KistOptions {
        var next = opts
        next.goal = goal
        next.planExecute = opts.planExecute || forcePlanned || missionID != nil
        next.planExecuteResumeID = missionID
        return next
    }

    static func runInteractiveBuild(_ opts: KistOptions, missionID: PlanExecuteMissionID?,
        goal g: String, roles: RoleBindings, forcePlanned: Bool, registry: ProviderRegistry,
        root: String, tools: ToolRegistry, context: ToolContext, checkpoints: LoopCheckpointStore?,
        toolMode: ToolMode, providerId: String, model: String?, riskObjective: String?,
        priorResultContext: PriorResultContext?) async -> HeavyRouteResult {
        let o = interactiveBuildOptions(opts, goal: g, missionID: missionID, forcePlanned: forcePlanned)
        // R1: ESC works on the plan-execute plane too — previously this plane was a
        // dead zone (no watcher, no cancellation checks), exactly where big requests
        // auto-escalate. The watcher cancels the runner task; PlanExecuteLoop and
        // PlanExecutor stop cooperatively at phase/wave boundaries. Sequential with
        // the chat turn's watcher (single-watcher invariant preserved).
        TurnInputQueue.shared.begin()
        defer { TurnInputQueue.shared.end() }
        let interrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
        let exitCode = await InterruptibleTurn.run(onInterrupt: { reason in
            interrupted.value = reason
            if reason == .cancel { TurnInputQueue.shared.clearAll() }
            else { TurnInputQueue.shared.commitPending() }
            print("\n\u{001B}[33m" + (reason == .cancel ? "⎋⎋ cancelled" : "⎋ interrupted")
                  + " — plan run stopped\u{001B}[0m")
        }) {
            await runBuilderCompatibility(o, goal: g, registry: registry, root: root,
                                          tools: tools, context: context, checkpoints: checkpoints,
                                          toolMode: toolMode, providerId: providerId, model: model,
                                          rolesOverride: roles,
                                          riskObjective: riskObjective,
                                          advisoryContext: priorResultContext)
        }
        let verification: HeavyRouteResult.Verification
        if interrupted.value != nil {
            verification = .unavailable("plan verification did not finish after interruption")
        } else if exitCode == 0 {
            verification = .passed("Builder's deterministic verification and required review completed")
        } else if exitCode == 1 {
            verification = .failed("Builder did not pass its required verification or review")
        } else {
            verification = .unavailable("plan execution was rejected before its verifier ran")
        }
        return HeavyRouteResult(exitCode: exitCode, interruption: interrupted.value,
                                review: .handledInternally("Builder owns its selected execution and review route"),
                                verification: verification)
    }
}
