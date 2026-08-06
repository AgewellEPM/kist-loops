import XCTest
import Foundation
import AgentCore
@testable import Kist

/// `/fix` = the Captain drives the build and refuses to accept analysis as done. These tests pin the
/// two things the wiring must guarantee: (1) the done-gate is deterministic and artifact-grounded, and
/// (2) it enforces Luke's NO-MONOLITHS rule with a REAL per-file line count — the exact gap the mapping
/// workflow flagged as the top risk (a naive judge faked maxFileLines=0 so the monolith gate never fired).
final class CaptainFixTests: XCTestCase {

    // MARK: - Decider: always builds, escalates when the Captain forces it

    func testDeciderAlwaysBuildsAndEscalatesWhenForced() async {
        let d = FixBuildDecider()
        let plain = await d.propose(objective: "make X", history: [], forcedAction: false)
        guard case .build(let s1) = plain else { return XCTFail("must propose a build") }
        XCTAssertEqual(s1, "make X")

        let forced = await d.propose(objective: "make X", history: [], forcedAction: true)
        guard case .build(let s2) = forced else { return XCTFail("forced must still be a build") }
        XCTAssertTrue(s2.contains("BUILD IT NOW"), "a forced retry must escalate: \(s2)")
        XCTAssertTrue(s2.contains("make X"))
    }

    // MARK: - fileLineCount

    func testFileLineCount() throws {
        let p = NSTemporaryDirectory() + "flc-\(UUID().uuidString).txt"
        try "a\nb\nc".write(toFile: p, atomically: true, encoding: .utf8)   // 3 lines, no trailing newline
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertEqual(KistREPL.fileLineCount(p), 3)
        XCTAssertEqual(KistREPL.fileLineCount("/no/such/file"), 0)
    }

    // MARK: - Judge: cheap guards (no working tree needed)

    func testJudgeRejectsAnalysisOnly() {
        let judge = KistREPL.makeFixJudge(projectRoot: NSTemporaryDirectory())
        // No artifact-producing move => not done, whatever the model did.
        if case .done = judge("obj", []) { XCTFail("empty history is not done") }
        let analyzed = [MoveOutcome(success: true, producedArtifact: false, summary: "analyzed")]
        if case .done = judge("obj", analyzed) { XCTFail("analysis-only is not done") }
        // A failed last move is not done even if an earlier move produced an artifact.
        let brokeAfter = [MoveOutcome(success: true, producedArtifact: true, summary: "built"),
                          MoveOutcome(success: false, producedArtifact: false, summary: "broke")]
        if case .done = judge("obj", brokeAfter) { XCTFail("a trailing failure is not done") }
    }

    // MARK: - Judge: the NO-MONOLITHS gate on REAL changed bytes (needs a git repo)

    func testJudgeBlocksAMonolithButAcceptsASmallVerifiedChange() throws {
        let bigRepo = try makeGitRepo(withFile: "Big.swift", lines: 1600)
        defer { try? FileManager.default.removeItem(atPath: bigRepo) }
        let smallRepo = try makeGitRepo(withFile: "Small.swift", lines: 12)
        defer { try? FileManager.default.removeItem(atPath: smallRepo) }

        // A build DID produce a verified artifact (cheap guard passes) — so the verdict now hinges on the
        // symbolic pass, i.e. the monolith gate.
        let built = [MoveOutcome(success: true, producedArtifact: true, summary: "built + verified")]

        let monolithVerdict = KistREPL.makeFixJudge(projectRoot: bigRepo)("obj", built)
        guard case .notDone(let reason) = monolithVerdict else {
            return XCTFail("a 1600-line changed file must be REFUSED by the monolith gate, got \(monolithVerdict)")
        }
        XCTAssertTrue(reason.lowercased().contains("monolith"), "the refusal must name the monolith rule: \(reason)")

        let smallVerdict = KistREPL.makeFixJudge(projectRoot: smallRepo)("obj", built)
        guard case .done = smallVerdict else {
            return XCTFail("a small verified change must be accepted as done, got \(smallVerdict)")
        }
    }

    // A PRE-EXISTING dirty monolith (in the baseline) must NOT block a small correct fix — but the gate
    // still fires for a monolith THIS fix actually touched. (Review finding 2026-08-05.)
    func testPreExistingMonolithDoesNotFalseBlockASmallFix() throws {
        let repo = try makeGitRepo(withFile: "Big.swift", lines: 1600)   // already-dirty 1600-line file
        defer { try? FileManager.default.removeItem(atPath: repo) }
        // …and this fix adds a small new file:
        try (1...12).map { "// line \($0)" }.joined(separator: "\n")
            .write(toFile: (repo as NSString).appendingPathComponent("Small.swift"), atomically: true, encoding: .utf8)
        let built = [MoveOutcome(success: true, producedArtifact: true, summary: "built")]

        // Baseline captured Big.swift (pre-existing) → judge only Small.swift → done, not blocked.
        let withBaseline = KistREPL.makeFixJudge(projectRoot: repo, baselineChanged: ["Big.swift"])("obj", built)
        guard case .done = withBaseline else {
            return XCTFail("a pre-existing dirty monolith must not block a small correct fix, got \(withBaseline)")
        }
        // WITHOUT a baseline (default), the 1600-line file still trips the monolith gate — the gate works.
        if case .done = KistREPL.makeFixJudge(projectRoot: repo)("obj", built) {
            XCTFail("with no baseline, a 1600-line changed file must still be refused by the monolith gate")
        }
    }

    // MARK: - helpers

    /// A throwaway git repo containing one untracked source file of `lines` lines, so
    /// `workingTreeChangedFiles` (git status --porcelain) sees it as a change.
    private func makeGitRepo(withFile name: String, lines: Int) throws -> String {
        let dir = ToolContext.canonicalize(
            try makeDir(NSTemporaryDirectory() + "fixrepo-\(UUID().uuidString)"))!
        try runGit(["init", "-q"], in: dir)
        let body = (1...lines).map { "// line \($0)" }.joined(separator: "\n")
        try body.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        return dir
    }

    private func makeDir(_ p: String) throws -> String {
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    private func runGit(_ args: [String], in dir: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", dir] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }
}
