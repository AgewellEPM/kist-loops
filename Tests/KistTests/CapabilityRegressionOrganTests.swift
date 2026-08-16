import XCTest
@testable import Kist
import AgentCore

/// Direct unit tests for the P3 held-out regression organ (`CapabilityRegressionOrgan`). The loop-level tests
/// in AgentCoreTests use a canned fake and cannot even import this Kist-module type; these pin the organ's OWN
/// logic with an injected spy `run` closure (no live models). They exist because the adversarial review
/// (2026-08-15) found the organ's real branches — the ones carrying the false-reject AND false-negative
/// landmines — had insufficient coverage. Each test maps to a specific confirmed finding.
///
/// CONFIRM MODEL under test (post-fix): a suspected drop is decided by a TWO-SIDED MAJORITY RATE TEST over
/// `confirmRetries+1` samples per arm — a regression is confirmed iff the candidate fails a STRICT MAJORITY of
/// its samples AND the baseline passes a strict majority of its own. Not a single sample; not a one-pass pardon.
final class CapabilityRegressionOrganTests: XCTestCase {

    /// Programmable spy for the injected `run` closure. The handler is called with the case names, whether the
    /// candidate tool was present (candidate arm vs baseline arm), and the 0-based index WITHIN that arm's calls
    /// — so a test can say "candidate arm fails cap_b on sample 0 and 1, passes on 2" without depending on the
    /// exact global call order. The organ awaits calls strictly in order, so @unchecked Sendable is safe here.
    final class RunSpy: @unchecked Sendable {
        struct Call: Equatable { let names: [String]; let hasExtra: Bool; let extraName: String? }
        private(set) var calls: [Call] = []
        private var candCalls = 0
        private var baseCalls = 0
        private let handler: (_ names: [String], _ hasExtra: Bool, _ armIndex: Int) -> Set<String>
        init(_ handler: @escaping (_ names: [String], _ hasExtra: Bool, _ armIndex: Int) -> Set<String>) {
            self.handler = handler
        }
        func run(_ cases: [EvalCase], _ extra: ScriptTool?) -> Set<String> {
            let hasExtra = extra != nil
            let armIndex = hasExtra ? candCalls : baseCalls
            if hasExtra { candCalls += 1 } else { baseCalls += 1 }
            calls.append(Call(names: cases.map { $0.name }, hasExtra: hasExtra, extraName: extra?.name))
            return handler(cases.map { $0.name }, hasExtra, armIndex)
        }
    }

    private func cases(_ names: [String]) -> [EvalCase] {
        names.map { EvalCase(name: $0, prompt: "do \($0)", assertions: []) }
    }

    private func organ(_ cs: [EvalCase], confirmRetries: Int = 2, spy: RunSpy) -> CapabilityRegressionOrgan {
        CapabilityRegressionOrgan(cases: cs, confirmRetries: confirmRetries) { c, e in spy.run(c, e) }
    }

    /// Writes a real manifest.json + script into a fresh temp dir so `SelfAuthoredManifest.loadFrom` succeeds,
    /// returning a candidate pointing at it plus the tool name.
    private func candidateWithManifest(name: String = "self__do_thing") -> (CapabilityCandidate, String) {
        let dir = NSTemporaryDirectory() + "cro-\(name)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let manifest = SelfAuthoredManifest(name: name, description: "test tool", interpreter: "/bin/bash",
                                            scriptFile: "tool.sh", parameters: [], contract: "does the thing",
                                            testArgs: [:], testExpectSubstring: "ok")
        try! JSONEncoder().encode(manifest).write(to: URL(fileURLWithPath: dir + "/manifest.json"))
        try! "echo ok".write(toFile: dir + "/tool.sh", atomically: true, encoding: .utf8)
        return (CapabilityCandidate(toolName: name, workdir: dir, contract: "does the thing", authorProvider: "deepseek"), name)
    }

    private func candidateMissingArtifact(name: String = "self__vanished") -> CapabilityCandidate {
        let dir = NSTemporaryDirectory() + "cro-missing-\(UUID().uuidString)"   // empty dir — no manifest
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return CapabilityCandidate(toolName: name, workdir: dir, contract: "x", authorProvider: "deepseek")
    }

    /// Empty corpus ⇒ additive no-op, closure NEVER invoked. Proves the fail-safe AT the organ (not just the loop).
    func testEmptyCorpusReturnsEmptyAndNeverRunsClosure() async {
        let spy = RunSpy { _, _, _ in ["should_not_happen"] }
        let o = organ([], spy: spy)
        let (cand, _) = candidateWithManifest()
        let before = await o.baselinePassing()
        let after = await o.passingWith(cand)
        XCTAssertEqual(before, [])
        XCTAssertEqual(after, [])
        XCTAssertEqual(spy.calls.count, 0, "empty corpus must short-circuit before any run")
    }

    /// Candidate arm injects exactly the candidate ScriptTool (named from its manifest); baseline arm has none.
    func testCandidateArmInjectsNamedTool() async {
        let spy = RunSpy { names, _, _ in Set(names) }   // everything passes both arms ⇒ fast path, no retries
        let o = organ(cases(["cap_a", "cap_b"]), spy: spy)
        let (cand, toolName) = candidateWithManifest(name: "self__named")
        _ = await o.baselinePassing()
        _ = await o.passingWith(cand)
        XCTAssertEqual(spy.calls.first?.hasExtra, false, "baseline arm carries no candidate tool")
        let candArm = spy.calls.first { $0.hasExtra }
        XCTAssertNotNil(candArm, "candidate arm must inject a tool")
        XCTAssertEqual(candArm?.extraName, toolName, "injected tool must be named from the manifest")
    }

    /// Missing artifact ⇒ return the EXACT cached baseline, NOT a re-measured (drift-prone) second run.
    /// (Codex BLOCKER.) The stateful spy would DRIFT a later baseline to {cap_a}; the cache must prevent that.
    func testMissingArtifactReturnsCachedBaselineNotReMeasure() async {
        let spy = RunSpy { _, hasExtra, armIndex in
            if !hasExtra && armIndex == 0 { return ["cap_a", "cap_b"] }   // first (real) baseline
            if !hasExtra { return ["cap_a"] }                            // drifted later baseline — must NOT be used
            return ["cap_a", "cap_b"]
        }
        let o = organ(cases(["cap_a", "cap_b"]), spy: spy)
        let before = await o.baselinePassing()
        let after = await o.passingWith(candidateMissingArtifact())
        XCTAssertEqual(before, ["cap_a", "cap_b"])
        XCTAssertEqual(after, before, "fallback must return the cached baseline, not a drift-prone re-measure")
        XCTAssertEqual(spy.calls.filter { !$0.hasExtra }.count, 1, "baseline must be measured exactly once")
    }

    /// A transient one-off flake in the candidate arm (fails the FIRST sample only) is a MINORITY ⇒ exonerated,
    /// never a false regression. (Codex HIGH — the false-reject side.)
    func testTransientFlakeIsExoneratedNoRegression() async {
        let spy = RunSpy { names, hasExtra, armIndex in
            if !hasExtra { return Set(names) }                              // baseline always passes
            if armIndex == 0 { return Set(names.filter { $0 != "cap_b" }) } // afterRaw: cap_b flaked once
            return Set(names)                                               // retries: cap_b passes ⇒ minority fail
        }
        let o = organ(cases(["cap_a", "cap_b"]), spy: spy)
        let (cand, _) = candidateWithManifest()
        let before = await o.baselinePassing()
        let after = await o.passingWith(cand)
        XCTAssertEqual(after, before, "a one-off (minority) flake must be exonerated, not rejected")
    }

    /// A REPRODUCIBLE candidate-caused break on EVERY sample IS surfaced as a drop (the guard keeps its teeth).
    func testReproducibleRegressionIsSurfaced() async {
        let spy = RunSpy { names, hasExtra, _ in
            if !hasExtra { return Set(names) }                     // baseline passes all
            return Set(names.filter { $0 != "cap_b" })            // candidate CONSISTENTLY breaks cap_b
        }
        let o = organ(cases(["cap_a", "cap_b"]), spy: spy)
        let (cand, _) = candidateWithManifest()
        let before = await o.baselinePassing()
        let after = await o.passingWith(cand)
        XCTAssertEqual(before, ["cap_a", "cap_b"])
        XCTAssertEqual(after, ["cap_a"], "a reproducible candidate-caused break must drop from the passing set")
        XCTAssertEqual(before.subtracting(after), ["cap_b"], "the loop must see exactly cap_b as the regression")
    }

    // MARK: findings 1 & 2 — the false-NEGATIVE (laundering) fix — the core reason for the two-sided rate test

    /// A candidate that breaks cap_b on a MAJORITY of runs (fails samples 0 and 1, passes sample 2) must be
    /// SURFACED. Under the pre-fix one-sided logic this exonerated the instant cap_b passed once (~40–66% of
    /// real breaks shipped); the majority rate test refuses it. This is THE regression test for the confirmed
    /// HIGH finding — it fails under "pardon on first pass" and passes under "strict-majority-fail".
    func testMajorityPartialBreakIsSurfacedNotLaundered() async {
        let spy = RunSpy { names, hasExtra, armIndex in
            if !hasExtra { return Set(names) }                              // baseline passes all
            if armIndex <= 1 { return Set(names.filter { $0 != "cap_b" }) } // candidate fails cap_b on 2 of 3
            return Set(names)                                               // ...passes on the 3rd (minority pass)
        }
        let o = organ(cases(["cap_a", "cap_b"]), spy: spy)   // confirmRetries=2 ⇒ 3 candidate samples
        let (cand, _) = candidateWithManifest()
        let before = await o.baselinePassing()
        let after = await o.passingWith(cand)
        XCTAssertEqual(before.subtracting(after), ["cap_b"],
                       "a majority-of-runs candidate break must be surfaced, not laundered by a single lucky pass")
    }

    // MARK: finding 3 — the baseline-flake exoneration branch (false-REJECT side, mutation-killer)

    /// A candidate consistently fails cap_b, but the BASELINE itself is unhealthy (fails cap_b on a majority of
    /// its retries) — so the drop can't be attributed to the candidate ⇒ EXONERATED (after == before). This
    /// pins the two-sided branch: without sampling baseline and requiring baseline-majority-pass, this becomes a
    /// FALSE REJECT (the exact landmine the design says it removes). Kills the "drop the baseline-side check" mutant.
    func testBaselineFlakeIsNotBlamedOnCandidate() async {
        let spy = RunSpy { names, hasExtra, armIndex in
            if hasExtra { return Set(names.filter { $0 != "cap_b" }) }      // candidate always fails cap_b
            if armIndex == 0 { return Set(names) }                         // first baseline measurement: cap_b passes ⇒ in `before`
            return Set(names.filter { $0 != "cap_b" })                     // baseline RETRIES: cap_b also fails ⇒ unhealthy
        }
        let o = organ(cases(["cap_a", "cap_b"]), spy: spy)
        let before = await o.baselinePassing()
        let after = await o.passingWith(candidateWithManifest().0)
        XCTAssertEqual(before, ["cap_a", "cap_b"])
        XCTAssertEqual(after, before, "an environmental baseline flake must not be charged to the candidate")
    }

    /// The basePasses SEED (the initial "it passed the cached baseline" vote) is LOAD-BEARING when the baseline
    /// is a BARE majority. Candidate reproducibly fails cap_b (3/3); baseline passes cap_b on the first
    /// measurement + exactly one retry but fails the other — a 2/3 majority that TIPS on the seed. The regression
    /// MUST be surfaced. Drop the `basePasses = 1` seed and this baseline reads 1/3 → not majority → the real
    /// regression is wrongly exonerated; this pins the seed against that mutation. (Re-review 2026-08-15, skeptic-verified.)
    func testBareMajorityBaselineSeedIsLoadBearing() async {
        let spy = RunSpy { names, hasExtra, armIndex in
            if hasExtra { return Set(names.filter { $0 != "cap_b" }) }   // candidate always fails cap_b (3/3)
            if armIndex <= 1 { return Set(names) }                       // baseline: seed measurement + 1 retry pass
            return Set(names.filter { $0 != "cap_b" })                   // baseline: the other retry fails ⇒ bare 2/3
        }
        let o = organ(cases(["cap_a", "cap_b"]), spy: spy)
        let before = await o.baselinePassing()
        let after = await o.passingWith(candidateWithManifest().0)
        XCTAssertEqual(before, ["cap_a", "cap_b"])
        XCTAssertEqual(before.subtracting(after), ["cap_b"],
                       "a reproducible regression against a bare-majority-healthy baseline must be surfaced (basePasses seed is load-bearing)")
    }

    // MARK: finding 4 — the confirmRetries floor (max(1,·)) resilience, false-REJECT side

    /// With confirmRetries:0 the `max(1, confirmRetries)` floor still forces ONE retry round (2 samples/arm), so
    /// a lone candidate flake (fails sample 0, passes sample 1 ⇒ no strict majority of 2) is still EXONERATED,
    /// not hard-rejected. Kills the `max(1,·) → confirmRetries` mutant (which would skip the loop and false-reject).
    func testConfirmRetriesFloorExoneratesLoneFlake() async {
        let spy = RunSpy { names, hasExtra, armIndex in
            if !hasExtra { return Set(names) }                              // baseline passes all
            if armIndex == 0 { return Set(names.filter { $0 != "cap_b" }) } // afterRaw flake
            return Set(names)                                               // the single forced retry passes
        }
        let o = organ(cases(["cap_a", "cap_b"]), confirmRetries: 0, spy: spy)
        let before = await o.baselinePassing()
        let after = await o.passingWith(candidateWithManifest().0)
        XCTAssertEqual(after, before, "the max(1,confirmRetries) floor must still exonerate a lone flake at confirmRetries:0")
        // Prove the floor actually ran a retry round (≥2 candidate samples), i.e. the loop was not skipped.
        XCTAssertGreaterThanOrEqual(spy.calls.filter { $0.hasExtra }.count, 2,
                                    "floor must force at least one retry round (≥2 candidate samples)")
    }
}
