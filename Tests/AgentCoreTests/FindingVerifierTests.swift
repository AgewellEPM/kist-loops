import XCTest
@testable import AgentCore

final class FindingVerifierTests: XCTestCase {

    /// Deterministic skeptic: refutes iff its verdict says so. No LLM, no flakiness.
    private struct Stub: FindingRefuter {
        let refuted: Bool
        let reason: String
        init(_ refuted: Bool, _ reason: String = "stub") { self.refuted = refuted; self.reason = reason }
        func refute(_ finding: SecurityFinding) async -> RefuteVote { RefuteVote(refuted: refuted, reason: reason) }
    }

    private func finding(_ rule: String = "aws-access-key") -> SecurityFinding {
        SecurityFinding(severity: .high, category: .secret, rule: rule, title: "Hardcoded key",
                        file: "src/app.swift", line: 12, evidence: "let k = \"redacted\"",
                        recommendation: "rotate + use a secret store")
    }

    private func eng(repos: [String], attestedBy: String = "luke") -> SecurityEngagement {
        SecurityEngagement(id: "e", program: "P", attestedBy: attestedBy, attestedAtISO: "2026-06-29T00:00:00Z",
                           targets: repos.map { SecurityTarget(kind: .repo, value: $0) },
                           safeHarbor: true, rulesURL: nil, testingLimits: [])
    }

    func testOutOfScopeRepoDropsEveryFinding() async {
        let v = await FindingVerifier.verify(findings: [finding()], engagement: eng(repos: ["acme/web"]),
                                             auditRepo: "someoneelse/secret", panel: [Stub(false)])
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].verdict, .outOfScope)
        XCTAssertFalse(v[0].isReportReady)
        XCTAssertNil(v[0].matchedTarget)
    }

    func testUnauthorizedEngagementDropsEverything() async {
        let v = await FindingVerifier.verify(findings: [finding()], engagement: eng(repos: ["acme/web"], attestedBy: " "),
                                             auditRepo: "acme/web", panel: [Stub(false)])
        XCTAssertEqual(v[0].verdict, .outOfScope)   // no attestation ⇒ fail-closed even on a listed repo
    }

    func testInScopeSurvivesWhenPanelMinorityRefutes() async {
        // 1 of 3 refute → strict minority → confirmed.
        let v = await FindingVerifier.verify(findings: [finding()], engagement: eng(repos: ["acme/web"]),
                                             auditRepo: "acme/web", panel: [Stub(true), Stub(false), Stub(false)])
        XCTAssertEqual(v[0].verdict, .confirmed)
        XCTAssertTrue(v[0].isReportReady)
        XCTAssertEqual(v[0].matchedTarget, "acme/web")
        XCTAssertEqual(v[0].refuteCount, 1)
        XCTAssertEqual(v[0].panelSize, 3)
    }

    func testMajorityRefuteDropsFinding() async {
        let v = await FindingVerifier.verify(findings: [finding()], engagement: eng(repos: ["acme/web"]),
                                             auditRepo: "acme/web",
                                             panel: [Stub(true, "false positive"), Stub(true, "unreachable"), Stub(false)])
        XCTAssertEqual(v[0].verdict, .refuted)
        XCTAssertFalse(v[0].isReportReady)
        XCTAssertTrue(v[0].rationale.contains("false positive") || v[0].rationale.contains("unreachable"))
    }

    func testTieIsRefutedNotConfirmed() async {
        // 1 of 2 refute → NOT strict minority (1*2 == 2) → refuted. Ties fail closed.
        let v = await FindingVerifier.verify(findings: [finding()], engagement: eng(repos: ["acme/web"]),
                                             auditRepo: "acme/web", panel: [Stub(true), Stub(false)])
        XCTAssertEqual(v[0].verdict, .refuted)
    }

    func testEmptyPanelIsUnverifiedNotConfirmed() async {
        let v = await FindingVerifier.verify(findings: [finding()], engagement: eng(repos: ["acme/web"]),
                                             auditRepo: "acme/web", panel: [])
        XCTAssertEqual(v[0].verdict, .unverified)
        XCTAssertFalse(v[0].isReportReady)   // no verification ⇒ never auto-promoted
        XCTAssertEqual(v[0].matchedTarget, "acme/web")
    }

    func testRepoCaseInsensitiveScopeMatch() async {
        let v = await FindingVerifier.verify(findings: [finding()], engagement: eng(repos: ["Acme/Web"]),
                                             auditRepo: "acme/web", panel: [Stub(false)])
        XCTAssertEqual(v[0].verdict, .confirmed)
    }

    func testMultipleFindingsVerifiedIndependently() async {
        let fs = [finding("rule-a"), finding("rule-b")]
        let v = await FindingVerifier.verify(findings: fs, engagement: eng(repos: ["acme/web"]),
                                             auditRepo: "acme/web", panel: [Stub(false)])
        XCTAssertEqual(v.count, 2)
        XCTAssertTrue(v.allSatisfy { $0.verdict == .confirmed })
    }
}
