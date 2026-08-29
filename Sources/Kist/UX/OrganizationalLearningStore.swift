import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct OrganizationalJSONLRow<Value> {
    let ordinal: Int
    let value: Value
}

enum OrganizationalJSONLLoadResult<Value> {
    case missing
    case complete([OrganizationalJSONLRow<Value>])
    case partial([OrganizationalJSONLRow<Value>])
    case refused
    case failure

    var readableRows: [OrganizationalJSONLRow<Value>] {
        switch self {
        case .complete(let rows), .partial(let rows): return rows
        case .missing, .refused, .failure: return []
        }
    }

    var valuesForMutation: [Value]? {
        switch self {
        case .missing: return []
        case .complete(let rows): return rows.map(\.value)
        case .partial, .refused, .failure: return nil
        }
    }
}

private struct OrganizationalTemporalCapsuleRow {
    let row: OrganizationalJSONLRow<LearningCapsule>
    let evaluation: TemporalMemoryEvaluation
    let eventAt: Date
}

private struct OrganizationalTemporalGenericRow {
    let row: OrganizationalJSONLRow<DiskMemoryRecord>
    let evaluation: TemporalMemoryEvaluation
    let eventAt: Date
    let transactionAt: Date
}

struct OrganizationalLearningStore: Sendable {
    static let maximumJSONLFileBytes = 64 * 1_024 * 1_024
    static let maximumJSONLLineBytes = 1_024 * 1_024
    static let maximumJSONLRows = 100_000

    let projectRoot: String
    let now: @Sendable () -> Date
    let makeSpecialistRegistry: @Sendable (String) -> SpecialistRegistry

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
                    insights: DashboardInsightBundle? = nil,
                    objective: String? = nil,
                    seasonalWindow: SeasonalMemoryWindow? = nil) -> LearningCapsule {
        // Dashboard hints are ephemeral projections of the current board. Persisting them here promoted
        // every render-time suggestion into permanent open debt, creating a self-reinforcing queue.
        // Explicit /knowledge entries and research tasks already have their own durable stores.
        _ = insights
        let capsule = Self.bounded(makeCapsule(
            plan: plan, spans: spans, trajectory: trajectory,
            outcomeSummary: outcomeSummary, success: success,
            objective: objective, seasonalWindow: seasonalWindow))
        appendJSON(capsule, to: capsulesPath)
        return capsule
    }

    func latestCapsule() -> LearningCapsule? {
        loadJSONL(LearningCapsule.self, path: capsulesPath).last
    }

    func capsules(limit: Int = 20) -> [LearningCapsule] {
        Array(loadJSONL(LearningCapsule.self, path: capsulesPath).suffix(max(0, limit)))
    }

    /// Operational projection of capsule history. Raw `latestCapsule`/`capsules` remain audit APIs
    /// and deliberately expose rows that are expired, retired, future-dated, or out of season.
    func latestTemporallyEligibleCapsule() -> LearningCapsule? {
        latestTemporallyEligibleCapsule(at: now())
    }

    func latestTemporallyEligibleCapsule(at instant: Date) -> LearningCapsule? {
        temporallyEligibleCapsuleRows(at: instant)
            .sorted(by: Self.latestCapsuleOrder)
            .first?
            .row.value
    }

    func evidenceLedger(limit: Int = 40) -> [LearningEvidenceRecord] {
        Array(loadJSONL(LearningEvidenceRecord.self, path: evidenceLedgerPath).suffix(max(0, limit)))
    }

    func openKnowledgeDebt(limit: Int = 20) -> [KnowledgeDebtRecord] {
        openKnowledgeDebt(limit: limit, at: now())
    }

    func openKnowledgeDebt(limit: Int = 20, at instant: Date) -> [KnowledgeDebtRecord] {
        let records = loadJSONLWithOrdinals(KnowledgeDebtRecord.self, path: debtPath)
            // Historical dashboard suggestions carry a source capsule. They were never accepted as
            // durable work, so retain them on disk for audit but do not resurrect them as live debt.
            .filter {
                $0.value.status == .open && $0.value.sourceCapsuleID == nil &&
                    ($0.value.temporalProjection?.evaluate(at: instant).isRetrievalEligible == true)
            }
            .sorted {
                if $0.value.impact != $1.value.impact { return $0.value.impact > $1.value.impact }
                if $0.value.updatedAt != $1.value.updatedAt { return $0.value.updatedAt > $1.value.updatedAt }
                return $0.ordinal < $1.ordinal
            }
        return records.prefix(max(0, limit)).map { Self.bounded($0.value) }
    }

    func permanentRules(limit: Int = 20) -> [OrganizationalRuleRecord] {
        // Source-controlled JSONL status is not authority. Until an exact accepted receipt can be
        // verified against this rule's canonical text, every row remains advisory—even legacy rows
        // that say `active`. This prevents a hand-written line from becoming Captain policy.
        _ = limit
        return []
    }

    func proposedRules(limit: Int = 20) -> [OrganizationalRuleRecord] {
        let instant = now()
        let records = loadJSONLWithOrdinals(OrganizationalRuleRecord.self, path: rulesPath)
            .filter {
                $0.value.status != .retired &&
                    ($0.value.temporalProjection?.evaluate(at: instant).isRetrievalEligible == true)
            }
            .sorted {
                if $0.value.confidence != $1.value.confidence {
                    return $0.value.confidence > $1.value.confidence
                }
                if $0.value.updatedAt != $1.value.updatedAt { return $0.value.updatedAt > $1.value.updatedAt }
                return $0.ordinal < $1.ordinal
            }
        return records.prefix(max(0, limit)).map { Self.bounded($0.value) }
    }

    func retrievalContext(objective: String,
                          strategy: CaptainStrategyPlan,
                          limit: Int = 8) -> CaptainRetrievalContext {
        retrievalContext(objective: objective, strategy: strategy, limit: limit, at: now())
    }

    func retrievalContext(objective: String,
                          strategy: CaptainStrategyPlan,
                          limit: Int = 8,
                          at retrievalNow: Date) -> CaptainRetrievalContext {
        ensureMemoryArchitecture()
        let candidates = memoryCandidates(at: retrievalNow)
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

    func selfHealAssignments(weakness: SelfHealWeakness,
                                     objective: String) -> [SelfHealAgentAssignment] {
        [
            SelfHealAgentAssignment(
                specialistName: "self-heal-researcher",
                role: "Gemini diagnostic analyst",
                preferredModel: "gemini",
                task: """
                Diagnose THIS specific failure before any implementation. Do not
                research the topic in the abstract.
                Objective: \(objective)
                Weakness: \(weakness.title)
                Why: \(weakness.reason)
                Evidence:
                \(weakness.supportingEvidence.joined(separator: "\n"))

                Work LOCAL-FIRST: read the failing tool/code path, its inputs, and
                the project state to find the concrete root cause. Only use web
                search if the cause genuinely cannot be determined from local code
                and docs — and if you do, tie every source back to THIS failure.
                Do not edit product code and do not mark tasks done.

                YOUR ONLY DELIVERABLE IS A HANDOFF. Do NOT produce more research
                tasks. End your final message with EXACTLY ONE fenced block:
                ```handoff
                {
                  "from": "self-heal-researcher",
                  "to": "self-heal-builder",
                  "root_cause": "<the confirmed cause, one sentence>",
                  "confidence": 0.0,
                  "target_files": ["<path>", "..."],
                  "repair_spec": "<the smallest reversible change to make>",
                  "reproduction_command": "<command that reproduces the failure>",
                  "verification_commands": ["<focused test>", "git diff --check"],
                  "blocked": false
                }
                ```
                If you cannot pin the cause, set "blocked": true and add
                "blocked_reason" — that is a valid terminal outcome to escalate, NOT
                a reason to open another research task.
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
    func createSelfHealSpecialists(assignments: [SelfHealAgentAssignment]) -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        var created = 0
        let defs = [
            SpecialistDefinition(
                name: "self-heal-researcher",
                description: "Researches Captain self-heal weaknesses, competitor patterns, docs, papers, and benchmark references before implementation.",
                systemPrompt: """
                You are Kist's self-heal DIAGNOSTIC researcher. Your job is to find the concrete root cause of the specific failure in the mission — not to survey the topic — and hand it off. Read the failing code path and local state FIRST; treat web search as a last resort and only for THIS failure. Do not edit product code and do not touch the task board. Your ONLY deliverable is a single ```handoff fenced JSON block (from, to, root_cause, confidence 0-1, target_files, repair_spec, reproduction_command, verification_commands, blocked). Do not produce more research tasks; if the cause is unknown, set blocked=true. The builder receives ONLY your handoff, so make repair_spec concrete and minimal.
                """,
                toolAllowlist: ["read_file", "search_code", "web_search", "fetch_url"],
                model: ProviderBinding(providerId: "gemini"),
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

    func selfHealTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    func simulationTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    func domainLearningTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    func localModelScoutTaskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    func preferredModelHint(for specialistName: String) -> String {
        let lower = specialistName.lowercased()
        if lower.contains("critic") || lower.contains("security") || lower.contains("risk") { return "deepseek" }
        if lower.contains("research") || lower.contains("strategic") || lower.contains("domain") { return "gemini or strongest research model" }
        if lower.contains("swift") || lower.contains("frontend") || lower.contains("symbolic") { return "MiMo" }
        if lower.contains("learning") || lower.contains("eval") || lower.contains("benchmark") { return "best benchmark-proven model" }
        return "inherit from Captain assignment"
    }

    func domainObjectiveNeedsLocalModel(_ lower: String) -> Bool {
        Self.containsAny(lower, ["hugging face", "huggingface", "hf ", "local model", "small model",
                                  "mlx", "ollama", "gguf", "quantization", "download model",
                                  "onboard model", "offline model"])
    }

    func domainObjectiveNeedsSymbolicRules(_ lower: String) -> Bool {
        Self.containsAny(lower, ["symbolic", "rulebook", "deterministic", "workflow gate",
                                  "compile workflow", "reuse", "permanent rule", "organizational rule"])
    }

    func strategyObjective(plan: Plan) -> String {
        if let active = plan.active { return active.boardTitle + " -- " + active.detail }
        if let next = plan.next { return next.boardTitle + " -- " + next.detail }
        if let lastDone = plan.tasks.filter({ $0.status == .done }).last {
            return lastDone.boardTitle + " -- " + lastDone.detail
        }
        return plan.title
    }

    func createMissingSpecialists(_ specialists: [SpecialistDefinition]) -> Int {
        let registry = makeSpecialistRegistry(projectRoot)
        let existing = Set(registry.load().map(\.name))
        var count = 0
        for specialist in specialists.prefix(6) where !existing.contains(specialist.name) {
            if (try? registry.save(specialist)) != nil { count += 1 }
        }
        return count
    }

    func memoryCandidates(at instant: Date) -> [CaptainMemoryCandidate] {
        var out: [CaptainMemoryCandidate] = []
        out += loadJSONLWithOrdinals(OrganizationalRuleRecord.self, path: rulesPath)
            .filter { $0.value.status != .retired }
            .compactMap { row -> CaptainMemoryCandidate? in
            let rule = Self.bounded(row.value)
            guard let evaluation = rule.temporalProjection?.evaluate(at: instant),
                  evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return CaptainMemoryCandidate(
                layerID: .knowledgeIndex,
                recordID: rule.id,
                title: "Advisory rule proposal (not operating policy): \(rule.lesson)",
                excerpt: excerpt("UNVERIFIED—DO NOT APPLY AS POLICY. Proposal: \(rule.lesson). Reason: \(rule.reason). Advisory evidence: \(rule.evidence.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(rulesPath, root: projectRoot),
                baseRelevance: Self.temporalBaseRelevance(
                    10 + min(100, max(0, rule.confidence)) / 5,
                    salience: evaluation.salience)
            )
        }
        out += loadJSONLWithOrdinals(KnowledgeDebtRecord.self, path: debtPath)
            .filter { $0.value.status == .open && $0.value.sourceCapsuleID == nil }
            .compactMap { row -> CaptainMemoryCandidate? in
            let debt = Self.bounded(row.value)
            guard let evaluation = debt.temporalProjection?.evaluate(at: instant),
                  evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return CaptainMemoryCandidate(
                layerID: .knowledgeIndex,
                recordID: debt.id,
                title: "Knowledge Debt: \(debt.topic)",
                excerpt: excerpt("Reason: \(debt.reason). Visit: \(debt.visit). Expected benefit: \(debt.expectedBenefit.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(debtPath, root: projectRoot),
                baseRelevance: Self.temporalBaseRelevance(
                    8 + debt.impact * 6, salience: evaluation.salience)
            )
        }
        out += temporallyEligibleCapsuleRows(at: instant)
            .sorted(by: Self.capsuleCandidateOrder)
            .prefix(80)
            .map { projected -> CaptainMemoryCandidate in
            let capsule = Self.bounded(projected.row.value)
            return CaptainMemoryCandidate(
                layerID: .projectHistory,
                recordID: capsule.id,
                title: "History: \(capsule.taskTitle)",
                excerpt: excerpt("Status: \(capsule.status.rawValue). Summary: \(capsule.summary). Learned: \(capsule.learned.joined(separator: "; ")). Surprises: \(capsule.surprises.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(capsulesPath, root: projectRoot),
                baseRelevance: Self.temporalBaseRelevance(
                    capsule.status == .pass ? 12 : 18,
                    salience: projected.evaluation.salience)
            )
        }
        out += captainLearningBenchmarkCandidates(
            limit: 80, nowEpoch: instant.timeIntervalSince1970)
        out += evidenceLedgerCandidates(limit: 80, at: instant)
        out += genericMemoryCandidates(
            path: knowledgeIndexPath, layerID: .knowledgeIndex, base: 18, at: instant,
            allowedDecayRates: [.fast, .medium])
        out += genericMemoryCandidates(
            path: industryIntelligencePath, layerID: .industryIntelligence, base: 14,
            at: instant, allowedDecayRates: [.fast])
        out += genericMemoryCandidates(
            path: evolutionProposalsPath, layerID: .knowledgeIndex, base: 22, at: instant,
            allowedDecayRates: [.medium])
        out += genericMemoryCandidates(
            path: benchmarksPath, layerID: .benchmarks, base: 18, at: instant,
            allowedDecayRates: [.fast])
        // Research documents are immutable audit artifacts, not self-dating memory. Operational
        // recall comes through their explicit, temporally indexed DiskMemoryRecord instead of file
        // mtime, which can be reset by copies or rewrites.
        return dedupe(out)
    }

    private func temporallyEligibleCapsuleRows(
        at instant: Date
    ) -> [OrganizationalTemporalCapsuleRow] {
        loadJSONLWithOrdinals(LearningCapsule.self, path: capsulesPath).compactMap { row in
            let capsule = Self.bounded(row.value)
            guard let temporal = capsule.temporalProjection else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return OrganizationalTemporalCapsuleRow(
                row: OrganizationalJSONLRow(ordinal: row.ordinal, value: capsule),
                evaluation: evaluation,
                eventAt: temporal.createdAt)
        }
    }

    private static func capsuleCandidateOrder(
        _ lhs: OrganizationalTemporalCapsuleRow,
        _ rhs: OrganizationalTemporalCapsuleRow
    ) -> Bool {
        if lhs.evaluation.salience != rhs.evaluation.salience {
            return lhs.evaluation.salience > rhs.evaluation.salience
        }
        if lhs.eventAt != rhs.eventAt { return lhs.eventAt > rhs.eventAt }
        return lhs.row.ordinal > rhs.row.ordinal
    }

    private static func latestCapsuleOrder(
        _ lhs: OrganizationalTemporalCapsuleRow,
        _ rhs: OrganizationalTemporalCapsuleRow
    ) -> Bool {
        if lhs.eventAt != rhs.eventAt { return lhs.eventAt > rhs.eventAt }
        return lhs.row.ordinal > rhs.row.ordinal
    }

    func evidenceLedgerCandidates(limit: Int, at instant: Date) -> [CaptainMemoryCandidate] {
        let projected = loadJSONLWithOrdinals(
            LearningEvidenceRecord.self, path: evidenceLedgerPath
        ).compactMap { row -> (OrganizationalJSONLRow<LearningEvidenceRecord>,
                               TemporalMemoryEvaluation, Date)? in
            let record = row.value
            guard let temporal = OrganizationalMemoryTemporal.legacy(
                createdAt: record.createdAt, updatedAt: record.createdAt,
                decayRate: .slow) else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return (row, evaluation, temporal.createdAt)
        }.sorted { lhs, rhs in
            if lhs.1.salience != rhs.1.salience { return lhs.1.salience > rhs.1.salience }
            if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
            return lhs.0.ordinal > rhs.0.ordinal
        }.prefix(max(0, limit))

        return projected.map { projected in
            let record = projected.0.value
            let evaluation = projected.1
            let taskIDs = record.taskIDs.isEmpty
                ? "none"
                : record.taskIDs.map(String.init).joined(separator: ", ")
            let memoryStatus = record.memoryRecorded ? "indexed" : "not indexed"
            let excerptText = """
            Durable specialist evidence. Kind: \(record.kind.rawValue). Objective: \(record.objective). Specialist: \(record.specialistName). Role: \(record.role). Preferred model: \(record.preferredModel). Artifact: \(record.artifactPath). Memory: \(memoryStatus). Task IDs: \(taskIDs). Task evidence updated: \(record.taskEvidenceUpdated). Ledger: \(Self.projectRelative(evidenceLedgerPath, root: projectRoot)).
            """
            let base = record.taskEvidenceUpdated > 0 && record.memoryRecorded ? 40 : 26
            return CaptainMemoryCandidate(layerID: .knowledgeIndex,
                                          recordID: record.id,
                                          title: "Evidence Ledger: \(record.specialistName) -> \(record.objective)",
                                          excerpt: excerpt(excerptText),
                                          sourcePath: record.artifactPath,
                                          baseRelevance: Self.temporalBaseRelevance(
                                            base, salience: evaluation.salience))
        }
    }

    func captainLearningBenchmarkCandidates(limit: Int,
                                             nowEpoch: Double) -> [CaptainMemoryCandidate] {
        captainLearningRetrievalSummaries(now: nowEpoch)
            .prefix(max(0, limit))
            .map { summary in
                let tags = summary.taskTags.isEmpty ? "general" : summary.taskTags.joined(separator: ", ")
                let language = summary.language ?? "any language"
                let percent = Int((summary.successRate * 100).rounded())
                let status = summary.promoted ? "route-bias eligible" : "shadow only"
                let modelEvidence = summary.providerId
                    + (summary.averageTokens > 0 ? " avg \(summary.averageTokens) tok" : "")
                    + (summary.averageLatencyMs > 0 ? " avg \(summary.averageLatencyMs)ms" : "")
                let excerptText = """
                UNSIGNED ADVISORY — not a receipt or independent benchmark authority. Source: Captain scorecard observations from benchmark and live-eval loops. Role: \(summary.role). Provider: \(summary.providerId). Task tags: \(tags). Language: \(language). Status: \(status). Success: \(summary.successes)/\(summary.samples) (\(percent)%). Tool failures: \(summary.toolFailures). Model/cost signal: \(modelEvidence).
                """
                let idParts = ["learning", summary.role, summary.providerId, tags, language]
                return CaptainMemoryCandidate(
                    layerID: .benchmarks,
                    recordID: Self.slug(idParts.joined(separator: "-")),
                    title: "Unsigned Scorecard Observations: \(summary.providerId) for \(summary.role) (\(tags))",
                    excerpt: excerpt(excerptText),
                    sourcePath: CaptainLearningStore.relativePath,
                    baseRelevance: summary.promoted ? 44 : min(34, 12 + summary.samples * 5)
                )
            }
    }

    /// Reports temporal admission without mutating or rejuvenating legacy rows. A row that cannot
    /// present one internally consistent clock remains available through raw JSONL readers only.
    func genericMemoryTemporalReadiness() -> (operational: Int, auditOnly: Int) {
        let paths = [
            knowledgeIndexPath,
            industryIntelligencePath,
            evolutionProposalsPath,
            benchmarksPath,
        ]
        let records = paths.flatMap { loadJSONL(DiskMemoryRecord.self, path: $0) }
        let operational = records.reduce(into: 0) { count, record in
            if record.temporalProjection != nil { count += 1 }
        }
        return (operational, records.count - operational)
    }

    static func temporalBaseRelevance(_ base: Int, salience: Double) -> Int {
        guard salience.isFinite else { return 0 }
        return min(100, max(0, Int((Double(base) * salience).rounded())))
    }

    func genericMemoryCandidates(path: String,
                                         layerID: CaptainMemoryLayerID,
                                         base: Int,
                                         at instant: Date,
                                         allowedDecayRates: [MemoryDecayRate])
        -> [CaptainMemoryCandidate] {
        let eligible = loadJSONLWithOrdinals(
            DiskMemoryRecord.self, path: path
        ).compactMap { row -> OrganizationalTemporalGenericRow? in
            let record = Self.bounded(row.value)
            guard let temporal = record.temporalProjection,
                  allowedDecayRates.contains(temporal.decayRate) else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return OrganizationalTemporalGenericRow(
                row: OrganizationalJSONLRow(ordinal: row.ordinal, value: record),
                evaluation: evaluation,
                eventAt: temporal.createdAt,
                transactionAt: temporal.updatedAt)
        }

        // A stable ID names one advisory memory across transaction revisions. Select the newest
        // eligible revision before relevance ranking so a physically older or more salient copy can
        // never shadow a later update. Ineligible future/retired revisions do not hide prior audit
        // history; they simply cannot enter this operational projection.
        var newestByID: [String: OrganizationalTemporalGenericRow] = [:]
        var anonymous: [OrganizationalTemporalGenericRow] = []
        for candidate in eligible {
            guard let rawID = candidate.row.value.id else {
                anonymous.append(candidate)
                continue
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                anonymous.append(candidate)
                continue
            }
            if let prior = newestByID[id],
               prior.transactionAt > candidate.transactionAt
                || (prior.transactionAt == candidate.transactionAt
                    && prior.row.ordinal > candidate.row.ordinal) {
                continue
            }
            newestByID[id] = candidate
        }

        let projected = (Array(newestByID.values) + anonymous).sorted { lhs, rhs in
            if lhs.evaluation.salience != rhs.evaluation.salience {
                return lhs.evaluation.salience > rhs.evaluation.salience
            }
            if lhs.eventAt != rhs.eventAt { return lhs.eventAt > rhs.eventAt }
            return lhs.row.ordinal > rhs.row.ordinal
        }.prefix(80)

        return projected.map { projected in
            let record = projected.row.value
            let index = projected.row.ordinal
            let title = Self.safe(record.title ?? record.summary ?? "\(layerID.title) \(index + 1)")
            let body = [record.summary, record.body, record.tags?.joined(separator: ", ")]
                .compactMap { $0 }
                .joined(separator: " ")
            let confidence = min(100, max(0, record.confidence ?? 0))
            let impact = min(5, max(0, record.impact ?? 0))
            let relevance = max(base, confidence / 2, impact * 8)
            return CaptainMemoryCandidate(layerID: layerID,
                                          recordID: record.id ?? "\(layerID.rawValue)-\(index + 1)",
                                          title: title,
                                          excerpt: excerpt(body.isEmpty ? title : body),
                                          sourcePath: Self.projectRelative(record.source ?? path, root: projectRoot),
                                          baseRelevance: Self.temporalBaseRelevance(
                                            relevance, salience: projected.evaluation.salience))
        }
    }

    /// Explicit raw-audit projection only. Never feed these unindexed filesystem artifacts into
    /// operational recall; they have no content-bound digest or trustworthy event clock.
    func rawResearchArchiveAuditCandidates(limit: Int) -> [CaptainMemoryCandidate] {
        let boundedLimit = min(40, max(0, limit))
        guard boundedLimit > 0,
              let confined = try? ConfinedRoot(root: researchArchiveRoot, readOnly: true) else {
            return []
        }

        // Keep even the explicit audit walk bounded. Descriptor-relative directory reads and stable
        // reads refuse symlinks, hardlinks, special files, oversized files, and mid-read changes.
        var directories = [""]
        var nextDirectory = 0
        var inspectedEntries = 0
        var files: [String] = []
        while nextDirectory < directories.count,
              inspectedEntries < 4_096,
              files.count < boundedLimit {
            let directory = directories[nextDirectory]
            nextDirectory += 1
            guard let entries = try? confined.entries(directory) else { continue }
            for entry in entries {
                guard inspectedEntries < 4_096, files.count < boundedLimit else { break }
                inspectedEntries += 1
                let relative = directory.isEmpty ? entry.name : directory + "/" + entry.name
                if entry.isDir {
                    directories.append(relative)
                    continue
                }
                let ext = (relative as NSString).pathExtension.lowercased()
                if ["md", "txt", "json"].contains(ext) { files.append(relative) }
            }
        }

        var out: [CaptainMemoryCandidate] = []
        for relative in files {
            let path = researchArchiveRoot + "/" + relative
            guard let data = try? confined.readStableData(relative, maxBytes: 1_024 * 1_024),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let title = Self.boundedText((relative as NSString).lastPathComponent, limit: 2_048)
            out.append(CaptainMemoryCandidate(layerID: .researchArchive,
                                              recordID: String(Self.slug(relative).prefix(256)),
                                              title: "Research: \(title)",
                                              excerpt: excerpt(text),
                                              sourcePath: Self.projectRelative(path, root: projectRoot),
                                              baseRelevance: 12))
        }
        return out
    }

    func makeCapsule(plan: Plan, spans: [AgentSpan], trajectory: [ActionRecord],
                             outcomeSummary: String, success: Bool,
                             objective: String? = nil,
                             seasonalWindow: SeasonalMemoryWindow? = nil) -> LearningCapsule {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        let title = taskTitle(plan: plan, outcomeSummary: outcomeSummary, objective: objective)
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
            id: Self.makeID(prefix: "LC", title: title, at: instant),
            taskTitle: title,
            status: success ? .pass : .fail,
            summary: summary,
            learned: Array(learned.prefix(4)),
            surprises: Array(surprises.prefix(3)),
            slowdowns: Array(slowdowns.prefix(3)),
            assumptionsToChallenge: assumptions,
            futureEvolution: Self.deriveFutureEvolution(success: success, failures: failures,
                                                        mutating: mutating, tools: tools,
                                                        objective: objective),
            tokenCount: tokens,
            at: instant.timeIntervalSince1970,
            temporal: OrganizationalMemoryTemporal.make(
                createdAt: instant, decayRate: .medium, seasonalWindow: seasonalWindow)
        )
    }

    /// Derive the next-capability line FROM this run's trajectory. This was a hardcoded sentence,
    /// so every capsule — and therefore every dashboard — showed the identical "future evolution"
    /// forever (routing audit 2026-08-25). Empty when the run carries no signal: the dashboard
    /// renderer skips empty capabilities, and an honest blank beats an invented priority.
    static func deriveFutureEvolution(success: Bool, failures: [ActionRecord],
                                      mutating: [ActionRecord], tools: Set<String>,
                                      objective: String? = nil) -> String {
        if let worst = Dictionary(grouping: failures, by: \.tool)
            .max(by: { $0.value.count < $1.value.count }) {
            return "Harden the \(worst.key) path — \(worst.value.count) failure(s) this run."
        }
        if !success { return "Diagnose why this turn failed with no individual tool failure recorded." }
        // "Reading without acting" is only a shortcoming when the user ASKED for mutation. A chat/
        // review/research turn that inspects source and answers is complete as-is — recording it as
        // unfinished work was a false dashboard claim (Codex P2, 2026-08-25). Unknown objective ⇒
        // assume read-only (no invented debt).
        let wantsMutation = objective.map {
            PromptCompiler.expectedOutcome(intent: PromptCompiler.inferIntent($0)) == .mutation
        } ?? false
        if wantsMutation, mutating.isEmpty, tools.contains("read_file") {
            return "Turn gathered context but changed nothing — convert reading into action next run."
        }
        return ""
    }

    func taskTitle(plan: Plan, outcomeSummary: String, objective: String?) -> String {
        if let objective {
            let clean = HeadlessAgentLoop.scopeRequestSource(for: objective)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return String(clean.prefix(90)) }
        }
        if let done = plan.tasks.filter({ $0.status == .done }).max(by: { $0.id < $1.id }) {
            return done.boardTitle
        }
        if let active = plan.active { return active.boardTitle }
        if let next = plan.next { return next.boardTitle }
        let first = outcomeSummary.split(separator: "\n").first.map(String.init) ?? "Turn"
        return first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Turn" : String(first.prefix(90))
    }

    func upsertKnowledgeDebt(from item: StatusDashboard.ResearchItem, sourceCapsuleID: String?) {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        let nowValue = instant.timeIntervalSince1970
        let record = Self.bounded(KnowledgeDebtRecord(
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
            updatedAt: nowValue,
            temporal: OrganizationalMemoryTemporal.make(createdAt: instant, decayRate: .slow)
        ))
        upsert(record)
    }

    @discardableResult
    func upsert(_ record: KnowledgeDebtRecord,
                seasonalWindow: SeasonalMemoryWindow? = nil) -> Bool {
        mutateJSONL(KnowledgeDebtRecord.self, path: debtPath) { records in
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                let created = records[idx].createdAt
                let status = records[idx].status
                let prior = records[idx]
                var updated = record
                updated.createdAt = created
                updated.updatedAt = max(prior.updatedAt, record.updatedAt)
                updated.status = status
                updated.impact = max(prior.impact, record.impact)
                if let envelope = prior.temporalProjection {
                    updated.temporal = OrganizationalMemoryTemporal.transactionUpdated(
                        envelope,
                        at: Date(timeIntervalSince1970: updated.updatedAt),
                        seasonalWindow: seasonalWindow)
                }
                records[idx] = updated
            } else {
                records.append(record)
            }
            return true
        }
    }

    @discardableResult
    func upsert(_ record: OrganizationalRuleRecord,
                seasonalWindow: SeasonalMemoryWindow? = nil) -> Bool {
        mutateJSONL(OrganizationalRuleRecord.self, path: rulesPath) { records in
            if let idx = records.firstIndex(where: { $0.id == record.id }) {
                let created = records[idx].createdAt
                let priorStatus = records[idx].status
                let prior = records[idx]
                var updated = record
                updated.createdAt = created
                updated.updatedAt = max(prior.updatedAt, record.updatedAt)
                updated.confidence = max(prior.confidence, record.confidence)
                updated.evidence = Self.unique(prior.evidence + record.evidence)
                if priorStatus == .active && record.status != .active {
                    updated.status = .active
                    updated.reason = prior.reason
                }
                if let envelope = prior.temporalProjection {
                    updated.temporal = OrganizationalMemoryTemporal.transactionUpdated(
                        envelope,
                        at: Date(timeIntervalSince1970: updated.updatedAt),
                        seasonalWindow: seasonalWindow)
                }
                records[idx] = updated
            } else {
                records.append(record)
            }
            return true
        }
    }

    @discardableResult
    func recordSpecialistEvidenceLedger(kind: LearningEvidenceRecord.Kind,
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

    func seedResearchTasks(plan: Plan, insights: DashboardInsightBundle) -> Int {
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

    func ensureMemoryArchitecture() {
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

    func dedupe(_ items: [CaptainMemoryCandidate]) -> [CaptainMemoryCandidate] {
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

    /// Append one advisory memory observation with an explicit shared temporal envelope. The caller
    /// chooses the shelf's decay class and may attach a real recurrence; no season is inferred from
    /// prose, tags, filenames, or wall-clock month.
    @discardableResult
    func appendGenericMemory(_ raw: DiskMemoryRecord, to path: String,
                             decayRate: MemoryDecayRate = .medium,
                             seasonalWindow: SeasonalMemoryWindow? = nil,
                             at suppliedInstant: Date? = nil) -> Bool {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(suppliedInstant ?? now())
        guard let record = temporalizedGenericMemory(
            raw, at: instant, decayRate: decayRate, seasonalWindow: seasonalWindow) else {
            return false
        }
        return appendJSON(record, to: path)
    }

    /// Stable-ID update for advisory memory. Updating title/body advances transaction time only; it
    /// preserves the original evidence/decay anchor and every lifecycle/season field. A legacy row
    /// with no event clock is retained for audit and a new temporal observation is added beside it,
    /// rather than inventing an age or silently rewriting history.
    @discardableResult
    func upsertGenericMemory(_ raw: DiskMemoryRecord, to path: String,
                             decayRate: MemoryDecayRate = .medium,
                             seasonalWindow: SeasonalMemoryWindow? = nil,
                             at suppliedInstant: Date? = nil) -> Bool {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(suppliedInstant ?? now())
        guard var incoming = temporalizedGenericMemory(
            raw, at: instant, decayRate: decayRate, seasonalWindow: seasonalWindow) else {
            return false
        }
        return mutateJSONL(DiskMemoryRecord.self, path: path) { records in
            if let id = incoming.id,
               let index = records.lastIndex(where: { $0.id == id }) {
                let prior = records[index]
                if let envelope = prior.temporalProjection,
                   let updated = OrganizationalMemoryTemporal.transactionUpdated(
                        envelope, at: instant, seasonalWindow: seasonalWindow) {
                    incoming.createdAt = updated.createdAt.timeIntervalSince1970
                    incoming.updatedAt = updated.updatedAt.timeIntervalSince1970
                    incoming.temporal = updated
                    records[index] = incoming
                } else {
                    // Unknown-age legacy data stays visible to audit but never becomes a fresh claim by
                    // replacement. The temporally explicit row wins operational dedupe/ranking.
                    records.append(incoming)
                }
            } else {
                records.append(incoming)
            }
            return true
        }
    }

    private func temporalizedGenericMemory(
        _ raw: DiskMemoryRecord,
        at instant: Date,
        decayRate: MemoryDecayRate,
        seasonalWindow: SeasonalMemoryWindow?
    ) -> DiskMemoryRecord? {
        var record = Self.bounded(raw)
        if let projection = record.temporalProjection {
            guard projection.decayRate == decayRate else { return nil }
            return record
        }
        guard record.createdAt == nil, record.updatedAt == nil, record.temporal == nil,
              let envelope = OrganizationalMemoryTemporal.make(
                createdAt: instant, decayRate: decayRate,
                seasonalWindow: seasonalWindow) else { return nil }
        record.createdAt = envelope.createdAt.timeIntervalSince1970
        record.updatedAt = envelope.updatedAt.timeIntervalSince1970
        record.temporal = envelope
        return record
    }

    @discardableResult
    func appendJSON<T: Encodable>(_ value: T, to path: String) -> Bool {
        let bounded = Self.boundedDecoded(value)
        guard Self.decodedRowIsMutationSafe(bounded),
              let data = try? JSONEncoder().encode(bounded),
              data.count <= Self.maximumJSONLLineBytes else { return false }
        return withJSONLMutationLock(path: path) {
            do {
                if !FileManager.default.fileExists(atPath: path) {
                    guard FileManager.default.createFile(atPath: path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        return false
                    }
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard let existingBytes = (attributes[.size] as? NSNumber)?.uint64Value else {
                    return false
                }
                let appendBytes = UInt64(data.count + 1)
                guard existingBytes <= UInt64(Self.maximumJSONLFileBytes),
                      appendBytes <= UInt64(Self.maximumJSONLFileBytes) - existingBytes else {
                    return false
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
        } ?? false
    }

    func loadJSONL<T: Decodable>(_ type: T.Type, path: String) -> [T] {
        loadJSONLWithOrdinals(type, path: path).map(\.value)
    }

    func loadJSONLForMutation<T: Decodable>(_ type: T.Type, path: String) -> [T]? {
        guard mutationInputIsWithinHardCaps(path: path) else { return nil }
        return loadJSONLResult(type, path: path).valuesForMutation
    }

    private func mutationInputIsWithinHardCaps(path: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return true }
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              let fileBytes = (attributes[.size] as? NSNumber)?.uint64Value,
              fileBytes <= UInt64(Self.maximumJSONLFileBytes),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: [.mappedIfSafe]),
              data.count <= Self.maximumJSONLFileBytes else { return false }
        var rowCount = 0
        var lineBytes = 0
        for byte in data {
            if byte == 0x0a {
                if lineBytes > 0 {
                    rowCount += 1
                    if rowCount > Self.maximumJSONLRows { return false }
                }
                lineBytes = 0
            } else {
                lineBytes += 1
                if lineBytes > Self.maximumJSONLLineBytes { return false }
            }
        }
        if lineBytes > 0 { rowCount += 1 }
        return rowCount <= Self.maximumJSONLRows
    }

    /// Keeps the physical line number after malformed rows are skipped. This makes equal-score
    /// ordering deterministic without letting one damaged JSONL line hide the safe lines around it.
    func loadJSONLWithOrdinals<T: Decodable>(
        _ type: T.Type, path: String
    ) -> [OrganizationalJSONLRow<T>] {
        loadJSONLResult(type, path: path).readableRows
    }

    /// Audit reads fail soft and return every independently safe row. Mutation callers receive the
    /// richer state and may rewrite only `.complete` or `.missing`; a cap, malformed line, invalid
    /// temporal projection, or I/O failure can therefore never collapse a durable archive.
    func loadJSONLResult<T: Decodable>(
        _ type: T.Type, path: String
    ) -> OrganizationalJSONLLoadResult<T> {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return .missing }
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              let fileBytes = (attributes[.size] as? NSNumber)?.uint64Value else {
            return .failure
        }
        guard fileBytes <= UInt64(Self.maximumJSONLFileBytes) else { return .refused }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: [.mappedIfSafe]) else { return .failure }
        guard data.count <= Self.maximumJSONLFileBytes else { return .refused }

        var rows: [OrganizationalJSONLRow<T>] = []
        rows.reserveCapacity(min(Self.maximumJSONLRows, 1_024))
        var nonemptyRows = 0
        var incomplete = false
        for (ordinal, line) in data.split(separator: 0x0a, omittingEmptySubsequences: false).enumerated() {
            guard !line.isEmpty else { continue }
            nonemptyRows += 1
            guard nonemptyRows <= Self.maximumJSONLRows else {
                incomplete = true
                break
            }
            guard line.count <= Self.maximumJSONLLineBytes,
                  let decoded = try? JSONDecoder().decode(T.self, from: Data(line)) else {
                incomplete = true
                continue
            }
            let bounded = Self.boundedDecoded(decoded)
            if !Self.decodedRowIsMutationSafe(bounded) { incomplete = true }
            rows.append(OrganizationalJSONLRow(ordinal: ordinal, value: bounded))
        }
        return incomplete ? .partial(rows) : .complete(rows)
    }

    @discardableResult
    func saveJSONL<T: Codable>(_ values: [T], to path: String) -> Bool {
        withJSONLMutationLock(path: path) {
            saveJSONLUnlocked(values, to: path)
        } ?? false
    }

    /// Holds the same sidecar lock across load, transform, and atomic replacement. Locking only the
    /// final write loses concurrent updates because every participant can otherwise read the same
    /// old generation and overwrite the other's result.
    func mutateJSONL<T: Codable>(
        _ type: T.Type,
        path: String,
        _ mutation: (inout [T]) -> Bool
    ) -> Bool {
        withJSONLMutationLock(path: path) {
            guard var values = loadJSONLForMutation(type, path: path),
                  mutation(&values) else { return false }
            return saveJSONLUnlocked(values, to: path)
        } ?? false
    }

    private func saveJSONLUnlocked<T: Codable>(_ values: [T], to path: String) -> Bool {
        guard values.count <= Self.maximumJSONLRows,
              mutationInputIsWithinHardCaps(path: path) else { return false }
        switch loadJSONLResult(T.self, path: path) {
        case .missing, .complete: break
        case .partial, .refused, .failure: return false
        }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
        } catch {
            return false
        }
        var output = Data()
        for value in values {
            let bounded = Self.boundedDecoded(value)
            guard Self.decodedRowIsMutationSafe(bounded),
                  let data = try? JSONEncoder().encode(bounded),
                  data.count <= Self.maximumJSONLLineBytes,
                  output.count <= Self.maximumJSONLFileBytes - data.count - 1 else {
                return false
            }
            output.append(data)
            output.append(0x0a)
        }
        do {
            try output.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// A per-ledger advisory lock used by every organizational JSONL mutation path. It is not an
    /// authority seal; it only prevents cooperative local writers from dropping one another's rows.
    private func withJSONLMutationLock<T>(path: String, _ body: () -> T) -> T? {
        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
#if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(
            path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX) == 0 else { return nil }
#endif
        return body()
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

    static func boundedDecoded<T>(_ value: T) -> T {
        if let capsule = value as? LearningCapsule {
            return (bounded(capsule) as? T) ?? value
        }
        if let debt = value as? KnowledgeDebtRecord {
            return (bounded(debt) as? T) ?? value
        }
        if let rule = value as? OrganizationalRuleRecord {
            return (bounded(rule) as? T) ?? value
        }
        if let memory = value as? DiskMemoryRecord {
            return (bounded(memory) as? T) ?? value
        }
        if let evidence = value as? LearningEvidenceRecord {
            return (bounded(evidence) as? T) ?? value
        }
        return value
    }

    static func decodedRowIsMutationSafe<T>(_ value: T) -> Bool {
        if let capsule = value as? LearningCapsule {
            return capsule.temporalProjection != nil
        }
        if let debt = value as? KnowledgeDebtRecord {
            return debt.temporalProjection != nil
        }
        if let rule = value as? OrganizationalRuleRecord {
            return rule.temporalProjection != nil
        }
        if let memory = value as? DiskMemoryRecord {
            let allLegacyFieldsMissing = memory.createdAt == nil
                && memory.updatedAt == nil && memory.temporal == nil
            return allLegacyFieldsMissing || memory.temporalProjection != nil
        }
        return true
    }

    static func bounded(_ value: LearningCapsule) -> LearningCapsule {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.taskTitle = boundedText(value.taskTitle, limit: 2_048)
        value.summary = boundedText(value.summary, limit: 8_192)
        value.learned = boundedStrings(value.learned)
        value.surprises = boundedStrings(value.surprises)
        value.slowdowns = boundedStrings(value.slowdowns)
        value.assumptionsToChallenge = boundedStrings(value.assumptionsToChallenge)
        value.futureEvolution = boundedText(value.futureEvolution, limit: 8_192)
        value.tokenCount = min(1_000_000_000, max(0, value.tokenCount))
        return value
    }

    static func bounded(_ value: KnowledgeDebtRecord) -> KnowledgeDebtRecord {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.topic = boundedText(value.topic, limit: 2_048)
        value.reason = boundedText(value.reason, limit: 8_192)
        value.visit = boundedText(value.visit, limit: 8_192)
        value.impact = min(5, max(1, value.impact))
        value.estimatedLearning = boundedText(value.estimatedLearning, limit: 2_048)
        value.expectedBenefit = boundedStrings(value.expectedBenefit)
        value.sourceCapsuleID = value.sourceCapsuleID.map { boundedText($0, limit: 256) }
        return value
    }

    static func bounded(_ value: OrganizationalRuleRecord) -> OrganizationalRuleRecord {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.lesson = boundedText(value.lesson, limit: 4_096)
        value.confidence = min(100, max(1, value.confidence))
        value.reason = boundedText(value.reason, limit: 8_192)
        value.evidence = boundedStrings(value.evidence)
        value.sourceCapsuleID = value.sourceCapsuleID.map { boundedText($0, limit: 256) }
        return value
    }

    static func bounded(_ value: DiskMemoryRecord) -> DiskMemoryRecord {
        var value = value
        value.id = value.id.map { boundedText($0, limit: 256) }
        value.title = value.title.map { boundedText($0, limit: 2_048) }
        value.summary = value.summary.map { boundedText($0, limit: 8_192) }
        value.body = value.body.map { boundedText($0, limit: 16_384) }
        value.source = value.source.map { boundedText($0, limit: 4_096) }
        value.confidence = value.confidence.map { min(100, max(0, $0)) }
        value.impact = value.impact.map { min(5, max(0, $0)) }
        value.tags = value.tags.map { boundedStrings($0) }
        return value
    }

    static func bounded(_ value: LearningEvidenceRecord) -> LearningEvidenceRecord {
        var value = value
        value.id = boundedText(value.id, limit: 256)
        value.objective = boundedText(value.objective, limit: 8_192)
        value.specialistName = boundedText(value.specialistName, limit: 512)
        value.role = boundedText(value.role, limit: 2_048)
        value.preferredModel = boundedText(value.preferredModel, limit: 512)
        value.artifactPath = boundedText(value.artifactPath, limit: 4_096)
        value.taskIDs = Array(value.taskIDs.prefix(1_024))
        value.taskEvidenceUpdated = min(1_024, max(0, value.taskEvidenceUpdated))
        return value
    }

    static func boundedStrings(_ values: [String], count: Int = 64,
                               each: Int = 4_096) -> [String] {
        values.prefix(max(0, count)).map { boundedText($0, limit: each) }
    }

    static func boundedText(_ text: String, limit: Int) -> String {
        let clean = safe(text)
        let maximumBytes = max(0, limit)
        let bytes = clean.utf8
        guard bytes.count > maximumBytes else { return clean }
        var end = bytes.index(bytes.startIndex, offsetBy: maximumBytes)
        while end > bytes.startIndex,
              (bytes[end] & 0b1100_0000) == 0b1000_0000 {
            end = bytes.index(before: end)
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    static func makeID(prefix: String, title: String, at: Date) -> String {
        "\(prefix)-\(Int(at.timeIntervalSince1970))-\(slug(title).prefix(28))"
    }

    func resolveProjectFile(_ raw: String) -> String? {
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

    static func slug(_ raw: String) -> String {
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

    static func safe(_ text: String) -> String {
        let redacted = SecretScanner.redactSecrets(in: text)
        return redacted.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func trimCommandOutput(_ text: String, limit: Int = 12_000) -> String {
        let safe = Self.safe(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if safe.isEmpty { return "(empty)" }
        if safe.count <= limit { return safe }
        return String(safe.prefix(limit)) + "\n... truncated ..."
    }

    func excerpt(_ text: String, limit: Int = 420) -> String {
        let clean = Self.safe(text)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if clean.count <= limit { return clean }
        return String(clean.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            out.append(value)
        }
        return out
    }

    static func boardTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["PLAN:", "ACTION:", "TEST:", "REVIEW:", "RESEARCH:", "DECISION:", "HANDOFF:", "BACKLOG:"] {
            if trimmed.uppercased().hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).description
            }
        }
        return trimmed
    }

    static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    static func projectRelative(_ path: String, root: String) -> String {
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

    func stars(_ value: Int) -> String {
        Self.stars(value)
    }

    static func stars(_ value: Int) -> String {
        let clamped = min(5, max(1, value))
        return String(repeating: "★", count: clamped) + String(repeating: "☆", count: 5 - clamped)
    }
}

extension String {
    var singleLine: String {
        replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
