import Foundation

/// Bounded proposal generation, separate from execution and completion authority.
struct PlanProposalEngine: Sendable {
    let tools: ToolRegistry
    let maxPlanRepairs: Int
    let hostOwnedFinalReview: Bool
    let budget: BudgetLedger?
    let complete: @Sendable ([ChatMessage], ModelSettings) async throws -> String

    // MARK: - Planning (propose + repair)

    enum Result {
        /// `lintWarnings` remains in the shape for durable legacy snapshots, but newly accepted plans
        /// always carry an empty list. A plan that violates the singular-step contract never executes.
        case ok(ExecutablePlan, lintWarnings: [String])
        case decompositionExhausted(ExecutablePlan, findings: [String])
        case invalid, providerError(String), budgetExceeded(Int)
    }

    func obtainPlan(_ messages: inout [ChatMessage], context: ToolContext,
                    policy: PlanSearchPolicy, excluding plans: [ExecutablePlan],
                    sink: RuntimeEventSink) async -> Result {
        guard policy.candidateLimit > 1 else { return await obtainSinglePlan(&messages, context: context) }
        let settings = ModelSettings(temperature: 0.2, maxTokens: 4096,
            systemPrompt: PlanExecuteLoop.plannerSystemPrompt(tools: tools,
                projectRoot: context.projectRoot, shellEnabled: context.shell.enabled,
                hostOwnedFinalReview: hostOwnedFinalReview) + policy.prompt,
            reasoningEffort: .deep)
        let excluded = Set(plans.map(PlanSearchPolicy.fingerprint))
        // Keep only the latest structural feedback for repair, not every rejected tree.
        let original = messages
        var request = original
        for _ in 0...max(0, maxPlanRepairs) {
            if Task.isCancelled { return .providerError("interrupted by user") }
            if let budget, await budget.isExceeded() {
                return .budgetExceeded(await budget.spentTokens())
            }
            let text: String
            do { text = try await complete(request, settings) }
            catch is PlanExecuteLoop.PlanBudgetDenied { return .budgetExceeded(await budget?.spentTokens() ?? 0) }
            catch { return .providerError("\(error)") }
            if Task.isCancelled { return .providerError("interrupted by user") }
            let selection = policy.select(text, tools: tools,
                hostOwnedFinalReview: hostOwnedFinalReview, excluding: excluded)
            if let plan = selection.plan, let json = selection.json, let ordinal = selection.ordinal {
                messages = original + [ChatMessage(role: .assistant, content: json)]
                sink.emit(.tokenDelta("plan search · selected approach \(ordinal)/\(selection.considered)"
                    + " · structural checks passed; execution and verification still required\n"))
                return .ok(plan, lintWarnings: [])
            }
            let feedback = String(selection.findings.joined(separator: "\n").prefix(2400))
            request = original + [ChatMessage(role: .user, content:
                "Host plan search rejected all candidates:\n\(feedback)\nReturn corrected candidates using the same goal and constraints.")]
        }
        return .invalid
    }

    /// Stream a plan from the current message context and validate it, re-prompting to repair an
    /// invalid/unparseable plan up to `maxPlanRepairs` times. Appends the conversation in place.
    func obtainSinglePlan(_ messages: inout [ChatMessage], context: ToolContext) async -> Result {
        let settings = ModelSettings(temperature: 0.2, maxTokens: 4096,
                                     systemPrompt: PlanExecuteLoop.plannerSystemPrompt(tools: tools,
                                                                            projectRoot: context.projectRoot,
                                                                            shellEnabled: context.shell.enabled,
                                                                            hostOwnedFinalReview:
                                                                                hostOwnedFinalReview))
        var lastLintRejected: (plan: ExecutablePlan, findings: [String])?
        for _ in 0...maxPlanRepairs {
            if let budget, await budget.isExceeded() {
                return .budgetExceeded(await budget.spentTokens())
            }
            let text: String
            do { text = try await complete(messages, settings) }
            catch is PlanExecuteLoop.PlanBudgetDenied { return .budgetExceeded(await budget?.spentTokens() ?? 0) }
            catch { return .providerError("\(error)") }
            messages.append(ChatMessage(role: .assistant, content: text))

            guard let parsed = PlanParser.parse(text) else {
                messages.append(ChatMessage(role: .user, content:
                    "That was not a parseable plan. Respond with ONLY the JSON plan object described above."))
                continue
            }
            let errors = parsed.validate(hostOwnedFinalReview: hostOwnedFinalReview)
            if errors.isEmpty {
                // R3: a lumpy plan is re-split before it executes — violations feed a bounded repair
                // loop. Exhaustion is fail-closed below; no rejected lump can become executable proof.
                let lint = PlanLint.findings(for: parsed)
                if lint.isEmpty { return .ok(parsed, lintWarnings: []) }
                lastLintRejected = (parsed, lint)
                messages.append(ChatMessage(role: .user, content:
                    "Your plan violates the SINGULAR-STEP contract:\n- " + lint.joined(separator: "\n- ")
                    + "\nOutput a corrected JSON plan (same format) where each step does exactly ONE thing."))
                continue
            }
            messages.append(ChatMessage(role: .user, content:
                "Your plan has these problems:\n\(PlanExecuteLoop.describe(errors))\nOutput a corrected JSON plan (same format)."))
        }
        // Repairs exhausted. Preserve the rejected plan/findings as diagnostic context, but do not
        // execute it. A later bounded re-plan can shrink the work without laundering this rejection.
        if let last = lastLintRejected {
            return .decompositionExhausted(last.plan, findings: last.findings)
        }
        return .invalid
    }

}
