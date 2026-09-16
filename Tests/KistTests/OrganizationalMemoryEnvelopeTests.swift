import XCTest
@testable import Kist
@testable import AgentCore

final class OrganizationalMemoryEnvelopeTests: XCTestCase {
    private var root = ""
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "organizational-envelope-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
        try FileManager.default.createDirectory(atPath: root + "/catalog", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(atPath: root)
    }

    private func access() throws -> AgentMemoryAccess {
        try XCTUnwrap(KistRunner.sharedAgentMemory(root: root, opts: KistOptions(project: root),
                                                  projectCatalogRoot: root + "/catalog"))
    }

    private func decision(_ entry: AgentMemoryEntry, at instant: Date) -> MemoryAdmissionDecision.Verdict {
        MemoryAdmissionGate(hostProject: root, authorizedProjects: []).decide(
            MemoryAdmissionCandidate(entry: entry, provenance: .hostProjectedLesson, sourceProject: root),
            at: instant)
    }

    func testEveryOrganizationalShelfCarriesItsOriginalEnvelopeThroughSharedRecall() throws {
        let instant = now
        let store = OrganizationalLearningStore(projectRoot: root, now: { instant })
        let observed = now.addingTimeInterval(-86_400)
        let epoch = observed.timeIntervalSince1970
        let rule = OrganizationalRuleRecord(
            id: "rule", lesson: "orchidMarker routing", confidence: 90, reason: "advisory",
            evidence: [], sourceCapsuleID: nil, status: .proposed, createdAt: epoch, updatedAt: epoch)
        let debt = KnowledgeDebtRecord(
            id: "debt", topic: "orchidMarker research", reason: "advisory", visit: "local",
            impact: 3, priority: .high, estimatedLearning: "routing", expectedBenefit: [],
            sourceCapsuleID: nil, status: .open, createdAt: epoch, updatedAt: epoch)
        let capsule = LearningCapsule(
            id: "capsule", taskTitle: "orchidMarker episode", status: .pass, summary: "observation",
            learned: [], surprises: [], slowdowns: [], assumptionsToChallenge: [],
            futureEvolution: "", tokenCount: 0, at: epoch)
        let evidence = LearningEvidenceRecord(
            id: "evidence", kind: .selfHealSpecialist, objective: "orchidMarker evidence",
            specialistName: "researcher", role: "researcher", preferredModel: "codex",
            artifactPath: "local-evidence.txt", memoryRecorded: true, taskIDs: [],
            taskEvidenceUpdated: 0, createdAt: epoch)
        XCTAssertTrue(store.appendJSON(rule, to: store.rulesPath))
        XCTAssertTrue(store.appendJSON(debt, to: store.debtPath))
        XCTAssertTrue(store.appendJSON(capsule, to: store.capsulesPath))
        XCTAssertTrue(store.appendJSON(evidence, to: store.evidenceLedgerPath))

        var expected: [String: MemoryTemporalEnvelope] = [
            "rule": try XCTUnwrap(rule.temporalProjection),
            "debt": try XCTUnwrap(debt.temporalProjection),
            "capsule": try XCTUnwrap(capsule.temporalProjection),
            "evidence": try MemoryTemporalEnvelope(createdAt: observed, decayRate: .slow),
        ]
        let genericShelves: [(String, String, MemoryDecayRate)] = [
            ("knowledge", store.knowledgeIndexPath, .medium),
            ("industry", store.industryIntelligencePath, .fast),
            ("evolution", store.evolutionProposalsPath, .medium),
            ("benchmark", store.benchmarksPath, .fast),
        ]
        for (id, path, decay) in genericShelves {
            let envelope = try MemoryTemporalEnvelope(createdAt: observed, decayRate: decay)
            XCTAssertTrue(store.appendJSON(DiskMemoryRecord(
                id: id, title: "orchidMarker \(id)", createdAt: epoch, updatedAt: epoch,
                temporal: envelope), to: path), id)
            expected[id] = envelope
        }
        let scorecards = CaptainLearningStore(projectRoot: root)
        XCTAssertTrue(scorecards.record(CaptainLearningSample(
            taskSignature: "orchidMarker", taskTags: ["orchid", "marker"], language: nil,
            role: "coder", providerId: "codex", model: nil, source: .liveEval,
            success: true, atEpoch: epoch)))
        let scorecard = try XCTUnwrap(store.captainLearningBenchmarkCandidates(
            limit: 1, nowEpoch: now.timeIntervalSince1970).first)
        expected[scorecard.recordID] = try MemoryTemporalEnvelope(
            createdAt: observed, validUntil: observed.addingTimeInterval(
                CaptainLearningRecencyPolicy.maximumAgeSeconds), decayRate: .fast)

        let paths = [store.rulesPath, store.debtPath, store.capsulesPath, store.evidenceLedgerPath]
            + genericShelves.map { $0.1 } + [root + "/" + CaptainLearningStore.relativePath]
        let before = try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let access = try access()
        let supplied = try XCTUnwrap(access.supplementalRecall)(root, "orchidMarker", now)
        for (id, envelope) in expected {
            let entry = try XCTUnwrap(supplied.first { $0.id == id }, id)
            XCTAssertEqual(entry.temporal, envelope, id)
            XCTAssertEqual(entry.observedAt, envelope.createdAt, id)
            XCTAssertEqual(entry.provenanceHint, .hostProjectedLesson, id)
            guard case .admitted(let salience, let note) = decision(entry, at: now) else {
                return XCTFail("\(id) should pass gate evaluation")
            }
            XCTAssertEqual(salience, envelope.evaluate(at: now).salience, id)
            XCTAssertTrue(note.contains("envelope-checked"), id)
        }
        let recalled = try access.recall(query: "orchidMarker", limit: 30, at: now)
        XCTAssertTrue(recalled.issues.isEmpty, recalled.issues.joined(separator: "; "))
        XCTAssertTrue(Set(expected.keys).isSubset(of: Set(recalled.entries.map(\.id))),
                      "missing: \(Set(expected.keys).subtracting(recalled.entries.map(\.id))); denied: \(recalled.denialReasons); issues: \(recalled.issues)")
        XCTAssertEqual(try paths.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }, before,
                       "projection and admission must not rewrite source clocks or content")
    }

    func testCapturedHostProjectionExpiresAtGateAfterUpstreamRead() throws {
        let store = OrganizationalLearningStore(projectRoot: root)
        let envelope = try MemoryTemporalEnvelope(
            createdAt: now.addingTimeInterval(-60), validUntil: now.addingTimeInterval(30),
            decayRate: .fast)
        XCTAssertTrue(store.appendJSON(DiskMemoryRecord(
            id: "expiring", title: "expiringMarker", createdAt: envelope.createdAt.timeIntervalSince1970,
            updatedAt: envelope.updatedAt.timeIntervalSince1970, temporal: envelope), to: store.knowledgeIndexPath))
        let supplied = try XCTUnwrap(try access().supplementalRecall)(root, "expiringMarker", now)
        let entry = try XCTUnwrap(supplied.first { $0.id == "expiring" })
        guard case .admitted = decision(entry, at: now) else { return XCTFail("initially eligible") }
        XCTAssertEqual(decision(entry, at: now.addingTimeInterval(60)),
                       .denied(.temporalIneligible, detail: "validity-expired"))
    }

    func testCapturedSeasonAndDecayAreReevaluatedWithoutRefreshingEvidence() throws {
        let store = OrganizationalLearningStore(projectRoot: root)
        let february = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-02-01T12:00:00Z"))
        let march = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z"))
        let season = try SeasonalMemoryWindow(months: [2], offSeasonFactor: 0)
        let envelope = try MemoryTemporalEnvelope(createdAt: february, seasonalWindow: season,
                                                  decayRate: .medium)
        XCTAssertTrue(store.appendJSON(DiskMemoryRecord(
            id: "seasonal", title: "seasonalMarker", createdAt: february.timeIntervalSince1970,
            updatedAt: february.timeIntervalSince1970, temporal: envelope), to: store.knowledgeIndexPath))
        let supplied = try XCTUnwrap(try access().supplementalRecall)(root, "seasonalMarker", february)
        let entry = try XCTUnwrap(supplied.first { $0.id == "seasonal" })
        XCTAssertEqual(entry.temporal, envelope)
        guard case .denied(.belowSalienceFloor, _) = decision(entry, at: march) else {
            return XCTFail("the gate must enforce the captured explicit season")
        }
        let later = february.addingTimeInterval(86_400 * 3_000)
        guard case .denied(.belowSalienceFloor, _) = decision(entry, at: later) else {
            return XCTFail("upstream eligibility cannot freeze temporal salience")
        }
    }

    func testScorecardSnapshotExpiresWhenOldestIncludedObservationAgesOut() throws {
        let oldest = now.addingTimeInterval(-29 * 86_400)
        let newest = now.addingTimeInterval(-86_400)
        let store = CaptainLearningStore(projectRoot: root)
        for instant in [oldest, newest] {
            XCTAssertTrue(store.record(CaptainLearningSample(
                taskSignature: "scorecardMarker", taskTags: ["coding"], language: nil,
                role: "coder", providerId: "codex", model: nil, source: .liveEval,
                success: true, atEpoch: instant.timeIntervalSince1970)))
        }
        let recall = try XCTUnwrap(try access().supplementalRecall)
        let entry = try XCTUnwrap(recall(root, "scorecardMarker", now).first {
            $0.title.contains("Unsigned Scorecard")
        })
        XCTAssertEqual(entry.temporal?.createdAt, oldest)
        XCTAssertEqual(entry.temporal?.updatedAt, newest)
        XCTAssertEqual(entry.temporal?.validUntil, oldest.addingTimeInterval(30 * 86_400))
        XCTAssertTrue(entry.text.contains("Success: 2/2"))
        let later = now.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(decision(entry, at: later), .denied(.temporalIneligible, detail: "validity-expired"))
        let refreshed = try XCTUnwrap(recall(root, "scorecardMarker", later).first {
            $0.title.contains("Unsigned Scorecard")
        })
        XCTAssertEqual(refreshed.temporal?.createdAt, newest)
        XCTAssertTrue(refreshed.text.contains("Success: 1/1"))
        guard case .admitted = decision(refreshed, at: later) else {
            return XCTFail("new aggregate contains only surviving observations")
        }
    }

    func testHostDoesNotPromoteUnknownAgeGenericRowsOrResearchArtifacts() throws {
        let store = OrganizationalLearningStore(projectRoot: root)
        XCTAssertTrue(store.appendJSON(DiskMemoryRecord(id: "unknown", title: "unknownMarker"),
                                       to: store.knowledgeIndexPath))
        try FileManager.default.createDirectory(atPath: store.researchArchiveRoot, withIntermediateDirectories: true)
        try "unknownMarker".write(toFile: store.researchArchiveRoot + "/raw.md", atomically: true, encoding: .utf8)
        let recall = try access().recall(query: "unknownMarker", at: now)
        XCTAssertFalse(recall.entries.contains { $0.text.contains("unknownMarker") })
        XCTAssertEqual(store.loadJSONL(DiskMemoryRecord.self, path: store.knowledgeIndexPath).count, 1)
        XCTAssertEqual(store.rawResearchArchiveAuditCandidates(limit: 10).count, 1)
    }

    func testCandidateCodingPreservesEnvelopeAndLegacyAbsenceStaysUnknown() throws {
        let envelope = try MemoryTemporalEnvelope(createdAt: now, decayRate: .fast)
        let candidate = CaptainMemoryCandidate(layerID: .knowledgeIndex, recordID: "coding",
            title: "coding", excerpt: "advisory", sourcePath: "local", temporal: envelope)
        XCTAssertEqual(try JSONDecoder().decode(CaptainMemoryCandidate.self,
                                               from: JSONEncoder().encode(candidate)), candidate)
        let legacy = Data("""
        {"layerID":"knowledgeIndex","recordID":"legacy","title":"legacy","excerpt":"advisory","sourcePath":"local","baseRelevance":1}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(CaptainMemoryCandidate.self, from: legacy).temporal)
    }
}
