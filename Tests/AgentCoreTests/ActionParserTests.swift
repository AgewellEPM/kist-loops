import XCTest
@testable import AgentCore

/// Adversarial fuzz corpus for `ActionParser` — the single most load-bearing function in the TEXT
/// protocol. Every provider (including local models with no native tool-calling) flows through it, so
/// each case here pins a real failure mode: prose braces, stringified `done`, fences, trailing text,
/// nested wrappers, and garbage that must fail CLEANLY (nil) rather than mis-dispatch.
final class ActionParserTests: XCTestCase {

    // MARK: - Baseline shapes (parity with the pre-hardening behavior)

    func testPlainActionObject() {
        let a = ActionParser.parse(#"{"thinking":"t","tool":"read_file","parameters":{"path":"x"}}"#)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "x")
        XCTAssertEqual(a?.done, false)
    }

    func testFencedJSON() {
        let a = ActionParser.parse("```json\n{\"tool\":\"list_files\",\"parameters\":{}}\n```")
        XCTAssertEqual(a?.tool, "list_files")
    }

    func testNestedNextActionDone() {
        let a = ActionParser.parse(#"{"thinking":"t","next_action":{"type":"done"},"summary":"fin"}"#)
        XCTAssertEqual(a?.done, true)
        XCTAssertEqual(a?.summary, "fin")
    }

    func testBraceInsideStringValue() {
        // A brace inside a JSON string must not terminate the object early.
        let a = ActionParser.parse(#"{"tool":"run_command","parameters":{"command":"echo {hi}"}}"#)
        XCTAssertEqual(a?.tool, "run_command")
        XCTAssertEqual(a?.parameters["command"] as? String, "echo {hi}")
    }

    func testTrailingProseAfterObject() {
        let a = ActionParser.parse(#"{"done":true,"summary":"ok"} — hope that helps!"#)
        XCTAssertEqual(a?.done, true)
        XCTAssertEqual(a?.summary, "ok")
    }

    // MARK: - Prose-only / non-actionable must fail cleanly (nil), never mis-dispatch

    func testProseOnlyReturnsNil() {
        XCTAssertNil(ActionParser.parse("I think I should read the file first."))
    }

    func testMusingObjectWithNoActionReturnsNil() {
        XCTAssertNil(ActionParser.parse(#"{"thinking":"just musing, no action"}"#))
    }

    // MARK: - THE hardening cases: a prose brace BEFORE the real action

    func testInvalidProseBraceBeforeAction() {
        // `{timeout: 30}` is not valid JSON; the old first-brace grab would fail the whole parse.
        let raw = #"I'll update the {timeout: 30} config. {"tool":"read_file","parameters":{"path":"c"}}"#
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "c")
    }

    func testValidNonActionBraceBeforeAction() {
        // `{"timeout": 30}` IS valid JSON but not an action; must be skipped in favor of the real action.
        let raw = #"The config {"timeout": 30} should change. {"tool":"search_code","parameters":{"q":"x"}}"#
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "search_code")
    }

    func testActionableObjectPreferredOverEarlierPlainObject() {
        let raw = #"{"note":"context"} then {"done":true,"summary":"finished"}"#
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.done, true)
        XCTAssertEqual(a?.summary, "finished")
    }

    // MARK: - Council regressions (Codex round 1) — these must never come back

    func testUnbalancedQuoteInProseBeforeObject() {
        // HIGH regression: an unbalanced quote in prose must not swallow the real opening brace.
        let raw = #"The key "timeout is missing. {"tool":"read_file","parameters":{"path":"c"}}"#
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "c")
        // extractJSONObject (AgentHooks/PlanParser/PlanExecuteLoop) must also survive it.
        XCTAssertEqual(ActionParser.extractJSONObject(raw), #"{"tool":"read_file","parameters":{"path":"c"}}"#)
    }

    func testExampleInFenceThenRealActionAfter() {
        // HIGH regression: a fenced EXAMPLE followed by the real action must expose both; last wins.
        let raw = "Example:\n```json\n{\"tool\":\"bad_tool\",\"parameters\":{}}\n```\nActual:\n{\"tool\":\"read_file\",\"parameters\":{\"path\":\"c\"}}"
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
    }

    func testActionShapedProseBeforeRealAction() {
        // "Do not run {X}. Instead {Y}." must dispatch Y, not X.
        let raw = #"Do not run {"tool":"write_file","parameters":{"path":"a"}}. Instead {"tool":"read_file","parameters":{"path":"b"}}"#
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "b")
    }

    func testStringifiedParametersAreParsed() {
        // Some providers stringify the params object; parse it rather than dispatch empty args.
        let a = ActionParser.parse(#"{"tool":"write_file","parameters":"{\"path\":\"x\",\"content\":\"y\"}"}"#)
        XCTAssertEqual(a?.tool, "write_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "x")
        XCTAssertEqual(a?.parameters["content"] as? String, "y")
    }

    func testMalformedParametersOnToolFailsClosed() {
        // A tool dispatch with present-but-unparseable params must FAIL (nil), not run with empty args.
        XCTAssertNil(ActionParser.parse(#"{"tool":"write_file","parameters":"not json at all"}"#))
    }

    func testDoneOnlyToleratesJunkParameters() {
        // A done-only action doesn't need params, so junk params must not reject the completion.
        let a = ActionParser.parse(#"{"done":true,"summary":"ok","parameters":"whatever"}"#)
        XCTAssertEqual(a?.done, true)
        XCTAssertEqual(a?.summary, "ok")
    }

    func testDoneStringWithTrailingNewlineCompletes() {
        let a = ActionParser.parse("{\"done\":\"true\\n\",\"summary\":\"s\"}")
        XCTAssertEqual(a?.done, true)
    }

    func testSummaryInsideWrapperParameters() {
        let a = ActionParser.parse(#"{"next_action":{"type":"done","parameters":{"summary":"finished"}}}"#)
        XCTAssertEqual(a?.done, true)
        XCTAssertEqual(a?.summary, "finished")
    }

    func testNoParametersKeyIsValidEmpty() {
        // list_files-style: no params key at all is valid and yields empty params, not a reject.
        let a = ActionParser.parse(#"{"tool":"list_files"}"#)
        XCTAssertEqual(a?.tool, "list_files")
        XCTAssertEqual(a?.parameters.isEmpty, true)
    }

    // MARK: - Council regressions (Codex round 2)

    func testMalformedLastActionDoesNotFallBackToFencedExample() {
        // HIGH: a fenced valid example followed by a bare MALFORMED real action must FAIL CLOSED,
        // not dispatch the stale example.
        let raw = "Example:\n```json\n{\"tool\":\"bad_tool\",\"parameters\":{}}\n```\n{\"tool\":\"write_file\",\"parameters\":\"not json\"}"
        XCTAssertNil(ActionParser.parse(raw))
    }

    func testBareActionBeatsTrailingFencedExample() {
        // MED symmetric bug: a real bare action followed by a fenced example must dispatch the bare one.
        let raw = "{\"tool\":\"read_file\",\"parameters\":{\"path\":\"real\"}}\nFor reference:\n```json\n{\"tool\":\"delete_all\",\"parameters\":{}}\n```"
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "real")
    }

    func testSoleFencedActionStillDispatches() {
        // Models often wrap their ONLY action in a fence despite the contract; that must still work.
        let a = ActionParser.parse("```json\n{\"tool\":\"list_files\",\"parameters\":{}}\n```")
        XCTAssertEqual(a?.tool, "list_files")
    }

    func testStringifiedWrapperParamsSummaryRecovered() {
        // LOW: summary inside stringified wrapper params must still be recovered.
        let a = ActionParser.parse(#"{"next_action":{"type":"done","parameters":"{\"summary\":\"finished\"}"}}"#)
        XCTAssertEqual(a?.done, true)
        XCTAssertEqual(a?.summary, "finished")
    }

    // MARK: - Declined findings pinned as intended behavior (Codex round 2)

    func testTypeIsDoneMarkerOnly_NotDispatchedAsTool() {
        // Declined #5: `type` is never a tool name. A control object with type:"message" and no tool
        // must NOT become a dispatch of a nonexistent "message" tool — it has no actionable signal.
        XCTAssertNil(ActionParser.parse(#"{"type":"message","message":"hello"}"#))
    }

    func testWhitespaceParamsTreatedAsAbsent_NotMalformed() {
        // Declined: an empty/whitespace params string is "no params", so no-arg tools aren't falsely
        // rejected; the tool layer enforces per-tool required args.
        let a = ActionParser.parse(#"{"tool":"list_files","parameters":"   "}"#)
        XCTAssertEqual(a?.tool, "list_files")
        XCTAssertEqual(a?.parameters.isEmpty, true)
    }

    // MARK: - Council regressions (Codex round 3)

    func testInvalidJSONActionAfterFencedExampleFailsClosed() {
        // HIGH: a bare object that is INVALID JSON but action-shaped must fail closed, not fall back
        // to a fenced example.
        let raw = "```json\n{\"tool\":\"safe\",\"parameters\":{}}\n```\n{\"tool\":\"write_file\",\"parameters\":}"
        XCTAssertNil(ActionParser.parse(raw))
    }

    func testNonStringToolFailsClosed() {
        // HIGH class: a numeric tool is a malformed action attempt, not prose.
        XCTAssertNil(ActionParser.parse(#"{"tool":123,"parameters":{}}"#))
    }

    func testBareDoneFalseNoToolFailsClosedOverEarlierAction() {
        // HIGH: a trailing `{"done":false}` (intent, no tool) must nudge, not let an earlier action win.
        let raw = #"Do not run {"tool":"write_file","parameters":{"path":"x"}}. {"done":false}"#
        XCTAssertNil(ActionParser.parse(raw))
    }

    func testTypeDoneWithToolDispatchesToolNotCompletion() {
        // MED: `type:"done"` alongside a real tool must dispatch the tool, not complete early.
        let a = ActionParser.parse(#"{"tool":"read_file","type":"done","parameters":{"path":"x"}}"#)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.done, false)
    }

    func testTildeFencedExampleLosesToBareAction() {
        // MED: ~~~ fences are fences too; a bare action must beat a tilde-fenced example.
        let raw = "{\"tool\":\"read_file\",\"parameters\":{\"path\":\"real\"}}\n~~~\n{\"tool\":\"delete_all\",\"parameters\":{}}\n~~~"
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
    }

    func testFourBacktickFenceNotClosedByInnerTriple() {
        // MED: a 4-backtick fence isn't closed by an inner 3-backtick run, so the inner example stays
        // fenced and the bare action outside wins.
        let raw = "````markdown\n```\n{\"tool\":\"delete_all\",\"parameters\":{}}\n```\n````\n{\"tool\":\"read_file\",\"parameters\":{\"path\":\"real\"}}"
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
    }

    // MARK: - Council regressions (Codex round 4)

    func testTruncatedFinalActionFailsClosed() {
        // HIGH: a truncated (unterminated) final action must fail closed, not fall back to an example.
        let raw = "```json\n{\"tool\":\"safe\",\"parameters\":{}}\n```\n{\"tool\":\"read_file\",\"parameters\":{\"path\":\"README.md\"}"
        XCTAssertNil(ActionParser.parse(raw))
    }

    func testTrailingBraceWithoutIntentDoesNotFailClosed() {
        // A truncated tail that ISN'T action-shaped must not suppress a valid earlier action.
        let raw = "{\"tool\":\"read_file\",\"parameters\":{\"path\":\"x\"}}\nnote: {incomplete prose"
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "read_file")
    }

    func testUnquotedKeyFinalActionNowParsesViaRelaxer() {
        // A JS-literal final action (unquoted keys) after a fenced example: relaxed parsing makes it a
        // real, dispatchable action (superseding the earlier fail-closed behavior). The example loses.
        let raw = "```json\n{\"tool\":\"safe\",\"parameters\":{}}\n```\n{tool:\"read_file\",parameters:{path:\"x\"}}"
        XCTAssertEqual(ActionParser.parse(raw)?.tool, "read_file")
    }

    func testSingleQuotedKeyLiteralNowParses() {
        // A sole single-quoted-key literal now parses (local-model support) rather than nudging.
        XCTAssertEqual(ActionParser.parse(#"{'tool':'read_file','parameters':{}}"#)?.tool, "read_file")
    }

    func testProseWordEndingInIntentKeyIsNotIntent() {
        // Guard against over-eager raw detection: "mytool" must not register as a `tool` key.
        let a = ActionParser.parse(#"{"note":"mytool: not an action"} {"done":true,"summary":"ok"}"#)
        XCTAssertEqual(a?.done, true)
    }

    func testExplicitDoneTrueWithToolFailsClosed() {
        // MED: contradictory done:true + a real tool must nudge, not complete early.
        XCTAssertNil(ActionParser.parse(#"{"done":true,"tool":"write_file","parameters":{"path":"x"}}"#))
    }

    // MARK: - Council regression (Codex round 5) — type:"done" as raw intent

    func testTruncatedDoneMarkerFailsClosedOverExample() {
        // A truncated final `{"type":"done"` (a supported done marker) must fail closed, not let an
        // earlier example tool dispatch.
        let raw = "Example only: {\"tool\":\"write_file\",\"parameters\":{\"path\":\"x\",\"content\":\"stale\"}}\n{\"type\":\"done\""
        XCTAssertNil(ActionParser.parse(raw))
    }

    func testTrailingCommaDoneMarkerNeverDispatchesStaleExample() {
        // `{"type":"done",}` may parse (lenient) as done or fail closed (strict) depending on platform
        // JSON leniency; the platform-independent invariant is that the stale example NEVER dispatches.
        let raw = "Example only: {\"tool\":\"write_file\",\"parameters\":{\"path\":\"x\"}}\n{\"type\":\"done\",}"
        XCTAssertNotEqual(ActionParser.parse(raw)?.tool, "write_file")
    }

    // MARK: - Stringified `done` (text-protocol models emit all three forms)

    func testStringDoneTrue() {
        let a = ActionParser.parse(#"{"done":"true","summary":"done via string"}"#)
        XCTAssertEqual(a?.done, true)
    }

    func testStringDoneYes() {
        let a = ActionParser.parse(#"{"done":"yes","summary":"y"}"#)
        XCTAssertEqual(a?.done, true)
    }

    func testStringDoneFalseWithTool() {
        // "false" done must not complete the run; the tool keeps it actionable.
        let a = ActionParser.parse(#"{"done":"false","tool":"read_file","parameters":{}}"#)
        XCTAssertEqual(a?.done, false)
        XCTAssertEqual(a?.tool, "read_file")
    }

    func testStringDoneFalseBeatsTypeDone() {
        // Explicit stringified false must win over a stray type:done so a run isn't falsely completed.
        let a = ActionParser.parse(#"{"done":"false","type":"done","tool":"read_file","parameters":{}}"#)
        XCTAssertEqual(a?.done, false)
    }

    // MARK: - Alternate key shapes (name/input)

    func testNameAndInputAliases() {
        let a = ActionParser.parse(#"{"name":"glob_files","input":{"pattern":"**/*.swift"}}"#)
        XCTAssertEqual(a?.tool, "glob_files")
        XCTAssertEqual(a?.parameters["pattern"] as? String, "**/*.swift")
    }

    // MARK: - Garbage / malformed must never crash and must return nil

    func testGarbageInputs() {
        for junk in ["", "{", "}", "{{{{", "}}}}", "{\"tool\":", "null", "[]", "[1,2,3]", "```json\n```",
                     "{\"tool\":\"x\" \"parameters\"}", "\u{0}\u{1}garbage"] {
            // Must not crash; result is either nil or a well-formed Action, never a partial dispatch.
            _ = ActionParser.parse(junk)
        }
        XCTAssertNil(ActionParser.parse("[1,2,3]"))
        XCTAssertNil(ActionParser.parse("{"))
    }

    func testDeeplyNestedParametersPreserved() {
        let raw = #"{"tool":"x","parameters":{"a":{"b":{"c":[1,2,{"d":"e"}]}}}}"#
        let a = ActionParser.parse(raw)
        XCTAssertEqual(a?.tool, "x")
        let inner = ((a?.parameters["a"] as? [String: Any])?["b"] as? [String: Any])?["c"] as? [Any]
        XCTAssertEqual(inner?.count, 3)
    }

    // MARK: - extractJSONObject compat (AgentHooks / PlanParser / PlanExecuteLoop rely on it)

    func testExtractJSONObjectReturnsFirstBalancedObject() {
        let raw = #"prefix {"a":1} suffix {"b":2}"#
        XCTAssertEqual(ActionParser.extractJSONObject(raw), #"{"a":1}"#)
    }

    func testExtractJSONObjectNilWhenNoObject() {
        XCTAssertNil(ActionParser.extractJSONObject("no braces here"))
    }

    func testCandidateEnumerationCountsTopLevelOnly() {
        let raw = #"{"outer":{"inner":1}} and {"second":2}"#
        XCTAssertEqual(ActionParser.candidateJSONObjects(raw).count, 2)
    }
}

/// Relaxed-JSON parsing for local models (JS/Python-literal drift). A pure fallback: only turns a
/// previously-unparseable action into a parsed one — it must NEVER corrupt a valid strict parse.
final class ActionParserRelaxedTests: XCTestCase {

    func testSingleQuotedStringsParse() {
        let a = ActionParser.parse(#"{'tool':'read_file','parameters':{'path':'README.md'}}"#)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "README.md")
    }

    func testUnquotedKeysParse() {
        let a = ActionParser.parse(#"{tool:"read_file",parameters:{path:"x"}}"#)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "x")
    }

    func testPythonLiteralsParse() {
        let a = ActionParser.parse(#"{"tool":"toggle","parameters":{"on":True,"off":False,"extra":None}}"#)
        XCTAssertEqual(a?.tool, "toggle")
        XCTAssertEqual(a?.parameters["on"] as? Bool, true)
        XCTAssertEqual(a?.parameters["off"] as? Bool, false)
        XCTAssertTrue(a?.parameters["extra"] is NSNull)
    }

    func testTrailingCommasStripped() {
        let a = ActionParser.parse(#"{"tool":"read_file","parameters":{"path":"x",},}"#)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["path"] as? String, "x")
    }

    func testMixedRelaxedShape() {
        let a = ActionParser.parse("{tool:'read_file', parameters:{path:'a', recursive:True,},}")
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["recursive"] as? Bool, true)
    }

    func testRepeatedMidCommaNotSilentlyRepaired() {
        // Council HIGH: `[1,,2]` is a genuine error (dropped element), not a style deviation. It must
        // stay invalid and fail closed — NOT be silently collapsed to [1,2] and dispatched.
        XCTAssertNil(ActionParser.parse(#"{"tool":"x","parameters":{"arr":[1,,2]}}"#))
    }

    func testTrailingCommaStillStrippedAfterFix() {
        // The legitimate single-trailing-comma case must still work after the repeated-comma fix.
        let a = ActionParser.parse(#"{tool:"read_file",parameters:{path:"x",},}"#)
        XCTAssertEqual(a?.tool, "read_file")
    }

    func testEmptyMemberShapesFailClosed() {
        // Council round 2: empty-member comma shapes must fail closed, not be silently repaired.
        XCTAssertNil(ActionParser.parse(#"{"tool":"x","parameters":{"arr":[1,,]}}"#))
        XCTAssertNil(ActionParser.parse(#"{"tool":"x","parameters":{"arr":[,]}}"#))
        XCTAssertNil(ActionParser.parse(#"{"tool":"x","parameters":{,}}"#))
        XCTAssertNil(ActionParser.parse(#"{"tool":"x","parameters":{"a":1,,}}"#))
    }

    // MARK: - Must NOT corrupt valid string CONTENTS

    func testValidStringContainingBraceCommaColonUntouched() {
        let a = ActionParser.parse(#"{"tool":"run_command","parameters":{"command":"echo {a:1, b:2},}"}}"#)
        XCTAssertEqual(a?.parameters["command"] as? String, "echo {a:1, b:2},}")
    }

    func testStringContainingPythonWordsUntouched() {
        // The words True/None inside a real string must survive verbatim (strict parse; relaxer not even invoked).
        let a = ActionParser.parse(#"{"tool":"say","parameters":{"text":"True story, None the wiser"}}"#)
        XCTAssertEqual(a?.parameters["text"] as? String, "True story, None the wiser")
    }

    func testStringWithApostropheInDoubleQuotesUntouched() {
        let a = ActionParser.parse(#"{"tool":"say","parameters":{"text":"it's a trap: {x}"}}"#)
        XCTAssertEqual(a?.parameters["text"] as? String, "it's a trap: {x}")
    }

    func testSingleQuotedValueWithInnerDoubleQuote() {
        let a = ActionParser.parse("{'tool':'say','parameters':{'text':'he said \"hi\"'}}")
        XCTAssertEqual(a?.parameters["text"] as? String, "he said \"hi\"")
    }

    func testStrictParseUnaffectedByRelaxer() {
        // A perfectly valid strict object must parse identically (relaxer never runs).
        let a = ActionParser.parse(#"{"tool":"read_file","parameters":{"path":"a/b.txt","n":3}}"#)
        XCTAssertEqual(a?.tool, "read_file")
        XCTAssertEqual(a?.parameters["n"] as? Int, 3)
    }

    func testNormalizerLeavesValidJSONByteIdentical() {
        // Idempotence guard on already-strict JSON (aside from insignificant whitespace it shouldn't add).
        let strict = #"{"tool":"x","parameters":{"a":"b,c}","n":True}}"#
        // Only True should change; the string "b,c}" must be preserved.
        let normalized = ActionParser.normalizeRelaxedJSON(strict)
        XCTAssertTrue(normalized.contains(#""b,c}""#))
        XCTAssertTrue(normalized.contains("true"))
        XCTAssertFalse(normalized.contains("True"))
    }
}

/// AgentHooks decision fail-safe (Codex round 4) — a block hidden behind an earlier object must win.
final class AgentHooksDecisionTests: XCTestCase {
    func testBlockBehindLeadingLogObjectStillBlocks() {
        let d = AgentHooks.decision(fromOutput: "debug {\"note\":\"x\"}\n{\"block\":true,\"reason\":\"policy\"}")
        XCTAssertEqual(d?.blocked, true)
        XCTAssertEqual(d?.reason, "policy")
    }

    func testAnyBlockWinsOverLaterAllow() {
        let d = AgentHooks.decision(fromOutput: "{\"block\":true,\"reason\":\"no\"} {\"block\":false}")
        XCTAssertEqual(d?.blocked, true)
    }

    func testNoDecisionObjectReturnsNil() {
        XCTAssertNil(AgentHooks.decision(fromOutput: "just logs, no decision"))
    }
}
