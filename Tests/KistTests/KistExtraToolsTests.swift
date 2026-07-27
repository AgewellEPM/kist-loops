import XCTest
@testable import Kist
@testable import AgentCore

/// Proves the full tool set (incl. the agent-writable Cortex) is actually WIRED into the runtime —
/// and identically for fresh and --resume runs (both call buildExtraTools).
final class KistExtraToolsTests: XCTestCase {

    func testCortexAndCoreExtrasAreHookedUp() {
        let opts = KistOptions(project: NSTemporaryDirectory())
        let tools = KistRunner.buildExtraTools(root: NSTemporaryDirectory(), fetchAllowedHosts: [],
                                               opts: opts, registry: KistRunner.makeRegistry())
        let names = Set(tools.map { $0.name })
        XCTAssertTrue(names.contains("cortex"), "CortexTool must be registered so the agent can write its own memory")
        // Regression guard: --resume previously lost ALL of these by passing no extraTools.
        for n in ["tasks", "browse", "security_audit", "business_workflow"] {
            XCTAssertTrue(names.contains(n), "\(n) must be in the shared extra tool set")
        }
    }

    func testFastModeTrimsToTheLeanDevSet() {
        var opts = KistOptions(project: "/tmp"); opts.fast = true
        let names = Set(KistRunner.buildExtraTools(root: "/tmp", fetchAllowedHosts: [], opts: opts,
                                                   registry: KistRunner.makeRegistry()).map { $0.name })
        XCTAssertEqual(names, ["cortex"], "--fast keeps only cortex in extras (core code tools live in headless)")
        // no media/browse/pentest/research/workflow/vision bloat in fast mode
        for bloat in ["browse", "pentest", "business_workflow", "analyze_media", "view_image", "research_run"] {
            XCTAssertFalse(names.contains(bloat), "\(bloat) must be dropped in --fast")
        }
        opts.noMemory = true
        XCTAssertTrue(KistRunner.buildExtraTools(root: "/tmp", fetchAllowedHosts: [], opts: opts,
                                                 registry: KistRunner.makeRegistry()).isEmpty, "--fast --no-memory → empty extras")
    }

    func testCortexOmittedUnderNoMemory() {
        var opts = KistOptions(project: NSTemporaryDirectory()); opts.noMemory = true
        let tools = KistRunner.buildExtraTools(root: NSTemporaryDirectory(), fetchAllowedHosts: [],
                                               opts: opts, registry: KistRunner.makeRegistry())
        XCTAssertFalse(tools.contains { $0.name == "cortex" }, "--no-memory must not expose the cortex tool")
    }

    // --resume memory refresh: guarded append so message alternation stays valid.
    private func checkpoint(lastRole: ChatMessage.Role) -> LoopCheckpoint {
        LoopCheckpoint(goal: "t", providerId: "p", model: nil, projectRoot: "/tmp",
                       messages: [ChatMessage(role: .user, content: "go"),
                                  ChatMessage(role: lastRole, content: "prev")])
    }

    func testMemoryRefreshAppendsAfterAssistantTurn() {
        let out = KistRunner.withMemoryRefresh(checkpoint(lastRole: .assistant), memory: "prefers X", enabled: true)
        XCTAssertEqual(out.messages.count, 3)
        XCTAssertEqual(out.messages.last?.role, .user)
        XCTAssertEqual(out.messages.last?.content.contains("prefers X"), true)
    }

    // sessionMemory must carry CORTEX content (not just ProjectMemory) so one-shot/TUI/loop/
    // plan-execute all inject "what kist knows about you" — the gap Luke flagged.
    func testSessionMemoryIncludesCortex() throws {
        let home = NSTemporaryDirectory() + "sessmem-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", home, 1)
        defer { unsetenv("XDG_DATA_HOME"); try? FileManager.default.removeItem(atPath: home) }
        try CortexMemory().remember("Luke prefers small focused functions")
        let mem = KistRunner.sessionMemory(root: "/tmp/proj", opts: KistOptions(project: "/tmp/proj"))
        XCTAssertNotNil(mem)
        XCTAssertEqual(mem?.contains("small focused functions"), true, "cortex must be in the injected session memory")
    }

    // REGRESSION (found by live-driving): cortex memory must come FIRST in the brief so the
    // 4000-char projectContext cap in TaskBrief.prompt can't truncate it off when lessons/persona
    // fill the budget. This bug made the model answer "NOT FOUND" for a seeded preference.
    func testMemorySurvivesLargeContextBudget() {
        let roles = RoleBindings(default: ProviderBinding(providerId: "deepseek"))
        let hugeLessons = String(repeating: "prior lesson blah. ", count: 500)   // ~9.5k chars
        let ctx = KistRunner.briefContext(memoryContext: "WHAT KIST KNOWS ABOUT YOU: MARKER-XYZ-77",
                                          roles: roles, lessons: hugeLessons, specialists: hugeLessons)!
        // memory appears before lessons in the ordering…
        XCTAssertTrue(ctx.range(of: "MARKER-XYZ-77")!.lowerBound < ctx.range(of: "prior lesson")!.lowerBound)
        // …and survives into the compiled prompt despite the huge other context.
        let compiled = PromptCompiler.compiledPrompt("go", mode: .inline, projectContext: ctx)
        XCTAssertTrue(compiled.contains("MARKER-XYZ-77"), "cortex memory must not be truncated off")
    }

    func testSessionMemoryNilUnderNoMemory() {
        var opts = KistOptions(project: "/tmp"); opts.noMemory = true
        XCTAssertNil(KistRunner.sessionMemory(root: "/tmp", opts: opts))
    }

    // Auto-journaling: a completed goal run logs itself to the cortex journal.
    func testAutoJournalWritesEntry() throws {
        let home = NSTemporaryDirectory() + "autojournal-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", home, 1)
        defer { unsetenv("XDG_DATA_HOME"); try? FileManager.default.removeItem(atPath: home) }
        KistRunner.autoJournalRun(goal: "ship the symbols tool\nmore detail", success: true, root: "/tmp/kist", enabled: true)
        let dir = home + "/cortex/journal"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertEqual(files.count, 1)
        let body = (try? String(contentsOfFile: dir + "/" + (files.first ?? ""), encoding: .utf8)) ?? ""
        XCTAssertTrue(body.contains("[done] ship the symbols tool"), "logs first line + status")
        XCTAssertFalse(body.contains("more detail"), "only the first line is journaled")
        XCTAssertTrue(body.contains("kist"), "tags the project")
    }

    func testAutoJournalNoOpWhenDisabled() throws {
        let home = NSTemporaryDirectory() + "autojournal2-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", home, 1)
        defer { unsetenv("XDG_DATA_HOME"); try? FileManager.default.removeItem(atPath: home) }
        KistRunner.autoJournalRun(goal: "x", success: true, root: "/tmp", enabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/cortex/journal"), "--no-memory writes nothing")
    }

    func testMemoryRefreshNoOpAfterUserTurnOrDisabledOrEmpty() {
        // After a user turn → skip (avoid two consecutive user messages).
        XCTAssertEqual(KistRunner.withMemoryRefresh(checkpoint(lastRole: .user), memory: "m", enabled: true).messages.count, 2)
        // Disabled / empty → unchanged.
        XCTAssertEqual(KistRunner.withMemoryRefresh(checkpoint(lastRole: .assistant), memory: "m", enabled: false).messages.count, 2)
        XCTAssertEqual(KistRunner.withMemoryRefresh(checkpoint(lastRole: .assistant), memory: "", enabled: true).messages.count, 2)
    }
}
