import Foundation
import AgentCore

private struct OrganizationalTemporalCapsuleRow {
    let row: OrganizationalJSONLRow<LearningCapsule>
    let evaluation: TemporalMemoryEvaluation
    let temporal: MemoryTemporalEnvelope
    var eventAt: Date { temporal.createdAt }
}

private struct OrganizationalTemporalGenericRow {
    let row: OrganizationalJSONLRow<DiskMemoryRecord>
    let evaluation: TemporalMemoryEvaluation
    let temporal: MemoryTemporalEnvelope
    var eventAt: Date { temporal.createdAt }
    var transactionAt: Date { temporal.updatedAt }
}

extension OrganizationalLearningStore {
    /// Operational projection of capsule history. Raw `latestCapsule`/`capsules` remain audit APIs
    /// and deliberately expose rows that are expired, retired, future-dated, or out of season.
    func latestTemporallyEligibleCapsule() -> LearningCapsule? {
        latestTemporallyEligibleCapsule(at: now())
    }

    func latestTemporallyEligibleCapsule(at instant: Date) -> LearningCapsule? {
        temporallyEligibleCapsuleRows(at: instant)
            .sorted(by: Self.latestCapsuleOrder)
            .first?
            .row.value
    }

    func openKnowledgeDebt(limit: Int = 20) -> [KnowledgeDebtRecord] {
        openKnowledgeDebt(limit: limit, at: now())
    }

    func openKnowledgeDebt(limit: Int = 20, at instant: Date) -> [KnowledgeDebtRecord] {
        let records = loadJSONLWithOrdinals(KnowledgeDebtRecord.self, path: debtPath)
            // Historical dashboard suggestions carry a source capsule. They were never accepted as
            // durable work, so retain them on disk for audit but do not resurrect them as live debt.
            .filter {
                $0.value.status == .open && $0.value.sourceCapsuleID == nil &&
                    ($0.value.temporalProjection?.evaluate(at: instant).isRetrievalEligible == true)
            }
            .sorted {
                if $0.value.impact != $1.value.impact { return $0.value.impact > $1.value.impact }
                if $0.value.updatedAt != $1.value.updatedAt { return $0.value.updatedAt > $1.value.updatedAt }
                return $0.ordinal < $1.ordinal
            }
        return records.prefix(max(0, limit)).map { Self.bounded($0.value) }
    }

    func permanentRules(limit: Int = 20) -> [OrganizationalRuleRecord] {
        // Source-controlled JSONL status is not authority. Until an exact accepted receipt can be
        // verified against this rule's canonical text, every row remains advisory—even legacy rows
        // that say `active`. This prevents a hand-written line from becoming Captain policy.
        _ = limit
        return []
    }

    func proposedRules(limit: Int = 20) -> [OrganizationalRuleRecord] {
        let instant = now()
        let records = loadJSONLWithOrdinals(OrganizationalRuleRecord.self, path: rulesPath)
            .filter {
                $0.value.status != .retired &&
                    ($0.value.temporalProjection?.evaluate(at: instant).isRetrievalEligible == true)
            }
            .sorted {
                if $0.value.confidence != $1.value.confidence {
                    return $0.value.confidence > $1.value.confidence
                }
                if $0.value.updatedAt != $1.value.updatedAt { return $0.value.updatedAt > $1.value.updatedAt }
                return $0.ordinal < $1.ordinal
            }
        return records.prefix(max(0, limit)).map { Self.bounded($0.value) }
    }

    func retrievalContext(objective: String,
                          strategy: CaptainStrategyPlan,
                          limit: Int = 8) -> CaptainRetrievalContext {
        retrievalContext(objective: objective, strategy: strategy, limit: limit, at: now())
    }

    func retrievalContext(objective: String,
                          strategy: CaptainStrategyPlan,
                          limit: Int = 8,
                          at retrievalNow: Date) -> CaptainRetrievalContext {
        ensureMemoryArchitecture()
        let candidates = memoryCandidates(at: retrievalNow)
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

    func memoryCandidates(at instant: Date) -> [CaptainMemoryCandidate] {
        var out: [CaptainMemoryCandidate] = []
        out += loadJSONLWithOrdinals(OrganizationalRuleRecord.self, path: rulesPath)
            .filter { $0.value.status != .retired }
            .compactMap { row -> CaptainMemoryCandidate? in
            let rule = Self.bounded(row.value)
            guard let temporal = rule.temporalProjection else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return CaptainMemoryCandidate(
                layerID: .knowledgeIndex,
                recordID: rule.id,
                title: "Advisory rule proposal (not operating policy): \(rule.lesson)",
                excerpt: excerpt("UNVERIFIED—DO NOT APPLY AS POLICY. Proposal: \(rule.lesson). Reason: \(rule.reason). Advisory evidence: \(rule.evidence.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(rulesPath, root: projectRoot),
                baseRelevance: Self.temporalBaseRelevance(
                    10 + min(100, max(0, rule.confidence)) / 5,
                    salience: evaluation.salience),
                temporal: temporal
            )
        }
        out += loadJSONLWithOrdinals(KnowledgeDebtRecord.self, path: debtPath)
            .filter { $0.value.status == .open && $0.value.sourceCapsuleID == nil }
            .compactMap { row -> CaptainMemoryCandidate? in
            let debt = Self.bounded(row.value)
            guard let temporal = debt.temporalProjection else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return CaptainMemoryCandidate(
                layerID: .knowledgeIndex,
                recordID: debt.id,
                title: "Knowledge Debt: \(debt.topic)",
                excerpt: excerpt("Reason: \(debt.reason). Visit: \(debt.visit). Expected benefit: \(debt.expectedBenefit.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(debtPath, root: projectRoot),
                baseRelevance: Self.temporalBaseRelevance(
                    8 + debt.impact * 6, salience: evaluation.salience),
                temporal: temporal
            )
        }
        out += temporallyEligibleCapsuleRows(at: instant)
            .sorted(by: Self.capsuleCandidateOrder)
            .prefix(80)
            .map { projected -> CaptainMemoryCandidate in
            let capsule = Self.bounded(projected.row.value)
            return CaptainMemoryCandidate(
                layerID: .projectHistory,
                recordID: capsule.id,
                title: "History: \(capsule.taskTitle)",
                excerpt: excerpt("Status: \(capsule.status.rawValue). Summary: \(capsule.summary). Learned: \(capsule.learned.joined(separator: "; ")). Surprises: \(capsule.surprises.joined(separator: "; "))"),
                sourcePath: Self.projectRelative(capsulesPath, root: projectRoot),
                baseRelevance: Self.temporalBaseRelevance(
                    capsule.status == .pass ? 12 : 18,
                    salience: projected.evaluation.salience),
                temporal: projected.temporal
            )
        }
        out += captainLearningBenchmarkCandidates(
            limit: 80, nowEpoch: instant.timeIntervalSince1970)
        out += evidenceLedgerCandidates(limit: 80, at: instant)
        out += genericMemoryCandidates(
            path: knowledgeIndexPath, layerID: .knowledgeIndex, base: 18, at: instant,
            allowedDecayRates: [.fast, .medium])
        out += genericMemoryCandidates(
            path: industryIntelligencePath, layerID: .industryIntelligence, base: 14,
            at: instant, allowedDecayRates: [.fast])
        out += genericMemoryCandidates(
            path: evolutionProposalsPath, layerID: .knowledgeIndex, base: 22, at: instant,
            allowedDecayRates: [.medium])
        out += genericMemoryCandidates(
            path: benchmarksPath, layerID: .benchmarks, base: 18, at: instant,
            allowedDecayRates: [.fast])
        // Research documents are immutable audit artifacts, not self-dating memory. Operational
        // recall comes through their explicit, temporally indexed DiskMemoryRecord instead of file
        // mtime, which can be reset by copies or rewrites.
        return dedupe(out)
    }

    private func temporallyEligibleCapsuleRows(
        at instant: Date
    ) -> [OrganizationalTemporalCapsuleRow] {
        loadJSONLWithOrdinals(LearningCapsule.self, path: capsulesPath).compactMap { row in
            let capsule = Self.bounded(row.value)
            guard let temporal = capsule.temporalProjection else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return OrganizationalTemporalCapsuleRow(
                row: OrganizationalJSONLRow(ordinal: row.ordinal, value: capsule),
                evaluation: evaluation,
                temporal: temporal)
        }
    }

    private static func capsuleCandidateOrder(
        _ lhs: OrganizationalTemporalCapsuleRow,
        _ rhs: OrganizationalTemporalCapsuleRow
    ) -> Bool {
        if lhs.evaluation.salience != rhs.evaluation.salience {
            return lhs.evaluation.salience > rhs.evaluation.salience
        }
        if lhs.eventAt != rhs.eventAt { return lhs.eventAt > rhs.eventAt }
        return lhs.row.ordinal > rhs.row.ordinal
    }

    private static func latestCapsuleOrder(
        _ lhs: OrganizationalTemporalCapsuleRow,
        _ rhs: OrganizationalTemporalCapsuleRow
    ) -> Bool {
        if lhs.eventAt != rhs.eventAt { return lhs.eventAt > rhs.eventAt }
        return lhs.row.ordinal > rhs.row.ordinal
    }

    func evidenceLedgerCandidates(limit: Int, at instant: Date) -> [CaptainMemoryCandidate] {
        let projected = loadJSONLWithOrdinals(
            LearningEvidenceRecord.self, path: evidenceLedgerPath
        ).compactMap { row -> (OrganizationalJSONLRow<LearningEvidenceRecord>,
                               TemporalMemoryEvaluation, MemoryTemporalEnvelope)? in
            let record = row.value
            guard let temporal = OrganizationalMemoryTemporal.legacy(
                createdAt: record.createdAt, updatedAt: record.createdAt,
                decayRate: .slow) else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return (row, evaluation, temporal)
        }.sorted { lhs, rhs in
            if lhs.1.salience != rhs.1.salience { return lhs.1.salience > rhs.1.salience }
            if lhs.2.createdAt != rhs.2.createdAt { return lhs.2.createdAt > rhs.2.createdAt }
            return lhs.0.ordinal > rhs.0.ordinal
        }.prefix(max(0, limit))

        return projected.map { projected in
            let record = projected.0.value
            let evaluation = projected.1
            let taskIDs = record.taskIDs.isEmpty
                ? "none"
                : record.taskIDs.map(String.init).joined(separator: ", ")
            let memoryStatus = record.memoryRecorded ? "indexed" : "not indexed"
            let excerptText = """
            Durable specialist evidence. Kind: \(record.kind.rawValue). Objective: \(record.objective). Specialist: \(record.specialistName). Role: \(record.role). Preferred model: \(record.preferredModel). Artifact: \(record.artifactPath). Memory: \(memoryStatus). Task IDs: \(taskIDs). Task evidence updated: \(record.taskEvidenceUpdated). Ledger: \(Self.projectRelative(evidenceLedgerPath, root: projectRoot)).
            """
            let base = record.taskEvidenceUpdated > 0 && record.memoryRecorded ? 40 : 26
            return CaptainMemoryCandidate(layerID: .knowledgeIndex,
                                          recordID: record.id,
                                          title: "Evidence Ledger: \(record.specialistName) -> \(record.objective)",
                                          excerpt: excerpt(excerptText),
                                          sourcePath: record.artifactPath,
                                          baseRelevance: Self.temporalBaseRelevance(
                                            base, salience: evaluation.salience),
                                          temporal: projected.2)
        }
    }

    func captainLearningBenchmarkCandidates(limit: Int,
                                             nowEpoch: Double) -> [CaptainMemoryCandidate] {
        captainLearningRetrievalSummaries(now: nowEpoch)
            .prefix(max(0, limit))
            .compactMap { summary -> CaptainMemoryCandidate? in
                // This aggregate expires when its oldest contributing sample leaves the
                // scorecard's 30-day window. Re-reading cannot rejuvenate that snapshot.
                guard let temporal = try? MemoryTemporalEnvelope(
                    createdAt: Date(timeIntervalSince1970: summary.earliestEpoch),
                    updatedAt: Date(timeIntervalSince1970: summary.latestEpoch),
                    validUntil: Date(timeIntervalSince1970:
                        summary.earliestEpoch + CaptainLearningRecencyPolicy.maximumAgeSeconds),
                    decayRate: .fast) else { return nil }
                let tags = summary.taskTags.isEmpty ? "general" : summary.taskTags.joined(separator: ", ")
                let language = summary.language ?? "any language"
                let percent = Int((summary.successRate * 100).rounded())
                let status = summary.promoted ? "route-bias eligible" : "shadow only"
                let modelEvidence = summary.providerId
                    + (summary.averageTokens > 0 ? " avg \(summary.averageTokens) tok" : "")
                    + (summary.averageLatencyMs > 0 ? " avg \(summary.averageLatencyMs)ms" : "")
                let excerptText = """
                UNSIGNED ADVISORY — not a receipt or independent benchmark authority. Source: Captain scorecard observations from benchmark and live-eval loops. Role: \(summary.role). Provider: \(summary.providerId). Task tags: \(tags). Language: \(language). Status: \(status). Success: \(summary.successes)/\(summary.samples) (\(percent)%). Tool failures: \(summary.toolFailures). Model/cost signal: \(modelEvidence).
                """
                let idParts = ["learning", summary.role, summary.providerId, tags, language]
                return CaptainMemoryCandidate(
                    layerID: .benchmarks,
                    recordID: Self.slug(idParts.joined(separator: "-")),
                    title: "Unsigned Scorecard Observations: \(summary.providerId) for \(summary.role) (\(tags))",
                    excerpt: excerpt(excerptText),
                    sourcePath: CaptainLearningStore.relativePath,
                    baseRelevance: summary.promoted ? 44 : min(34, 12 + summary.samples * 5),
                    temporal: temporal
                )
            }
    }

    /// Reports temporal admission without mutating or rejuvenating legacy rows. A row that cannot
    /// present one internally consistent clock remains available through raw JSONL readers only.
    func genericMemoryTemporalReadiness() -> (operational: Int, auditOnly: Int) {
        let paths = [
            knowledgeIndexPath,
            industryIntelligencePath,
            evolutionProposalsPath,
            benchmarksPath,
        ]
        let records = paths.flatMap { loadJSONL(DiskMemoryRecord.self, path: $0) }
        let operational = records.reduce(into: 0) { count, record in
            if record.temporalProjection != nil { count += 1 }
        }
        return (operational, records.count - operational)
    }

    static func temporalBaseRelevance(_ base: Int, salience: Double) -> Int {
        guard salience.isFinite else { return 0 }
        return min(100, max(0, Int((Double(base) * salience).rounded())))
    }

    func genericMemoryCandidates(path: String,
                                         layerID: CaptainMemoryLayerID,
                                         base: Int,
                                         at instant: Date,
                                         allowedDecayRates: [MemoryDecayRate])
        -> [CaptainMemoryCandidate] {
        let eligible = loadJSONLWithOrdinals(
            DiskMemoryRecord.self, path: path
        ).compactMap { row -> OrganizationalTemporalGenericRow? in
            // LIST is read only through its validated, escaped advisory-data renderer. Reusing the
            // generic summary/body projection would strip that boundary in Captain prompt context.
            guard !Self.isListMemory(row.value) else { return nil }
            let record = Self.bounded(row.value)
            guard let temporal = record.temporalProjection,
                  allowedDecayRates.contains(temporal.decayRate) else { return nil }
            let evaluation = temporal.evaluate(at: instant)
            guard evaluation.isRetrievalEligible,
                  evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else { return nil }
            return OrganizationalTemporalGenericRow(
                row: OrganizationalJSONLRow(ordinal: row.ordinal, value: record),
                evaluation: evaluation,
                temporal: temporal)
        }

        // A stable ID names one advisory memory across transaction revisions. Select the newest
        // eligible revision before relevance ranking so a physically older or more salient copy can
        // never shadow a later update. Ineligible future/retired revisions do not hide prior audit
        // history; they simply cannot enter this operational projection.
        var newestByID: [String: OrganizationalTemporalGenericRow] = [:]
        var anonymous: [OrganizationalTemporalGenericRow] = []
        for candidate in eligible {
            guard let rawID = candidate.row.value.id else {
                anonymous.append(candidate)
                continue
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                anonymous.append(candidate)
                continue
            }
            if let prior = newestByID[id],
               prior.transactionAt > candidate.transactionAt
                || (prior.transactionAt == candidate.transactionAt
                    && prior.row.ordinal > candidate.row.ordinal) {
                continue
            }
            newestByID[id] = candidate
        }

        let projected = (Array(newestByID.values) + anonymous).sorted { lhs, rhs in
            if lhs.evaluation.salience != rhs.evaluation.salience {
                return lhs.evaluation.salience > rhs.evaluation.salience
            }
            if lhs.eventAt != rhs.eventAt { return lhs.eventAt > rhs.eventAt }
            return lhs.row.ordinal > rhs.row.ordinal
        }.prefix(80)

        return projected.map { projected in
            let record = projected.row.value
            let index = projected.row.ordinal
            let title = Self.safe(record.title ?? record.summary ?? "\(layerID.title) \(index + 1)")
            let body = [record.summary, record.body, record.tags?.joined(separator: ", ")]
                .compactMap { $0 }
                .joined(separator: " ")
            let confidence = min(100, max(0, record.confidence ?? 0))
            let impact = min(5, max(0, record.impact ?? 0))
            let relevance = max(base, confidence / 2, impact * 8)
            return CaptainMemoryCandidate(layerID: layerID,
                                          recordID: record.id ?? "\(layerID.rawValue)-\(index + 1)",
                                          title: title,
                                          excerpt: excerpt(body.isEmpty ? title : body),
                                          sourcePath: Self.projectRelative(record.source ?? path, root: projectRoot),
                                          baseRelevance: Self.temporalBaseRelevance(
                                            relevance, salience: projected.evaluation.salience),
                                          temporal: projected.temporal)
        }
    }

    /// Explicit raw-audit projection only. Never feed these unindexed filesystem artifacts into
    /// operational recall; they have no content-bound digest or trustworthy event clock.
    func rawResearchArchiveAuditCandidates(limit: Int) -> [CaptainMemoryCandidate] {
        let boundedLimit = min(40, max(0, limit))
        guard boundedLimit > 0,
              let confined = try? ConfinedRoot(root: researchArchiveRoot, readOnly: true) else {
            return []
        }

        // Keep even the explicit audit walk bounded. Descriptor-relative directory reads and stable
        // reads refuse symlinks, hardlinks, special files, oversized files, and mid-read changes.
        var directories = [""]
        var nextDirectory = 0
        var inspectedEntries = 0
        var files: [String] = []
        while nextDirectory < directories.count,
              inspectedEntries < 4_096,
              files.count < boundedLimit {
            let directory = directories[nextDirectory]
            nextDirectory += 1
            guard let entries = try? confined.entries(directory) else { continue }
            for entry in entries {
                guard inspectedEntries < 4_096, files.count < boundedLimit else { break }
                inspectedEntries += 1
                let relative = directory.isEmpty ? entry.name : directory + "/" + entry.name
                if entry.isDir {
                    directories.append(relative)
                    continue
                }
                let ext = (relative as NSString).pathExtension.lowercased()
                if ["md", "txt", "json"].contains(ext) { files.append(relative) }
            }
        }

        var out: [CaptainMemoryCandidate] = []
        for relative in files {
            let path = researchArchiveRoot + "/" + relative
            guard let data = try? confined.readStableData(relative, maxBytes: 1_024 * 1_024),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let title = Self.boundedText((relative as NSString).lastPathComponent, limit: 2_048)
            out.append(CaptainMemoryCandidate(layerID: .researchArchive,
                                              recordID: String(Self.slug(relative).prefix(256)),
                                              title: "Research: \(title)",
                                              excerpt: excerpt(text),
                                              sourcePath: Self.projectRelative(path, root: projectRoot),
                                              baseRelevance: 12))
        }
        return out
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

}
