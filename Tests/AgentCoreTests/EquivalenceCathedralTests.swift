import XCTest
@testable import AgentCore

/// The cathedral: the full L0 Legacy Modernization loop — synthesize → capture → judge → measure corpus
/// strength → fuse into honest evidence — exercised end to end through the PortVerifier facade, plus the
/// durable GoldenCorpus store.
final class EquivalenceCathedralTests: XCTestCase {

    // A payroll currency transform: parse the row as an amount, output whole cents.
    private static func cents(_ s: String, rounding: Bool) -> String {
        guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { return "invalid" }
        return "cents=\(rounding ? Int((d * 100).rounded()) : Int(d * 100))"
    }
    private func original(_ s: String) -> String { Self.cents(s, rounding: true) }

    private let amountRecord = [InputSynthesizer.Field(name: "amount", type: .currency, nominal: "10.00")]

    /// A realistic set of ≥5 killable currency mutants — enough to make a mutation score MEAN something.
    private func currencyMutants() -> [MutationMeter.Mutant] {
        func arith(_ name: String, _ f: @escaping @Sendable (Int) -> Int) -> MutationMeter.Mutant {
            MutationMeter.Mutant(name: name) { s in
                guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { return "invalid" }
                return "cents=\(f(Int((d * 100).rounded())))"
            }
        }
        return [arith("plus-cent") { $0 + 1 }, arith("minus-cent") { $0 - 1 }, arith("zero") { _ in 0 },
                arith("double") { $0 * 2 }, MutationMeter.Mutant(name: "truncate") { Self.cents($0, rounding: false) }]
    }

    // MARK: - MutationMeter

    func testStrongCorpusKillsAMutant() {
        // The synthesized currency corpus contains 0.005 (half-cent) → a truncate mutant is caught.
        let corpus = InputSynthesizer.synthesize(record: amountRecord)
        let truncate = MutationMeter.Mutant(name: "truncate") { Self.cents($0, rounding: false) }
        let score = MutationMeter.measure(corpus: corpus, oracle: original, mutants: [truncate])
        XCTAssertEqual(score.killed, ["truncate"])
        XCTAssertEqual(score.score, 1.0)
    }

    func testWeakCorpusLetsAMutantSurvive() {
        // A corpus of only the nominal input can't catch a rounding fault → the mutant SURVIVES (a gap).
        let happyPath: [EquivalenceRun.Case] = [.init(id: "nom", input: "10.00")]
        let truncate = MutationMeter.Mutant(name: "truncate") { Self.cents($0, rounding: false) }
        let score = MutationMeter.measure(corpus: happyPath, oracle: original, mutants: [truncate])
        XCTAssertEqual(score.survived, ["truncate"])
        XCTAssertEqual(score.score, 0.0)
    }

    func testEquivalentMutantExcludedFromScore() {
        let corpus = InputSynthesizer.synthesize(record: amountRecord)
        let noop = MutationMeter.Mutant(name: "whitespace-noop", isEquivalent: true) { self.original($0) }
        let score = MutationMeter.measure(corpus: corpus, oracle: original, mutants: [noop])
        XCTAssertEqual(score.equivalentSkipped, ["whitespace-noop"])
        XCTAssertNil(score.score)   // nothing killable was measured
    }

    func testNondeterministicOracleMakesMutantInconclusiveNotKilled() {
        // Council-critical: a flaky/nondeterministic ORACLE makes the run captureFailed — that must be
        // INCONCLUSIVE, never a false "kill" (which would inflate corpus strength → false certification).
        var tick = 0
        let leakyOracle: (String) -> String = { _ in tick += 1; return "v\(tick)" }
        let mutant = MutationMeter.Mutant(name: "m") { _ in "anything" }
        let score = MutationMeter.measure(corpus: [.init(id: "x", input: "a")], oracle: leakyOracle, mutants: [mutant])
        XCTAssertEqual(score.inconclusive, ["m"])
        XCTAssertTrue(score.killed.isEmpty)
        XCTAssertNil(score.score)   // nothing cleanly measurable
    }

    // MARK: - PortEvidence fusion (the load-bearing honesty rule)

    func testCleanRunOnStrongCorpusIsCertified() {
        let equiv = EquivalenceReport((0..<10).map { .init(id: "\($0)", verdict: .equivalent) })
        let mutation = MutationMeter.Score(killed: ["a", "b", "c", "d", "e"], survived: [], inconclusive: [], equivalentSkipped: [])
        let ev = PortEvidence.compile(equivalence: equiv, mutation: mutation)
        XCTAssertEqual(ev.trust, .evidenceBoundedEquivalent)
        XCTAssertTrue(ev.isCutoverEligible)
    }

    func testCleanRunOnWEAKCorpusIsNotCertified() {
        // The core mandate: the port matched every input, but the corpus couldn't catch faults → NOT a pass.
        let equiv = EquivalenceReport((0..<10).map { .init(id: "\($0)", verdict: .equivalent) })
        let mutation = MutationMeter.Score(killed: ["a", "b", "c"], survived: ["d", "e", "f"], inconclusive: [], equivalentSkipped: [])  // 50%
        let ev = PortEvidence.compile(equivalence: equiv, mutation: mutation)
        XCTAssertEqual(ev.trust, .corpusTooWeak)
        XCTAssertFalse(ev.isCutoverEligible)
    }

    func testTinyMutantSetCannotCertifyEvenAt100Percent() {
        // Council: 1-killed-of-1 = 100% but proves nothing — must not certify below the minimum count.
        let equiv = EquivalenceReport((0..<10).map { .init(id: "\($0)", verdict: .equivalent) })
        let mutation = MutationMeter.Score(killed: ["only"], survived: [], inconclusive: [], equivalentSkipped: [])
        let ev = PortEvidence.compile(equivalence: equiv, mutation: mutation)   // 100% but 1 < minMutants 5
        XCTAssertEqual(ev.trust, .corpusTooWeak)
        XCTAssertFalse(ev.isCutoverEligible)
    }

    func testCleanRunWithUNMEASUREDCorpusIsNotCertified() {
        let equiv = EquivalenceReport((0..<10).map { .init(id: "\($0)", verdict: .equivalent) })
        let mutation = MutationMeter.Score(killed: [], survived: [], inconclusive: [], equivalentSkipped: [])   // no mutants → nil
        let ev = PortEvidence.compile(equivalence: equiv, mutation: mutation)
        XCTAssertEqual(ev.trust, .corpusTooWeak)   // can't certify a corpus you never measured
    }

    func testRegressionAndCaptureBrokenDominate() {
        let strong = MutationMeter.Score(killed: ["a", "b", "c", "d", "e"], survived: [], inconclusive: [], equivalentSkipped: [])
        let regr = EquivalenceReport([.init(id: "x", verdict: .notEquivalent)])
        XCTAssertEqual(PortEvidence.compile(equivalence: regr, mutation: strong).trust, .regressed)
        let broken = EquivalenceReport([.init(id: "x", verdict: .captureFailed)])
        XCTAssertEqual(PortEvidence.compile(equivalence: broken, mutation: strong).trust, .captureBroken)
    }

    // MARK: - THE CATHEDRAL: PortVerifier end to end

    func testCorrectPortWithStrongCorpusIsCutoverEligible() {
        let result = PortVerifier.verify(record: amountRecord, mutants: currencyMutants(),
                                         oracle: original, candidate: original)
        XCTAssertEqual(result.evidence.trust, .evidenceBoundedEquivalent)
        XCTAssertTrue(result.evidence.isCutoverEligible)
        XCTAssertEqual(result.evidence.mutationScore, 1.0)
        XCTAssertGreaterThanOrEqual(result.evidence.mutantsMeasured, 5)
    }

    func testCorrectPortButCorpusBlindToAFaultClassIsNotCertified() {
        // The port is CORRECT, and there are enough mutants to measure — but one misbehaves only on an
        // input the corpus lacks and SURVIVES, dragging the score below the bar → the engine refuses to
        // certify. A green run over a corpus with a proven blind spot is not trust.
        let blindSpot = MutationMeter.Mutant(name: "wrong-only-at-7.77") { $0.trimmingCharacters(in: .whitespaces) == "7.77" ? "cents=0" : self.original($0) }
        let result = PortVerifier.verify(record: amountRecord, mutants: currencyMutants() + [blindSpot],
                                         oracle: original, candidate: original)
        XCTAssertEqual(result.evidence.trust, .corpusTooWeak)
        XCTAssertFalse(result.evidence.isCutoverEligible)
        XCTAssertEqual(result.evidence.survivedMutants, ["wrong-only-at-7.77"])
    }

    func testBuggyPortRegressesEvenWithStrongCorpus() {
        let result = PortVerifier.verify(record: amountRecord, mutants: currencyMutants(),
                                         oracle: original, candidate: { Self.cents($0, rounding: false) })
        XCTAssertEqual(result.evidence.trust, .regressed)
        XCTAssertFalse(result.evidence.isCutoverEligible)
    }

    // MARK: - GoldenCorpus (capture-once / replay-many)

    func testCaptureStoresDeterministicAndFlagsUnsealed() {
        var tick = 0
        let cases: [EquivalenceRun.Case] = [.init(id: "ok", input: "10.00"), .init(id: "leaky", input: "x")]
        let (golden, unsealed) = GoldenCorpus.capture(cases,
            oracle: { input in input == "x" ? { tick += 1; return "v\(tick)" }() : self.original(input) })
        XCTAssertEqual(golden.map { $0.id }, ["ok"])
        XCTAssertEqual(unsealed, ["leaky"])
    }

    func testGoldenReplayCatchesABuggyPort() {
        let (golden, _) = GoldenCorpus.capture(InputSynthesizer.synthesize(record: amountRecord), oracle: original)
        let good = GoldenCorpus.replay(golden, candidate: original)
        XCTAssertEqual(good.overall, .evidenceBoundedEquivalent)
        let bad = GoldenCorpus.replay(golden, candidate: { Self.cents($0, rounding: false) })
        XCTAssertEqual(bad.overall, .regressed)
    }

    func testGoldenCorpusPersistsRoundTrip() {
        let root = NSTemporaryDirectory() + "golden-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = GoldenCorpus(projectRoot: root)
        let (golden, _) = GoldenCorpus.capture([.init(id: "a", input: "10.00")], oracle: original)
        store.save(golden)
        XCTAssertEqual(store.load(), golden)
    }
}
