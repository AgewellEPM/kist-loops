import XCTest
@testable import Kist

/// Regression pins for the self-heal dispatch defects seen in the wild:
///  A) specialist output printed twice (streamed live, then the summary reprinted),
///     which also dumped raw plan/chain-of-thought a second time;
///  B) the self-heal researcher ran a generic web survey instead of diagnosing the
///     actual failure, and marked its task "done" with no fix (it held `tasks`);
///  C) automatic repair half-ran in plan mode and died on "blocked by plan mode".
///
/// These are source-projection assertions (same style as the other Captain tests):
/// they pin the invariant on the REAL source so a future edit can't silently
/// reintroduce the behavior.
final class CaptainSelfHealDispatchTests: XCTestCase {
    private func repoRoot() -> String {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("Sources/Kist/KistRunner.swift").path
            if FileManager.default.fileExists(atPath: candidate) { return url.path }
            url.deleteLastPathComponent()
        }
        return FileManager.default.currentDirectoryPath
    }

    private func source(_ relative: String) throws -> String {
        // KistREPL helpers were split into KistREPL+*.swift modules — read the whole family.
        if relative == "Sources/Kist/KistREPL.swift" { return kistREPLFamilySource() }
        return try String(contentsOfFile: repoRoot() + "/" + relative, encoding: .utf8)
    }

    // A: no dispatch loop may reprint the specialist summary — it already streamed
    // live through the spawner's TerminalEventSink. The old bug was a trailing
    // `\u{001B}[0m\n\(summary)")` on the completion marker.
    func testSpecialistDispatchDoesNotReprintStreamedSummary() throws {
        let repl = try source("Sources/Kist/KistREPL.swift")
        XCTAssertFalse(repl.contains("[0m\\n\\(summary)\")"),
                       "specialist dispatch must not reprint the already-streamed summary (double-print / CoT leak)")
        XCTAssertTrue(repl.contains("already streamed live through the"),
                      "the dedup rationale comment must document why the summary is not reprinted")
    }

    // C: automatic self-heal must defer (not half-run) when the session is in plan
    // mode, and must NOT silently escalate to execute (privilege escalation).
    func testSelfHealDefersInPlanModeInsteadOfHalfRunning() throws {
        let repl = try source("Sources/Kist/KistREPL.swift")
        XCTAssertTrue(repl.contains("Captain self-heal deferred: plan mode is on"),
                      "automatic self-heal must defer with a clear message when plan mode is on")
        XCTAssertTrue(repl.contains("if automatic && perm.effectivePlan {"),
                      "the plan-mode defer guard must gate the automatic dispatch path")
    }

    // B: the researcher must diagnose THIS failure, not run a generic topic survey.
    func testSelfHealResearcherIsDiagnosticNotGenericSurvey() throws {
        let store = try source("Sources/Kist/UX/OrganizationalLearningStore.swift")
        XCTAssertTrue(store.contains("Diagnose THIS specific failure"),
                      "researcher task must be grounded in the concrete failure")
        XCTAssertTrue(store.contains("Work LOCAL-FIRST"),
                      "researcher must inspect local code before any web search")
        XCTAssertFalse(store.contains("Gather competitor, docs, source, and benchmark references."),
                       "the old generic-survey task must be gone")
    }

    // Clean handoff: the builder must receive the researcher's machine-readable spec, NOT the transcript,
    // and dispatch must HALT (not churn more research) if the researcher produced no actionable handoff.
    func testSelfHealBuilderGetsCleanHandoffNotTranscript() throws {
        let repl = try source("Sources/Kist/KistREPL.swift")
        XCTAssertTrue(repl.contains("researcherHandoff = SelfHealHandoff.parse(from: summary)"),
                      "dispatch must parse the researcher's handoff artifact")
        XCTAssertTrue(repl.contains("taskForAgent = h.builderBrief()"),
                      "the builder must receive ONLY the handoff spec, not the chained transcript")
        XCTAssertTrue(repl.contains("self-heal halted after research"),
                      "no actionable handoff must HALT the mission, not spawn more research")
    }

    // Reproduce-first: self-heal must PROVE the exact original failure before fixing, and RE-RUN that
    // same repro after — otherwise a "repair" can pass without proving it fixed the real failure.
    func testSelfHealReproducesFailureBeforeAndAfterFix() throws {
        let sh = try source("Sources/Kist/UX/OrganizationalLearningStore+SelfHeal.swift")
        XCTAssertTrue(sh.contains("REPRODUCE: Prove the original failure first"),
                      "self-heal must seed a reproduce-the-failure stage before the fix")
        XCTAssertTrue(sh.contains("reproduced BEFORE the fix"),
                      "the reproduce stage must capture the failure happening before any change")
        XCTAssertTrue(sh.contains("RE-RUN the SAME repro"),
                      "the fix stage must re-run the exact repro to prove the failure is gone")
    }

    // B: the researcher must not hold the `tasks` tool — that let it mark work
    // "done" with no fix and was its only mutation (→ the plan-mode block).
    func testSelfHealResearcherCannotTouchTaskBoard() throws {
        let store = try source("Sources/Kist/UX/OrganizationalLearningStore.swift")
        XCTAssertFalse(store.contains("\"web_search\", \"fetch_url\", \"tasks\"]"),
                       "self-heal-researcher toolAllowlist must not include the `tasks` board tool")
        XCTAssertTrue(store.contains("\"read_file\", \"search_code\", \"web_search\", \"fetch_url\"]"),
                      "self-heal-researcher keeps read/search/web tools, minus tasks")
    }
}
