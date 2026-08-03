import Foundation
import AgentCore

struct OrganizationalLearningStore: Sendable {
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
                    objective: String? = nil) -> LearningCapsule {
        let bundle = insights ?? DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                                trajectory: trajectory)
        let capsule = makeCapsule(plan: plan, spans: spans, trajectory: trajectory,
                                  outcomeSummary: outcomeSummary, success: success,
                                  objective: objective)
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

    func memoryCandidates() -> [CaptainMemoryCandidate] {
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

    func evidenceLedgerCandidates(limit: Int) -> [CaptainMemoryCandidate] {
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

    func captainLearningBenchmarkCandidates(limit: Int) -> [CaptainMemoryCandidate] {
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

    func genericMemoryCandidates(path: String,
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

    func researchArchiveCandidates(limit: Int) -> [CaptainMemoryCandidate] {
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

    func makeCapsule(plan: Plan, spans: [AgentSpan], trajectory: [ActionRecord],
                             outcomeSummary: String, success: Bool,
                             objective: String? = nil) -> LearningCapsule {
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

    func upsert(_ record: KnowledgeDebtRecord) {
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

    func upsert(_ record: OrganizationalRuleRecord) {
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

    @discardableResult
    func appendJSON<T: Encodable>(_ value: T, to path: String) -> Bool {
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

    func loadJSONL<T: Decodable>(_ type: T.Type, path: String) -> [T] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(T.self, from: Data(line.utf8))
        }
    }

    @discardableResult
    func saveJSONL<T: Encodable>(_ values: [T], to path: String) -> Bool {
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
