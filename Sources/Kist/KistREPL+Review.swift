import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Second-opinion / ultra / copilot review (run() decomposition — behavior-identical methods relocated from KistREPL.run())
extension KistREPL {
        // Pick the reviewer: a model DIFFERENT from the one that just answered — never self-review (that's
        // the "just repeat yourself" anti-pattern Luke called out). Team mode's explicit `co` wins if it's
        // distinct; otherwise auto-pick a configured provider ≠ the answering one, cheap/reliable first.
        // nil ⇒ no distinct reviewer available (skip the review rather than let a model grade its own work).
        func autoReviewer(answeredBy: ProviderBinding) -> ProviderBinding? {
            if let co = copilot.co, Copilot.isDistinctReviewer(co, from: answeredBy) { return co }
            let configured = Set(providerAliases.values)
            let prefer = ["claude-cli", "gemini", "deepseek", "mimo", "codex-cli", "moonshot", "zhipu", "grok"]
            if let pid = prefer.first(where: { $0 != answeredBy.providerId && configured.contains($0) }) {
                return ProviderBinding(providerId: pid)
            }
            if let pid = configured.first(where: { $0 != answeredBy.providerId }) {
                return ProviderBinding(providerId: pid)
            }
            return nil
        }

        // The grounding handed to the second-opinion reviewer so it isn't context-blind. Same self-identity
        // brief the primary turn rides on (so the reviewer knows what "Kist" IS) + durable project memory
        // (AGENTS.md/CLAUDE.md/facts). Without this the reviewer answers "I've never heard of this system,
        // can't verify the claims" instead of actually reviewing — the brain-dead second opinion.
        func reviewerGrounding() -> String {
            var parts = [kistSelfContext()]
            let facts = ProjectMemory(root: projectRoot).facts()
            if !facts.isEmpty { parts.append("[PROJECT MEMORY]\n" + facts) }
            return parts.joined(separator: "\n\n")
        }

        /// `/ballbusting` — a no-mercy review of the current work: the working-tree diff by default, or a
        /// plan/description you name. Uses a DISTINCT skeptical reviewer (never self-review) with the
        /// BallBusting contract: no gaslighting, every flaw named, a concrete fix proposed for each, an
        /// honest rating. Advisory — it proposes changes; it does not auto-apply them.
        func runBallbusting(args: String) async {
            guard let modelComplete else {
                print("\u{001B}[31mball-busting review is unavailable in this mode\u{001B}[0m"); return
            }
            let target = args.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject: String
            let label: String
            if !target.isEmpty {
                subject = target; label = "your description/plan"
            } else {
                let diff = Self.workingTreeDiff(projectRoot: projectRoot)
                if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    print("\u{001B}[2mnothing to bust — no working-tree changes. `/ballbusting <what to review>` to roast a plan or idea.\u{001B}[0m")
                    return
                }
                subject = diff; label = "the working-tree diff"
            }
            let reviewer = autoReviewer(answeredBy: activeBinding) ?? activeBinding
            let system = BallBusting.systemPrompt
            let user = BallBusting.prompt(subject: subject, label: label, grounding: reviewerGrounding())
            print("\u{001B}[31;1m🔨 ball-busting review\u{001B}[0m\u{001B}[2m · \(TeamLanguage.displayName(reviewer.providerId)) · zero gaslighting, every flaw named + a fix proposed\u{001B}[0m")
            guard let review = await modelComplete(reviewer.providerId, reviewer.model, system, user),
                  !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("\u{001B}[31mball-busting review returned nothing (reviewer unavailable)\u{001B}[0m")
                return
            }
            print(review)
        }

        // One advisory review pass. Reviews the working-tree DIFF for a coding turn, else the substantive
        // ANSWER text. The result distinguishes "not applicable" from a missing reviewer response so a
        // silent/failed model can never be counted as a clean vote.
        func runOneReview(task: String, answer: String = "", reviewer: ProviderBinding? = nil,
                          answeredBy: ProviderBinding? = nil,
                          baselineDiff: String? = nil) async -> Copilot.ReviewAttempt {
            guard let modelComplete else { return .incomplete("review completion is unavailable in this mode") }
            let author = answeredBy ?? activeBinding
            // `reviewer` lets ULTRA mode rotate the second opinion through a roster of minds; nil ⇒ the
            // default top-ranked distinct reviewer.
            guard let co = reviewer ?? autoReviewer(answeredBy: author) else {
                return .incomplete("no distinct reviewer is configured")
            }
            let isCoding = Copilot.shouldReview(trajectory: turnEvidenceSnapshot())
            let diff: String
            if isCoding {
                guard let baselineDiff else {
                    return .incomplete("turn-scoped review baseline is unavailable")
                }
                diff = Copilot.turnScopedReviewSubject(before: baselineDiff,
                                                       after: Self.workingTreeDiff(projectRoot: projectRoot))
                guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    // Never silently substitute a prose-summary review for an artifact review. Git cannot
                    // expose non-repository, ignored, binary, or already-committed changes; that is an
                    // incomplete review subject, not evidence that the change was clean.
                    return .incomplete("a mutation was recorded, but no turn-scoped textual git diff is available")
                }
                guard !diff.contains("Binary files "),
                      !diff.contains("[review input incomplete:"),
                      !diff.contains("[new file truncated at"),
                      !diff.contains("[turn delta truncated]") else {
                    return .incomplete("the turn's textual review subject was unavailable or truncated")
                }
            } else {
                diff = ""
            }
            // Ground the reviewer in the SAME context the primary turn had — its self-identity brief plus
            // durable project memory. Without this the second model is context-blind about the domain (it
            // has never heard of "Kist") and answers "I can't verify these claims" instead of reviewing.
            let grounding = reviewerGrounding()
            let system: String, userPrompt: String
            if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                system = Copilot.reviewSystemPrompt
                userPrompt = Copilot.reviewPrompt(task: task, diff: diff, projectContext: grounding)
            } else if Copilot.isSubstantiveAnswer(answer) {
                system = Copilot.answerReviewSystemPrompt
                userPrompt = Copilot.answerReviewPrompt(task: task, answer: answer, projectContext: grounding)
            } else {
                return .notApplicable("no reviewable diff or substantive answer")
            }
            print("\u{001B}[35m⎇ second opinion · \(TeamLanguage.displayName(co.providerId)) reviewing…\u{001B}[0m")
            let review = await InterruptibleTurn.run(onInterrupt: { reason in
                if reason == .cancel { TurnInputQueue.shared.clearAll() }
                else { TurnInputQueue.shared.commitPending() }
                print("\n\u{001B}[33m"
                      + (reason == .cancel ? "⎋⎋ review cancelled" : "⎋ review interrupted — your turn")
                      + "\u{001B}[0m")
            }) {
                await modelComplete(co.providerId, co.model, system, userPrompt)
            }
            guard let review, !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .incomplete("\(TeamLanguage.displayName(co.providerId)) returned no response")
            }
            print("\u{001B}[35m⎇ review (\(TeamLanguage.displayName(co.providerId))):\u{001B}[0m\n\(Copilot.safeReviewDisplay(review))")
            return .completed(review)
        }

        // ULTRA MODE: every reachable model independently reviews the current work. Review is advisory;
        // findings are handed back to the ORIGINAL author for a bounded repair, and executed build/tests
        // remain the separate verification authority.
        func ultraRoster(excluding answered: ProviderBinding) -> [ProviderBinding] {
            let configured = Set(providerAliases.values)
            // Capability order — Claude leads, Codex second, then the rest (matches the operator's mental model).
            let prefer = ["claude-cli", "codex-cli", "gemini", "deepseek", "mimo", "moonshot", "zhipu", "grok", "openai", "anthropic"]
            var seen = Set<String>(); var out: [ProviderBinding] = []
            for pid in prefer where configured.contains(pid) && pid != answered.providerId && seen.insert(pid).inserted {
                out.append(ProviderBinding(providerId: pid))
            }
            return out
        }

        func runUltraReview(task: String, answer: String, author: ProviderBinding,
                            turnIntent: TaskBrief.Intent,
                            baselineDiff: String?) async {
            let roster = ultraRoster(excluding: author)
            guard !roster.isEmpty else {
                let text = "incomplete — no distinct reviewers configured"
                print("\u{001B}[37m⎇ ultra · no other minds configured — add models with /model\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false, text: text))
                return
            }
            let maxRepairs = min(3, max(0, copilot.maxFixRounds))
            print("\u{001B}[35m⎇ ultra · consensus of minds: \(roster.map { TeamLanguage.displayName($0.providerId) }.joined(separator: " → "))\u{001B}[0m")
            print("\u{001B}[2m  advisory review · up to \(maxRepairs) author repair rounds\u{001B}[0m")
            var current = answer
            var repairs = 0
            while true {
                guard !lastTurnInterrupted else {
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "incomplete — review interrupted"))
                    return
                }
                let pass = repairs + 1
                var cleanCount = 0
                var findings: [Copilot.RepairFinding] = []
                var missing: [String] = []
                var notApplicableReason: String?
                for mind in roster {
                    guard !lastTurnInterrupted else {
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                                 text: "incomplete — review interrupted"))
                        return
                    }
                    let name = TeamLanguage.displayName(mind.providerId)
                    switch await runOneReview(task: task, answer: current, reviewer: mind, answeredBy: author,
                                              baselineDiff: baselineDiff) {
                    case .notApplicable(let reason):
                        notApplicableReason = reason
                    case .incomplete(let reason):
                        missing.append("\(name): \(reason)")
                    case .completed(let review):
                        switch Copilot.classifyReviewResponse(review) {
                        case .clean:
                            cleanCount += 1
                            print("\u{001B}[32m⎇ ultra · review · \(name) reported no blocking issues (pass \(pass))\u{001B}[0m")
                        case .findings(let structured):
                            findings.append(contentsOf: structured)
                        case .incomplete:
                            missing.append("\(name): malformed or non-contract response")
                        }
                    }
                }

                if let reason = notApplicableReason {
                    print("\u{001B}[37m⎇ ultra · review not run — \(reason)\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                             text: "not applicable — \(reason)"))
                    return
                }
                if findings.isEmpty {
                    if missing.isEmpty && cleanCount == roster.count {
                        print("\u{001B}[1;32m⎇ ultra · review consensus: \(cleanCount)/\(roster.count) reported no blocking issues (pass \(pass))\u{001B}[0m")
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: true,
                                                 text: "\(cleanCount)/\(roster.count) reviewers reported no blocking issues"))
                    } else {
                        print("\u{001B}[33m⎇ ultra · review incomplete: \(cleanCount)/\(roster.count) clean responses; missing \(missing.count)\u{001B}[0m")
                        for item in missing { print("\u{001B}[2m  · \(item)\u{001B}[0m") }
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                                 text: "incomplete — \(missing.count) reviewer response(s) missing"))
                    }
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    return
                }

                if !missing.isEmpty {
                    print("\u{001B}[33m⎇ ultra · review incomplete: \(missing.count) reviewer(s) returned no usable response; repairing known findings only\u{001B}[0m")
                }
                guard turnIntent != .delegate else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · delegated result has blocking findings; start a new explicit delegation to repair it\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "blocking delegated-child findings require a new explicit delegation"))
                    return
                }
                guard copilot.autoFix else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · review findings reported; automatic repair is off\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "blocking findings reported; automatic repair off"))
                    return
                }
                guard repairs < maxRepairs else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · review findings remain after \(maxRepairs) author repair rounds\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "blocking findings remain after \(maxRepairs) author repair rounds"))
                    return
                }
                guard let loopFactory else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · review findings reported; author repair is unavailable in this mode\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "blocking findings reported; author repair unavailable"))
                    return
                }

                repairs += 1
                print("\u{001B}[35m⎇ ultra · review complete → original author \(TeamLanguage.displayName(author.providerId)) repairing aggregated findings (round \(repairs)/\(maxRepairs))…\u{001B}[0m")
                armTurnLoop()
                let fixLoop = perm.arm(loopFactory(author, roleSelection.bindings, perm.mode.isPlan,
                                                    showReasoning, extendedThinking))
                archiveCurrentEvidencePhase()
                let oc = await runTurnInterruptible(loop: fixLoop,
                                                    userInput: Copilot.repairPrompt(task: task, findings: findings),
                                                    rawRequest: task, resolvedIntent: turnIntent)
                await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                if lastTurnInterrupted {
                    repairPhaseFailed = true
                    return
                }
                guard oc.success else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ ultra · repair incomplete — original author turn failed\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "repair incomplete — original author turn failed"))
                    return
                }
                current = oc.summary
            }
        }

        // R4: the coder↔reviewer partnership. The co-reviewer critiques the diff; if it flags blocking
        // issues AND auto-fix is armed (team mode), the LEAD runs a bounded fix turn to address them,
        // then the reviewer re-checks — a real team accomplishing the goal, not an advisory print.
        func runCopilotReview(task: String, answer: String = "", allowAdvisory: Bool = false,
                              authoredBy: ProviderBinding? = nil,
                              baselineDiff: String? = nil,
                              turnIntent: TaskBrief.Intent,
                              turnSucceeded: Bool) async {
            // R2a (review catch): after an interject the user's typed instruction must run NEXT —
            // not after a copilot model call they didn't ask for.
            if lastTurnInterrupted {
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                         text: "not run — turn interrupted"))
            }
            guard !lastTurnInterrupted else { return }
            // Run the review when team mode is on (enabled) OR an explicitly enabled advisory second opinion
            // applies to this DIRECT turn. Ordinary Q&A leaves autoSecondOpinion off by default.
            let advisory = allowAdvisory && copilot.autoSecondOpinion
            let automaticBuild = turnSucceeded && turnIntent.expectsMutation
                && copilot.automaticBuildReview
                && Copilot.shouldReview(trajectory: turnEvidenceSnapshot())
            guard copilot.enabled || advisory || automaticBuild else {
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                         text: "not requested"))
                return
            }
            let author = authoredBy ?? copilot.lead ?? activeBinding
            if copilot.ultra {
                await runUltraReview(task: task, answer: answer, author: author,
                                     turnIntent: turnIntent, baselineDiff: baselineDiff)
                return
            }

            var currentAnswer = answer
            let firstAttempt = await runOneReview(task: task, answer: currentAnswer, answeredBy: author,
                                                  baselineDiff: baselineDiff)
            var reviewResponse: Copilot.ReviewResponse
            switch firstAttempt {
            case .notApplicable(let reason):
                print("\u{001B}[37m⎇ review not run — \(reason)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: nil,
                                         text: "not applicable — \(reason)"))
                return
            case .incomplete(let reason):
                print("\u{001B}[33m⎇ review incomplete — \(reason)\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "incomplete — \(reason)"))
                return
            case .completed(let response):
                reviewResponse = Copilot.classifyReviewResponse(response)
            }
            if case .clean = reviewResponse {
                print("\u{001B}[32m⎇ review · no blocking issues reported\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: true,
                                         text: "reviewer reported no blocking issues"))
                return
            }
            guard case .findings = reviewResponse else {
                print("\u{001B}[33m⎇ review incomplete — reviewer returned malformed or non-contract output; automatic repair withheld\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "incomplete — malformed reviewer response; automatic repair withheld"))
                return
            }

            // `autoFix` is the authority: a review may print findings without silently creating another
            // mutating model turn. When armed, the ORIGINAL author—not the reviewer—owns every repair.
            guard turnIntent != .delegate else {
                repairPhaseFailed = true
                print("\u{001B}[33m⎇ review · delegated result has blocking findings; start a new explicit delegation to repair it\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "blocking delegated-child findings require a new explicit delegation"))
                return
            }
            guard copilot.autoFix else {
                repairPhaseFailed = true
                print("\u{001B}[33m⎇ review · findings reported; automatic repair is off\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "blocking findings reported; automatic repair off"))
                return
            }
            guard let loopFactory else {
                repairPhaseFailed = true
                print("\u{001B}[33m⎇ review · findings reported; author repair is unavailable in this mode\u{001B}[0m")
                print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "blocking findings reported; author repair unavailable"))
                return
            }
            let repairLimit = min(3, max(1, copilot.maxFixRounds))
            var round = 0
            while round < repairLimit {
                guard case .findings(let findings) = reviewResponse else { break }
                round += 1
                let fixer = author
                print("\u{001B}[35m⎇ review complete → original author \(TeamLanguage.displayName(fixer.providerId)) repairing findings (round \(round)/\(repairLimit))…\u{001B}[0m")
                armTurnLoop()
                let fixLoop = perm.arm(loopFactory(fixer, roleSelection.bindings, perm.mode.isPlan,
                                                   showReasoning, extendedThinking))
                // Start a fresh phase for the repair while archiving the original evidence. Review and
                // final verification consume the combined ledger; phase-local routing still sees only
                // the repair attempt currently executing.
                archiveCurrentEvidencePhase()
                let oc = await runTurnInterruptible(loop: fixLoop,
                                                    userInput: Copilot.repairPrompt(task: task, findings: findings),
                                                    rawRequest: task, resolvedIntent: turnIntent)
                await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                if lastTurnInterrupted {
                    repairPhaseFailed = true
                    return
                }     // user stepped in — stop the team loop
                guard oc.success else {
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ team · repair incomplete — original author turn failed\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "repair incomplete — original author turn failed"))
                    return
                }
                currentAnswer = oc.summary
                // Re-review the fix so the loop converges (or exhausts its bounded rounds).
                switch await runOneReview(task: task, answer: currentAnswer, answeredBy: author,
                                          baselineDiff: baselineDiff) {
                case .completed(let next):
                    reviewResponse = Copilot.classifyReviewResponse(next)
                    if case .incomplete = reviewResponse {
                        repairPhaseFailed = true
                        print("\u{001B}[33m⎇ team · review incomplete after repair — malformed or non-contract output; further automatic repair withheld\u{001B}[0m")
                        print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                        proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                                 text: "incomplete after repair — malformed reviewer response"))
                        return
                    }
                case .notApplicable(let reason):
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ team · review incomplete after repair — \(reason)\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "incomplete after repair — \(reason)"))
                    return
                case .incomplete(let reason):
                    repairPhaseFailed = true
                    print("\u{001B}[33m⎇ team · review incomplete after repair — \(reason)\u{001B}[0m")
                    print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                    proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                             text: "incomplete after repair — \(reason)"))
                    return
                }
            }
            if case .clean = reviewResponse {
                print("\u{001B}[32m⎇ team · review · no blocking issues reported after \(round) repair round(s)\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: true,
                                         text: "no blocking issues reported after \(round) author repair round(s)"))
            } else {
                repairPhaseFailed = true
                print("\u{001B}[33m⎇ team · review findings remain after \(repairLimit) repair rounds\u{001B}[0m")
                proofStore?.record(.init(kind: .reviewAssessment, tool: nil, success: false,
                                         text: "blocking findings remain after \(repairLimit) author repair rounds"))
            }
            print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
        }

}
