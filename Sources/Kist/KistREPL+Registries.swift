import Foundation
import AgentCore

// /agents and /cortex handlers — the specialist registry + personal-memory views.
// Extracted verbatim from KistREPL.swift (Pass-1 modularization; no behavior change).
extension KistREPL {

    /// `/tasks` subcommands over the project's shared plan (.kist/plan.json):
    ///   /tasks                 show the plan
    ///   /tasks add <title> [| acceptance: ... | verify: ... | evidence: ...]
    ///   /tasks start [id]      start a task (or the next todo)
    ///   /tasks done <id>       mark done
    ///   /tasks block <id> <why>  mark blocked
    ///   /tasks evidence <id> <proof>  attach proof to a task
    ///   /tasks validate      show contract issues (missing acceptance/verification/evidence)
    ///   /tasks clear           empty the plan
    /// `/agents` — list/show the specialist registry (`<project>/.kist/agents/` + user scope).
    /// Read-only in P1; forging from a description lands in P3.
    static func handleAgents(_ args: String, projectRoot: String) -> String {
        let reg = SpecialistRegistry(projectRoot: projectRoot)
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let sub = parts.first?.lowercased()
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch sub {
        case "show":
            guard !rest.isEmpty, let d = reg.named(rest) else { return "usage: /agents show <name> (unknown: \(rest))" }
            let tools = d.toolAllowlist.map { $0.joined(separator: ", ") } ?? "inherit all"
            let model = d.model.map { $0.providerId + ($0.model.map { ":\($0)" } ?? "") } ?? "inherit"
            return """
            \u{001B}[1m\(d.name)\u{001B}[0m  \u{001B}[37m(\(d.source))\u{001B}[0m
            when: \(d.description)
            tools: \(tools)   model: \(model)
            ---
            \(d.systemPrompt)
            """
        default:
            let all = reg.load()
            guard !all.isEmpty else {
                return "no specialists yet — use /agent new <role description> or add one at \(projectRoot)/.kist/agents/<name>.md."
            }
            let rows = all.map { "  \u{001B}[36m\($0.name)\u{001B}[0m \u{001B}[37m·\u{001B}[0m \($0.description)" }
            return "specialists (\(all.count)):\n" + rows.joined(separator: "\n") + "\n\u{001B}[37m/agents show <name> for detail\u{001B}[0m"
        }
    }


    /// `/cortex` — explicit operator audit of the retired Markdown archive. It is never prompt context.
    static func handleCortex(_ args: String, cortex: CortexMemory?) -> String {
        guard let cortex else { return "cortex memory is off (started with --no-memory)." }
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let sub = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        switch sub {
        case "remember":
            _ = rest
            return "legacy cortex Markdown is raw audit-only; use temporal semantic memory or operator-owned AGENTS.md"
        case "project":
            _ = rest
            return "legacy cortex Markdown is raw audit-only; use temporal semantic memory or operator-owned project facts"
        case "files", "ls":
            let fs = cortex.files()
            return fs.isEmpty ? "no cortex files yet." : "cortex files (\(cortex.root)):\n" + fs.map { "  " + $0 }.joined(separator: "\n")
        case "show", "cat":
            guard !rest.isEmpty else { return "usage: /cortex show <file> (see /cortex files)" }
            return cortex.show(rest) ?? "no such cortex file: \(rest)"
        default:
            let fs = cortex.files()
            let listing = fs.isEmpty ? "no legacy cortex files." :
                fs.map { "  " + $0 }.joined(separator: "\n")
            return "legacy cortex Markdown is raw audit-only (never injected into prompts):\n"
                + listing + "\n\u{001B}[2m/cortex files · /cortex show <file>\u{001B}[0m"
        }
    }

    /// `/knowledge` — the durable knowledge-debt ledger. This is distinct from the task board:
    /// it tracks what the organization should learn before architecture hardens around weak assumptions.
    static func handleKnowledgeCommand(_ args: String, projectRoot: String) -> String {
        let store = OrganizationalLearningStore(projectRoot: projectRoot)
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let sub = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch sub {
        case "", "list", "show":
            return store.renderKnowledgeDebt()
        case "add":
            guard !rest.isEmpty else {
                return "usage: /knowledge add <topic> | reason: ... | visit: ... | impact: 1-5 | priority: high|medium | benefit: ..."
            }
            let fields = parseKnowledgeDebt(rest)
            guard let record = store.addKnowledgeDebt(topic: fields.topic,
                                                      reason: fields.reason,
                                                      visit: fields.visit,
                                                      impact: fields.impact,
                                                      priority: fields.priority,
                                                      estimatedLearning: fields.estimatedLearning,
                                                      expectedBenefit: fields.expectedBenefit) else {
                return "knowledge debt NOT added · persistence refused; existing ledger preserved"
            }
            return "knowledge debt added · \(record.id)\n" + store.renderKnowledgeDebt(limit: 6)
        case "done", "close", "paid":
            guard !rest.isEmpty else { return "usage: /knowledge done <id>" }
            return store.markKnowledgeDebtDone(rest)
                ? "knowledge debt closed · \(rest)"
                : "no open knowledge debt with id \(rest)"
        default:
            return "usage: /knowledge [list] · /knowledge add <topic> | reason: ... | impact: 1-5 · /knowledge done <id>"
        }
    }

    /// `/teach` — promote durable organizational lessons into Captain rules.
    /// This is intentionally separate from memory: it captures operating principles that should
    /// steer future objectives, not facts from the transcript.
    static func handleTeachCommand(_ args: String, projectRoot: String) -> String {
        let store = OrganizationalLearningStore(projectRoot: projectRoot)
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let sub = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch sub {
        case "", "list", "show", "rules":
            return store.renderOrganizationalRules()
        case "add", "promote":
            guard !rest.isEmpty else {
                return "usage: /teach add <lesson> | confidence: 97 | reason: ... | evidence: ..."
            }
            let fields = parseOrganizationalRule(rest)
            guard let rule = store.promoteOrganizationalRule(lesson: fields.lesson,
                                                             confidence: fields.confidence,
                                                             reason: fields.reason,
                                                             evidence: fields.evidence) else {
                return "organizational rule NOT recorded · persistence refused; existing ledger preserved"
            }
            let status = rule.status == .active ? "promoted" : "proposed — awaiting verified evidence"
            return "organizational rule \(status) · \(rule.id)\n" + store.renderOrganizationalRules(limit: 6)
        default:
            return "usage: /teach [list] · /teach add <lesson> | confidence: 97 | reason: ... | evidence: ..."
        }
    }

    static func handleCaptainStrategyCommand(_ objective: String, projectRoot: String) -> String {
        let evidence = CaptainProjectEvidence.capture(projectRoot: projectRoot)
        let specialists = SpecialistRegistry(projectRoot: projectRoot).load()
        let plan = CaptainStrategist.plan(objective: objective, evidence: evidence,
                                          specialists: specialists)
        let retrieval = OrganizationalLearningStore(projectRoot: projectRoot)
            .retrievalContext(objective: objective, strategy: plan)
        return plan.briefing + "\n\n" + retrieval.briefing
    }

    static func handleRetrieveCommand(
        _ objective: String, projectRoot: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> String {
        let clean = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "usage: /retrieve <objective>" }
        let evidence = CaptainProjectEvidence.capture(projectRoot: projectRoot)
        let specialists = SpecialistRegistry(projectRoot: projectRoot).load()
        let plan = CaptainStrategist.plan(objective: clean, evidence: evidence,
                                          specialists: specialists)
        return OrganizationalLearningStore(projectRoot: projectRoot, now: now)
            .retrievalContext(objective: clean, strategy: plan)
            .briefing
    }

    static func handleCaptainLearningCommand(
        _ args: String, projectRoot: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> String {
        OrganizationalLearningStore(projectRoot: projectRoot, now: now).renderCaptainLearning()
    }

    static func handleStrategicIntelligenceCommand(_ args: String, projectRoot: String) -> String {
        OrganizationalLearningStore(projectRoot: projectRoot).renderStrategicIntelligence()
    }

    static func handleSelfHealCommand(_ args: String, projectRoot: String,
                                      trajectory: [ActionRecord] = []) -> SelfHealMissionReport {
        let objective = normalizedSelfHealObjective(args)
        let store = OrganizationalLearningStore(projectRoot: projectRoot)
        return store.runSelfHealMission(plan: PlanStore(projectRoot: projectRoot).load(),
                                        trajectory: trajectory,
                                        objective: objective)
    }

    static func handleDomainLearningCommand(_ args: String, projectRoot: String,
                                            trajectory: [ActionRecord] = []) -> DomainLearningReport {
        let objective = normalizedDomainLearningObjective(args)
        let store = OrganizationalLearningStore(projectRoot: projectRoot)
        return store.runDomainLearningPreflight(plan: PlanStore(projectRoot: projectRoot).load(),
                                                trajectory: trajectory,
                                                objective: objective)
    }

    static func handleLegalResearchCommand(_ args: String, projectRoot: String,
                                           trajectory: [ActionRecord] = []) -> LegalResearchReport {
        LegalResearchWorkflow(projectRoot: projectRoot).run(input: args, trajectory: trajectory)
    }

    static func isLegalResearchIntent(_ raw: String) -> Bool {
        LegalResearchWorkflow.isLegalResearchIntent(raw)
    }

    static func legalResearchShouldRun(_ raw: String) -> Bool {
        LegalResearchWorkflow.shouldAutoRunResearch(raw)
    }

    static func legalResearchHasExternalDocumentConsent(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let markers = [
            "--send-docs", "--allow-external", "--external-ok",
            "external ok", "send document to model", "send documents to model",
            "share document with model", "share documents with model",
            "i consent to send", "i consent"
        ]
        return markers.contains { lower.contains($0) }
    }

    static func handleLocalModelScoutCommand(_ args: String, projectRoot: String) -> LocalModelScoutReport {
        let objective = normalizedLocalModelScoutObjective(args)
        return OrganizationalLearningStore(projectRoot: projectRoot).runLocalModelScout(objective: objective)
    }

    static func handleLiveModelMetadataGateCommand(_ args: String,
                                                   projectRoot: String,
                                                   fetcher: LiveModelMetadataFetcher = LiveModelMetadataFetcher()) async -> LiveModelMetadataGateReport {
        let spec = normalizedLiveModelMetadataGateSpec(args)
        return await OrganizationalLearningStore(projectRoot: projectRoot)
            .runLiveModelMetadataGate(spec: spec, fetcher: fetcher)
    }

    static func handleLocalModelAcquisitionCommand(_ args: String, projectRoot: String) -> LocalModelAcquisitionPreflightReport {
        let manifestPath = normalizedLocalModelAcquisitionPath(args)
        return OrganizationalLearningStore(projectRoot: projectRoot)
            .runLocalModelAcquisitionPreflight(manifestPath: manifestPath)
    }

    static func handleLocalModelAcquisitionRunCommand(_ args: String, projectRoot: String) -> LocalModelAcquisitionRunReport {
        let parsed = parseLocalModelAcquisitionRun(args)
        return OrganizationalLearningStore(projectRoot: projectRoot)
            .runLocalModelAcquisitionStage(stage: parsed.stage, manifestPath: parsed.manifestPath)
    }

    static func handleSelfTestCommand(_ args: String, projectRoot: String) -> CaptainSelfTestReport {
        CaptainSelfTestSuite(projectRoot: projectRoot).run(seedFindings: selfTestShouldSeed(args))
    }

    static func handleImmuneCommand(_ args: String, projectRoot: String,
                                    trajectory: [ActionRecord] = []) -> CaptainImmuneSystemReport {
        CaptainImmuneSystem(projectRoot: projectRoot)
            .run(seedRepairs: immuneShouldSeedRepairs(args), trajectory: trajectory)
    }

    static func selfTestUsageIfNeeded(_ args: String) -> String? {
        let clean = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valid = ["", "check", "run", "seed", "--seed"]
        guard !valid.contains(clean) else { return nil }
        if clean == "help" || clean == "--help" || clean == "-h" {
            return "usage: /self-test [check|run|--seed]\nDefault writes a static report only. `run`/`--seed` also seeds repair/review tasks for findings."
        }
        return "usage: /self-test [check|run|--seed]\nUnknown self-test argument: \(clean)"
    }

    static func selfTestShouldSeed(_ args: String) -> Bool {
        let clean = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean == "run" || clean == "seed" || clean == "--seed"
    }

    static func immuneUsageIfNeeded(_ args: String) -> String? {
        let clean = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valid = ["", "check", "--check", "run", "repair", "seed", "--seed"]
        guard !valid.contains(clean) else { return nil }
        if clean == "help" || clean == "--help" || clean == "-h" {
            return "usage: /immune [check|run|repair]\nDefault runs Captain's immune audit and seeds repair tasks. `check` writes the report without seeding."
        }
        return "usage: /immune [check|run|repair]\nUnknown immune argument: \(clean)"
    }

    static func immuneShouldSeedRepairs(_ args: String) -> Bool {
        let clean = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return clean != "check" && clean != "--check"
    }

    static func normalizedLocalModelScoutObjective(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        for prefix in ["scout ", "plan ", "research ", "recommend "] where lower.hasPrefix(prefix) {
            clean = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return clean.isEmpty ? "safe local model acquisition" : clean
    }

    static func normalizedLiveModelMetadataGateSpec(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        for verb in ["vet", "verify", "metadata", "allow", "gate", "check"] {
            if lower == verb { return "" }
            let prefix = verb + " "
            if lower.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return clean
    }

    static func normalizedLocalModelAcquisitionPath(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = clean.lowercased()
        for verb in ["acquire", "acquisition", "preflight"] {
            if lower == verb { return "" }
            let prefix = verb + " "
            if lower.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return clean
    }

    static func parseLocalModelAcquisitionRun(_ raw: String) -> (stage: String, manifestPath: String) {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var lower = clean.lowercased()
        for verb in ["run", "execute", "stage"] {
            if lower == verb { return ("", "") }
            let prefix = verb + " "
            if lower.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                lower = clean.lowercased()
                break
            }
        }
        let parts = clean.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let stage = parts.first else { return ("", "") }
        let manifestPath = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (String(stage), manifestPath)
    }

    static func isLocalModelAcquisitionRunIntent(command: String, args: String) -> Bool {
        let clean = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let command = command.lowercased()
        if ["model-run", "run-model-acquire", "model-acquisition-run"].contains(command) { return true }
        guard ["model", "m", "local-model", "local-models", "model-scout"].contains(command) else { return false }
        let parsed = parseLocalModelAcquisitionRun(clean)
        return LocalModelAcquisitionStage.parse(parsed.stage) != nil && !parsed.manifestPath.isEmpty
    }

    static func isLocalModelAcquisitionIntent(command: String, args: String) -> Bool {
        let clean = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let lower = clean.lowercased()
        let verbs = ["acquire", "acquisition", "preflight"]
        let command = command.lowercased()
        if ["model-acquire", "acquire-model"].contains(command) { return true }
        guard ["model", "m", "local-model", "local-models", "model-scout"].contains(command) else { return false }
        return verbs.contains(lower) || verbs.contains(where: { lower.hasPrefix($0 + " ") })
    }

    static func isLiveModelMetadataGateIntent(command: String, args: String) -> Bool {
        let clean = args.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        let lower = clean.lowercased()
        let verbs = ["vet", "verify", "metadata", "allow", "gate", "check"]
        if verbs.contains(lower) || verbs.contains(where: { lower.hasPrefix($0 + " ") }) {
            return true
        }
        let command = command.lowercased()
        if ["hf", "huggingface"].contains(command) {
            let scoutVerbs = ["scout", "plan", "research", "recommend"]
            return !(scoutVerbs.contains(lower) || scoutVerbs.contains(where: { lower.hasPrefix($0 + " ") }))
        }
        return false
    }

    static func handleSimulationCommand(_ args: String, projectRoot: String,
                                        trajectory: [ActionRecord] = []) -> CaptainSimulationGateReport {
        let objective = normalizedSimulationObjective(args)
        let store = OrganizationalLearningStore(projectRoot: projectRoot)
        return store.runSimulationGate(plan: PlanStore(projectRoot: projectRoot).load(),
                                       trajectory: trajectory,
                                       objective: objective,
                                       measuredTrialMode: simulationShouldRunExecutableTrials(args) ? .interactive : .preflight)
    }

    static func handleSymbolicWorkflowCommand(_ args: String, projectRoot: String,
                                              trajectory: [ActionRecord] = []) -> String {
        let store = SymbolicWorkflowStore(projectRoot: projectRoot)
        let parts = args.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        let sub = parts.first?.lowercased() ?? ""
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch sub {
        case "", "list", "show":
            return store.list()
        case "compile", "promote", "learn":
            let report = store.compile(plan: PlanStore(projectRoot: projectRoot).load(),
                                       objective: rest,
                                       trajectory: trajectory)
            return report.text + "\n\nwritten: \(report.path)"
        case "run", "use", "apply", "deploy":
            let runParts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard let id = runParts.first else {
                return "usage: /symbolic run <workflow-id> <target>"
            }
            let input = runParts.count > 1 ? runParts[1] : ""
            guard let report = store.run(id: id, input: input) else {
                return "unknown symbolic workflow '\(id)'.\n\n" + store.list(limit: 8)
            }
            return report.text
        default:
            return "usage: /symbolic [list] · /symbolic compile <objective> · /symbolic run <workflow-id> <target>"
        }
    }

    static func isSimulationIntent(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return lower == "simulate" || lower == "simulation"
            || lower == "sandbox" || lower == "risk"
            || lower.hasPrefix("simulate ")
            || lower.hasPrefix("simulation ")
            || lower.hasPrefix("sandbox ")
            || lower.hasPrefix("risk ")
    }

    static func normalizedSimulationObjective(_ raw: String) -> String {
        simulationPayload(raw)
    }

    static func simulationShouldRunExecutableTrials(_ raw: String) -> Bool {
        simulationExecutionVerb(stripSimulationPrefix(raw)) != nil
    }

    private static func simulationPayload(_ raw: String) -> String {
        var text = stripSimulationPrefix(raw)
        if let verb = simulationExecutionVerb(text) {
            text = String(text.dropFirst(verb.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefixes = ["simulate", "simulation", "sandbox", "risk"]
        for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let wordsToDrop: Set<String> = ["now", "gate"]
        let kept = text.split(separator: " ").filter { !wordsToDrop.contains($0.lowercased()) }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripSimulationPrefix(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["simulate", "simulation", "sandbox", "risk"]
        for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }

    private static func simulationExecutionVerb(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(separator: " ").first else { return nil }
        let lower = first.lowercased()
        return ["run", "exec", "execute", "--exec"].contains(String(lower)) ? String(first) : nil
    }

    static func isSelfHealIntent(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return lower == "fix-self" || lower == "fix self"
            || lower == "self-heal" || lower == "self heal"
            || lower == "heal-self" || lower == "heal self"
            || lower.hasPrefix("fix-self ")
            || lower.hasPrefix("fix self ")
            || lower.hasPrefix("self-heal ")
            || lower.hasPrefix("self heal ")
            || lower.hasPrefix("heal-self ")
            || lower.hasPrefix("heal self ")
    }

    static func selfHealShouldRun(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains("run") || tokens.contains("dispatch") || tokens.contains("now")
    }

    static func normalizedSelfHealObjective(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["fix-self", "fix self", "self-heal", "self heal", "heal-self", "heal self"]
        for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let wordsToDrop: Set<String> = ["run", "dispatch", "now"]
        let kept = text.split(separator: " ").filter { !wordsToDrop.contains($0.lowercased()) }
        let objective = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return objective.isEmpty
            ? "Captain self-heal: follow the dashboard's own advice by assigning research, build, review, benchmark, and Teach Captain gates."
            : objective
    }

    static func shouldAutoSuperviseFailure(goal: String) -> Bool {
        let lower = goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        if lower.hasPrefix("/") {
            return false
        }
        if isSelfHealIntent(lower)
            || lower.hasPrefix("failures")
            || lower.hasPrefix("failure-analysis")
            || lower.hasPrefix("self-test")
            || lower.hasPrefix("selftest")
            || lower.hasPrefix("immune")
            || lower.hasPrefix("simulate")
            || lower.hasPrefix("simulation") {
            return false
        }
        return true
    }

    static func supervisorRepairObjective(for capsule: CaptainFailureCapsule) -> String {
        "Captain continuous supervisor: investigate \(capsule.id) (\(capsule.likelyLayer.rawValue)) -- \(capsule.observed)"
    }

    static func isDomainLearningIntent(_ raw: String) -> Bool {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        return lower == "learn" || lower == "domain" || lower == "domain-learning"
            || lower == "research-first" || lower == "sme"
            || lower.hasPrefix("learn ")
            || lower.hasPrefix("domain ")
            || lower.hasPrefix("domain-learning ")
            || lower.hasPrefix("research-first ")
            || lower.hasPrefix("sme ")
    }

    static func domainLearningShouldRun(_ raw: String) -> Bool {
        guard let first = domainLearningPayload(raw).split(separator: " ").first?.lowercased() else {
            return false
        }
        return ["run", "dispatch", "now"].contains(String(first))
    }

    static func normalizedDomainLearningObjective(_ raw: String) -> String {
        var text = domainLearningPayload(raw)
        if let first = text.split(separator: " ").first,
           ["run", "dispatch", "now"].contains(first.lowercased()) {
            text = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let objective = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return objective.isEmpty
            ? "Learn the domain, become a temporary subject-matter expert, assemble specialists, simulate risk, and only then execute."
            : objective
    }

    private static func domainLearningPayload(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["domain-learning", "research-first", "domain", "learn", "sme"]
        for prefix in prefixes where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text
    }

    struct ParsedKnowledgeDebt: Equatable {
        var topic: String
        var reason: String = ""
        var visit: String = ""
        var impact: Int = 3
        var priority: KnowledgeDebtRecord.Priority = .medium
        var estimatedLearning: String = ""
        var expectedBenefit: [String] = []
    }

    struct ParsedOrganizationalRule: Equatable {
        var lesson: String
        var confidence: Int = 90
        var reason: String = ""
        var evidence: [String] = []
    }

    static func parseKnowledgeDebt(_ raw: String) -> ParsedKnowledgeDebt {
        let chunks = raw.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out = ParsedKnowledgeDebt(topic: chunks.first ?? raw.trimmingCharacters(in: .whitespacesAndNewlines))
        for chunk in chunks.dropFirst() {
            guard let colon = chunk.firstIndex(of: ":") else {
                out.reason = out.reason.isEmpty ? chunk : out.reason + " " + chunk
                continue
            }
            let key = chunk[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = chunk[chunk.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "reason", "why":
                out.reason = value
            case "visit", "source", "url", "site", "docs":
                out.visit = value
            case "impact", "stars", "roi":
                out.impact = min(5, max(1, Int(String(value.filter(\.isNumber))) ?? out.impact))
            case "priority":
                out.priority = value.lowercased().contains("high") ? .high : .medium
            case "learning", "estimate", "time":
                out.estimatedLearning = value
            case "benefit", "expected benefit", "outcome":
                out.expectedBenefit = value.split(separator: ";").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            default:
                out.reason = out.reason.isEmpty ? chunk : out.reason + " " + chunk
            }
        }
        return out
    }

    static func parseOrganizationalRule(_ raw: String) -> ParsedOrganizationalRule {
        let chunks = raw.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var out = ParsedOrganizationalRule(lesson: chunks.first ?? raw.trimmingCharacters(in: .whitespacesAndNewlines))
        for chunk in chunks.dropFirst() {
            guard let colon = chunk.firstIndex(of: ":") else {
                out.reason = out.reason.isEmpty ? chunk : out.reason + " " + chunk
                continue
            }
            let key = chunk[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = chunk[chunk.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "confidence", "conf", "certainty":
                out.confidence = min(100, max(1, Int(String(value.filter(\.isNumber))) ?? out.confidence))
            case "reason", "why":
                out.reason = value
            case "evidence", "proof", "source", "sources":
                out.evidence = value.split(separator: ";").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
            default:
                out.reason = out.reason.isEmpty ? chunk : out.reason + " " + chunk
            }
        }
        return out
    }
}
