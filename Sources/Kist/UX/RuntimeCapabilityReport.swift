import Foundation
import AgentCore

/// Host observations, not a model's self-assessment or a capability benchmark. The same snapshot
/// accompanies each model attempt and is inspectable in the REPL without spending inference tokens.
struct RuntimeCapabilityReport {
    let projectRoot: String
    let binding: ProviderBinding
    let toolNames: Set<String>
    let shellEnabled: Bool
    let planMode: Bool
    let fleetConfigured: Bool
    let councilConfigured: Bool
    let buildReviewEnabled: Bool
    let evalSuiteConfigured: Bool
    let memoryEnabled: Bool
    let semanticCaptureConfigured: Bool
    let autoRouting: Bool
    let healthConfigured: Bool
    let readiness: EvolutionAutonomyReadiness
    let replayRunID: String?

    func render(modelLabel: String = "Model attempt") -> String {
        let edits = ["write_file", "edit_file", "apply_patch"].filter { toolNames.contains($0) }
        let model = binding.model ?? "provider default (exact model in /usage)"
        let missing = readiness.blockers.map { "\($0.gate.rawValue): \($0.reason)" }
        var lines = [
            "Runtime capabilities · host observations; configuration is not proof of successful execution",
            "Project: \(Self.literal(projectRoot))",
            "\(modelLabel): \(Self.literal(binding.providerId)):\(Self.literal(model))",
            "1. Evolution: \(readiness.ready ? "readiness gates met; separate operator activation required" : "BLOCKED") · auto-promotion disabled.",
            "2. Execution: \(toolNames.count) registered tools; edits: \(edits.isEmpty ? "none registered" : edits.joined(separator: ", ")); shell: \(shellEnabled ? "enabled" : "disabled"); plan mode: \(planMode ? "on (read-only)" : "off"). Tool and scope gates still apply. /tools · /permissions",
            "3. Benchmarks: stable eval suite \(evalSuiteConfigured ? "wired" : "unavailable in this session"); no passing score is implied. /eval-suite · /scorecard",
            "4. Team: fleet \(fleetConfigured ? "wired" : "unavailable"); council \(councilConfigured ? "wired" : "unavailable"); automatic build review \(buildReviewEnabled ? "enabled" : "disabled"). Configured reviewers do not establish independent review. /roles · /copilot",
            "5. Memory: advisory recall \(memoryEnabled ? "enabled" : "disabled"); semantic lesson capture \(memoryEnabled && semanticCaptureConfigured ? "wired" : "unavailable"). Recall is not benchmark or receipt authority. /memory",
            "6. Routing: automatic model selection \(autoRouting ? "enabled" : "disabled"); provider health \(healthConfigured ? "wired" : "unavailable"). Observed usage and cost: /usage; readiness: /health.",
        ]
        if !missing.isEmpty { lines.append("Evolution blockers: " + missing.joined(separator: "; ")) }
        if let replayRunID {
            let command = RunReplayStore.isValidRunID(replayRunID) ? "/replay \(replayRunID)" : "/replay"
            lines.append("Run: \(Self.literal(replayRunID)) · \(command)")
        }
        lines.append("Evidence: /logs · cost: /usage · board: /tasks · /summary. A trace, task marked done, or model answer alone does not verify completion.")
        return lines.joined(separator: "\n")
    }

    /// Paths and provider labels are data, including when they contain control characters or secrets.
    private static func literal(_ value: String) -> String {
        let text = SecretScanner.redactSecrets(in: String(value.prefix(1_024)))
        let data = try? JSONEncoder().encode(text)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"unavailable\""
    }
}

extension KistREPL {
    func runtimeCapabilityReport(loop attemptLoop: HeadlessAgentLoop? = nil,
                                 binding: ProviderBinding? = nil) -> RuntimeCapabilityReport {
        let currentLoop = attemptLoop ?? loop
        return RuntimeCapabilityReport(
            projectRoot: projectRoot, binding: binding ?? activeBinding,
            toolNames: Set(currentLoop.toolNames), shellEnabled: currentLoop.shellEnabled,
            planMode: attemptLoop?.isPlanMode ?? perm?.effectivePlan ?? currentLoop.isPlanMode,
            fleetConfigured: fleet != nil, councilConfigured: council != nil,
            buildReviewEnabled: copilot.automaticBuildReview,
            evalSuiteConfigured: runEvalSuite != nil,
            memoryEnabled: advisoryMemoryEnabled, semanticCaptureConfigured: rememberLesson != nil,
            autoRouting: autoRouting, healthConfigured: providerHealth != nil,
            readiness: EvolutionAutonomyReadinessAssessment.current, replayRunID: replayRunID)
    }

    /// Inspecting a completed turn must not erase its tool evidence or mix its calls with session costs.
    func renderSubmittedTurnSummary() -> String {
        let summary = Self.renderSimpleSummary(
            projectRoot: projectRoot, spans: submittedTurnSpans,
            trajectory: turnEvidenceSnapshot(), sessionStartedAt: sessionStart)
        let decisions = proofStore?.lastEntries().filter {
            [.reviewAssessment, .verificationAssessment, .turnFinalized].contains($0.kind)
        } ?? []
        let evidence = decisions.suffix(3).map {
            Copilot.safeReviewDisplay(SecretScanner.redactSecrets(in: String($0.text.prefix(700))))
        }.joined(separator: "\n")
        return summary + (evidence.isEmpty ? "" : "\n" + evidence)
            + "\n\n" + runtimeCapabilityReport().render(modelLabel: "Current session model")
    }

    func prepareTurnEvidence(for input: String) {
        let command = input.split(whereSeparator: { $0.isWhitespace }).first?.lowercased() ?? ""
        let inspectors: Set<String> = [
            "/summary", "/status", "/logs", "/details", "/proof", "/replay",
            "/usage", "/cost", "/tokens", "/tasks", "/goals", "/confidence", "/why",
            "/tools", "/capabilities", "/contract", "/health", "/providers", "/permissions",
        ]
        if !inspectors.contains(command) { resetTurnEvidence() }
    }
}
