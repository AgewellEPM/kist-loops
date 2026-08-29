import Foundation
import AgentCore

extension OrganizationalLearningStore {
    func runBoardMeeting(plan: Plan, trajectory: [ActionRecord]) -> EvolutionBoardReport {
        runBoardMeeting(plan: plan, trajectory: trajectory, at: now())
    }

    func runBoardMeeting(plan: Plan, trajectory: [ActionRecord],
                         at instant: Date) -> EvolutionBoardReport {
        let insights = DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                       trajectory: trajectory, limit: 6)
        let debts = openKnowledgeDebt(limit: 8, at: instant)
        let latest = latestTemporallyEligibleCapsule(at: instant)
        let timestamp = Int(instant.timeIntervalSince1970)
        let path = boardMeetingsRoot + "/\(timestamp)-evolve.md"
        ensureMemoryArchitecture()
        let strategy = CaptainStrategist.plan(objective: strategyObjective(plan: plan),
                                              evidence: CaptainProjectEvidence.capture(projectRoot: projectRoot),
                                              specialists: makeSpecialistRegistry(projectRoot).load())
        // The hardcoded Kist competitor watch-list only belongs when developing Kist itself.
        let pname = URL(fileURLWithPath: projectRoot).lastPathComponent.lowercased()
        let isKistProject = pname == "kist" || pname == "kist-loops" || pname.hasPrefix("kist-") || pname == "mythos"
        let intelligence = StrategicIntelligencePlanner.build(
            objective: strategy.objective,
            strategy: strategy,
            debts: debts,
            insights: insights,
            learning: captainLearningRetrievalSummaries(
                now: instant.timeIntervalSince1970),
            generatedAt: instant.timeIntervalSince1970,
            isKistProject: isKistProject)
        let strategicResearch = strategicResearchItems(from: intelligence)
        let combinedInsights = DashboardInsightBundle(
            research: mergeResearch(strategicResearch + insights.research),
            knowledgeDebt: insights.knowledgeDebt,
            questions: insights.questions,
            observation: insights.observation)
        let seeded = seedResearchTasks(plan: plan, insights: combinedInsights)
        let strategicRecords = recordStrategicIntelligence(intelligence)
        let retrieval = retrievalContext(
            objective: strategy.objective, strategy: strategy, at: instant)
        let createdSpecialists = createMissingSpecialists(strategy.missingSpecialists)
        let existingRuleIDs = Set(permanentRules(limit: Int.max).map(\.id))
        let taughtRule = teachCaptain(plan: plan, latest: latest, strategy: strategy,
                                      intelligence: intelligence)
        let taughtNew = taughtRule.map {
            $0.status == .active && !existingRuleIDs.contains($0.id)
        } ?? false
        let reservedRuleIDs = taughtRule.map {
            existingRuleIDs.union([$0.id])
        } ?? existingRuleIDs
        let promotedStrategicRules = promoteStrategicProposalRules(
            intelligence,
            existingRuleIDs: reservedRuleIDs)
        let promotedRules = (taughtNew ? 1 : 0) + promotedStrategicRules
        let rules = permanentRules(limit: 5)
        let proposed = proposedRules(limit: 5)

        var lines = [
            "# Kist Evolution Board Meeting",
            "",
            "Primary question: How does this engineering organization become better every day?",
            "",
            "## Captain Strategy",
            strategy.briefing,
            "",
            "## Captain Memory Architecture",
            renderCaptainMemoryArchitecture(),
            "",
            "## Captain Retrieval",
            retrieval.briefing,
            "",
            "## Recent Learning",
        ]
        if let latest {
            lines += [
                "- Latest build: \(latest.taskTitle) (\(latest.status.rawValue))",
                "- Learned: \(latest.learned.prefix(3).joined(separator: "; "))",
                "- Future evolution: \(latest.futureEvolution)",
            ]
        } else {
            lines.append("- No capsule recorded yet. Run real work, then reflect.")
        }
        lines += [
            "",
            "## Strategic Intelligence",
            "Question: What changed in industry today, and should Kist evolve?",
        ]
        for item in intelligence.sourceTargets.prefix(8) {
            lines += [
                "- \(stars(item.expectedImpact)) \(item.title)",
                "  Category: \(item.category.rawValue) / \(item.priority.rawValue) priority",
                "  Source target: \(item.sourceTarget)",
                "  Compare against: \(item.compareAgainst.joined(separator: "; "))",
                "  Research question: \(item.researchQuestion)",
                "  Likely Kist gap: \(item.likelyKistGap)",
                "  Proposed evolution: \(item.proposedEvolution)",
            ]
        }
        lines += [
            "",
            "## Evolution Proposal",
        ]
        for proposal in intelligence.proposals.prefix(6) {
            lines += [
                "- \(stars(proposal.expectedImpact)) \(proposal.title)",
                "  Reason: \(proposal.reason)",
                "  Evidence needed: \(proposal.evidenceNeeded.joined(separator: "; "))",
                "  Benchmark plan: \(proposal.benchmarkPlan)",
                "  Teachable rule: \(proposal.teachableRule)",
            ]
        }
        lines += ["", "## Teach Captain",
                  "Question: What organizational lesson should become permanent?"]
        if let taughtRule {
            lines += [
                "\(taughtRule.status == .active ? "Promoted" : "Proposed") rule: \(taughtRule.id)",
                "Lesson: \(taughtRule.lesson)",
                "Confidence: \(taughtRule.confidence)%",
                "Status: \(taughtRule.status.rawValue)",
                "Reason: \(taughtRule.reason)",
            ]
        } else {
            lines += [
                "Status: PERSISTENCE REFUSED",
                "No rule was reported as taught; the existing organizational ledger was preserved.",
            ]
        }
        lines += ["", "## Highest Knowledge Debt"]
        let debtRows = debts.isEmpty
            ? insights.research.map { ($0.title, $0.reason, $0.impact) }
            : debts.map { ($0.topic, $0.reason, $0.impact) }
        for row in debtRows.prefix(6) {
            lines += ["- \(stars(row.2)) \(row.0)", "  Reason: \(row.1)"]
        }
        lines += ["", "## Permanent Organizational Rules"]
        if rules.isEmpty {
            lines.append("- None active. Proposed lessons must clear the evidence gate before entering Captain memory.")
        } else {
            for rule in rules {
                lines += ["- \(rule.id) (\(rule.confidence)%): \(rule.lesson)", "  Why: \(rule.reason)"]
            }
        }
        if !proposed.isEmpty {
            lines += ["", "## Proposed Rules Awaiting Evidence"]
            for rule in proposed {
                lines += ["- \(rule.id) (\(rule.confidence)%): \(rule.lesson)", "  Why blocked: \(rule.reason)"]
            }
        }
        lines += [
            "",
            "## Industry Research Agenda",
        ]
        lines += intelligence.sourceTargets.prefix(8).map {
            "- \($0.title): \($0.sourceTarget)"
        }
        lines += [
            "",
            "## Roadmap Ranked By Expected Impact",
        ]
        lines += intelligence.proposals.enumerated().map { index, proposal in
            "\(index + 1). \(proposal.title) -- \(proposal.reason)"
        }
        lines += [
            "",
            "## Assumptions To Challenge",
        ]
        lines += intelligence.assumptionsToChallenge.map { "- \($0)" }
        lines += [
            "",
            "Seeded research tasks: \(seeded)",
            "Created specialists: \(createdSpecialists)",
            "Promoted organizational rules: \(promotedRules)",
            "Strategic intelligence records: \(strategicRecords)",
        ]
        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(atPath: boardMeetingsRoot, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return EvolutionBoardReport(path: Self.projectRelative(path, root: projectRoot), text: text,
                                    seededResearchTasks: seeded, createdSpecialists: createdSpecialists,
                                    promotedRules: promotedRules)
    }

    func evolutionProposal(strategy: CaptainStrategyPlan, debts: [KnowledgeDebtRecord]) -> String {
        if strategy.requiredExpertise.contains(where: { $0.name == "agent-orchestration-architect" }) {
            return "Add delegation decision cards backed by research, live evals, and competitor/runtime comparison."
        }
        if let debt = debts.first {
            return "Prioritize paying `\(debt.topic)` before hardening the next architecture decision."
        }
        return "Run a weekly `/evolve` board meeting that scans industry change, updates knowledge debt, and teaches Captain one permanent rule."
    }

    @discardableResult
    func teachCaptain(plan: Plan, latest: LearningCapsule?,
                              strategy: CaptainStrategyPlan,
                              intelligence: StrategicIntelligenceSnapshot) -> OrganizationalRuleRecord? {
        let lesson = CaptainStrategist.organizationalLessonCandidate(
            objective: strategy.objective,
            expertiseNames: strategy.requiredExpertise.map(\.name)
        )
        var evidence = [
            "stage order includes \(CaptainStrategyStage.strategicIntelligence.title), \(CaptainStrategyStage.evolutionProposal.title), and \(CaptainStrategyStage.teachCaptain.title)",
            "understanding confidence \(strategy.understanding.confidence)% / threshold \(strategy.understanding.threshold)%",
        ]
        if let latest {
            evidence.append("latest capsule \(latest.id): \(latest.taskTitle) \(latest.status.rawValue)")
        }
        if let active = plan.active {
            evidence.append("active task: \(active.boardTitle)")
        } else if let next = plan.next {
            evidence.append("next task: \(next.boardTitle)")
        }
        if let topTarget = intelligence.sourceTargets.first {
            evidence.append("strategic target: \(topTarget.title) -> \(topTarget.proposedEvolution)")
        }
        if let topProposal = intelligence.proposals.first {
            evidence.append("evolution proposal: \(topProposal.title) / \(topProposal.benchmarkPlan)")
        }
        let confidence = strategy.understanding.canOrganize ? 92 : 86
        return promoteOrganizationalRule(
            lesson: lesson,
            confidence: confidence,
            reason: "Teach Captain converts the board meeting retrospective into institutional operating knowledge.",
            evidence: evidence,
            sourceCapsuleID: latest?.id
        )
    }

}
