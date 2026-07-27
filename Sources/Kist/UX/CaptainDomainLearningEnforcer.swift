import Foundation
import AgentCore

enum CaptainDomainLearningPreflightMode: String, Sendable, Equatable {
    case fleet
    case planExecute

    var title: String {
        switch self {
        case .fleet: return "fleet"
        case .planExecute: return "plan-execute"
        }
    }
}

struct CaptainDomainLearningPreflightResult: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        case notRequired(reason: String)
        case allowed(report: DomainLearningReport)
        case blocked(report: DomainLearningReport, reasons: [String])
    }

    var mode: CaptainDomainLearningPreflightMode
    var objective: String
    var decision: Decision

    var canExecute: Bool {
        switch decision {
        case .notRequired, .allowed: return true
        case .blocked: return false
        }
    }

    var report: DomainLearningReport? {
        switch decision {
        case .notRequired: return nil
        case .allowed(let report), .blocked(let report, _): return report
        }
    }

    var terminalLines: [String] {
        switch decision {
        case .notRequired(let reason):
            return ["domain learning gate · skipped for \(mode.title): \(reason)"]
        case .allowed(let report):
            return summaryLines(prefix: "domain learning gate · passed", report: report)
        case .blocked(let report, let reasons):
            var lines = summaryLines(prefix: "domain learning gate · blocked", report: report)
            lines.append(contentsOf: reasons.map { "domain learning gate · reason: \($0)" })
            lines.append("domain learning gate · run \(report.dispatchCommand) to gather specialist evidence")
            return lines
        }
    }

    private func summaryLines(prefix: String, report: DomainLearningReport) -> [String] {
        [
            "\(prefix) · \(mode.title) · confidence \(report.understandingConfidence)%/\(report.confidenceThreshold)%",
            "domain learning gate · evidence: \(report.path)",
            "domain learning gate · seeded \(report.seededTasks) task(s), \(report.knowledgeDebtCreated) debt item(s), \(report.createdSpecialists) specialist(s)"
        ]
    }
}

enum CaptainDomainLearningEnforcer {
    enum EvidenceMode: Sendable, Equatable {
        case full
        case redacted

        func objectiveForArtifact(_ objective: String) -> String {
            switch self {
            case .full: return objective
            case .redacted: return "Redacted mandatory domain-learning safety evidence"
            }
        }
    }

    enum DomainRisk: String, Sendable, Equatable, Comparable {
        case routine
        case unfamiliar
        case regulated

        static func < (lhs: DomainRisk, rhs: DomainRisk) -> Bool {
            order(lhs) < order(rhs)
        }

        private static func order(_ risk: DomainRisk) -> Int {
            switch risk {
            case .routine: return 0
            case .unfamiliar: return 1
            case .regulated: return 2
            }
        }
    }

    static func preflight(mode: CaptainDomainLearningPreflightMode,
                          objective: String,
                          projectRoot: String,
                          evidenceMode: EvidenceMode = .full,
                          now: @escaping @Sendable () -> Date = { Date() }) -> CaptainDomainLearningPreflightResult {
        let normalized = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let risk = domainRisk(objective: normalized)
        guard risk >= .unfamiliar else {
            return CaptainDomainLearningPreflightResult(
                mode: mode,
                objective: normalized,
                decision: .notRequired(reason: "objective does not signal unfamiliar or regulated domain work"))
        }

        let store = OrganizationalLearningStore(projectRoot: projectRoot, now: now)
        let report = store.runDomainLearningPreflight(plan: PlanStore(projectRoot: projectRoot).load(),
                                                      trajectory: [],
                                                      objective: evidenceMode.objectiveForArtifact(normalized))
        let reasons = blockReasons(report: report, risk: risk)
        guard reasons.isEmpty else {
            return CaptainDomainLearningPreflightResult(mode: mode,
                                                        objective: normalized,
                                                        decision: .blocked(report: report, reasons: reasons))
        }
        return CaptainDomainLearningPreflightResult(mode: mode,
                                                    objective: normalized,
                                                    decision: .allowed(report: report))
    }

    static func domainRisk(objective: String) -> DomainRisk {
        let lower = objective.lowercased()
        if containsAny(lower, regulatedSignals) { return .regulated }
        if containsAny(lower, unfamiliarSignals) { return .unfamiliar }
        return .routine
    }

    static func shouldBlock(report: DomainLearningReport,
                            risk: DomainRisk) -> Bool {
        !blockReasons(report: report, risk: risk).isEmpty
    }

    private static func blockReasons(report: DomainLearningReport,
                                     risk: DomainRisk) -> [String] {
        var reasons: [String] = []
        if !report.writeSucceeded {
            reasons.append("domain-learning report was not durably written: \(report.writeError ?? "unknown write error")")
        }
        if report.memoryRecords == 0 {
            reasons.append("domain-learning memory record was not durably written")
        }
        if !report.canExecute {
            reasons.append("understanding confidence \(report.understandingConfidence)% is below \(report.confidenceThreshold)%")
        }
        if risk == .regulated && report.understandingConfidence < report.confidenceThreshold {
            reasons.append("regulated domain requires temporary subject-matter expertise before execution")
        }
        return reasons
    }

    private static let regulatedSignals = [
        "medical", "radiology", "dicom", "hipaa", "fda", "clinical", "healthcare",
        "legal", "law", "contract", "finance", "financial", "banking", "trading",
        "payment", "billing", "factory", "robot", "robotics", "hardware", "actuator",
        "customers safe", "customer safety", "safety critical"
    ]

    private static let unfamiliarSignals = [
        "unfamiliar domain", "new domain", "learn the domain", "become expert",
        "subject matter expert", "sme", "hugging face", "huggingface", "local model",
        "small model", "mlx", "ollama", "gguf", "symbolic", "rulebook",
        "digital twin", "physics simulator", "market simulation", "synthetic customer",
        "pricing experiment"
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
