import XCTest
import AgentCore
@testable import Kist

/// `/chain`, `/copilot`, and the `/model` picker — pure logic pinned without a terminal.
final class ChainCopilotPickerTests: XCTestCase {

    // MARK: ChainParser

    func testChainSplitsOnPipe() {
        XCTAssertEqual(ChainParser.parse("a | b | c"), ["a", "b", "c"])
    }

    func testChainStripsQuotesAndTrims() {
        XCTAssertEqual(ChainParser.parse(#" "scaffold the parser" |  'add tests' "#),
                       ["scaffold the parser", "add tests"])
    }

    func testChainQuoteProtectsPipe() {
        // A pipe INSIDE quotes is part of the task, not a separator.
        XCTAssertEqual(ChainParser.parse(#" "delete the | char" | ship "#),
                       ["delete the | char", "ship"])
    }

    func testChainDropsEmptySegments() {
        XCTAssertEqual(ChainParser.parse("a | | b |"), ["a", "b"])
    }

    func testChainNewlineSeparated() {
        XCTAssertEqual(ChainParser.parse("first\nsecond\nthird"), ["first", "second", "third"])
    }

    func testChainSingleTask() {
        XCTAssertEqual(ChainParser.parse("just one thing"), ["just one thing"])
    }

    // MARK: Copilot — command parsing

    func testCopilotParsesToggles() {
        XCTAssertEqual(Copilot.parseCommand(""), .status)
        XCTAssertEqual(Copilot.parseCommand("status"), .status)
        XCTAssertEqual(Copilot.parseCommand("on"), .on)
        XCTAssertEqual(Copilot.parseCommand("OFF"), .off)
    }

    func testCopilotParsesRoleAssignments() {
        XCTAssertEqual(Copilot.parseCommand("lead openai:gpt-5.5"), .setLead("openai:gpt-5.5"))
        XCTAssertEqual(Copilot.parseCommand("co gemini"), .setCo("gemini"))
        XCTAssertEqual(Copilot.parseCommand("reviewer deepseek"), .setCo("deepseek"))   // reviewer == co
        XCTAssertEqual(Copilot.parseCommand("lead"), .invalid)                          // missing spec
        XCTAssertEqual(Copilot.parseCommand("wat"), .invalid)
    }

    // MARK: Copilot — review triggers only on a successful mutation

    func testCopilotReviewsOnlyAfterSuccessfulMutation() {
        let mutated = [ActionRecord(tool: "read_file", argsFingerprint: "a", success: true),
                       ActionRecord(tool: "write_file", argsFingerprint: "b", success: true)]
        XCTAssertTrue(Copilot.shouldReview(trajectory: mutated))

        let readOnly = [ActionRecord(tool: "read_file", argsFingerprint: "a", success: true),
                        ActionRecord(tool: "run_command", argsFingerprint: "ls", success: true)]
        XCTAssertFalse(Copilot.shouldReview(trajectory: readOnly), "no file mutation ⇒ nothing to review")

        let failedWrite = [ActionRecord(tool: "write_file", argsFingerprint: "b", success: false)]
        XCTAssertFalse(Copilot.shouldReview(trajectory: failedWrite), "a FAILED write changed nothing")

        XCTAssertFalse(Copilot.shouldReview(trajectory: []))
    }

    func testCopilotReviewPromptClipsHugeDiff() {
        let huge = String(repeating: "x", count: 50_000)
        let prompt = Copilot.reviewPrompt(task: "build", diff: huge, maxChars: 1_000)
        XCTAssertTrue(prompt.contains("truncated"))
        XCTAssertLessThan(prompt.count, 2_000)
        XCTAssertTrue(prompt.contains("build"))
    }

    func testCopilotStatusLineReflectsState() {
        var cfg = CopilotConfig()
        // Default: team mode off, but the advisory second opinion is ON (that's the default-on feature).
        XCTAssertTrue(cfg.statusLine(render: { $0.providerId }).contains("second opinion"))
        // Fully silenced only when the second opinion is also off.
        cfg.autoSecondOpinion = false
        XCTAssertTrue(cfg.statusLine(render: { $0.providerId }).contains("off"))
        // Team mode → the review→fix loop.
        cfg.enabled = true
        cfg.co = ProviderBinding(providerId: "gemini")
        let line = cfg.statusLine(render: { $0.providerId })
        XCTAssertTrue(line.contains("team"))
        XCTAssertTrue(line.contains("gemini"))
        XCTAssertTrue(line.contains("session model"))   // lead unset ⇒ session model
    }

    // MARK: ModelPicker — pure navigation/filter state

    private func demoEntries() -> [ModelPickerState.Entry] {
        [.init(providerId: "anthropic", model: "claude"),
         .init(providerId: "gemini", model: "gemini-2.5-flash"),
         .init(providerId: "openai", model: "gpt-5.5"),
         .init(providerId: "deepseek", model: "deepseek-chat")]
    }

    func testPickerMoveWraps() {
        var s = ModelPickerState(all: demoEntries(), initialSelection: 0)
        s.moveUp()
        XCTAssertEqual(s.current?.providerId, "deepseek", "up from the top wraps to the bottom")
        s.moveDown()
        XCTAssertEqual(s.current?.providerId, "anthropic", "down from the bottom wraps to the top")
    }

    func testPickerFilterNarrowsAndResetsCursor() {
        var s = ModelPickerState(all: demoEntries(), initialSelection: 2)   // openai
        s.type("g")   // matches "gemini" (label) and "gpt" — both contain 'g'? gemini yes, gpt yes via label "openai · gpt-5.5"
        XCTAssertEqual(s.cursor, 0, "typing resets to the first match")
        XCTAssertTrue(s.filtered.allSatisfy { $0.label.lowercased().contains("g") })
        // Narrow to exactly gemini.
        s.type("e"); s.type("m")
        XCTAssertEqual(s.filtered.count, 1)
        XCTAssertEqual(s.current?.providerId, "gemini")
    }

    func testPickerNoMatchHasNilCurrent() {
        var s = ModelPickerState(all: demoEntries())
        for c in "zzzz" { s.type(c) }
        XCTAssertTrue(s.filtered.isEmpty)
        XCTAssertNil(s.current)
        s.backspace(); s.backspace(); s.backspace(); s.backspace()
        XCTAssertEqual(s.filtered.count, 4, "clearing the filter restores the full list")
    }

    func testPickerEntriesDedupeAndListEveryModel() {
        let entries = ModelPicker.entries(
            providerModels: ["gemini": ["gemini-2.5-flash", "gemini-3.1-pro"], "openai": ["gpt-5.5"], "bare": []],
            providers: ["gemini", "openai", "bare"])
        // 2 gemini + 1 openai + 1 bare(default) = 4
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries.contains { $0.providerId == "bare" && $0.model == nil })
        XCTAssertTrue(entries.contains { $0.providerId == "gemini" && $0.model == "gemini-3.1-pro" })
    }

    func testPickerMarksKeyStatusAndFloatsKeyedToTop() {
        let keyed: Set<String> = ["gemini"]   // gemini has a key; openai does not
        let entries = ModelPicker.entries(
            providerModels: ["gemini": ["g1"], "openai": ["o1"]],
            providers: ["gemini", "openai"],
            hasKey: { keyed.contains($0) })
        XCTAssertEqual(entries.first?.providerId, "gemini", "keyed (green) providers float to the top")
        XCTAssertTrue(entries.first { $0.providerId == "gemini" }!.hasKey)
        XCTAssertFalse(entries.first { $0.providerId == "openai" }!.hasKey)
    }

    // MARK: copilot review diff — untracked NEW files must be reviewable

    /// Regression: `/copilot` used only `git diff HEAD`, which omits untracked files, so a turn that
    /// CREATED a file produced an empty diff and the co-reviewer saw nothing. `syntheticNewFileDiff`
    /// renders a new file as a `new file` unified-diff block so it reviews like any other change.
    func testSyntheticNewFileDiffRendersEveryLineAsAddition() {
        let diff = KistREPL.syntheticNewFileDiff(path: "Sources/Foo.swift",
                                                 content: "line one\nline two", maxChars: 10_000)
        XCTAssertTrue(diff.contains("diff --git a/Sources/Foo.swift b/Sources/Foo.swift"))
        XCTAssertTrue(diff.contains("new file"))
        XCTAssertTrue(diff.contains("--- /dev/null"))
        XCTAssertTrue(diff.contains("+++ b/Sources/Foo.swift"))
        XCTAssertTrue(diff.contains("+line one"))
        XCTAssertTrue(diff.contains("+line two"), "every line of a new file is an addition")
    }

    func testSyntheticNewFileDiffClipsHugeFile() {
        let huge = String(repeating: "x", count: 5_000)
        let diff = KistREPL.syntheticNewFileDiff(path: "big.txt", content: huge, maxChars: 100)
        XCTAssertTrue(diff.contains("[new file truncated at 100 chars]"))
        XCTAssertLessThan(diff.count, 400, "clipped, not the whole 5k file")
    }
}
