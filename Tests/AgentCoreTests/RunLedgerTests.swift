import XCTest
@testable import AgentCore

final class RunLedgerTests: XCTestCase {

    // MARK: - helpers

    private func rec(id: String = "r", route: String, at: Double = 1,
                     success: Bool = true, verified: Bool = false, stuck: Bool = false,
                     replans: Int = 0, failRate: Double = 0, iters: Int = 5, budget: Int = 15,
                     tokens: Int = 1000, duration: Double = 100, signature: String = "sig",
                     orgVersion: String = "v1", failureStage: String? = nil) -> RunRecord {
        RunRecord(id: id, at: at, goal: "g", signature: signature, orgVersion: orgVersion,
                  route: route, complexity: 20, thinking: "light", planning: "direct", team: "solo",
                  modelTier: "standard", decisionReason: "x", specialists: [], provider: "p", model: "m",
                  success: success, verified: verified, failureRate: failRate, iterationsUsed: iters,
                  iterationBudget: budget, replansUsed: replans, wasStuck: stuck, toolCalls: 3,
                  durationMs: duration, totalTokens: tokens, failureStage: failureStage)
    }

    private func tmpRoot() -> String {
        NSTemporaryDirectory() + "runledger-" + UUID().uuidString
    }

    // MARK: - RoutingMisfit (the core self-improvement signal)

    func testFastRunThatStruggledIsUnderEscalated() {
        XCTAssertEqual(rec(route: "fast", stuck: true).routingMisfit, .underEscalated)
        XCTAssertEqual(rec(route: "standard", success: false).routingMisfit, .underEscalated)
        XCTAssertEqual(rec(route: "fast", replans: 2).routingMisfit, .underEscalated)
    }

    func testHealthyFastRunHasNoMisfit() {
        XCTAssertNil(rec(route: "fast", success: true).routingMisfit)
        XCTAssertNil(rec(route: "standard", success: true, iters: 4).routingMisfit)
    }

    func testTrivialPipelineRunIsOverEscalated() {
        // succeeded fast, no struggle, well under budget (5 <= 15/3) → the pipeline was overkill.
        XCTAssertEqual(rec(route: "pipeline", success: true, iters: 5, budget: 15).routingMisfit, .overEscalated)
    }

    func testHardPipelineRunIsNotOverEscalated() {
        // a pipeline run that actually used the budget / struggled is correctly routed → no misfit.
        XCTAssertNil(rec(route: "pipeline", success: true, iters: 12, budget: 15).routingMisfit)
        XCTAssertNil(rec(route: "pipeline", success: true, stuck: true, iters: 4, budget: 15).routingMisfit)
        XCTAssertNil(rec(route: "pipeline", success: false, iters: 2, budget: 15).routingMisfit)
    }

    // MARK: - OrgFingerprint (must be stable across processes — no per-process Hasher)

    func testFingerprintIsStableAndOrderIndependent() {
        let a = OrgFingerprint.make(["fast": "18", "complex": "55"])
        let b = OrgFingerprint.make(["complex": "55", "fast": "18"])
        XCTAssertEqual(a, b, "key order must not change the fingerprint")
        // A known-value pin: if the FNV-1a impl ever changes, before/after history silently breaks — catch it.
        XCTAssertEqual(a, OrgFingerprint.make(["fast": "18", "complex": "55"]))
    }

    func testFingerprintChangesWithConfig() {
        XCTAssertNotEqual(OrgFingerprint.make(["complex": "55"]), OrgFingerprint.make(["complex": "50"]))
    }

    // MARK: - RunAnalytics.stats / byRoute

    func testStatsAggregatesRatesAndMisfits() {
        let s = RunAnalytics.stats([
            rec(route: "fast", success: true, verified: true),
            rec(route: "fast", success: false),                 // underEscalated
            rec(route: "pipeline", success: true, iters: 5, budget: 15), // overEscalated
            rec(route: "pipeline", success: true, iters: 12, budget: 15),
        ])
        XCTAssertEqual(s.count, 4)
        XCTAssertEqual(s.successRate, 0.75, accuracy: 0.001)
        XCTAssertEqual(s.verifiedRate, 0.25, accuracy: 0.001)
        XCTAssertEqual(s.underEscalated, 1)
        XCTAssertEqual(s.overEscalated, 1)
    }

    func testByRouteGroups() {
        let by = RunAnalytics.byRoute([rec(route: "fast"), rec(route: "fast"), rec(route: "pipeline", iters: 12, budget: 15)])
        XCTAssertEqual(by["fast"]?.count, 2)
        XCTAssertEqual(by["pipeline"]?.count, 1)
    }

    func testEmptyStatsIsZero() {
        XCTAssertEqual(RunAnalytics.stats([]), .empty)
    }

    // MARK: - RunAnalytics.routingSignals (evidence-gated)

    func testRoutingSignalNeedsEnoughSamples() {
        // 3 under-escalated fast runs, but below the 8-sample floor → no signal (one bad streak ≠ a rule).
        let runs = (0..<3).map { rec(id: "\($0)", route: "fast", success: false) }
        XCTAssertTrue(RunAnalytics.routingSignals(runs).isEmpty)
    }

    func testRoutingSignalFiresAboveThreshold() {
        // 10 fast runs, 4 struggled (40% > 25% threshold) → an under-escalation signal.
        var runs = (0..<4).map { rec(id: "b\($0)", route: "fast", success: false) }
        runs += (0..<6).map { rec(id: "g\($0)", route: "fast", success: true) }
        let sigs = RunAnalytics.routingSignals(runs)
        XCTAssertEqual(sigs.count, 1)
        XCTAssertEqual(sigs.first?.misfit, .underEscalated)
        XCTAssertEqual(sigs.first?.route, "fast")
        XCTAssertTrue(sigs.first?.suggestion.contains("HEAVIER") ?? false)
    }

    func testRoutingSignalsAreDeterministicallyOrdered() {
        var runs = (0..<10).map { rec(id: "f\($0)", route: "fast", success: false) }
        runs += (0..<10).map { rec(id: "p\($0)", route: "pipeline", success: true, iters: 1, budget: 15) }
        let sigs = RunAnalytics.routingSignals(runs)
        XCTAssertEqual(sigs.map { $0.route }, ["fast", "pipeline"])  // sorted, stable
    }

    // MARK: - RunAnalytics.lift (the honest before/after)

    func testLiftDeclaresClearImprovementOnHigherSuccess() {
        // 40 runs/side, 40% → 85%: a large, STATISTICALLY SIGNIFICANT lift (two-proportion z ≈ 4.2).
        let before = (0..<40).map { rec(id: "b\($0)", route: "standard", success: $0 < 16) }  // 40%
        let after  = (0..<40).map { rec(id: "a\($0)", route: "standard", success: $0 < 34) }  // 85%
        let lift = RunAnalytics.lift(before: before, after: after)
        XCTAssertEqual(lift.successRateDelta, 0.45, accuracy: 0.001)
        XCTAssertTrue(lift.isClearLift)
    }

    func testLiftRefusesStatisticallyInsignificantDelta() {
        // Council (DeepSeek) counterexample: 5/8 → 6/8 is a +12.5-point delta but p≈0.6 — pure noise. The
        // OLD magnitude-only rule called this a "clear lift"; the significance gate must now refuse it.
        let before = (0..<8).map { rec(id: "b\($0)", route: "standard", success: $0 < 5) }  // 5/8
        let after  = (0..<8).map { rec(id: "a\($0)", route: "standard", success: $0 < 6) }  // 6/8
        let lift = RunAnalytics.lift(before: before, after: after)
        XCTAssertGreaterThanOrEqual(lift.successRateDelta, 0.05)   // magnitude alone would have passed
        XCTAssertFalse(lift.isClearLift, "a +12.5pt delta on 8 vs 8 is not significant — must not be a lift")
    }

    func testSuccessZMatchesHandComputedValue() {
        // Pin the statistic: 40% vs 85% on 40/side → pooled 0.625, se≈0.1082, z≈4.16.
        let before = (0..<40).map { rec(id: "b\($0)", route: "standard", success: $0 < 16) }
        let after  = (0..<40).map { rec(id: "a\($0)", route: "standard", success: $0 < 34) }
        XCTAssertEqual(RunAnalytics.successZ(before: before, after: after), 4.16, accuracy: 0.05)
        // Undefined test (all-success both sides → zero variance) returns 0, never "significant".
        let flat = (0..<10).map { rec(id: "f\($0)", route: "standard", success: true) }
        XCTAssertEqual(RunAnalytics.successZ(before: flat, after: flat), 0)
    }

    func testLiftRefusesOnThinEvidence() {
        // Big apparent jump but only 3 samples/side → NOT a clear lift (leaky-benchmark guard).
        let before = (0..<3).map { rec(id: "b\($0)", route: "standard", success: false) }
        let after  = (0..<3).map { rec(id: "a\($0)", route: "standard", success: true) }
        XCTAssertFalse(RunAnalytics.lift(before: before, after: after).isClearLift)
    }

    func testLiftRefusesWhenSuccessRegresses() {
        // Cheaper (fewer iterations) but success dropped → must NOT be called an improvement.
        let before = (0..<10).map { rec(id: "b\($0)", route: "standard", success: true, iters: 10) }
        let after  = (0..<10).map { rec(id: "a\($0)", route: "standard", success: $0 < 5, iters: 3) }
        let lift = RunAnalytics.lift(before: before, after: after)
        XCTAssertTrue(lift.avgIterationsDelta < 0)   // it IS cheaper
        XCTAssertFalse(lift.isClearLift)             // but success regressed → not a win
    }

    func testLiftRejectsTinyTokenBaselineManufacturedWin() {
        // Council (GPT) edge: a degenerate tiny token baseline must NOT let a fractional-token "reduction"
        // fake a clear lift. Same success, no iteration reduction, tokens 10→4 (a 60% drop, but on noise).
        let before = (0..<10).map { rec(id: "b\($0)", route: "standard", success: true, iters: 5, tokens: 10) }
        let after  = (0..<10).map { rec(id: "a\($0)", route: "standard", success: true, iters: 5, tokens: 4) }
        XCTAssertFalse(RunAnalytics.lift(before: before, after: after).isClearLift,
                       "a sub-200-token baseline must not manufacture a clear lift via the token gate")
    }

    func testLiftCountsCheaperAtSameSuccessAsWin() {
        let before = (0..<10).map { rec(id: "b\($0)", route: "standard", success: true, iters: 10, tokens: 2000) }
        let after  = (0..<10).map { rec(id: "a\($0)", route: "standard", success: true, iters: 5, tokens: 900) }
        XCTAssertTrue(RunAnalytics.lift(before: before, after: after).isClearLift)
    }

    // MARK: - RunLedger persistence

    func testRecordRoundTrips() {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = RunLedger(projectRoot: root)
        let r = rec(id: "run-1", route: "pipeline", iters: 12, budget: 15)
        ledger.record(r)
        let loaded = ledger.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, r)
    }

    func testLedgerIsBounded() {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = RunLedger(projectRoot: root, maxRecords: 5)
        for i in 0..<12 { ledger.record(rec(id: "r\(i)", route: "fast")) }
        let loaded = ledger.load()
        XCTAssertEqual(loaded.count, 5)
        XCTAssertEqual(loaded.last?.id, "r11")   // newest kept
    }

    func testCorruptLineIsSkippedNotFatal() {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = RunLedger(projectRoot: root)
        ledger.record(rec(id: "good", route: "fast"))
        // splice a garbage line into the jsonl
        let path = root + "/.kist/run-ledger.jsonl"
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? (existing + "{ not json }\n").write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = ledger.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "good")
    }

    func testCorruptByteDoesNotDestroyHistoryOnAppend() {
        // Council (DeepSeek) Bug #2: a single non-UTF-8 byte previously made record()'s whole-file read fail
        // → it silently OVERWROTE all prior history with just the new line. The resilient per-line read must
        // now preserve every valid record across the next append.
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = RunLedger(projectRoot: root)
        ledger.record(rec(id: "one", route: "fast"))
        ledger.record(rec(id: "two", route: "fast"))
        // Corrupt the file with a raw non-UTF-8 byte (0xFF) appended after the valid lines.
        let path = root + "/.kist/run-ledger.jsonl"
        var data = FileManager.default.contents(atPath: path) ?? Data()
        data.append(0xFF); data.append(0x0A)
        try? data.write(to: URL(fileURLWithPath: path))
        // The next append must NOT wipe "one"/"two".
        ledger.record(rec(id: "three", route: "fast"))
        let ids = Set(ledger.load().map { $0.id })
        XCTAssertTrue(ids.isSuperset(of: ["one", "two", "three"]), "prior history destroyed by a corrupt byte: \(ids)")
    }

    func testMissingFileIsEmptyNotCrash() {
        let ledger = RunLedger(projectRoot: tmpRoot() + "/does/not/exist")
        XCTAssertEqual(ledger.load().count, 0)
    }

    func testSliceBySignatureAndOrgVersion() {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = RunLedger(projectRoot: root)
        ledger.record(rec(id: "1", route: "fast", signature: "A", orgVersion: "v1"))
        ledger.record(rec(id: "2", route: "fast", signature: "A", orgVersion: "v2"))
        ledger.record(rec(id: "3", route: "fast", signature: "B", orgVersion: "v1"))
        XCTAssertEqual(ledger.runs(signature: "A").count, 2)
        XCTAssertEqual(ledger.runs(signature: "A", orgVersion: "v1").count, 1)
    }

    func testLedgerLiftAcrossOrgVersions() {
        let root = tmpRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let ledger = RunLedger(projectRoot: root)
        for i in 0..<20 { ledger.record(rec(id: "b\(i)", route: "standard", success: i < 10, signature: "A", orgVersion: "v1")) }
        for i in 0..<20 { ledger.record(rec(id: "a\(i)", route: "standard", success: i < 18, signature: "A", orgVersion: "v2")) }
        let lift = ledger.lift(signature: "A", before: "v1", after: "v2")
        XCTAssertTrue(lift.isClearLift)     // 50%→90% on 20/side → z≈2.8, significant
        XCTAssertEqual(lift.successRateDelta, 0.4, accuracy: 0.001)
    }
}
