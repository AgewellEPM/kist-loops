import XCTest
import AgentCore
@testable import Kist

/// End-to-end smoke of the `/bug-bounty` REPL command path: ingest a spec → list → run the wizard, all
/// against isolated temp stores + a planted-vuln repo, with the deterministic panel (no model needed).
final class BountyConsoleTests: XCTestCase {

    var tmp: [String] = []
    override func tearDownWithError() throws { for p in tmp { try? FileManager.default.removeItem(atPath: p) }; tmp = [] }
    func tempDir() throws -> String {
        let d = NSTemporaryDirectory() + "bb-console-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        tmp.append(d); return d
    }
    func isolatedStores() throws -> BountyStores {
        BountyStores(engagements: try engStore(), rules: try rulesStore(), submissions: try subTracker())
    }
    func engStore() throws -> EngagementStore { EngagementStore(root: try tempDir()) }
    func rulesStore() throws -> BountyRulesStore { BountyRulesStore(root: try tempDir()) }
    func subTracker() throws -> SubmissionTracker { SubmissionTracker(root: try tempDir()) }

    func specJSON() -> Data {
        """
        {"id":"acme","program":"HackerOne: Acme","attestedBy":"luke","attestedAtISO":"2026-06-30T00:00:00Z",
         "targets":[{"kind":"repo","value":"acme/app"}],
         "automation":"allowed","maxRequestsPerSecond":5,"allowedVulnClasses":["injection"],
         "payoutTableUSD":{"high":1500}}
        """.data(using: .utf8)!
    }

    func testIngestThenListThenRunProducesReportReady() async throws {
        let stores = try isolatedStores()

        // write the spec + a vulnerable repo
        let specPath = try tempDir() + "/spec.json"
        try specJSON().write(to: URL(fileURLWithPath: specPath))
        let repo = try tempDir()
        try "import subprocess\ndef r(c):\n    subprocess.run(c, shell=True)\n".write(toFile: repo + "/svc.py", atomically: true, encoding: .utf8)

        // ingest
        let ing = await BountyConsole.handle("ingest \(specPath)", projectRoot: repo, complete: nil, stores: stores)
        XCTAssertTrue(ing.contains("ingested acme"), ing)

        // list
        let list = await BountyConsole.handle("list", projectRoot: repo, complete: nil, stores: stores)
        XCTAssertTrue(list.contains("acme"), list)

        // run — deterministic panel; high-severity shell-true reproduces ⇒ report-ready + a drafted report
        let run = await BountyConsole.handle("run acme \(repo)", projectRoot: repo, complete: nil, stores: stores)
        XCTAssertTrue(run.contains("report-ready"), run)
        XCTAssertTrue(run.contains("Report drafted") || run.contains("## Steps to reproduce"), "expected a draft in the run output")
        XCTAssertTrue(run.contains("[you]"), "the submit/draft step must be flagged as human")
    }

    func testRunUnknownProgramIsHandled() async throws {
        let out = await BountyConsole.handle("run ghost", projectRoot: try tempDir(), complete: nil, stores: try isolatedStores())
        XCTAssertTrue(out.contains("no ingested program"))
    }

    func testHelpListsSubcommands() async {
        let out = await BountyConsole.handle("", projectRoot: ".", complete: nil)
        XCTAssertTrue(out.contains("ingest"))
        XCTAssertTrue(out.contains("run"))
    }
}

private extension BountyStores {
    init(engagements: EngagementStore, rules: BountyRulesStore, submissions: SubmissionTracker) {
        self.init()
        self.engagements = engagements
        self.rules = rules
        self.submissions = submissions
    }
}
