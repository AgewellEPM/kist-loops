import Foundation
import AgentCore

enum CaptainSimulationDomain: String, Codable, Sendable, Equatable {
    case software
    case productMarket
    case roboticsFactory
    case security
    case general

    var title: String {
        switch self {
        case .software: return "Software sandbox"
        case .productMarket: return "Product / market sandbox"
        case .roboticsFactory: return "Factory / robotics digital twin"
        case .security: return "Security lab sandbox"
        case .general: return "General decision sandbox"
        }
    }

    var defaultTrialCount: Int {
        switch self {
        case .software: return 64
        case .productMarket: return 48
        case .roboticsFactory: return 80
        case .security: return 72
        case .general: return 40
        }
    }
}

struct CaptainSimulationStrategy: Codable, Sendable, Equatable {
    var name: String
    var sandbox: String
    var reason: String
    var trials: Int
    var passedTrials: Int
    var failedTrials: Int
    var estimatedSuccess: Int
    var failureRisk: Int
    var expectedValue: Int
    var failureModes: [String]
    var requiredEvidence: [String]
    var verificationCommands: [String]
}

enum CaptainSimulationMeasuredTrialMode: String, Codable, Sendable, Equatable {
    case preflight
    case interactive
}

struct CaptainSimulationMeasuredTrial: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable, Equatable {
        case passed
        case failed
        case timedOut
        case skipped
    }

    var command: String
    var status: Status
    var exitCode: Int32?
    var timedOut: Bool
    var elapsedSeconds: Double
    var sandbox: String
    var outputExcerpt: String

    var passed: Bool { status == .passed }
    var executed: Bool { status != .skipped }
}

struct CaptainSimulationRun: Codable, Sendable, Equatable {
    var id: String
    var objective: String
    var domain: CaptainSimulationDomain
    var strategies: [CaptainSimulationStrategy]
    var recommendedStrategy: CaptainSimulationStrategy
    var measuredTrials: [CaptainSimulationMeasuredTrial]
    var decision: String
    var acceptanceThreshold: Int
    var generatedAt: Double
    /// How the verdict JUDGES trial coverage. `.interactive` demands the recommended strategy's
    /// full verification suite (REPL /simulate, fleet, critical risk). `.preflight` judges only
    /// the trials preflight actually runs — demanding interactive-suite evidence from a mode
    /// that never executes it made every high-risk one-shot plan-execute a deterministic
    /// threshold-1 block (2026-07-29 dogfood catch), which is a brick, not safety.
    var judgedTrialMode: CaptainSimulationMeasuredTrialMode = .interactive

    var executedMeasuredTrials: [CaptainSimulationMeasuredTrial] {
        measuredTrials.filter(\.executed)
    }

    var requiredVerificationCommands: [String] {
        recommendedStrategy.verificationCommands.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    var passedMeasuredCommands: Set<String> {
        Set(measuredTrials.filter(\.passed).map(\.command))
    }

    var measuredTrialsIncomplete: Bool {
        if judgedTrialMode == .interactive {
            let required = Set(requiredVerificationCommands)
            if !required.isEmpty && !required.isSubset(of: passedMeasuredCommands) {
                return true
            }
        }
        // Preflight judging: coverage = the trials preflight attempted. A skipped trial still
        // blocks; trials that were never part of this mode cannot be "missing evidence".
        return measuredTrials.contains { $0.status == .skipped }
    }

    var measuredTrialsPassed: Bool {
        !measuredTrials.isEmpty && !measuredTrialsIncomplete && measuredTrials.allSatisfy(\.passed)
    }

    var measuredTrialsFailed: Bool {
        executedMeasuredTrials.contains { !$0.passed }
    }

    var estimatedSuccess: Int {
        if measuredTrialsFailed { return min(recommendedStrategy.estimatedSuccess, 45) }
        if measuredTrialsIncomplete { return min(recommendedStrategy.estimatedSuccess, acceptanceThreshold - 1) }
        if measuredTrialsPassed { return max(recommendedStrategy.estimatedSuccess, min(99, acceptanceThreshold + 6)) }
        return recommendedStrategy.estimatedSuccess
    }

    var failureRisk: Int {
        if measuredTrialsFailed { return max(recommendedStrategy.failureRisk, 55) }
        if measuredTrialsIncomplete { return max(recommendedStrategy.failureRisk, 100 - estimatedSuccess + 1) }
        if measuredTrialsPassed { return min(recommendedStrategy.failureRisk, max(1, 100 - estimatedSuccess)) }
        return recommendedStrategy.failureRisk
    }

    var passesGate: Bool {
        estimatedSuccess >= acceptanceThreshold && failureRisk <= 100 - acceptanceThreshold
    }
}

struct CaptainSimulationGateReport: Equatable, Sendable {
    var path: String
    var text: String
    var objective: String
    var domainTitle: String
    var recommendedStrategy: String
    var decision: String
    var acceptanceThreshold: Int
    var estimatedSuccess: Int
    var failureRisk: Int
    var seededTasks: Int
    var createdSpecialists: Int
    var benchmarkRecords: Int
    var writeSucceeded: Bool
    var writeError: String?
    /// True (default) for a normal run where durable evidence persistence is required — a failed write is a
    /// fail-closed BLOCK. False ONLY on the `--no-memory` no-write path: the gate decision is still computed
    /// and enforced, but persistence is intentionally suppressed, so `!writeSucceeded` must NOT block.
    /// (Council-adapted 2026-07-03: honest audit representation instead of a fabricated `writeSucceeded=true`.)
    var persistenceRequired: Bool = true

    var passesGate: Bool {
        writeSucceeded && estimatedSuccess >= acceptanceThreshold && failureRisk <= 100 - acceptanceThreshold
    }
}

enum CaptainSimulationLab {
    static func build(objective rawObjective: String,
                      artifactObjective rawArtifactObjective: String? = nil,
                      plan: Plan,
                      evidence: CaptainProjectEvidence,
                      generatedAt: Date) -> CaptainSimulationRun {
        let objective = normalize(rawObjective, fallback: fallbackObjective(plan))
        let artifactObjective = normalize(rawArtifactObjective ?? objective, fallback: objective)
        let domain = classify(objective: objective, evidence: evidence)
        let templates = strategyTemplates(for: domain, evidence: evidence)
        let strategies = templates.enumerated().map { index, template in
            materialize(template: template,
                        objective: objective,
                        domain: domain,
                        index: index)
        }.sorted {
            if $0.expectedValue != $1.expectedValue { return $0.expectedValue > $1.expectedValue }
            if $0.failureRisk != $1.failureRisk { return $0.failureRisk < $1.failureRisk }
            return $0.name < $1.name
        }
        let recommended = strategies.first ?? materialize(
            template: StrategyTemplate(
                name: "Manual evidence gate",
                sandbox: "Create a reversible test environment and define failure modes before real execution.",
                reason: "No domain-specific sandbox was inferred.",
                baseSuccess: 62,
                valueBias: 10,
                blastRadius: 35,
                failureModes: ["unknown operational side effects"],
                requiredEvidence: ["sandbox notes", "risk register", "rollback path"],
                verificationCommands: []),
            objective: objective,
            domain: domain,
            index: 0)
        let threshold = threshold(for: domain)
        let decision = recommended.estimatedSuccess >= threshold && recommended.failureRisk <= 100 - threshold
            ? "PROCEED TO EXECUTION ONLY AFTER THE REQUIRED EVIDENCE IS ATTACHED."
            : "HOLD EXECUTION; run another research/simulation pass before acting."
        return CaptainSimulationRun(
            id: makeID(objective: artifactObjective, at: generatedAt),
            objective: artifactObjective,
            domain: domain,
            strategies: strategies,
            recommendedStrategy: recommended,
            measuredTrials: [],
            decision: decision,
            acceptanceThreshold: threshold,
            generatedAt: generatedAt.timeIntervalSince1970)
    }

    static func attachingMeasuredTrials(_ measuredTrials: [CaptainSimulationMeasuredTrial],
                                        to run: CaptainSimulationRun) -> CaptainSimulationRun {
        var updated = run
        updated.measuredTrials = measuredTrials
        if updated.measuredTrialsFailed {
            updated.decision = "HOLD EXECUTION; executable sandbox trials failed or timed out."
        } else if updated.measuredTrialsIncomplete {
            updated.decision = "HOLD EXECUTION; executable sandbox coverage is incomplete."
        } else if updated.passesGate {
            updated.decision = updated.executedMeasuredTrials.isEmpty
                ? "PROCEED TO EXECUTION ONLY AFTER THE REQUIRED EVIDENCE IS ATTACHED."
                : "PROCEED: executable sandbox trials passed; execution still requires attached evidence and review."
        } else {
            updated.decision = "HOLD EXECUTION; run another research/simulation pass before acting."
        }
        return updated
    }

    static func render(_ run: CaptainSimulationRun,
                       reportPath: String,
                       seededTasks: Int,
                       createdSpecialists: Int,
                       benchmarkRecords: Int) -> String {
        var lines = [
            "# Captain Simulation Gate",
            "",
            "Objective: \(run.objective)",
            "Domain: \(run.domain.title)",
            "Decision: \(run.decision)",
            "Acceptance threshold: \(run.acceptanceThreshold)% estimated success with bounded failure risk",
            "",
            "## Recommended Strategy",
            run.recommendedStrategy.name,
            "",
            "Sandbox: \(run.recommendedStrategy.sandbox)",
            "Estimated success: \(run.recommendedStrategy.estimatedSuccess)%",
            "Measured-adjusted success: \(run.estimatedSuccess)%",
            "Failure risk: \(run.failureRisk)%",
            "Expected value: \(run.recommendedStrategy.expectedValue)%",
            "Trials: \(run.recommendedStrategy.passedTrials)/\(run.recommendedStrategy.trials) passed",
            "",
            "## Sandbox Simulation",
            "Captain must prove the plan in a disposable environment before real-world execution.",
            "",
            "## Executable Sandbox Trials",
        ]
        if run.measuredTrials.isEmpty {
            lines.append("- No executable sandbox trial was run. Use `/simulate <objective>` in a project with safe test entrypoints, or attach external sandbox evidence.")
        } else {
            for trial in run.measuredTrials {
                lines += [
                    "- \(trial.command)",
                    "  Status: \(trial.status.rawValue)",
                    "  Exit: \(trial.exitCode.map(String.init) ?? "n/a")\(trial.timedOut ? " (timed out)" : "")",
                    "  Elapsed: \(String(format: "%.2fs", trial.elapsedSeconds))",
                    "  Sandbox: \(trial.sandbox)",
                ]
                if !trial.outputExcerpt.isEmpty {
                    lines.append("  Output: \(trial.outputExcerpt)")
                }
            }
        }
        lines += [
            "",
            "## Probabilistic Trials",
        ]
        for strategy in run.strategies {
            lines += [
                "- \(strategy.name)",
                "  Sandbox: \(strategy.sandbox)",
                "  Why: \(strategy.reason)",
                "  Trials: \(strategy.passedTrials)/\(strategy.trials) passed",
                "  Estimated success: \(strategy.estimatedSuccess)%",
                "  Failure risk: \(strategy.failureRisk)%",
                "  Expected value: \(strategy.expectedValue)%",
            ]
            if !strategy.failureModes.isEmpty {
                lines.append("  Failure modes: \(strategy.failureModes.joined(separator: "; "))")
            }
        }
        lines += [
            "",
            "## Required Evidence Before Real Execution",
        ]
        lines += run.recommendedStrategy.requiredEvidence.map { "- \($0)" }
        lines += [
            "",
            "## Suggested Verification Commands",
        ]
        if run.recommendedStrategy.verificationCommands.isEmpty {
            lines.append("- Define the domain sandbox command before executing.")
        } else {
            lines += run.recommendedStrategy.verificationCommands.map { "- \($0)" }
        }
        lines += [
            "",
            "## Compare Strategies",
            "Pick the strategy with the best expected value after penalizing failure risk and blast radius.",
            "",
            "## Execution Gate",
            "- Do not execute the real-world action until the simulation task, benchmark task, review task, and accept/reject decision are complete.",
            "- If evidence contradicts this simulation, update the risk model instead of forcing the plan through.",
            "- If accepted, Teach Captain should promote the lesson: risky objectives require sandbox simulation before execution.",
            "",
            "## Artifacts",
            "Simulation report: \(reportPath)",
            "Seeded simulation tasks: \(seededTasks)",
            "Created simulation specialists: \(createdSpecialists)",
            "Benchmark recording: only after this report persists and the gate passes"
        ]
        return lines.joined(separator: "\n")
    }

    private struct StrategyTemplate {
        var name: String
        var sandbox: String
        var reason: String
        var baseSuccess: Int
        var valueBias: Int
        var blastRadius: Int
        var failureModes: [String]
        var requiredEvidence: [String]
        var verificationCommands: [String]
    }

    private static func classify(objective: String,
                                 evidence: CaptainProjectEvidence) -> CaptainSimulationDomain {
        let lower = objective.lowercased()
        if containsAny(lower, ["robot", "factory", "manufactur", "digital twin", "physics", "cad", "fea",
                               "hardware", "vision replay", "actuator", "assembly line"]) {
            return .roboticsFactory
        }
        if containsAny(lower, ["security", "pentest", "bug bounty", "vulnerab", "exploit", "auth",
                               "scope", "safe", "customers safe"]) {
            return .security
        }
        if !evidence.languages.isEmpty
            || containsAny(lower, ["code", "repo", "software", "api", "test suite", "unit test", "docker", "swift",
                                   "react", "typescript", "cli", "kist", "mcp"]) {
            return .software
        }
        if containsAny(lower, ["market", "pricing", "customer", "persona", "landing page", "growth",
                               "conversion", "synthetic interview", "product"]) {
            return .productMarket
        }
        return .general
    }

    private static func strategyTemplates(for domain: CaptainSimulationDomain,
                                          evidence: CaptainProjectEvidence) -> [StrategyTemplate] {
        switch domain {
        case .software:
            let testCommands = evidence.testEntrypoints.isEmpty ? ["swift test", "git diff --check"] : evidence.testEntrypoints + ["git diff --check"]
            return [
                StrategyTemplate(
                    name: "Disposable repo test sandbox",
                    sandbox: "Use a throwaway branch/worktree, fake APIs, focused tests, and CI-style verification.",
                    reason: "Software changes are cheapest to validate in an isolated repo before touching the main path.",
                    baseSuccess: evidence.testEntrypoints.isEmpty ? 74 : 86,
                    valueBias: 16,
                    blastRadius: 18,
                    failureModes: ["test gaps", "mock drift", "uncovered integration behavior"],
                    requiredEvidence: ["focused test output", "diff check", "rollback path", "fake API or fixture notes"],
                    verificationCommands: testCommands),
                StrategyTemplate(
                    name: "Containerized integration sandbox",
                    sandbox: "Run the plan in Docker or an equivalent isolated service graph with mock external systems.",
                    reason: "Integration risk needs a closer runtime model than unit tests alone.",
                    baseSuccess: 82,
                    valueBias: 18,
                    blastRadius: 22,
                    failureModes: ["container/runtime mismatch", "missing secrets", "service startup flake"],
                    requiredEvidence: ["container startup log", "integration test output", "fixture inventory", "resource cleanup proof"],
                    verificationCommands: ["docker compose config", "docker compose up --abort-on-container-exit"]),
                StrategyTemplate(
                    name: "Direct edit without sandbox",
                    sandbox: "No isolated validation; edit the live project and rely on post-hoc review.",
                    reason: "This is included as the baseline Captain should usually reject.",
                    baseSuccess: 48,
                    valueBias: 4,
                    blastRadius: 68,
                    failureModes: ["regression reaches the user", "hidden state mutation", "rollback confusion"],
                    requiredEvidence: ["operator approval", "manual rollback plan"],
                    verificationCommands: [])
            ]
        case .productMarket:
            return [
                StrategyTemplate(
                    name: "Synthetic customer and persona simulation",
                    sandbox: "Run persona tests, objection mapping, and workflow walkthroughs before building the feature.",
                    reason: "Product guesses should be challenged before engineering effort hardens them.",
                    baseSuccess: 76,
                    valueBias: 18,
                    blastRadius: 25,
                    failureModes: ["synthetic personas miss real buyer constraints", "overfitted copy", "weak success metric"],
                    requiredEvidence: ["persona matrix", "objection list", "success metric", "decision memo"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Landing page / pricing experiment",
                    sandbox: "Test offer, pricing, and positioning with a low-risk landing page or prototype.",
                    reason: "Market risk is best reduced with demand evidence before full implementation.",
                    baseSuccess: 70,
                    valueBias: 24,
                    blastRadius: 30,
                    failureModes: ["sample bias", "weak traffic quality", "ambiguous conversion signal"],
                    requiredEvidence: ["experiment hypothesis", "metric threshold", "traffic/source note", "result summary"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Build full product first",
                    sandbox: "Skip market simulation and use the shipped feature as the test.",
                    reason: "This is the expensive baseline Captain should compare against.",
                    baseSuccess: 42,
                    valueBias: 8,
                    blastRadius: 72,
                    failureModes: ["months spent on wrong feature", "false confidence", "positioning miss"],
                    requiredEvidence: ["explicit operator approval", "budget cap", "kill criteria"],
                    verificationCommands: [])
            ]
        case .roboticsFactory:
            return [
                StrategyTemplate(
                    name: "Digital twin and physics replay",
                    sandbox: "Run CAD/FEA/physics simulation, robot path replay, and sensor/vision logs before touching hardware.",
                    reason: "Physical systems need failure-mode testing before any real actuation.",
                    baseSuccess: 84,
                    valueBias: 22,
                    blastRadius: 20,
                    failureModes: ["sim-to-real gap", "sensor noise", "unmodeled material tolerance"],
                    requiredEvidence: ["digital twin config", "replay logs", "failure-mode table", "hardware interlock checklist"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Staged hardware dry run",
                    sandbox: "Run slow-speed/no-load hardware trials with emergency stop and operator supervision.",
                    reason: "Some physical risk only appears after simulation, but it must be staged.",
                    baseSuccess: 72,
                    valueBias: 18,
                    blastRadius: 38,
                    failureModes: ["operator safety risk", "mechanical wear", "unexpected collision"],
                    requiredEvidence: ["dry-run checklist", "safety observer signoff", "abort threshold", "telemetry log"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Direct production run",
                    sandbox: "Skip simulation and test on live production hardware.",
                    reason: "This is the high-blast-radius option Captain should reject without extraordinary evidence.",
                    baseSuccess: 30,
                    valueBias: 5,
                    blastRadius: 92,
                    failureModes: ["injury", "equipment damage", "production outage"],
                    requiredEvidence: ["executive approval", "safety signoff", "insurance/risk acceptance"],
                    verificationCommands: [])
            ]
        case .security:
            return [
                StrategyTemplate(
                    name: "Authorized lab reproduction",
                    sandbox: "Use local fixtures, fake targets, and scoped replay before touching a real system.",
                    reason: "Security work must prove authorization and avoid collateral impact.",
                    baseSuccess: 80,
                    valueBias: 20,
                    blastRadius: 18,
                    failureModes: ["scope ambiguity", "false positive", "tool noise"],
                    requiredEvidence: ["authorization scope", "lab reproduction", "rate-limit note", "safe disclosure path"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Scoped DAST / replay sandbox",
                    sandbox: "Run bounded scanner/replay against explicit in-scope assets with throttling.",
                    reason: "Dynamic evidence is useful only when scope and rate limits are enforced.",
                    baseSuccess: 68,
                    valueBias: 18,
                    blastRadius: 42,
                    failureModes: ["service disruption", "out-of-scope request", "noisy finding"],
                    requiredEvidence: ["program scope", "scanner config", "throttle proof", "reproduction log"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Direct target probing",
                    sandbox: "Interact with real targets before lab proof and scope review.",
                    reason: "This is the unsafe baseline and should fail the gate by default.",
                    baseSuccess: 28,
                    valueBias: 4,
                    blastRadius: 86,
                    failureModes: ["unauthorized activity", "customer impact", "evidence contamination"],
                    requiredEvidence: ["explicit written authorization", "human approval"],
                    verificationCommands: [])
            ]
        case .general:
            return [
                StrategyTemplate(
                    name: "Reversible pilot sandbox",
                    sandbox: "Run the plan against a reversible pilot, small cohort, or synthetic environment.",
                    reason: "Unknown domains still need a low-blast-radius test before real execution.",
                    baseSuccess: 66,
                    valueBias: 16,
                    blastRadius: 28,
                    failureModes: ["weak assumptions", "pilot mismatch", "missing rollback trigger"],
                    requiredEvidence: ["pilot scope", "success metric", "failure threshold", "rollback path"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Decision-table simulation",
                    sandbox: "Compare likely outcomes, constraints, and failure modes with a written trial matrix.",
                    reason: "A structured model is better than acting from an untested guess.",
                    baseSuccess: 62,
                    valueBias: 12,
                    blastRadius: 24,
                    failureModes: ["missing variables", "optimistic probabilities", "unvalidated assumptions"],
                    requiredEvidence: ["assumption table", "probability rationale", "review notes"],
                    verificationCommands: []),
                StrategyTemplate(
                    name: "Act immediately",
                    sandbox: "No sandbox, no trials, no strategy comparison.",
                    reason: "This is the baseline Captain should reject for non-trivial work.",
                    baseSuccess: 38,
                    valueBias: 4,
                    blastRadius: 70,
                    failureModes: ["avoidable failure", "unclear rollback", "no learning record"],
                    requiredEvidence: ["explicit operator approval"],
                    verificationCommands: [])
            ]
        }
    }

    private static func materialize(template: StrategyTemplate,
                                    objective: String,
                                    domain: CaptainSimulationDomain,
                                    index: Int) -> CaptainSimulationStrategy {
        let trials = domain.defaultTrialCount + index * 8
        let jitter = Int(seed(objective + template.name) % 13) - 6
        let success = clamp(template.baseSuccess + jitter - max(0, template.blastRadius - 60) / 4)
        let passed = Int((Double(trials) * Double(success) / 100.0).rounded())
        let failureRisk = 100 - success
        let expected = clamp(success + template.valueBias - failureRisk / 3 - template.blastRadius / 5)
        return CaptainSimulationStrategy(
            name: template.name,
            sandbox: template.sandbox,
            reason: template.reason,
            trials: trials,
            passedTrials: min(trials, max(0, passed)),
            failedTrials: max(0, trials - passed),
            estimatedSuccess: success,
            failureRisk: failureRisk,
            expectedValue: expected,
            failureModes: template.failureModes,
            requiredEvidence: template.requiredEvidence,
            verificationCommands: template.verificationCommands)
    }

    private static func threshold(for domain: CaptainSimulationDomain) -> Int {
        switch domain {
        case .roboticsFactory, .security: return 82
        case .software: return 78
        case .productMarket: return 72
        case .general: return 70
        }
    }

    private static func fallbackObjective(_ plan: Plan) -> String {
        if let active = plan.active { return active.boardTitle }
        if let next = plan.next { return next.boardTitle }
        return plan.title
    }

    private static func normalize(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func makeID(objective: String, at: Date) -> String {
        "\(Int(at.timeIntervalSince1970))-\(slug(objective).prefix(36))"
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

    private static func seed(_ text: String) -> UInt64 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 1_099_511_628_211
        }
        return value
    }

    private static func clamp(_ value: Int) -> Int {
        min(99, max(1, value))
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}
