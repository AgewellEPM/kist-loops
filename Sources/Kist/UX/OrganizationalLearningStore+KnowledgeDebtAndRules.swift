import Foundation
import AgentCore

extension OrganizationalLearningStore {
    @discardableResult
    func addKnowledgeDebt(topic: String, reason: String = "", visit: String = "",
                          impact: Int = 3, priority: KnowledgeDebtRecord.Priority = .medium,
                          estimatedLearning: String = "",
                          expectedBenefit: [String] = [],
                          seasonalWindow: SeasonalMemoryWindow? = nil) -> KnowledgeDebtRecord? {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        let nowValue = instant.timeIntervalSince1970
        let record = Self.bounded(KnowledgeDebtRecord(
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
            updatedAt: nowValue,
            temporal: OrganizationalMemoryTemporal.make(
                createdAt: instant, decayRate: .slow, seasonalWindow: seasonalWindow)
        ))
        guard upsert(record, seasonalWindow: seasonalWindow) else { return nil }
        return record
    }

    @discardableResult
    func markKnowledgeDebtDone(_ rawID: String) -> Bool {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        return mutateJSONL(KnowledgeDebtRecord.self, path: debtPath) { records in
            guard let idx = records.firstIndex(where: { $0.id == id }),
                  var envelope = records[idx].temporalProjection,
                  instant >= envelope.updatedAt else { return false }
            do {
                try envelope.retire(reason: "knowledge debt completed", now: instant)
            } catch {
                return false
            }
            records[idx].status = .done
            records[idx].updatedAt = envelope.updatedAt.timeIntervalSince1970
            records[idx].temporal = envelope
            return true
        }
    }

    @discardableResult
    func promoteOrganizationalRule(lesson: String, confidence: Int = 90, reason: String = "",
                                   evidence: [String] = [], sourceCapsuleID: String? = nil,
                                   seasonalWindow: SeasonalMemoryWindow? = nil) -> OrganizationalRuleRecord? {
        let instant = OrganizationalMemoryTemporal.canonicalInstant(now())
        let nowValue = instant.timeIntervalSince1970
        let cleanLesson = Self.safe(lesson)
        let cleanReason = Self.safe(reason.isEmpty ? "Proposed by Teach Captain." : reason)
        let cleanEvidence = evidence.map(Self.safe)
        let decision = organizationalRulePromotionDecision(lesson: cleanLesson,
                                                           confidence: confidence,
                                                           evidence: cleanEvidence)
        let status: OrganizationalRuleRecord.Status = decision.accepted ? .active : .proposed
        let finalReason = decision.accepted
            ? cleanReason
            : Self.safe(cleanReason + " Promotion blocked: " + decision.blockers.joined(separator: "; "))
        let record = Self.bounded(OrganizationalRuleRecord(
            id: Self.ruleID(cleanLesson),
            lesson: cleanLesson,
            confidence: min(100, max(1, confidence)),
            reason: finalReason,
            evidence: cleanEvidence,
            sourceCapsuleID: sourceCapsuleID,
            status: status,
            createdAt: nowValue,
            updatedAt: nowValue,
            temporal: OrganizationalMemoryTemporal.make(
                createdAt: instant, decayRate: .verySlow, seasonalWindow: seasonalWindow)
        ))
        let persisted = upsert(record, seasonalWindow: seasonalWindow)
        guard persisted else { return nil }
        if status == .proposed {
            addKnowledgeDebt(topic: "Prove organizational rule: \(cleanLesson)",
                             reason: "Captain proposed this rule, but it lacks enough verified evidence to become permanent. Blockers: \(decision.blockers.joined(separator: "; "))",
                             visit: "Preserve benchmark and review artifacts for a future exact receipt-bound rule verifier.",
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
        // Text that says "passed", and even a path that happens to exist, proves neither the
        // claimed run nor this exact rule. Keep it as advisory evidence until a future verifier can
        // bind an accepted receipt's digest and mission subject to the exact canonical rule text.
        _ = raw
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
                    "Reason: \(rule.reason)",
                    "Blockers: \(decision.blockers.joined(separator: "; "))",
                ]
                if !rule.evidence.isEmpty {
                    lines.append("Evidence: \(rule.evidence.joined(separator: "; "))")
                }
                lines.append("")
            }
        }
        lines.append("`/teach add` records an advisory proposal. Permanent promotion remains blocked until exact receipt-bound rule verification exists.")
        return lines.joined(separator: "\n")
    }

}
