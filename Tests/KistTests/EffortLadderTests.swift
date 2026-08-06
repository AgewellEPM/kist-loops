import XCTest
@testable import Kist

/// `/effort` — the escalation ladder. The live escalation needs models, but the ARG PARSING and the
/// rung naming are pure and load-bearing (they decide where the ladder starts), so pin them.
final class EffortLadderTests: XCTestCase {

    func testParseStartLevelFromLeadingToken() {
        XCTAssertEqual(KistREPL.parseEffortArgs("2 build a parser").startLevel, 2)
        XCTAssertEqual(KistREPL.parseEffortArgs("2 build a parser").goal, "build a parser")
        XCTAssertEqual(KistREPL.parseEffortArgs("ultra fix the crash").startLevel, 4)
        XCTAssertEqual(KistREPL.parseEffortArgs("ultra fix the crash").goal, "fix the crash")
        XCTAssertEqual(KistREPL.parseEffortArgs("gauntlet ship it").startLevel, 4)
        XCTAssertEqual(KistREPL.parseEffortArgs("3 add tests").startLevel, 3)
    }

    func testNoLevelTokenStartsAtOneAndKeepsWholeGoal() {
        let r = KistREPL.parseEffortArgs("build a parser for X")
        XCTAssertEqual(r.startLevel, 1)
        XCTAssertEqual(r.goal, "build a parser for X")   // "build" is NOT mistaken for a level
    }

    func testEmptyArgs() {
        XCTAssertEqual(KistREPL.parseEffortArgs("").startLevel, 1)
        XCTAssertEqual(KistREPL.parseEffortArgs("   ").goal, "")
    }

    func testRungNamesEscalate() {
        XCTAssertTrue(EscalatingBuildDecider.levelName(1).contains("solo"))
        XCTAssertTrue(EscalatingBuildDecider.levelName(2).contains("reviewer"))
        XCTAssertTrue(EscalatingBuildDecider.levelName(3).contains("rater"))
        XCTAssertTrue(EscalatingBuildDecider.levelName(4).lowercased().contains("ultra"))
        XCTAssertTrue(EscalatingBuildDecider.levelName(99).lowercased().contains("ultra")) // clamps up
    }
}
