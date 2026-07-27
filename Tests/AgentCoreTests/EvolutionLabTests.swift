import XCTest
import Foundation
@testable import AgentCore

final class EvolutionLabTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evolution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testEvaluatorBlocksProtectedTrustSpineChanges() {
        let record = EvolutionEvaluator.evaluate(
            runID: "run",
            candidateID: "cand",
            parentID: nil,
            objective: "improve the planner",
            branch: "mythos/auto-evolve",
            worktreePath: "/wt",
            baseSHA: "base",
            commitSHA: "head",
            changedFiles: ["Sources/AgentCore/Foreman.swift", "Sources/AgentCore/PromptCompiler.swift"],
            benchmarks: [bench("swift test", 0)],
            policy: EvolutionPolicy(),
            createdAtEpoch: 1
        )

        XCTAssertEqual(record.status, .blocked)
        XCTAssertEqual(record.score, 0)
        XCTAssertEqual(record.protectedFiles, ["Sources/AgentCore/Foreman.swift"])
        XCTAssertTrue(record.summary.contains("protected"))
    }

    // Codex CRITICAL: a candidate must not be able to commit a .gitattributes (to suppress the test diff
    // and blind the integrity guard) — it's a protected file, so touching it BLOCKS the candidate outright.
    func testGitattributesAndConscienceFilesAreProtected() {
        let policy = EvolutionPolicy()
        XCTAssertFalse(policy.protectedFiles(in: [".gitattributes"]).isEmpty, "root .gitattributes protected")
        XCTAssertFalse(policy.protectedFiles(in: ["Tests/.gitattributes"]).isEmpty, "subdir .gitattributes protected")
        XCTAssertFalse(policy.protectedFiles(in: ["Sources/AgentCore/Fleet/CIIntegrityGuard.swift"]).isEmpty,
                       "the conscience itself is protected")
        let blocked = EvolutionEvaluator.evaluate(
            runID: "r", candidateID: "c", parentID: nil, objective: "hide the diff", branch: "b",
            worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: [".gitattributes", "Tests/AppTests/CoreTests.swift"],
            benchmarks: [bench("swift test", 0)], policy: policy, createdAtEpoch: 1)
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blocked.score, 0)
    }

    // THE CONSCIENCE ON EVOLUTION: a candidate whose benchmarks PASS but that gamed its own verifier
    // (per CIIntegrityGuard) must be BLOCKED, not scored as a win — self-evolution can't reward test-gaming.
    func testEvaluatorBlocksTestGamingEvenWhenBenchmarksPass() {
        let record = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "cheat", parentID: nil, objective: "go green the easy way",
            branch: "b", worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: ["Sources/AgentCore/PromptCompiler.swift", "Tests/AgentCoreTests/FooTests.swift"],
            benchmarks: [bench("swift test", 0)],   // benchmarks GREEN…
            policy: EvolutionPolicy(),
            integrityViolations: ["test_deleted: func testImportantInvariant()"],  // …but it deleted a test
            createdAtEpoch: 1)
        XCTAssertEqual(record.status, .blocked)
        XCTAssertEqual(record.score, 0)
        XCTAssertTrue(record.summary.contains("gamed the verifier"))
    }

    // End-to-end of the wiring: a real test-deleting diff → CIIntegrityGuard finds it → evaluator blocks.
    func testIntegrityGuardToEvaluatorWiringBlocksADeletedTest() {
        let diff = """
        diff --git a/Tests/AppTests/CoreTests.swift b/Tests/AppTests/CoreTests.swift
        --- a/Tests/AppTests/CoreTests.swift
        +++ b/Tests/AppTests/CoreTests.swift
        @@ -1,4 +1,2 @@
        -    func testCriticalPath() {
        -        XCTAssertTrue(invariantHolds())
        -    }
        """
        let violations = CIIntegrityGuard.inspect(committedFiles: ["Tests/AppTests/CoreTests.swift"],
                                                  committedDiff: diff).map { "\($0.kind): \($0.claim)" }
        XCTAssertFalse(violations.isEmpty, "guard must flag the deleted test")
        let record = EvolutionEvaluator.evaluate(
            runID: "r", candidateID: "c", parentID: nil, objective: "x", branch: "b",
            worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: ["Tests/AppTests/CoreTests.swift"], benchmarks: [bench("swift test", 0)],
            policy: EvolutionPolicy(), integrityViolations: violations, createdAtEpoch: 1)
        XCTAssertEqual(record.status, .blocked)
    }

    func testEvaluatorScoresPassingFailingAndNoChangeCandidates() {
        let policy = EvolutionPolicy()
        let passed = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "pass", parentID: nil, objective: "x",
            branch: "b", worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: ["Sources/AgentCore/PromptCompiler.swift"],
            benchmarks: [bench("swift test", 0), bench("./test.sh", 0)],
            policy: policy, createdAtEpoch: 1)
        let failed = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "fail", parentID: nil, objective: "x",
            branch: "b", worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: ["Sources/AgentCore/PromptCompiler.swift"],
            benchmarks: [bench("swift test", 1)],
            policy: policy, createdAtEpoch: 1)
        let noChange = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "none", parentID: nil, objective: "x",
            branch: "b", worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: [], benchmarks: [bench("swift test", 0)],
            policy: policy, createdAtEpoch: 1)

        XCTAssertEqual(passed.status, .passed)
        XCTAssertGreaterThan(passed.score, failed.score)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(noChange.status, .noChange)
    }

    func testEvaluatorRewardsCompactPassingDiffsOverSprawlingDiffs() {
        let compact = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "compact", parentID: nil, objective: "x",
            branch: "b", worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: ["Sources/AgentCore/PromptCompiler.swift"],
            benchmarks: [bench("swift test", 0)],
            policy: EvolutionPolicy(), createdAtEpoch: 1)
        let sprawling = EvolutionEvaluator.evaluate(
            runID: "run", candidateID: "sprawling", parentID: nil, objective: "x",
            branch: "b", worktreePath: "/wt", baseSHA: "base", commitSHA: "head",
            changedFiles: (1...30).map { "Sources/AgentCore/File\($0).swift" },
            benchmarks: [bench("swift test", 0)],
            policy: EvolutionPolicy(), createdAtEpoch: 1)

        XCTAssertEqual(compact.status, .passed)
        XCTAssertEqual(sprawling.status, .passed)
        XCTAssertGreaterThan(compact.score, sprawling.score)
    }

    func testArchiveAppendsLoadsAndRanksPassingCandidates() throws {
        let store = EvolutionArchiveStore(root: root.path)
        try store.append(record(id: "low", status: .passed, score: 110, epoch: 1))
        try store.append(record(id: "blocked", status: .blocked, score: 999, epoch: 2))
        try store.append(record(id: "high", status: .passed, score: 130, epoch: 3))

        XCTAssertEqual(store.records().map(\.candidateID), ["low", "blocked", "high"])
        XCTAssertEqual(store.topCandidates(limit: 2).map(\.candidateID), ["high", "low"])
        XCTAssertTrue(store.context(limit: 1).contains("high"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.archiveURL.path))
    }

    func testCandidatePromptCarriesDGMConstraintsAndProtectedFiles() {
        let prompt = EvolutionLab.candidatePrompt(
            objective: "make researchers cite sources",
            variantIndex: 1,
            variantCount: 3,
            archiveContext: "- old score=120",
            policy: EvolutionPolicy(requiredBenchmarkCommands: ["swift test"])
        )

        XCTAssertTrue(prompt.contains("EVOLUTION LAB CANDIDATE 1/3"))
        XCTAssertTrue(prompt.contains("DGM-style isolated candidate branch"))
        XCTAssertTrue(prompt.contains("Do not merge"))
        XCTAssertTrue(prompt.contains("Sources/AgentCore/ForgeSeal.swift"))
        XCTAssertTrue(prompt.contains("swift test"))
    }

    func testDefaultBenchmarkCommandsPreferTestShThenSwiftPackageThenDiffCheck() throws {
        let fm = FileManager.default
        try "".write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EvolutionBenchmarkRunner.defaultCommands(repoRoot: root.path), ["swift test"])

        try "#!/bin/sh\nexit 0\n".write(to: root.appendingPathComponent("test.sh"), atomically: true, encoding: .utf8)
        XCTAssertEqual(EvolutionBenchmarkRunner.defaultCommands(repoRoot: root.path), ["./test.sh"])

        try fm.removeItem(at: root.appendingPathComponent("test.sh"))
        try fm.removeItem(at: root.appendingPathComponent("Package.swift"))
        XCTAssertEqual(EvolutionBenchmarkRunner.defaultCommands(repoRoot: root.path), ["git diff --check"])
    }

    private func bench(_ command: String, _ exitCode: Int32) -> EvolutionBenchmarkResult {
        EvolutionBenchmarkResult(command: command, exitCode: exitCode, timedOut: false, output: "")
    }

    private func record(id: String, status: EvolutionCandidateStatus, score: Int, epoch: Double) -> EvolutionCandidateRecord {
        EvolutionCandidateRecord(
            runID: "run",
            candidateID: id,
            parentID: nil,
            objective: "objective",
            branch: "mythos/\(id)",
            worktreePath: "/wt/\(id)",
            baseSHA: "base",
            commitSHA: "head",
            status: status,
            score: score,
            changedFiles: ["Sources/AgentCore/PromptCompiler.swift"],
            protectedFiles: [],
            benchmarks: [bench("swift test", 0)],
            summary: "summary",
            createdAtEpoch: epoch
        )
    }
}
