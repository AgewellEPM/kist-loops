import XCTest
@testable import AgentCore

/// Pass 3 recon + the real source reproducer, and the end-to-end proof that Pass 1 (gate) + Pass 3 (recon)
/// + Pass 2 (verify spine) compose: a planted, in-scope, in-class vuln becomes report-ready only after it
/// is deterministically reproduced; everything else is refused, filtered, or dropped.
final class BountyReconPipelineTests: XCTestCase {

    var repos: [String] = []
    override func tearDownWithError() throws {
        for r in repos { try? FileManager.default.removeItem(atPath: r) }
        repos = []
    }

    /// Write files into a fresh temp dir; returns its path.
    func makeRepo(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "bounty-recon-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, body) in files {
            try body.write(toFile: dir + "/" + name, atomically: true, encoding: .utf8)
        }
        repos.append(dir)
        return dir
    }

    /// A python file whose line 3 fires the deterministic `shell-true-py` rule (category codeInjection).
    let vulnPy = "import subprocess\ndef run(cmd):\n    subprocess.run(cmd, shell=True)\n"

    func engagement() -> SecurityEngagement {
        SecurityEngagement(
            id: "acme", program: "HackerOne: Acme", attestedBy: "luke",
            attestedAtISO: "2026-06-30T00:00:00Z",
            targets: [SecurityTarget(kind: .repo, value: "acme/app")],
            safeHarbor: true, rulesURL: nil, testingLimits: [])
    }
    func rules(classes: Set<String> = ["injection"], automation: AutomationPolicy = .allowed) -> BountyProgramRules {
        BountyProgramRules(automation: automation, maxRequestsPerSecond: 5, allowedVulnClasses: classes)
    }

    // MARK: recon authorization

    func testReconRefusedWhenRepoOutOfScope() throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let outcome = ReconPipeline().run(target: ReconTarget(repo: "someone/else", root: root),
                                          engagement: engagement(), rules: rules())
        guard case .refused(_, let rule) = outcome else { return XCTFail("expected refusal") }
        XCTAssertEqual(rule, "scope.repo-out-of-scope")
    }

    func testReconRefusedWhenAutomationBanned() throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let outcome = ReconPipeline().run(target: ReconTarget(repo: "acme/app", root: root),
                                          engagement: engagement(), rules: rules(automation: .banned))
        guard case .refused(_, let rule) = outcome else { return XCTFail("expected refusal") }
        XCTAssertEqual(rule, "automation.banned")
    }

    // MARK: recon findings + class filter

    func testReconSurfacesInClassCandidate() throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let outcome = ReconPipeline().run(target: ReconTarget(repo: "acme/app", root: root),
                                          engagement: engagement(), rules: rules(classes: ["injection"]))
        guard case .completed(let report) = outcome else { return XCTFail("expected completed") }
        XCTAssertEqual(report.candidates.count, 1)
        let c = report.candidates[0]
        XCTAssertEqual(c.finding.rule, "shell-true-py")
        XCTAssertEqual(c.pocDraft.findingId, c.finding.id)
        XCTAssertEqual(c.pocDraft.vulnClass, "injection")
    }

    func testReconDropsOutOfClassFindings() throws {
        let root = try makeRepo(["svc.py": vulnPy])
        // program only accepts "secret" → the injection finding is dropped, no candidate emitted.
        let outcome = ReconPipeline().run(target: ReconTarget(repo: "acme/app", root: root),
                                          engagement: engagement(), rules: rules(classes: ["secret"]))
        guard case .completed(let report) = outcome else { return XCTFail("expected completed") }
        XCTAssertEqual(report.candidates.count, 0)
        XCTAssertGreaterThanOrEqual(report.droppedOutOfClass, 1)
    }

    // MARK: the real reproducer

    func testSourceRescanReproducesPlantedFinding() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let report = SecurityAuditor.audit(root: root)
        let f = try XCTUnwrap(report.findings.first { $0.rule == "shell-true-py" })
        let repro = SourceRescanReproducer(root: root, findings: report.findings)
        let poc = ReconPipeline.draftPoC(for: f, repo: "acme/app", vulnClass: "injection")
        let r = await repro.reproduce(poc)
        XCTAssertTrue(r.reproduced, r.observed)
    }

    // REGRESSION (panel review, defense-in-depth #7): a finding whose file escapes the scan root via ../
    // must be refused, never read through.
    func testSourceRescanRefusesPathTraversal() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let evil = SecurityFinding(severity: .high, category: .codeInjection, rule: "x", title: "x",
                                   file: "../../../../../../etc/passwd", line: 1, evidence: "x", recommendation: "x")
        let repro = SourceRescanReproducer(root: root, findings: [evil])
        let poc = ProofOfConcept(findingId: evil.id, summary: "x", vulnClass: "injection", reproSteps: "-", expectedSignal: "-")
        let r = await repro.reproduce(poc)
        XCTAssertFalse(r.reproduced)
        XCTAssertTrue(r.observed.contains("escapes"))
    }

    func testSourceRescanFailsClosedOnUnknownPoC() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let repro = SourceRescanReproducer(root: root, findings: [])   // knows no findings
        let poc = ProofOfConcept(findingId: "ghost:rule:x.py:1", summary: "?", vulnClass: "injection",
                                 reproSteps: "-", expectedSignal: "-")
        let r = await repro.reproduce(poc)
        XCTAssertFalse(r.reproduced)
    }

    // MARK: END-TO-END — recon → verify spine → report-ready

    func testReconThroughVerifySpineToReportReady() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        // Pass 3: recon
        guard case .completed(let report) = ReconPipeline().run(
            target: ReconTarget(repo: "acme/app", root: root), engagement: engagement(), rules: rules())
        else { return XCTFail("recon should complete") }
        let candidate = try XCTUnwrap(report.candidates.first)

        // Pass 2: verify with the REAL source reproducer + a confirming skeptic panel
        let reproducer = SourceRescanReproducer(root: root, findings: report.candidates.map(\.finding))
        let verifier = BountyFindingVerifier(gate: BountyGate(), reproducer: reproducer)
        struct OK: FindingRefuter { func refute(_ f: SecurityFinding) async -> RefuteVote { RefuteVote(refuted: false, reason: "ok") } }
        let v = await verifier.verify(finding: candidate.finding, poc: candidate.pocDraft,
                                      engagement: engagement(), rules: rules(), auditRepo: "acme/app",
                                      panel: [OK(), OK(), OK()])
        XCTAssertTrue(v.isReportReady, "planted, in-scope, reproduced finding should be report-ready: \(v.verdict.dropReason ?? "")")
        XCTAssertEqual(v.repro?.reproduced, true)
    }

    // Same pipeline, but the finding is fixed before verify → PoC can't reproduce → dropped.
    func testFixedVulnIsDroppedByVerifySpine() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        guard case .completed(let report) = ReconPipeline().run(
            target: ReconTarget(repo: "acme/app", root: root), engagement: engagement(), rules: rules())
        else { return XCTFail("recon should complete") }
        let candidate = try XCTUnwrap(report.candidates.first)

        // "fix" the file so a re-scan no longer fires the rule
        try "import subprocess\ndef run(cmd):\n    subprocess.run([cmd])\n".write(toFile: root + "/svc.py", atomically: true, encoding: .utf8)

        let reproducer = SourceRescanReproducer(root: root, findings: report.candidates.map(\.finding))
        let verifier = BountyFindingVerifier(gate: BountyGate(), reproducer: reproducer)
        struct OK: FindingRefuter { func refute(_ f: SecurityFinding) async -> RefuteVote { RefuteVote(refuted: false, reason: "ok") } }
        let v = await verifier.verify(finding: candidate.finding, poc: candidate.pocDraft,
                                      engagement: engagement(), rules: rules(), auditRepo: "acme/app",
                                      panel: [OK(), OK(), OK()])
        XCTAssertFalse(v.isReportReady)
        XCTAssertTrue(v.verdict.dropReason?.contains("did not reproduce") == true)
    }
}
