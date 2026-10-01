import Foundation

// Bounded advisory verdict; deterministic execution and outer acceptance remain separate.
extension PlanExecuteLoop {
    static var goalReviewSettings: ModelSettings {
        ModelSettings(temperature: 0, maxTokens: 512, disableThinking: true, geminiBuiltins: false)
    }

    // MARK: - Verify gate

    func verifyGoalMet(goal: String, execution: PlanExecution,
                               verificationBinding: ReviewVerificationBinding?,
                               functionalEvidenceSection: FunctionalEvidenceReviewSection? = nil)
        async -> (done: Bool, reason: String) {
        let stepSummary = execution.stepResults
            .map { "- \($0.stepId) (\($0.tool)): \(String($0.output.prefix(200)).replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let messages = [ChatMessage(role: .user, content: Self.verifyPrompt(
            goal: goal, stepSummary: stepSummary, verificationBinding: verificationBinding,
            functionalEvidenceSection: functionalEvidenceSection))]
        let settings = Self.goalReviewSettings
        // The CRITIC verifies — can be a DIFFERENT vendor than the planner (clean-context reviewer,
        // the research's highest-confidence cross-vendor win). Metered + traced like every model call.
        guard let text = try? await meteredComplete(role: .critic, messages: messages, settings: settings),
              let verdict = Self.parseVerdict(text) else {
            return (done: false, reason: "verification unavailable or unparseable")
        }
        return verdict
    }

}
