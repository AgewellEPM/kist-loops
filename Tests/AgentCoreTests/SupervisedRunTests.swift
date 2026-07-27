import XCTest
import Foundation
@testable import AgentCore

/// END-TO-END proof the gavel BITES on a REAL run: isolate a worktree off a real repo, let an "agent"
/// leave a deliverable, commit it, and have the Foreman judge the REAL artifacts (committed `base...HEAD`
/// diff + the worktree's `test.sh` exit) and seal a forge-proof signoff — or block honestly. Real-git +
/// real `/bin/sh test.sh`; XCTSkip if `git` is absent (CI has it). No injected seams — the production
/// path runs.
final class SupervisedRunTests: XCTestCase {

    @discardableResult
    private func git(_ args: [String], cwd: URL) -> (Int32, String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = cwd
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return nil }
    }

    /// Create a base repo. `baseTestSh`, when set, commits a `test.sh` INTO THE BASE — so the agent's
    /// worktree branches from a repo that already has the (trusted, agent-unauthored) verifier script.
    private func makeRepo(baseTestSh: String? = nil) throws -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervised-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let (rc, _) = git(["init"], cwd: dir), rc == 0 else { return nil }
        _ = git(["config", "user.email", "t@t.test"], cwd: dir)
        _ = git(["config", "user.name", "Test"], cwd: dir)
        try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        if let sh = baseTestSh {
            try sh.write(to: dir.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        }
        _ = git(["add", "-A"], cwd: dir)
        guard let (crc, _) = git(["commit", "-m", "init"], cwd: dir), crc == 0 else { return nil }
        return dir
    }

    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()   // fresh per-test seal key, no disk write
    }

    private func writeFile(_ rel: String, _ body: String, in wt: GitWorktree) {
        let path = (wt.path as NSString).appendingPathComponent(rel)
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: green — real diff + passing test.sh ⇒ sealed signoff

    func testMeasuredGreenRunSealsSignoffAgainstRealGit() async throws {
        // The verifier script is TRUSTED (committed at base, agent-unauthored) — the agent only writes code.
        guard let repo = try makeRepo(baseTestSh: "#!/bin/sh\nexit 0\n") else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }

        let ledger = FleetSignoffLedger(baseDir: repo.appendingPathComponent(".fleet"))
        let foreman = Foreman(ledger: ledger, allowWorktreeHarness: true)   // REAL seams (committed diff, sandboxed test run, commit count)
        let agentID = UUID()

        let outcome = await SupervisedRun.run(
            repo: repo.path, goalID: "G", subjectID: agentID, title: "feature",
            nowEpoch: 1, foreman: foreman, keepWorktree: false) { wt in
                writeFile("Feature.swift", "let answer = 42\n", in: wt)
                return true
            }

        let report = try XCTUnwrap(outcome.report, "a worktree was created and inspected")
        XCTAssertTrue(outcome.committed, "the deliverable committed")
        XCTAssertEqual(report.verdict, .green, "real committed diff + passing test.sh ⇒ measured green")
        XCTAssertNotNil(report.signoff, "a real ForgeSeal-sealed signoff was minted")
        XCTAssertTrue(report.testExitCode == 0)
        XCTAssertTrue(ledger.signedOff(agentID: agentID), "the signoff persisted to the ledger")
        XCTAssertNil(ledger.verifyChain(), "the ledger chain is intact")
    }

    // MARK: blocked — a real failing test.sh is never green

    func testFailingTestShBlocksAgainstRealGit() async throws {
        // The FAILING verifier is TRUSTED (committed at base, agent-unauthored) so it actually RUNS and
        // its non-zero exit blocks — not vacuously blocked by a missing runner. The agent writes only code.
        guard let repo = try makeRepo(baseTestSh: "#!/bin/sh\nexit 1\n") else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }

        let ledger = FleetSignoffLedger(baseDir: repo.appendingPathComponent(".fleet"))
        let foreman = Foreman(ledger: ledger, allowWorktreeHarness: true)
        let agentID = UUID()

        let outcome = await SupervisedRun.run(
            repo: repo.path, goalID: "G", subjectID: agentID, title: "feature",
            nowEpoch: 1, foreman: foreman, keepWorktree: false) { wt in
                writeFile("Feature.swift", "let answer = 42\n", in: wt)   // code only; the base test.sh fails
                return true
            }

        let report = try XCTUnwrap(outcome.report)
        XCTAssertTrue(outcome.committed, "work committed, but the trusted test.sh exits 1")
        XCTAssertEqual(report.verdict, .blocked, "a real (trusted) failing test.sh can never be green")
        XCTAssertTrue(report.failedBlockers.contains("done_needs_tests"))
        XCTAssertNil(report.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: agentID), "no signoff for a failing run")
    }

    // MARK: blocked — a test that rewrites the committed snapshot (TOCTOU) can't seal a green

    func testTestShThatMutatesTrackedSourceIsBlockedAgainstRealGit() async throws {
        // The mutating verifier is TRUSTED (at base) — the forge being tested is a trusted test.sh that
        // rewrites tracked source after commit, not an agent-supplied command.
        guard let repo = try makeRepo(baseTestSh: "#!/bin/sh\necho 'let answer = 42' > Feature.swift\nexit 0\n")
        else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }

        let ledger = FleetSignoffLedger(baseDir: repo.appendingPathComponent(".fleet"))
        let foreman = Foreman(ledger: ledger, allowWorktreeHarness: true)   // REAL trackedDirty seam
        let agentID = UUID()

        let outcome = await SupervisedRun.run(
            repo: repo.path, goalID: "G", subjectID: agentID, title: "feature",
            nowEpoch: 1, foreman: foreman, keepWorktree: false) { wt in
                // The agent commits a broken version; the base test.sh rewrites it (uncommitted) then exits 0
                // — the classic forge: green attests bytes that will NOT merge.
                writeFile("Feature.swift", "let answer = 0  // committed (broken)\n", in: wt)
                return true
            }

        let report = try XCTUnwrap(outcome.report)
        XCTAssertEqual(report.verdict, .blocked, "a test that rewrote the committed snapshot is refused")
        XCTAssertTrue(report.failedBlockers.contains("tree_dirty_after_test"))
        XCTAssertNil(report.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: agentID),
                       "the green attested mutated bytes — no signoff")
    }

    // MARK: DEFAULT fail-closed — no operator oracle + no opt-in ⇒ an in-repo test.sh can NEVER verify

    func testDefaultRefusesInRepoHarnessEndToEndAgainstRealGit() async throws {
        // A base-trusted, PASSING test.sh — but the Foreman is at the SECURE DEFAULT (allowWorktreeHarness
        // false) and no operator oracle is set. The full realRunTests path must fail closed ⇒ no green, no
        // signoff (proves the resolver gate holds through the real run, not just the unit resolver).
        guard let repo = try makeRepo(baseTestSh: "#!/bin/sh\nexit 0\n") else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }

        let ledger = FleetSignoffLedger(baseDir: repo.appendingPathComponent(".fleet"))
        let foreman = Foreman(ledger: ledger)   // DEFAULT: in-repo tier OFF
        let agentID = UUID()

        let outcome = await SupervisedRun.run(
            repo: repo.path, goalID: "G", subjectID: agentID, title: "feature",
            nowEpoch: 1, foreman: foreman, keepWorktree: false) { wt in
                writeFile("Feature.swift", "let answer = 42\n", in: wt)
                return true
            }

        let report = try XCTUnwrap(outcome.report)
        XCTAssertEqual(report.verdict, .blocked, "default posture: an in-repo harness can NEVER mint a green")
        XCTAssertTrue(report.failedBlockers.contains("done_needs_tests"))
        XCTAssertNil(report.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: agentID), "no held-out oracle + no opt-in ⇒ no signoff")
    }

    // MARK: blocked — a no-op run has no deliverable

    func testNoChangeRunBlocksOnDiff() async throws {
        guard let repo = try makeRepo() else { throw XCTSkip("git not available") }
        defer { try? FileManager.default.removeItem(at: repo) }

        let ledger = FleetSignoffLedger(baseDir: repo.appendingPathComponent(".fleet"))
        let foreman = Foreman(ledger: ledger, allowWorktreeHarness: true)
        let agentID = UUID()

        let outcome = await SupervisedRun.run(
            repo: repo.path, goalID: "G", subjectID: agentID, title: "feature",
            nowEpoch: 1, foreman: foreman, keepWorktree: false) { _ in
                return true   // the agent claims success but left NOTHING
            }

        let report = try XCTUnwrap(outcome.report)
        XCTAssertFalse(outcome.committed, "nothing to commit")
        XCTAssertEqual(report.verdict, .blocked, "no committed change ⇒ not done")
        XCTAssertTrue(report.failedBlockers.contains("done_needs_diff"))
        XCTAssertNil(report.signoff)
        XCTAssertFalse(ledger.signedOff(agentID: agentID),
                       "the agent's advisory 'success' can NOT mint a signoff — only measured evidence can")
    }
}
