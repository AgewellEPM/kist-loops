import Foundation
import AgentCore

struct LearningCapsule: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case pass = "PASS", fail = "FAIL" }

    var id: String
    var taskTitle: String
    var status: Status
    var summary: String
    var learned: [String]
    var surprises: [String]
    var slowdowns: [String]
    var assumptionsToChallenge: [String]
    var futureEvolution: String
    var tokenCount: Int
    var at: Double
}

struct KnowledgeDebtRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case open, done }
    enum Priority: String, Codable, Equatable, Sendable { case high, medium }

    var id: String
    var topic: String
    var reason: String
    var visit: String
    var impact: Int
    var priority: Priority
    var estimatedLearning: String
    var expectedBenefit: [String]
    var sourceCapsuleID: String?
    var status: Status
    var createdAt: Double
    var updatedAt: Double
}

struct OrganizationalRuleRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Equatable, Sendable { case active, proposed, retired }

    var id: String
    var lesson: String
    var confidence: Int
    var reason: String
    var evidence: [String]
    var sourceCapsuleID: String?
    var status: Status
    var createdAt: Double
    var updatedAt: Double
}

struct OrganizationalRulePromotionDecision: Equatable, Sendable {
    var accepted: Bool
    var blockers: [String]
    var verifiedEvidenceCount: Int
}

private struct DiskMemoryRecord: Codable, Equatable, Sendable {
    var id: String?
    var title: String?
    var summary: String?
    var body: String?
    var source: String?
    var confidence: Int?
    var impact: Int?
    var tags: [String]?
}

struct LearningEvidenceRecord: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case selfHealSpecialist = "self-heal-specialist"
        case domainLearningSpecialist = "domain-learning-specialist"
    }

    var id: String
    var kind: Kind
    var objective: String
    var specialistName: String
    var role: String
    var preferredModel: String
    var artifactPath: String
    var memoryRecorded: Bool
    var taskIDs: [Int]
    var taskEvidenceUpdated: Int
    var createdAt: Double
}

struct EvolutionBoardReport: Equatable, Sendable {
    var path: String
    var text: String
    var seededResearchTasks: Int
    var createdSpecialists: Int
    var promotedRules: Int
}

struct SelfHealAgentAssignment: Equatable, Sendable, Codable {
    var specialistName: String
    var role: String
    var preferredModel: String
    var task: String
}

struct SelfHealMissionReport: Equatable, Sendable {
    var path: String
    var text: String
    var boardMeetingPath: String
    var seededTasks: Int
    var createdSpecialists: Int
    var promotedRules: Int
    var agentAssignments: [SelfHealAgentAssignment]
    var dispatchCommand: String
    var writeSucceeded: Bool
    var writeError: String?
}

struct SelfHealSpecialistArtifact: Equatable, Sendable {
    var path: String
    var memoryRecorded: Bool
    var taskEvidenceUpdated: Int
    var updatedTaskIDs: [Int]
    var evidenceLedgerRecorded: Bool
}

struct DomainLearningAssignment: Equatable, Sendable, Codable {
    var specialistName: String
    var role: String
    var preferredModel: String
    var task: String
}

struct DomainLearningReport: Equatable, Sendable {
    var path: String
    var text: String
    var objective: String
    var understandingConfidence: Int
    var confidenceThreshold: Int
    var canExecute: Bool
    var seededTasks: Int
    var knowledgeDebtCreated: Int
    var createdSpecialists: Int
    var memoryRecords: Int
    var agentAssignments: [DomainLearningAssignment]
    var dispatchCommand: String
    var writeSucceeded: Bool
    var writeError: String?
}

struct DomainLearningSpecialistArtifact: Equatable, Sendable {
    var path: String
    var memoryRecorded: Bool
    var taskEvidenceUpdated: Int
    var updatedTaskIDs: [Int]
    var evidenceLedgerRecorded: Bool
}

struct OrganizationalLearningStore: Sendable {
    let projectRoot: String
    private let now: @Sendable () -> Date
    private let makeSpecialistRegistry: @Sendable (String) -> SpecialistRegistry

    init(projectRoot: String,
         now: @escaping @Sendable () -> Date = { Date() },
         specialistRegistry: @escaping @Sendable (String) -> SpecialistRegistry = { SpecialistRegistry(projectRoot: $0) }) {
        self.projectRoot = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.now = now
        self.makeSpecialistRegistry = specialistRegistry
    }

    var learningRoot: String { projectRoot + "/.kist/learning" }
    var capsulesPath: String { learningRoot + "/capsules.jsonl" }
    var knowledgeIndexPath: String { learningRoot + "/knowledge-index.jsonl" }
    var debtPath: String { learningRoot + "/knowledge-debt.jsonl" }
    var rulesPath: String { learningRoot + "/organizational-rules.jsonl" }
    var researchArchiveRoot: String { learningRoot + "/research-archive" }
    var industryIntelligencePath: String { learningRoot + "/industry-intelligence.jsonl" }
    var benchmarksPath: String { learningRoot + "/benchmarks.jsonl" }
    var evolutionProposalsPath: String { learningRoot + "/evolution-proposals.jsonl" }
    var evidenceLedgerPath: String { learningRoot + "/evidence-ledger.jsonl" }
    var boardMeetingsRoot: String { learningRoot + "/board-meetings" }
    var selfHealRoot: String { learningRoot + "/self-heal" }
    var localModelsRoot: String { learningRoot + "/local-models" }
    var simulationsRoot: String { learningRoot + "/simulations" }

    @discardableResult
    func recordTurn(plan: Plan, spans: [AgentSpan], trajectory: [ActionRecord],
                    outcomeSummary: String, success: Bool,
                    insights: DashboardInsightBundle? = nil) -> LearningCapsule {
        let bundle = insights ?? DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                                trajectory: trajectory)
        let capsule = makeCapsule(plan: plan, spans: spans, trajectory: trajectory,
                                  outcomeSummary: outcomeSummary, success: success)
        appendJSON(capsule, to: capsulesPath)
        for item in bundle.research {
            upsertKnowledgeDebt(from: item, sourceCapsuleID: capsule.id)
        }
        return capsule
    }

    func latestCapsule() -> LearningCapsule? {
        loadJSONL(LearningCapsule.self, path: capsulesPath).last
    }

    func capsules(limit: Int = 20) -> [LearningCapsule] {
        Array(loadJSONL(LearningCapsule.self, path: capsulesPath).suffix(max(0, limit)))
    }

    func evidenceLedger(limit: Int = 40) -> [LearningEvidenceRecord] {
        Array(loadJSONL(LearningEvidenceRecord.self, path: evidenceLedgerPath).suffix(max(0, limit)))
    }

    func openKnowledgeDebt(limit: Int = 20) -> [KnowledgeDebtRecord] {
        let records = loadJSONL(KnowledgeDebtRecord.self, path: debtPath)
            .filter { $0.status == .open }
            .sorted {
                if $0.impact != $1.impact { return $0.impact > $1.impact }
                return $0.updatedAt > $1.updatedAt
            }
        return Array(records.prefix(max(0, limit)))
    }

    func permanentRules(limit: Int = 20) -> [OrganizationalRuleRecord] {
        let records = loadJSONL(OrganizationalRuleRecord.self, path: rulesPath)
            .filter { $0.status == .active }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.updatedAt > $1.updatedAt
            }
        return Array(records.prefix(max(0, limit)))
    }

    func proposedRules(limit: Int = 20) -> [OrganizationalRuleRecord] {
        let records = loadJSONL(OrganizationalRuleRecord.self, path: rulesPath)
            .filter { $0.status == .proposed }
            .sorted {
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.updatedAt > $1.updatedAt
            }
        return Array(records.prefix(max(0, limit)))
    }

    @discardableResult
    func addKnowledgeDebt(topic: String, reason: String = "", visit: String = "",
                          impact: Int = 3, priority: KnowledgeDebtRecord.Priority = .medium,
                          estimatedLearning: String = "",
                          expectedBenefit: [String] = []) -> KnowledgeDebtRecord {
        let nowValue = now().timeIntervalSince1970
        let record = KnowledgeDebtRecord(
            id: Self.debtID(topic),
            topic: Self.safe(topic),
            reason: Self.safe(reason.isEmpty ? "Manual knowledge debt entry." : reason),
            visit: Self.safe(visit.isEmpty ? "Primary docs, source, papers, and competitor notes" : visit),
            impact: min(5, max(1, impact)),
            priority: priority,
            estimatedLearning: Self.safe(estimatedLearning.isEmpty ? "1-2 hours" : estimatedLearning),
            expectedBenefit: expectedBenefit.isEmpty ? ["improve roadmap quality"] : expectedBenefit.map(Self.safe),
            sourceCapsuleID: nil,
            status: .open,
            createdAt: nowValue,
            updatedAt: nowValue
        )
        upsert(record)
        return record
    }

    @discardableResult
    func markKnowledgeDebtDone(_ rawID: String) -> Bool {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        var records = loadJSONL(KnowledgeDebtRecord.self, path: debtPath)
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return false }
        records[idx].status = .done
        records[idx].updatedAt = now().timeIntervalSince1970
        saveJSONL(records, to: debtPath)
        return true
    }

    @discardableResult
    func promoteOrganizationalRule(lesson: String, confidence: Int = 90, reason: String = "",
                                   evidence: [String] = [], sourceCapsuleID: String? = nil) -> OrganizationalRuleRecord {
        let nowValue = now().timeIntervalSince1970
        let cleanLesson = Self.safe(lesson)
        let cleanReason = Self.safe(reason.isEmpty ? "Promoted by Teach Captain." : reason)
        let cleanEvidence = evidence.map(Self.safe)
        let decision = organizationalRulePromotionDecision(lesson: cleanLesson,
                                                           confidence: confidence,
                                                           evidence: cleanEvidence)
        let status: OrganizationalRuleRecord.Status = decision.accepted ? .active : .proposed
        let finalReason = decision.accepted
            ? cleanReason
            : Self.safe(cleanReason + " Promotion blocked: " + decision.blockers.joined(separator: "; "))
        let record = OrganizationalRuleRecord(
            id: Self.ruleID(cleanLesson),
            lesson: cleanLesson,
            confidence: min(100, max(1, confidence)),
            reason: finalReason,
            evidence: cleanEvidence,
            sourceCapsuleID: sourceCapsuleID,
            status: status,
            createdAt: nowValue,
            updatedAt: nowValue
        )
        upsert(record)
        if status == .proposed {
            addKnowledgeDebt(topic: "Prove organizational rule: \(cleanLesson)",
                             reason: "Captain proposed this rule, but it lacks enough verified evidence to become permanent. Blockers: \(decision.blockers.joined(separator: "; "))",
                             visit: "Run benchmark/live-eval/research proof, attach reports, then re-run /teach with evidence.",
                             impact: 4,
                             priority: .high,
                             estimatedLearning: "1-2 hours",
                             expectedBenefit: ["prevent unverified lessons from becoming operating policy"])
        }
        return record
    }

    func organizationalRulePromotionDecision(lesson: String,
                                             confidence: Int,
                                             evidence: [String]) -> OrganizationalRulePromotionDecision {
        var blockers: [String] = []
        let cleanLesson = lesson.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanLesson.count < 12 {
            blockers.append("lesson is too short to become an operating rule")
        }
        if confidence < 95 {
            blockers.append("confidence must be at least 95 for permanent rules")
        }
        if evidence.count < 2 {
            blockers.append("at least two evidence items are required")
        }
        let verifiedCount = evidence.filter { isVerifiedOrganizationalRuleEvidence($0) }.count
        if verifiedCount < 2 {
            blockers.append("at least two verified evidence items are required")
        }
        return OrganizationalRulePromotionDecision(accepted: blockers.isEmpty,
                                                   blockers: Self.unique(blockers),
                                                   verifiedEvidenceCount: verifiedCount)
    }

    private func isVerifiedOrganizationalRuleEvidence(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        guard !value.isEmpty else { return false }
        let weakSignals = [
            "evidence needed", "benchmark plan", "expected roi", "expected impact",
            "proposed evolution", "teachable rule", "agenda", "hypothesis"
        ]
        if weakSignals.contains(where: { lower.contains($0) }) {
            return false
        }

        if lower.contains("tests") || lower.contains("swift test") || lower.contains("xcodebuild") {
            return lower.contains("pass") || lower.contains("0 failures") || lower.contains("succeeded")
        }
        if lower.contains("benchmark") || lower.contains("benchmarks:") || lower.contains("live-eval") || lower.contains("eval:") {
            return lower.contains("pass") || lower.contains("win") || lower.contains("score") ||
                lower.contains("improv") || lower.contains("regress") || lower.contains("latency") ||
                lower.contains("verified")
        }
        if lower.contains("verified") || lower.contains("independent review") {
            return true
        }
        if lower.contains(".kist/learning/research-archive/") || lower.contains(".kist/learning/benchmarks") {
            return true
        }
        if lower.hasPrefix("report:") || lower.hasPrefix("artifact:") || lower.hasPrefix("source:") {
            return true
        }

        let pathCandidates = value.split(whereSeparator: { $0 == " " || $0 == ";" || $0 == "," })
            .map(String.init)
            .filter { $0.hasPrefix(".kist/") || $0.hasPrefix("/") }
        for path in pathCandidates {
            let resolved = path.hasPrefix("/")
                ? path
                : (projectRoot as NSString).appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: resolved) {
                return true
            }
        }
        return false
    }

    func renderKnowledgeDebt(limit: Int = 12) -> String {
        let records = openKnowledgeDebt(limit: limit)
        guard !records.isEmpty else {
            return "Knowledge Debt\n\nNo open knowledge debt yet. Run a task, /reflect, or `/knowledge add <topic>`."
        }
        var lines = ["Knowledge Debt", ""]
        for item in records {
            lines += [
                "\(stars(item.impact)) \(item.id)",
                "Need to research: \(item.topic)",
                "Reason: \(item.reason)",
                "Visit: \(item.visit)",
                "Expected benefit: \(item.expectedBenefit.joined(separator: "; "))",
                ""
            ]
        }
        lines.append("Use `/knowledge done <id>` when the debt has been paid down.")
        return lines.joined(separator: "\n")
    }

    func renderOrganizationalRules(limit: Int = 12) -> String {
        let records = permanentRules(limit: limit)
        var lines = ["Teach Captain", "", "Permanent Organizational Rules", ""]
        if records.isEmpty {
            lines.append("No permanent organizational rules yet. Weak lessons stay proposed until evidence clears the promotion gate.")
            lines.append("")
        } else {
            for rule in records {
                lines += [
                    "\(rule.id)  confidence \(rule.confidence)%",
                    "Lesson: \(rule.lesson)",
                    "Reason: \(rule.reason)",
                ]
                if !rule.evidence.isEmpty {
                    lines.append("Evidence: \(rule.evidence.joined(separator: "; "))")
                }
                lines.append("")
            }
        }

        let proposed = proposedRules(limit: limit)
        if !proposed.isEmpty {
            lines += ["", "Proposed Rules Awaiting Evidence", ""]
            for rule in proposed {
                let decision = organizationalRulePromotionDecision(lesson: rule.lesson,
                                                                   confidence: rule.confidence,
                                                                   evidence: rule.evidence)
                lines += [
                    "\(rule.id)  confidence \(rule.confidence)%  status proposed",
                    "Lesson: \(rule.lesson)",
                    "Blockers: \(decision.blockers.joined(separator: "; "))",
                ]
                if !rule.evidence.isEmpty {
                    lines.append("Evidence: \(rule.evidence.joined(separator: "; "))")
                }
                lines.append("")
            }
        }
        lines.append("Use `/teach add <lesson> | confidence: 97 | reason: ... | evidence: tests passed; benchmark: passed` to promote a rule.")
        return lines.joined(separator: "\n")
    }

    func renderCaptainMemoryArchitecture() -> String {
        let locations: [CaptainMemoryLayerID: String] = [
            .contextWindow: "current model context",
            .knowledgeIndex: Self.projectRelative(knowledgeIndexPath, root: projectRoot),
            .organizationalRules: Self.projectRelative(rulesPath, root: projectRoot),
            .researchArchive: Self.projectRelative(researchArchiveRoot, root: projectRoot),
            .industryIntelligence: Self.projectRelative(industryIntelligencePath, root: projectRoot),
            .benchmarks: Self.projectRelative(benchmarksPath, root: projectRoot),
            .projectHistory: Self.projectRelative(capsulesPath, root: projectRoot),
        ]
        var lines = [
            "Captain Memory Architecture",
            "Context Window is RAM. Everything else is disk.",
            "Retrieval policy: load only relevant records into working memory for the current objective.",
            ""
        ]
        for layer in CaptainMemoryArchitecture.default.layers {
            lines += [
                "\(layer.title) [\(layer.medium.rawValue)]",
                "Role: \(layer.role)",
                "Store: \(locations[layer.id] ?? layer.location)",
                "Retrieval: \(layer.retrievalPolicy)",
                ""
            ]
        }
        return lines.joined(separator: "\n")
    }

    func renderCaptainLearning(limit: Int = 16) -> String {
        let store = CaptainLearningStore(projectRoot: projectRoot)
        let samples = store.load()
        guard !samples.isEmpty else {
            return """
            Captain Learning

            No benchmark or live-eval samples yet.
            Run `/bench <task>` or `/eval <task>` to create shadow evidence. Captain promotes evidence only after repeated verified wins.
            """
        }

        let assignment = store.assignmentContext()
        let summaries = captainLearningRetrievalSummaries()
        let promoted = summaries.filter(\.promoted)
        let shadow = summaries.filter { !$0.promoted }
        var lines = [
            "Captain Learning",
            "",
            "Source: \(CaptainLearningStore.relativePath)",
            "Samples: \(samples.count)",
            "Assignment status: \(assignment.statusLine)",
            "",
            "Promotion gate",
            "- at least 3 samples",
            "- success rate >= 67%",
            "- tool failures <= max(1, samples / 2)",
            "",
            "Promoted Evidence",
        ]
        if promoted.isEmpty {
            lines.append("- none yet")
        } else {
            lines += promoted.prefix(max(0, limit)).map(renderLearningSummary)
        }
        lines += ["", "Shadow Evidence"]
        if shadow.isEmpty {
            lines.append("- none")
        } else {
            lines += shadow.prefix(max(0, limit)).map(renderLearningSummary)
        }
        lines += [
            "",
            "How Captain uses this",
            "- promoted evidence can bias fleet role assignment and appears in benchmark retrieval memory",
            "- shadow evidence is visible but not trusted enough to steer policy",
            "- every new /bench or /eval sample can move a provider/role toward or away from promotion",
        ]
        return lines.joined(separator: "\n")
    }

    func renderStrategicIntelligence(limit: Int = 12) -> String {
        let intelligence = loadJSONL(DiskMemoryRecord.self, path: industryIntelligencePath)
        let proposals = loadJSONL(DiskMemoryRecord.self, path: evolutionProposalsPath)
        guard !intelligence.isEmpty || !proposals.isEmpty else {
            return """
            Strategic Intelligence

            No industry intelligence records yet.
            Run `/evolve` to create a competitor, paper, standards, and benchmark comparison agenda.
            """
        }

        var lines = [
            "Strategic Intelligence",
            "",
            "Source: \(Self.projectRelative(industryIntelligencePath, root: projectRoot))",
            "Evolution proposals: \(Self.projectRelative(evolutionProposalsPath, root: projectRoot))",
            "",
            "Industry Radar",
        ]
        for item in intelligence.suffix(max(0, limit)).reversed() {
            lines += [
                "- \(item.title ?? item.id ?? "industry item")",
                "  \(item.summary ?? item.body ?? "")",
            ]
            if let body = item.body, body != item.summary, !body.isEmpty {
                lines.append("  \(body.replacingOccurrences(of: "\n", with: "\n  "))")
            }
            if let source = item.source, !source.isEmpty {
                lines.append("  Source target: \(source)")
            }
            if let impact = item.impact {
                lines.append("  Impact: \(stars(impact))")
            }
        }
        lines += ["", "Evolution Proposals"]
        for proposal in proposals.suffix(max(0, limit)).reversed() {
            lines += [
                "- \(proposal.title ?? proposal.id ?? "proposal")",
                "  \(proposal.summary ?? proposal.body ?? "")",
            ]
            if let body = proposal.body, body != proposal.summary, !body.isEmpty {
                lines.append("  \(body.replacingOccurrences(of: "\n", with: "\n  "))")
            }
            if let impact = proposal.impact {
                lines.append("  Impact: \(stars(impact))")
            }
        }
        lines += [
            "",
            "Use `/evolve` to refresh the radar, seed research tasks, and promote one high-confidence organizational rule."
        ]
        return lines.joined(separator: "\n")
    }

    func retrievalContext(objective: String,
                          strategy: CaptainStrategyPlan,
                          limit: Int = 8) -> CaptainRetrievalContext {
        ensureMemoryArchitecture()
        let candidates = memoryCandidates()
        let retrieved = CaptainRetrievalRanker.retrieve(objective: objective,
                                                        candidates: candidates,
                                                        limit: limit)
        let cards = CaptainDecisionCards.build(objective: objective,
                                               retrieval: retrieved,
                                               strategy: strategy)
        return CaptainRetrievalContext(objective: objective,
                                       retrieved: retrieved,
                                       decisionCards: cards)
    }

    func renderLatestReflection() -> String {
        guard let capsule = latestCapsule() else {
            return "No learning capsule yet. Run a task or `/reflect now` to create one."
        }
        return Self.render(capsule)
    }

    func makeManualReflection(plan: Plan, spans: [AgentSpan], trajectory: [ActionRecord]) -> LearningCapsule {
        recordTurn(plan: plan, spans: spans, trajectory: trajectory,
                   outcomeSummary: "Manual reflection over the current project board.",
                   success: true)
    }

    func runBoardMeeting(plan: Plan, trajectory: [ActionRecord]) -> EvolutionBoardReport {
        let insights = DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                       trajectory: trajectory, limit: 6)
        let debts = openKnowledgeDebt(limit: 8)
        let latest = latestCapsule()
        let timestamp = Int(now().timeIntervalSince1970)
        let path = boardMeetingsRoot + "/\(timestamp)-evolve.md"
        ensureMemoryArchitecture()
        let strategy = CaptainStrategist.plan(objective: strategyObjective(plan: plan),
                                              evidence: CaptainProjectEvidence.capture(projectRoot: projectRoot),
                                              specialists: makeSpecialistRegistry(projectRoot).load())
        let intelligence = StrategicIntelligencePlanner.build(
            objective: strategy.objective,
            strategy: strategy,
            debts: debts,
            insights: insights,
            learning: captainLearningRetrievalSummaries(),
            generatedAt: now().timeIntervalSince1970)
        let strategicResearch = strategicResearchItems(from: intelligence)
        let combinedInsights = DashboardInsightBundle(
            research: mergeResearch(strategicResearch + insights.research),
            knowledgeDebt: insights.knowledgeDebt,
            questions: insights.questions,
            observation: insights.observation)
        let seeded = seedResearchTasks(plan: plan, insights: combinedInsights)
        let strategicRecords = recordStrategicIntelligence(intelligence)
        let retrieval = retrievalContext(objective: strategy.objective, strategy: strategy)
        let createdSpecialists = createMissingSpecialists(strategy.missingSpecialists)
        let existingRuleIDs = Set(permanentRules(limit: Int.max).map(\.id))
        let taughtRule = teachCaptain(plan: plan, latest: latest, strategy: strategy,
                                      intelligence: intelligence)
        let taughtNew = taughtRule.status == .active && !existingRuleIDs.contains(taughtRule.id)
        let promotedStrategicRules = promoteStrategicProposalRules(
            intelligence,
            existingRuleIDs: existingRuleIDs.union([taughtRule.id]))
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
        lines += [
            "",
            "## Teach Captain",
            "Question: What organizational lesson should become permanent?",
            "\(taughtRule.status == .active ? "Promoted" : "Proposed") rule: \(taughtRule.id)",
            "Lesson: \(taughtRule.lesson)",
            "Confidence: \(taughtRule.confidence)%",
            "Status: \(taughtRule.status.rawValue)",
            "Reason: \(taughtRule.reason)",
        ]
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

    func runSelfHealMission(plan: Plan, trajectory: [ActionRecord],
                            objective: String = "") -> SelfHealMissionReport {
        let cleanObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let missionObjective = cleanObjective.isEmpty
            ? "Captain self-heal: convert observations into assigned research, build, review, benchmark, and Teach Captain gates."
            : cleanObjective
        let boardMeeting = runBoardMeeting(plan: plan, trajectory: trajectory)
        let currentPlan = PlanStore(projectRoot: projectRoot).load()
        let insights = DashboardResearchPlanner.build(for: currentPlan, projectRoot: projectRoot,
                                                       trajectory: trajectory, limit: 6)
        let weakness = selfHealWeakness(insights: insights,
                                        debts: openKnowledgeDebt(limit: 6),
                                        latest: latestCapsule())
        let assignments = selfHealAssignments(weakness: weakness, objective: missionObjective)
        let createdSpecialists = createSelfHealSpecialists(assignments: assignments)
        let seededTasks = seedSelfHealTasks(weakness: weakness,
                                            objective: missionObjective,
                                            assignments: assignments,
                                            boardMeetingPath: boardMeeting.path)

        let timestamp = Int(now().timeIntervalSince1970)
        let path = selfHealRoot + "/\(timestamp)-self-heal.md"
        let dispatchCommand = "/self-heal run"
        var text = renderSelfHealMission(objective: missionObjective,
                                          weakness: weakness,
                                          assignments: assignments,
                                          boardMeeting: boardMeeting,
                                          seededTasks: seededTasks,
                                          createdSpecialists: createdSpecialists,
                                          dispatchCommand: dispatchCommand)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: selfHealRoot, withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
            text += [
                "",
                "## Evidence Persistence",
                "Status: FAILED",
                "Error: \(Self.safe(writeError ?? "unknown error"))",
                "Dispatch gate: HOLD; self-heal agents cannot run until the mission report is durably written."
            ].joined(separator: "\n")
        }
        return SelfHealMissionReport(path: Self.projectRelative(path, root: projectRoot),
                                     text: text,
                                     boardMeetingPath: boardMeeting.path,
                                     seededTasks: seededTasks,
                                     createdSpecialists: createdSpecialists,
                                     promotedRules: boardMeeting.promotedRules,
                                     agentAssignments: assignments,
                                     dispatchCommand: dispatchCommand,
                                     writeSucceeded: writeSucceeded,
                                     writeError: writeError)
    }

    func runSimulationGate(plan: Plan, trajectory: [ActionRecord],
                           objective: String = "",
                           artifactObjective: String? = nil,
                           measuredTrialMode: CaptainSimulationMeasuredTrialMode = .preflight,
                           judgedTrialMode: CaptainSimulationMeasuredTrialMode = .interactive,
                           persist: Bool = true) -> CaptainSimulationGateReport {
        let evidence = CaptainProjectEvidence.capture(projectRoot: projectRoot)
        var draftRun = CaptainSimulationLab.build(objective: objective,
                                                  artifactObjective: artifactObjective,
                                                  plan: plan,
                                                  evidence: evidence,
                                                  generatedAt: now())
        // How coverage is JUDGED (full interactive suite vs preflight's own trials) — set before
        // any verdict is computed; attachingMeasuredTrials copies it forward on the run value.
        draftRun.judgedTrialMode = judgedTrialMode
        // NO-WRITE path (`--no-memory`, persist == false): compute + enforce the gate DECISION from the pure
        // `draftRun`, but WRITE nothing and RUN no measured trials. Measured trials call simulationEnvironment(),
        // which durably creates `.kist/simulation-{home,tmp}` under the project — so they MUST be skipped here or
        // --no-memory leaks disk state (caught by Codex, 2026-07-03). ensureMemoryArchitecture() also creates
        // durable dirs, so the guard precedes it too. The read above (CaptainProjectEvidence.capture) is a
        // read-only git/tree scan needed for the verdict; --no-memory suppresses PERSISTENCE + durable side
        // effects, not the reads/heuristics that inform the safety verdict. persistenceRequired:false tells the
        // enforcer NOT to fail-closed on the (intentional) absence of a write; the decision string is
        // contaminated so no human/log mistakes an unpersisted pass for a fully-vetted, recorded one.
        guard persist else {
            let text = CaptainSimulationLab.render(draftRun, reportPath: "",
                                                   seededTasks: 0, createdSpecialists: 0, benchmarkRecords: 0)
            return CaptainSimulationGateReport(path: "", text: text,
                                               objective: draftRun.objective, domainTitle: draftRun.domain.title,
                                               recommendedStrategy: draftRun.recommendedStrategy.name,
                                               decision: "[NON-PERSISTENT] " + draftRun.decision,
                                               acceptanceThreshold: draftRun.acceptanceThreshold,
                                               estimatedSuccess: draftRun.estimatedSuccess,
                                               failureRisk: draftRun.failureRisk,
                                               seededTasks: 0, createdSpecialists: 0, benchmarkRecords: 0,
                                               writeSucceeded: false, writeError: nil,
                                               persistenceRequired: false)
        }
        ensureMemoryArchitecture()
        let measuredTrials = runMeasuredSimulationTrials(run: draftRun,
                                                         evidence: evidence,
                                                         mode: measuredTrialMode)
        let run = CaptainSimulationLab.attachingMeasuredTrials(measuredTrials, to: draftRun)
        let path = simulationsRoot + "/\(run.id)-simulation.md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let createdSpecialists = createSimulationSpecialists()
        let seededTasks = seedSimulationTasks(run: run, reportPath: relativePath)
        var benchmarkRecords = 0
        let persistenceFailureDecision = "HOLD EXECUTION; simulation evidence report could not be persisted."
        var text = CaptainSimulationLab.render(run,
                                               reportPath: relativePath,
                                               seededTasks: seededTasks,
                                               createdSpecialists: createdSpecialists,
                                               benchmarkRecords: benchmarkRecords)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: simulationsRoot, withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
            text = text.replacingOccurrences(of: "Decision: \(run.decision)",
                                             with: "Decision: \(persistenceFailureDecision)")
            text += [
                "",
                "## Evidence Persistence",
                "Status: FAILED",
                "Error: \(Self.safe(writeError ?? "unknown error"))",
                "Execution gate: \(persistenceFailureDecision)"
            ].joined(separator: "\n")
        }
        if writeSucceeded && run.passesGate {
            benchmarkRecords = recordSimulationBenchmark(run: run,
                                                         reportPath: relativePath,
                                                         trajectory: trajectory)
        }
        return CaptainSimulationGateReport(path: relativePath,
                                           text: text,
                                           objective: run.objective,
                                           domainTitle: run.domain.title,
                                           recommendedStrategy: run.recommendedStrategy.name,
                                           decision: writeSucceeded
                                                ? run.decision
                                                : persistenceFailureDecision,
                                           acceptanceThreshold: run.acceptanceThreshold,
                                           estimatedSuccess: run.estimatedSuccess,
                                           failureRisk: run.failureRisk,
                                           seededTasks: seededTasks,
                                           createdSpecialists: createdSpecialists,
                                           benchmarkRecords: benchmarkRecords,
                                           writeSucceeded: writeSucceeded,
                                           writeError: writeError)
    }

    func runDomainLearningPreflight(plan: Plan, trajectory: [ActionRecord],
                                    objective rawObjective: String) -> DomainLearningReport {
        ensureMemoryArchitecture()
        let cleanObjective = rawObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? strategyObjective(plan: plan)
            : Self.safe(rawObjective.trimmingCharacters(in: .whitespacesAndNewlines))
        let evidence = CaptainProjectEvidence.capture(projectRoot: projectRoot)
        let registry = makeSpecialistRegistry(projectRoot)
        let strategy = CaptainStrategist.plan(objective: cleanObjective,
                                              evidence: evidence,
                                              specialists: registry.load())
        let retrieval = retrievalContext(objective: strategy.objective, strategy: strategy)
        let createdStrategySpecialists = createMissingSpecialists(strategy.missingSpecialists)
        let createdLearningSpecialists = createDomainLearningSpecialists(strategy: strategy)
        let assignments = domainLearningAssignments(strategy: strategy,
                                                    specialists: registry.load())
        let knowledgeDebt = seedDomainLearningKnowledgeDebt(strategy: strategy,
                                                            objective: strategy.objective)
        let timestamp = Int(now().timeIntervalSince1970)
        let path = researchArchiveRoot + "/domain-learning/\(timestamp)-\(Self.slug(strategy.objective)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let seededTasks = seedDomainLearningTasks(strategy: strategy,
                                                  assignments: assignments,
                                                  reportPath: relativePath,
                                                  trajectory: trajectory)
        let memoryRecords = recordDomainLearningMemory(strategy: strategy,
                                                       retrieval: retrieval,
                                                       reportPath: relativePath,
                                                       trajectory: trajectory)
        let dispatchCommand = "/domain run \(strategy.objective)"
        let text = renderDomainLearningReport(strategy: strategy,
                                              retrieval: retrieval,
                                              assignments: assignments,
                                              reportPath: relativePath,
                                              seededTasks: seededTasks,
                                              knowledgeDebtCreated: knowledgeDebt,
                                              createdSpecialists: createdStrategySpecialists + createdLearningSpecialists,
                                              memoryRecords: memoryRecords,
                                              dispatchCommand: dispatchCommand)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        return DomainLearningReport(path: relativePath,
                                    text: text,
                                    objective: strategy.objective,
                                    understandingConfidence: strategy.understanding.confidence,
                                    confidenceThreshold: strategy.understanding.threshold,
                                    canExecute: strategy.understanding.canOrganize,
                                    seededTasks: seededTasks,
                                    knowledgeDebtCreated: knowledgeDebt,
                                    createdSpecialists: createdStrategySpecialists + createdLearningSpecialists,
                                    memoryRecords: memoryRecords,
                                    agentAssignments: assignments,
                                    dispatchCommand: dispatchCommand,
                                    writeSucceeded: writeSucceeded,
                                    writeError: writeError)
    }

    @discardableResult
    func recordDomainLearningSpecialistOutput(objective rawObjective: String,
                                              assignment: DomainLearningAssignment,
                                              summary rawSummary: String) -> DomainLearningSpecialistArtifact? {
        ensureMemoryArchitecture()
        let objective = Self.safe(rawObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Domain learning specialist output"
            : rawObjective.trimmingCharacters(in: .whitespacesAndNewlines))
        let summary = Self.safe(rawSummary.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !summary.isEmpty else { return nil }

        let timestamp = Int(now().timeIntervalSince1970)
        let path = researchArchiveRoot + "/domain-learning/specialists/"
            + "\(timestamp)-\(Self.slug(objective))-\(Self.slug(assignment.specialistName)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let text = [
            "# Domain Learning Specialist Output",
            "",
            "Objective: \(objective)",
            "Specialist: \(Self.safe(assignment.specialistName))",
            "Role: \(Self.safe(assignment.role))",
            "Preferred model: \(Self.safe(assignment.preferredModel))",
            "",
            "## Assigned Task",
            Self.safe(assignment.task),
            "",
            "## Specialist Summary",
            summary,
            "",
            "## Evidence Contract",
            "This artifact is captured so Captain can retrieve, review, benchmark, and teach from specialist work instead of losing it in terminal output.",
            "",
            "Source: \(relativePath)"
        ].joined(separator: "\n")

        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let memoryRecorded = appendJSON(DiskMemoryRecord(
            id: "AA-domain-learning-specialist-\(timestamp)-\(Self.slug(assignment.specialistName))",
            title: "Domain Learning Specialist: \(assignment.specialistName)",
            summary: "\(assignment.role): \(excerpt(summary, limit: 180))",
            body: [
                "Objective: \(objective)",
                "Preferred model: \(assignment.preferredModel)",
                "Task: \(assignment.task.singleLine)",
                "Summary: \(summary)"
            ].joined(separator: "\n"),
            source: relativePath,
            confidence: 74,
            impact: 4,
            tags: ["domain-learning", "specialist-output", assignment.specialistName]
        ), to: knowledgeIndexPath)

        let planStore = PlanStore(projectRoot: projectRoot)
        let plan = planStore.load()
        var updatedTaskIDs: [Int] = []
        for task in plan.tasks where task.owner == assignment.specialistName && !task.evidence.contains(relativePath) {
            if planStore.update(id: task.id, appendEvidence: [relativePath]) != nil {
                updatedTaskIDs.append(task.id)
            }
        }
        let ledgerRecorded = recordSpecialistEvidenceLedger(kind: .domainLearningSpecialist,
                                                            objective: objective,
                                                            specialistName: assignment.specialistName,
                                                            role: assignment.role,
                                                            preferredModel: assignment.preferredModel,
                                                            artifactPath: relativePath,
                                                            memoryRecorded: memoryRecorded,
                                                            taskIDs: updatedTaskIDs)

        return DomainLearningSpecialistArtifact(path: relativePath,
                                                memoryRecorded: memoryRecorded,
                                                taskEvidenceUpdated: updatedTaskIDs.count,
                                                updatedTaskIDs: updatedTaskIDs,
                                                evidenceLedgerRecorded: ledgerRecorded)
    }

    @discardableResult
    func recordSelfHealSpecialistOutput(objective rawObjective: String,
                                        assignment: SelfHealAgentAssignment,
                                        summary rawSummary: String) -> SelfHealSpecialistArtifact? {
        ensureMemoryArchitecture()
        let objective = Self.safe(rawObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Captain self-heal specialist output"
            : rawObjective.trimmingCharacters(in: .whitespacesAndNewlines))
        let summary = Self.safe(rawSummary.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !summary.isEmpty else { return nil }

        let timestamp = Int(now().timeIntervalSince1970)
        let path = selfHealRoot + "/specialists/"
            + "\(timestamp)-\(Self.slug(objective))-\(Self.slug(assignment.specialistName)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let text = [
            "# Self-Heal Specialist Output",
            "",
            "Objective: \(objective)",
            "Specialist: \(Self.safe(assignment.specialistName))",
            "Role: \(Self.safe(assignment.role))",
            "Preferred model: \(Self.safe(assignment.preferredModel))",
            "",
            "## Assigned Repair Task",
            Self.safe(assignment.task),
            "",
            "## Specialist Summary",
            summary,
            "",
            "## Evidence Contract",
            "This artifact is captured so Captain's repair loop can be reviewed, benchmarked, and taught from durable evidence instead of terminal-only output.",
            "",
            "Source: \(relativePath)"
        ].joined(separator: "\n")

        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        let memoryRecorded = appendJSON(DiskMemoryRecord(
            id: "AA-self-heal-specialist-\(timestamp)-\(Self.slug(assignment.specialistName))",
            title: "Self-Heal Specialist: \(assignment.specialistName)",
            summary: "\(assignment.role): \(excerpt(summary, limit: 180))",
            body: [
                "Objective: \(objective)",
                "Preferred model: \(assignment.preferredModel)",
                "Task: \(assignment.task.singleLine)",
                "Summary: \(summary)"
            ].joined(separator: "\n"),
            source: relativePath,
            confidence: 76,
            impact: 5,
            tags: ["self-heal", "specialist-output", assignment.specialistName]
        ), to: knowledgeIndexPath)

        let planStore = PlanStore(projectRoot: projectRoot)
        let plan = planStore.load()
        var updatedTaskIDs: [Int] = []
        for task in plan.tasks where task.owner == assignment.specialistName && !task.evidence.contains(relativePath) {
            if planStore.update(id: task.id, appendEvidence: [relativePath]) != nil {
                updatedTaskIDs.append(task.id)
            }
        }
        let ledgerRecorded = recordSpecialistEvidenceLedger(kind: .selfHealSpecialist,
                                                            objective: objective,
                                                            specialistName: assignment.specialistName,
                                                            role: assignment.role,
                                                            preferredModel: assignment.preferredModel,
                                                            artifactPath: relativePath,
                                                            memoryRecorded: memoryRecorded,
                                                            taskIDs: updatedTaskIDs)

        return SelfHealSpecialistArtifact(path: relativePath,
                                          memoryRecorded: memoryRecorded,
                                          taskEvidenceUpdated: updatedTaskIDs.count,
                                          updatedTaskIDs: updatedTaskIDs,
                                          evidenceLedgerRecorded: ledgerRecorded)
    }

    func runLocalModelScout(objective rawObjective: String) -> LocalModelScoutReport {
        ensureMemoryArchitecture()
        let objective = Self.safe(rawObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "safe local model acquisition"
            : rawObjective.trimmingCharacters(in: .whitespacesAndNewlines))
        let hardwareMemoryGB = LocalModelScout.defaultMemoryGB()
        let candidates = LocalModelScout.plan(objective: objective,
                                              hardwareMemoryGB: hardwareMemoryGB)
        let timestamp = Int(now().timeIntervalSince1970)
        let path = localModelsRoot + "/\(timestamp)-\(Self.slug(objective)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let seededTasks = seedLocalModelScoutTasks(objective: objective,
                                                   candidates: candidates,
                                                   reportPath: relativePath)
        let memoryRecords = recordLocalModelScoutMemory(objective: objective,
                                                        candidates: candidates,
                                                        reportPath: relativePath)
        let text = LocalModelScout.render(objective: objective,
                                          hardwareMemoryGB: hardwareMemoryGB,
                                          candidates: candidates,
                                          reportPath: relativePath,
                                          seededTasks: seededTasks,
                                          memoryRecords: memoryRecords)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        return LocalModelScoutReport(path: relativePath,
                                     text: text,
                                     objective: objective,
                                     hardwareMemoryGB: hardwareMemoryGB,
                                     candidates: candidates,
                                     seededTasks: seededTasks,
                                     memoryRecords: memoryRecords,
                                     writeSucceeded: writeSucceeded,
                                     writeError: writeError)
    }

    func runLiveModelMetadataGate(spec rawSpec: String,
                                  fetcher: LiveModelMetadataFetcher = LiveModelMetadataFetcher()) async -> LiveModelMetadataGateReport {
        ensureMemoryArchitecture()
        let cleanSpec = rawSpec.trimmingCharacters(in: .whitespacesAndNewlines)
        let displaySpec = Self.safe(cleanSpec.isEmpty ? "missing-model-spec" : cleanSpec)
        let createdAt = now().timeIntervalSince1970
        let timestamp = Int(createdAt)
        let path = localModelsRoot + "/\(timestamp)-metadata-\(Self.slug(displaySpec)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)

        var metadata: LiveModelMetadata?
        var decision: LiveModelMetadataDecision?
        var acquisitionManifest: LocalModelAcquisitionManifest?
        var acquisitionManifestPath: String?
        var manifestRequired = false
        var manifestWriteSucceeded = false
        var manifestWriteError: String?
        var fetchError: String?
        if let request = LiveModelMetadataGate.parseRequest(cleanSpec) {
            switch await fetcher.fetch(request) {
            case .success(let fetched):
                metadata = fetched
                decision = LiveModelMetadataDecision.evaluate(fetched)
                if let decision, decision.accepted,
                   let manifest = LiveModelMetadataGate.makeAcquisitionManifest(spec: displaySpec,
                                                                                metadata: fetched,
                                                                                decision: decision,
                                                                                gateReportPath: relativePath,
                                                                                createdAt: createdAt) {
                    manifestRequired = true
                    let manifestPath = localModelsRoot + "/\(timestamp)-acquisition-\(Self.slug(displaySpec)).json"
                    let manifestRelativePath = Self.projectRelative(manifestPath, root: projectRoot)
                    do {
                        let data = try LiveModelMetadataGate.manifestJSONData(manifest)
                        try FileManager.default.createDirectory(atPath: (manifestPath as NSString).deletingLastPathComponent,
                                                                withIntermediateDirectories: true)
                        try data.write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
                        acquisitionManifest = manifest
                        acquisitionManifestPath = manifestRelativePath
                        manifestWriteSucceeded = true
                    } catch {
                        manifestWriteError = String(describing: error)
                    }
                }
            case .failure(let error):
                fetchError = String(describing: error)
            }
        } else {
            fetchError = "invalid model spec; use hf:<owner/repo>, mlx:<owner/repo>, or ollama:<tag>"
        }

        let seededTasks = seedLiveModelMetadataGateTasks(spec: displaySpec,
                                                         metadata: metadata,
                                                         decision: decision,
                                                         reportPath: relativePath,
                                                         manifestPath: acquisitionManifestPath,
                                                         manifest: acquisitionManifest,
                                                         manifestWriteSucceeded: !manifestRequired || manifestWriteSucceeded,
                                                         manifestWriteError: manifestWriteError,
                                                         fetchError: fetchError)
        let memoryRecords = recordLiveModelMetadataGateMemory(spec: displaySpec,
                                                              metadata: metadata,
                                                              decision: decision,
                                                              reportPath: relativePath,
                                                              fetchError: fetchError)
        let text = LiveModelMetadataGate.render(spec: displaySpec,
                                                metadata: metadata,
                                                decision: decision,
                                                fetchError: fetchError,
                                                acquisitionManifest: acquisitionManifest,
                                                acquisitionManifestPath: acquisitionManifestPath,
                                                manifestWriteSucceeded: !manifestRequired || manifestWriteSucceeded,
                                                manifestWriteError: manifestWriteError,
                                                path: relativePath,
                                                seededTasks: seededTasks,
                                                memoryRecords: memoryRecords)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        return LiveModelMetadataGateReport(path: relativePath,
                                           text: text,
                                           spec: displaySpec,
                                           metadata: metadata,
                                           decision: decision,
                                           acquisitionManifest: acquisitionManifest,
                                           acquisitionManifestPath: acquisitionManifestPath,
                                           seededTasks: seededTasks,
                                           memoryRecords: memoryRecords,
                                           writeSucceeded: writeSucceeded,
                                           writeError: writeError,
                                           manifestWriteSucceeded: !manifestRequired || manifestWriteSucceeded,
                                           manifestWriteError: manifestWriteError,
                                           fetchError: fetchError)
    }

    func runLocalModelAcquisitionPreflight(manifestPath rawPath: String) -> LocalModelAcquisitionPreflightReport {
        ensureMemoryArchitecture()
        let cleanPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPath = Self.safe(cleanPath.isEmpty ? "missing-manifest-path" : cleanPath)
        let timestamp = Int(now().timeIntervalSince1970)

        var manifest: LocalModelAcquisitionManifest?
        var loadError: String?
        var storedManifestPath = displayPath
        if cleanPath.isEmpty {
            loadError = "missing acquisition manifest path"
        } else if let resolved = resolveProjectFile(cleanPath) {
            storedManifestPath = Self.projectRelative(resolved, root: projectRoot)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
                manifest = try JSONDecoder().decode(LocalModelAcquisitionManifest.self, from: data)
            } catch {
                loadError = String(describing: error)
            }
        } else {
            loadError = "manifest path must exist inside the project root"
        }

        let decision = manifest.map(LiveModelMetadataGate.validateAcquisitionManifest)
            ?? LocalModelAcquisitionDecision(accepted: false,
                                             reasons: [loadError ?? "manifest unavailable"],
                                             warnings: [])
        let reportSlug = manifest?.approvalID ?? displayPath
        let path = localModelsRoot + "/\(timestamp)-acquire-\(Self.slug(reportSlug)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let seededTasks = seedLocalModelAcquisitionPreflightTasks(manifestPath: storedManifestPath,
                                                                  manifest: manifest,
                                                                  decision: decision,
                                                                  reportPath: relativePath)
        let memoryRecords = recordLocalModelAcquisitionPreflightMemory(manifestPath: storedManifestPath,
                                                                       manifest: manifest,
                                                                       decision: decision,
                                                                       reportPath: relativePath,
                                                                       loadError: loadError)
        let text = renderLocalModelAcquisitionPreflight(manifestPath: storedManifestPath,
                                                        manifest: manifest,
                                                        decision: decision,
                                                        reportPath: relativePath,
                                                        seededTasks: seededTasks,
                                                        memoryRecords: memoryRecords,
                                                        loadError: loadError)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        return LocalModelAcquisitionPreflightReport(path: relativePath,
                                                    text: text,
                                                    manifestPath: storedManifestPath,
                                                    manifest: manifest,
                                                    decision: decision,
                                                    seededTasks: seededTasks,
                                                    memoryRecords: memoryRecords,
                                                    writeSucceeded: writeSucceeded,
                                                    writeError: writeError,
                                                    loadError: loadError)
    }

    func runLocalModelAcquisitionStage(stage rawStage: String,
                                       manifestPath rawPath: String,
                                       executor: LocalModelAcquisitionExecutor = OrganizationalLearningStore.executeLocalModelAcquisitionCommand,
                                       dependencyResolver: LocalModelAcquisitionDependencyResolver = OrganizationalLearningStore.localModelAcquisitionDependencyBlockers) -> LocalModelAcquisitionRunReport {
        ensureMemoryArchitecture()
        let cleanPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPath = Self.safe(cleanPath.isEmpty ? "missing-manifest-path" : cleanPath)
        let timestamp = Int(now().timeIntervalSince1970)
        let stage = LocalModelAcquisitionStage.parse(rawStage)

        var manifest: LocalModelAcquisitionManifest?
        var loadError: String?
        var storedManifestPath = displayPath
        if cleanPath.isEmpty {
            loadError = "missing acquisition manifest path"
        } else if let resolved = resolveProjectFile(cleanPath) {
            storedManifestPath = Self.projectRelative(resolved, root: projectRoot)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
                manifest = try JSONDecoder().decode(LocalModelAcquisitionManifest.self, from: data)
            } catch {
                loadError = String(describing: error)
            }
        } else {
            loadError = "manifest path must exist inside the project root"
        }

        var decision = manifest.map(LiveModelMetadataGate.validateAcquisitionManifest)
            ?? LocalModelAcquisitionDecision(accepted: false,
                                             reasons: [loadError ?? "manifest unavailable"],
                                             warnings: [])
        if stage == nil {
            decision.accepted = false
            decision.reasons.append("unknown acquisition stage '\(rawStage)'")
        }

        var command: LocalModelAcquisitionRunnableCommand?
        if let stage, let manifest, decision.accepted {
            command = LiveModelMetadataGate.runnableCommand(for: stage, manifest: manifest)
            if command == nil {
                decision.accepted = false
                decision.reasons.append("manifest does not authorize acquisition stage '\(stage.rawValue)'")
            }
        }
        if let stage, let manifest, decision.accepted {
            let blockers = localModelAcquisitionStageBlockers(stage: stage, manifest: manifest)
            if !blockers.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: blockers)
            }
        }
        if let command, decision.accepted {
            let mismatches = command.invocations
                .filter { $0.display != command.manifestCommand && command.stage != .benchmark }
                .map { "structured invocation '\($0.display)' does not match manifest command '\(command.manifestCommand)'" }
            if !mismatches.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: mismatches)
            }
        }
        var dependencyBlockers: [LocalModelAcquisitionDependencyBlocker] = []
        if let command, decision.accepted {
            dependencyBlockers = dependencyResolver(command)
            if !dependencyBlockers.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: dependencyBlockers.map {
                    "missing dependency '\($0.executable)': \($0.reason)"
                })
            }
        }
        if let command, decision.accepted {
            let executableBlockers = Self.localModelAcquisitionExecutableTrustBlockers(command,
                                                                                      projectRoot: projectRoot)
            if !executableBlockers.isEmpty {
                decision.accepted = false
                decision.reasons.append(contentsOf: executableBlockers)
            }
        }
        decision.reasons = Self.unique(decision.reasons)
        decision.warnings = Self.unique(decision.warnings)

        var outcome: LocalModelAcquisitionRunOutcome?
        if decision.accepted, let command {
            outcome = executor(command, projectRoot)
            if outcome?.succeeded != true {
                decision.accepted = false
                decision.reasons.append("acquisition stage command failed")
                decision.reasons = Self.unique(decision.reasons)
            }
        }

        var artifactAttestation: LocalModelAcquisitionArtifactAttestation?
        var artifactAttestationPath: String?
        if stage == .download, let manifest, outcome?.succeeded == true {
            let attestation = makeLocalModelAcquisitionArtifactAttestation(manifest: manifest)
            artifactAttestation = attestation
            artifactAttestationPath = writeLocalModelAcquisitionArtifactAttestation(attestation, manifest: manifest)
            if artifactAttestationPath == nil {
                decision.accepted = false
                decision.reasons.append("artifact attestation could not be written")
            }
            if !attestation.accepted {
                decision.accepted = false
                decision.reasons.append(contentsOf: attestation.blockers.map { "artifact attestation failed: \($0)" })
            }
            decision.reasons = Self.unique(decision.reasons)
            decision.warnings = Self.unique(decision.warnings + attestation.warnings)
        }

        let reportSlug = [manifest?.approvalID, stage?.rawValue].compactMap { $0 }.joined(separator: "-")
        let path = localModelsRoot + "/\(timestamp)-run-\(Self.slug(reportSlug.isEmpty ? displayPath : reportSlug)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        var markerPath: String?
        if let stage, let manifest, outcome?.succeeded == true, decision.accepted {
            markerPath = writeLocalModelAcquisitionStageMarker(stage: stage,
                                                               manifest: manifest,
                                                               command: command?.manifestCommand ?? "",
                                                               reportPath: relativePath)
            if markerPath == nil {
                decision.accepted = false
                decision.reasons.append("success marker could not be written")
                decision.reasons = Self.unique(decision.reasons)
            }
        }
        let seededTasks = seedLocalModelAcquisitionRunTasks(manifestPath: storedManifestPath,
                                                            manifest: manifest,
                                                            stage: stage,
                                                            decision: decision,
                                                            dependencyBlockers: dependencyBlockers,
                                                            artifactAttestation: artifactAttestation,
                                                            artifactAttestationPath: artifactAttestationPath,
                                                            reportPath: relativePath)
        let memoryRecords = recordLocalModelAcquisitionRunMemory(manifestPath: storedManifestPath,
                                                                 manifest: manifest,
                                                                 stage: stage,
                                                                 decision: decision,
                                                                 reportPath: relativePath)
        let text = renderLocalModelAcquisitionRun(manifestPath: storedManifestPath,
                                                  stage: stage,
                                                  manifest: manifest,
                                                  decision: decision,
                                                  command: command,
                                                  outcome: outcome,
                                                  dependencyBlockers: dependencyBlockers,
                                                  artifactAttestation: artifactAttestation,
                                                  artifactAttestationPath: artifactAttestationPath,
                                                  reportPath: relativePath,
                                                  markerPath: markerPath,
                                                  seededTasks: seededTasks,
                                                  memoryRecords: memoryRecords,
                                                  loadError: loadError)
        var writeSucceeded = false
        var writeError: String?
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            try (text + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            writeSucceeded = true
        } catch {
            writeError = String(describing: error)
        }
        return LocalModelAcquisitionRunReport(path: relativePath,
                                              text: text,
                                              manifestPath: storedManifestPath,
                                              stage: stage,
                                              manifest: manifest,
                                              decision: decision,
                                              command: command,
                                              outcome: outcome,
                                              markerPath: markerPath,
                                              dependencyBlockers: dependencyBlockers,
                                              artifactAttestation: artifactAttestation,
                                              artifactAttestationPath: artifactAttestationPath,
                                              seededTasks: seededTasks,
                                              memoryRecords: memoryRecords,
                                              writeSucceeded: writeSucceeded,
                                              writeError: writeError,
                                              loadError: loadError)
    }

    private struct StrategicAgendaItem: Equatable {
        var title: String
        var reason: String
    }

    private struct SelfHealWeakness: Equatable {
        var title: String
        var reason: String
        var supportingEvidence: [String]
        var benchmarkPlan: String
        var teachableRule: String
    }

    private func createDomainLearningSpecialists(strategy: CaptainStrategyPlan) -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        var created = 0
        let lower = strategy.objective.lowercased()
        var defs = [
            SpecialistDefinition(
                name: "domain-research-lead",
                description: "Learns an unfamiliar domain before Kist plans, recruits specialists, or executes real work.",
                systemPrompt: """
                You are Kist's domain research lead. Start by admitting what is not understood. Build a research plan, read primary documentation, compare competitors and open source, identify standards and known failures, then summarize whether Captain is qualified to act as a temporary subject-matter expert. Do not implement before the confidence gate is cleared.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 8,
                memory: "project",
                color: "cyan",
                source: "captain-domain-learning"),
            SpecialistDefinition(
                name: "domain-architecture-critic",
                description: "Critiques Captain's domain understanding, expertise map, strategy, and evidence before execution.",
                systemPrompt: """
                You are Kist's domain architecture critic. Be skeptical. Challenge weak evidence, missing standards, shallow competitor comparisons, unsafe execution gates, and specialists created from bad framing. Return blocking findings first and require citations, local project evidence, simulations, and benchmarks before acceptance.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                model: ProviderBinding(providerId: "deepseek"),
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "purple",
                source: "captain-domain-learning"),
            SpecialistDefinition(
                name: "simulation-and-risk-engineer",
                description: "Design sandbox simulations, probabilistic trials, failure-mode models, and accept/reject thresholds before real-world execution.",
                systemPrompt: """
                You are Kist's simulation and risk engineer. Convert plans into sandbox trials, fake APIs, test repos, benchmarks, digital twins, or market simulations. Estimate success and failure risk, compare strategies, and block execution when the evidence is weak.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "blue",
                source: "captain-domain-learning")
        ]
        if domainObjectiveNeedsLocalModel(lower) {
            defs.append(SpecialistDefinition(
                name: "local-model-scout",
                description: "Safely evaluates Hugging Face, MLX, Ollama, and other small local models by task, size, license, template, and benchmark fit before onboarding.",
                systemPrompt: """
                You are Kist's local-model scout. Do not download or install models blindly. For each task, identify candidate small models, license/provenance, hardware fit, quantization, chat template, stop tokens, expected latency, benchmark plan, and rollback path. Only recommend onboarding after sandbox simulation and eval evidence.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "green",
                source: "captain-domain-learning"))
        }
        if domainObjectiveNeedsSymbolicRules(lower) {
            defs.append(SpecialistDefinition(
                name: "symbolic-rule-compiler",
                description: "Turns repeated successful AI workflows into deterministic symbolic gates, rulebook policies, and reusable checks.",
                systemPrompt: """
                You are Kist's symbolic rule compiler. Find workflow steps that no longer need generative judgment, compile them into deterministic gates or organizational rules, and define acceptance tests that prove the symbolic path is reusable.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "yellow",
                source: "captain-domain-learning"))
        }
        for def in defs where !existing.contains(def.name) {
            if (try? registry.save(def)) != nil { created += 1 }
        }
        return created
    }

    private func domainLearningAssignments(strategy: CaptainStrategyPlan,
                                           specialists: [SpecialistDefinition]) -> [DomainLearningAssignment] {
        let lower = strategy.objective.lowercased()
        var assignments: [DomainLearningAssignment] = [
            DomainLearningAssignment(
                specialistName: "domain-research-lead",
                role: "Research and temporary SME gate",
                preferredModel: "gemini or strongest research model",
                task: """
                Objective: \(strategy.objective)
                Build the research plan and evidence dossier. Answer the missing knowledge list, compare docs/competitors/papers/open source/standards, then state whether Captain's understanding can cross \(strategy.understanding.threshold)% confidence.
                """),
            DomainLearningAssignment(
                specialistName: "simulation-and-risk-engineer",
                role: "Sandbox and probabilistic evidence",
                preferredModel: "MiMo for local project facts plus strongest reasoning model for risk",
                task: """
                Objective: \(strategy.objective)
                Design the safest sandbox, trial matrix, benchmark, fake service, or digital twin that can test the plan before real-world execution. Define success threshold, failure modes, rollback path, and verification commands.
                """),
            DomainLearningAssignment(
                specialistName: "domain-architecture-critic",
                role: "Independent critique",
                preferredModel: "deepseek",
                task: """
                Objective: \(strategy.objective)
                Review the research dossier, expertise map, sandbox plan, and proposed organization. Block shallow evidence, missing standards, unsafe assumptions, weak tests, or premature execution.
                """)
        ]
        for need in strategy.requiredExpertise {
            let name = need.existingSpecialists.first ?? need.name
            guard !assignments.contains(where: { $0.specialistName == name }) else { continue }
            assignments.append(DomainLearningAssignment(
                specialistName: name,
                role: need.reason,
                preferredModel: preferredModelHint(for: name),
                task: """
                Objective: \(strategy.objective)
                Work only inside your expertise: \(need.reason). Use project evidence, research findings, and benchmark/simulation constraints. Return what Captain must know before planning or execution.
                """))
        }
        if domainObjectiveNeedsLocalModel(lower) {
            assignments.append(DomainLearningAssignment(
                specialistName: "local-model-scout",
                role: "Safe local/Hugging Face model acquisition",
                preferredModel: "MiMo plus local benchmark harness",
                task: """
                Objective: \(strategy.objective)
                Identify candidate small local/Hugging Face models by task fit, size, license, quantization, chat template, stop tokens, hardware fit, and eval plan. Do not download or install without a sandbox and benchmark acceptance gate.
                """))
        }
        if domainObjectiveNeedsSymbolicRules(lower) {
            assignments.append(DomainLearningAssignment(
                specialistName: "symbolic-rule-compiler",
                role: "Compile successful workflow into deterministic policy",
                preferredModel: "MiMo for source-grounded rule extraction",
                task: """
                Objective: \(strategy.objective)
                Identify which repeated workflow gates can become symbolic checks or permanent organizational rules. Define the exact deterministic inputs, outputs, acceptance tests, and rollback path.
                """))
        }
        return assignments.filter { specialist in
            specialists.contains { $0.name == specialist.specialistName }
                || ["domain-research-lead", "domain-architecture-critic", "simulation-and-risk-engineer", "local-model-scout", "symbolic-rule-compiler"].contains(specialist.specialistName)
        }
    }

    private func seedDomainLearningKnowledgeDebt(strategy: CaptainStrategyPlan,
                                                 objective: String) -> Int {
        var count = 0
        for item in strategy.understanding.missingKnowledge.prefix(6) {
            _ = addKnowledgeDebt(topic: "Domain learning: \(item)",
                                 reason: "Captain is below the temporary subject-matter expert confidence gate for: \(objective)",
                                 visit: "Primary docs, standards, competitors, papers, open source, and local project evidence.",
                                 impact: 5,
                                 priority: .high,
                                 estimatedLearning: strategy.understanding.recommendedResearchTime,
                                 expectedBenefit: ["raise Captain understanding above \(strategy.understanding.threshold)%", "avoid premature specialist assignment"])
            count += 1
        }
        for question in strategy.researchQuestions.prefix(4) {
            _ = addKnowledgeDebt(topic: "Research question: \(question)",
                                 reason: "Domain learning preflight requires this answer before execution.",
                                 visit: "Official docs and primary sources for \(objective)",
                                 impact: 4,
                                 priority: .high,
                                 estimatedLearning: "30-60 minutes",
                                 expectedBenefit: ["turn uncertainty into evidence-backed planning"])
            count += 1
        }
        return count
    }

    private func seedDomainLearningTasks(strategy: CaptainStrategyPlan,
                                         assignments: [DomainLearningAssignment],
                                         reportPath: String,
                                         trajectory: [ActionRecord]) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstAddedID: Int?
        var count = 0

        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String,
                 _ verification: String, _ evidence: [String] = []) {
            guard !domainLearningTaskExists(title: title) else { return }
            let task = store.add(title: title,
                                 detail: detail,
                                 owner: owner,
                                 kind: kind,
                                 acceptance: acceptance,
                                 verification: verification,
                                 evidence: evidence)
            if firstAddedID == nil { firstAddedID = task.id }
            count += 1
        }

        add("PLAN: Domain learning preflight -- \(strategy.objective)", .plan, "captain",
            "Confidence \(strategy.understanding.confidence)% / threshold \(strategy.understanding.threshold)%. \(strategy.understanding.gateSummary)",
            "Research plan, missing knowledge, specialist roster, simulation gate, and accept/reject policy are explicit.",
            "/domain \(strategy.objective) shows the durable learning dossier.",
            [reportPath])
        add("RESEARCH: Build domain evidence dossier -- \(strategy.objective)", .research, "domain-research-lead",
            "Answer the missing knowledge list using primary docs, standards, competitors, papers, open source, and local project evidence.",
            "Dossier raises or blocks the temporary subject-matter expert confidence gate with cited evidence.",
            "Attach research notes under .kist/learning/research-archive/ and close matching Knowledge Debt.",
            [reportPath])
        add("RESEARCH: Compare industry and prior art -- \(strategy.objective)", .research, "domain-research-lead",
            "Compare what already solves this and where those systems fail.",
            "Competitor/open-source/paper/standards comparison changes the execution plan or explicitly validates it.",
            "Attach source targets, comparison notes, and architecture implications.",
            strategy.researchQuestions.prefix(5).map { "question: \($0)" })
        add("DECISION: Temporary subject-matter expert gate -- \(strategy.objective)", .decision, "captain",
            "Do not plan or execute until Captain can state what it knows, what it still does not know, and why the remaining risk is acceptable.",
            "Understanding confidence is >= \(strategy.understanding.threshold)% or the plan is held for another research pass.",
            "/domain and /retrieve show the report, retrieval cards, and knowledge debt.",
            [reportPath])
        add("HANDOFF: Assemble specialist organization -- \(strategy.objective)", .handoff, "captain",
            assignments.map { "\($0.specialistName): \($0.role)" }.joined(separator: "\n"),
            "Existing specialists are used first; missing specialists are created only from confirmed expertise gaps.",
            "/agents lists the required specialists; assignments have task, model hint, and evidence expectations.",
            assignments.map { ".kist/agents/\($0.specialistName).md" })
        add("TEST: Sandbox simulation and benchmark gate -- \(strategy.objective)", .test, "simulation-and-risk-engineer",
            "Create a safe sandbox, probabilistic trial plan, benchmark/live-eval signal, and rollback path before real execution.",
            "Simulation evidence, benchmark output, and failure-mode review either clear execution or block it.",
            "/simulate \(strategy.objective); attach benchmark or live-eval logs.",
            [reportPath])
        add("REVIEW: Independent domain architecture critique -- \(strategy.objective)", .review, "domain-architecture-critic",
            "Critique research quality, specialist fit, confidence estimate, simulation fidelity, and execution risk.",
            "Review either clears the plan with evidence or records blocking findings and the next research task.",
            "Attach critic findings and commands run.",
            [reportPath])
        add("DECISION: Teach Captain after domain learning -- \(strategy.objective)", .decision, "captain",
            "Candidate lesson: \(CaptainStrategist.organizationalLessonCandidate(objective: strategy.objective, expertiseNames: strategy.requiredExpertise.map(\.name)))",
            "Promote a permanent organizational rule only after research, simulation, review, and benchmark evidence.",
            "/teach add <lesson> | confidence: ... | reason: ... | evidence: \(reportPath)",
            [reportPath])

        if domainObjectiveNeedsLocalModel(strategy.objective.lowercased()) {
            add("RESEARCH: Safe local model acquisition -- \(strategy.objective)", .research, "local-model-scout",
                "Evaluate Hugging Face/MLX/Ollama candidates by license, size, hardware fit, quantization, template, stop tokens, and benchmark task fit.",
                "No model is downloaded or promoted without provenance, sandbox eval, clean-stop profile, and rollback path.",
                "--inspect-model <path>; /bench <task>; attach candidate matrix and eval logs.",
                [reportPath])
        }
        if domainObjectiveNeedsSymbolicRules(strategy.objective.lowercased()) {
            add("ACTION: Compile reusable symbolic gates -- \(strategy.objective)", .action, "symbolic-rule-compiler",
                "Identify workflow steps that should become deterministic gates or rulebook policy instead of repeated generative reasoning.",
                "A symbolic workflow or organizational rule is compiled with acceptance tests and a rollback path.",
                "/symbolic compile \(strategy.objective); /symbolic run <workflow-id> <target>",
                [reportPath])
        }

        if trajectory.contains(where: { !$0.success }) {
            add("REVIEW: Account for failed tool evidence -- \(strategy.objective)", .review, "domain-architecture-critic",
                "The triggering turn had failed tool actions; include them as workflow friction before execution.",
                "Failed tools are either resolved, scoped out, or converted into blockers.",
                "/logs and task evidence name the failure and recovery path.",
                [reportPath])
        }

        if activeBefore == nil, let firstAddedID {
            _ = store.update(id: firstAddedID, status: .inProgress)
        }
        return count
    }

    @discardableResult
    private func recordDomainLearningMemory(strategy: CaptainStrategyPlan,
                                            retrieval: CaptainRetrievalContext,
                                            reportPath: String,
                                            trajectory: [ActionRecord]) -> Int {
        var count = 0
        let recordID = "AA-domain-learning-\(Self.slug(strategy.objective).prefix(48))"
        let record = DiskMemoryRecord(
            id: recordID,
            title: "Domain Learning Preflight: \(strategy.objective)",
            summary: "\(strategy.understanding.confidence)% / \(strategy.understanding.threshold)% understanding. \(strategy.understanding.gateSummary)",
            body: [
                "Missing knowledge: \(strategy.understanding.missingKnowledge.joined(separator: "; "))",
                "Research questions: \(strategy.researchQuestions.prefix(8).joined(separator: "; "))",
                "Required expertise: \(strategy.requiredExpertise.map(\.name).joined(separator: ", "))",
                "Retrieved memory: \(retrieval.retrieved.map(\.evidenceID).joined(separator: ", "))",
                "Observed tools: \(Set(trajectory.map(\.tool)).sorted().joined(separator: ", "))",
                "Next action: \(strategy.nextAction)"
            ].joined(separator: "\n"),
            source: reportPath,
            confidence: strategy.understanding.confidence,
            impact: strategy.understanding.canOrganize ? 3 : 5,
            tags: ["domain-learning", "temporary-sme", "research-first", "captain"]
        )
        var records = loadJSONL(DiskMemoryRecord.self, path: knowledgeIndexPath)
        if let idx = records.firstIndex(where: { $0.id == recordID }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        if saveJSONL(records, to: knowledgeIndexPath) {
            count += 1
        }
        return count
    }

    private func renderDomainLearningReport(strategy: CaptainStrategyPlan,
                                            retrieval: CaptainRetrievalContext,
                                            assignments: [DomainLearningAssignment],
                                            reportPath: String,
                                            seededTasks: Int,
                                            knowledgeDebtCreated: Int,
                                            createdSpecialists: Int,
                                            memoryRecords: Int,
                                            dispatchCommand: String) -> String {
        var lines = [
            "# Captain Domain Learning Preflight",
            "",
            "Objective: \(strategy.objective)",
            "",
            "## Operating Law",
            "Research before expertise. Expertise before organization. Organization before execution.",
            "",
            "## Current Understanding",
            "\(strategy.understanding.confidence)% / \(strategy.understanding.threshold)%",
            strategy.understanding.currentUnderstanding,
            "",
            "Gate: \(strategy.understanding.gateSummary)",
            "",
            "## Research Plan",
            "Captain must learn the domain before pretending to lead it.",
            "",
            "Research checklist:",
            "- Primary documentation",
            "- Competitors and comparable products",
            "- Papers and benchmark suites",
            "- Architecture and open-source references",
            "- Standards, compliance, and best practices",
            "- Known failures and anti-patterns",
            "- Local project evidence",
            "- Sandbox simulation and probabilistic risk plan",
            "",
            "## Knowledge Gap Analysis",
        ]
        lines += strategy.understanding.missingKnowledge.map { "- \($0)" }
        lines += [
            "",
            "Recommended research time: \(strategy.understanding.recommendedResearchTime)",
            "",
            "## Research Questions",
        ]
        lines += strategy.researchQuestions.prefix(12).map { "- \($0)" }
        lines += [
            "",
            "## Temporary Subject-Matter Expert Gate",
            strategy.understanding.canOrganize
                ? "PASS: Captain can start organization design after validating assumptions."
                : "HOLD: Captain is not qualified yet. Learn until the confidence threshold is reached.",
            "",
            "## Required Expertise",
        ]
        for need in strategy.requiredExpertise {
            let covered = need.existingSpecialists.isEmpty
                ? "missing"
                : "covered by \(need.existingSpecialists.joined(separator: ", "))"
            lines.append("- \(need.name): \(covered) -- \(need.reason)")
        }
        lines += [
            "",
            "## Specialist Organization",
        ]
        for assignment in assignments {
            lines += [
                "- \(assignment.specialistName) -- \(assignment.role)",
                "  Preferred model: \(assignment.preferredModel)",
                "  Task: \(assignment.task.singleLine)"
            ]
        }
        if domainObjectiveNeedsLocalModel(strategy.objective.lowercased()) {
            lines += [
                "",
                "## Safe Local Model Acquisition",
                "Local/Hugging Face model onboarding is a gated research and benchmark task, not an automatic download.",
                "Required proof: provenance, license, size, hardware fit, chat template, stop tokens, sandbox eval, benchmark win, rollback path."
            ]
        }
        if domainObjectiveNeedsSymbolicRules(strategy.objective.lowercased()) {
            lines += [
                "",
                "## Symbolic Rule Path",
                "Repeated successful workflows should be compiled into deterministic gates or permanent organizational rules after evidence.",
                "Required proof: exact inputs, outputs, acceptance tests, and rule retirement path."
            ]
        }
        lines += [
            "",
            "## Captain Retrieval",
            retrieval.briefing,
            "",
            "## Execution Policy",
            "- Do not execute real-world work until research, simulation, review, and evidence gates clear.",
            "- Use existing specialists first; create missing specialists only for confirmed expertise gaps.",
            "- Promote a Teach Captain rule only after the work is proven, not merely hypothesized.",
            "",
            "## Dispatch",
            "Run now: \(dispatchCommand)",
            "Manual sequence:",
        ]
        lines += assignments.map { "- /agents run \($0.specialistName) \($0.task.singleLine)" }
        lines += [
            "",
            "## Artifacts",
            "Report: \(reportPath)",
            "Seeded tasks: \(seededTasks)",
            "Knowledge debt records: \(knowledgeDebtCreated)",
            "Created specialists: \(createdSpecialists)",
            "Knowledge index records: \(memoryRecords)"
        ]
        return lines.joined(separator: "\n")
    }

    private func strategicResearchItems(from intelligence: StrategicIntelligenceSnapshot) -> [StatusDashboard.ResearchItem] {
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
    private func recordStrategicIntelligence(_ intelligence: StrategicIntelligenceSnapshot) -> Int {
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
    private func promoteStrategicProposalRules(_ intelligence: StrategicIntelligenceSnapshot,
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

    private func writeStrategicArchive(_ intelligence: StrategicIntelligenceSnapshot) {
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

    private func mergeResearch(_ items: [StatusDashboard.ResearchItem]) -> [StatusDashboard.ResearchItem] {
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

    private func strategicIntelligenceAgenda(strategy: CaptainStrategyPlan,
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

    private func evolutionProposal(strategy: CaptainStrategyPlan, debts: [KnowledgeDebtRecord]) -> String {
        if strategy.requiredExpertise.contains(where: { $0.name == "agent-orchestration-architect" }) {
            return "Add delegation decision cards backed by research, live evals, and competitor/runtime comparison."
        }
        if let debt = debts.first {
            return "Prioritize paying `\(debt.topic)` before hardening the next architecture decision."
        }
        return "Run a weekly `/evolve` board meeting that scans industry change, updates knowledge debt, and teaches Captain one permanent rule."
    }

    @discardableResult
    private func teachCaptain(plan: Plan, latest: LearningCapsule?,
                              strategy: CaptainStrategyPlan,
                              intelligence: StrategicIntelligenceSnapshot) -> OrganizationalRuleRecord {
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

    private func selfHealWeakness(insights: DashboardInsightBundle,
                                  debts: [KnowledgeDebtRecord],
                                  latest: LearningCapsule?) -> SelfHealWeakness {
        var evidence: [String] = [
            "dashboard observation",
            "knowledge debt queue",
            "strategic intelligence board meeting"
        ]
        if let topResearch = insights.research.first {
            evidence.append("top research: \(topResearch.title) -- \(topResearch.reason)")
            if !topResearch.visit.isEmpty { evidence.append("source target: \(topResearch.visit)") }
        }
        if let topDebt = debts.first {
            evidence.append("top debt: \(topDebt.topic) -- \(topDebt.reason)")
        }
        if let latest {
            evidence.append("latest capsule: \(latest.taskTitle) \(latest.status.rawValue)")
        }
        if let failure = CaptainFailureAnalysis.latest(projectRoot: projectRoot) {
            evidence.append("latest failure capsule: \(failure.id) -- \(failure.observed)")
            evidence.append("likely failure layer: \(failure.likelyLayer.rawValue) @ \(failure.confidence)%")
            evidence.append(contentsOf: failure.evidence.prefix(3))
            return SelfHealWeakness(
                title: "Failure analysis: \(failure.observed)",
                reason: "Captain has a concrete failure capsule. Self-heal must investigate the likely \(failure.likelyLayer.rawValue) layer, confirm or reject the ranked hypotheses, repair the root cause, verify, and teach the permanent lesson.",
                supportingEvidence: Array(evidence.prefix(10)),
                benchmarkPlan: failure.verificationPlan.isEmpty
                    ? "Reproduce the failure, add a focused regression, then run the relevant suite."
                    : failure.verificationPlan.joined(separator: "; "),
                teachableRule: failure.teachCandidate
            )
        }
        return SelfHealWeakness(
            title: "Captain self-heal handoff loop",
            reason: "Captain can identify weaknesses and generate research/build queues, but the next step must become an assigned repair mission with independent research, implementation, review, benchmark evidence, and a Teach Captain accept/reject gate.",
            supportingEvidence: Array(evidence.prefix(8)),
            benchmarkPlan: "Run focused self-heal tests, then the full suite. Accept only if the mission seeds tasks, creates specialists, preserves operator gates, and produces a teachable decision.",
            teachableRule: "Captain self-healing must turn observations into assigned research, build, review, benchmark, and Teach Captain gates before changing platform behavior."
        )
    }

    private func selfHealAssignments(weakness: SelfHealWeakness,
                                     objective: String) -> [SelfHealAgentAssignment] {
        [
            SelfHealAgentAssignment(
                specialistName: "self-heal-researcher",
                role: "Gemini research analyst",
                preferredModel: "gemini",
                task: """
                Research the self-heal objective before implementation.
                Objective: \(objective)
                Weakness: \(weakness.title)
                Gather competitor, docs, source, and benchmark references. Do not edit product code. Update the research task with evidence and a concise recommendation.
                """),
            SelfHealAgentAssignment(
                specialistName: "self-heal-builder",
                role: "implementation agent",
                preferredModel: "current default or strongest coding model",
                task: """
                Implement the smallest high-confidence fix for the self-heal objective.
                Objective: \(objective)
                Weakness: \(weakness.title)
                Use the research evidence and existing project patterns. Keep changes scoped, update the task board, and leave verification commands.
                If you run or inspect a verification result, emit exact proof lines:
                VERIFY: <command/check> => PASS|FAIL: <short output evidence>
                Do not write PASS unless command output or attached evidence proves it.
                """),
            SelfHealAgentAssignment(
                specialistName: "self-heal-critic",
                role: "DeepSeek independent critic",
                preferredModel: "deepseek",
                task: """
                Brutally review the self-heal implementation.
                Objective: \(objective)
                Weakness: \(weakness.title)
                Look for regressions, weak tests, unsafe autonomy, hidden provider assumptions, and stale research. Run available verification where possible.
                Emit exact proof lines for every check you run or inspect:
                VERIFY: <command/check> => PASS|FAIL: <short output evidence>
                Do not write PASS unless command output or attached evidence proves it.
                """),
            SelfHealAgentAssignment(
                specialistName: "self-heal-captain-gate",
                role: "Captain acceptance gate",
                preferredModel: "current default",
                task: """
                Decide whether to accept or reject the self-heal change.
                Objective: \(objective)
                Benchmark plan: \(weakness.benchmarkPlan)
                Accept only if research evidence, implementation proof, independent review, and benchmark results all support promotion. If accepted, propose the Teach Captain rule: \(weakness.teachableRule)
                Emit exact proof lines for every accepted check:
                VERIFY: <command/check> => PASS|FAIL: <short output evidence>
                Do not write PASS unless command output or attached evidence proves it.
                """)
        ]
    }

    @discardableResult
    private func createSelfHealSpecialists(assignments: [SelfHealAgentAssignment]) -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        var created = 0
        let defs = [
            SpecialistDefinition(
                name: "self-heal-researcher",
                description: "Researches Captain self-heal weaknesses, competitor patterns, docs, papers, and benchmark references before implementation.",
                systemPrompt: """
                You are Kist's self-heal researcher. Research before expertise. Do not edit product code. Gather primary docs, competitor/source comparisons, benchmark ideas, and risks. Update the task board with evidence and a recommendation that the builder can act on.
                """,
                toolAllowlist: ["read_file", "search_code", "web_search", "fetch_url", "tasks"],
                model: ProviderBinding(providerId: "gemini"),
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "blue",
                source: "captain-self-heal"),
            SpecialistDefinition(
                name: "self-heal-builder",
                description: "Implements the smallest scoped repair after Captain research and evidence gates identify the highest-confidence self-heal fix.",
                systemPrompt: """
                You are Kist's self-heal builder. Read the mission, research evidence, and local code before editing. Implement the smallest scoped fix, update the shared task board, and leave verifiable proof. Do not promote lessons or claim acceptance; that belongs to the gate.
                """,
                toolAllowlist: ["read_file", "search_code", "edit_file", "apply_patch", "run_command", "tasks"],
                modelAlias: "inherit",
                maxTurns: 8,
                memory: "project",
                color: "orange",
                source: "captain-self-heal"),
            SpecialistDefinition(
                name: "self-heal-critic",
                description: "Performs independent AI review of self-heal changes, looking for regressions, weak tests, unsafe autonomy, and stale assumptions.",
                systemPrompt: """
                You are Kist's self-heal critic. Be direct and skeptical. Review the implementation against the mission, research evidence, tests, safety gates, and operator visibility. Prefer findings with file/line evidence. Do not rubber-stamp.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                model: ProviderBinding(providerId: "deepseek"),
                maxTurns: 6,
                memory: "project",
                color: "purple",
                source: "captain-self-heal"),
            SpecialistDefinition(
                name: "self-heal-captain-gate",
                description: "Accepts or rejects a self-heal mission after research, implementation, independent review, and benchmarks produce evidence.",
                systemPrompt: """
                You are Kist's self-heal acceptance gate. Compare the mission against the evidence. Accept only when research, implementation, tests, review, and rollback path are coherent. If accepted, propose one Teach Captain rule; if rejected, write the next repair task.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                maxTurns: 5,
                memory: "project",
                color: "green",
                source: "captain-self-heal")
        ]
        let wanted = Set(assignments.map(\.specialistName))
        for def in defs where wanted.contains(def.name) && !existing.contains(def.name) {
            if (try? registry.save(def)) != nil { created += 1 }
        }
        return created
    }

    @discardableResult
    private func seedSelfHealTasks(weakness: SelfHealWeakness,
                                   objective: String,
                                   assignments: [SelfHealAgentAssignment],
                                   boardMeetingPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstAddedID: Int?
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String,
                 _ verification: String, _ evidence: [String] = []) {
            guard !selfHealTaskExists(title: title) else { return }
            let task = store.add(title: title,
                                 detail: detail,
                                 owner: owner,
                                 kind: kind,
                                 acceptance: acceptance,
                                 verification: verification,
                                 evidence: evidence)
            if firstAddedID == nil { firstAddedID = task.id }
            count += 1
        }

        add("PLAN: Captain self-heal mission -- \(weakness.title)", .plan, "captain",
            "Objective: \(objective)\nWeakness: \(weakness.reason)",
            "Weakness, assigned agents, gates, and rollback path are explicit.",
            "/self-heal shows the mission report and dispatch plan.",
            [boardMeetingPath])
        add("RESEARCH: Self-heal evidence scan -- \(weakness.title)", .research, "self-heal-researcher",
            assignments.first { $0.specialistName == "self-heal-researcher" }?.task ?? weakness.reason,
            "Primary sources, competitor/source comparison, and benchmark implications are attached.",
            "Attach research archive notes and source targets to this task.",
            weakness.supportingEvidence)
        add("ACTION: Implement highest-confidence self-heal fix", .action, "self-heal-builder",
            assignments.first { $0.specialistName == "self-heal-builder" }?.task ?? weakness.reason,
            "Implementation is scoped, reversible, and tied to the mission weakness.",
            "Run focused tests for the touched subsystem.",
            [])
        add("REVIEW: Independent AI review of self-heal fix", .review, "self-heal-critic",
            assignments.first { $0.specialistName == "self-heal-critic" }?.task ?? weakness.reason,
            "Review identifies blocking findings or explicitly clears the change with evidence.",
            "Attach reviewer findings and commands run.",
            [])
        add("TEST: Benchmark self-heal behavior", .test, "self-heal-captain-gate",
            weakness.benchmarkPlan,
            "Focused tests and the full suite pass, or failures are recorded as blockers.",
            "swift test; git diff --check",
            [])
        add("DECISION: Teach Captain or reject self-heal lesson", .decision, "self-heal-captain-gate",
            assignments.first { $0.specialistName == "self-heal-captain-gate" }?.task ?? weakness.teachableRule,
            "Captain either promotes the lesson with evidence or writes the next repair task.",
            "/teach add <lesson> only after research, implementation, review, and tests pass.",
            [])

        if activeBefore == nil, let firstAddedID {
            _ = store.update(id: firstAddedID, status: .inProgress)
        }
        return count
    }

    @discardableResult
    private func createSimulationSpecialists() -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        var created = 0
        let defs = [
            SpecialistDefinition(
                name: "simulation-architect",
                description: "Designs sandbox environments, probabilistic trial matrices, and verification evidence before real-world execution.",
                systemPrompt: """
                You are Kist's simulation architect. Before implementation reaches the real world, define the sandbox, assumptions, trial matrix, fake services or digital twin, success threshold, failure modes, and verification commands. Do not edit product code unless Captain explicitly assigns implementation elsewhere.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 6,
                memory: "project",
                color: "blue",
                source: "captain-simulation"),
            SpecialistDefinition(
                name: "risk-model-critic",
                description: "Critiques simulation assumptions, failure probabilities, blast radius, and accept/reject thresholds.",
                systemPrompt: """
                You are Kist's risk-model critic. Be skeptical of optimistic simulations. Look for missing failure modes, weak probability estimates, inadequate sandbox fidelity, and unsafe execution gates. Prefer concrete evidence and blocked recommendations over vague confidence.
                """,
                toolAllowlist: ["read_file", "search_code", "run_command", "tasks"],
                modelAlias: "inherit",
                permissionMode: "plan",
                maxTurns: 5,
                memory: "project",
                color: "purple",
                source: "captain-simulation")
        ]
        for def in defs where !existing.contains(def.name) {
            if (try? registry.save(def)) != nil { created += 1 }
        }
        return created
    }

    @discardableResult
    private func seedSimulationTasks(run: CaptainSimulationRun,
                                     reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstAddedID: Int?
        var count = 0
        let recommended = run.recommendedStrategy
        let commandProof = recommended.verificationCommands.isEmpty
            ? "Attach sandbox logs and trial evidence."
            : recommended.verificationCommands.joined(separator: "; ")

        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String,
                 _ verification: String, _ evidence: [String] = []) {
            guard !simulationTaskExists(title: title) else { return }
            let task = store.add(title: title,
                                 detail: detail,
                                 owner: owner,
                                 kind: kind,
                                 acceptance: acceptance,
                                 verification: verification,
                                 evidence: evidence)
            if firstAddedID == nil { firstAddedID = task.id }
            count += 1
        }

        add("PLAN: Simulation gate -- \(run.objective)", .plan, "captain",
            "Domain: \(run.domain.title). Recommended strategy: \(recommended.name). Decision: \(run.decision)",
            "Sandbox domain, risk threshold, strategy comparison, and rollback/evidence requirements are explicit.",
            "/simulate shows the simulation report and trial matrix.",
            [reportPath])
        add("RESEARCH: Define sandbox assumptions -- \(run.domain.title)", .research, "simulation-architect",
            "Document what the sandbox represents, what it does not represent, and which failure modes could escape it.",
            "Assumptions and known gaps are attached before the test task is marked done.",
            "Attach sandbox assumptions and failure-mode notes.",
            recommended.failureModes)
        add("TEST: Run probabilistic sandbox trials -- \(recommended.name)", .test, "simulation-architect",
            "Trial matrix: \(recommended.passedTrials)/\(recommended.trials) passed; estimated success \(recommended.estimatedSuccess)%; failure risk \(recommended.failureRisk)%.",
            "A repeatable sandbox trial log exists and the acceptance threshold is either met or explicitly blocked.",
            commandProof,
            [reportPath])
        add("TEST: Benchmark selected strategy -- \(recommended.name)", .test, "simulation-architect",
            "Convert the recommended strategy into a real benchmark/live-eval harness or a domain-specific experiment.",
            "Benchmark result can be retrieved later from Captain's benchmark memory.",
            commandProof,
            [Self.projectRelative(benchmarksPath, root: projectRoot)])
        add("REVIEW: Critique simulation risk model -- \(recommended.name)", .review, "risk-model-critic",
            "Challenge the probability estimate, sandbox fidelity, failure modes, and execution gate.",
            "Independent critique either clears the simulation gate or names blockers.",
            "Attach risk review notes and any commands run.",
            recommended.failureModes)
        add("DECISION: Execute or hold after simulation -- \(run.objective)", .decision, "captain",
            "Compare sandbox evidence, benchmark output, and risk critique before real execution.",
            "Captain either authorizes execution with evidence or holds the plan and writes the next research/simulation task.",
            "Do not execute until simulation, benchmark, review, and evidence tasks are done.",
            [reportPath])

        if activeBefore == nil, let firstAddedID {
            _ = store.update(id: firstAddedID, status: .inProgress)
        }
        return count
    }

    @discardableResult
    private func recordSimulationBenchmark(run: CaptainSimulationRun,
                                           reportPath: String,
                                           trajectory: [ActionRecord]) -> Int {
        let strategy = run.recommendedStrategy
        let measured = run.measuredTrials.map {
            "\($0.command): \($0.status.rawValue) exit=\($0.exitCode.map(String.init) ?? "n/a") elapsed=\(String(format: "%.2fs", $0.elapsedSeconds))"
        }.joined(separator: "; ")
        let record = DiskMemoryRecord(
            id: "simulation-\(run.id)",
            title: "Simulation Gate: \(run.objective)",
            summary: "\(run.domain.title): \(strategy.name) measured-adjusted \(run.estimatedSuccess)% success / \(run.failureRisk)% failure risk.",
            body: [
                "Decision: \(run.decision)",
                "Trials: \(strategy.passedTrials)/\(strategy.trials) passed",
                "Executable trials: \(measured.isEmpty ? "none" : measured)",
                "Expected value: \(strategy.expectedValue)%",
                "Failure modes: \(strategy.failureModes.joined(separator: "; "))",
                "Required evidence: \(strategy.requiredEvidence.joined(separator: "; "))",
            "Verification commands: \(strategy.verificationCommands.joined(separator: "; "))",
            "Trajectory tools observed: \(Set(trajectory.map(\.tool)).sorted().joined(separator: ", "))"
        ].joined(separator: "\n"),
            source: reportPath,
            confidence: run.estimatedSuccess,
            impact: min(5, max(1, strategy.expectedValue / 20)),
            tags: ["simulation-gate", run.domain.rawValue, "probabilistic-trials", "benchmark"]
        )
        return appendJSON(record, to: benchmarksPath) ? 1 : 0
    }

    private struct MeasuredSimulationCommand {
        var display: String
        var launchPath: String
        var launchArgs: [String]
    }

    private func runMeasuredSimulationTrials(run: CaptainSimulationRun,
                                             evidence: CaptainProjectEvidence,
                                             mode: CaptainSimulationMeasuredTrialMode) -> [CaptainSimulationMeasuredTrial] {
        guard run.domain == .software else { return [] }
        let commands = measuredSimulationCommandCandidates(run: run,
                                                           evidence: evidence,
                                                           mode: mode)
        guard !commands.isEmpty else { return [] }
        let timeout = mode == .preflight ? 20 : 120
        return commands.map {
            executeMeasuredSimulationCommand($0, timeoutSeconds: timeout)
        }
    }

    private func measuredSimulationCommandCandidates(run: CaptainSimulationRun,
                                                     evidence: CaptainProjectEvidence,
                                                     mode: CaptainSimulationMeasuredTrialMode) -> [MeasuredSimulationCommand] {
        let rawCommands: [String]
        switch mode {
        case .preflight:
            rawCommands = isGitRepository(projectRoot) ? ["git diff --check"] : []
        case .interactive:
            var commands = run.recommendedStrategy.verificationCommands
            if isGitRepository(projectRoot) { commands.append("git diff --check") }
            rawCommands = commands
        }

        var seen = Set<String>()
        var out: [MeasuredSimulationCommand] = []
        for command in rawCommands {
            let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, !seen.contains(clean) else { continue }
            seen.insert(clean)
            if let spec = measuredSimulationCommandSpec(clean, evidence: evidence) {
                out.append(spec)
            } else if mode == .interactive {
                out.append(MeasuredSimulationCommand(display: clean,
                                                     launchPath: "",
                                                     launchArgs: []))
            }
        }
        return out
    }

    private func measuredSimulationCommandSpec(_ command: String,
                                               evidence: CaptainProjectEvidence) -> MeasuredSimulationCommand? {
        let root = projectRoot
        switch command {
        case "git diff --check":
            guard isGitRepository(root), let git = trustedSimulationExecutable("git") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: git, launchArgs: ["diff", "--check"])
        case "./test.sh":
            let script = (root as NSString).appendingPathComponent("test.sh")
            guard let trustedScript = trustedProjectScript(script) else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: trustedScript, launchArgs: [])
        case "swift test":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Package.swift")),
                  let swift = trustedSimulationExecutable("swift") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: swift, launchArgs: ["test"])
        case "npm test":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("package.json")),
                  let npm = trustedSimulationExecutable("npm") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: npm, launchArgs: ["test"])
        case "cargo test":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("Cargo.toml")),
                  let cargo = trustedSimulationExecutable("cargo") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: cargo, launchArgs: ["test"])
        case "go test ./...":
            guard evidence.testEntrypoints.contains(command),
                  FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("go.mod")),
                  let go = trustedSimulationExecutable("go") else { return nil }
            return MeasuredSimulationCommand(display: command, launchPath: go, launchArgs: ["test", "./..."])
        default:
            return nil
        }
    }

    private func executeMeasuredSimulationCommand(_ command: MeasuredSimulationCommand,
                                                  timeoutSeconds: Int) -> CaptainSimulationMeasuredTrial {
        let started = Date()
        guard !command.launchPath.isEmpty else {
            return CaptainSimulationMeasuredTrial(command: command.display,
                                                  status: .skipped,
                                                  exitCode: nil,
                                                  timedOut: false,
                                                  elapsedSeconds: 0,
                                                  sandbox: "not executed",
                                                  outputExcerpt: "unsupported command for automatic sandbox execution")
        }
        let outcome = SandboxedProcessRunner.runRequired(
            launchPath: command.launchPath,
            launchArgs: command.launchArgs,
            root: projectRoot,
            cwd: projectRoot,
            env: simulationEnvironment(),
            timeoutSeconds: timeoutSeconds,
            capPerStream: 24_000)
        let elapsed = Date().timeIntervalSince(started)
        let status: CaptainSimulationMeasuredTrial.Status
        if outcome.timedOut {
            status = .timedOut
        } else if outcome.exitCode == 0 {
            status = .passed
        } else {
            status = .failed
        }
        return CaptainSimulationMeasuredTrial(command: command.display,
                                              status: status,
                                              exitCode: outcome.exitCode,
                                              timedOut: outcome.timedOut,
                                              elapsedSeconds: elapsed,
                                              sandbox: outcome.sandbox,
                                              outputExcerpt: Self.safe(String(outcome.combined.prefix(800))).singleLine)
    }

    private func isGitRepository(_ root: String) -> Bool {
        guard let git = trustedSimulationExecutable("git") else { return false }
        let outcome = SandboxedProcessRunner.runRequired(launchPath: git,
                                                         launchArgs: ["rev-parse", "--is-inside-work-tree"],
                                                         root: projectRoot,
                                                         cwd: root,
                                                         env: simulationEnvironment(),
                                                         timeoutSeconds: 5,
                                                         capPerStream: 2_000)
        return outcome.exitCode == 0 && outcome.combined.lowercased().contains("true")
    }

    private func trustedSimulationExecutable(_ name: String) -> String? {
        let candidates = [
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)"
        ]
        return candidates.compactMap { path -> String? in
            let resolved = (path as NSString).resolvingSymlinksInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir)
                && !isDir.boolValue
                && FileManager.default.isExecutableFile(atPath: resolved)
                && isTrustedSimulationExecutablePath(resolved) else { return nil }
            return resolved
        }.first
    }

    private func trustedProjectScript(_ path: String) -> String? {
        let root = (projectRoot as NSString).resolvingSymlinksInPath
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard resolved == (root as NSString).appendingPathComponent("test.sh"),
              resolved.hasPrefix(root + "/"),
              FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
        return resolved
    }

    private func isTrustedSimulationExecutablePath(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let root = (projectRoot as NSString).resolvingSymlinksInPath
        guard resolved != root, !resolved.hasPrefix(root + "/") else { return false }
        guard !resolved.hasPrefix("/tmp/"), !resolved.hasPrefix("/private/tmp/") else { return false }
        let allowedPrefixes = ["/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/"]
        return allowedPrefixes.contains { resolved.hasPrefix($0) }
    }

    private func simulationEnvironment() -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        let home = (projectRoot as NSString).appendingPathComponent(".kist/simulation-home")
        let tmp = (projectRoot as NSString).appendingPathComponent(".kist/simulation-tmp")
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "HOME": home,
            "TMPDIR": tmp
        ]
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "TERM"] {
            if let value = parent[key] { env[key] = value }
        }
        return env
    }

    private func selfHealTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    private func simulationTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    private func domainLearningTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    private func localModelScoutTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    private func seedLocalModelScoutTasks(objective: String,
                                          candidates: [LocalModelScoutCandidate],
                                          reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String] = []) {
            guard !localModelScoutTaskExists(title: title) else { return }
            store.add(title: title,
                      detail: detail,
                      owner: owner,
                      kind: kind,
                      acceptance: acceptance,
                      verification: verification,
                      evidence: evidence)
            count += 1
        }

        let candidateList = candidates.map {
            "\($0.modelID) (\($0.provider), score \($0.score))"
        }.joined(separator: "\n")
        add("RESEARCH: Safe local model scout -- \(objective)", .research, "local-model-scout",
            "Candidate matrix:\n\(candidateList)",
            "Each candidate has source/provenance, license, size, memory fit, template, risk, and eval gates.",
            "/model scout \(objective)",
            [reportPath])
        add("TEST: Local model onboarding gate -- \(objective)", .test, "local-model-scout",
            "Run inspect/onboard checks for the highest-scoring approved candidate without changing the default model.",
            "`kist --inspect-model` and `kist --onboard` pass, or the candidate is rejected with evidence.",
            "Attach inspect/onboard output and keep rollback to the current default model.",
            [reportPath])
        add("TEST: Local-vs-current benchmark -- \(objective)", .test, "local-model-scout",
            "Compare the approved local candidate against the current default/cloud baseline for this exact task family.",
            "Candidate only advances if `/bench` or `/eval` records repeated wins or an explicit low-risk offline benefit.",
            "/bench \(objective); /eval \(objective); /learning",
            [reportPath])
        add("DECISION: Promote or reject local model -- \(objective)", .decision, "captain",
            "Decide whether the candidate stays shadow-only, becomes a role-bound worker, or is rejected.",
            "Promotion includes task family, fallback model, benchmark evidence, and rollback path.",
            "/teach add <local model rule> | confidence: ... | evidence: \(reportPath)",
            [reportPath])
        return count
    }

    @discardableResult
    private func recordLocalModelScoutMemory(objective: String,
                                             candidates: [LocalModelScoutCandidate],
                                             reportPath: String) -> Int {
        let top = candidates.first
        let body = candidates.map {
            "\($0.modelID) via \($0.provider): score \($0.score), memory ~\($0.estimatedMemoryGB) GB, gates: \($0.licenseGate) \($0.templateGate)"
        }.joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-local-model-scout-\(Self.slug(objective).prefix(48))",
            title: "Safe Local Model Scout: \(objective)",
            summary: top.map { "Top candidate \($0.modelID) via \($0.provider), score \($0.score)." }
                ?? "No candidate selected.",
            body: body,
            source: reportPath,
            confidence: top?.score ?? 50,
            impact: 4,
            tags: ["local-model", "hugging-face", "mlx", "ollama", "model-scout"]
        )
        var records = loadJSONL(DiskMemoryRecord.self, path: knowledgeIndexPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        return saveJSONL(records, to: knowledgeIndexPath) ? 1 : 0
    }

    private func seedLiveModelMetadataGateTasks(spec: String,
                                                metadata: LiveModelMetadata?,
                                                decision: LiveModelMetadataDecision?,
                                                reportPath: String,
                                                manifestPath: String?,
                                                manifest: LocalModelAcquisitionManifest?,
                                                manifestWriteSucceeded: Bool,
                                                manifestWriteError: String?,
                                                fetchError: String?) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String] = []) {
            guard !localModelScoutTaskExists(title: title) else { return }
            store.add(title: title,
                      detail: detail,
                      owner: owner,
                      kind: kind,
                      acceptance: acceptance,
                      verification: verification,
                      evidence: evidence)
            count += 1
        }

        if decision?.accepted == true, manifestWriteSucceeded, let manifest, manifestPath != nil {
            let modelID = metadata?.modelID ?? spec
            let provider = metadata?.providerHint ?? "hf"
            let evidence = [reportPath, manifestPath].compactMap { $0 }
            add("ACTION: Verify acquisition manifest -- \(spec)", .action, "local-model-scout",
                "Metadata gate passed for \(modelID). Run the acquisition preflight before any dry-run/download command.",
                "The manifest policy hash, approval id, pinned commands, and target directory are verified by `/model acquire`.",
                "/model acquire \(manifestPath ?? "<manifest.json>")",
                evidence)
            add("TEST: Inspect approved local model -- \(spec)", .test, "local-model-scout",
                "Inspect chat template, stop tokens, and provider profile for \(provider):\(modelID) after `/model acquire` and sandbox download.",
                "`kist --inspect-model` identifies usable stops/template, or the candidate is rejected with evidence.",
                manifest.commands.inspect,
                evidence)
            add("TEST: Benchmark metadata-cleared model -- \(spec)", .test, "local-model-scout",
                "Run the candidate against the current default/cloud model for the exact task family before routing work.",
                "`/bench` or `/eval` records repeated wins or an explicit low-risk offline benefit.",
                manifest.commands.benchmark,
                evidence)
            add("DECISION: Promote or reject metadata-cleared model -- \(spec)", .decision, "captain",
                "Decide whether this model remains shadow-only, becomes a role-bound worker, or is rejected.",
                "Promotion includes task family, fallback model, benchmark evidence, rollback path, and Teach Captain rule if durable.",
                "/teach add <model routing lesson> | confidence: ... | evidence: \(reportPath)",
                evidence)
        } else if decision?.accepted == true {
            let blocker = manifestWriteError ?? "accepted metadata did not produce a persisted acquisition manifest"
            add("REVIEW: Resolve local model acquisition manifest persistence -- \(spec)", .review, "local-model-scout",
                "Do not download this candidate. Metadata passed, but the acquisition manifest was not written. Blocker: \(blocker)",
                "Re-run `/model vet` and confirm the JSON acquisition manifest is written before any download command is used.",
                "/model vet \(spec)",
                [reportPath])
        } else {
            let blockers = fetchError
                ?? decision?.reasons.joined(separator: "; ")
                ?? "metadata unavailable"
            add("REVIEW: Resolve local model metadata blockers -- \(spec)", .review, "local-model-scout",
                "Do not download this candidate. Blockers: \(blockers)",
                "The candidate is either replaced or re-run through `/model vet` with all license/provenance blockers cleared.",
                "/model vet \(spec)",
                [reportPath])
        }
        return count
    }

    @discardableResult
    private func recordLiveModelMetadataGateMemory(spec: String,
                                                   metadata: LiveModelMetadata?,
                                                   decision: LiveModelMetadataDecision?,
                                                   reportPath: String,
                                                   fetchError: String?) -> Int {
        let verdict = decision?.accepted == true ? "accepted" : "rejected"
        let reasons = decision?.reasons.joined(separator: "; ") ?? fetchError ?? "metadata unavailable"
        let warnings = decision?.warnings.joined(separator: "; ") ?? "none"
        let details = [
            "Spec: \(spec)",
            "Verdict: \(verdict)",
            "Source: \(metadata?.source.rawValue ?? "unknown")",
            "Model: \(metadata?.modelID ?? "unknown")",
            "Author: \(metadata?.author ?? "unknown")",
            "License: \(decision?.allowedLicense ?? metadata?.license ?? "unknown")",
            "SHA: \(metadata?.sha ?? "unknown")",
            "Reasons: \(reasons)",
            "Warnings: \(warnings)"
        ].joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-live-model-metadata-\(Self.slug(spec).prefix(48))",
            title: "Live Model Metadata Gate: \(spec)",
            summary: "\(verdict.uppercased()): \(metadata?.modelID ?? spec) -- \(reasons)",
            body: details,
            source: reportPath,
            confidence: decision?.accepted == true ? 82 : 70,
            impact: 4,
            tags: ["local-model", "metadata-gate", "license-gate", "provenance", metadata?.providerHint ?? "unknown"]
        )
        var records = loadJSONL(DiskMemoryRecord.self, path: knowledgeIndexPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        return saveJSONL(records, to: knowledgeIndexPath) ? 1 : 0
    }

    private func renderLocalModelAcquisitionPreflight(manifestPath: String,
                                                      manifest: LocalModelAcquisitionManifest?,
                                                      decision: LocalModelAcquisitionDecision,
                                                      reportPath: String,
                                                      seededTasks: Int,
                                                      memoryRecords: Int,
                                                      loadError: String?) -> String {
        var lines = [
            "# Local Model Acquisition Preflight",
            "",
            "Manifest: \(manifestPath)",
            "",
            "## Result",
            decision.accepted ? "VERIFIED: acquisition manifest is intact and policy-approved." : "REJECTED: acquisition manifest failed verification.",
            ""
        ]
        if let loadError {
            lines += ["Load error: \(loadError)", ""]
        }
        if let manifest {
            lines += [
                "Approval ID: \(manifest.approvalID)",
                "Policy: \(manifest.policyVersion)",
                "Model: \(manifest.modelID)",
                "Provider hint: \(manifest.providerHint)",
                "Source: \(manifest.sourceURL)",
                "License: \(manifest.license)",
                "Revision SHA: \(manifest.revisionSHA ?? "not applicable")",
                "Local directory: \(manifest.localDirectory)",
                ""
            ]
        }
        lines += ["Reasons:"]
        lines += decision.reasons.isEmpty ? ["- none"] : decision.reasons.map { "- \($0)" }
        lines += ["", "Warnings:"]
        lines += decision.warnings.isEmpty ? ["- none"] : decision.warnings.map { "- \($0)" }
        if decision.accepted, let manifest {
            lines += [
                "",
                "## Approved Command Set",
                "- dry-run: \(manifest.commands.dryRun ?? "not available")",
                "- download: \(manifest.commands.download ?? "not authorized by this manifest")",
                "- inspect: \(manifest.commands.inspect)",
                "- onboard: \(manifest.commands.onboard ?? "not available")",
                "- benchmark: \(manifest.commands.benchmark)",
                "",
                "## Hard Rule",
                "Run the dry-run first. Do not run any download command except the exact command above."
            ]
        } else {
            lines += [
                "",
                "## Hard Rule",
                "Do not download. Re-run `/model vet` and use a freshly verified acquisition manifest."
            ]
        }
        lines += [
            "",
            "## Artifacts",
            "Report: \(reportPath)",
            "Seeded tasks: \(seededTasks)",
            "Knowledge index records: \(memoryRecords)"
        ]
        return lines.joined(separator: "\n")
    }

    private func renderLocalModelAcquisitionRun(manifestPath: String,
                                                stage: LocalModelAcquisitionStage?,
                                                manifest: LocalModelAcquisitionManifest?,
                                                decision: LocalModelAcquisitionDecision,
                                                command: LocalModelAcquisitionRunnableCommand?,
                                                outcome: LocalModelAcquisitionRunOutcome?,
                                                dependencyBlockers: [LocalModelAcquisitionDependencyBlocker],
                                                artifactAttestation: LocalModelAcquisitionArtifactAttestation?,
                                                artifactAttestationPath: String?,
                                                reportPath: String,
                                                markerPath: String?,
                                                seededTasks: Int,
                                                memoryRecords: Int,
                                                loadError: String?) -> String {
        let resultLine: String
        if outcome?.succeeded == true, decision.accepted {
            resultLine = "PASS: acquisition stage completed and evidence was recorded."
        } else if outcome?.succeeded == true {
            resultLine = "FAIL: acquisition stage command ran, but post-run gates failed."
        } else if outcome != nil {
            resultLine = "FAIL: acquisition stage command ran but did not pass."
        } else if decision.accepted {
            resultLine = "READY: acquisition stage is approved but did not run."
        } else {
            resultLine = "BLOCKED: acquisition stage was not allowed to run."
        }
        var lines = [
            "# Local Model Acquisition Run",
            "",
            "Manifest: \(manifestPath)",
            "Stage: \(stage?.rawValue ?? "unknown")",
            "",
            "## Result",
            resultLine,
            ""
        ]
        if let loadError {
            lines += ["Load error: \(loadError)", ""]
        }
        if let manifest {
            lines += [
                "Approval ID: \(manifest.approvalID)",
                "Policy hash: \(manifest.policyHash)",
                "Model: \(manifest.modelID)",
                "Provider hint: \(manifest.providerHint)",
                "Local directory: \(manifest.localDirectory)",
                ""
            ]
        }
        lines += ["Reasons:"]
        lines += decision.reasons.isEmpty ? ["- none"] : decision.reasons.map { "- \($0)" }
        lines += ["", "Warnings:"]
        lines += decision.warnings.isEmpty ? ["- none"] : decision.warnings.map { "- \($0)" }
        if !dependencyBlockers.isEmpty {
            lines += ["", "## Dependency Preflight"]
            for blocker in dependencyBlockers {
                lines += [
                    "",
                    "Missing: \(blocker.executable)",
                    "Reason: \(blocker.reason)",
                    "Setup: \(blocker.setupCommand)",
                    "Verify: \(blocker.verifyCommand)"
                ]
            }
        }
        if let artifactAttestation {
            lines += [
                "",
                "## Artifact Attestation",
                artifactAttestation.accepted ? "PASS: local artifacts match the manifest gate." : "BLOCKED: local artifacts failed the manifest gate.",
                "",
                "Path: \(artifactAttestationPath ?? "not written")",
                "Required files: \(artifactAttestation.requiredFilesPresent ? "present" : "missing")",
                "Files scanned: \(artifactAttestation.fileCount)",
                "Total size: \(LiveModelMetadataGate.formatBytes(artifactAttestation.totalBytes))",
                "",
                "Blockers:"
            ]
            lines += artifactAttestation.blockers.isEmpty ? ["- none"] : artifactAttestation.blockers.map { "- \($0)" }
            lines += ["", "Warnings:"]
            lines += artifactAttestation.warnings.isEmpty ? ["- none"] : artifactAttestation.warnings.map { "- \($0)" }
            if !artifactAttestation.sampledFiles.isEmpty {
                lines += ["", "Files sampled:"]
                lines += artifactAttestation.sampledFiles.prefix(20).map {
                    "- \($0.path) (\(LiveModelMetadataGate.formatBytes($0.bytes)))"
                }
                if artifactAttestation.sampledFiles.count > 20 {
                    lines.append("- ... +\(artifactAttestation.sampledFiles.count - 20) more")
                }
            }
        }
        if let command {
            lines += [
                "",
                "## Manifest Command",
                command.manifestCommand,
                "",
                "## Structured Invocation"
            ]
            for invocation in command.invocations {
                lines.append("- \(invocation.label): \(invocation.display)")
            }
        }
        if let outcome {
            lines += ["", "## Command Output"]
            for result in outcome.results {
                lines += [
                    "",
                    "### \(result.label)",
                    "Command: \(result.command)",
                    "Exit: \(result.exitCode)\(result.timedOut ? " (timed out)" : "")",
                    "Stdout:",
                    Self.trimCommandOutput(result.stdout),
                    "Stderr:",
                    Self.trimCommandOutput(result.stderr)
                ]
            }
        } else {
            lines += [
                "",
                "## Command Output",
                "No command executed."
            ]
        }
        lines += [
            "",
            "## Artifacts",
            "Report: \(reportPath)",
            "Success marker: \(markerPath ?? "not written")",
            "Artifact attestation: \(artifactAttestationPath ?? "not written")",
            "Seeded tasks: \(seededTasks)",
            "Knowledge index records: \(memoryRecords)"
        ]
        return lines.joined(separator: "\n")
    }

    private func localModelAcquisitionStageBlockers(stage: LocalModelAcquisitionStage,
                                                    manifest: LocalModelAcquisitionManifest) -> [String] {
        var blockers: [String] = []
        let isHF = manifest.source == LiveModelMetadata.Source.huggingFace.rawValue
        switch stage {
        case .dryRun:
            break
        case .download:
            if !localModelAcquisitionStagePassed(.dryRun, manifest: manifest) {
                blockers.append("download requires a successful dry-run marker for the same approvalID and policyHash")
            }
        case .inspect:
            let downloadPassed = localModelAcquisitionStagePassed(.download, manifest: manifest)
            if isHF && !downloadPassed {
                blockers.append("inspect requires a successful download marker for the same approvalID and policyHash")
            } else if isHF && !localModelAcquisitionArtifactAttestationPassed(manifest: manifest) {
                blockers.append("inspect requires a successful local artifact attestation for the same approvalID and policyHash")
            }
        case .onboard:
            if !localModelAcquisitionStagePassed(.inspect, manifest: manifest) {
                blockers.append("onboard requires a successful inspect marker for the same approvalID and policyHash")
            }
        case .benchmark:
            if !localModelAcquisitionStagePassed(.onboard, manifest: manifest) {
                blockers.append("benchmark requires a successful onboard marker for the same approvalID and policyHash")
            }
        }
        return blockers
    }

    private func localModelAcquisitionArtifactAttestationPath(_ manifest: LocalModelAcquisitionManifest) -> String {
        localModelsRoot + "/\(Self.slug(manifest.approvalID + "-download-artifacts")).json"
    }

    private func localModelAcquisitionArtifactAttestationPassed(manifest: LocalModelAcquisitionManifest) -> Bool {
        let path = localModelAcquisitionArtifactAttestationPath(manifest)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let attestation = try? JSONDecoder().decode(LocalModelAcquisitionArtifactAttestation.self, from: data) else {
            return false
        }
        guard attestation.accepted
            && attestation.approvalID == manifest.approvalID
            && attestation.policyHash == manifest.policyHash
            && attestation.modelID == manifest.modelID
            && attestation.localDirectory == manifest.localDirectory
            && attestation.revisionSHA == manifest.revisionSHA
            && ForgeSeal.verify(localModelAcquisitionArtifactAttestationCanonical(attestation),
                                seal: attestation.seal ?? "") else {
            return false
        }
        var current = makeLocalModelAcquisitionArtifactAttestation(manifest: manifest)
        current.createdAt = attestation.createdAt
        current.seal = attestation.seal
        return current == attestation
    }

    private func makeLocalModelAcquisitionArtifactAttestation(manifest: LocalModelAcquisitionManifest) -> LocalModelAcquisitionArtifactAttestation {
        let fm = FileManager.default
        let rootPath = (projectRoot as NSString).resolvingSymlinksInPath
        let modelsPath = (rootPath as NSString).appendingPathComponent(".kist/models")
        let localPath = (rootPath as NSString).appendingPathComponent(manifest.localDirectory)
        let resolvedModelsPath = (modelsPath as NSString).resolvingSymlinksInPath
        let resolvedLocalPath = (localPath as NSString).resolvingSymlinksInPath
        var blockers: [String] = []
        var warnings: [String] = []
        var files: [LocalModelAcquisitionArtifactFile] = []
        var seen = Set<String>()
        var totalBytes: Int64 = 0

        if Self.isSymbolicLink(rootPath + "/.kist") {
            blockers.append(".kist is a symbolic link")
        }
        if Self.isSymbolicLink(modelsPath) {
            blockers.append(".kist/models is a symbolic link")
        }
        if resolvedLocalPath != resolvedModelsPath && !resolvedLocalPath.hasPrefix(resolvedModelsPath + "/") {
            blockers.append("local directory is outside .kist/models")
        }

        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: localPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
            blockers.append("local directory does not exist")
        } else if Self.isSymbolicLink(localPath) {
            blockers.append("local directory is a symbolic link")
        } else if let enumerator = fm.enumerator(atPath: localPath) {
            let expected = Set(manifest.fileNames.filter { !$0.hasPrefix(".cache/") })
            for case let relative as String in enumerator {
                guard Self.isSafeLocalModelArtifactPath(relative) else {
                    blockers.append("unsafe artifact path '\(relative)'")
                    continue
                }
                let fullPath = localPath + "/" + relative
                if Self.isSymbolicLink(fullPath) {
                    blockers.append("symbolic link artifact '\(relative)'")
                    continue
                }
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let type = attrs[.type] as? FileAttributeType else {
                    warnings.append("could not inspect artifact '\(relative)'")
                    continue
                }
                if type == .typeDirectory {
                    continue
                }
                if relative.hasPrefix(".cache/") {
                    continue
                }
                if !expected.contains(relative) {
                    blockers.append("unexpected artifact file '\(relative)'")
                    continue
                }
                guard Self.isAllowedLocalModelArtifactFile(relative) else {
                    blockers.append("unsafe artifact file type '\(relative)'")
                    continue
                }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                if let expectedSize = manifest.fileSizes[relative], size != expectedSize {
                    blockers.append("artifact size mismatch for '\(relative)': expected \(expectedSize), got \(size)")
                    continue
                }
                let hash: String
                do {
                    hash = try MythosCrypto.sha256File(path: fullPath).map { String(format: "%02x", $0) }.joined()
                } catch {
                    blockers.append("could not hash artifact '\(relative)'")
                    continue
                }
                totalBytes += size
                seen.insert(relative)
                files.append(LocalModelAcquisitionArtifactFile(path: relative, bytes: size, sha256: hash))
            }
        }

        let expected = manifest.fileNames.filter { !$0.hasPrefix(".cache/") }
        let missing = expected.filter { !seen.contains($0) }
        if !missing.isEmpty {
            blockers.append("missing manifest file(s): \(Self.joinSample(missing, limit: 8))")
        }
        if files.isEmpty {
            blockers.append("no local model artifacts were found")
        }
        if let expectedBytes = manifest.storageBytes {
            let tolerance = max(Int64(64 * 1_048_576), expectedBytes / 10)
            if totalBytes > expectedBytes + tolerance {
                blockers.append("local artifacts exceed approved storage size")
            }
        } else {
            warnings.append("manifest storage size unavailable; total local bytes recorded without size comparison")
        }

        blockers = Self.unique(blockers)
        warnings = Self.unique(warnings)
        var attestation = LocalModelAcquisitionArtifactAttestation(
            approvalID: manifest.approvalID,
            policyHash: manifest.policyHash,
            modelID: manifest.modelID,
            revisionSHA: manifest.revisionSHA,
            localDirectory: manifest.localDirectory,
            createdAt: now().timeIntervalSince1970,
            accepted: blockers.isEmpty,
            requiredFilesPresent: missing.isEmpty,
            fileCount: files.count,
            totalBytes: totalBytes,
            sampledFiles: files.sorted { $0.path < $1.path }.prefix(50).map { $0 },
            blockers: blockers,
            warnings: warnings,
            seal: nil)
        attestation.seal = ForgeSeal.sign(localModelAcquisitionArtifactAttestationCanonical(attestation))
        return attestation
    }

    private func localModelAcquisitionArtifactAttestationCanonical(_ attestation: LocalModelAcquisitionArtifactAttestation) -> String {
        let files = attestation.sampledFiles
            .sorted { $0.path < $1.path }
            .map { "\(ForgeSeal.field($0.path)):\($0.bytes):\(ForgeSeal.field($0.sha256))" }
            .joined(separator: ",")
        return [
            "approval=\(ForgeSeal.field(attestation.approvalID))",
            "policy=\(ForgeSeal.field(attestation.policyHash))",
            "model=\(ForgeSeal.field(attestation.modelID))",
            "revision=\(ForgeSeal.field(attestation.revisionSHA ?? ""))",
            "local=\(ForgeSeal.field(attestation.localDirectory))",
            "createdAt=\(attestation.createdAt)",
            "accepted=\(attestation.accepted ? "1" : "0")",
            "required=\(attestation.requiredFilesPresent ? "1" : "0")",
            "count=\(attestation.fileCount)",
            "bytes=\(attestation.totalBytes)",
            "files=\(files)",
            "blockers=\(attestation.blockers.map(ForgeSeal.field).joined(separator: ","))",
            "warnings=\(attestation.warnings.map(ForgeSeal.field).joined(separator: ","))"
        ].joined(separator: "|")
    }

    private func writeLocalModelAcquisitionArtifactAttestation(_ attestation: LocalModelAcquisitionArtifactAttestation,
                                                               manifest: LocalModelAcquisitionManifest) -> String? {
        let path = localModelAcquisitionArtifactAttestationPath(manifest)
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(attestation)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            return Self.projectRelative(path, root: projectRoot)
        } catch {
            return nil
        }
    }

    private static func isSafeLocalModelArtifactPath(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.contains(".."),
              !value.contains("\0"),
              !value.contains("\\") else { return false }
        return true
    }

    private static func isAllowedLocalModelArtifactFile(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent.lowercased()
        if [".gitattributes", "license", "notice"].contains(name) { return true }
        let ext = (name as NSString).pathExtension
        return ["json", "txt", "md", "safetensors", "gguf", "model", "tiktoken"].contains(ext)
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    private static func joinSample(_ values: [String], limit: Int) -> String {
        let prefix = values.prefix(limit).joined(separator: ", ")
        if values.count > limit {
            return "\(prefix), +\(values.count - limit) more"
        }
        return prefix
    }

    private struct LocalModelAcquisitionStageMarker: Codable, Equatable, Sendable {
        var approvalID: String
        var policyHash: String
        var stage: String
        var command: String
        var reportPath: String
        var succeeded: Bool
        var createdAt: Double
        var seal: String?
    }

    private func localModelAcquisitionStageMarkerPath(_ stage: LocalModelAcquisitionStage,
                                                      manifest: LocalModelAcquisitionManifest) -> String {
        localModelsRoot + "/\(Self.slug(manifest.approvalID + "-" + stage.rawValue)).passed.json"
    }

    private func localModelAcquisitionStagePassed(_ stage: LocalModelAcquisitionStage,
                                                  manifest: LocalModelAcquisitionManifest) -> Bool {
        let path = localModelAcquisitionStageMarkerPath(stage, manifest: manifest)
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let marker = try? JSONDecoder().decode(LocalModelAcquisitionStageMarker.self, from: data) else {
            return false
        }
        let reportPath = (projectRoot as NSString).appendingPathComponent(marker.reportPath)
        return marker.succeeded
            && marker.approvalID == manifest.approvalID
            && marker.policyHash == manifest.policyHash
            && marker.stage == stage.rawValue
            && FileManager.default.fileExists(atPath: reportPath)
            && ForgeSeal.verify(localModelAcquisitionStageMarkerCanonical(marker),
                                seal: marker.seal ?? "")
    }

    private func writeLocalModelAcquisitionStageMarker(stage: LocalModelAcquisitionStage,
                                                       manifest: LocalModelAcquisitionManifest,
                                                       command: String,
                                                       reportPath: String) -> String? {
        let path = localModelAcquisitionStageMarkerPath(stage, manifest: manifest)
        var marker = LocalModelAcquisitionStageMarker(approvalID: manifest.approvalID,
                                                      policyHash: manifest.policyHash,
                                                      stage: stage.rawValue,
                                                      command: command,
                                                      reportPath: reportPath,
                                                      succeeded: true,
                                                      createdAt: now().timeIntervalSince1970,
                                                      seal: nil)
        marker.seal = ForgeSeal.sign(localModelAcquisitionStageMarkerCanonical(marker))
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(marker)
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
            return Self.projectRelative(path, root: projectRoot)
        } catch {
            return nil
        }
    }

    private func localModelAcquisitionStageMarkerCanonical(_ marker: LocalModelAcquisitionStageMarker) -> String {
        [
            "approval=\(ForgeSeal.field(marker.approvalID))",
            "policy=\(ForgeSeal.field(marker.policyHash))",
            "stage=\(ForgeSeal.field(marker.stage))",
            "command=\(ForgeSeal.field(marker.command))",
            "report=\(ForgeSeal.field(marker.reportPath))",
            "succeeded=\(marker.succeeded ? "1" : "0")",
            "createdAt=\(marker.createdAt)"
        ].joined(separator: "|")
    }

    private func seedLocalModelAcquisitionPreflightTasks(manifestPath: String,
                                                        manifest: LocalModelAcquisitionManifest?,
                                                        decision: LocalModelAcquisitionDecision,
                                                        reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String]) {
            guard !localModelScoutTaskExists(title: title) else { return }
            store.add(title: title,
                      detail: detail,
                      owner: owner,
                      kind: kind,
                      acceptance: acceptance,
                      verification: verification,
                      evidence: evidence)
            count += 1
        }

        let evidence = [reportPath, manifestPath]
        if decision.accepted, let manifest {
            add("ACTION: Run local model acquisition dry-run -- \(manifest.approvalID)", .action, "local-model-scout",
                "Execute only the manifest dry-run command and compare expected files, size, local directory, source, and revision.",
                "Dry-run completes without changing the default model and confirms the pinned revision/local directory.",
                manifest.commands.dryRun ?? "ollama show \(manifest.modelID)",
                evidence)
            if let download = manifest.commands.download {
                add("ACTION: Download manifest-approved local model -- \(manifest.approvalID)", .action, "local-model-scout",
                    "Download only after the dry-run passes, using the exact manifest command.",
                    "Model files land under \(manifest.localDirectory); no default routing changes happen during download.",
                    download,
                    evidence)
            }
            add("TEST: Inspect/onboard manifest-approved local model -- \(manifest.approvalID)", .test, "local-model-scout",
                "Inspect template/stops and run onboarding before any worker can route to this model.",
                "`kist --inspect-model` and onboarding evidence are attached, or the model is rejected.",
                [manifest.commands.inspect, manifest.commands.onboard].compactMap { $0 }.joined(separator: " && "),
                evidence)
            add("DECISION: Promote or reject manifest-approved local model -- \(manifest.approvalID)", .decision, "captain",
                "Decide whether the model remains shadow-only, becomes role-bound, or is rejected.",
                "Decision includes benchmark/eval evidence, rollback path, and a Teach Captain rule only if durable.",
                manifest.commands.benchmark,
                evidence)
        } else {
            let blockers = decision.reasons.joined(separator: "; ")
            add("REVIEW: Reject or repair local model acquisition manifest -- \(manifestPath)", .review, "local-model-scout",
                "Do not download from this manifest. Blockers: \(blockers)",
                "A fresh `/model vet` manifest is generated and passes `/model acquire` before any download command is used.",
                "/model vet <spec> && /model acquire <manifest.json>",
                [reportPath])
        }
        return count
    }

    private func seedLocalModelAcquisitionRunTasks(manifestPath: String,
                                                   manifest: LocalModelAcquisitionManifest?,
                                                   stage: LocalModelAcquisitionStage?,
                                                   decision: LocalModelAcquisitionDecision,
                                                   dependencyBlockers: [LocalModelAcquisitionDependencyBlocker],
                                                   artifactAttestation: LocalModelAcquisitionArtifactAttestation?,
                                                   artifactAttestationPath: String?,
                                                   reportPath: String) -> Int {
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        func add(_ title: String, _ kind: PlanTask.Kind, _ owner: String,
                 _ detail: String, _ acceptance: String, _ verification: String,
                 _ evidence: [String]) {
            guard !localModelScoutTaskExists(title: title) else { return }
            store.add(title: title,
                      detail: detail,
                      owner: owner,
                      kind: kind,
                      acceptance: acceptance,
                      verification: verification,
                      evidence: evidence)
            count += 1
        }
        guard let manifest, let stage else { return 0 }
        let evidence = [reportPath, manifestPath]
        if !dependencyBlockers.isEmpty {
            for blocker in dependencyBlockers {
                add("ACTION: Install local model acquisition dependency -- \(blocker.executable)", .action, "local-model-scout",
                    "Install the missing executable before retrying the \(stage.rawValue) stage. Reason: \(blocker.reason)",
                    "`\(blocker.verifyCommand)` succeeds and the acquisition stage can be retried without dependency blockers.",
                    "\(blocker.setupCommand) && \(blocker.verifyCommand)",
                    evidence)
            }
        } else if stage == .download, let artifactAttestation, !artifactAttestation.accepted {
            let blockerText = artifactAttestation.blockers.joined(separator: "; ")
            add("REVIEW: Repair local model artifact attestation -- \(manifest.approvalID)", .review, "local-model-scout",
                "The download command ran, but artifact attestation blocked promotion. Blockers: \(blockerText)",
                "Local files match the manifest, unsafe artifacts are removed, and `/model run download \(manifestPath)` writes both attestation and success marker.",
                "/model run download \(manifestPath)",
                evidence + [artifactAttestationPath].compactMap { $0 })
        } else if decision.accepted {
            switch stage {
            case .dryRun:
                if let download = manifest.commands.download {
                    add("ACTION: Download manifest-approved local model -- \(manifest.approvalID)", .action, "local-model-scout",
                        "The dry-run passed; download may now run, but only through the manifest runner.",
                        "Download completes into \(manifest.localDirectory) and records a matching success marker.",
                        "/model run download \(manifestPath)",
                        evidence + [download])
                }
            case .download:
                add("TEST: Inspect manifest-approved local model -- \(manifest.approvalID)", .test, "local-model-scout",
                    "The download passed; inspect the template/stops before onboarding.",
                    "Inspect command passes and records a matching success marker.",
                    "/model run inspect \(manifestPath)",
                    evidence + [manifest.commands.inspect])
            case .inspect:
                if manifest.commands.onboard != nil {
                    add("TEST: Onboard manifest-approved local model -- \(manifest.approvalID)", .test, "local-model-scout",
                        "The inspect stage passed; run onboarding before any worker can use the model.",
                        "Onboarding passes and records a matching success marker.",
                        "/model run onboard \(manifestPath)",
                        evidence)
                }
            case .onboard:
                add("DECISION: Benchmark/promote manifest-approved local model -- \(manifest.approvalID)", .decision, "captain",
                    "Onboarding passed; compare this model against the current default before promotion.",
                    "Benchmark/eval evidence supports a role-bound promotion, shadow-only status, or rejection.",
                    "/model run benchmark \(manifestPath)",
                    evidence + [manifest.commands.benchmark])
            case .benchmark:
                add("DECISION: Teach or reject local model promotion -- \(manifest.approvalID)", .decision, "captain",
                    "Benchmarking completed; promote only if evidence beats the current route for a specific role.",
                    "A Teach Captain rule exists for the role binding, or rejection rationale is recorded.",
                    "/teach local model \(manifest.modelID) only after benchmark evidence supports a role-bound route",
                    evidence)
            }
        } else {
            add("REVIEW: Repair blocked local model acquisition stage -- \(manifest.approvalID)", .review, "local-model-scout",
                "Stage \(stage.rawValue) did not run. Blockers: \(decision.reasons.joined(separator: "; "))",
                "The missing prior marker, manifest issue, or command failure is repaired before retry.",
                "/model acquire \(manifestPath)",
                evidence)
        }
        return count
    }

    @discardableResult
    private func recordLocalModelAcquisitionPreflightMemory(manifestPath: String,
                                                           manifest: LocalModelAcquisitionManifest?,
                                                           decision: LocalModelAcquisitionDecision,
                                                           reportPath: String,
                                                           loadError: String?) -> Int {
        let verdict = decision.accepted ? "verified" : "rejected"
        let reasons = decision.reasons.isEmpty ? "none" : decision.reasons.joined(separator: "; ")
        let details = [
            "Manifest: \(manifestPath)",
            "Verdict: \(verdict)",
            "Model: \(manifest?.modelID ?? "unknown")",
            "Approval ID: \(manifest?.approvalID ?? "none")",
            "Policy: \(manifest?.policyVersion ?? "unknown")",
            "Reasons: \(reasons)",
            "Load error: \(loadError ?? "none")"
        ].joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-local-model-acquire-\(Self.slug(manifest?.approvalID ?? manifestPath).prefix(48))",
            title: "Local Model Acquisition Preflight: \(manifest?.modelID ?? manifestPath)",
            summary: "\(verdict.uppercased()): \(manifest?.modelID ?? manifestPath) -- \(reasons)",
            body: details,
            source: reportPath,
            confidence: decision.accepted ? 88 : 72,
            impact: 4,
            tags: ["local-model", "acquisition-manifest", "download-gate", manifest?.providerHint ?? "unknown"]
        )
        var records = loadJSONL(DiskMemoryRecord.self, path: knowledgeIndexPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        return saveJSONL(records, to: knowledgeIndexPath) ? 1 : 0
    }

    private func recordLocalModelAcquisitionRunMemory(manifestPath: String,
                                                      manifest: LocalModelAcquisitionManifest?,
                                                      stage: LocalModelAcquisitionStage?,
                                                      decision: LocalModelAcquisitionDecision,
                                                      reportPath: String) -> Int {
        let verdict = decision.accepted ? "passed" : "blocked"
        let title = "Local model acquisition \(stage?.rawValue ?? "unknown") \(verdict): \(manifest?.modelID ?? manifestPath)"
        let body = [
            "Manifest: \(manifestPath)",
            "Report: \(reportPath)",
            "Approval: \(manifest?.approvalID ?? "none")",
            "Stage: \(stage?.rawValue ?? "unknown")",
            "Reasons: \(decision.reasons.isEmpty ? "none" : decision.reasons.joined(separator: "; "))"
        ].joined(separator: "\n")
        let record = DiskMemoryRecord(
            id: "AA-local-model-run-\(Self.slug((manifest?.approvalID ?? manifestPath) + "-" + (stage?.rawValue ?? "unknown")).prefix(48))",
            title: title,
            summary: "\(verdict.uppercased()): \(stage?.rawValue ?? "unknown") -- \(manifest?.modelID ?? manifestPath)",
            body: body,
            source: reportPath,
            confidence: decision.accepted ? 88 : 72,
            impact: 4,
            tags: ["local-model", "acquisition-run", stage?.rawValue ?? "unknown", manifest?.providerHint ?? "unknown"]
        )
        var records = loadJSONL(DiskMemoryRecord.self, path: knowledgeIndexPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        return saveJSONL(records, to: knowledgeIndexPath) ? 1 : 0
    }

    private func preferredModelHint(for specialistName: String) -> String {
        let lower = specialistName.lowercased()
        if lower.contains("critic") || lower.contains("security") || lower.contains("risk") { return "deepseek" }
        if lower.contains("research") || lower.contains("strategic") || lower.contains("domain") { return "gemini or strongest research model" }
        if lower.contains("swift") || lower.contains("frontend") || lower.contains("symbolic") { return "MiMo" }
        if lower.contains("learning") || lower.contains("eval") || lower.contains("benchmark") { return "best benchmark-proven model" }
        return "inherit from Captain assignment"
    }

    private func domainObjectiveNeedsLocalModel(_ lower: String) -> Bool {
        Self.containsAny(lower, ["hugging face", "huggingface", "hf ", "local model", "small model",
                                  "mlx", "ollama", "gguf", "quantization", "download model",
                                  "onboard model", "offline model"])
    }

    private func domainObjectiveNeedsSymbolicRules(_ lower: String) -> Bool {
        Self.containsAny(lower, ["symbolic", "rulebook", "deterministic", "workflow gate",
                                  "compile workflow", "reuse", "permanent rule", "organizational rule"])
    }

    private func renderSelfHealMission(objective: String,
                                       weakness: SelfHealWeakness,
                                       assignments: [SelfHealAgentAssignment],
                                       boardMeeting: EvolutionBoardReport,
                                       seededTasks: Int,
                                       createdSpecialists: Int,
                                       dispatchCommand: String) -> String {
        var lines = [
            "# Captain Self-Heal Mission",
            "",
            "Objective: \(objective)",
            "",
            "## Diagnosed Weakness",
            weakness.title,
            "",
            "Reason: \(weakness.reason)",
            "",
            "Supporting evidence:",
        ]
        lines += weakness.supportingEvidence.map { "- \($0)" }
        lines += [
            "",
            "## Agent Dispatch",
        ]
        for assignment in assignments {
            lines += [
                "- \(assignment.specialistName) -- \(assignment.role)",
                "  Preferred model: \(assignment.preferredModel)",
                "  Task: \(assignment.task.replacingOccurrences(of: "\n", with: "\n  "))",
            ]
        }
        lines += [
            "",
            "## Acceptance Gate",
            "- Research evidence is attached before implementation hardens.",
            "- Builder changes are scoped and reversible.",
            "- Independent critic review either clears the change or blocks it.",
            "- Benchmarks/tests pass before acceptance.",
            "- Teach Captain promotes the lesson only after evidence.",
            "",
            "Benchmark plan: \(weakness.benchmarkPlan)",
            "Teachable rule candidate: \(weakness.teachableRule)",
            "",
            "## Dispatch",
            "Run now: \(dispatchCommand)",
            "Manual sequence:",
        ]
        lines += assignments.map { "- /agents run \($0.specialistName) \($0.task.singleLine)" }
        lines += [
            "",
            "## Artifacts",
            "Board meeting: \(boardMeeting.path)",
            "Seeded self-heal tasks: \(seededTasks)",
            "Created self-heal specialists: \(createdSpecialists)",
            "Promoted rules during board meeting: \(boardMeeting.promotedRules)",
        ]
        return lines.joined(separator: "\n")
    }

    private func strategyObjective(plan: Plan) -> String {
        if let active = plan.active { return active.boardTitle + " -- " + active.detail }
        if let next = plan.next { return next.boardTitle + " -- " + next.detail }
        if let lastDone = plan.tasks.filter({ $0.status == .done }).last {
            return lastDone.boardTitle + " -- " + lastDone.detail
        }
        return plan.title
    }

    private func createMissingSpecialists(_ specialists: [SpecialistDefinition]) -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        var count = 0
        for specialist in specialists.prefix(6) where !existing.contains(specialist.name) {
            if (try? registry.save(specialist)) != nil { count += 1 }
        }
        return count
    }

    private func memoryCandidates() -> [CaptainMemoryCandidate] {
        var out: [CaptainMemoryCandidate] = []
        out += permanentRules(limit: 80).map { rule in
            CaptainMemoryCandidate(
                layerID: .organizationalRules,
                recordID: rule.id,
                title: "Rule: \(rule.lesson)",
                excerpt: excerpt("Lesson: \(rule.lesson). Reason: \(rule.reason). Evidence: \(rule.evidence.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(rulesPath, root: projectRoot),
                baseRelevance: max(20, rule.confidence / 2)
            )
        }
        out += openKnowledgeDebt(limit: 80).map { debt in
            CaptainMemoryCandidate(
                layerID: .knowledgeIndex,
                recordID: debt.id,
                title: "Knowledge Debt: \(debt.topic)",
                excerpt: excerpt("Reason: \(debt.reason). Visit: \(debt.visit). Expected benefit: \(debt.expectedBenefit.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(debtPath, root: projectRoot),
                baseRelevance: 8 + debt.impact * 6
            )
        }
        out += capsules(limit: 80).map { capsule in
            CaptainMemoryCandidate(
                layerID: .projectHistory,
                recordID: capsule.id,
                title: "History: \(capsule.taskTitle)",
                excerpt: excerpt("Status: \(capsule.status.rawValue). Summary: \(capsule.summary). Learned: \(capsule.learned.joined(separator: "; ")). Surprises: \(capsule.surprises.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(capsulesPath, root: projectRoot),
                baseRelevance: capsule.status == .pass ? 12 : 18
            )
        }
        out += captainLearningBenchmarkCandidates(limit: 80)
        out += evidenceLedgerCandidates(limit: 80)
        out += genericMemoryCandidates(path: knowledgeIndexPath, layerID: .knowledgeIndex, base: 18)
        out += genericMemoryCandidates(path: industryIntelligencePath, layerID: .industryIntelligence, base: 14)
        out += genericMemoryCandidates(path: evolutionProposalsPath, layerID: .knowledgeIndex, base: 22)
        out += genericMemoryCandidates(path: benchmarksPath, layerID: .benchmarks, base: 18)
        out += researchArchiveCandidates(limit: 40)
        return dedupe(out)
    }

    private func evidenceLedgerCandidates(limit: Int) -> [CaptainMemoryCandidate] {
        evidenceLedger(limit: limit).map { record in
            let taskIDs = record.taskIDs.isEmpty
                ? "none"
                : record.taskIDs.map(String.init).joined(separator: ", ")
            let memoryStatus = record.memoryRecorded ? "indexed" : "not indexed"
            let excerptText = """
            Durable specialist evidence. Kind: \(record.kind.rawValue). Objective: \(record.objective). Specialist: \(record.specialistName). Role: \(record.role). Preferred model: \(record.preferredModel). Artifact: \(record.artifactPath). Memory: \(memoryStatus). Task IDs: \(taskIDs). Task evidence updated: \(record.taskEvidenceUpdated). Ledger: \(Self.projectRelative(evidenceLedgerPath, root: projectRoot)).
            """
            let relevance = record.taskEvidenceUpdated > 0 && record.memoryRecorded ? 40 : 26
            return CaptainMemoryCandidate(layerID: .knowledgeIndex,
                                          recordID: record.id,
                                          title: "Evidence Ledger: \(record.specialistName) -> \(record.objective)",
                                          excerpt: excerpt(excerptText),
                                          sourcePath: record.artifactPath,
                                          baseRelevance: relevance)
        }
    }

    private func captainLearningBenchmarkCandidates(limit: Int) -> [CaptainMemoryCandidate] {
        captainLearningRetrievalSummaries()
            .prefix(max(0, limit))
            .map { summary in
                let tags = summary.taskTags.isEmpty ? "general" : summary.taskTags.joined(separator: ", ")
                let language = summary.language ?? "any language"
                let percent = Int((summary.successRate * 100).rounded())
                let status = summary.promoted ? "promoted" : "shadow"
                let modelEvidence = summary.providerId
                    + (summary.averageTokens > 0 ? " avg \(summary.averageTokens) tok" : "")
                    + (summary.averageLatencyMs > 0 ? " avg \(summary.averageLatencyMs)ms" : "")
                let excerptText = """
                Source: Captain learning samples from benchmarks and live eval loops. Role: \(summary.role). Provider: \(summary.providerId). Task tags: \(tags). Language: \(language). Status: \(status). Success: \(summary.successes)/\(summary.samples) (\(percent)%). Tool failures: \(summary.toolFailures). Model/cost signal: \(modelEvidence).
                """
                let idParts = ["learning", summary.role, summary.providerId, tags, language]
                return CaptainMemoryCandidate(
                    layerID: .benchmarks,
                    recordID: Self.slug(idParts.joined(separator: "-")),
                    title: "Benchmark Evidence: \(summary.providerId) for \(summary.role) (\(tags))",
                    excerpt: excerpt(excerptText),
                    sourcePath: CaptainLearningStore.relativePath,
                    baseRelevance: summary.promoted ? 44 : min(34, 12 + summary.samples * 5)
                )
            }
    }

    private func captainLearningRetrievalSummaries() -> [CaptainLearningSummary] {
        struct Key: Hashable {
            let role: String
            let providerId: String
            let language: String?
        }
        let samples = CaptainLearningStore(projectRoot: projectRoot).load()
        var buckets: [Key: [CaptainLearningSample]] = [:]
        for sample in samples {
            buckets[Key(role: sample.role, providerId: sample.providerId, language: sample.language), default: []].append(sample)
        }
        return buckets.map { key, values in
            let successes = values.filter(\.success).count
            let scored = values.compactMap(\.judgeScore)
            let tags = Array(Set(values.flatMap(\.taskTags))).sorted()
            let avgScore = scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count)
            let avgTokens = values.isEmpty ? 0 : values.reduce(0) { $0 + $1.tokens } / values.count
            let avgLatency = values.isEmpty ? 0 : values.reduce(0) { $0 + $1.latencyMs } / values.count
            let failures = values.reduce(0) { $0 + $1.toolFailures }
            let latest = values.map(\.atEpoch).max() ?? 0
            return CaptainLearningSummary(role: key.role, providerId: key.providerId,
                                          taskTags: tags.isEmpty ? ["coding"] : tags,
                                          language: key.language, samples: values.count,
                                          successes: successes, averageJudgeScore: avgScore,
                                          averageTokens: avgTokens,
                                          averageLatencyMs: avgLatency,
                                          toolFailures: failures, latestEpoch: latest)
        }.sorted { a, b in
            if a.promoted != b.promoted { return a.promoted && !b.promoted }
            if a.scoreBoost != b.scoreBoost { return a.scoreBoost > b.scoreBoost }
            if a.samples != b.samples { return a.samples > b.samples }
            return a.providerId < b.providerId
        }
    }

    private func genericMemoryCandidates(path: String,
                                         layerID: CaptainMemoryLayerID,
                                         base: Int) -> [CaptainMemoryCandidate] {
        loadJSONL(DiskMemoryRecord.self, path: path).enumerated().map { index, record in
            let title = Self.safe(record.title ?? record.summary ?? "\(layerID.title) \(index + 1)")
            let body = [record.summary, record.body, record.tags?.joined(separator: ", ")]
                .compactMap { $0 }
                .joined(separator: " ")
            let relevance = max(base, record.confidence.map { $0 / 2 } ?? 0, (record.impact ?? 0) * 8)
            return CaptainMemoryCandidate(layerID: layerID,
                                          recordID: record.id ?? "\(layerID.rawValue)-\(index + 1)",
                                          title: title,
                                          excerpt: excerpt(body.isEmpty ? title : body),
                                          sourcePath: Self.projectRelative(record.source ?? path, root: projectRoot),
                                          baseRelevance: relevance)
        }
    }

    private func researchArchiveCandidates(limit: Int) -> [CaptainMemoryCandidate] {
        guard let enumerator = FileManager.default.enumerator(atPath: researchArchiveRoot) else { return [] }
        var out: [CaptainMemoryCandidate] = []
        for case let relative as String in enumerator {
            guard out.count < limit else { break }
            let ext = (relative as NSString).pathExtension.lowercased()
            guard ["md", "txt", "json"].contains(ext) else { continue }
            let path = researchArchiveRoot + "/" + relative
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let title = (relative as NSString).lastPathComponent
            out.append(CaptainMemoryCandidate(layerID: .researchArchive,
                                              recordID: Self.slug(relative),
                                              title: "Research: \(title)",
                                              excerpt: excerpt(text),
                                              sourcePath: Self.projectRelative(path, root: projectRoot),
                                              baseRelevance: 12))
        }
        return out
    }

    private func makeCapsule(plan: Plan, spans: [AgentSpan], trajectory: [ActionRecord],
                             outcomeSummary: String, success: Bool) -> LearningCapsule {
        let title = taskTitle(plan: plan, outcomeSummary: outcomeSummary)
        let summary = Self.safe(outcomeSummary)
        let tools = Set(trajectory.map(\.tool))
        let mutating = trajectory.filter { ["edit_file", "write_file", "apply_patch", "run_command", "move_file"].contains($0.tool) }
        let failures = trajectory.filter { !$0.success }
        let tokens = UsageCost.summarize(spans: spans).tokens
        var learned = ["Completed work creates learning debt, not just code changes."]
        if tools.contains("read_file") || tools.contains("search_code") {
            learned.append("Project context was gathered before synthesis.")
        }
        if !mutating.isEmpty {
            learned.append("Implementation progress was tied to concrete tool actions.")
        }
        if success {
            learned.append("The current build path can pass through the Captain dashboard loop.")
        }

        var surprises: [String] = []
        if failures.isEmpty {
            surprises.append("No tool failures were recorded this turn.")
        } else {
            surprises.append("\(failures.count) tool failure(s) exposed workflow friction.")
        }
        if tokens > 0 { surprises.append("The turn consumed \(tokens) token(s), making cost part of the learning record.") }

        var slowdowns: [String] = []
        if tools.contains("read_file") { slowdowns.append("Understanding still depends on reading enough local context.") }
        if failures.isEmpty { slowdowns.append("No explicit slowdown was captured; future capsules should name bottlenecks.") }
        else { slowdowns.append("Failed tools should become either fixes, guardrails, or documentation.") }

        let assumptions = [
            "The next best investment may be research instead of implementation.",
            "Competitors may already have solved parts of the workflow better.",
            "Architecture should be compared against evidence, not just momentum."
        ]

        return LearningCapsule(
            id: Self.makeID(prefix: "LC", title: title, at: now()),
            taskTitle: title,
            status: success ? .pass : .fail,
            summary: summary,
            learned: Array(learned.prefix(4)),
            surprises: Array(surprises.prefix(3)),
            slowdowns: Array(slowdowns.prefix(3)),
            assumptionsToChallenge: assumptions,
            futureEvolution: "Persistent research memory linked to benchmarks and live evals.",
            tokenCount: tokens,
            at: now().timeIntervalSince1970
        )
    }

    private func taskTitle(plan: Plan, outcomeSummary: String) -> String {
        if let done = plan.tasks.filter({ $0.status == .done }).max(by: { $0.id < $1.id }) {
            return done.boardTitle
        }
        if let active = plan.active { return active.boardTitle }
        if let next = plan.next { return next.boardTitle }
        let first = outcomeSummary.split(separator: "\n").first.map(String.init) ?? "Turn"
        return first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Turn" : String(first.prefix(90))
    }

    private func upsertKnowledgeDebt(from item: StatusDashboard.ResearchItem, sourceCapsuleID: String?) {
        let nowValue = now().timeIntervalSince1970
        let record = KnowledgeDebtRecord(
            id: Self.debtID(item.title),
            topic: Self.safe(item.title),
            reason: Self.safe(item.reason),
            visit: Self.safe(item.visit),
            impact: item.impact,
            priority: item.priority == .high ? .high : .medium,
            estimatedLearning: Self.safe(item.estimatedLearning),
            expectedBenefit: item.expectedBenefit.map(Self.safe),
            sourceCapsuleID: sourceCapsuleID,
            status: .open,
            createdAt: nowValue,
            updatedAt: nowValue
        )
        upsert(record)
    }

    private func upsert(_ record: KnowledgeDebtRecord) {
        var records = loadJSONL(KnowledgeDebtRecord.self, path: debtPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            let created = records[idx].createdAt
            let status = records[idx].status
            records[idx] = record
            records[idx].createdAt = created
            records[idx].status = status
            records[idx].impact = max(records[idx].impact, record.impact)
        } else {
            records.append(record)
        }
        saveJSONL(records, to: debtPath)
    }

    private func upsert(_ record: OrganizationalRuleRecord) {
        var records = loadJSONL(OrganizationalRuleRecord.self, path: rulesPath)
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            let created = records[idx].createdAt
            let priorStatus = records[idx].status
            var updated = record
            updated.createdAt = created
            updated.confidence = max(records[idx].confidence, record.confidence)
            updated.evidence = Self.unique(records[idx].evidence + record.evidence)
            if priorStatus == .active && record.status != .active {
                updated.status = .active
                updated.reason = records[idx].reason
            }
            records[idx] = updated
        } else {
            records.append(record)
        }
        saveJSONL(records, to: rulesPath)
    }

    @discardableResult
    private func recordSpecialistEvidenceLedger(kind: LearningEvidenceRecord.Kind,
                                                objective: String,
                                                specialistName: String,
                                                role: String,
                                                preferredModel: String,
                                                artifactPath: String,
                                                memoryRecorded: Bool,
                                                taskIDs: [Int]) -> Bool {
        let nowValue = now().timeIntervalSince1970
        let pathKey = String(Self.slug(artifactPath).suffix(36))
        let record = LearningEvidenceRecord(
            id: "AA-evidence-\(kind.rawValue)-\(Int(nowValue))-\(Self.slug(specialistName))-\(pathKey)",
            kind: kind,
            objective: Self.safe(objective),
            specialistName: Self.safe(specialistName),
            role: Self.safe(role),
            preferredModel: Self.safe(preferredModel),
            artifactPath: artifactPath,
            memoryRecorded: memoryRecorded,
            taskIDs: taskIDs,
            taskEvidenceUpdated: taskIDs.count,
            createdAt: nowValue
        )
        return appendJSON(record, to: evidenceLedgerPath)
    }

    private func seedResearchTasks(plan: Plan, insights: DashboardInsightBundle) -> Int {
        let existing = Set(plan.tasks.map { $0.boardTitle.lowercased() })
        let store = PlanStore(projectRoot: projectRoot)
        var count = 0
        for item in insights.research.prefix(5) where !existing.contains(item.title.lowercased()) {
            store.add(title: "RESEARCH: \(item.title)",
                      detail: item.reason,
                      kind: .research,
                      acceptance: "Evidence captured and impact on Kist roadmap summarized.",
                      verification: "Attach source links or notes, then mark this research debt paid.",
                      evidence: item.visit.isEmpty ? [] : [item.visit])
            count += 1
        }
        return count
    }

    private func ensureMemoryArchitecture() {
        try? FileManager.default.createDirectory(atPath: learningRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: researchArchiveRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: localModelsRoot, withIntermediateDirectories: true)
        for path in [knowledgeIndexPath, rulesPath, industryIntelligencePath, benchmarksPath,
                     evolutionProposalsPath, capsulesPath, debtPath, evidenceLedgerPath] {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
        }
    }

    private func dedupe(_ items: [StrategicAgendaItem]) -> [StrategicAgendaItem] {
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

    private func dedupe(_ items: [CaptainMemoryCandidate]) -> [CaptainMemoryCandidate] {
        var seen = Set<String>()
        var out: [CaptainMemoryCandidate] = []
        for item in items {
            let key = "\(item.layerID.rawValue):\(item.recordID)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

    private func renderLearningSummary(_ summary: CaptainLearningSummary) -> String {
        let pct = Int((summary.successRate * 100).rounded())
        let tags = summary.taskTags.isEmpty ? "general" : summary.taskTags.joined(separator: ", ")
        let language = summary.language ?? "any"
        let judge = summary.averageJudgeScore.map { " judge=\(Int(($0 * 100).rounded()))%" } ?? ""
        let latency = summary.averageLatencyMs > 0 ? " avgLatency=\(summary.averageLatencyMs)ms" : ""
        let tokens = summary.averageTokens > 0 ? " avgTokens=\(summary.averageTokens)" : ""
        return "- \(summary.providerId) / \(summary.role) [\(tags)] language=\(language) "
            + "\(summary.successes)/\(summary.samples) \(pct)%\(judge)\(tokens)\(latency) "
            + "toolFailures=\(summary.toolFailures) status=\(summary.promoted ? "promoted" : "shadow")"
    }

    @discardableResult
    private func appendJSON<T: Encodable>(_ value: T, to path: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    return false
                }
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            var line = data
            line.append(0x0a)
            try handle.write(contentsOf: line)
            return true
        } catch {
            return false
        }
    }

    private func loadJSONL<T: Decodable>(_ type: T.Type, path: String) -> [T] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(T.self, from: Data(line.utf8))
        }
    }

    @discardableResult
    private func saveJSONL<T: Encodable>(_ values: [T], to path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
        } catch {
            return false
        }
        let lines = values.compactMap { value -> String? in
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
        do {
            try (lines + (lines.isEmpty ? "" : "\n")).write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    static func render(_ capsule: LearningCapsule) -> String {
        var lines = [
            "BUILD COMPLETE",
            capsule.taskTitle,
            "Status",
            capsule.status.rawValue,
            "",
            "WHAT WE LEARNED",
        ]
        lines += capsule.learned.map { "• \($0)" }
        lines += ["", "WHAT SURPRISED US"]
        lines += capsule.surprises.map { "• \($0)" }
        lines += ["", "WHAT SLOWED US DOWN"]
        lines += capsule.slowdowns.map { "• \($0)" }
        lines += ["", "ASSUMPTIONS TO CHALLENGE"]
        lines += capsule.assumptionsToChallenge.map { "• \($0)" }
        lines += ["", "FUTURE EVOLUTION", capsule.futureEvolution]
        return lines.joined(separator: "\n")
    }

    static func debtID(_ topic: String) -> String {
        "KD-" + slug(topic).prefix(44)
    }

    static func ruleID(_ lesson: String) -> String {
        "OR-" + slug(lesson).prefix(44)
    }

    static func executeLocalModelAcquisitionCommand(_ command: LocalModelAcquisitionRunnableCommand,
                                                    projectRoot: String) -> LocalModelAcquisitionRunOutcome {
        var results: [LocalModelAcquisitionProcessResult] = []
        for invocation in command.invocations {
            let result = runLocalModelAcquisitionInvocation(invocation,
                                                           projectRoot: projectRoot,
                                                           timeoutSeconds: command.timeoutSeconds)
            results.append(result)
            if !result.succeeded { break }
        }
        return LocalModelAcquisitionRunOutcome(results: results)
    }

    static func localModelAcquisitionDependencyBlockers(_ command: LocalModelAcquisitionRunnableCommand) -> [LocalModelAcquisitionDependencyBlocker] {
        var seen = Set<String>()
        var blockers: [LocalModelAcquisitionDependencyBlocker] = []
        for invocation in command.invocations {
            guard seen.insert(invocation.executable).inserted else { continue }
            guard resolveExecutableForLocalModelAcquisition(invocation.executable) == nil else { continue }
            blockers.append(localModelAcquisitionDependencyBlocker(for: invocation.executable))
        }
        return blockers
    }

    static func localModelAcquisitionExecutableTrustBlockers(_ command: LocalModelAcquisitionRunnableCommand,
                                                             projectRoot: String) -> [String] {
        var seen = Set<String>()
        var blockers: [String] = []
        for invocation in command.invocations {
            guard seen.insert(invocation.executable).inserted else { continue }
            guard let path = resolveExecutableForLocalModelAcquisition(invocation.executable) else { continue }
            if !isTrustedLocalModelAcquisitionExecutable(path,
                                                         executable: invocation.executable,
                                                         projectRoot: projectRoot) {
                blockers.append("untrusted acquisition executable '\(invocation.executable)' resolved to '\(path)'")
            }
        }
        return blockers
    }

    private static func localModelAcquisitionDependencyBlocker(for executable: String) -> LocalModelAcquisitionDependencyBlocker {
        switch executable {
        case "hf":
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "Hugging Face CLI is required for manifest dry-run/download stages and is not on PATH",
                setupCommand: "python3 -m pip install --user -U 'huggingface_hub[cli]'",
                verifyCommand: "hf --help")
        case "ollama":
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "Ollama CLI is required to inspect installed Ollama models and is not on PATH",
                setupCommand: "brew install ollama",
                verifyCommand: "ollama --version")
        case "kist":
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "Kist must be callable from PATH for recursive inspect/onboard/benchmark stages",
                setupCommand: "export PATH=\"$HOME/bin:$PATH\"",
                verifyCommand: "kist --help")
        default:
            return LocalModelAcquisitionDependencyBlocker(
                executable: executable,
                reason: "required acquisition-stage executable is not on PATH",
                setupCommand: "install \(executable) with your package manager",
                verifyCommand: "\(executable) --help")
        }
    }

    private static func runLocalModelAcquisitionInvocation(_ invocation: LocalModelAcquisitionRunnableCommand.Invocation,
                                                           projectRoot: String,
                                                           timeoutSeconds: Int) -> LocalModelAcquisitionProcessResult {
        let display = invocation.display
        guard let executable = resolveExecutableForLocalModelAcquisition(invocation.executable) else {
            return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                      command: display,
                                                      exitCode: 127,
                                                      timedOut: false,
                                                      stdout: "",
                                                      stderr: "executable not found: \(invocation.executable)")
        }
        guard isTrustedLocalModelAcquisitionExecutable(executable,
                                                       executable: invocation.executable,
                                                       projectRoot: projectRoot) else {
            return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                      command: display,
                                                      exitCode: 126,
                                                      timedOut: false,
                                                      stdout: "",
                                                      stderr: "untrusted executable path: \(executable)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = invocation.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
        process.environment = scrubbedLocalModelAcquisitionEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutCapture = LocalModelAcquisitionOutputCapture()
        let stderrCapture = LocalModelAcquisitionOutputCapture()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutCapture.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrCapture.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                      command: display,
                                                      exitCode: 126,
                                                      timedOut: false,
                                                      stdout: "",
                                                      stderr: String(describing: error))
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        var timedOut = false
        if finished.wait(timeout: .now() + .seconds(max(1, timeoutSeconds))) == .timedOut {
            timedOut = true
            process.terminate()
            _ = finished.wait(timeout: .now() + .seconds(2))
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if !process.isRunning {
            stdoutCapture.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrCapture.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
        } else {
            stderrCapture.append(Data("\nprocess still running after timeout termination request".utf8))
        }
        return LocalModelAcquisitionProcessResult(label: invocation.label,
                                                  command: display,
                                                  exitCode: timedOut ? 124 : process.terminationStatus,
                                                  timedOut: timedOut,
                                                  stdout: stdoutCapture.string(),
                                                  stderr: stderrCapture.string())
    }

    private final class LocalModelAcquisitionOutputCapture {
        private let lock = NSLock()
        private var data = Data()
        private let cap = 120_000

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard data.count < cap else { return }
            data.append(chunk.prefix(cap - data.count))
        }

        func string() -> String {
            lock.lock()
            let snapshot = data
            let wasCapped = data.count >= cap
            lock.unlock()
            let text = String(data: snapshot, encoding: .utf8) ?? ""
            return wasCapped ? text + "\n... output capped ..." : text
        }
    }

    private static func resolveExecutableForLocalModelAcquisition(_ executable: String) -> String? {
        let fm = FileManager.default
        if executable == "kist",
           let current = CommandLine.arguments.first,
           fm.isExecutableFile(atPath: current) {
            if current.hasPrefix("/") { return (current as NSString).resolvingSymlinksInPath }
            let cwdPath = (fm.currentDirectoryPath as NSString).appendingPathComponent(current)
            if fm.isExecutableFile(atPath: cwdPath) { return (cwdPath as NSString).resolvingSymlinksInPath }
        }
        if executable.hasPrefix("/") {
            let resolved = (executable as NSString).resolvingSymlinksInPath
            return fm.isExecutableFile(atPath: resolved) ? resolved : nil
        }
        guard !executable.contains("/") else { return nil }
        let path = ProcessInfo.processInfo.environment["PATH"]
            ?? "/opt/homebrew/bin:/usr/local/bin:/Users/lukekist/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            let resolved = (candidate as NSString).resolvingSymlinksInPath
            if fm.isExecutableFile(atPath: resolved) { return resolved }
        }
        return nil
    }

    private static func isTrustedLocalModelAcquisitionExecutable(_ path: String,
                                                                 executable: String,
                                                                 projectRoot: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        let root = (projectRoot as NSString).resolvingSymlinksInPath
        if resolved == root || resolved.hasPrefix(root + "/") { return false }
        if resolved.hasPrefix("/tmp/") || resolved.hasPrefix("/private/tmp/") { return false }
        if executable == "kist" {
            let current = CommandLine.arguments.first.map { ($0 as NSString).resolvingSymlinksInPath }
            if current == resolved { return true }
        }
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath
        let allowedPrefixes = [
            "/opt/homebrew/bin/",
            "/usr/local/bin/",
            "/usr/bin/",
            "/bin/",
            "/usr/sbin/",
            "/sbin/",
            home + "/bin/",
            home + "/.local/bin/"
        ]
        return allowedPrefixes.contains { resolved.hasPrefix($0) }
    }

    private static func scrubbedLocalModelAcquisitionEnvironment() -> [String: String] {
        let allow = Set(["PATH", "HOME", "USER", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR", "SHELL"])
        return ProcessInfo.processInfo.environment.filter { allow.contains($0.key) }
    }

    private static func makeID(prefix: String, title: String, at: Date) -> String {
        "\(prefix)-\(Int(at.timeIntervalSince1970))-\(slug(title).prefix(28))"
    }

    private func resolveProjectFile(_ raw: String) -> String? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("\0") else { return nil }
        let candidate = clean.hasPrefix("/")
            ? clean
            : (projectRoot as NSString).appendingPathComponent(clean)
        guard FileManager.default.fileExists(atPath: candidate) else { return nil }
        let root = (projectRoot as NSString).resolvingSymlinksInPath
        let resolved = (candidate as NSString).resolvingSymlinksInPath
        guard resolved == root || resolved.hasPrefix(root + "/") else { return nil }
        return resolved
    }

    private static func slug(_ raw: String) -> String {
        let lower = raw.lowercased()
        var scalars = String.UnicodeScalarView()
        var lastDash = false
        for scalar in lower.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
            if isAllowed {
                scalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                scalars.append("-")
                lastDash = true
            }
        }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func safe(_ text: String) -> String {
        let redacted = SecretScanner.redactSecrets(in: text)
        return redacted.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func trimCommandOutput(_ text: String, limit: Int = 12_000) -> String {
        let safe = Self.safe(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if safe.isEmpty { return "(empty)" }
        if safe.count <= limit { return safe }
        return String(safe.prefix(limit)) + "\n... truncated ..."
    }

    private func excerpt(_ text: String, limit: Int = 420) -> String {
        let clean = Self.safe(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if clean.count <= limit { return clean }
        return String(clean.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            out.append(value)
        }
        return out
    }

    private static func boardTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["PLAN:", "ACTION:", "TEST:", "REVIEW:", "RESEARCH:", "DECISION:", "HANDOFF:", "BACKLOG:"] {
            if trimmed.uppercased().hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).description
            }
        }
        return trimmed
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func projectRelative(_ path: String, root: String) -> String {
        let canonicalRoot = ToolContext.canonicalize(root) ?? root
        let resolvedRoot = (canonicalRoot as NSString).resolvingSymlinksInPath
        let roots = [canonicalRoot, resolvedRoot].reduce(into: [String]()) { out, value in
            let clean = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !clean.isEmpty, !out.contains(clean) { out.append(clean) }
        }
        for candidate in [path, (path as NSString).resolvingSymlinksInPath] {
            for cleanRoot in roots where candidate.hasPrefix("/" + cleanRoot + "/") {
                return String(candidate.dropFirst(cleanRoot.count + 2))
            }
        }
        return path
    }

    private func stars(_ value: Int) -> String {
        Self.stars(value)
    }

    private static func stars(_ value: Int) -> String {
        let clamped = min(5, max(1, value))
        return String(repeating: "★", count: clamped) + String(repeating: "☆", count: 5 - clamped)
    }
}

private extension String {
    var singleLine: String {
        replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
