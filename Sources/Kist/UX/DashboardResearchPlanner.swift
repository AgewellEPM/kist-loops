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
        let projectName = URL(fileURLWithPath: projectRoot).lastPathComponent.lowercased()
        // The hardcoded Claude Code / Cursor / OpenHands / MCP / Foundation-Models items are research
        // for building KIST ITSELF. A broad substring match (agent/worker/background/mcp/…) fired on
        // almost every turn — even on unrelated projects run from ~ — so the panel showed the SAME
        // irrelevant suggestions forever instead of reflecting the actual work. Gate them on being in
        // the real Kist repo; everywhere else, research is derived from the current board/next task.
        let isKistProject = projectName == "kist" || projectName == "kist-loops"
            || projectName.hasPrefix("kist-") || projectName == "mythos"
        let orchestrationContext = isKistProject
        let learningContext = isKistProject
        let toolContext = isKistProject

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

        if orchestrationContext {
            add(StatusDashboard.ResearchItem(
                title: "Study Claude Code's fleet scheduling",
                priority: .high,
                reason: "Compare orchestration strategy against Kist's Captain/worker handoff.",
                visit: "Claude Code docs: subagents, hooks, background work, permissions",
                impact: 5,
                estimatedLearning: "2 hours",
                expectedBenefit: ["sharper delegation model", "cleaner task isolation"]
            ))
            add(StatusDashboard.ResearchItem(
                title: "Analyze Cursor background agents",
                priority: .high,
                reason: "Kist needs durable task persistence while work continues outside the foreground turn.",
                visit: "Cursor docs and background-agent product notes",
                impact: 5,
                estimatedLearning: "2 hours",
                expectedBenefit: ["better task persistence", "clearer resume and status UX"]
            ))
            add(StatusDashboard.ResearchItem(
                title: "Review OpenHands planning loop",
                priority: .high,
                reason: "Multi-step execution should be compared against an open planner/runtime loop.",
                visit: "OpenHands planner, runtime, and agent-loop docs/source",
                impact: 4,
                estimatedLearning: "2-3 hours",
                expectedBenefit: ["stronger Plan -> Execute loop", "less ad hoc agent scheduling"]
            ))
        }

        if toolContext {
            add(StatusDashboard.ResearchItem(
                title: "Compare Anthropic MCP lifecycle",
                priority: orchestrationContext ? .medium : .high,
                reason: "Current tool routing needs a clean lifecycle, permission, and background-worker comparison.",
                visit: "Anthropic MCP specification and official server examples",
                impact: 4,
                estimatedLearning: "90 minutes",
                expectedBenefit: ["fewer MCP surprises", "cleaner tool permission model"]
            ))
        }

        if isKistProject {
            add(StatusDashboard.ResearchItem(
                title: "Read Apple Foundation Models docs",
                priority: .medium,
                reason: "Current architecture assumes cloud routing; local reasoning changes latency, privacy, and fallback design.",
                visit: "Apple Foundation Models and Apple Intelligence developer docs",
                impact: 5,
                estimatedLearning: "3 hours",
                expectedBenefit: ["reduce latency", "enable offline orchestration roadmap"]
            ))
        }

        if learningContext {
            add(StatusDashboard.ResearchItem(
                title: "Study DGM self-improvement architecture",
                priority: .medium,
                reason: "Learning from benchmarks and live eval loops needs a promotion system that rewards real improvement.",
                visit: "DGM paper, code, and benchmark methodology",
                impact: 4,
                estimatedLearning: "3 hours",
                expectedBenefit: ["safer self-improvement engine", "clearer promotion criteria"]
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

        let debt = knowledgeDebt(orchestrationContext: orchestrationContext,
                                 learningContext: learningContext,
                                 research: research)
        let questions = questions(orchestrationContext: orchestrationContext,
                                  learningContext: learningContext,
                                  plan: plan)
        let observation = observation(orchestrationContext: orchestrationContext,
                                      research: research)

        return DashboardInsightBundle(research: Array(research.prefix(limit)),
                                      knowledgeDebt: debt,
                                      questions: questions,
                                      observation: observation)
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private static func knowledgeDebt(orchestrationContext: Bool, learningContext: Bool,
                                      research: [StatusDashboard.ResearchItem]) -> [StatusDashboard.KnowledgeDebt] {
        if orchestrationContext {
            var items: [StatusDashboard.KnowledgeDebt] = [
                .init(need: "Need to understand", topic: "Apple Foundation Models",
                      impact: "Captain roadmap, local reasoning, offline orchestration", severity: 5),
                .init(need: "Need to benchmark", topic: "Cursor background execution",
                      impact: "Task persistence and long-running work UX", severity: 4),
                .init(need: "Need to compare", topic: "OpenHands planning loop",
                      impact: "Agent scheduling and multi-step execution", severity: 4)
            ]
            if learningContext {
                items.append(.init(need: "Need to study", topic: "DGM evolution architecture",
                                   impact: "Self-improvement and benchmark promotion gates", severity: 4))
            }
            return Array(items.prefix(4))
        }

        return research.prefix(3).map {
            StatusDashboard.KnowledgeDebt(need: "Need to research", topic: $0.title,
                                          impact: $0.expectedBenefit.first ?? $0.reason,
                                          severity: $0.impact)
        }
    }

    private static func questions(orchestrationContext: Bool, learningContext: Bool, plan: Plan) -> [String] {
        if orchestrationContext {
            var out = [
                "Can Captain become fully autonomous without losing human-readable gates?",
                "Should planning become hierarchical before more agents are added?",
                "Can memory become evidence-driven instead of transcript-driven?"
            ]
            if learningContext {
                out[2] = "Which benchmark and live-eval signals are strong enough to promote a learned strategy?"
            }
            return out
        }
        if let next = plan.active ?? plan.next {
            return [
                "What unknown could invalidate \(next.boardTitle)?",
                "Which comparable system should be studied before building the next version?",
                "What evidence would change the implementation plan?"
            ]
        }
        return []
    }

    private static func observation(orchestrationContext: Bool,
                                    research: [StatusDashboard.ResearchItem]) -> StatusDashboard.Observation? {
        guard !research.isEmpty else { return nil }
        let top = research.prefix(3).map(\.title)
        let roi = research.contains { $0.impact >= 5 } ? "High" : "Medium"
        let message: String
        if orchestrationContext {
            message = "The build queue is moving Captain architecture faster than the evidence base. Treat the top research item as product work before another major orchestration pass."
        } else {
            message = "The next build step has open knowledge debt. A short research pass may change the implementation shape."
        }
        return StatusDashboard.Observation(message: message, recommendedReading: Array(top), expectedROI: roi)
    }
}
