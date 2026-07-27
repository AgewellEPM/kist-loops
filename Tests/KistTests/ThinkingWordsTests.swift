import XCTest
@testable import Kist

/// The hip-hop / dark-comedy spinner rotator — pure, so its cycling is pinned without a terminal.
final class ThinkingWordsTests: XCTestCase {

    func testPhaseMapping() {
        XCTAssertEqual(ThinkingWords.phase(from: "planning"), .planning)
        XCTAssertEqual(ThinkingWords.phase(from: "working"), .working)
        XCTAssertEqual(ThinkingWords.phase(from: "thinking"), .thinking)
        XCTAssertEqual(ThinkingWords.phase(from: "anything-else"), .thinking)   // defaults to thinking
    }

    func testWordRotatesOverTime() {
        // Same seed, advancing the clock past the interval, must land on a DIFFERENT word.
        let t0 = ThinkingWords.word(phase: .thinking, elapsed: 0, seed: 0, intervalSeconds: 3.5)
        let t1 = ThinkingWords.word(phase: .thinking, elapsed: 4, seed: 0, intervalSeconds: 3.5)
        XCTAssertNotEqual(t0, t1, "the bar should switch after the interval")
        // Within the same interval it stays put.
        let t0b = ThinkingWords.word(phase: .thinking, elapsed: 2, seed: 0, intervalSeconds: 3.5)
        XCTAssertEqual(t0, t0b)
    }

    func testWordCyclesBackAround() {
        let n = ThinkingWords.thinking.count
        let first = ThinkingWords.word(phase: .thinking, elapsed: 0, seed: 0, intervalSeconds: 1)
        let wrapped = ThinkingWords.word(phase: .thinking, elapsed: Double(n), seed: 0, intervalSeconds: 1)
        XCTAssertEqual(first, wrapped, "after a full cycle it returns to the start")
    }

    func testSeedVariesStartingWord() {
        let a = ThinkingWords.word(phase: .thinking, elapsed: 0, seed: 0)
        let b = ThinkingWords.word(phase: .thinking, elapsed: 0, seed: 1)
        XCTAssertNotEqual(a, b, "different turns (seeds) open on different bars")
    }

    func testNegativeSeedIsSafe() {
        // Must never crash / index out of range with a negative seed.
        let w = ThinkingWords.word(phase: .working, elapsed: 10, seed: -7)
        XCTAssertTrue(ThinkingWords.working.contains(w))
    }

    func testEachPhaseHasBarsAndTheyAreDistinctVoice() {
        XCTAssertGreaterThanOrEqual(ThinkingWords.thinking.count, 8)
        XCTAssertFalse(ThinkingWords.planning.isEmpty)
        XCTAssertFalse(ThinkingWords.working.isEmpty)
        // The voice is there (a couple of signature bars), not the plain "thinking".
        XCTAssertTrue(ThinkingWords.thinking.contains("cookin' bars"))
        XCTAssertTrue(ThinkingWords.thinking.contains("channelin' ODB"))
    }
}
