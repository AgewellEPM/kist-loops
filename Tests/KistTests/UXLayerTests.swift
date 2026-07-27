import XCTest
import AgentCore
import CoreGraphics
import ImageIO
@testable import Kist

final class UXLayerTests: XCTestCase {

    // MARK: TeamLanguage — plain language, not jargon (#4/#7)

    func testHomogeneousSessionHasNoTeamDescription() {
        let b = RoleBindings(default: ProviderBinding(providerId: "gemini"))
        XCTAssertTrue(TeamLanguage.isHomogeneous(b))
        XCTAssertNil(TeamLanguage.describeTeam(b))   // single model → no team line
    }

    func testTeamRendersInPlainLanguage() {
        let b = RoleBindings(default: ProviderBinding(providerId: "mimo"))
            .binding(.critic, to: ProviderBinding(providerId: "gemini"))
            .binding(.coder, to: ProviderBinding(providerId: "deepseek"))
        let desc = TeamLanguage.describeTeam(b)
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.contains("Gemini is reviewing"))
        XCTAssertTrue(desc!.contains("DeepSeek is building"))
        XCTAssertTrue(desc!.contains("MiMo is researching"))   // worker = default mimo
        XCTAssertFalse(desc!.contains("critic="))              // no jargon
    }

    func testDisplayNamesAreFriendly() {
        XCTAssertEqual(TeamLanguage.displayName("mimo"), "MiMo")
        XCTAssertEqual(TeamLanguage.displayName("anthropic"), "Claude")
        XCTAssertEqual(TeamLanguage.displayName("someprovider"), "Someprovider")
    }

    // MARK: ErrorHumanizer — recovery language, not status codes (#11)

    func testHumanizesCommonProviderErrors() {
        XCTAssertTrue(ErrorHumanizer.humanize("HTTP 401 Unauthorized", provider: "deepseek").contains("API key"))
        let rateLimit = ErrorHumanizer.humanize("429 rate limit exceeded", provider: "gemini")
        XCTAssertTrue(rateLimit.lowercased().contains("rate-limited"), rateLimit)
        XCTAssertTrue(rateLimit.contains("Captain will try an eligible replacement model"), rateLimit)
        let toolsErr = ErrorHumanizer.humanize("model does not support tools", provider: "deepseek")
        XCTAssertTrue(toolsErr.contains("text protocol"))
        XCTAssertTrue(toolsErr.contains("Nothing was lost"))
        let timeout = ErrorHumanizer.humanize("connection timed out", provider: "mimo")
        XCTAssertTrue(timeout.lowercased().contains("timed out"), timeout)
        XCTAssertTrue(timeout.contains("Captain will try an eligible replacement model"), timeout)
    }

    func testMalformedProviderErrorPointsAtCaptainSubstitution() {
        let h = ErrorHumanizer.humanize("HTTP 400 bad request malformed image_url expected text", provider: "mimo")
        XCTAssertTrue(h.contains("Captain will diagnose"), h)
        XCTAssertTrue(h.contains("eligible replacement model"), h)
        XCTAssertTrue(h.contains("when replay is safe"), h)
        XCTAssertFalse(h.contains("switch model with `/model`"), h)
    }

    func testServerProviderErrorPointsAtCaptainSubstitution() {
        let h = ErrorHumanizer.humanize("HTTP 503 server error", provider: "mimo")
        XCTAssertTrue(h.contains("Captain will try an eligible replacement model"), h)
        XCTAssertTrue(h.contains("when replay is safe"), h)
        XCTAssertFalse(h.contains("switch model with `/model`"), h)
    }

    func testUnknownErrorStillFramedNotRaw() {
        let h = ErrorHumanizer.humanize("weird internal blob xyz", tool: "write_file")
        XCTAssertTrue(h.contains("write_file"))
        XCTAssertTrue(h.lowercased().contains("retry") || h.lowercased().contains("nothing was committed"))
        XCTAssertFalse(h.hasPrefix("weird internal blob"))   // never a bare dump
    }

    // Regression (live --evolve dogfood): an error that already ends in "." must NOT render a double
    // period before "Nothing was committed" (seen: "…--sandbox.. Nothing was committed").
    func testNoDoublePeriodWhenErrorEndsWithPeriod() {
        let h = ErrorHumanizer.humanize("custom_tool.run requires the OS sandbox. Start with --auto.", tool: "custom_tool")
        XCTAssertFalse(h.contains(".."), "no double period before the recovery suffix: \(h)")
        XCTAssertTrue(h.contains("Nothing was committed"))
    }

    // Dogfood regression (Luke, screenshot): read_file missing a path printed
    // "The step didn't complete: not found: … Nothing was committed" — mutation framing on a read.
    func testReadNotFoundIsNotFramedAsUncommittedMutation() {
        let h = ErrorHumanizer.humanize("not found: .kist/runs/1782979476-fb0a93cf/plan.json", tool: "read_file")
        XCTAssertFalse(h.contains("Nothing was committed"), "a read that misses a path committed nothing to lose: \(h)")
        XCTAssertFalse(h.contains("didn't complete"), "missing path isn't a failed step: \(h)")
        XCTAssertTrue(h.contains("read_file"))
        XCTAssertTrue(h.contains("doesn't exist"))
        XCTAssertTrue(h.contains(".kist/runs/1782979476-fb0a93cf/plan.json"), "keeps the offending path: \(h)")
    }

    // A read/list/search failure that ISN'T a missing-path still must not claim uncommitted work.
    func testReadOnlyToolFailureSuppressesCommitFraming() {
        let h = ErrorHumanizer.humanize("weird internal blob xyz", tool: "list_files")
        XCTAssertFalse(h.contains("Nothing was committed"), "list_files can't leave uncommitted work: \(h)")
        XCTAssertTrue(h.lowercased().contains("retry"))
        // A mutating tool with the SAME error keeps the commit framing.
        let mut = ErrorHumanizer.humanize("weird internal blob xyz", tool: "edit_file")
        XCTAssertTrue(mut.contains("Nothing was committed"), "edit_file failure can leave uncommitted work: \(mut)")
    }

    // Codex (c): a MUTATING tool whose error merely CONTAINS "not found" must NOT be reframed as a
    // missing path — the not-found reframe is gated on the tool being read-only.
    func testMutatingToolNotFoundIsNotReframedAsMissingPath() {
        // edit_file: the file EXISTS; the anchor text wasn't found. Not a missing path.
        let edit = ErrorHumanizer.humanize("old_text not found in Sources/App.swift", tool: "edit_file")
        XCTAssertFalse(edit.contains("doesn't exist here"), "anchor-not-found isn't a missing path: \(edit)")
        XCTAssertTrue(edit.contains("Nothing was committed"), "edit_file is mutating — keep commit framing: \(edit)")
        // run_command: an executable-not-found is a launch failure, not a filesystem path miss.
        let run = ErrorHumanizer.humanize("executable not found or not executable", tool: "run_command")
        XCTAssertFalse(run.contains("doesn't exist here"), "launch failure isn't a missing path: \(run)")
        XCTAssertTrue(run.contains("Nothing was committed"))
        // The 'tasks' tool is only sometimes read-only; name-only it's treated mutating (safe side).
        let tasks = ErrorHumanizer.humanize("not found: .kist/plan.json", tool: "tasks")
        XCTAssertTrue(tasks.contains("Nothing was committed"), "sometimes-read tools keep commit framing by name: \(tasks)")
    }

    func testConciseTrimsLongMultilineErrors() {
        let long = "first line of the error\nstack frame 1\nstack frame 2"
        XCTAssertEqual(ErrorHumanizer.concise(long), "first line of the error")
    }

    // A raw error carrying a key must be redacted in the user-facing gist (no leak).
    func testConciseRedactsSecrets() {
        let leak = "401 unauthorized for key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"
        XCTAssertFalse(ErrorHumanizer.concise(leak).contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    }

    // MARK: StatusLine — visibility of system status (#3)

    func testStatusLineShowsModelModeCostAndTasks() {
        let s = StatusLine(modelLabel: "Gemini is reviewing · MiMo is researching", mode: "plan",
                           cost: "$0.01 · 1.2k tok", activeTask: "[3] build the parser", nextStep: "[4] write tests")
        let out = s.render(color: false)
        XCTAssertTrue(out.contains("Gemini is reviewing"))
        XCTAssertTrue(out.contains("mode: plan"))
        XCTAssertTrue(out.contains("cost: $0.01 · 1.2k tok"))
        XCTAssertTrue(out.contains("doing: [3] build the parser"))
        XCTAssertTrue(out.contains("next: [4] write tests"))
    }

    func testStatusLineWithoutTasksIsOneLine() {
        let s = StatusLine(modelLabel: "Claude", mode: "chat", cost: "—", activeTask: nil, nextStep: nil)
        let out = s.render(color: false)
        XCTAssertFalse(out.contains("\n"))
        XCTAssertFalse(out.contains("doing:"))
    }

    func testOperatorPanelRendersLikeAgentOSNotProviderDump() {
        let panel = OperatorPanel(agent: "MiMo (mimo-v2.5-pro)", goal: "Waiting for your request",
                                  mode: "chat", memory: "healthy", context: "/tmp/project",
                                  cost: "$0.002", tools: ["↑/↓ history", "Tab completion", "/usage"])
        let out = panel.render(color: false)

        XCTAssertTrue(out.contains("Mythos"))
        XCTAssertTrue(out.contains("Agent : MiMo"))
        XCTAssertTrue(out.contains("Goal  : Waiting for your request"))
        XCTAssertTrue(out.contains("Status"))
        XCTAssertTrue(out.contains("Tools"))
        XCTAssertTrue(out.contains("Cost"))
        XCTAssertFalse(out.contains("roles · planner="))
    }

    func testCalmSuccessSummaryShowsFileMutationDetails() {
        XCTAssertEqual(TerminalEventSink.calmSuccessSummary(tool: "write_file",
                                                            output: "Wrote Sources/App.swift (42 lines)"),
                       "Wrote Sources/App.swift (42 lines)")
        XCTAssertEqual(TerminalEventSink.calmSuccessSummary(tool: "edit_file",
                                                            output: "Edited Sources/App.swift (+3 lines)"),
                       "Edited Sources/App.swift (+3 lines)")
        XCTAssertEqual(TerminalEventSink.calmSuccessSummary(tool: "move_file",
                                                            output: "Moved old.swift → new.swift"),
                       "Moved old.swift → new.swift")
    }

    func testCalmSuccessSummaryKeepsReadOutputBehindLogs() {
        let read = TerminalEventSink.calmSuccessSummary(tool: "read_file", output: "1│ a\n2│ b\n3│ c")
        XCTAssertTrue(read.contains("read 3 line(s)"))
        XCTAssertTrue(read.contains("/logs"))

        let command = TerminalEventSink.calmSuccessSummary(tool: "run_command", output: "one\ntwo")
        XCTAssertTrue(command.contains("command output"))
        XCTAssertTrue(command.contains("/logs"))
    }

    func testLiveThinkingStatusShowsElapsedAndEstimatedTokens() {
        let out = TerminalEventSink.liveStatusText(label: "thinking", elapsed: 65, streamedCharacters: 44)

        XCTAssertTrue(out.contains("◇ thinking"))
        XCTAssertTrue(out.contains("1m 5s"))
        XCTAssertTrue(out.contains("~11 tok"))
    }

    func testLiveStatusPrefersMeasuredUsageTokens() {
        let out = TerminalEventSink.liveStatusText(label: "working", elapsed: 7, streamedCharacters: 400,
                                                   promptTokens: 1200, completionTokens: 80,
                                                   estimated: false)

        XCTAssertTrue(out.contains("1.3k tok"))
        XCTAssertFalse(out.contains("~100 tok"))
    }

    func testToolSummaryShowsTokenCountBeforeLogsPointer() {
        let summary = TerminalEventSink.calmSuccessSummary(tool: "read_file", output: "a\nb")
        let out = TerminalEventSink.annotateSummaryWithTokenCount(summary, promptTokens: 1400,
                                                                  completionTokens: 100,
                                                                  estimated: true)

        XCTAssertEqual(out, "read 2 line(s) · ~1.5k tok · /logs for details")
    }

    func testToolSummaryEstimatesHiddenOutputTokensWhenUsageMetadataIsMissing() {
        let output = String(repeating: "abcd", count: 375)
        let summary = TerminalEventSink.calmSuccessSummary(tool: "read_file", output: output)
        let out = TerminalEventSink.annotateSummaryWithEstimatedOutputTokens(summary, output: output)

        XCTAssertEqual(out, "read 1 line(s) · ~375 tok · /logs for details")
    }

    func testVisibleMutationSummaryDoesNotGetOutputTokenNoise() {
        let summary = TerminalEventSink.calmSuccessSummary(tool: "write_file",
                                                           output: "Wrote Sources/App.swift (42 lines)")
        let out = TerminalEventSink.annotateSummaryWithEstimatedOutputTokens(summary,
                                                                             output: "Wrote Sources/App.swift (42 lines)")

        XCTAssertEqual(out, "Wrote Sources/App.swift (42 lines)")
    }

    func testApprovalPromptCanDeferNaturalLanguageAfterSkip() {
        XCTAssertEqual(TerminalInteractor.deferredPrompt(fromRejectedApproval: "n bring in mimo to build this"),
                       "bring in mimo to build this")
        XCTAssertEqual(TerminalInteractor.deferredPrompt(fromRejectedApproval: "great now bring in mimo"),
                       "great now bring in mimo")
        XCTAssertNil(TerminalInteractor.deferredPrompt(fromRejectedApproval: "n"))
    }

    func testSearchTrailShowsQueryAndSourceURLs() {
        let output = """
        Searched: latest swift version · via duckduckgo_html

        1. Swift.org - Download
           URL: https://swift.org/download
           Snippet: Latest release...
        2. Swift Releases
           URL: https://github.com/apple/swift/releases
        """
        let trail = try! XCTUnwrap(TerminalEventSink.searchTrail(output: output, color: false))
        // EXACT query — the engine ("via duckduckgo_html") must NOT be part of the shown query.
        XCTAssertTrue(trail.contains("searched: latest swift version · 2 sources · duckduckgo_html"), trail)
        XCTAssertFalse(trail.contains("via duckduckgo"), "engine suffix must not leak into the query")
        XCTAssertTrue(trail.contains("https://swift.org/download"))
        XCTAssertTrue(trail.contains("https://github.com/apple/swift/releases"))
        XCTAssertNil(TerminalEventSink.searchTrail(output: "Searched: x\n\n(no results)", color: false))
    }

    func testTerminalMediaProtocolDetection() {
        XCTAssertEqual(TerminalMediaRenderer.detect(env: ["TERM_PROGRAM": "iTerm.app"], isTTY: true), .iterm2)
        XCTAssertEqual(TerminalMediaRenderer.detect(env: ["TERM_PROGRAM": "WezTerm"], isTTY: true), .iterm2)
        XCTAssertEqual(TerminalMediaRenderer.detect(env: ["KITTY_WINDOW_ID": "7"], isTTY: true), .kitty)
        // Terminal.app has no pixel protocol but IS a TTY → universal ANSI-block fallback (real picture).
        XCTAssertEqual(TerminalMediaRenderer.detect(env: ["TERM_PROGRAM": "Apple_Terminal"], isTTY: true), .ansiBlocks)
        // Not a TTY (piped) or explicitly disabled → no preview at all.
        XCTAssertEqual(TerminalMediaRenderer.detect(env: ["TERM_PROGRAM": "iTerm.app"], isTTY: false), .none)
        XCTAssertEqual(TerminalMediaRenderer.detect(env: ["KIST_MEDIA_PREVIEW": "0"], isTTY: true), .none)
    }

    func testSpaceListItemsAddsBlankLineBetweenBullets() {
        let input = "Here are the points:\n- first item\n- second item\n* third item"
        let out = TerminalEventSink.spaceListItems(input)
        XCTAssertTrue(out.contains("- first item\n\n- second item"), "blank line between bullets")
        XCTAssertTrue(out.contains("- second item\n\n* third item"), "blank line before * bullet")
        // Numbered lists too.
        let nums = TerminalEventSink.spaceListItems("1. one\n2. two\n3) three")
        XCTAssertTrue(nums.contains("1. one\n\n2. two"))
        XCTAssertTrue(nums.contains("2. two\n\n3) three"))
    }

    func testSpaceListItemsLeavesProseAndCodeUntouched() {
        let prose = "Just a sentence.\nAnother sentence."
        XCTAssertEqual(TerminalEventSink.spaceListItems(prose), prose)   // no list → unchanged
        // A "-" inside a fenced code block must NOT be treated as a bullet.
        let code = "Run:\n```\n- not a bullet\n- still code\n```"
        XCTAssertEqual(TerminalEventSink.spaceListItems(code), code)
        // Already-spaced bullets aren't double-spaced.
        let spaced = "- a\n\n- b"
        XCTAssertEqual(TerminalEventSink.spaceListItems(spaced), spaced)
    }

    func testTerminalMediaSequences() {
        let data = Data([0x89, 0x50, 0x4E, 0x47])

        let iterm = TerminalMediaRenderer.iterm2Sequence(data: data, name: "shot.png")
        XCTAssertTrue(iterm.contains("]1337;File=inline=1"))
        XCTAssertTrue(iterm.contains(data.base64EncodedString()))

        // Kitty chunk contract: first chunk carries the controls + m=1, continuation chunks carry
        // ONLY m, last chunk terminates with m=0. (Regression pin for the multi-chunk render bug.)
        let kitty = TerminalMediaRenderer.kittySequence(data: data, chunkSize: 3)
        XCTAssertTrue(kitty.hasPrefix("\u{001B}_Gf=100,a=T,m=1;"), "first chunk must hold the controls + m=1")
        XCTAssertTrue(kitty.contains("\u{001B}_Gm=1;"), "continuation chunks carry only m=1")
        XCTAssertTrue(kitty.contains("m=0;"), "final chunk must terminate with m=0")
        XCTAssertEqual(kitty.components(separatedBy: "f=100,a=T").count, 2,
                       "controls appear exactly once (first chunk only), not on every chunk")
        XCTAssertTrue(kitty.hasSuffix("\u{001B}\\"))

        // Single-chunk image: one escape, controls + terminating m=0.
        let single = TerminalMediaRenderer.kittySequence(data: data, chunkSize: 4096)
        XCTAssertTrue(single.hasPrefix("\u{001B}_Gf=100,a=T,m=0;"))
    }

    func testAnsiImageRendererProducesColouredBlocks() throws {
        // Build a tiny 4×4 PNG in-memory, then render it as ANSI half-blocks.
        let png = try Self.makeSolidPNG(width: 4, height: 4, r: 200, g: 20, b: 20)
        let out = try XCTUnwrap(AnsiImageRenderer.render(data: png, maxCols: 4, maxRows: 8, truecolor: true))
        XCTAssertTrue(out.contains("▀"), "uses the upper-half-block glyph")
        XCTAssertTrue(out.contains("\u{001B}[38;2;"), "truecolor foreground escape")
        XCTAssertTrue(out.contains("\u{001B}[48;2;"), "truecolor background escape")
        XCTAssertTrue(out.contains("\u{001B}[0m"), "resets colour at line end")
        // Non-image bytes decode to nil, not garbage.
        XCTAssertNil(AnsiImageRenderer.render(data: Data([0x00, 0x01, 0x02]), maxCols: 4))
        // xterm-256 cube fallback maps black→16, white→231.
        XCTAssertEqual(AnsiImageRenderer.xterm256(0, 0, 0), 16)
        XCTAssertEqual(AnsiImageRenderer.xterm256(255, 255, 255), 231)
    }

    // MARK: PlanStatusVisibility — a prior session's plan must not greet a cold start as `next:`
    // (Luke: "why is this appearing when a new session starts"). The persisted plan drives the status
    // line ONLY when it belongs to the current session (file written at/after sessionStart).

    func testStalePlanFromPriorSessionIsHidden() {
        let sessionStart = Date()
        let staleWrite = sessionStart.addingTimeInterval(-3600)   // plan written an hour before this session
        XCTAssertFalse(PlanStatusVisibility.shouldShow(planModifiedAt: staleWrite, sessionStart: sessionStart, hasActiveTask: false))
    }

    func testNoPlanFileIsHidden() {
        XCTAssertFalse(PlanStatusVisibility.shouldShow(planModifiedAt: nil, sessionStart: Date(), hasActiveTask: false))
    }

    func testPlanAdvancedThisSessionIsShown() {
        let sessionStart = Date()
        let freshWrite = sessionStart.addingTimeInterval(5)       // this session touched the plan
        XCTAssertTrue(PlanStatusVisibility.shouldShow(planModifiedAt: freshWrite, sessionStart: sessionStart, hasActiveTask: false))
    }

    // A STALE in-progress task from a PRIOR session must NOT greet a cold start (Luke: a leftover
    // `resolve-aliases.sh` action showed on every startup). An active task no longer force-shows — only a
    // plan this session actually touched (mtime >= sessionStart) surfaces. Reachable anytime via /tasks.
    func testStalePriorSessionActiveTaskDoesNotGreetColdStart() {
        let sessionStart = Date()
        let staleWrite = sessionStart.addingTimeInterval(-3600)
        XCTAssertFalse(PlanStatusVisibility.shouldShow(planModifiedAt: staleWrite, sessionStart: sessionStart, hasActiveTask: true))
        XCTAssertFalse(PlanStatusVisibility.shouldShow(planModifiedAt: nil, sessionStart: sessionStart, hasActiveTask: true))
        // A plan advanced THIS session still shows (real mid-flight work).
        let freshWrite = sessionStart.addingTimeInterval(5)
        XCTAssertTrue(PlanStatusVisibility.shouldShow(planModifiedAt: freshWrite, sessionStart: sessionStart, hasActiveTask: true))
    }

    // Boundary: `>=` means a plan written at the exact session-start instant shows; one tick earlier hides.
    // Pins the comparator so a later `>=`→`>` change can't silently flip cold-start behavior.
    func testMtimeBoundaryAroundSessionStart() {
        let sessionStart = Date()
        XCTAssertTrue(PlanStatusVisibility.shouldShow(planModifiedAt: sessionStart, sessionStart: sessionStart, hasActiveTask: false))
        XCTAssertTrue(PlanStatusVisibility.shouldShow(planModifiedAt: sessionStart.addingTimeInterval(0.001), sessionStart: sessionStart, hasActiveTask: false))
        XCTAssertFalse(PlanStatusVisibility.shouldShow(planModifiedAt: sessionStart.addingTimeInterval(-0.001), sessionStart: sessionStart, hasActiveTask: false))
    }

    private static func makeSolidPNG(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) throws -> Data {
        let bytesPerRow = width * 4
        var px = [UInt8](repeating: 0, count: bytesPerRow * height)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = r; px[i+1] = g; px[i+2] = b; px[i+3] = 255 }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        let dst = NSMutableData()
        let out = CGImageDestinationCreateWithData(dst, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(out, cg, nil)
        guard CGImageDestinationFinalize(out) else { throw NSError(domain: "png", code: 1) }
        return dst as Data
    }

    func testGroundedReviewValidatorFlagsMissingFileReferences() throws {
        let dir = NSTemporaryDirectory() + "grounding-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/Sources/Kist", withIntermediateDirectories: true)
        try "ok".write(toFile: dir + "/Sources/Kist/KistREPL.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = GroundedReviewValidator.audit("""
        Sources/Kist/KistREPL.swift:10 is real.
        mcp-server/Sources/fca-mcp/MCPServer.swift:20 is hallucinated.
        """, projectRoot: dir)

        XCTAssertEqual(report.missingFiles, ["mcp-server/Sources/fca-mcp/MCPServer.swift"])
        XCTAssertTrue(report.render(color: false).contains("grounding warning"))
    }

    // Regression (live dogfood false-positive): a BARE filename the model saw in a directory listing —
    // and which really exists deeper in the tree — must NOT be flagged. Only fabricated PATHS are flagged.
    func testGroundedReviewValidatorDoesNotFlagBareFilenames() throws {
        let dir = NSTemporaryDirectory() + "grounding2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/cortex", withIntermediateDirectories: true)
        try "prefs".write(toFile: dir + "/cortex/preferences.md", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // "preferences.md" exists at cortex/preferences.md (not at root); a bare name must be given a pass.
        // "tool.py" doesn't exist anywhere, but as a BARE name it's still not flagged (too noisy to claim).
        let report = GroundedReviewValidator.audit("It reads preferences.md every session and has a tool.py helper.",
                                                   projectRoot: dir)
        XCTAssertTrue(report.isGrounded, "bare filenames must not trip the grounding warning: \(report.missingFiles)")
    }

    // MARK: TurnProofStore — proof drawer, not default wall of logs (#2/#8)

    func testTurnProofStoreRendersLastTurnDetails() {
        let store = TurnProofStore()
        store.startTurn(goal: "build the thing")
        store.record(.init(kind: .actionStarted, tool: "read_file", success: nil, text: "Sources/App.swift"))
        store.record(.init(kind: .actionFinished, tool: "read_file", success: true, text: "line 1\nline 2"))
        store.record(.init(kind: .completed, tool: nil, success: true, text: "done"))

        let out = store.renderLast()

        XCTAssertTrue(out.contains("Details"))
        XCTAssertTrue(out.contains("Goal: build the thing"))
        XCTAssertTrue(out.contains("tool started: read_file"))
        XCTAssertTrue(out.contains("tool ok: read_file"))
        XCTAssertTrue(out.contains("completed: done"))
    }

    func testTurnProofStoreRedactsSecrets() {
        let store = TurnProofStore()
        store.startTurn(goal: "test")
        store.record(.init(kind: .failed, tool: nil, success: false,
                           text: "bad key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"))

        XCTAssertFalse(store.renderLast().contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    }

    func testTurnProofStoreRendersWaitStatesWithoutCallingThemReplans() {
        let store = TurnProofStore()
        store.startTurn(goal: "approve active scan")
        store.record(.init(kind: .awaitingInput, tool: "ask_user", success: nil, text: "What target?"))
        store.record(.init(kind: .awaitingApproval, tool: nil, success: nil, text: "browse(url: https://example.com)"))

        let out = store.renderLast()

        XCTAssertTrue(out.contains("waiting for answer: What target?"))
        XCTAssertTrue(out.contains("waiting for approval: browse(url: https://example.com)"))
        XCTAssertFalse(out.contains("replan:"))
    }
}
