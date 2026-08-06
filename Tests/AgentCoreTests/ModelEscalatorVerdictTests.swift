import XCTest
@testable import AgentCore

/// The scorecard READ path: ModelEscalator.pick must honor per-model verdicts — skip chronic offenders,
/// nudge on rankDelta — WITHOUT regressing when there's no data (cold system behaves exactly as before),
/// and never strand the only option. This is the per-site assertion for the selection choke point.
final class ModelEscalatorVerdictTests: XCTestCase {

    private func mv(_ pid: String, rankDelta: Int, exclude: Bool) -> ModelVerdict {
        ModelVerdict(providerId: pid, samples: 6, successRate: 0.5, failureRate: 0.5, loopRate: 0,
                     byReason: [:], lastFailureEpoch: nil, rankDelta: rankDelta, exclude: exclude, reason: "test")
    }

    func testEmptyVerdictsAreByteForByteUnchanged() {
        let without = ModelEscalator.pick(tier: .frontier, keyed: ["gemini", "deepseek"], preferred: "deepseek")
        let withEmpty = ModelEscalator.pick(tier: .frontier, keyed: ["gemini", "deepseek"], preferred: "deepseek", verdicts: [:])
        XCTAssertEqual(without, withEmpty, "no data ⇒ identical to pre-scorecard behavior")
        XCTAssertEqual(withEmpty, "gemini", "frontier still picks the strongest (gemini 85 > deepseek 70)")
    }

    func testChronicOffenderIsRoutedAroundEvenIfStrongest() {
        let v = ["gemini": mv("gemini", rankDelta: -12, exclude: true)]
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["gemini", "deepseek"], preferred: "deepseek", verdicts: v)
        XCTAssertEqual(pick, "deepseek", "a chronically failing/looping model is skipped even though it out-ranks the field")
    }

    func testChronicOffenderIsNeverStrandedWhenItsTheOnlyOption() {
        let v = ["gemini": mv("gemini", rankDelta: -12, exclude: true)]
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["gemini"], preferred: "gemini", verdicts: v)
        XCTAssertEqual(pick, "gemini", "the only keyed model is used regardless — better a chronic offender than nothing")
    }

    func testStrongTrackRecordCanLiftACloseModel() {
        let v = ["grok": mv("grok", rankDelta: 6, exclude: false)]
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["deepseek", "grok"], preferred: "deepseek", verdicts: v)
        XCTAssertEqual(pick, "grok", "grok (65 + 6 track-record) edges out deepseek (70) — the nudge works")
    }

    func testNudgeNeverDominatesALargeStrengthGap() {
        // A single verdict (clamped to ±[-12,+6]) can't flip a big gap: claude(100) stays ahead of mimo(45)+6.
        let v = ["mimo": mv("mimo", rankDelta: 6, exclude: false)]
        let pick = ModelEscalator.pick(tier: .frontier, keyed: ["claude", "mimo"], preferred: "mimo", verdicts: v)
        XCTAssertEqual(pick, "claude", "the scorecard nudges, it does not override a large capability gap")
    }
}
