import XCTest
@testable import AgentCore

/// Q3 context-recurrence reactivation: a memory that decayed below the retrieval floor returns
/// when the situation it belongs to recurs — and ONLY then. These tests pin the derivation of
/// situation signatures, the overlay store's decay math, the gate's reactivation branch and its
/// hard limits (no resurrection of superseded/unknown-age records), and the end-to-end path
/// through `AgentMemoryAccess.recall`.
final class MemoryReactivationTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "reactivation-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    // MARK: - Situation signatures

    func testSignaturesComeFromFailureDetailsAndExcludeGenericFailureVocabulary() {
        let context = MemoryRecurrenceContext.derive(failureDetails:
            ["Error: deployFrobnicate failed with E1234_TIMEOUT at stage rollback"])
        XCTAssertTrue(context.signatures.contains("deployfrobnicate"))
        XCTAssertTrue(context.signatures.contains("e1234_timeout"))
        XCTAssertTrue(context.signatures.contains("rollback"))
        XCTAssertFalse(context.signatures.contains("error"), "generic failure vocabulary is not identity")
        XCTAssertFalse(context.signatures.contains("failed"))
        XCTAssertFalse(context.signatures.contains("with"), "short tokens are not identity")
    }

    func testSignatureDerivationIsBounded() {
        let flood = (0..<200).map { "distinctSignalToken\($0) uniqueMarkerValue\($0)" }
        let context = MemoryRecurrenceContext.derive(failureDetails: flood)
        XCTAssertEqual(context.signatures.count, MemoryRecurrenceContext.maximumSignatures)
    }

    func testRecurrenceScoreMeasuresSituationOverlapNotQuerySimilarity() {
        let context = MemoryRecurrenceContext.derive(failureDetails:
            ["deployFrobnicate E1234_TIMEOUT stage rollback"])
        let strong = context.recurrenceScore(
            title: "Prior episode", text: "fixed deployFrobnicate after E1234_TIMEOUT recurred")
        XCTAssertGreaterThanOrEqual(strong, MemoryRecurrenceAdvisor.reactivationThreshold)
        let weak = context.recurrenceScore(title: "Prior episode", text: "updated the readme")
        XCTAssertEqual(weak, 0)
    }

    // MARK: - Overlay store

    func testOverlayBoostDecaysWithSevenDayHalfLifeAndIsLocatorScoped() throws {
        let now = Date()
        let store = MemoryReactivationStore(hostRoot: root)
        let context = MemoryRecurrenceContext.derive(failureDetails: ["frobnicate marker"])
        XCTAssertNil(store.record(locator: "/a/episodes.jsonl", context: context, query: "q", at: now))
        // The store caches its directory listing at init; re-open to observe the write.
        let reopened = MemoryReactivationStore(hostRoot: root)
        XCTAssertEqual(reopened.boost(locator: "/a/episodes.jsonl", at: now), 1.5, accuracy: 0.001)
        XCTAssertEqual(reopened.boost(locator: "/a/episodes.jsonl",
                                      at: now.addingTimeInterval(86_400 * 14)),
                       1.125, accuracy: 0.001, "boost must halve every seven days")
        XCTAssertEqual(reopened.boost(locator: "/other/file", at: now), 1,
                       "a reactivation must not boost unrelated locators")
    }

    func testOverlayBoostIsCappedAtTheSeasonalCeiling() throws {
        let now = Date()
        let context = MemoryRecurrenceContext.derive(failureDetails: ["frobnicate marker"])
        for _ in 0..<6 {
            XCTAssertNil(MemoryReactivationStore(hostRoot: root)
                .record(locator: "/a", context: context, query: "q", at: now))
        }
        let boost = MemoryReactivationStore(hostRoot: root).boost(locator: "/a", at: now)
        XCTAssertEqual(boost, MemoryReactivationStore.maximumBoost, accuracy: 0.001)
    }

    // MARK: - Gate reactivation branch and its hard limits

    private let host = "/host/project"

    private func gate() -> MemoryAdmissionGate {
        MemoryAdmissionGate(hostProject: host, authorizedProjects: [])
    }

    private func advisor(_ details: [String]) -> MemoryRecurrenceAdvisor {
        MemoryRecurrenceAdvisor(context: MemoryRecurrenceContext.derive(failureDetails: details),
                                store: MemoryReactivationStore(hostRoot: root))
    }

    private func dormantEntry(text: String, at now: Date) -> AgentMemoryEntry {
        // 400 days at medium decay: salience ≈ 0.8 * 0.5^4.44 ≈ 0.037 < 0.05 floor → dormant.
        AgentMemoryEntry(id: "dormant", title: "Prior episode", text: text, locator: "/x",
                         observedAt: now.addingTimeInterval(-86_400 * 400))
    }

    func testGateReactivatesDormantMemoryOnContextRecurrenceOnly() {
        let now = Date()
        let entry = dormantEntry(text: "deployFrobnicate broke with E1234_TIMEOUT", at: now)
        let candidate = MemoryAdmissionCandidate(entry: entry, provenance: .episode, sourceProject: host)
        let recurred = gate().screen([candidate], at: now,
                                     advisor: advisor(["deployFrobnicate E1234_TIMEOUT again"]))
        XCTAssertEqual(recurred.admitted.map(\.id), ["dormant"],
                       "a dormant memory must return when its situation recurs")
        XCTAssertEqual(recurred.reactivations.count, 1)
        let unrelated = gate().screen([candidate], at: now,
                                      advisor: advisor(["totally different subsystem crash"]))
        XCTAssertTrue(unrelated.admitted.isEmpty,
                      "without context recurrence the dormant memory stays below the floor")
        XCTAssertEqual(unrelated.reactivations.count, 0)
    }

    func testReactivationNeverResurrectsSupersededOrUnknownAgeMemory() throws {
        let now = Date()
        var superseded = try MemoryTemporalEnvelope(createdAt: now.addingTimeInterval(-86_400 * 400))
        try superseded.markSuperseded(by: "newer-record", now: now.addingTimeInterval(-86_400))
        let supersededVerdict = gate().decide(MemoryAdmissionCandidate(
            entry: AgentMemoryEntry(id: "s", title: "t", text: "deployFrobnicate E1234_TIMEOUT",
                                    locator: "/x", temporal: superseded),
            provenance: .episode, sourceProject: host), at: now,
            advisor: advisor(["deployFrobnicate E1234_TIMEOUT"]))
        XCTAssertEqual(supersededVerdict, .denied(.temporalIneligible, detail: "superseded"),
                       "reactivation lifts decay; it must never resurrect a superseded claim")
        let unknownAge = gate().decide(MemoryAdmissionCandidate(
            entry: AgentMemoryEntry(id: "u", title: "t", text: "deployFrobnicate E1234_TIMEOUT",
                                    locator: "/x"),
            provenance: .episode, sourceProject: host), at: now,
            advisor: advisor(["deployFrobnicate E1234_TIMEOUT"]))
        guard case .denied(.unknownAge, _) = unknownAge else {
            return XCTFail("recurrence must not launder unknown-age data, got \(unknownAge)")
        }
    }

    func testPriorReactivationSustainsRetrievabilityAndDecaysBack() throws {
        let now = Date()
        let entry = dormantEntry(text: "deployFrobnicate broke with E1234_TIMEOUT", at: now)
        let candidate = MemoryAdmissionCandidate(entry: entry, provenance: .episode, sourceProject: host)
        let context = MemoryRecurrenceContext.derive(failureDetails: ["unrelated later failure"])
        XCTAssertNil(MemoryReactivationStore(hostRoot: root).record(
            locator: entry.locator, context: context, query: "q", at: now))
        let sustained = gate().decide(candidate, at: now,
            advisor: MemoryRecurrenceAdvisor(context: context,
                                             store: MemoryReactivationStore(hostRoot: root)))
        guard case .admitted(_, let note) = sustained, note.contains("sustained") else {
            return XCTFail("a fresh overlay hit must sustain the memory (0.037 × 1.5 ≥ floor), got \(sustained)")
        }
        // A month later the overlay contribution has decayed ~16×; the memory sinks back.
        let later = now.addingTimeInterval(86_400 * 30)
        let faded = gate().decide(candidate, at: later,
            advisor: MemoryRecurrenceAdvisor(context: context,
                                             store: MemoryReactivationStore(hostRoot: root)))
        guard case .denied(.belowSalienceFloor, _) = faded else {
            return XCTFail("the overlay itself must forget: without fresh recurrence the memory sinks back, got \(faded)")
        }
    }

    // MARK: - End to end through recall()

    private func identity(_ access: AgentMemoryAccess, run: String = "prior") -> AgentRunIdentity {
        AgentRunIdentity(runID: run, parentRunID: nil, rootRunID: run,
                         sessionID: access.sessionID, role: "researcher", project: access.project,
                         executionRoot: root)
    }

    func testRecallReactivatesDormantEpisodeWhenFailureContextRecursDespiteUnrelatedQuery() throws {
        let now = Date()
        // A dormant episode: 400 days old, decayed far below the recall floor.
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "fix frobnicateDeploy pipeline", success: true,
            summary: "E1234_TIMEOUT was caused by the registry mirror; flushed mirror cache",
            at: now.addingTimeInterval(-86_400 * 400)))
        let access = try AgentMemoryAccess(projectRoot: root)
        // Sanity: without a recurring failure context the episode stays dormant.
        let quiet = try access.recall(query: "registry status", at: now)
        XCTAssertFalse(quiet.entries.contains { $0.text.contains("E1234_TIMEOUT") },
                       "without context recurrence the dormant episode must stay below the floor")
        // The situation recurs: a CURRENT failure carries the episode's signatures.
        try access.history.append(agent: identity(access), kind: "failed",
                                  detail: "frobnicateDeploy hit E1234_TIMEOUT again", at: now)
        let recall = try access.recall(query: "what changed in the docs lately", at: now)
        XCTAssertTrue(recall.entries.contains { $0.text.contains("E1234_TIMEOUT") },
                      "the dormant episode must return because the SITUATION recurred, not the query")
        XCTAssertEqual(recall.reactivatedCandidates, 1)
        // Reconsolidation left a durable overlay record.
        let confined = try ConfinedRoot(root: root, readOnly: true)
        let overlay = try confined.entries(MemoryReactivationStore.directory).filter { !$0.isDir }
        XCTAssertEqual(overlay.count, 1, "each fresh reactivation must write one overlay record")
        // And the boost now sustains the memory even after the failure context changes.
        let restoredEpisode = try XCTUnwrap(recall.entries.first {
            $0.locator == root + "/.mythos/memory/episodes.jsonl"
        })
        let sustained = MemoryReactivationStore(hostRoot: root).boost(restoredEpisode, at: now)
        XCTAssertEqual(sustained, 1.5, accuracy: 0.001)
    }

    func testRecallWithoutFailuresSkipsTheDormantPassEntirely() throws {
        let now = Date()
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "ancient work", success: true, summary: "old summary",
            at: now.addingTimeInterval(-86_400 * 400)))
        let access = try AgentMemoryAccess(projectRoot: root)
        let recall = try access.recall(query: "ancient work", at: now)
        XCTAssertEqual(recall.reactivatedCandidates, 0)
        XCTAssertFalse(recall.entries.contains { $0.text.contains("old summary") })
    }

    // MARK: - Codex review regression pins

    func testReactivationDoesNotOverrideExplicitOffSeasonSuppression() throws {
        // Codex P2: offSeasonFactor 0 evaluates eligible with zero salience; recurrence must not
        // readmit a memory its owner explicitly suppressed out of season.
        let now = Date()
        var components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: now)
        let outOfSeasonMonth = (components.month! % 12) + 1
        let window = try SeasonalMemoryWindow(months: [outOfSeasonMonth], offSeasonFactor: 0)
        let envelope = try MemoryTemporalEnvelope(
            createdAt: now.addingTimeInterval(-86_400 * 400), seasonalWindow: window)
        let entry = AgentMemoryEntry(id: "seasonal", title: "Prior episode",
                                     text: "deployFrobnicate broke with E1234_TIMEOUT",
                                     locator: "/x", temporal: envelope)
        let verdict = gate().decide(MemoryAdmissionCandidate(
            entry: entry, provenance: .episode, sourceProject: host), at: now,
            advisor: advisor(["deployFrobnicate E1234_TIMEOUT again"]))
        guard case .denied(.belowSalienceFloor, _) = verdict else {
            return XCTFail("explicit off-season suppression must beat reactivation, got \(verdict)")
        }
        _ = components
    }

    func testExplicitForeignProjectSearchDoesNotSurfaceHostDormantEpisodes() throws {
        // Codex P2: an explicit search of another authorized project must not return host
        // material through the dormant pass.
        let now = Date()
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "fix frobnicateDeploy pipeline", success: true,
            summary: "E1234_TIMEOUT registry mirror fix", at: now.addingTimeInterval(-86_400 * 400)))
        let foreign = root + "/foreign"
        try FileManager.default.createDirectory(atPath: foreign, withIntermediateDirectories: true)
        let access = try AgentMemoryAccess(projectRoot: root, authorizedReadRoots: [foreign])
        try access.history.append(agent: identity(access), kind: "failed",
                                  detail: "frobnicateDeploy hit E1234_TIMEOUT again", at: now)
        let recall = try access.recall(query: "anything at all", project: foreign, at: now)
        XCTAssertFalse(recall.entries.contains { $0.text.contains("E1234_TIMEOUT") },
                       "host dormant episodes must not leak into a foreign-project search")
        XCTAssertEqual(recall.reactivatedCandidates, 0)
    }

    func testLiveOverlaySustainsDormantMemoryAfterFailureContextAgesOut() throws {
        // Codex P2: once reactivated, a memory must stay retrievable through its overlay boost
        // even after the triggering failures age past the 7-day context window.
        let start = Date().addingTimeInterval(-86_400 * 8)
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "fix frobnicateDeploy pipeline", success: true,
            summary: "E1234_TIMEOUT registry mirror fix",
            at: start.addingTimeInterval(-86_400 * 380)))
        let access = try AgentMemoryAccess(projectRoot: root)
        // Two distinct matching failures → two overlay hits, enough boost to survive 8 days.
        try access.history.append(agent: identity(access), kind: "failed",
                                  detail: "frobnicateDeploy hit E1234_TIMEOUT in staging", at: start)
        try access.history.append(agent: identity(access), kind: "failed",
                                  detail: "frobnicateDeploy E1234_TIMEOUT again in prod",
                                  at: start.addingTimeInterval(60))
        let first = try access.recall(query: "unrelated docs question", at: start.addingTimeInterval(120))
        XCTAssertEqual(first.reactivatedCandidates, 1, "setup: the dormant episode must reactivate")
        // Eight days later the failures are outside the context window; only the overlay remains.
        let later = start.addingTimeInterval(86_400 * 8)
        let sustained = try access.recall(query: "unrelated docs question", at: later)
        XCTAssertTrue(sustained.entries.contains { $0.text.contains("E1234_TIMEOUT") },
                      "a live overlay must sustain the memory without fresh failure context")
        XCTAssertEqual(sustained.reactivatedCandidates, 0,
                       "sustained admission is not a new reactivation event")
    }
}
