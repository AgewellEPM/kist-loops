import Foundation
import AgentCore

extension OrganizationalLearningStore {
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

    func isVerifiedOrganizationalRuleEvidence(_ raw: String) -> Bool {
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

}
