import XCTest
@testable import AgentCore

/// The per-model scorecard (Phase 1). These pin the SAFEGUARDS that keep it from making things worse:
/// backward-compatible decode, cold-start neutrality, chronic-only exclude, stale-probe (no permanent
/// blacklist), and recency (a recovered model isn't punished for ancient faults).
final class CaptainScorecardTests: XCTestCase {

    private func sample(_ success: Bool, loop: Bool = false, reason: String? = nil, epoch: Double,
                        provider: String = "mimo") -> CaptainLearningSample {
        CaptainLearningSample(taskSignature: "t", taskTags: ["coding"], language: nil, role: "turn",
                              providerId: provider, model: nil, source: .liveEval, success: success,
                              atEpoch: epoch, failureReason: reason,
                              loopKinds: loop ? ["runawayLoop"] : [], wasStuck: loop,
                              failureRate: success ? 0 : 1)
    }

    // MARK: - Backward-compatible decode (old JSONL lines must still load)

    func testDecodesOldLineWithoutNewFields() throws {
        let old = #"{"taskSignature":"x","taskTags":["coding"],"role":"turn","providerId":"gemini","source":"liveEval","success":true,"atEpoch":100}"#
        let s = try JSONDecoder().decode(CaptainLearningSample.self, from: Data(old.utf8))
        XCTAssertEqual(s.providerId, "gemini")
        XCTAssertEqual(s.loopKinds, [])
        XCTAssertFalse(s.wasStuck)
        XCTAssertNil(s.failureReason)
        XCTAssertEqual(s.failureRate, 0)
    }

    func testNewFieldsRoundTrip() throws {
        let s = sample(false, loop: true, reason: "runawayLoop", epoch: 5)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(CaptainLearningSample.self, from: data)
        XCTAssertEqual(back.loopKinds, ["runawayLoop"])
        XCTAssertEqual(back.failureReason, "runawayLoop")
        XCTAssertTrue(back.wasStuck)
    }

    // MARK: - Cold-start neutral (must behave exactly like before the scorecard existed)

    func testColdStartIsNeutral() {
        let v = CaptainLearningStore.verdict(providerId: "mimo",
            samples: [sample(false, epoch: 1), sample(false, epoch: 2)], now: 100)
        XCTAssertEqual(v.rankDelta, 0, "<3 runs ⇒ no nudge")
        XCTAssertFalse(v.exclude, "one or two blips never exile a model")
    }

    // MARK: - Chronic offender (this is the 'don't burn shit')

    func testChronicOffenderExcludedWhenRecent() {
        let now = 1_000_000.0
        let s = (0..<6).map { sample(false, loop: true, reason: "runawayLoop", epoch: now - Double($0 * 10)) }
        let v = CaptainLearningStore.verdict(providerId: "mimo", samples: s, now: now)
        XCTAssertTrue(v.exclude, "6 recent all-fail/loop runs = chronic → skip it")
        XCTAssertLessThan(v.rankDelta, 0)
        XCTAssertTrue(v.reason.contains("chronic"))
    }

    // MARK: - No permanent blacklist (a stale offender gets a probe)

    func testChronicButStaleGetsAProbe() {
        let now = 1_000_000.0
        let old = now - (48 * 3600)   // last failure 48h ago > 24h stale window
        let s = (0..<6).map { sample(false, loop: true, reason: "runawayLoop", epoch: old - Double($0 * 10)) }
        let v = CaptainLearningStore.verdict(providerId: "mimo", samples: s, now: now)
        XCTAssertFalse(v.exclude, "a model that had a bad week is probed again, never permanently blacklisted")
    }

    // MARK: - Reward + recency

    func testStrongModelGetsPositiveDelta() {
        let now = 1_000_000.0
        let s = (0..<6).map { sample(true, epoch: now - Double($0 * 10), provider: "claude") }
        let v = CaptainLearningStore.verdict(providerId: "claude", samples: s, now: now)
        XCTAssertGreaterThan(v.rankDelta, 0)
        XCTAssertFalse(v.exclude)
    }

    // The shared failure-reason categorizer (extracted so the two writers can't drift) — priority order.
    func testScorecardReasonPriority() {
        typealias S = CaptainLearningSample
        XCTAssertEqual(S.scorecardReason(providerFault: true, flaky: true, verificationRejected: true, loopKind: "runawayLoop", failureRate: 1, ungrounded: true), "providerFault")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: true, verificationRejected: true, loopKind: "x", failureRate: 1, ungrounded: true), "flaky")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: true, loopKind: "x", failureRate: 1, ungrounded: true), "verificationFail")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: "runawayLoop", failureRate: 1, ungrounded: true), "runawayLoop")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: nil, failureRate: 0.5, ungrounded: true), "toolFailures")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: nil, failureRate: 0.1, ungrounded: true), "ungrounded")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: nil, failureRate: 0.1, ungrounded: false), "incomplete")
    }

    func testRecencyWindowFadesAncientFailures() {
        let now = 1_000_000.0
        var s = (0..<30).map { sample(false, loop: true, epoch: Double($0)) }              // ancient fails
        s += (0..<20).map { sample(true, epoch: now - Double(20 - $0)) }                    // recent wins
        let v = CaptainLearningStore.verdict(providerId: "gemini", samples: s, now: now)
        XCTAssertGreaterThan(v.rankDelta, 0, "the last 20 runs (all wins) dominate ancient failures")
        XCTAssertFalse(v.exclude)
    }
}
