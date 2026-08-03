import Foundation
import AgentCore

struct StrategicIntelligenceTarget: Codable, Equatable, Sendable {
    enum Category: String, Codable, Equatable, Sendable {
        case competitor
        case openSource
        case standard
        case paper
        case platform
        case benchmark
    }

    enum Priority: String, Codable, Equatable, Sendable {
        case high
        case medium
    }

    var id: String
    var title: String
    var category: Category
    var priority: Priority
    var sourceTarget: String
    var compareAgainst: [String]
    var researchQuestion: String
    var reason: String
    var likelyKistGap: String
    var expectedImpact: Int
    var benchmarkPlan: String
    var proposedEvolution: String
}

struct StrategicEvolutionProposal: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var reason: String
    var expectedImpact: Int
    var evidenceNeeded: [String]
    var benchmarkPlan: String
    var teachableRule: String
}

struct StrategicIntelligenceSnapshot: Codable, Equatable, Sendable {
    var id: String
    var objective: String
    var generatedAt: Double
    var sourceTargets: [StrategicIntelligenceTarget]
    var proposals: [StrategicEvolutionProposal]
    var assumptionsToChallenge: [String]
    var questions: [String]
}

enum StrategicIntelligencePlanner {
    static func build(objective: String,
                      strategy: CaptainStrategyPlan,
                      debts: [KnowledgeDebtRecord],
                      insights: DashboardInsightBundle,
                      learning: [CaptainLearningSummary],
                      generatedAt: Double,
                      isKistProject: Bool = false) -> StrategicIntelligenceSnapshot {
        let context = [
            objective,
            strategy.objective,
            strategy.requiredExpertise.map(\.name).joined(separator: " "),
            debts.map(\.topic).joined(separator: " "),
            insights.research.map(\.title).joined(separator: " "),
            learning.map { $0.taskTags.joined(separator: " ") }.joined(separator: " ")
        ].joined(separator: "\n").lowercased()

        let orchestration = containsAny(context, ["captain", "orchestrat", "agent", "fleet", "worker", "delegate", "background"])
        let learningLoop = containsAny(context, ["learning", "benchmark", "eval", "evolve", "dgm", "promotion"])
        let toolLifecycle = orchestration || containsAny(context, ["mcp", "tool", "permission", "sandbox", "browser"])
        let localReasoning = containsAny(context, ["local", "offline", "apple", "foundation", "latency", "privacy"])

        // The hardcoded competitor/roadmap watch-list (Cursor/OpenHands/Claude Code/MCP/Apple) is Kist's
        // OWN self-improvement roadmap — only relevant when developing Kist itself. On any other project it
        // made the "goals" never change (same 5 items every turn, unrelated to the actual work). Gate it.
        var targets = isKistProject ? baselineTargets() : []
        if orchestration {
            promote(["cursor-background-agents", "openhands-planner-runtime", "claude-code-subagents-hooks"], in: &targets)
        }
        if learningLoop {
            promote(["dgm-self-improvement", "swe-bench-live-evals"], in: &targets)
        }
        if toolLifecycle {
            promote(["anthropic-mcp-lifecycle", "codex-cli-agent-controls"], in: &targets)
        }
        if localReasoning {
            promote(["apple-foundation-models"], in: &targets)
        }
        for debt in debts.prefix(3) {
            targets.append(StrategicIntelligenceTarget(
                id: "knowledge-debt-\(slug(debt.topic))",
                title: "Pay knowledge debt: \(debt.topic)",
                category: .benchmark,
                priority: debt.priority == .high ? .high : .medium,
                sourceTarget: debt.visit,
                compareAgainst: ["current Kist architecture", "implementation evidence", "benchmarks"],
                researchQuestion: "What evidence would pay down `\(debt.topic)` enough to change the roadmap?",
                reason: debt.reason,
                likelyKistGap: "Knowledge debt is tracked, but the evidence may not yet be archived or benchmarked.",
                expectedImpact: debt.impact,
                benchmarkPlan: "Attach source notes, then run the smallest /eval or /bench that would expose the architectural risk.",
                proposedEvolution: "Convert this debt item into an evidence-backed Captain rule or close it as paid."
            ))
        }

        targets = dedupe(targets)
            .sorted {
                if $0.priority != $1.priority { return $0.priority == .high }
                if $0.expectedImpact != $1.expectedImpact { return $0.expectedImpact > $1.expectedImpact }
                return $0.title < $1.title
            }

        let proposals = evolutionProposals(targets: targets, learning: learning,
                                           orchestration: orchestration,
                                           learningLoop: learningLoop,
                                           toolLifecycle: toolLifecycle,
                                           localReasoning: localReasoning)
        return StrategicIntelligenceSnapshot(
            id: "SI-\(Int(generatedAt))-\(slug(objective).prefix(32))",
            objective: objective,
            generatedAt: generatedAt,
            sourceTargets: Array(targets.prefix(10)),
            proposals: proposals,
            assumptionsToChallenge: [
                "Kist's current architecture is ahead of competitor workflows.",
                "Local project evidence is enough to decide platform direction.",
                "The next best action is implementation rather than research.",
                "A proposal is ready before it has source evidence and a benchmark plan."
            ],
            questions: [
                "What changed in competitor workflows or standards that should alter Captain's roadmap?",
                "Which paper, benchmark, or open-source runtime invalidates a current Kist assumption?",
                "Which evolution proposal should become a permanent organizational rule after evidence?"
            ]
        )
    }

    private static func baselineTargets() -> [StrategicIntelligenceTarget] {
        [
            .init(id: "claude-code-subagents-hooks",
                  title: "Claude Code subagents, hooks, and permissions",
                  category: .competitor,
                  priority: .medium,
                  sourceTarget: "Official Claude Code docs and release notes for subagents, hooks, MCP, permissions, and background work.",
                  compareAgainst: ["Captain/worker handoff", "specialist registry", "permission bar", "MCP lifecycle"],
                  researchQuestion: "Where does Claude Code separate orchestration, tools, permissions, and background workers better than Kist?",
                  reason: "Claude Code is a shipped agent shell with comparable delegation and tool-control pressure.",
                  likelyKistGap: "Kist has strong orchestration primitives, but delegation decisions and lifecycle changes are not yet visible as first-class evidence.",
                  expectedImpact: 5,
                  benchmarkPlan: "Create a delegation/task-persistence eval that compares visible decision cards, permission handling, and restart recovery.",
                  proposedEvolution: "Add delegation decision cards for every specialist or fleet assignment."),
            .init(id: "codex-cli-agent-controls",
                  title: "Codex CLI agent controls and AGENTS.md behavior",
                  category: .competitor,
                  priority: .medium,
                  sourceTarget: "Official Codex CLI docs/manual and AGENTS.md behavior notes.",
                  compareAgainst: ["AGENTS.md loading", "approval modes", "tool execution", "sandbox behavior"],
                  researchQuestion: "Which Codex CLI controls should Kist mirror, avoid, or exceed?",
                  reason: "Kist runs in the same operator space and should learn from Codex's control model.",
                  likelyKistGap: "Kist has rich UX, but its strategic rules are not always mapped back to operator-control guarantees.",
                  expectedImpact: 4,
                  benchmarkPlan: "Run an eval over AGENTS.md precedence, approval semantics, and tool visibility.",
                  proposedEvolution: "Map each Captain rule to an operator-visible control or proof artifact."),
            .init(id: "cursor-background-agents",
                  title: "Cursor background agents and task persistence",
                  category: .competitor,
                  priority: .medium,
                  sourceTarget: "Cursor docs, changelog, and product notes for background agents, task status, and resumability.",
                  compareAgainst: ["Kist task board", "fleet worktrees", "run replay", "resume UX"],
                  researchQuestion: "How should Kist persist long-running work so the foreground shell never feels stuck?",
                  reason: "Background execution changes how users trust long-running multi-agent work.",
                  likelyKistGap: "Kist can run fleets, but persistent worker lifecycle and operator status are not yet a product-grade loop.",
                  expectedImpact: 5,
                  benchmarkPlan: "Simulate interrupted long-running work and score recovery, status clarity, and proof continuity.",
                  proposedEvolution: "Add persistent background worker state with resumable status cards."),
            .init(id: "openhands-planner-runtime",
                  title: "OpenHands planner/runtime loop",
                  category: .openSource,
                  priority: .medium,
                  sourceTarget: "OpenHands source, planner/runtime docs, issues, and benchmark notes.",
                  compareAgainst: ["PlanExecuteLoop", "FleetPlanner", "tool traces", "runtime state"],
                  researchQuestion: "What planner/runtime state should Kist make explicit before adding more autonomy?",
                  reason: "Open planner/runtime source gives concrete comparison points for multi-step execution.",
                  likelyKistGap: "Kist has planning and gates, but strategic planning evidence is spread across reports, tasks, and traces.",
                  expectedImpact: 4,
                  benchmarkPlan: "Run a multi-step task eval that requires replan, failed tool recovery, and final proof.",
                  proposedEvolution: "Unify planner, runtime, and evidence state into a single inspectable Captain run record."),
            .init(id: "anthropic-mcp-lifecycle",
                  title: "Anthropic MCP lifecycle and permission model",
                  category: .standard,
                  priority: .medium,
                  sourceTarget: "Official MCP specification, SDK docs, server examples, and changelog.",
                  compareAgainst: ["MCP startup", "stderr handling", "tool contract", "permissions", "server health"],
                  researchQuestion: "What MCP lifecycle guarantees should Kist enforce instead of merely logging?",
                  reason: "Tool lifecycle drift directly affects reliability and trust.",
                  likelyKistGap: "Kist gates noisy MCP stderr, but server health and permission drift should become structured evidence.",
                  expectedImpact: 4,
                  benchmarkPlan: "Add MCP lifecycle evals for EOF, noisy stderr, invalid tool schema, permission mismatch, and recovery.",
                  proposedEvolution: "Promote MCP server health into Strategic Intelligence and proof logs."),
            .init(id: "apple-foundation-models",
                  title: "Apple Foundation Models and local reasoning roadmap",
                  category: .platform,
                  priority: .medium,
                  sourceTarget: "Apple developer docs, Foundation Models framework notes, WWDC sessions, and on-device AI guidance.",
                  compareAgainst: ["cloud model routing", "local fallback", "privacy", "latency", "offline mode"],
                  researchQuestion: "Which Captain tasks can move local without degrading reasoning or evidence quality?",
                  reason: "Local reasoning may change Kist's latency, privacy, and offline orchestration assumptions.",
                  likelyKistGap: "Kist routes across cloud/local providers, but does not yet have a strategic local-first policy.",
                  expectedImpact: 4,
                  benchmarkPlan: "Create local-vs-cloud evals for routing, summarization, retrieval, and low-risk tool planning.",
                  proposedEvolution: "Add a local/offline reasoning tier with explicit confidence gates."),
            .init(id: "dgm-self-improvement",
                  title: "DGM self-improvement architecture",
                  category: .paper,
                  priority: .medium,
                  sourceTarget: "DGM paper, code, benchmark methodology, and follow-up discussion.",
                  compareAgainst: ["--evolve lab", "candidate archive", "promotion gates", "benchmark learning"],
                  researchQuestion: "How can Kist self-improve without rewarding benchmark gaming or unsafe autonomy?",
                  reason: "Self-improvement must be measured, isolated, and promotion-gated.",
                  likelyKistGap: "Kist has isolated evolution candidates, but Strategic Intelligence should decide what to evolve before coding candidates.",
                  expectedImpact: 5,
                  benchmarkPlan: "Require candidate proposals to include a benchmark, anti-cheat proof, and rollback path.",
                  proposedEvolution: "Make /evolve produce evidence-backed proposals before launching candidate branches."),
            .init(id: "swe-bench-live-evals",
                  title: "SWE-bench style live eval methodology",
                  category: .benchmark,
                  priority: .medium,
                  sourceTarget: "SWE-bench papers, live eval harnesses, and public benchmark methodology.",
                  compareAgainst: ["CaptainLearningStore", "/bench", "/eval", "model assignment"],
                  researchQuestion: "What makes Captain's live eval samples strong enough to steer model assignment?",
                  reason: "Sparse benchmark samples should remain shadow evidence until repeated wins prove generality.",
                  likelyKistGap: "Kist records learning samples, but eval coverage may not map to each role and task type.",
                  expectedImpact: 5,
                  benchmarkPlan: "Track task family, language, tool failures, judge score, latency, and promotion confidence per provider-role.",
                  proposedEvolution: "Require role-assignment changes to cite promoted learning evidence.")
        ]
    }

    private static func evolutionProposals(targets: [StrategicIntelligenceTarget],
                                           learning: [CaptainLearningSummary],
                                           orchestration: Bool,
                                           learningLoop: Bool,
                                           toolLifecycle: Bool,
                                           localReasoning: Bool) -> [StrategicEvolutionProposal] {
        var proposals: [StrategicEvolutionProposal] = [
            .init(id: "proposal-strategic-intelligence-cadence",
                  title: "Create a recurring Strategic Intelligence cadence",
                  reason: "Captain should watch competitors, standards, papers, and benchmark movement before declaring the roadmap stable.",
                  expectedImpact: 5,
                  evidenceNeeded: ["source scan notes", "comparison matrix", "affected Kist subsystem", "benchmark or eval plan"],
                  benchmarkPlan: "Run /evolve weekly and assert it writes industry intelligence, research tasks, and at least one teachable proposal.",
                  teachableRule: "Strategic Intelligence must compare Kist against current competitors, standards, papers, and benchmarks before major platform evolution."),
            .init(id: "proposal-evidence-linked-research-archive",
                  title: "Link every knowledge-debt item to evidence",
                  reason: "Knowledge debt should close only when source notes, comparison, and impact decision are archived.",
                  expectedImpact: 5,
                  evidenceNeeded: ["research archive entry", "source targets visited", "decision summary", "closed knowledge-debt id"],
                  benchmarkPlan: "Add an eval that refuses to close high-impact knowledge debt without an archive record.",
                  teachableRule: "High-impact knowledge debt is not paid until the research archive contains evidence and a roadmap decision.")
        ]

        if orchestration {
            proposals.append(.init(
                id: "proposal-delegation-decision-cards",
                title: "Make delegation decision cards mandatory",
                reason: "Users need to see why Captain assigned a model or specialist before workers start changing code.",
                expectedImpact: 5,
                evidenceNeeded: targets.prefix(4).map(\.title),
                benchmarkPlan: "Evaluate a fleet task for visible intent, confidence, model reason, cost estimate, and non-overlap proof.",
                teachableRule: "Every multi-agent launch must include an inspectable delegation decision card before execution."))
        }
        if learningLoop || learning.contains(where: { $0.promoted }) {
            proposals.append(.init(
                id: "proposal-benchmark-gated-assignment",
                title: "Benchmark-gated model assignment",
                reason: "Captain should assign workers from measured role evidence, not preference or model popularity.",
                expectedImpact: 5,
                evidenceNeeded: ["promoted CaptainLearningSummary", "shadow evidence kept separate", "regression eval result"],
                benchmarkPlan: "Require at least three successful role/task samples before assignment policy changes.",
                teachableRule: "Model assignment changes require promoted benchmark or live-eval evidence, with shadow evidence shown but not trusted."))
        }
        if toolLifecycle {
            proposals.append(.init(
                id: "proposal-tool-lifecycle-health",
                title: "Promote tool lifecycle health into Strategic Intelligence",
                reason: "MCP, browser, sandbox, and permission drift can break trust even when code compiles.",
                expectedImpact: 4,
                evidenceNeeded: ["MCP health checks", "permission contract", "tool schema drift report"],
                benchmarkPlan: "Run lifecycle evals for noisy stderr, EOF, schema drift, and permission mismatch.",
                teachableRule: "Tool lifecycle drift is product risk and must be tracked as Strategic Intelligence, not incidental logs."))
        }
        if localReasoning {
            proposals.append(.init(
                id: "proposal-local-reasoning-tier",
                title: "Create a local/offline reasoning tier",
                reason: "Local models can reduce latency and improve privacy, but only if confidence gates prevent weak reasoning from taking high-risk work.",
                expectedImpact: 4,
                evidenceNeeded: ["local-vs-cloud benchmark", "task class", "confidence threshold", "fallback rule"],
                benchmarkPlan: "Compare local and cloud providers on retrieval, summarization, low-risk planning, and code-review tasks.",
                teachableRule: "Local reasoning may handle low-risk work only when benchmarks prove the task class and fallback path."))
        }
        return Array(dedupe(proposals).sorted {
            if $0.expectedImpact != $1.expectedImpact { return $0.expectedImpact > $1.expectedImpact }
            return $0.title < $1.title
        }.prefix(6))
    }

    private static func promote(_ ids: [String], in targets: inout [StrategicIntelligenceTarget]) {
        let wanted = Set(ids)
        for idx in targets.indices where wanted.contains(targets[idx].id) {
            targets[idx].priority = .high
            targets[idx].expectedImpact = max(targets[idx].expectedImpact, 5)
        }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func dedupe(_ targets: [StrategicIntelligenceTarget]) -> [StrategicIntelligenceTarget] {
        var seen = Set<String>()
        var out: [StrategicIntelligenceTarget] = []
        for target in targets where !seen.contains(target.id) {
            seen.insert(target.id)
            out.append(target)
        }
        return out
    }

    private static func dedupe(_ proposals: [StrategicEvolutionProposal]) -> [StrategicEvolutionProposal] {
        var seen = Set<String>()
        var out: [StrategicEvolutionProposal] = []
        for proposal in proposals where !seen.contains(proposal.id) {
            seen.insert(proposal.id)
            out.append(proposal)
        }
        return out
    }

    private static func slug(_ text: String) -> String {
        let chars = text.lowercased().map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "-"
        }
        let collapsed = String(chars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "item" : collapsed
    }
}
