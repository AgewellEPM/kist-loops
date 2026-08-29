import Foundation
import AgentCore

extension OrganizationalLearningStore {
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
        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        let timestamp = Int(instant.timeIntervalSince1970)
        let path = researchArchiveRoot + "/domain-learning/\(timestamp)-\(Self.slug(strategy.objective)).md"
        let relativePath = Self.projectRelative(path, root: projectRoot)
        let seededTasks = seedDomainLearningTasks(strategy: strategy,
                                                  assignments: assignments,
                                                  reportPath: relativePath,
                                                  trajectory: trajectory)
        let dispatchCommand = "/domain run \(strategy.objective)"
        var memoryRecords = 0
        var text = renderDomainLearningReport(strategy: strategy,
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

            memoryRecords = recordDomainLearningMemory(strategy: strategy,
                                                       retrieval: retrieval,
                                                       reportPath: relativePath,
                                                       trajectory: trajectory,
                                                       at: instant)
            let finalizedText = renderDomainLearningReport(
                strategy: strategy,
                retrieval: retrieval,
                assignments: assignments,
                reportPath: relativePath,
                seededTasks: seededTasks,
                knowledgeDebtCreated: knowledgeDebt,
                createdSpecialists: createdStrategySpecialists + createdLearningSpecialists,
                memoryRecords: memoryRecords,
                dispatchCommand: dispatchCommand)
            try (finalizedText + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            text = finalizedText
        } catch {
            writeSucceeded = false
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

        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        let timestamp = Int(instant.timeIntervalSince1970)
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

        let memoryRecorded = appendGenericMemory(DiskMemoryRecord(
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
        ), to: knowledgeIndexPath, decayRate: .medium, at: instant)

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

    func createDomainLearningSpecialists(strategy: CaptainStrategyPlan) -> Int {
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

    func domainLearningAssignments(strategy: CaptainStrategyPlan,
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

    func seedDomainLearningKnowledgeDebt(strategy: CaptainStrategyPlan,
                                                 objective: String) -> Int {
        var count = 0
        for item in strategy.understanding.missingKnowledge.prefix(6) {
            if addKnowledgeDebt(topic: "Domain learning: \(item)",
                                reason: "Captain is below the temporary subject-matter expert confidence gate for: \(objective)",
                                visit: "Primary docs, standards, competitors, papers, open source, and local project evidence.",
                                impact: 5,
                                priority: .high,
                                estimatedLearning: strategy.understanding.recommendedResearchTime,
                                expectedBenefit: ["raise Captain understanding above \(strategy.understanding.threshold)%", "avoid premature specialist assignment"]) != nil {
                count += 1
            }
        }
        for question in strategy.researchQuestions.prefix(4) {
            if addKnowledgeDebt(topic: "Research question: \(question)",
                                reason: "Domain learning preflight requires this answer before execution.",
                                visit: "Official docs and primary sources for \(objective)",
                                impact: 4,
                                priority: .high,
                                estimatedLearning: "30-60 minutes",
                                expectedBenefit: ["turn uncertainty into evidence-backed planning"]) != nil {
                count += 1
            }
        }
        return count
    }

    func seedDomainLearningTasks(strategy: CaptainStrategyPlan,
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
    func recordDomainLearningMemory(strategy: CaptainStrategyPlan,
                                            retrieval: CaptainRetrievalContext,
                                            reportPath: String,
                                            trajectory: [ActionRecord],
                                            at instant: Date) -> Int {
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
        if upsertGenericMemory(
            record, to: knowledgeIndexPath, decayRate: .fast, at: instant) {
            count += 1
        }
        return count
    }

    func renderDomainLearningReport(strategy: CaptainStrategyPlan,
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

}
