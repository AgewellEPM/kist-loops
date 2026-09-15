import XCTest
@testable import AgentCore

/// Q9 admission gate: unit pins for every provenance-class policy (each class is one recall source
/// site, so these are the per-site assertions the multi-site rule requires) plus end-to-end pins
/// proving `AgentMemoryAccess.recall` actually enforces the gate at every site.
final class MemoryAdmissionGateTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "admission-gate-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    private let host = "/host/project"
    private let other = "/other/authorized"

    private func gate() -> MemoryAdmissionGate {
        MemoryAdmissionGate(hostProject: host, authorizedProjects: [other])
    }

    private func entry(_ id: String = "e1", text: String = "durable observation content",
                       observedAt: Date? = nil, temporal: MemoryTemporalEnvelope? = nil) -> AgentMemoryEntry {
        AgentMemoryEntry(id: id, title: "t", text: text, locator: "/tmp/x", observedAt: observedAt,
                         temporal: temporal)
    }

    private func days(_ count: Double, before now: Date) -> Date {
        now.addingTimeInterval(-86_400 * count)
    }

    // MARK: - Per-class policy units (one per recall source site)

    func testCuratedFactAdmittedWithoutClockAndNoteNamesSupersessionPolicy() {
        let verdict = gate().decide(MemoryAdmissionCandidate(
            entry: entry(), provenance: .curatedFact, sourceProject: host), at: Date())
        guard case .admitted(let salience, let note) = verdict else {
            return XCTFail("curated fact must admit without a clock, got \(verdict)")
        }
        XCTAssertEqual(salience, 1)
        XCTAssertTrue(note.contains("supersession"), "policy note must name the governing policy")
    }

    func testHistoryEventRequiresClockAndDecaysToDenial() {
        let now = Date()
        let fresh = gate().decide(MemoryAdmissionCandidate(
            entry: entry(observedAt: now), provenance: .historyEvent, sourceProject: host), at: now)
        XCTAssertTrue({ if case .admitted = fresh { return true }; return false }(),
                      "fresh history event must admit")
        let stale = gate().decide(MemoryAdmissionCandidate(
            entry: entry(observedAt: days(3_000, before: now)), provenance: .historyEvent,
            sourceProject: host), at: now)
        XCTAssertEqual(stale, .denied(.belowSalienceFloor,
                                      detail: String(format: "salience %.4f", 0.0)),
                       "decayed history event must deny below the salience floor")
        let clockless = gate().decide(MemoryAdmissionCandidate(
            entry: entry(), provenance: .historyEvent, sourceProject: host), at: now)
        guard case .denied(.unknownAge, _) = clockless else {
            return XCTFail("history event without any clock must deny fail-closed, got \(clockless)")
        }
    }

    func testEpisodeAttachedSupersededEnvelopeIsDeniedEvenWhenRecent() throws {
        let now = Date()
        var envelope = try MemoryTemporalEnvelope(createdAt: days(1, before: now))
        try envelope.markSuperseded(by: "episode-2", now: days(0.5, before: now))
        let verdict = gate().decide(MemoryAdmissionCandidate(
            entry: entry(observedAt: days(1, before: now), temporal: envelope),
            provenance: .episode, sourceProject: host), at: now)
        XCTAssertEqual(verdict, .denied(.temporalIneligible, detail: "superseded"),
                       "an attached superseded envelope must win over a fresh event clock")
    }

    func testResearchEvidenceDecaysFasterThanHistoryAtTheSameAge() {
        // fast half-life 30d: at 150 days salience = 0.8 * 0.5^5 = 0.025 < 0.05 floor → denied.
        // medium half-life 90d: at 150 days salience = 0.8 * 0.5^1.67 ≈ 0.25 → admitted.
        let now = Date()
        let aged = entry(observedAt: days(150, before: now))
        let research = gate().decide(MemoryAdmissionCandidate(
            entry: aged, provenance: .researchEvidence, sourceProject: host), at: now)
        guard case .denied(.belowSalienceFloor, _) = research else {
            return XCTFail("150-day research evidence must decay past the floor (fast), got \(research)")
        }
        let history = gate().decide(MemoryAdmissionCandidate(
            entry: aged, provenance: .historyEvent, sourceProject: host), at: now)
        guard case .admitted = history else {
            return XCTFail("150-day history event must survive medium decay, got \(history)")
        }
    }

    func testSupplementalLessonWithoutAnyClockIsDeniedFailClosed() {
        let verdict = gate().decide(MemoryAdmissionCandidate(
            entry: entry(), provenance: .supplementalLesson, sourceProject: host), at: Date())
        guard case .denied(.unknownAge, _) = verdict else {
            return XCTFail("unknown-age supplemental data must not become current knowledge, got \(verdict)")
        }
    }

    func testHostProjectedLessonIsHostOnlyAndAnAttachedEnvelopeWins() throws {
        let now = Date()
        let foreign = gate().decide(MemoryAdmissionCandidate(
            entry: entry(), provenance: .hostProjectedLesson, sourceProject: other), at: now)
        guard case .denied(.outOfScope, _) = foreign else {
            return XCTFail("host-projected lessons must be host-project only, got \(foreign)")
        }
        let trusted = gate().decide(MemoryAdmissionCandidate(
            entry: entry(), provenance: .hostProjectedLesson, sourceProject: host), at: now)
        guard case .admitted(_, let note) = trusted, note.contains("upstream") else {
            return XCTFail("host lesson admission must be labeled upstream-projected, got \(trusted)")
        }
        var superseded = try MemoryTemporalEnvelope(createdAt: days(1, before: now))
        try superseded.markSuperseded(by: "newer", now: days(0.5, before: now))
        let contradicted = gate().decide(MemoryAdmissionCandidate(
            entry: entry(temporal: superseded), provenance: .hostProjectedLesson,
            sourceProject: host), at: now)
        XCTAssertEqual(contradicted, .denied(.temporalIneligible, detail: "superseded"),
                       "an attached ineligible envelope must override the upstream-projection contract")
    }

    func testOutOfScopeSourceProjectIsDeniedForEveryProvenanceClass() {
        let now = Date()
        for provenance in MemoryProvenanceClass.allCases {
            let verdict = gate().decide(MemoryAdmissionCandidate(
                entry: entry(observedAt: now), provenance: provenance,
                sourceProject: "/never/authorized"), at: now)
            guard case .denied(.outOfScope, _) = verdict else {
                return XCTFail("\(provenance.rawValue) from an unauthorized project must deny, got \(verdict)")
            }
        }
    }

    func testEmptyContentIsDeniedForEveryProvenanceClass() {
        let now = Date()
        for provenance in MemoryProvenanceClass.allCases {
            let verdict = gate().decide(MemoryAdmissionCandidate(
                entry: entry(text: "  \n "), provenance: provenance, sourceProject: host), at: now)
            guard case .denied(.emptyContent, _) = verdict else {
                return XCTFail("\(provenance.rawValue) with no content must deny, got \(verdict)")
            }
        }
    }

    func testUnrepresentableClockFailsClosedAsEvaluationFailure() {
        let verdict = gate().decide(MemoryAdmissionCandidate(
            entry: entry(observedAt: Date(timeIntervalSince1970: 3e17)),
            provenance: .historyEvent, sourceProject: host), at: Date())
        guard case .denied(.evaluationFailure, _) = verdict else {
            return XCTFail("an unrepresentable clock must fail closed, got \(verdict)")
        }
    }

    func testScreenPreservesOrderAndCountsDenialsByReason() {
        let now = Date()
        let screen = gate().screen([
            MemoryAdmissionCandidate(entry: entry("a", observedAt: now),
                                     provenance: .historyEvent, sourceProject: host),
            MemoryAdmissionCandidate(entry: entry("b"), provenance: .supplementalLesson,
                                     sourceProject: host),
            MemoryAdmissionCandidate(entry: entry("c"), provenance: .historyEvent,
                                     sourceProject: "/never/authorized"),
        ], at: now)
        XCTAssertEqual(screen.admitted.map(\.id), ["a"])
        XCTAssertEqual(screen.deniedCount, 2)
        XCTAssertEqual(screen.denialReasons, ["unknown_age": 1, "out_of_scope": 1])
        XCTAssertEqual(screen.decisions.map(\.candidateID), ["a", "b", "c"])
    }

    // MARK: - Audit log

    func testAuditRecordIsWrittenWithBoundedDenialSamples() throws {
        let now = Date()
        var candidates = [MemoryAdmissionCandidate(
            entry: entry("ok", observedAt: now), provenance: .historyEvent, sourceProject: host)]
        candidates += (0..<40).map { index in
            MemoryAdmissionCandidate(entry: entry("denied-\(index)"),
                                     provenance: .supplementalLesson, sourceProject: host)
        }
        let screen = gate().screen(candidates, at: now)
        XCTAssertNil(MemoryAdmissionAuditLog.record(screen: screen, query: "q",
                                                    hostRoot: root, at: now))
        let confined = try ConfinedRoot(root: root, readOnly: true)
        let records = try confined.entries(MemoryAdmissionAuditLog.directory).filter { !$0.isDir }
        XCTAssertEqual(records.count, 1)
        let data = try confined.readStableData(
            MemoryAdmissionAuditLog.directory + "/" + records[0].name, maxBytes: 64_000)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["admitted"] as? Int, 1)
        XCTAssertEqual(decoded["denied"] as? Int, 40)
        XCTAssertEqual((decoded["denialSamples"] as? [[String: Any]])?.count,
                       MemoryAdmissionAuditLog.maximumDenialSamples,
                       "denial samples must stay bounded")
        XCTAssertEqual(decoded["querySHA256"] as? String, BuilderEvidenceDigest.sha256("q"))
    }

    // MARK: - End-to-end pins: recall() enforces the gate at every source site

    private func identity(_ access: AgentMemoryAccess, run: String = "prior") -> AgentRunIdentity {
        AgentRunIdentity(runID: run, parentRunID: nil, rootRunID: run,
                         sessionID: access.sessionID, role: "researcher", project: access.project,
                         executionRoot: root)
    }

    func testRecallHistorySiteDeniesStaleEventsAndAdmitsFreshOnes() throws {
        // The history index pre-filters stale events when eligible (AgentHistoryIndex); the gate
        // is the authoritative second layer covering the index-unavailable raw fallback. This pin
        // holds the end-to-end behavior: stale absent, fresh admitted and counted.
        let access = try AgentMemoryAccess(projectRoot: root)
        let now = Date()
        try access.history.append(agent: identity(access), kind: "tool_finished",
                                  detail: "staleGateMarker result", at: now.addingTimeInterval(-86_400 * 3_000))
        try access.history.append(agent: identity(access), kind: "tool_finished",
                                  detail: "freshGateMarker result", at: now)
        let recall = try access.recall(query: "GateMarker", at: now)
        XCTAssertFalse(recall.entries.contains { $0.text.contains("staleGateMarker") },
                       "history site: stale event must not reach the model")
        XCTAssertTrue(recall.entries.contains { $0.text.contains("freshGateMarker") },
                      "history site: fresh event must pass the gate")
        XCTAssertGreaterThanOrEqual(recall.admittedCandidates, 1)
    }

    func testRecallCuratedSiteAdmitsProjectContextThroughGate() throws {
        try "curatedGateMarker: the deploy command is make ship".write(
            toFile: root + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let access = try AgentMemoryAccess(projectRoot: root)
        let recall = try access.recall(query: "curatedGateMarker deploy")
        XCTAssertTrue(recall.entries.contains { $0.id == "CLAUDE.md" },
                      "curated site: operator context must be admitted (supersession-governed)")
        XCTAssertGreaterThanOrEqual(recall.admittedCandidates, 1)
    }

    func testRecallEpisodeSiteFlowsThroughGate() throws {
        let now = Date()
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "episodeGateMarker rollout", success: true,
            summary: "shipped the gate", at: now.addingTimeInterval(-3_600)))
        let access = try AgentMemoryAccess(projectRoot: root)
        let recall = try access.recall(query: "episodeGateMarker", at: now)
        XCTAssertTrue(recall.entries.contains { $0.text.contains("episodeGateMarker") },
                      "episode site: a recent episode must be admitted through the gate")
    }

    func testRecallSupplementalSiteDeniesUnknownAgeAndAdmitsClockedLessons() throws {
        let now = Date()
        let access = try AgentMemoryAccess(projectRoot: root) { _, _, _ in
            [AgentMemoryEntry(id: "no-clock", title: "supplementalGateMarker mystery",
                              text: "supplementalGateMarker unknown-age claim", locator: "/x",
                              provenanceHint: .supplementalLesson),
             AgentMemoryEntry(id: "clocked", title: "supplementalGateMarker lesson",
                              text: "supplementalGateMarker verified recent lesson", locator: "/y",
                              observedAt: now.addingTimeInterval(-3_600),
                              provenanceHint: .supplementalLesson)]
        }
        let recall = try access.recall(query: "supplementalGateMarker", at: now)
        XCTAssertFalse(recall.entries.contains { $0.id == "no-clock" },
                       "supplemental site: unknown-age entries must deny fail-closed")
        XCTAssertTrue(recall.entries.contains { $0.id == "clocked" },
                      "supplemental site: clocked lessons must pass temporal governance")
        XCTAssertGreaterThanOrEqual(recall.denialReasons["unknown_age"] ?? 0, 1)
    }

    func testRecallRoutesProvenanceHintsToPerClassDecayEndToEnd() throws {
        let now = Date()
        // 150 days sits between the fast (30d) and medium (90d) half-life denial thresholds.
        let aged = now.addingTimeInterval(-86_400 * 150)
        let access = try AgentMemoryAccess(projectRoot: root) { _, _, _ in
            [AgentMemoryEntry(id: "old-research", title: "hintGateMarker fetch",
                              text: "hintGateMarker fetched claim", locator: "/r",
                              observedAt: aged, provenanceHint: .researchEvidence),
             AgentMemoryEntry(id: "old-lesson", title: "hintGateMarker lesson",
                              text: "hintGateMarker learned rule", locator: "/l",
                              observedAt: aged, provenanceHint: .supplementalLesson)]
        }
        let recall = try access.recall(query: "hintGateMarker", at: now)
        XCTAssertFalse(recall.entries.contains { $0.id == "old-research" },
                       "research hint must route to fast decay and deny at 150 days")
        XCTAssertTrue(recall.entries.contains { $0.id == "old-lesson" },
                      "lesson hint must route to medium decay and admit at 150 days")
        XCTAssertGreaterThanOrEqual(recall.denialReasons["below_salience_floor"] ?? 0, 1)
    }

    func testRecallWritesAuditRecordAndBootstrapDisclosesTheGate() throws {
        let access = try AgentMemoryAccess(projectRoot: root) { _, _, _ in
            [AgentMemoryEntry(id: "no-clock", title: "auditGateMarker", text: "auditGateMarker claim",
                              locator: "/x", provenanceHint: .supplementalLesson)]
        }
        _ = try access.recall(query: "auditGateMarker")
        let confined = try ConfinedRoot(root: root, readOnly: true)
        let records = try confined.entries(MemoryAdmissionAuditLog.directory).filter { !$0.isDir }
        XCTAssertGreaterThanOrEqual(records.count, 1, "every recall must leave an audit record")
        let bootstrap = try access.bootstrap(query: "auditGateMarker",
                                             agent: identity(access, run: "boot"))
        XCTAssertTrue(bootstrap.contains("Admission gate:"),
                      "the model-facing brief must disclose gate activity")
        XCTAssertTrue(bootstrap.contains("unknown_age"),
                      "denial reasons must be visible, not silent")
    }
}
