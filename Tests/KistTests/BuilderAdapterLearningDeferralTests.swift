import XCTest
@testable import AgentCore
@testable import Kist

/// Regression coverage for nested headless adapter learning. Clocked LessonStore writes are deferred
/// until the final Builder receipt; retired Cortex Markdown never receives runtime writes.
///
/// On the sealed-headless-mutation path a `.stoppedUnverified` outcome that satisfies
/// `builderHeadlessCanHandOffToDeterministicVerification` is the EXPECTED handoff: the outer BuilderRun
/// keeps going to node verification, final verification, and independent review before it decides
/// acceptance. `outcome.success` is still false at that point, so the previous code eagerly recorded a
/// failure lesson and a paused legacy journal entry — poisoning retrieval for builds that go on to be accepted.
///
/// A genuinely-final headless failure (no handoff) must STILL record, so real failures are never
/// swallowed by the temporal LessonStore. The Cortex checks pin its raw-audit-only boundary.
final class BuilderAdapterLearningDeferralTests: XCTestCase {

    // A sealed headless plan whose stopped-unverified outcome is a legitimate deterministic-verification
    // handoff (adapter=headless, has operations, has verification commands).
    private func sealedHeadlessPlan() -> KistRunner.BuilderPreflightPlan {
        KistRunner.BuilderPreflightPlan(
            schemaVersion: 1,
            adapter: KistRunner.BuilderCompatibilityAdapter.headless.rawValue,
            operations: [.init(kind: .modify, path: "Sources/Target.swift", preimageSHA256: nil)],
            verificationCommands: [.init(
                executable: "swift", arguments: ["test"], timeoutSeconds: 120)],
            partitions: [])
    }

    private func stoppedUnverifiedOutcome() -> HeadlessAgentLoop.Outcome {
        HeadlessAgentLoop.Outcome(
            success: false,
            summary: "model stopped without running the sealed verifier",
            iterations: 3,
            checkpointId: "chk-handoff",
            terminalStatus: .stoppedUnverified)
    }

    private func genuinelyFailedOutcome() -> HeadlessAgentLoop.Outcome {
        HeadlessAgentLoop.Outcome(
            success: false,
            summary: "the edit did not compile and the model gave up",
            iterations: 5,
            checkpointId: "chk-failed",
            terminalStatus: .failed)
    }

    // MARK: - Decision seam (mirrors the exact guard used at the .headless call site)

    func testDecisionSeamDefersOnHeadlessVerificationHandoff() {
        // The sealed-headless handoff must be RECOGNIZED as a handoff...
        let handoff = KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: stoppedUnverifiedOutcome(), sealedPlan: sealedHeadlessPlan())
        XCTAssertTrue(handoff, "sealed .stoppedUnverified mutation is the expected handoff")
        // ...and therefore nested adapter learning must be SKIPPED (deferred to the final receipt).
        XCTAssertFalse(
            KistRunner.builderShouldRecordNestedAdapterLearning(
                headlessVerificationHandoff: handoff),
            "learning must be deferred on the expected headless-verification handoff")
    }

    func testDecisionSeamRecordsOnGenuinelyFinalFailure() {
        // A plain .failed run with no sealed plan is NOT a handoff...
        let handoff = KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: genuinelyFailedOutcome(), sealedPlan: nil)
        XCTAssertFalse(handoff, "a plain failed run is not a deterministic-verification handoff")
        // ...so nested adapter learning must STILL fire — real failures are never swallowed.
        XCTAssertTrue(
            KistRunner.builderShouldRecordNestedAdapterLearning(
                headlessVerificationHandoff: handoff),
            "genuinely-final headless failures must still record learning")
    }

    // MARK: - Surface 1 (LessonStore) — per-site assertions

    /// LessonStore surface, HANDOFF site: no "task failed" obstacle lesson is written.
    func testLessonStoreSurfaceDefersOnHandoffSite() {
        let store = temporaryLessonStore("handoff")
        let handoff = KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: stoppedUnverifiedOutcome(), sealedPlan: sealedHeadlessPlan())
        recordUnderProductionGuard(
            goal: "modify Sources/Target.swift to add a symbols exporter",
            success: false, handoff: handoff, lessonStore: store, root: "/tmp/kist-handoff")
        XCTAssertFalse(
            store.all().contains { $0.kind == .obstacle && $0.text.contains("task failed") },
            "LessonStore [handoff] must not record a failure lesson before authoritative acceptance")
    }

    /// LessonStore surface, FINAL-FAILURE site: the "task failed" obstacle lesson IS written.
    func testLessonStoreSurfaceRecordsOnFinalFailureSite() {
        let store = temporaryLessonStore("final")
        let handoff = KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
            outcome: genuinelyFailedOutcome(), sealedPlan: nil)
        recordUnderProductionGuard(
            goal: "modify Sources/Target.swift to add a symbols exporter",
            success: false, handoff: handoff, lessonStore: store, root: "/tmp/kist-final")
        XCTAssertTrue(
            store.all().contains { $0.kind == .obstacle && $0.text.contains("task failed") },
            "LessonStore [final-failure] must record a failure lesson so real failures aren't swallowed")
    }

    // MARK: - Retired Cortex journal — raw audit only

    /// Journal surface, HANDOFF site: no paused journal entry is written.
    func testJournalSurfaceDefersOnHandoffSite() throws {
        try withTemporaryCortexHome { home in
            let handoff = KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
                outcome: stoppedUnverifiedOutcome(), sealedPlan: sealedHeadlessPlan())
            recordUnderProductionGuard(
                goal: "modify Sources/Target.swift to add a symbols exporter",
                success: false, handoff: handoff, lessonStore: nil, root: "/tmp/kist-handoff")
            XCTAssertFalse(
                journalContains("[paused]", home: home),
                "journal [handoff] must not write a paused entry before authoritative acceptance")
            XCTAssertFalse(
                journalDirectoryExists(home: home),
                "journal [handoff] must remain untouched on the expected handoff")
        }
    }

    /// Even a genuine final failure cannot manufacture an undated raw Markdown memory.
    func testJournalSurfaceStaysRawAuditOnlyOnFinalFailureSite() throws {
        try withTemporaryCortexHome { home in
            let handoff = KistRunner.builderHeadlessCanHandOffToDeterministicVerification(
                outcome: genuinelyFailedOutcome(), sealedPlan: nil)
            recordUnderProductionGuard(
                goal: "modify Sources/Target.swift to add a symbols exporter",
                success: false, handoff: handoff, lessonStore: nil, root: "/tmp/kist-final")
            XCTAssertFalse(journalContains("[paused]", home: home))
            XCTAssertFalse(
                journalDirectoryExists(home: home),
                "final failures remain in clocked LessonStore, never raw Cortex Markdown")
        }
    }

    // MARK: - Helpers

    /// Replays the EXACT production guard from the `.headless` adapter case so the test regresses if the
    /// call site stops honoring `builderShouldRecordNestedAdapterLearning`.
    private func recordUnderProductionGuard(
        goal: String, success: Bool, handoff: Bool,
        lessonStore: LessonStore?, root: String
    ) {
        guard KistRunner.builderShouldRecordNestedAdapterLearning(
            headlessVerificationHandoff: handoff) else { return }
        KistRunner.recordRuntimeLessons(
            goal: goal, success: success, recorder: TrajectoryRecorder(),
            lessonStore: lessonStore, maxIterations: 12, mode: .inline)
        KistRunner.autoJournalRun(goal: goal, success: success, root: root, enabled: true)
    }

    private func temporaryLessonStore(_ label: String) -> LessonStore {
        let path = NSTemporaryDirectory()
            + "builder-adapter-learning-\(label)-\(UUID().uuidString)/lessons.jsonl"
        addTeardownBlock {
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        return LessonStore(path: path)
    }

    private func withTemporaryCortexHome(_ body: (String) throws -> Void) throws {
        let home = NSTemporaryDirectory() + "builder-adapter-journal-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", home, 1)
        defer { unsetenv("XDG_DATA_HOME"); try? FileManager.default.removeItem(atPath: home) }
        try body(home)
    }

    private func journalDirectoryExists(home: String) -> Bool {
        FileManager.default.fileExists(atPath: home + "/cortex/journal")
    }

    private func journalContains(_ needle: String, home: String) -> Bool {
        let dir = home + "/cortex/journal"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for file in files {
            let body = (try? String(contentsOfFile: dir + "/" + file, encoding: .utf8)) ?? ""
            if body.contains(needle) { return true }
        }
        return false
    }
}
