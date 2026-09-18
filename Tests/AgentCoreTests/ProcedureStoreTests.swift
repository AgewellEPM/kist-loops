import XCTest
@testable import AgentCore

/// Q5 unified typed schema: the procedure type (reinforced how-to) and the working-state leak
/// guard. Pins the four per-type policies at the store and gate, and the end-to-end recall
/// lane including dormant-procedure reactivation on situation recurrence.
final class ProcedureStoreTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "procedures-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        root = try XCTUnwrap(ToolContext.canonicalize(root))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(atPath: root) }

    private var store: ProcedureStore { ProcedureStore(projectRoot: root) }

    // MARK: - Store semantics

    func testDepositRequiresProvenSourceAndRejectsDuplicates() {
        let now = Date()
        let unproven = store.deposit(title: "Roll back a deploy", task: "deploy rollback",
                                     steps: "run x then y", source: "  ", at: now)
        XCTAssertNil(unproven.procedure, "an unproven how-to is a guess, not memory")
        XCTAssertNotNil(unproven.issue)
        let first = store.deposit(title: "Roll back a deploy", task: "deploy rollback",
                                  steps: "run x then y", source: "signoff:run-42", at: now)
        XCTAssertNotNil(first.procedure)
        XCTAssertNil(first.issue)
        let duplicate = store.deposit(title: "Roll back a deploy", task: "deploy rollback",
                                      steps: "different steps", source: "signoff:run-43", at: now)
        XCTAssertNil(duplicate.procedure)
        XCTAssertTrue(duplicate.issue?.contains("reinforce") == true,
                      "updates are reinforcement or supersession, never silent overwrite")
    }

    func testVerifiedReinforcementGrowsPersistenceAcrossDisuse() throws {
        let now = Date()
        let created = now.addingTimeInterval(-86_400 * 2_000)
        let deposited = try XCTUnwrap(store.deposit(
            title: "Flush the registry mirror", task: "registry mirror timeout",
            steps: "purge cache then restart mirror", source: "signoff:run-7", at: created).procedure)
        // 2000 days of disuse at slow decay: far below the retrieval floor.
        XCTAssertLessThan(deposited.temporal.evaluate(at: now).salience,
                          MemoryTemporalEnvelope.confidenceFloor)
        let reinforcedAt = now.addingTimeInterval(-86_400 * 100)
        let reinforced = try XCTUnwrap(store.reinforce(
            id: deposited.id, verifiedSource: "signoff:run-88", at: reinforcedAt).procedure)
        XCTAssertEqual(reinforced.version, 2)
        XCTAssertEqual(reinforced.temporal.reinforcementCount, 1)
        XCTAssertGreaterThanOrEqual(reinforced.temporal.evaluate(at: now).salience,
                                    MemoryTemporalEnvelope.confidenceFloor,
                                    "verified reuse must restore persistence (anchor moves to confirmation)")
        // Both versions remain on disk: the reinforcement history is an audit trail.
        let confined = try ConfinedRoot(root: root, readOnly: true)
        XCTAssertEqual(try confined.entries(ProcedureStore.directory).count, 2)
        XCTAssertEqual(store.latest(id: deposited.id)?.version, 2)
    }

    func testSupersededProcedureIsRefusedByStoreAndGateEvenOnRecurrence() throws {
        let now = Date()
        let old = try XCTUnwrap(store.deposit(
            title: "Old mirror fix", task: "registry mirror timeout",
            steps: "obsolete approach", source: "signoff:run-1",
            at: now.addingTimeInterval(-3_600)).procedure)
        XCTAssertNil(store.supersede(id: old.id, by: "better-procedure", at: now).issue)
        XCTAssertTrue(store.retrieve(applicability: "registry mirror timeout", at: now).isEmpty,
                      "a superseded procedure must not be retrievable")
        XCTAssertNotNil(store.reinforce(id: old.id, verifiedSource: "signoff:run-2",
                                        at: now.addingTimeInterval(60)).issue,
                        "reinforcing a superseded procedure must refuse")
        let superseded = try XCTUnwrap(store.latest(id: old.id))
        let gate = MemoryAdmissionGate(hostProject: "/host", authorizedProjects: [])
        let advisor = MemoryRecurrenceAdvisor(
            context: MemoryRecurrenceContext.derive(failureDetails: ["registry mirror timeout obsolete approach"]),
            store: MemoryReactivationStore(hostRoot: root))
        let verdict = gate.decide(MemoryAdmissionCandidate(
            entry: AgentMemoryEntry(id: "p", title: superseded.title, text: superseded.steps,
                                    locator: "/x", temporal: superseded.temporal),
            provenance: .procedure, sourceProject: "/host"), at: now, advisor: advisor)
        XCTAssertEqual(verdict, .denied(.temporalIneligible, detail: "superseded"),
                       "recurrence must never resurrect a superseded procedure")
    }

    func testRetrieveRanksByTaskApplicability() throws {
        let now = Date()
        _ = store.deposit(title: "Flush registry mirror", task: "registry mirror timeout",
                          steps: "purge then restart", source: "s:1", at: now)
        _ = store.deposit(title: "Rotate signing keys", task: "expired signing certificate",
                          steps: "generate then swap", source: "s:2", at: now)
        let hits = store.retrieve(applicability: "registry mirror timeout", at: now)
        XCTAssertEqual(hits.first?.title, "Flush registry mirror")
        XCTAssertFalse(hits.contains { $0.title == "Rotate signing keys" })
    }

    func testTamperedAndConflictingRecordsAreIgnoredNotTrusted() throws {
        let now = Date()
        let real = try XCTUnwrap(store.deposit(
            title: "Real procedure", task: "real task", steps: "real steps",
            source: "s:1", at: now).procedure)
        // A hand-planted higher version with a forged identity must not shadow the real record.
        let confined = try ConfinedRoot(root: root)
        _ = try confined.createDataIfMissing(
            ProcedureStore.directory + "/\(real.id)-v000002.json",
            Data("{\"forged\":true}".utf8), createParents: true)
        XCTAssertEqual(store.latest(id: real.id)?.version, 1,
                       "an undecodable planted version must be ignored")
        // And publishing over the occupied version name surfaces a conflict, never a replace.
        let conflicted = store.reinforce(id: real.id, verifiedSource: "s:2",
                                         at: now.addingTimeInterval(60))
        XCTAssertNil(conflicted.procedure)
        XCTAssertTrue(conflicted.issue?.contains("conflict") == true)
    }

    // MARK: - Typed schema pins

    func testRecordTypeMappingCoversEveryProvenanceClass() {
        let expected: [MemoryProvenanceClass: MemoryRecordType] = [
            .curatedFact: .fact,
            .historyEvent: .episode, .episode: .episode, .researchEvidence: .episode,
            .supplementalLesson: .procedure, .hostProjectedLesson: .procedure, .procedure: .procedure,
            .workingState: .workingState,
        ]
        for provenance in MemoryProvenanceClass.allCases {
            XCTAssertEqual(provenance.recordType, expected[provenance],
                           "\(provenance.rawValue) must map to a declared Q5 type")
        }
    }

    func testWorkingStateIsDeniedUnconditionally() {
        // Even fresh, host-scoped, envelope-carrying, recurrence-matched working state must
        // never enter durable recall.
        let now = Date()
        let gate = MemoryAdmissionGate(hostProject: "/host", authorizedProjects: [])
        let advisor = MemoryRecurrenceAdvisor(
            context: MemoryRecurrenceContext.derive(failureDetails: ["scratch variable tracker"]),
            store: MemoryReactivationStore(hostRoot: root))
        let verdict = gate.decide(MemoryAdmissionCandidate(
            entry: AgentMemoryEntry(id: "w", title: "scratch", text: "scratch variable tracker",
                                    locator: "/x", observedAt: now),
            provenance: .workingState, sourceProject: "/host"), at: now, advisor: advisor)
        guard case .denied(.workingStateLeak, _) = verdict else {
            return XCTFail("working state must never become durable recall, got \(verdict)")
        }
    }

    // MARK: - End to end through recall()

    private func identity(_ access: AgentMemoryAccess) -> AgentRunIdentity {
        AgentRunIdentity(runID: "prior", parentRunID: nil, rootRunID: "prior",
                         sessionID: access.sessionID, role: "researcher", project: access.project,
                         executionRoot: root)
    }

    func testRecallRetrievesFreshProcedureByApplicability() throws {
        let now = Date()
        _ = store.deposit(title: "Flush registry mirror", task: "registry mirror timeout",
                          steps: "purge cache then restart mirror", source: "s:1",
                          at: now.addingTimeInterval(-3_600))
        let access = try AgentMemoryAccess(projectRoot: root)
        let recall = try access.recall(query: "registry mirror timeout", at: now)
        XCTAssertTrue(recall.entries.contains { $0.title.hasPrefix("Procedure:") },
                      "a fresh procedure must be retrievable by task applicability")
        XCTAssertEqual(recall.reactivatedCandidates, 0)
    }

    func testRecallReactivatesDormantProcedureWhenItsSituationRecurs() throws {
        let now = Date()
        _ = store.deposit(title: "Flush registry mirror", task: "frobnicateDeploy E1234_TIMEOUT",
                          steps: "purge cache then restart mirror", source: "s:1",
                          at: now.addingTimeInterval(-86_400 * 2_000))
        let access = try AgentMemoryAccess(projectRoot: root)
        try access.history.append(agent: identity(access), kind: "failed",
                                  detail: "frobnicateDeploy hit E1234_TIMEOUT again", at: now)
        let recall = try access.recall(query: "unrelated documentation question", at: now)
        XCTAssertTrue(recall.entries.contains { $0.title.hasPrefix("Procedure:") },
                      "a dormant how-to must return when the failure it fixes recurs")
        XCTAssertEqual(recall.reactivatedCandidates, 1)
    }
}
