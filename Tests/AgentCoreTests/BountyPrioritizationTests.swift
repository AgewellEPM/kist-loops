import XCTest
@testable import AgentCore

/// Pass 5: dedup-risk + prioritization. Duplicates sink, novel/severe/well-paying float up — deterministic
/// and explainable, and it never drops anything (triage, not a gate).
final class BountyPrioritizationTests: XCTestCase {

    func finding(_ severity: SecurityFinding.Severity, _ category: SecurityFinding.Category,
                 rule: String, file: String, line: Int = 1) -> SecurityFinding {
        SecurityFinding(severity: severity, category: category, rule: rule, title: rule,
                        file: file, line: line, evidence: "x", recommendation: "fix")
    }
    func submission(of f: SecurityFinding) -> SubmissionRecord {
        SubmissionRecord(id: f.id, program: "P", findingId: f.id, title: f.title,
                         submittedBy: "luke", submittedAtISO: "t", outcome: .submitted, payoutUSD: nil, note: "")
    }
    func rules() -> BountyProgramRules {
        BountyProgramRules(automation: .allowed, maxRequestsPerSecond: 5,
                           allowedVulnClasses: ["injection", "crypto"],
                           payoutTableUSD: ["critical": 5000, "high": 1500, "low": 50])
    }

    // MARK: dedup risk

    func testExactPriorSubmissionIsHighDedupRisk() {
        let f = finding(.high, .codeInjection, rule: "shell-true-py", file: "svc.py")
        let s = DedupRiskScorer(priorSubmissions: [submission(of: f)]).score(finding: f)
        XCTAssertGreaterThanOrEqual(s.risk, 0.9)
    }

    func testSameRuleSameFileDifferentLineIsLikelyDuplicate() {
        let filed = finding(.high, .codeInjection, rule: "shell-true-py", file: "svc.py", line: 3)
        let other = finding(.high, .codeInjection, rule: "shell-true-py", file: "svc.py", line: 40)
        let s = DedupRiskScorer(priorSubmissions: [submission(of: filed)]).score(finding: other)
        XCTAssertGreaterThanOrEqual(s.risk, 0.7)
    }

    func testNovelHighSeverityHasLowDedupRisk() {
        let f = finding(.high, .codeInjection, rule: "shell-true-py", file: "new.py")
        let s = DedupRiskScorer().score(finding: f)
        XCTAssertLessThan(s.risk, 0.4)
    }

    func testCommonLowSeverityRuleHasHighDedupRisk() {
        let f = finding(.low, .crypto, rule: "weak-hash-md5", file: "util.py")
        let s = DedupRiskScorer().score(finding: f)
        XCTAssertGreaterThan(s.risk, 0.6)   // low sev + very-common rule
    }

    // MARK: prioritization ordering

    func testNovelSevereRanksAboveCommonLow() {
        let severe = finding(.critical, .codeInjection, rule: "eval-use", file: "a.py")
        let common = finding(.low, .crypto, rule: "weak-hash-md5", file: "b.py")
        let ranked = FindingPrioritizer().rank([common, severe], program: rules())
        XCTAssertEqual(ranked.first?.finding.id, severe.id)
        XCTAssertEqual(ranked.last?.finding.id, common.id)
    }

    func testAlreadySubmittedSinksToBottom() {
        let filed = finding(.high, .codeInjection, rule: "shell-true-py", file: "svc.py")
        let fresh = finding(.medium, .codeInjection, rule: "os-system", file: "cmd.py")
        let ranked = FindingPrioritizer(priorSubmissions: [submission(of: filed)]).rank([filed, fresh], program: rules())
        // Even though `filed` is higher severity, its ~0.95 dedup risk should push it below the novel medium.
        XCTAssertEqual(ranked.first?.finding.id, fresh.id)
        XCTAssertEqual(ranked.last?.finding.id, filed.id)
        XCTAssertGreaterThanOrEqual(ranked.last!.dedup.risk, 0.9)
    }

    func testNothingIsDropped() {
        let fs = [finding(.low, .config, rule: "ats-arbitrary-loads", file: "Info.plist"),
                  finding(.high, .codeInjection, rule: "eval-use", file: "a.py")]
        XCTAssertEqual(FindingPrioritizer().rank(fs, program: rules()).count, 2)
    }

    func testRationaleIsExplainable() {
        let f = finding(.high, .codeInjection, rule: "eval-use", file: "a.py")
        let r = FindingPrioritizer().rank([f], program: rules()).first!
        XCTAssertTrue(r.rationale.contains("novelty"))
        XCTAssertTrue(r.rationale.contains("severity"))
        XCTAssertTrue(r.rationale.contains("priority"))
    }
}
