import XCTest
@testable import AgentCore

final class ControlIntentParserTests: XCTestCase {
    let known = ["deepseek": "deepseek", "gemini": "gemini", "mimo": "mimo", "openai": "openai",
                 "claude": "anthropic", "anthropic": "anthropic"]

    private func parse(_ s: String) -> ControlIntentParser.Intent? {
        ControlIntentParser.parse(s, knownProviders: known)
    }
    private func roles(_ intent: ControlIntentParser.Intent?) -> [AgentRole: String] {
        guard case .setRoles(let rs)? = intent?.action else { return [:] }
        return Dictionary(uniqueKeysWithValues: rs.map { ($0.role, $0.binding.providerId) })
    }
    private func model(_ intent: ControlIntentParser.Intent?) -> String? {
        if case .setModel(let b)? = intent?.action { return b.providerId }; return nil
    }

    // MARK: Luke's exact examples

    func testRoleAssignmentSingle() {
        let i = parse("Use DeepSeek as the builder")
        XCTAssertEqual(roles(i)[.coder], "deepseek")
        XCTAssertTrue(i!.isControlOnly)
    }

    func testTeamTwoRoles() {
        let i = parse("use DeepSeek as builder and Gemini as critic")
        XCTAssertEqual(roles(i)[.coder], "deepseek")
        XCTAssertEqual(roles(i)[.critic], "gemini")
        XCTAssertTrue(i!.isControlOnly)
    }

    func testHaveGeminiReviewThis() {
        let i = parse("Have Gemini review this")
        XCTAssertEqual(roles(i)[.critic], "gemini")
        XCTAssertEqual(i?.residualTask, "review this")     // the task survives
        XCTAssertFalse(i!.isControlOnly)
    }

    func testMakeMiMoCodeIt() {
        let i = parse("Make MiMo code it")
        XCTAssertEqual(roles(i)[.coder], "mimo")
        XCTAssertEqual(i?.residualTask, "code it")
    }

    func testBringInMiMoToBuildKeepsOnlyTheBuildTask() {
        let i = parse("bring in mimo to build this all now")
        XCTAssertEqual(roles(i)[.coder], "mimo")
        XCTAssertEqual(i?.residualTask, "build this all now")
    }

    func testSingleRoleVerbMappings() {
        XCTAssertEqual(roles(parse("have Gemini critique this"))[.critic], "gemini")
        XCTAssertEqual(roles(parse("use DeepSeek to implement this"))[.coder], "deepseek")
        XCTAssertEqual(roles(parse("let MiMo research this"))[.worker], "mimo")
        XCTAssertEqual(roles(parse("ask MiMo to build the fix"))[.coder], "mimo")
        XCTAssertEqual(roles(parse("call Gemini to review it"))[.critic], "gemini")
        XCTAssertEqual(roles(parse("have OpenAI architect the migration"))[.planner], "openai")
    }

    func testSwitchToGeminiForNextTask() {
        let i = parse("Switch to Gemini for this next task")
        XCTAssertEqual(model(i), "gemini")
        XCTAssertTrue(i!.isControlOnly)                    // "for this next task" is not a task
    }

    func testTwoAgentsWithVerbsIsTeam() {
        let i = parse("Use DeepSeek to run these tests, then Gemini to critique")
        XCTAssertEqual(roles(i)[.coder], "deepseek")       // run → coder
        XCTAssertEqual(roles(i)[.critic], "gemini")        // critique → critic
    }

    func testSwitchBare() {
        XCTAssertEqual(model(parse("switch to gemini")), "gemini")
        XCTAssertEqual(model(parse("use claude")), "anthropic")
    }

    // REGRESSION (live screenshot bug): "ask deepseek …" / "ask grok …" / "call claude …" printed
    // "routed to gemini (staying on current model)" instead of switching. A bare provider directly
    // after ask/call/bring is now a model switch, with the rest kept as the task.
    func testAskBareProviderSwitchesModelAndKeepsTask() {
        let i = parse("ask deepseek to look at this crash")
        // "to look" is not a role verb, so this is a plain model switch, not a role bind.
        XCTAssertEqual(model(i), "deepseek")
        XCTAssertEqual(i?.residualTask, "look at this crash")
    }

    func testAskGrokAndCallClaudeSwitchModel() {
        let known2 = ["deepseek": "deepseek", "gemini": "gemini", "grok": "grok",
                      "claude": "anthropic", "anthropic": "anthropic"]
        func modelOf(_ s: String) -> String? {
            if case .setModel(let b)? = ControlIntentParser.parse(s, knownProviders: known2)?.action { return b.providerId }
            return nil
        }
        XCTAssertEqual(modelOf("ask grok what it thinks"), "grok")
        XCTAssertEqual(modelOf("call claude on this one"), "anthropic")
    }

    // MARK: false positives — these must NOT change runtime bindings

    func testNormalBuildRequestNoIntent() {
        XCTAssertNil(parse("build a login page with validation"))
        XCTAssertNil(parse("research the best database for this"))
    }

    func testProviderInObjectPositionNoIntent() {
        XCTAssertNil(parse("research the gemini api docs"))      // gemini is the object, not the agent
        XCTAssertNil(parse("explain how the openai sdk works"))
    }

    func testProviderProductMentionsAreNotRoleDirectives() {
        XCTAssertNil(parse("is it like claude code terminal"))
        XCTAssertNil(parse("compare our system with claude code and codex"))
        XCTAssertNil(parse("built with gemini support"))
    }

    func testWeakProviderMentionsDoNotBareSwitch() {
        XCTAssertNil(parse("my own claude code should feel conversational"))
        XCTAssertNil(parse("have the gemini api docs open"))
    }

    // REGRESSION (the screenshot bug): a casual mention of a provider next to a verb-word must NOT be
    // read as a command. "claude code" is the product name, not "make anthropic the coder".
    func testCasualProviderMentionIsNotADirective() {
        XCTAssertNil(parse("you know i built you, this is sick, my own claude code terminal"))
        XCTAssertNil(parse("i love that this is a claude code style terminal"))
        XCTAssertNil(parse("this whole thing was built with gemini and it's awesome"))
        XCTAssertNil(parse("the openai api is confusing but mimo is fast"))
        XCTAssertNil(parse("claude code is my favorite tool"))
    }

    func testNoProviderNoIntent() {
        XCTAssertNil(parse("split this into smaller tasks"))
        XCTAssertNil(parse("write the tests then review them"))  // no provider named
    }

    func testEmptyKnownProvidersNeverFires() {
        XCTAssertNil(ControlIntentParser.parse("use deepseek as builder", knownProviders: [:]))
    }

    // MARK: settings by talking

    private func setting(_ i: ControlIntentParser.Intent?) -> ControlIntentParser.Setting? {
        if case .setting(let s)? = i?.action { return s }; return nil
    }
    func testPlanModeByTalking() {
        XCTAssertEqual(setting(parse("go read-only and just propose a plan")), .planMode(true))
        XCTAssertEqual(setting(parse("exit plan mode")), .planMode(false))
        XCTAssertEqual(setting(parse("don't make changes, dry run only")), .planMode(true))
    }
    func testReasoningByTalking() {
        XCTAssertEqual(setting(parse("show your reasoning")), .reasoning(true))
        XCTAssertEqual(setting(parse("hide reasoning")), .reasoning(false))
    }
    func testSettingsAreControlOnly() {
        XCTAssertTrue(parse("plan mode")!.isControlOnly)
    }
    func testNormalMessageIsNotASetting() {
        XCTAssertNil(parse("write a plan for the migration"))   // "plan" alone isn't "plan mode"
    }

    // MARK: team + task → residual is the task (REPL runs it via plan-execute)

    func testTeamWithTaskKeepsResidual() {
        let i = parse("use DeepSeek as builder and Gemini as critic then run the tests")
        XCTAssertEqual(roles(i)[.coder], "deepseek")
        XCTAssertEqual(roles(i)[.critic], "gemini")
        XCTAssertEqual(i?.residualTask, "run the tests")
        XCTAssertFalse(i!.isControlOnly)
    }

    // MARK: canonicalization

    func testProviderAliasCanonicalized() {
        XCTAssertEqual(model(parse("switch to claude")), "anthropic")
    }
}
