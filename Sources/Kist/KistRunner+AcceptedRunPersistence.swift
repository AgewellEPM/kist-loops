import Foundation
import AgentCore

extension KistRunner {
    /// Convert the already-accepted PlanExecute Builder result into the advisory row which must match
    /// its sealed host receipt exactly. This helper does not mint: `AcceptedRunPersistence` remains the
    /// sole typed independent-authority gate and commits ledger-first, receipt-last.
    static func persistAcceptedPlanExecuteRun(
        authority: BuilderFinalAcceptanceAuthority,
        missionID: PlanExecuteMissionID,
        goal: String,
        projectRoot: String,
        launch: BuilderCompatibilityLaunch,
        planOutcome: PlanOutcome?,
        iterationBudget: Int
    ) throws -> AcceptedRunPersistenceResult {
        let final = authority.finalReceipt
        let usage = builderAggregateRunUsage(final)
        let projectIdentity = try AcceptedRunReceipt.computeProjectIdentity(
            projectRoot: projectRoot)
        let attempts = planOutcome?.execution?.attemptResults ?? []
        let failedAttempts = attempts.filter { !$0.success }.count
        let failureRate = attempts.isEmpty
            ? 0 : Double(failedAttempts) / Double(attempts.count)
        let uniqueWorkers = Dictionary(grouping: final.workers) {
            "\($0.provider.lowercased()):\($0.model.lowercased())"
        }
        let soleWorker = uniqueWorkers.count == 1 ? final.workers.first : nil
        let objectiveFingerprint = builderObjectiveFingerprint(
            contractID: final.contractID, goal: goal)
        let run = RunRecord(
            id: missionID.rawValue,
            at: final.completedAt.timeIntervalSince1970,
            goal: goal,
            signature: EffortController.signature(for: goal),
            orgVersion: OrgFingerprint.make([
                "contractID": final.contractID,
                "route": launch.routeHint.resolve().rawValue,
                "complexity": String(launch.effort.complexity),
                "thinking": launch.effort.thinking.rawValue,
                "planning": launch.effort.planning.rawValue,
                "team": launch.effort.team.rawValue,
                "modelTier": launch.effort.modelTier.rawValue,
            ]),
            route: final.route.rawValue,
            complexity: launch.effort.complexity,
            thinking: launch.effort.thinking.rawValue,
            planning: launch.effort.planning.rawValue,
            team: launch.effort.team.rawValue,
            modelTier: launch.effort.modelTier.rawValue,
            decisionReason: launch.routerDecision.reason,
            specialists: final.review.workerIdentities ?? [],
            provider: soleWorker?.provider,
            model: soleWorker?.model,
            success: final.accepted,
            verified: final.review.reviewGrade == .independent
                && final.review.independent == true,
            failureRate: failureRate,
            iterationsUsed: final.workers.count,
            iterationBudget: max(1, iterationBudget),
            replansUsed: planOutcome?.replansUsed ?? 0,
            wasStuck: false,
            toolCalls: attempts.count,
            durationMs: usage.wallTimeSeconds * 1_000,
            totalTokens: usage.inputTokens + usage.outputTokens,
            projectIdentity: projectIdentity,
            contractID: final.contractID,
            objectiveFingerprint: objectiveFingerprint,
            verificationSubject: final.verification.verificationSubject,
            verificationDigest: final.verification.subjectDigest)
        return try AcceptedRunPersistence(projectRoot: projectRoot)
            .persistPlanExecuteAccepted(run, authorizing: authority)
    }
}
