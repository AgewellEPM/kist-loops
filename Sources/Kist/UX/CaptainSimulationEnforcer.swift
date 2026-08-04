import Foundation
import AgentCore

enum CaptainSimulationPreflightMode: String, Sendable, Equatable {
    case fleet
    case planExecute

    var title: String {
        switch self {
        case .fleet: return "fleet"
        case .planExecute: return "plan-execute"
        }
    }
}

struct CaptainSimulationPreflightResult: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        case notRequired(reason: String)
        case allowed(report: CaptainSimulationGateReport, risk: CaptainSimulationEnforcer.RiskLevel)
        /// The gate's verdict was sub-threshold but the objective is an EXPLICIT user request below
        /// critical risk — the human already made the call, so the estimate informs, it doesn't veto.
        /// (2026-08-04: "build me a win98 hangman app" was refused twice on an invented 64-68% score.)
        case advisory(report: CaptainSimulationGateReport, risk: CaptainSimulationEnforcer.RiskLevel, reasons: [String])
        case blocked(report: CaptainSimulationGateReport, risk: CaptainSimulationEnforcer.RiskLevel, reasons: [String])
    }

    var mode: CaptainSimulationPreflightMode
    var objective: String
    var decision: Decision

    var canExecute: Bool {
        switch decision {
        case .notRequired, .allowed, .advisory: return true
        case .blocked: return false
        }
    }

    var report: CaptainSimulationGateReport? {
        switch decision {
        case .notRequired: return nil
        case .allowed(let report, _), .advisory(let report, _, _), .blocked(let report, _, _): return report
        }
    }

    var terminalLines: [String] {
        switch decision {
        case .notRequired(let reason):
            return ["simulation gate · skipped for \(mode.title): \(reason)"]
        case .allowed(let report, let risk):
            return summaryLines(prefix: "simulation gate · passed", report: report, risk: risk)
        case .advisory(let report, let risk, let reasons):
            var lines = summaryLines(prefix: "simulation gate · advisory", report: report, risk: risk)
            lines.append(contentsOf: reasons.map { "simulation gate · caution: \($0)" })
            lines.append("simulation gate · proceeding — you asked for this build; the estimate informs, it doesn't veto")
            return lines
        case .blocked(let report, let risk, let reasons):
            var lines = summaryLines(prefix: "simulation gate · blocked", report: report, risk: risk)
            lines.append(contentsOf: reasons.map { "simulation gate · reason: \($0)" })
            lines.append("simulation gate · run /simulate \(objective) for the full report")
            return lines
        }
    }

    private func summaryLines(prefix: String,
                              report: CaptainSimulationGateReport,
                              risk: CaptainSimulationEnforcer.RiskLevel) -> [String] {
        [
            "\(prefix) · \(mode.title) · risk \(risk.rawValue)",
            "simulation gate · \(report.domainTitle) · \(report.estimatedSuccess)% success · \(report.failureRisk)% failure risk · threshold \(report.acceptanceThreshold)%",
            "simulation gate · strategy: \(report.recommendedStrategy)",
            "simulation gate · evidence: \(report.path)"
        ]
    }
}

enum CaptainSimulationEnforcer {
    enum EvidenceMode: Sendable, Equatable {
        case full
        case redacted

        var artifactObjective: String? {
            switch self {
            case .full: return nil
            case .redacted: return "Redacted mandatory simulation safety evidence"
            }
        }
    }

    /// Who asked for this work. An EXPLICIT user request (typed /build, /pe, --plan-execute) below
    /// critical risk downgrades a sub-threshold verdict to ADVISORY — the human already decided;
    /// refusing on the gate's own probability estimate is theater, not safety. Autonomous callers
    /// (and every caller that doesn't say otherwise) keep the fail-closed block. Critical-risk
    /// signals (production/delete/payments/secrets) and a failed REQUIRED evidence write always
    /// block regardless of initiator.
    enum Initiator: Sendable, Equatable {
        case userRequest
        case autonomous
    }

    enum RiskLevel: String, Sendable, Equatable, Comparable {
        case low
        case medium
        case high
        case critical

        static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
            order(lhs) < order(rhs)
        }

        private static func order(_ risk: RiskLevel) -> Int {
            switch risk {
            case .low: return 0
            case .medium: return 1
            case .high: return 2
            case .critical: return 3
            }
        }
    }

    static func preflight(mode: CaptainSimulationPreflightMode,
                          objective: String,
                          projectRoot: String,
                          evidenceMode: EvidenceMode = .full,
                          noMemory: Bool = false,
                          initiator: Initiator = .autonomous,
                          now: @escaping @Sendable () -> Date = { Date() }) -> CaptainSimulationPreflightResult {
        let normalized = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let risk = riskLevel(mode: mode, objective: normalized)
        guard risk >= .medium else {
            return CaptainSimulationPreflightResult(
                mode: mode,
                objective: normalized,
                decision: .notRequired(reason: "objective looks read-only or advisory"))
        }

        let store = OrganizationalLearningStore(projectRoot: projectRoot, now: now)
        let artifactObjective = evidenceMode.artifactObjective
        let plan = seedPreflightPlanIfNeeded(objective: artifactObjective ?? normalized,
                                             mode: mode,
                                             projectRoot: projectRoot,
                                             risk: risk)
        // One-shot plan-execute below critical risk is judged on the trials preflight actually
        // RUNS. Demanding the interactive suite's evidence from a mode that never executes it
        // made every high-risk one-shot goal a deterministic threshold-1 block (there is no
        // /simulate in one-shot mode to attach it) — a brick, not safety. Fleet and critical
        // risk keep the strict full-suite demand (pinned by KistRunnerSafetyTests).
        let judged: CaptainSimulationMeasuredTrialMode =
            (mode == .planExecute && risk < .critical) ? .preflight : .interactive
        // `--no-memory` must not leave board tasks / specialists / disk artifacts behind (the gate
        // decision is still computed and enforced; only persistence is suppressed).
        let report = store.runSimulationGate(plan: plan,
                                             trajectory: [],
                                             objective: normalized,
                                             artifactObjective: artifactObjective,
                                             measuredTrialMode: .preflight,
                                             judgedTrialMode: judged,
                                             persist: !noMemory)
        guard shouldBlock(report: report, risk: risk) else {
            return CaptainSimulationPreflightResult(
                mode: mode,
                objective: normalized,
                decision: .allowed(report: report, risk: risk))
        }

        let reasons = blockReasons(report: report, risk: risk)
        // Explicit user request below critical risk → the sub-threshold verdict INFORMS, it doesn't
        // veto. Exception: a REQUIRED evidence write that failed stays fail-closed for everyone
        // (real disk failure ⇒ no trustworthy audit trail for the run that follows).
        if initiator == .userRequest, risk < .critical,
           !(report.persistenceRequired && !report.writeSucceeded) {
            return CaptainSimulationPreflightResult(
                mode: mode,
                objective: normalized,
                decision: .advisory(report: report, risk: risk, reasons: reasons))
        }

        return CaptainSimulationPreflightResult(
            mode: mode,
            objective: normalized,
            decision: .blocked(report: report, risk: risk, reasons: reasons))
    }

    static func riskLevel(mode: CaptainSimulationPreflightMode,
                          objective: String) -> RiskLevel {
        let lower = objective.lowercased()
        if mode == .fleet { return .high }
        if containsAny(lower, criticalSignals) { return .critical }
        if containsAny(lower, highSignals) { return .high }
        if containsAny(lower, mediumSignals) { return .medium }
        return .low
    }

    static func shouldBlock(report: CaptainSimulationGateReport,
                            risk: RiskLevel) -> Bool {
        // A REQUIRED-but-failed evidence write is fail-closed (real disk failure ⇒ no trustworthy audit ⇒ BLOCK).
        // The `--no-memory` no-write path sets persistenceRequired:false — an intentional skip, NOT a failure —
        // so it must NOT block here; its verdict is judged on metrics below. (Council-adapted 2026-07-03.)
        if report.persistenceRequired && !report.writeSucceeded { return true }
        guard risk >= .high else { return false }
        // Persisted runs judge via passesGate (which requires writeSucceeded — pinned by CaptainSelfTestSuite).
        // The no-persist path judges the SAME metric thresholds inline, so --no-memory is never weaker on the
        // block decision, only on durability. Kept out of passesGate to preserve the pinned marker string.
        if report.persistenceRequired { return !report.passesGate }
        return !(report.estimatedSuccess >= report.acceptanceThreshold
                 && report.failureRisk <= 100 - report.acceptanceThreshold)
    }

    private static func blockReasons(report: CaptainSimulationGateReport,
                                     risk: RiskLevel) -> [String] {
        var reasons: [String] = []
        // Only a REQUIRED write that failed is a block reason. The --no-memory path intentionally skips the
        // write (persistenceRequired == false) — don't surface it as "write failed" (Codex, 2026-07-03).
        if report.persistenceRequired && !report.writeSucceeded {
            reasons.append("simulation evidence report was not persisted: \(report.writeError ?? "unknown write error")")
        }
        if report.estimatedSuccess < report.acceptanceThreshold {
            reasons.append("estimated success \(report.estimatedSuccess)% is below \(report.acceptanceThreshold)%")
        }
        let maxFailureRisk = 100 - report.acceptanceThreshold
        if report.failureRisk > maxFailureRisk {
            reasons.append("failure risk \(report.failureRisk)% is above \(maxFailureRisk)%")
        }
        if reasons.isEmpty {
            reasons.append("risk \(risk.rawValue) requires an accepted sandbox simulation")
        }
        return reasons
    }

    private static func seedPreflightPlanIfNeeded(objective: String,
                                                  mode: CaptainSimulationPreflightMode,
                                                  projectRoot: String,
                                                  risk: RiskLevel) -> Plan {
        let store = PlanStore(projectRoot: projectRoot)
        let existing = store.load()
        if !existing.tasks.isEmpty { return existing }
        let title = objective.isEmpty ? "Captain Simulation Preflight" : objective
        return Plan(
            title: title,
            tasks: [
                PlanTask(id: 1,
                         title: "PLAN: Simulation preflight for \(mode.title)",
                         detail: "Risk \(risk.rawValue): Captain must compare strategies before real execution.",
                         kind: .plan,
                         acceptance: "The safest/highest-value sandbox strategy is selected.",
                         verification: "/simulate \(title)",
                         owner: "captain"),
                PlanTask(id: 2,
                         title: "DECISION: Accept or reject real execution",
                         detail: "Real \(mode.title) work may proceed only if the simulation gate passes.",
                         kind: .decision,
                         acceptance: "Simulation decision is PROCEED, not HOLD.",
                         verification: "Review .kist/learning/simulations",
                         owner: "captain")
            ],
            nextId: 3)
    }

    private static let criticalSignals = [
        "production", "customer", "customers", "live site", "live system",
        "deploy", "release", "rollout", "migration", "migrate", "delete", "drop",
        "destroy", "truncate", "purge", "nuke", "reset", "overwrite", "remove all",
        "erase", "wipe", "decommission", "payment", "billing", "stripe", "invoice",
        "charge", "transaction", "subscription", "refund", "auth", "oauth", "login",
        "password", "secret", "credential", "token", "jwt", "certificate", "private key",
        "api key", "access key", "signing key", "secret key", "rotate keys", "revoke access",
        "hipaa", "medical",
        "robot", "factory", "hardware", "actuator", "exploit", "pentest",
        "bug bounty", "vulnerability", "vulnerable", "safety", "customers safe"
    ]

    private static let highSignals = [
        "build", "implement", "fix", "refactor", "rewrite", "install", "onboard",
        "download", "run command", "shell", "script", "write", "edit", "patch",
        "agent", "agents", "worker", "swarm", "orchestrate", "self-heal",
        "plan-execute", "fleet", "merge", "branch", "git"
    ]

    private static let mediumSignals = [
        "plan", "benchmark", "simulate", "test", "review", "compare", "research",
        "analyze", "diagnose", "evaluate"
    ]

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { containsSignal(text, signal: $0) }
    }

    private static func containsSignal(_ text: String, signal rawSignal: String) -> Bool {
        let signal = rawSignal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !signal.isEmpty else { return false }
        if signal.contains(" ") || signal.contains("-") {
            return text.contains(signal)
        }
        return containsWholeToken(text, token: signal)
    }

    private static func containsWholeToken(_ text: String, token: String) -> Bool {
        var cursor = text.startIndex
        while let range = text.range(of: token, range: cursor..<text.endIndex) {
            let beforeIsBoundary = range.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: range.lowerBound)])
            let afterIsBoundary = range.upperBound == text.endIndex
                || !isWordCharacter(text[range.upperBound])
            if beforeIsBoundary && afterIsBoundary { return true }
            cursor = range.upperBound
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }
}
