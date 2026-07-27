import XCTest
@testable import AgentCore

/// The verify spine is the moat: a finding reaches `.reportReady` ONLY when it is authorized to reproduce,
/// survives the adversarial panel, AND actually reproduces. Each test kills exactly one of those and proves
/// the finding is DROPPED — plus the happy path proves a real, proven finding still gets through.
final class BountyFindingVerifierTests: XCTestCase {

    // deterministic stubs
    struct StubRefuter: FindingRefuter {
        let willRefute: Bool
        func refute(_ f: SecurityFinding) async -> RefuteVote { RefuteVote(refuted: willRefute, reason: "stub") }
    }
    struct StubReproducer: PoCReproducer {
        let ok: Bool
        func reproduce(_ p: ProofOfConcept) async -> ReproResult {
            ReproResult(reproduced: ok, observed: ok ? "expected signal observed" : "no signal")
        }
    }

    func engagement() -> SecurityEngagement {
        SecurityEngagement(
            id: "acme", program: "HackerOne: Acme", attestedBy: "luke",
            attestedAtISO: "2026-06-30T00:00:00Z",
            targets: [SecurityTarget(kind: .domain, value: "example.com"),
                      SecurityTarget(kind: .repo, value: "acme/app")],
            safeHarbor: true, rulesURL: nil, testingLimits: [])
    }
    func rules(automation: AutomationPolicy = .allowed) -> BountyProgramRules {
        BountyProgramRules(automation: automation, maxRequestsPerSecond: 5, allowedVulnClasses: ["xss"])
    }
    func finding() -> SecurityFinding {
        SecurityFinding(severity: .high, category: .codeInjection, rule: "xss-reflect",
                        title: "Reflected XSS", file: "app.js", line: 10,
                        evidence: "res.send(req.query.q)", recommendation: "encode output", owasp: "A03:2021")
    }
    func poc(host: String = "api.example.com", vulnClass: String = "xss", rps: Double? = 1) -> ProofOfConcept {
        ProofOfConcept(findingId: finding().id, summary: "reflect a script", method: .exploitPoC,
                       targetHost: host, targetRepo: nil, vulnClass: vulnClass, requestsPerSecond: rps,
                       reproSteps: "GET /?q=<script>…", expectedSignal: "unescaped reflection")
    }

    func confirmingPanel() -> [FindingRefuter] { [StubRefuter(willRefute: false), StubRefuter(willRefute: false), StubRefuter(willRefute: false)] }
    func refutingPanel() -> [FindingRefuter] { [StubRefuter(willRefute: true), StubRefuter(willRefute: true), StubRefuter(willRefute: false)] }

    func verifier(reproduces: Bool) -> BountyFindingVerifier {
        BountyFindingVerifier(gate: BountyGate(), reproducer: StubReproducer(ok: reproduces))
    }

    // MARK: happy path — authorized + confirmed + reproduced ⇒ report-ready

    func testAuthorizedConfirmedReproducedIsReportReady() async {
        let v = await verifier(reproduces: true).verify(
            finding: finding(), poc: poc(), engagement: engagement(), rules: rules(),
            auditRepo: "acme/app", panel: confirmingPanel())
        XCTAssertTrue(v.isReportReady, "expected report-ready, got: \(v.verdict.dropReason ?? "?")")
    }

    // MARK: each gate, killed individually

    func testNoPoCDropped() async {
        let v = await verifier(reproduces: true).verify(
            finding: finding(), poc: nil, engagement: engagement(), rules: rules(),
            auditRepo: "acme/app", panel: confirmingPanel())
        XCTAssertFalse(v.isReportReady)
        XCTAssertTrue(v.verdict.dropReason?.contains("no proof-of-concept") == true)
    }

    func testOutOfScopeHostNotAuthorizedToReproduce() async {
        let v = await verifier(reproduces: true).verify(
            finding: finding(), poc: poc(host: "evil.com"), engagement: engagement(), rules: rules(),
            auditRepo: "acme/app", panel: confirmingPanel())
        XCTAssertFalse(v.isReportReady)
        XCTAssertTrue(v.verdict.dropReason?.contains("not authorized to reproduce") == true)
        XCTAssertNil(v.repro, "must not attempt reproduction on an out-of-scope host")
    }

    func testAutomationBannedNotAuthorizedToReproduce() async {
        let v = await verifier(reproduces: true).verify(
            finding: finding(), poc: poc(), engagement: engagement(), rules: rules(automation: .banned),
            auditRepo: "acme/app", panel: confirmingPanel())
        XCTAssertFalse(v.isReportReady)
        XCTAssertTrue(v.verdict.dropReason?.contains("automation.banned") == true)
    }

    func testWrongVulnClassNotAuthorizedToReproduce() async {
        let v = await verifier(reproduces: true).verify(
            finding: finding(), poc: poc(vulnClass: "rce"), engagement: engagement(), rules: rules(),
            auditRepo: "acme/app", panel: confirmingPanel())
        XCTAssertFalse(v.isReportReady)
        XCTAssertTrue(v.verdict.dropReason?.contains("vulnclass.not-accepted") == true)
    }

    func testRefutedByPanelDropped() async {
        let v = await verifier(reproduces: true).verify(
            finding: finding(), poc: poc(), engagement: engagement(), rules: rules(),
            auditRepo: "acme/app", panel: refutingPanel())
        XCTAssertFalse(v.isReportReady)
        XCTAssertTrue(v.verdict.dropReason?.contains("adversarial panel") == true)
        XCTAssertNil(v.repro, "must not reproduce a finding the panel already refuted")
    }

    // THE moat case: panel confirms, but the PoC does NOT reproduce ⇒ dropped as a false positive.
    func testConfirmedButNotReproducedIsDroppedAsFalsePositive() async {
        let v = await verifier(reproduces: false).verify(
            finding: finding(), poc: poc(), engagement: engagement(), rules: rules(),
            auditRepo: "acme/app", panel: confirmingPanel())
        XCTAssertFalse(v.isReportReady, "a non-reproducing PoC must NEVER be report-ready, even if the panel confirmed")
        XCTAssertTrue(v.verdict.dropReason?.contains("did not reproduce") == true)
    }

    // MARK: batch filter returns only the proven ones

    func testReportReadyBatchReturnsOnlyProven() async {
        let good: (SecurityFinding, ProofOfConcept?) = (finding(), poc())
        let unproven: (SecurityFinding, ProofOfConcept?) = (finding(), nil)
        let ready = await verifier(reproduces: true).reportReady(
            from: [good, unproven], engagement: engagement(), rules: rules(),
            auditRepo: "acme/app", panel: confirmingPanel())
        XCTAssertEqual(ready.count, 1)
        XCTAssertTrue(ready.allSatisfy { $0.isReportReady })
    }
}
