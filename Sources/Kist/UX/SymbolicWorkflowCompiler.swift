import Foundation
import AgentCore

struct SymbolicWorkflowGate: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case research
        case simulation
        case action
        case test
        case review
        case decision
        case teach

        var planKind: PlanTask.Kind {
            switch self {
            case .research: return .research
            case .simulation: return .test
            case .action: return .action
            case .test: return .test
            case .review: return .review
            case .decision: return .decision
            case .teach: return .decision
            }
        }

        var titlePrefix: String {
            switch self {
            case .research: return "RESEARCH"
            case .simulation: return "TEST"
            case .action: return "ACTION"
            case .test: return "TEST"
            case .review: return "REVIEW"
            case .decision: return "DECISION"
            case .teach: return "DECISION"
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    var owner: String
    var detail: String
    var acceptance: String
    var verification: String
}

struct SymbolicWorkflowRecord: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var sourceObjective: String
    var triggerKeywords: [String]
    var gates: [SymbolicWorkflowGate]
    var requiredEvidence: [String]
    var createdAt: Double
    var updatedAt: Double
    var source: String
}

struct SymbolicWorkflowCompileReport: Sendable, Equatable {
    var path: String
    var record: SymbolicWorkflowRecord
    var insertedRequiredGates: [String]
    var text: String
}

struct SymbolicWorkflowRunReport: Sendable, Equatable {
    var record: SymbolicWorkflowRecord
    var seededTasks: Int
    var text: String
}

struct SymbolicWorkflowStore: Sendable {
    let projectRoot: String
    private let now: @Sendable () -> Date

    init(projectRoot: String,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.projectRoot = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.now = now
    }

    var learningRoot: String { projectRoot + "/.kist/learning" }
    var workflowsPath: String { learningRoot + "/symbolic-workflows.jsonl" }

    func list(limit: Int = 20) -> String {
        let records = load().suffix(max(0, limit)).reversed()
        guard !records.isEmpty else {
            return """
            Symbolic Workflows

            No compiled workflows yet.
            Use `/symbolic compile <objective>` after a successful researched/simulated/reviewed workflow.
            """
        }
        var lines = [
            "Symbolic Workflows",
            "",
            "These are reusable deterministic gate sequences. They reduce repeated generative planning.",
            ""
        ]
        for record in records {
            lines += [
                "\(record.id)  \(record.name)",
                "Source: \(record.sourceObjective)",
                "Triggers: \(record.triggerKeywords.joined(separator: ", "))",
                "Gates: \(record.gates.map { $0.kind.rawValue }.joined(separator: " -> "))",
                "Run: /symbolic run \(record.id) <target>",
                ""
            ]
        }
        return lines.joined(separator: "\n")
    }

    func compile(plan: Plan, objective rawObjective: String,
                 trajectory: [ActionRecord]) -> SymbolicWorkflowCompileReport {
        let objective = normalizedObjective(rawObjective, plan: plan)
        let timestamp = now().timeIntervalSince1970
        let id = "SW-" + Self.slug(objective).prefix(44)
        let baseGates = gatesFromPlan(plan, objective: objective)
        let required = requiredGates(objective: objective, trajectory: trajectory)
        let existingKinds = Set(baseGates.map(\.kind))
        let inserted = required.filter { !existingKinds.contains($0.kind) }
        let gates = normalizeGateOrder(baseGates + inserted)
        let record = SymbolicWorkflowRecord(
            id: String(id),
            name: workflowName(objective),
            sourceObjective: objective,
            triggerKeywords: triggerKeywords(objective: objective, plan: plan),
            gates: gates,
            requiredEvidence: Array(Set(gates.map(\.verification)).sorted()).filter { !$0.isEmpty },
            createdAt: timestamp,
            updatedAt: timestamp,
            source: "captain-symbolic-compiler"
        )
        let saved = upsert(record)
        let text = renderCompile(saved, inserted: inserted)
        return SymbolicWorkflowCompileReport(path: Self.projectRelative(workflowsPath, root: projectRoot),
                                             record: saved,
                                             insertedRequiredGates: inserted.map(\.title),
                                             text: text)
    }

    func run(id rawID: String, input rawInput: String) -> SymbolicWorkflowRunReport? {
        guard let record = find(rawID) else { return nil }
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = input.isEmpty ? "current objective" : input
        let store = PlanStore(projectRoot: projectRoot)
        let activeBefore = store.load().active
        var firstAddedID: Int?
        var seeded = 0
        for gate in record.gates {
            let title = "\(gate.kind.titlePrefix): \(gate.title.replacingOccurrences(of: "{input}", with: target))"
            guard !taskExists(title: title) else { continue }
            let task = store.add(title: title,
                                 detail: gate.detail.replacingOccurrences(of: "{input}", with: target),
                                 owner: gate.owner,
                                 kind: gate.kind.planKind,
                                 acceptance: gate.acceptance.replacingOccurrences(of: "{input}", with: target),
                                 verification: gate.verification.replacingOccurrences(of: "{input}", with: target),
                                 evidence: [Self.projectRelative(workflowsPath, root: projectRoot)])
            if firstAddedID == nil { firstAddedID = task.id }
            seeded += 1
        }
        if activeBefore == nil, let firstAddedID {
            _ = store.update(id: firstAddedID, status: .inProgress)
        }
        return SymbolicWorkflowRunReport(record: record,
                                         seededTasks: seeded,
                                         text: renderRun(record, target: target, seededTasks: seeded))
    }

    func find(_ rawID: String) -> SymbolicWorkflowRecord? {
        let needle = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return load().last {
            $0.id.lowercased() == needle
                || $0.name.lowercased() == needle
                || Self.slug($0.name) == needle
                || Self.slug($0.sourceObjective) == needle
        }
    }

    private func gatesFromPlan(_ plan: Plan, objective: String) -> [SymbolicWorkflowGate] {
        let candidates = plan.tasks.sorted { $0.id < $1.id }
            .filter { !$0.boardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !candidates.isEmpty else { return [] }
        return candidates.enumerated().map { index, task in
            SymbolicWorkflowGate(
                id: "g\(index + 1)-\(Self.slug(task.boardTitle).prefix(24))",
                kind: gateKind(from: task),
                title: task.boardTitle,
                owner: task.owner ?? defaultOwner(for: gateKind(from: task)),
                detail: task.detail.isEmpty ? "Run this gate for {input}." : task.detail,
                acceptance: task.acceptance.isEmpty
                    ? defaultAcceptance(kind: gateKind(from: task), objective: objective)
                    : task.acceptance,
                verification: task.verificationText.isEmpty
                    ? defaultVerification(kind: gateKind(from: task))
                    : task.verificationText
            )
        }
    }

    private func requiredGates(objective: String,
                               trajectory: [ActionRecord]) -> [SymbolicWorkflowGate] {
        var out: [SymbolicWorkflowGate] = [
            gate(.research, "Research evidence for {input}",
                 "Gather local/project evidence, source docs, competitor patterns, and assumptions before acting.",
                 "Research notes name sources, assumptions, and open gaps.",
                 "Attach source links, file paths, or research archive notes."),
            gate(.action, "Apply scoped implementation for {input}",
                 "Execute only the smallest scoped implementation supported by research and simulation evidence.",
                 "Implementation is scoped, reversible, and tied to the objective.",
                 "Attach diff summary and rollback path."),
            gate(.test, "Verify {input}",
                 "Run the deterministic test or benchmark gate for the workflow.",
                 "Verification passes or blockers are explicitly recorded.",
                 "Run focused tests plus the relevant suite."),
            gate(.review, "Independent review for {input}",
                 "Review the result with an independent critic or deterministic checker.",
                 "Review either clears the workflow or records blocking findings.",
                 "Attach review notes and commands run."),
            gate(.decision, "Accept or reject {input}",
                 "Captain compares research, simulation, tests, review, and evidence before declaring done.",
                 "The workflow is accepted with evidence or held with the next repair task.",
                 "Check all prior gates are done with evidence."),
            gate(.teach, "Teach Captain lesson from {input}",
                 "Promote only recurring/high-confidence lessons into permanent organizational rules.",
                 "A rule is promoted only if evidence supports reuse.",
                 "/teach add <lesson> with confidence/reason/evidence.")
        ]
        if shouldRequireSimulation(objective: objective, trajectory: trajectory) {
            out.insert(gate(.simulation, "Simulate {input} before real execution",
                            "Run sandbox simulation, probabilistic trials, risk estimate, and strategy comparison before real-world effects.",
                            "Simulation report names strategy, success estimate, failure risk, and accept/reject threshold.",
                            "/simulate {input}; attach .kist/learning/simulations report."),
                       at: 1)
        }
        return out
    }

    private func normalizeGateOrder(_ gates: [SymbolicWorkflowGate]) -> [SymbolicWorkflowGate] {
        let order = Dictionary(uniqueKeysWithValues: SymbolicWorkflowGate.Kind.allCases.enumerated().map { ($1, $0) })
        var seen = Set<SymbolicWorkflowGate.Kind>()
        var out: [SymbolicWorkflowGate] = []
        for gate in gates.sorted(by: { (order[$0.kind] ?? 99) < (order[$1.kind] ?? 99) }) {
            if seen.insert(gate.kind).inserted {
                out.append(gate)
            }
        }
        return out.enumerated().map { index, gate in
            var updated = gate
            updated.id = "g\(index + 1)-\(gate.kind.rawValue)"
            return updated
        }
    }

    private func gateKind(from task: PlanTask) -> SymbolicWorkflowGate.Kind {
        switch task.kind {
        case .research: return .research
        case .test:
            return task.boardTitle.lowercased().contains("simulat") ? .simulation : .test
        case .review: return .review
        case .decision: return task.boardTitle.lowercased().contains("teach") ? .teach : .decision
        case .plan: return .research
        case .action, .handoff: return .action
        }
    }

    private func gate(_ kind: SymbolicWorkflowGate.Kind, _ title: String, _ detail: String,
                      _ acceptance: String, _ verification: String) -> SymbolicWorkflowGate {
        SymbolicWorkflowGate(id: "g-\(kind.rawValue)",
                             kind: kind,
                             title: title,
                             owner: defaultOwner(for: kind),
                             detail: detail,
                             acceptance: acceptance,
                             verification: verification)
    }

    private func shouldRequireSimulation(objective: String,
                                         trajectory: [ActionRecord]) -> Bool {
        let lower = objective.lowercased()
        if ["simulate", "simulation", "sandbox", "risk", "customer", "security", "deploy",
            "install", "release", "factory", "robot", "pricing", "migration"].contains(where: lower.contains) {
            return true
        }
        return trajectory.contains { ["run_command", "edit_file", "write_file", "apply_patch", "move_file"].contains($0.tool) }
    }

    private func defaultOwner(for kind: SymbolicWorkflowGate.Kind) -> String {
        switch kind {
        case .research: return "researcher"
        case .simulation: return "simulation-architect"
        case .action: return "builder"
        case .test: return "verifier"
        case .review: return "critic"
        case .decision, .teach: return "captain"
        }
    }

    private func defaultAcceptance(kind: SymbolicWorkflowGate.Kind, objective: String) -> String {
        switch kind {
        case .research: return "Evidence and assumptions for \(objective) are captured before implementation."
        case .simulation: return "Sandbox simulation passes or blockers are recorded."
        case .action: return "Implementation is scoped and reversible."
        case .test: return "Deterministic verification passes."
        case .review: return "Independent review clears the change or blocks it with findings."
        case .decision: return "Captain accepts or rejects based on evidence."
        case .teach: return "Only proven reusable lessons are promoted."
        }
    }

    private func defaultVerification(kind: SymbolicWorkflowGate.Kind) -> String {
        switch kind {
        case .research: return "Attach source links, repo paths, or research notes."
        case .simulation: return "/simulate <objective>"
        case .action: return "Attach diff summary."
        case .test: return "Run focused tests and full relevant suite."
        case .review: return "Attach review findings."
        case .decision: return "Check prior gates and evidence."
        case .teach: return "/teach add <lesson> | confidence: ... | evidence: ..."
        }
    }

    private func normalizedObjective(_ raw: String, plan: Plan) -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { return clean }
        if let active = plan.active { return active.boardTitle }
        if let next = plan.nextActionable ?? plan.next { return next.boardTitle }
        if let done = plan.tasks.filter({ $0.status == .done }).last { return done.boardTitle }
        return plan.title
    }

    private func workflowName(_ objective: String) -> String {
        let words = objective.split { !$0.isLetter && !$0.isNumber }.prefix(8)
        let name = words.joined(separator: " ")
        return name.isEmpty ? "Workflow" : name
    }

    private func triggerKeywords(objective: String, plan: Plan) -> [String] {
        let text = ([objective] + plan.tasks.map(\.boardTitle)).joined(separator: " ")
        var seen = Set<String>()
        var out: [String] = []
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) {
            guard token.count > 3, seen.insert(token).inserted else { continue }
            out.append(token)
            if out.count == 12 { break }
        }
        return out
    }

    @discardableResult
    private func upsert(_ record: SymbolicWorkflowRecord) -> SymbolicWorkflowRecord {
        var records = load()
        var saved = record
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            saved.createdAt = records[index].createdAt
            records[index] = saved
        } else {
            records.append(saved)
        }
        save(records)
        return saved
    }

    private func load() -> [SymbolicWorkflowRecord] {
        guard let text = try? String(contentsOfFile: workflowsPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(SymbolicWorkflowRecord.self, from: Data($0.utf8))
        }
    }

    private func save(_ records: [SymbolicWorkflowRecord]) {
        try? FileManager.default.createDirectory(atPath: learningRoot, withIntermediateDirectories: true)
        let lines = records.compactMap { record -> String? in
            guard let data = try? JSONEncoder().encode(record) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
        try? (lines + (lines.isEmpty ? "" : "\n")).write(toFile: workflowsPath, atomically: true, encoding: .utf8)
    }

    private func taskExists(title: String) -> Bool {
        let wanted = Self.boardTitle(title).lowercased()
        return PlanStore(projectRoot: projectRoot).load().tasks.contains {
            Self.boardTitle($0.title).lowercased() == wanted
        }
    }

    private func renderCompile(_ record: SymbolicWorkflowRecord,
                               inserted: [SymbolicWorkflowGate]) -> String {
        var lines = [
            "Symbolic Workflow Compiled",
            "",
            "\(record.id)  \(record.name)",
            "Source objective: \(record.sourceObjective)",
            "Triggers: \(record.triggerKeywords.joined(separator: ", "))",
            "",
            "Deterministic Gates",
        ]
        lines += record.gates.map {
            "- \($0.kind.rawValue): \($0.title) [\($0.owner)]"
        }
        lines += [
            "",
            "Inserted required gates: \(inserted.isEmpty ? "none" : inserted.map(\.kind.rawValue).joined(separator: ", "))",
            "",
            "How to reuse",
            "/symbolic run \(record.id) <target>",
            "",
            "Why this matters",
            "Kist can reuse this gate sequence without asking a generative model to rediscover the workflow."
        ]
        return lines.joined(separator: "\n")
    }

    private func renderRun(_ record: SymbolicWorkflowRecord,
                           target: String,
                           seededTasks: Int) -> String {
        """
        Symbolic Workflow Deployed

        \(record.id)  \(record.name)
        Target: \(target)
        Seeded tasks: \(seededTasks)

        Gates:
        \(record.gates.map { "- \($0.kind.rawValue): \($0.title.replacingOccurrences(of: "{input}", with: target))" }.joined(separator: "\n"))

        This was deterministic: no model was needed to design the workflow gates.
        """
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

    private static func slug(_ raw: String) -> String {
        let lower = raw.lowercased()
        var scalars = String.UnicodeScalarView()
        var lastDash = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                scalars.append("-")
                lastDash = true
            }
        }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func projectRelative(_ path: String, root: String) -> String {
        let cleanRoot = (ToolContext.canonicalize(root) ?? root).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasPrefix("/" + cleanRoot + "/") {
            return String(path.dropFirst(cleanRoot.count + 2))
        }
        return path
    }
}
