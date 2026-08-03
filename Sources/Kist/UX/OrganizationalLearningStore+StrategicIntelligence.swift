import Foundation
import AgentCore

extension OrganizationalLearningStore {
    struct StrategicAgendaItem: Equatable {
        var title: String
        var reason: String
    }

    func strategicResearchItems(from intelligence: StrategicIntelligenceSnapshot) -> [StatusDashboard.ResearchItem] {
        intelligence.sourceTargets.map { target in
            StatusDashboard.ResearchItem(
                title: "Compare: \(target.title)",
                priority: target.priority == .high ? .high : .medium,
                reason: target.reason + " " + target.researchQuestion,
                visit: target.sourceTarget,
                impact: target.expectedImpact,
                estimatedLearning: target.priority == .high ? "2-3 hours" : "90 minutes",
                expectedBenefit: [target.proposedEvolution, target.benchmarkPlan]
            )
        }
    }

    @discardableResult
    func recordStrategicIntelligence(_ intelligence: StrategicIntelligenceSnapshot) -> Int {
        var count = 0
        for target in intelligence.sourceTargets {
            if appendJSON(DiskMemoryRecord(
                id: target.id,
                title: target.title,
                summary: "\(target.category.rawValue) comparison: \(target.reason)",
                body: [
                    "Source target: \(target.sourceTarget)",
                    "Compare against: \(target.compareAgainst.joined(separator: "; "))",
                    "Research question: \(target.researchQuestion)",
                    "Likely Kist gap: \(target.likelyKistGap)",
                    "Benchmark plan: \(target.benchmarkPlan)",
                    "Proposed evolution: \(target.proposedEvolution)"
                ].joined(separator: "\n"),
                source: target.sourceTarget,
                confidence: target.priority == .high ? 80 : 68,
                impact: target.expectedImpact,
                tags: ["strategic-intelligence", target.category.rawValue, target.priority.rawValue]
            ), to: industryIntelligencePath) {
                count += 1
            }
        }
        for proposal in intelligence.proposals {
            if appendJSON(DiskMemoryRecord(
                id: proposal.id,
                title: proposal.title,
                summary: proposal.reason,
                body: [
                    "Evidence needed: \(proposal.evidenceNeeded.joined(separator: "; "))",
                    "Benchmark plan: \(proposal.benchmarkPlan)",
                    "Teachable rule: \(proposal.teachableRule)"
                ].joined(separator: "\n"),
                source: Self.projectRelative(industryIntelligencePath, root: projectRoot),
                confidence: 82,
                impact: proposal.expectedImpact,
                tags: ["evolution-proposal", "strategic-intelligence"]
            ), to: evolutionProposalsPath) {
                count += 1
            }
        }
        writeStrategicArchive(intelligence)
        return count
    }

    @discardableResult
    func promoteStrategicProposalRules(_ intelligence: StrategicIntelligenceSnapshot,
                                               existingRuleIDs: Set<String>) -> Int {
        var promoted = 0
        for proposal in intelligence.proposals
            .filter({ $0.expectedImpact >= 5 })
            .prefix(3) {
            let id = Self.ruleID(proposal.teachableRule)
            guard !existingRuleIDs.contains(id) else { continue }
            let record = promoteOrganizationalRule(
                lesson: proposal.teachableRule,
                confidence: min(96, 82 + proposal.expectedImpact * 2),
                reason: "Promoted from Strategic Intelligence proposal `\(proposal.title)`.",
                evidence: proposal.evidenceNeeded + [proposal.benchmarkPlan],
                sourceCapsuleID: nil)
            if record.status == .active {
                promoted += 1
            }
        }
        return promoted
    }

    func writeStrategicArchive(_ intelligence: StrategicIntelligenceSnapshot) {
        let dir = researchArchiveRoot + "/strategic-intelligence"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines = [
            "# Strategic Intelligence \(intelligence.id)",
            "",
            "Objective: \(intelligence.objective)",
            "",
            "## Source Targets",
        ]
        for target in intelligence.sourceTargets {
            lines += [
                "- \(target.title)",
                "  Source target: \(target.sourceTarget)",
                "  Research question: \(target.researchQuestion)",
                "  Compare against: \(target.compareAgainst.joined(separator: "; "))",
                "  Likely Kist gap: \(target.likelyKistGap)",
                "  Benchmark plan: \(target.benchmarkPlan)",
            ]
        }
        lines += ["", "## Evolution Proposals"]
        for proposal in intelligence.proposals {
            lines += [
                "- \(proposal.title)",
                "  Reason: \(proposal.reason)",
                "  Evidence needed: \(proposal.evidenceNeeded.joined(separator: "; "))",
                "  Benchmark plan: \(proposal.benchmarkPlan)",
                "  Teachable rule: \(proposal.teachableRule)",
            ]
        }
        lines += ["", "## Questions"]
        lines += intelligence.questions.map { "- \($0)" }
        let path = dir + "/\(intelligence.id).md"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    func mergeResearch(_ items: [StatusDashboard.ResearchItem]) -> [StatusDashboard.ResearchItem] {
        var seen = Set<String>()
        var out: [StatusDashboard.ResearchItem] = []
        for item in items {
            let key = item.title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

    func strategicIntelligenceAgenda(strategy: CaptainStrategyPlan,
                                             debts: [KnowledgeDebtRecord],
                                             insights: DashboardInsightBundle) -> [StrategicAgendaItem] {
        var items: [StrategicAgendaItem] = [
            StrategicAgendaItem(title: "Scan competitor agent workflows",
                                reason: "Captain architecture should be compared against shipped behavior, not internal assumptions."),
            StrategicAgendaItem(title: "Scan new papers and benchmark suites",
                                reason: "Learning policy should evolve only when research or evals change expected outcomes."),
            StrategicAgendaItem(title: "Review tool and permission lifecycle changes",
                                reason: "MCP, browser, sandbox, and background-worker changes can alter Kist's safety model."),
            StrategicAgendaItem(title: "Check local/offline reasoning roadmap",
                                reason: "Cloud routing assumptions may become stale as local models improve."),
        ]
        for debt in debts.prefix(3) {
            items.append(StrategicAgendaItem(title: "Pay knowledge debt: \(debt.topic)",
                                             reason: debt.reason))
        }
        for research in insights.research.prefix(2) {
            items.append(StrategicAgendaItem(title: research.title,
                                             reason: research.reason))
        }
        if strategy.requiredExpertise.contains(where: { $0.name == "strategic-intelligence-analyst" }) {
            items.insert(StrategicAgendaItem(title: "Create recurring Strategic Intelligence cadence",
                                             reason: "This objective directly asks Captain to watch industry movement and produce evolution proposals."),
                         at: 0)
        }
        return dedupe(items)
    }

    func dedupe(_ items: [StrategicAgendaItem]) -> [StrategicAgendaItem] {
        var seen = Set<String>()
        var out: [StrategicAgendaItem] = []
        for item in items {
            let key = item.title.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

}
