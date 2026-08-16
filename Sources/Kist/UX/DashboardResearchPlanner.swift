import Foundation
import AgentCore

struct DashboardInsightBundle: Sendable, Equatable {
    let research: [StatusDashboard.ResearchItem]
    let knowledgeDebt: [StatusDashboard.KnowledgeDebt]
    let questions: [String]
    let observation: StatusDashboard.Observation?

    var summaryLine: String? {
        let titles = research.prefix(3).map(\.title)
        guard !titles.isEmpty else { return nil }
        return titles.joined(separator: "; ")
    }
}

enum DashboardResearchPlanner {
    static func build(for plan: Plan, projectRoot: String,
                      trajectory: [ActionRecord], limit: Int = 6) -> DashboardInsightBundle {
        // Project identity must not select a permanent research syllabus. The dashboard is a view of
        // CURRENT work; strategic watch lists belong in the explicit Strategic Intelligence workflow.
        _ = projectRoot

        var seen = Set<String>()
        var research: [StatusDashboard.ResearchItem] = []

        func add(_ item: StatusDashboard.ResearchItem) {
            let key = item.title.lowercased()
            guard !seen.contains(key), research.count < limit else { return }
            seen.insert(key)
            research.append(item)
        }

        let explicitResearch = plan.tasks
            .filter { $0.kind == .research && $0.status != .done }
            .sorted(by: { $0.id < $1.id })

        for task in explicitResearch.filter({ $0.status == .inProgress }).prefix(2) {
            add(StatusDashboard.ResearchItem(
                title: task.boardTitle,
                priority: .high,
                reason: firstNonEmpty(task.detail, task.acceptance,
                                      "Explicit research item already exists on the shared board."),
                visit: firstNonEmpty(task.link ?? "", task.evidence.first ?? "",
                                     "Official docs and primary sources for \(task.boardTitle)"),
                impact: task.status == .inProgress ? 5 : 4,
                estimatedLearning: "1-2 hours",
                expectedBenefit: ["turn board research into an evidence-backed product decision"]
            ))
        }

        for task in explicitResearch.filter({ $0.status != .inProgress }).prefix(2) {
            add(StatusDashboard.ResearchItem(
                title: task.boardTitle,
                priority: .medium,
                reason: firstNonEmpty(task.detail, task.acceptance,
                                      "Explicit research item already exists on the shared board."),
                visit: firstNonEmpty(task.link ?? "", task.evidence.first ?? "",
                                     "Official docs and primary sources for \(task.boardTitle)"),
                impact: 4,
                estimatedLearning: "1-2 hours",
                expectedBenefit: ["turn board research into an evidence-backed product decision"]
            ))
        }

        if research.isEmpty, let next = plan.active ?? plan.next {
            add(StatusDashboard.ResearchItem(
                title: "Research prior art for \(next.boardTitle)",
                priority: .high,
                reason: "The next build task should be shaped by comparable systems before implementation hardens.",
                visit: "Official docs, source, and benchmarks for systems solving \(next.boardTitle)",
                impact: 3,
                estimatedLearning: "1 hour",
                expectedBenefit: ["avoid building from guesswork"]
            ))
        } else if research.isEmpty, !trajectory.isEmpty {
            add(StatusDashboard.ResearchItem(
                title: "Trace evidence gaps from /logs",
                priority: .medium,
                reason: "The turn used tools but left no explicit research debt attached to the board.",
                visit: "/logs, changed files, and official docs for touched subsystems",
                impact: 3,
                estimatedLearning: "45 minutes",
                expectedBenefit: ["turn observed uncertainty into a concrete learning task"]
            ))
        }

        let debt = knowledgeDebt(research: research)
        let questions = questions(plan: plan)
        let observation = observation(research: research)

        return DashboardInsightBundle(research: Array(research.prefix(limit)),
                                      knowledgeDebt: debt,
                                      questions: questions,
                                      observation: observation)
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private static func knowledgeDebt(research: [StatusDashboard.ResearchItem]) -> [StatusDashboard.KnowledgeDebt] {
        return research.prefix(3).map {
            StatusDashboard.KnowledgeDebt(need: "Need to research", topic: $0.title,
                                          impact: $0.expectedBenefit.first ?? $0.reason,
                                          severity: $0.impact)
        }
    }

    private static func questions(plan: Plan) -> [String] {
        if let next = plan.active ?? plan.next {
            return [
                "What unknown could invalidate \(next.boardTitle)?",
                "Which comparable system should be studied before building the next version?",
                "What evidence would change the implementation plan?"
            ]
        }
        return []
    }

    private static func observation(research: [StatusDashboard.ResearchItem]) -> StatusDashboard.Observation? {
        guard !research.isEmpty else { return nil }
        let top = research.prefix(3).map(\.title)
        let roi = research.contains { $0.impact >= 5 } ? "High" : "Medium"
        let message = "The current board has an evidence gap. Resolve or complete its research task to change this queue."
        return StatusDashboard.Observation(message: message, recommendedReading: Array(top), expectedROI: roi)
    }
}
