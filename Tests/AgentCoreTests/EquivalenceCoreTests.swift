import XCTest
@testable import AgentCore

final class EquivalenceCoreTests: XCTestCase {

    private func ev(_ id: String, a: String?, b: String?, c: String?,
                    volatiles: [VolatileField] = [], nd: Bool = false, inv: Bool? = nil) -> CaseEvidence {
        CaseEvidence(id: id, oracleRunA: a, oracleRunB: b, candidate: c,
                     volatiles: volatiles, mayBeNondeterministic: nd, invariantHolds: inv)
    }

    // MARK: - CanonicalForm

    func testJsonKeyOrderAndWhitespaceCanonicalizeEqual() {
        let x = CanonicalForm.canonicalize(#"{"b":1,"a":2}"#)
        let y = CanonicalForm.canonicalize(#"{ "a": 2,  "b": 1 }"#)
        XCTAssertEqual(x, y, "key order + whitespace must not survive canonicalization")
    }

    func testNestedJsonKeysSortedRecursively() {
        let x = CanonicalForm.canonicalize(#"{"o":{"z":1,"a":2},"k":3}"#)
        let y = CanonicalForm.canonicalize(#"{"k":3,"o":{"a":2,"z":1}}"#)
        XCTAssertEqual(x, y)
    }

    func testTextTrailingWhitespaceNormalizedButIndentationKept() {
        let x = CanonicalForm.canonicalize("line1   \n  indented\nlast\t\n")
        let y = CanonicalForm.canonicalize("line1\n  indented\nlast")
        XCTAssertEqual(x, y)
        XCTAssertTrue(x.contains("  indented"), "leading indentation is semantic — must be preserved")
    }

    func testVolatileProjectionMasksValueNotShape() {
        let v = [VolatileField.isoTimestamp]
        let x = CanonicalForm.canonicalize("at 2026-07-03T12:00:00Z done", projecting: v)
        let y = CanonicalForm.canonicalize("at 2026-01-01T00:00:00Z done", projecting: v)
        XCTAssertEqual(x, y, "declared volatile timestamps must be projected to a placeholder")
        XCTAssertTrue(x.contains("<TS>"))
    }

    func testCanonicalizationIsSymmetricCannotManufactureADifference() {
        // Same raw input → identical canonical form (a normalization can mask a diff, never invent one).
        let raw = #"{"b":1,"a":[3,2,1]}"#
        XCTAssertEqual(CanonicalForm.canonicalize(raw), CanonicalForm.canonicalize(raw))
    }

    // MARK: - The five verdict states

    func testEquivalentWhenCandidateMatchesDeterministicOracle() {
        XCTAssertEqual(EquivalenceHarness.judge(ev("1", a: #"{"x":1}"#, b: #"{"x":1}"#, c: #"{ "x":1 }"#)), .equivalent)
    }

    func testNotEquivalentWhenCandidateDiffersFromDeterministicOracle() {
        XCTAssertEqual(EquivalenceHarness.judge(ev("2", a: #"{"x":1}"#, b: #"{"x":1}"#, c: #"{"x":2}"#)), .notEquivalent)
    }

    func testNotCoveredWhenAnyInputMissing() {
        XCTAssertEqual(EquivalenceHarness.judge(ev("3", a: nil, b: "x", c: "x")), .notCovered)
        XCTAssertEqual(EquivalenceHarness.judge(ev("3b", a: "x", b: "x", c: nil)), .notCovered)
    }

    func testCaptureFailedWhenOracleDisagreesWithItselfUnexpectedly() {
        // Gate 0: two sealed replays of the ORIGINAL diverged, and the caller did NOT declare the field
        // nondeterministic → the sealing is broken. Fail-closed: never judge the candidate.
        XCTAssertEqual(EquivalenceHarness.judge(ev("4", a: "result=41", b: "result=42", c: "result=42")), .captureFailed)
    }

    func testUnprovableWhenOracleNondeterminismIsDeclaredAndNoInvariant() {
        // Same oracle disagreement, but the caller KNEW this field is unsealed and offered no invariant.
        XCTAssertEqual(EquivalenceHarness.judge(ev("5", a: "id=41", b: "id=42", c: "id=99", nd: true)), .unprovable)
    }

    func testInvariantAdjudicatesWhenOracleIsNondeterministic() {
        // Oracle disagrees with itself, but an invariant on the candidate holds → equivalent-by-invariant.
        XCTAssertEqual(EquivalenceHarness.judge(ev("6", a: "id=41", b: "id=42", c: "id=99", nd: true, inv: true)), .equivalent)
        XCTAssertEqual(EquivalenceHarness.judge(ev("6b", a: "id=41", b: "id=42", c: "bad", nd: true, inv: false)), .notEquivalent)
    }

    func testGate0BeatsCandidateMatch() {
        // Even if the candidate happens to match one oracle run, a broken capture must NOT read as equivalent.
        // (candidate == oracleRunB, but A≠B → captureFailed, never equivalent.)
        XCTAssertEqual(EquivalenceHarness.judge(ev("7", a: "41", b: "42", c: "42")), .captureFailed)
    }

    func testDeterministicOracleWithInvariantRescuesAReformat() {
        // Oracle deterministic, candidate differs textually, but a supplied invariant says it's fine.
        XCTAssertEqual(EquivalenceHarness.judge(ev("8", a: "1,2,3", b: "1,2,3", c: "3,2,1", inv: true)), .equivalent)
    }

    // MARK: - Council bug #1: Gate 0 fail-closed must beat the invariant

    func testInvariantCannotLaunderABrokenCaptureIntoEquivalent() {
        // Council CRITICAL: undeclared oracle disagreement (A!=B, mayBeNondeterministic:false) must be
        // captureFailed even if a trivial invariantHolds:true is supplied. An invariant may NEVER override
        // a broken capture — it only rescues a DECLARED-nondeterministic field.
        let v = EquivalenceHarness.judge(ev("b1", a: #"{"x":1}"#, b: #"{"x":2}"#, c: #"{"x":1}"#, nd: false, inv: true))
        XCTAssertEqual(v, .captureFailed, "invariant must not launder a broken capture into equivalent")
    }

    func testInvariantStillAdjudicatesWhenNondeterminismIsDeclared() {
        // The legitimate path still works: declared nondeterministic + invariant holds → equivalent.
        XCTAssertEqual(EquivalenceHarness.judge(ev("b1b", a: "id=1", b: "id=2", c: "id=9", nd: true, inv: true)), .equivalent)
    }

    func testCandidateThrewFlagIsNotEquivalentOnDeterministicOracle() {
        // Out-of-band crash signal: oracle deterministic + candidateThrew → notEquivalent (never notCovered,
        // never equivalent). Candidate string is nil (it threw); the flag carries the truth.
        let e = CaseEvidence(id: "t", oracleRunA: "42", oracleRunB: "42", candidate: nil, candidateThrew: true)
        XCTAssertEqual(EquivalenceHarness.judge(e), .notEquivalent)
    }

    func testCandidateThrewOnBrokenCaptureStaysCaptureFailed() {
        // If the oracle capture itself is broken (A!=B, undeclared), that dominates a candidate throw.
        let e = CaseEvidence(id: "t2", oracleRunA: "41", oracleRunB: "42", candidate: nil, candidateThrew: true)
        XCTAssertEqual(EquivalenceHarness.judge(e), .captureFailed)
    }

    // MARK: - Council bug #2: JSON canonicalization must not mint false equivalents

    func testNumberLexemePreservedOneVsOnePointZeroIsNotEquivalent() {
        // Council HIGH: 1.0 vs 1 must NOT canonicalize equal (JSONSerialization collapsed them → false pass).
        XCTAssertNotEqual(CanonicalForm.canonicalize("1.0"), CanonicalForm.canonicalize("1"))
        XCTAssertEqual(EquivalenceHarness.judge(ev("b2a", a: "1.0", b: "1.0", c: "1")), .notEquivalent)
        // and inside an object
        XCTAssertEqual(EquivalenceHarness.judge(ev("b2a2", a: #"{"v":1.0}"#, b: #"{"v":1.0}"#, c: #"{"v":1}"#)), .notEquivalent)
    }

    func testExponentAndPlainFormNotSilentlyEqual() {
        XCTAssertNotEqual(CanonicalForm.canonicalize("1e2"), CanonicalForm.canonicalize("100"))
    }

    func testDuplicateKeysNotMaskedIntoEquivalent() {
        // Council HIGH: {"a":1,"a":2} (last-wins) vs {"a":2} must NOT read equivalent. Duplicate-key
        // objects are rejected by the JSON canonicalizer → text fallback → the two strings differ.
        XCTAssertEqual(EquivalenceHarness.judge(ev("b2b", a: #"{"a":1,"a":2}"#, b: #"{"a":1,"a":2}"#, c: #"{"a":2}"#)), .notEquivalent)
    }

    func testUnicodeEscapeAndLiteralStringAreEquivalent() {
        // String VALUES are unambiguous → "A" and "A" are the same string (no false NOT-equivalent).
        XCTAssertEqual(CanonicalForm.canonicalize(#"{"k":"A"}"#), CanonicalForm.canonicalize(#"{"k":"A"}"#))
    }

    func testValidJsonStillCanonicalizesKeyOrder() {
        // The good behavior we still want: key order + whitespace is not a diff.
        XCTAssertEqual(EquivalenceHarness.judge(ev("b2c", a: #"{"a":1,"b":2}"#, b: #"{"a":1,"b":2}"#, c: #"{ "b":2, "a":1 }"#)), .equivalent)
    }

    // MARK: - Council round 2: JSON parser hardening (strictness + robustness)

    func testDeepNestingDoesNotCrashAndFallsBackSafely() {
        // Council (DeepSeek): unbounded recursion → stack overflow. Beyond the depth cap we must return a
        // value (via text fallback) without crashing. 5000 levels would overflow a naive recursive parser.
        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        let out = CanonicalForm.canonicalize(deep)   // must not crash
        XCTAssertFalse(out.isEmpty)
    }

    func testLeadingZeroNumberRejectedToTextFallback() {
        // 0123 is invalid JSON → JSON canon returns nil → text fallback. It must NOT canonicalize equal to
        // the valid 123 (that would let an invalid input mask a diff).
        XCTAssertNotEqual(CanonicalForm.canonicalize("0123"), CanonicalForm.canonicalize("123"))
    }

    func testRawControlCharInStringRejected() {
        // A raw tab inside a JSON string is invalid → must not canonicalize equal to the escaped-valid twin.
        let rawTab = "{\"k\":\"a\tb\"}"          // literal tab byte
        let escaped = #"{"k":"a\tb"}"#           // valid \t escape
        XCTAssertNotEqual(CanonicalForm.canonicalize(rawTab), CanonicalForm.canonicalize(escaped))
    }

    func testValidSurrogatePairCombinesAndMatchesRawEmoji() {
        // 😀 (escaped 😀) must canonicalize equal to the raw emoji — no false NOT-equivalent.
        XCTAssertEqual(EquivalenceHarness.judge(ev("sp", a: #"{"e":"😀"}"#, b: #"{"e":"😀"}"#, c: #"{"e":"😀"}"#)), .equivalent)
    }

    func testLoneSurrogateRejectedToTextFallback() {
        // A lone high surrogate is invalid JSON → JSON canon nil → text fallback (no crash, no false equal).
        let lone = #"{"k":"\uD800"}"#
        XCTAssertFalse(CanonicalForm.canonicalize(lone).isEmpty)   // no crash
    }

    func testTrailingGarbageRejected() {
        // {"a":1} extra → not one clean JSON value → text fallback (must not equal the clean form).
        XCTAssertNotEqual(CanonicalForm.canonicalize(#"{"a":1} x"#), CanonicalForm.canonicalize(#"{"a":1}"#))
    }

    // MARK: - EquivalenceReport (honest weakest-link roll-up)

    func testOverallIsWeakestLinkNotGreenCount() {
        // 9 equivalent + 1 regression → the slice REGRESSED, not "90% passed".
        var results = (0..<9).map { EquivalenceReport.CaseResult(id: "ok\($0)", verdict: .equivalent) }
        results.append(.init(id: "bad", verdict: .notEquivalent))
        XCTAssertEqual(EquivalenceReport(results).overall, .regressed)
    }

    func testCaptureFailedDominatesEverything() {
        let r = EquivalenceReport([.init(id: "a", verdict: .equivalent), .init(id: "b", verdict: .captureFailed),
                                   .init(id: "c", verdict: .notEquivalent)])
        XCTAssertEqual(r.overall, .captureFailed)   // invalid evidence trumps even a regression
        XCTAssertFalse(r.isCutoverEligible)
    }

    func testIncompleteWhenGapsButNoRegression() {
        let r = EquivalenceReport([.init(id: "a", verdict: .equivalent), .init(id: "b", verdict: .notCovered),
                                   .init(id: "c", verdict: .unprovable)])
        XCTAssertEqual(r.overall, .incomplete)
        XCTAssertFalse(r.isCutoverEligible)
    }

    func testEvidenceBoundedEquivalentOnlyWhenAllGreenAndCovered() {
        let r = EquivalenceReport((0..<5).map { .init(id: "\($0)", verdict: .equivalent) })
        XCTAssertEqual(r.overall, .evidenceBoundedEquivalent)
        XCTAssertTrue(r.isCutoverEligible)
    }

    func testEmptyReportIsIncompleteNotPass() {
        let r = EquivalenceReport([])
        XCTAssertEqual(r.overall, .incomplete)
        XCTAssertFalse(r.isCutoverEligible)
    }

    func testRenderLeadsWithWeakestLinkAndShowsAllFourStates() {
        let r = EquivalenceReport([.init(id: "a", verdict: .equivalent), .init(id: "b", verdict: .notEquivalent)])
        let out = r.render()
        XCTAssertTrue(out.contains("REGRESSED"))
        XCTAssertTrue(out.contains("not-covered"))   // all states shown even when zero
        XCTAssertTrue(out.contains("CAPTURE-FAILED"))
    }

    func testJudgingBuildsReportFromEvidence() {
        let r = EquivalenceReport.judging([
            ev("a", a: "1", b: "1", c: "1"),
            ev("b", a: "1", b: "1", c: "2"),
        ])
        XCTAssertEqual(r.count(.equivalent), 1)
        XCTAssertEqual(r.count(.notEquivalent), 1)
        XCTAssertEqual(r.overall, .regressed)
    }
}
