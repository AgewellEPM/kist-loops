import XCTest
@testable import AgentCore

/// Pass 4: the last mile. The drafter refuses to write up anything unproven; the tracker is human-only and
/// re-checks scope at submit time; reputation compounds from recorded outcomes.
final class BountyReportingTests: XCTestCase {

    var roots: [String] = []
    override func tearDownWithError() throws {
        for r in roots { try? FileManager.default.removeItem(atPath: r) }
        roots = []
    }
    func tempRoot() -> String {
        let d = NSTemporaryDirectory() + "bounty-sub-" + UUID().uuidString
        roots.append(d); return d
    }

    func finding() -> SecurityFinding {
        SecurityFinding(severity: .high, category: .codeInjection, rule: "shell-true-py",
                        title: "subprocess with shell=True", file: "svc.py", line: 3,
                        evidence: "subprocess.run(cmd, shell=True)", recommendation: "Pass an argv list.",
                        owasp: "A03:2021 Injection")
    }
    func poc() -> ProofOfConcept {
        ProofOfConcept(findingId: finding().id, summary: "shell injection", method: .passiveRecon,
                       targetHost: nil, targetRepo: "acme/app", vulnClass: "injection",
                       reproSteps: "Re-scan svc.py; rule fires at line 3.", expectedSignal: "shell=True sink")
    }
    func reportReady() -> VerifiedBountyFinding {
        let panel = VerifiedFinding(finding: finding(), verdict: .confirmed, matchedTarget: "acme/app",
                                    refuteCount: 0, panelSize: 3, rationale: "survived panel")
        return VerifiedBountyFinding(finding: finding(), poc: poc(), panel: panel,
                                     repro: ReproResult(reproduced: true, observed: "re-detected at svc.py:3"),
                                     verdict: .reportReady)
    }
    func dropped() -> VerifiedBountyFinding {
        VerifiedBountyFinding(finding: finding(), poc: poc(), panel: nil, repro: nil,
                              verdict: .dropped(reason: "PoC did not reproduce"))
    }
    func engagement(repo: String = "acme/app") -> SecurityEngagement {
        SecurityEngagement(id: "acme", program: "HackerOne: Acme", attestedBy: "luke",
                           attestedAtISO: "2026-06-30T00:00:00Z",
                           targets: [SecurityTarget(kind: .repo, value: repo)],
                           safeHarbor: true, rulesURL: nil, testingLimits: [])
    }
    func rules() -> BountyProgramRules {
        BountyProgramRules(automation: .allowed, maxRequestsPerSecond: 5,
                           allowedVulnClasses: ["injection"], payoutTableUSD: ["high": 1500])
    }

    // MARK: drafter

    func testDrafterRefusesNonReportReadyFinding() {
        XCTAssertThrowsError(try ReportDrafter().draft(dropped(), program: rules(), programName: "HackerOne: Acme")) { err in
            guard case ReportDraftError.notReportReady = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func testDrafterProducesGroundedDisclosure() throws {
        let r = try ReportDrafter().draft(reportReady(), program: rules(), programName: "HackerOne: Acme")
        XCTAssertEqual(r.severity, .high)
        XCTAssertEqual(r.asset, "acme/app")
        XCTAssertEqual(r.vulnClass, "injection")
        XCTAssertEqual(r.estimatedPayoutUSD, 1500)
        let md = r.renderMarkdown()
        XCTAssertTrue(md.contains("## Steps to reproduce"))
        XCTAssertTrue(md.contains("## Proof of concept"))
        XCTAssertTrue(md.contains("re-detected at svc.py:3"))   // grounded in the real repro observation
        XCTAssertTrue(md.contains("$1500"))
    }

    // MARK: tracker — human-only, scope-rechecked, durable

    func testRecordSubmissionHappyPathPersists() throws {
        let tracker = SubmissionTracker(root: tempRoot())
        let report = try ReportDrafter().draft(reportReady(), program: rules(), programName: "HackerOne: Acme")
        let rec = try tracker.recordSubmission(report: report, verified: reportReady(), submittedBy: "luke",
                                               atISO: "2026-06-30T01:00:00Z", engagement: engagement(), rules: rules())
        XCTAssertEqual(rec.outcome, .submitted)
        XCTAssertEqual(rec.submittedBy, "luke")
        XCTAssertEqual(tracker.list(program: "HackerOne: Acme").count, 1)
    }

    func testRecordSubmissionRefusesEmptySubmitter() throws {
        let tracker = SubmissionTracker(root: tempRoot())
        let report = try ReportDrafter().draft(reportReady(), program: rules(), programName: "HackerOne: Acme")
        XCTAssertThrowsError(try tracker.recordSubmission(report: report, verified: reportReady(), submittedBy: "   ",
                                                          atISO: "t", engagement: engagement(), rules: rules())) { err in
            guard case SubmissionError.emptySubmitter = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func testRecordSubmissionRefusesOutOfScopeAssetAtSubmitTime() throws {
        let tracker = SubmissionTracker(root: tempRoot())
        let report = try ReportDrafter().draft(reportReady(), program: rules(), programName: "HackerOne: Acme")
        // Engagement that does NOT cover acme/app → the gate must refuse the submit action.
        XCTAssertThrowsError(try tracker.recordSubmission(report: report, verified: reportReady(), submittedBy: "luke",
                                                          atISO: "t", engagement: engagement(repo: "other/repo"), rules: rules())) { err in
            guard case SubmissionError.submissionRefused = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    func testRecordSubmissionRefusesUnprovenFinding() throws {
        let tracker = SubmissionTracker(root: tempRoot())
        let report = try ReportDrafter().draft(reportReady(), program: rules(), programName: "HackerOne: Acme")
        // pass a DROPPED verified finding alongside a (any) report → not report-ready ⇒ refused.
        XCTAssertThrowsError(try tracker.recordSubmission(report: report, verified: dropped(), submittedBy: "luke",
                                                          atISO: "t", engagement: engagement(), rules: rules())) { err in
            guard case SubmissionError.notReportReady = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    // MARK: outcomes + reputation compound

    func testUpdateOutcomeAndReputation() throws {
        let tracker = SubmissionTracker(root: tempRoot())
        let report = try ReportDrafter().draft(reportReady(), program: rules(), programName: "HackerOne: Acme")
        let rec = try tracker.recordSubmission(report: report, verified: reportReady(), submittedBy: "luke",
                                               atISO: "t", engagement: engagement(), rules: rules())
        let updated = try tracker.update(id: rec.id, outcome: .paid, payoutUSD: 1500, note: "triaged fast")
        XCTAssertEqual(updated.outcome, .paid)
        let rep = tracker.reputation(program: "HackerOne: Acme")
        XCTAssertEqual(rep.total, 1)
        XCTAssertEqual(rep.signal, 1)
        XCTAssertEqual(rep.paidUSD, 1500)
        XCTAssertEqual(rep.signalRatio, 1.0, accuracy: 0.001)
    }

    func testUpdateUnknownRecordThrows() {
        let tracker = SubmissionTracker(root: tempRoot())
        XCTAssertThrowsError(try tracker.update(id: "nope", outcome: .accepted))
    }
}
