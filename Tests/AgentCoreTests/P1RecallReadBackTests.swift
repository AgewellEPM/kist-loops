import XCTest
@testable import AgentCore

/// P1 — recall→plan read-back. Two deterministic contracts, pinned without a live embedder or model:
///  1. `formatLessonBlock` surfaces ONLY verified auto-lessons above the floor, capped, framed advisory.
///  2. The RECALL corpus (`/ablation recall`) loads from its OWN file and is disjoint from golden/capability.
final class P1RecallReadBackTests: XCTestCase {

    private func hit(_ text: String, _ score: Float, kind: String?) -> VectorHit {
        VectorHit(id: SemanticMemoryService.id(for: text), text: text, score: score,
                  metadata: kind.map { ["kind": $0] } ?? [:])
    }

    // MARK: - formatLessonBlock

    func testKeepsOnlyVerifiedAutoLessonsAboveFloor() {
        let hits = [
            hit("VERIFIED: use kist-rebuild --force to promote", 0.9, kind: "auto-lesson"),
            hit("an unverified plain note", 0.9, kind: nil),          // not an auto-lesson → dropped
            hit("a tagged-but-not-lesson note", 0.9, kind: "tag"),    // wrong kind → dropped
            hit("a faint auto-lesson", 0.05, kind: "auto-lesson"),    // below floor → dropped
        ]
        let block = SemanticMemoryService.formatLessonBlock(hits, minScore: 0.2)
        XCTAssertTrue(block.contains("kist-rebuild --force"), "the verified auto-lesson above the floor must appear")
        XCTAssertFalse(block.contains("unverified plain note"), "a non-auto-lesson deposit must never leak into the plan")
        XCTAssertFalse(block.contains("tagged-but-not-lesson"), "only kind=auto-lesson qualifies")
        XCTAssertFalse(block.contains("faint auto-lesson"), "below-floor similarity must be dropped")
    }

    func testEmptyWhenNothingQualifies() {
        let hits = [hit("plain", 0.99, kind: nil), hit("weak lesson", 0.01, kind: "auto-lesson")]
        XCTAssertEqual(SemanticMemoryService.formatLessonBlock(hits, minScore: 0.2), "",
                       "no qualifying lesson ⇒ empty ⇒ the loop injects nothing (no phantom block)")
    }

    func testCapsAtThreeLessons() {
        let hits = (1...6).map { hit("lesson number \($0)", 0.9, kind: "auto-lesson") }
        let block = SemanticMemoryService.formatLessonBlock(hits, minScore: 0.2)
        let bullets = block.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        XCTAssertEqual(bullets, 3, "at most 3 lessons are surfaced so the read-back can't flood the prompt")
    }

    func testFramedAdvisoryNotAuthority() {
        let block = SemanticMemoryService.formatLessonBlock([hit("do X", 0.9, kind: "auto-lesson")], minScore: 0.2)
        // The framing is a real contract: a recalled lesson is CONTEXT, never an instruction the model must obey.
        XCTAssertTrue(block.lowercased().contains("advisory"), "block must be framed advisory")
        XCTAssertTrue(block.lowercased().contains("not an authority grant"), "block must disclaim authority")
    }

    // MARK: - the recall corpus (multi-site: each corpus loads from ITS OWN file, disjoint)

    private func tmpRoot(golden: String?, capability: String?, recall: String?) -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-p1-\(UUID().uuidString)")
        let evalDir = (root as NSString).appendingPathComponent(".kist/eval")
        try? FileManager.default.createDirectory(atPath: evalDir, withIntermediateDirectories: true)
        func w(_ s: String?, _ f: String) { if let s { try? s.write(toFile: (evalDir as NSString).appendingPathComponent(f), atomically: true, encoding: .utf8) } }
        w(golden, "suite.json"); w(capability, "capability-suite.json"); w(recall, "recall-suite.json")
        return root
    }

    func testRecallCorpusLoadsFromItsOwnFileAndIsDisjoint() {
        let root = tmpRoot(
            golden: #"[{"name":"g-case","prompt":"g","assertions":["healthy"]}]"#,
            capability: #"[{"name":"cap-case","prompt":"c","assertions":["healthy"]}]"#,
            recall: #"[{"name":"recall-case","prompt":"what is the deploy command","assertions":[{"contains":"kist-rebuild"}]}]"#)
        // Per-site: assert EACH corpus contains ONLY its own file's cases (the multi-site discipline — three
        // sibling loaders, one assertion each, so a regressed loader names itself).
        let byCorpus: [(String, Set<String>)] = [
            ("golden",     Set(EvalGoldenSuite.cases(projectRoot: root).map { $0.name })),
            ("capability", Set(EvalGoldenSuite.capabilityCases(projectRoot: root).map { $0.name })),
            ("recall",     Set(EvalGoldenSuite.recallCases(projectRoot: root).map { $0.name })),
        ]
        XCTAssertTrue(byCorpus[0].1.contains("g-case"))
        XCTAssertTrue(byCorpus[1].1.contains("cap-case"))
        XCTAssertTrue(byCorpus[2].1.contains("recall-case"))
        // Recall must NOT bleed into the others and vice-versa.
        XCTAssertFalse(byCorpus[0].1.contains("recall-case"), "golden must not include the recall corpus")
        XCTAssertFalse(byCorpus[1].1.contains("recall-case"), "capability must not include the recall corpus")
        XCTAssertFalse(byCorpus[2].1.contains("g-case"), "recall must not include the golden corpus")
        XCTAssertFalse(byCorpus[2].1.contains("cap-case"), "recall must not include the capability corpus")
    }

    func testRecallCorpusEmptyWhenUnseeded() {
        let root = tmpRoot(golden: nil, capability: nil, recall: nil)
        XCTAssertTrue(EvalGoldenSuite.recallCases(projectRoot: root).isEmpty,
                      "unseeded recall corpus is empty (built-in intentionally empty) — /ablation recall reports so honestly")
    }
}
