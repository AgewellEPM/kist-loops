import XCTest
@testable import AgentCore

/// The fleet planner's PARSE is the deterministic core (the model call is a thin wrapper). It must be
/// tolerant of fences/prose, fill optional fields, and skip junk — while never inventing a subtask.
final class FleetPlannerTests: XCTestCase {

    func testParsesCleanArray() {
        let json = #"""
        [{"title":"parser","intent":"build the parser","scopeGlobs":["Core/*"],"acceptanceCriterion":"parses a plan"},
         {"title":"lexer","intent":"build the lexer","scopeGlobs":["Lex/*"],"acceptanceCriterion":"tokenizes"}]
        """#
        let subs = FleetPlanner.parse(json)
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].title, "parser")
        XCTAssertEqual(subs[0].scopeGlobs, ["Core/*"])
        XCTAssertEqual(subs[1].acceptanceCriterion, "tokenizes")
    }

    func testStripsCodeFences() {
        let fenced = "```json\n[{\"title\":\"a\",\"intent\":\"do a\",\"scopeGlobs\":[\"X/*\"]}]\n```"
        let subs = FleetPlanner.parse(fenced)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].scopeGlobs, ["X/*"])
    }

    func testExtractsArrayFromSurroundingProse() {
        let prose = "Sure! Here is the plan:\n[{\"title\":\"a\",\"intent\":\"do a\"}]\nLet me know if you want changes."
        let subs = FleetPlanner.parse(prose)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].intent, "do a")
        XCTAssertTrue(subs[0].scopeGlobs.isEmpty, "missing scope defaults to empty (validated → permissive)")
    }

    func testExtractsArrayAfterBracketedProse() {
        let prose = "Plan [draft]:\n[{\"title\":\"a\",\"intent\":\"do a\",\"scopeGlobs\":[\"Core/*\"]}]\n[note]"
        let subs = FleetPlanner.parse(prose)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].scopeGlobs, ["Core/*"])
    }

    func testIgnoresBracketsInsideJSONString() {
        let prose = #"Here: [{"title":"a","intent":"write [safe] parsing","scopeGlobs":["Core/*"]}] trailing [noise]"#
        let subs = FleetPlanner.parse(prose)
        XCTAssertEqual(subs.count, 1)
        XCTAssertEqual(subs[0].intent, "write [safe] parsing")
    }

    func testFallsBackTitleToIntentAndSkipsEmpty() {
        let json = #"[{"intent":"only an intent"},{"scopeGlobs":["X/*"]},{"title":"t2","intent":"i2"}]"#
        let subs = FleetPlanner.parse(json)
        // element 1: intent only → title derived from intent; element 2: no intent/title → SKIPPED;
        // element 3: full.
        XCTAssertEqual(subs.count, 2)
        XCTAssertEqual(subs[0].intent, "only an intent")
        XCTAssertFalse(subs[0].title.isEmpty, "title falls back to a prefix of the intent")
        XCTAssertEqual(subs[1].title, "t2")
    }

    func testAliasToleratesLiveFileActionShape() {
        // The exact shape a live openai run emitted (a file-creation plan, not our schema): {scope,
        // action,file,content}. Must still yield a usable subtask, not get skipped.
        let json = #"""
        [{"scope":"","action":"create","file":"Strings/Reverse.swift","content":"func reverse() {}"}]
        """#
        let subs = FleetPlanner.parse(json)
        XCTAssertEqual(subs.count, 1, "a file-action element is parsed via aliases, not skipped")
        XCTAssertEqual(subs[0].title, "Strings/Reverse.swift", "title falls back to the file")
        XCTAssertTrue(subs[0].intent.contains("create") || subs[0].intent.contains("Reverse"), "intent from action/file")
        XCTAssertEqual(subs[0].scopeGlobs, ["Strings/*"], "scope derived from the file's directory")
    }

    func testGarbageReturnsEmpty() {
        XCTAssertTrue(FleetPlanner.parse("not json at all").isEmpty)
        XCTAssertTrue(FleetPlanner.parse("{\"not\":\"an array\"}").isEmpty)
        XCTAssertTrue(FleetPlanner.parse("").isEmpty)
    }

    func testExtractJSONArrayHelper() {
        XCTAssertEqual(FleetPlanner.extractJSONArray("x [1,2] y"), "[1,2]")
        XCTAssertNil(FleetPlanner.extractJSONArray("no brackets"))
        XCTAssertEqual(FleetPlanner.extractJSONArray("```\n[7]\n```"), "[7]")
        XCTAssertEqual(FleetPlanner.extractJSONArray("noise [draft] [{\"x\":\"[ok]\"}] tail [n]"), #"[{"x":"[ok]"}]"#)
    }
}
