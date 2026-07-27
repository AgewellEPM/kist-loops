import XCTest
@testable import AgentCore

/// The guided wizard (beginner mode) ties passes 1–5 together, teaches at every stage, and NEVER submits.
final class BountyWizardTests: XCTestCase {

    var repos: [String] = []
    override func tearDownWithError() throws { for r in repos { try? FileManager.default.removeItem(atPath: r) }; repos = [] }
    func makeRepo(_ files: [String: String]) throws -> String {
        let dir = NSTemporaryDirectory() + "bounty-wiz-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (n, b) in files { try b.write(toFile: dir + "/" + n, atomically: true, encoding: .utf8) }
        repos.append(dir); return dir
    }
    let vulnPy = "import subprocess\ndef run(cmd):\n    subprocess.run(cmd, shell=True)\n"

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
    struct OK: FindingRefuter { func refute(_ f: SecurityFinding) async -> RefuteVote { RefuteVote(refuted: false, reason: "ok") } }
    struct NO: FindingRefuter { func refute(_ f: SecurityFinding) async -> RefuteVote { RefuteVote(refuted: true, reason: "nope") } }

    func testFullWizardRunProducesDraftAndNeverAutoSubmits() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let out = await BountyWizard().run(target: ReconTarget(repo: "acme/app", root: root),
                                           engagement: engagement(), rules: rules(),
                                           panel: [OK(), OK(), OK()])
        XCTAssertNil(out.refusedReason)
        XCTAssertGreaterThanOrEqual(out.reportReadyCount, 1)
        XCTAssertNotNil(out.topDraft, "a reproduced, in-scope finding should be drafted")
        // every stage teaches
        XCTAssertTrue(out.steps.allSatisfy { !$0.teaching.isEmpty })
        // there is a submit step, and it REQUIRES a human — the wizard never files anything itself
        let submit = out.steps.first { $0.stage == "submit" }
        XCTAssertEqual(submit?.needsHuman, true)
        XCTAssertTrue((submit?.teaching ?? "").lowercased().contains("you submit") || (submit?.title ?? "").lowercased().contains("you submit"))
    }

    func testWizardStagesAreInOrder() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let out = await BountyWizard().run(target: ReconTarget(repo: "acme/app", root: root),
                                           engagement: engagement(), rules: rules(), panel: [OK(), OK(), OK()])
        let stages = out.steps.map(\.stage)
        XCTAssertEqual(Array(stages.prefix(5)), ["welcome", "program", "recon", "verify", "prioritize"])
        XCTAssertTrue(stages.contains("coach"))
    }

    func testOutOfScopeReconRefusedAndNoDraft() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let out = await BountyWizard().run(target: ReconTarget(repo: "someone/else", root: root),
                                           engagement: engagement(), rules: rules(), panel: [OK(), OK(), OK()])
        XCTAssertNotNil(out.refusedReason)
        XCTAssertNil(out.topDraft)
        XCTAssertEqual(out.reportReadyCount, 0)
        XCTAssertEqual(out.steps.last?.stage, "recon")   // stops at the refusal
    }

    func testNothingReproduciblyReportedWhenPanelRefutes() async throws {
        let root = try makeRepo(["svc.py": vulnPy])
        let out = await BountyWizard().run(target: ReconTarget(repo: "acme/app", root: root),
                                           engagement: engagement(), rules: rules(), panel: [NO(), NO(), NO()])
        XCTAssertEqual(out.reportReadyCount, 0)
        XCTAssertNil(out.topDraft)
        // still coaches — the "nothing to report, and that's the point" lesson
        XCTAssertTrue(out.steps.contains { $0.stage == "draft" && $0.title.contains("Nothing to report") })
    }

    func testTeachIntroMentionsProveAndInScope() {
        let t = BountyWizard.teach().lowercased()
        XCTAssertTrue(t.contains("prove"))
        XCTAssertTrue(t.contains("scope"))
    }
}
