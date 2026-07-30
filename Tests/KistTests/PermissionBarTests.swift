import XCTest
import AgentCore
@testable import Kist

/// The shift+tab permission bar (Claude-Code-style): mode cycle order, tier→approval mapping, the
/// guards-off confirm gate, and the bar text. Pure logic, pinned without a terminal.
final class PermissionBarTests: XCTestCase {

    private let sensitive: Set<String> = ["run_command", "write_file", "edit_file", "browse", "make_dir"]
    private let edits: Set<String> = ["write_file", "edit_file", "make_dir"]

    // MARK: cycle order — repeated shift+tab shuffles through all tiers and wraps

    func testCycleOrderWraps() {
        XCTAssertEqual(PermissionMode.normal.next(), .acceptEdits)
        XCTAssertEqual(PermissionMode.acceptEdits.next(), .plan)
        XCTAssertEqual(PermissionMode.plan.next(), .bypass)
        XCTAssertEqual(PermissionMode.bypass.next(), .normal)   // wraps
    }

    // MARK: tier → approval set

    func testApprovalToolsPerTier() {
        XCTAssertEqual(PermissionMode.normal.approvalTools(sensitive: sensitive, editTools: edits), sensitive)
        // accept-edits auto-approves file edits but still prompts for shell/browse
        let ae = PermissionMode.acceptEdits.approvalTools(sensitive: sensitive, editTools: edits)
        XCTAssertEqual(ae, ["run_command", "browse"])
        XCTAssertFalse(ae.contains("write_file"))
        XCTAssertTrue(PermissionMode.bypass.approvalTools(sensitive: sensitive, editTools: edits).isEmpty)
        // plan keeps the full prompt set as defense-in-depth (read-only is enforced separately)
        XCTAssertEqual(PermissionMode.plan.approvalTools(sensitive: sensitive, editTools: edits), sensitive)
    }

    // MARK: controller — guards-off NEVER arms without a confirm

    func testControllerArmDefersGuardsOffUntilConfirmed() {
        var c = PermissionController(mode: .normal, sensitive: sensitive, edit: edits)
        c.cycle(); c.cycle(); c.cycle()                 // normal → acceptEdits → plan → bypass
        XCTAssertEqual(c.mode, .bypass)
        XCTAssertTrue(c.needsBypassConfirm)
        // Before confirm, arm() falls back to the NORMAL approval set — guards stay ON.
        let preApproval = c.arm(makeStubLoop()).currentApprovalTools
        XCTAssertEqual(preApproval, sensitive, "unconfirmed bypass must not drop approvals")
        // After confirm, arm() drops to guards-off.
        c.confirmBypass()
        XCTAssertFalse(c.needsBypassConfirm)
        XCTAssertTrue(c.arm(makeStubLoop()).currentApprovalTools.isEmpty)
    }

    func testLeavingBypassDisarmsIt() {
        var c = PermissionController(mode: .bypass, sensitive: sensitive, edit: edits)
        XCTAssertFalse(c.needsBypassConfirm, "launched in bypass (--yolo) ⇒ already armed")
        c.cycle()                                       // bypass → normal
        c.cycle(); c.cycle(); c.cycle()                 // back to bypass
        XCTAssertTrue(c.needsBypassConfirm, "re-entering bypass must re-confirm")
    }

    func testDeclineBypassDropsToNormal() {
        var c = PermissionController(mode: .plan, sensitive: sensitive, edit: edits)
        c.cycle()                                       // plan → bypass
        c.declineBypass()
        XCTAssertEqual(c.mode, .normal)
    }

    // Codex CRITICAL pin: after guards-off is confirmed and then LEFT, arming must restore the full
    // approval set — a later turn must never reuse the stale empty (guards-off) approvals.
    func testLeavingConfirmedBypassReArmsToFullApprovals() {
        var c = PermissionController(mode: .bypass, sensitive: sensitive, edit: edits)
        c.confirmBypass()
        XCTAssertTrue(c.arm(makeStubLoop()).currentApprovalTools.isEmpty, "confirmed bypass ⇒ guards off")
        c.cycle()                                       // bypass → normal
        XCTAssertEqual(c.arm(makeStubLoop()).currentApprovalTools, sensitive,
                       "leaving bypass must restore approvals — no stale guards-off")
    }

    // Structural multi-site contract: EVERY conversational turn routes through the single armed +
    // interruptible helper, so a stale guards-off loop can never run a /command or task turn (a prior
    // Codex CRITICAL). Scans ALL Kist sources recursively (the modularize split spread the REPL across
    // KistREPL.swift + KistREPL+*.swift) and asserts every `.turn(transcript:` site is on the allowlist:
    //   • KistREPL.swift — the ONE call inside runTurnInterruptible (the armed + esc-interruptible path).
    //   • TUIConversation.swift — the `--tui` surface, which now has its OWN armed + interruptible turn
    //     (perm.arm(loop) + InterruptibleTurn.run); a distinct arming path from the REPL helper, so it's
    //     allowlisted here rather than forced through the nested REPL helper it can't see.
    // A NEW `.turn(transcript:` anywhere else fails this test — the whole point (Codex NO-SHIP caught the
    // earlier version being blind to TUIConversation).
    func testEveryTurnRoutesThroughTheArmedHelper() throws {
        let allowedFiles: Set<String> = ["KistREPL.swift", "TUIConversation.swift"]
        var sites: [String] = []
        let kist = repoRoot().appendingPathComponent("Sources/Kist")
        let en = FileManager.default.enumerator(at: kist, includingPropertiesForKeys: nil)!
        for case let url as URL in en where url.pathExtension == "swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            for line in src.split(separator: "\n") where line.contains("await") && line.contains(".turn(transcript:") {
                sites.append("\(url.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        let offenders = sites.filter { site in !allowedFiles.contains(where: { site.hasPrefix($0 + ":") }) }
        XCTAssertTrue(offenders.isEmpty, "un-allowlisted turn site(s) bypass arming: \(offenders)")
        // KistREPL must have EXACTLY one (the helper) — pins that the REPL didn't sprout a second.
        let inRepl = sites.filter { $0.hasPrefix("KistREPL.swift:") }
        XCTAssertEqual(inRepl.count, 1, "KistREPL must have exactly one turn site (runTurnInterruptible) — found: \(inRepl)")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private func repoFile(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)
    }

    func testSetPlanFromCommand() {
        var c = PermissionController(mode: .normal, sensitive: sensitive, edit: edits)
        c.set(.plan)
        XCTAssertTrue(c.mode.isPlan)
        XCTAssertTrue(c.arm(makeStubLoop()).isPlanMode)
    }

    // MARK: bar text — exact Claude-Code wording

    func testBarTextPerMode() {
        XCTAssertTrue(PromptBar.hint(mode: .bypass, includeInterrupt: false, color: false)
            .contains("⏵⏵ bypass permissions on (shift+tab to cycle)"))
        XCTAssertTrue(PromptBar.hint(mode: .acceptEdits, includeInterrupt: false, color: false)
            .contains("⏵⏵ accept edits on (shift+tab to cycle)"))
        XCTAssertTrue(PromptBar.hint(mode: .plan, includeInterrupt: false, color: false)
            .contains("⏸ plan mode on (shift+tab to cycle)"))
        // normal shows only the shortcut hint, no "on" banner
        let normal = PromptBar.hint(mode: .normal, includeInterrupt: false, color: false)
        XCTAssertTrue(normal.contains("shift+tab to cycle permissions"))
        XCTAssertFalse(normal.contains(" on "))
    }

    func testBarIncludesInterruptOnlyWhenWired() {
        XCTAssertFalse(PromptBar.hint(mode: .normal, includeInterrupt: false, color: false).contains("esc to interrupt"))
        XCTAssertTrue(PromptBar.hint(mode: .normal, includeInterrupt: true, color: false).contains("esc to interrupt"))
    }

    // MARK: decoder — shift+tab is ESC [ Z, distinct from a lone escape

    func testBackTabDecodes() {
        XCTAssertEqual(KeyDecoder.decode([0x1B, 0x5B, 0x5A]), [.backTab])
        XCTAssertEqual(KeyDecoder.decode([0x1B]), [.escape])
        XCTAssertEqual(KeyDecoder.decode([0x09]), [.tab])   // plain tab unaffected
    }

    // MARK: frame — boxed input: input line + bottom border + hint + cursor reposition

    func testFrameDrawsBoxWithBottomBorderHintAndParksCursor() {
        let out = PromptBar.frame(promptAndInput: "│ ❯ hi", hint: "BAR", cursorCol: 6, width: 30)
        XCTAssertTrue(out.contains("│ ❯ hi"))
        XCTAssertTrue(out.hasPrefix("\r\u{001B}[J"))
        XCTAssertTrue(out.contains("╰"))               // bottom border present (the box closes)
        XCTAssertTrue(out.contains("╯"))
        XCTAssertTrue(out.contains("BAR"))
        XCTAssertTrue(out.contains("\u{001B}[2A"))      // cursor up TWO rows (past bottom border) to input
        XCTAssertTrue(out.contains("\u{001B}[6G"))      // parked at the edit column
    }

    // On submit the R2b pinned bar is repainted with this EMPTY box so the just-sent text stops lingering
    // in the box while the turn streams above it ("it still ain't cleared"). It draws the full box — top
    // border · empty input line · bottom border · hint — with every row self-clearing (ESC[2K) and NO
    // cursor parking / no `\r ESC[J` (the caller has already positioned at the panel top).
    func testEmptyBoxDrawsAClearedInputBoxWithNoStaleTextOrCursorPark() {
        let out = PromptBar.emptyBox(promptLead: "│ ❯ ", hint: "BAR", width: 30)
        XCTAssertTrue(out.contains("╭") && out.contains("╮"))   // top border
        XCTAssertTrue(out.contains("│ ❯ "))                     // the prompt lead — with NO input after it
        XCTAssertTrue(out.contains("╰") && out.contains("╯"))   // bottom border closes the box
        XCTAssertTrue(out.contains("BAR"))                      // hint
        XCTAssertEqual(out.components(separatedBy: "\u{001B}[2K").count - 1, 3, "each box row self-clears")
        XCTAssertFalse(out.contains("\u{001B}[2A"), "static repaint parks no cursor (the caller does)")
        XCTAssertFalse(out.hasPrefix("\r\u{001B}[J"), "no clear-screen prefix — the panelLead already cleared")
    }

    func testTopAndBottomBordersMatchWidth() {
        let top = PromptBar.topBorder(width: 20, color: false)
        let bot = PromptBar.bottomBorder(width: 20, color: false)
        XCTAssertTrue(top.hasPrefix("╭") && top.hasSuffix("╮"))
        XCTAssertTrue(bot.hasPrefix("╰") && bot.hasSuffix("╯"))
        XCTAssertEqual(top.count, 20)                   // ╭ + 18 ─ + ╮
        XCTAssertEqual(bot.count, 20)
    }

    func testPromptBoxSafeWidthLeavesRightMargin() {
        XCTAssertEqual(PromptBar.safeWidth(columns: 79), 77)
        XCTAssertEqual(PromptBar.safeWidth(columns: 12), 10)
    }

    // Claude subagent permissionMode → kist tier mapping (Phase 1 primitive).
    func testClaudePermissionModeMapping() {
        XCTAssertEqual(PermissionMode.fromClaudeFrontmatter("default"), .normal)
        XCTAssertEqual(PermissionMode.fromClaudeFrontmatter("acceptEdits"), .acceptEdits)
        XCTAssertEqual(PermissionMode.fromClaudeFrontmatter("plan"), .plan)
        XCTAssertEqual(PermissionMode.fromClaudeFrontmatter("bypassPermissions"), .bypass)
        XCTAssertEqual(PermissionMode.fromClaudeFrontmatter("dontAsk"), .bypass, "don't-ask collapses to bypass")
        XCTAssertEqual(PermissionMode.fromClaudeFrontmatter("auto"), .acceptEdits, "auto → nearest kist tier")
        XCTAssertNil(PermissionMode.fromClaudeFrontmatter("nonsense"), "unknown ⇒ nil (keep session default)")
    }

    // Codex HIGH: a file's permissionMode can only make a spawned specialist MORE restrictive, never less.
    // The cap = parentApproval ∪ childApproval. A `bypass` child (approval == []) must NOT drop the parent's
    // guards. This pins the security invariant the runSpecialist seam relies on.
    func testChildPermissionCannotDropBelowParent() {
        let sensitive: Set<String> = ["run_command", "write_file", "browse"]
        let editTools: Set<String> = ["write_file"]
        let parent = PermissionMode.normal.approvalTools(sensitive: sensitive, editTools: editTools)
        XCTAssertFalse(parent.isEmpty, "a guarded parent requires approvals")

        // Malicious/misconfigured agent file asks for guards-off.
        let bypassChild = PermissionMode.bypass.approvalTools(sensitive: sensitive, editTools: editTools)
        XCTAssertTrue(bypassChild.isEmpty, "bypass alone would skip every prompt")
        XCTAssertEqual(parent.union(bypassChild), parent,
                       "union with the parent floor preserves EVERY parent approval — no escalation")

        // A stricter child only ADDS approvals.
        let strictChild = PermissionMode.normal.approvalTools(sensitive: sensitive, editTools: editTools)
        XCTAssertTrue(parent.union(strictChild).isSuperset(of: parent))
    }

    // Codex HIGH (confirmation): the parent floor passed to a spawn must be the EFFECTIVE state, not the raw
    // indicator. An UNCONFIRMED bypass must read as normal (guards on), or it would hand a child an empty floor.
    func testEffectiveApprovalHonorsUnconfirmedBypassFailSafe() {
        let sensitive: Set<String> = ["run_command", "write_file"]
        var perm = PermissionController(mode: .normal, sensitive: sensitive, edit: ["write_file"])
        perm.cycle(); perm.cycle(); perm.cycle()   // normal → acceptEdits → plan → bypass (indicator only)
        XCTAssertEqual(perm.mode, .bypass)
        XCTAssertTrue(perm.needsBypassConfirm, "bypass not yet confirmed")
        XCTAssertEqual(perm.effectiveApproval(), PermissionMode.normal.approvalTools(sensitive: sensitive, editTools: ["write_file"]),
                       "unconfirmed bypass ⇒ effective floor is NORMAL, never empty")
        XCTAssertFalse(perm.effectiveApproval().isEmpty)
        perm.confirmBypass()
        XCTAssertTrue(perm.effectiveApproval().isEmpty, "once confirmed, bypass truly drops approvals")
    }

    private func makeStubLoop() -> HeadlessAgentLoop {
        HeadlessAgentLoop(providers: ProviderRegistry(), providerId: "stub", model: nil,
                          tools: .headless(),
                          context: ToolContext(projectRoot: NSTemporaryDirectory()),
                          approvalTools: [])
    }
}
