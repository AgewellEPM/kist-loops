import XCTest
@testable import Kist
@testable import AgentCore

/// Proves temporal semantic tools stay separate from the retired Cortex compatibility surface.
final class KistExtraToolsTests: XCTestCase {

    func testLegacyCortexToolIsAbsentWhileCoreExtrasRemainHookedUp() {
        let opts = KistOptions(project: NSTemporaryDirectory())
        let tools = KistRunner.buildExtraTools(root: NSTemporaryDirectory(), fetchAllowedHosts: [],
                                               opts: opts, registry: KistRunner.makeRegistry(config: KistConfig()))
        let names = Set(tools.map { $0.name })
        XCTAssertFalse(names.contains("cortex"),
                       "raw audit-only Markdown must not expose a model tool")
        // Regression guard: --resume previously lost ALL of these by passing no extraTools.
        for n in ["tasks", "browse", "security_audit", "business_workflow"] {
            XCTAssertTrue(names.contains(n), "\(n) must be in the shared extra tool set")
        }
    }

    func testFastModeTrimsToTheLeanDevSet() {
        let previous = ProcessInfo.processInfo.environment["KIST_EMBEDDER"]
        setenv("KIST_EMBEDDER", "ollama", 1)
        defer {
            if let previous { setenv("KIST_EMBEDDER", previous, 1) }
            else { unsetenv("KIST_EMBEDDER") }
        }
        var opts = KistOptions(project: "/tmp"); opts.fast = true
        let names = Set(KistRunner.buildExtraTools(root: "/tmp", fetchAllowedHosts: [], opts: opts,
                                                   registry: KistRunner.makeRegistry(config: KistConfig())).map { $0.name })
        XCTAssertEqual(names, ["remember", "recall"],
                       "--fast retains only temporal semantic extras when an embedder is admitted")
        // no media/browse/pentest/research/workflow/vision bloat in fast mode
        for bloat in ["browse", "pentest", "business_workflow", "analyze_media", "view_image", "research_run"] {
            XCTAssertFalse(names.contains(bloat), "\(bloat) must be dropped in --fast")
        }
        opts.noMemory = true
        XCTAssertTrue(KistRunner.buildExtraTools(root: "/tmp", fetchAllowedHosts: [], opts: opts,
                                                 registry: KistRunner.makeRegistry(config: KistConfig())).isEmpty, "--fast --no-memory → empty extras")
    }

    func testEveryMemoryToolIsOmittedUnderNoMemoryWithActiveEmbedder() {
        let previous = ProcessInfo.processInfo.environment["KIST_EMBEDDER"]
        setenv("KIST_EMBEDDER", "ollama", 1)
        defer {
            if let previous { setenv("KIST_EMBEDDER", previous, 1) }
            else { unsetenv("KIST_EMBEDDER") }
        }
        var opts = KistOptions(project: NSTemporaryDirectory()); opts.noMemory = true
        let registry = KistRunner.makeRegistry(config: KistConfig())
        XCTAssertNotNil(KistRunner.makeEmbedder(
            registry: registry, environment: ["KIST_EMBEDDER": "ollama"]))
        XCTAssertNil(KistRunner.makeSemanticMemory(
            root: NSTemporaryDirectory(), opts: opts, registry: registry,
            environment: ["KIST_EMBEDDER": "ollama"]))
        let tools = KistRunner.buildExtraTools(root: NSTemporaryDirectory(), fetchAllowedHosts: [],
                                               opts: opts, registry: registry)
        let names = Set(tools.map(\.name))
        for memoryTool in ["cortex", "remember", "recall"] {
            XCTAssertFalse(names.contains(memoryTool), "--no-memory must not expose \(memoryTool)")
        }
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

    func testSessionMemoryExcludesRawCortexButPreservesOperatorProjectConfig() throws {
        let home = NSTemporaryDirectory() + "sessmem-\(UUID().uuidString)"
        let project = home + "/project"
        try FileManager.default.createDirectory(
            atPath: home + "/cortex", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: project, withIntermediateDirectories: true)
        setenv("XDG_DATA_HOME", home, 1)
        defer { unsetenv("XDG_DATA_HOME"); try? FileManager.default.removeItem(atPath: home) }
        try "RAW CORTEX MARKER MUST NOT BE INJECTED".write(
            toFile: home + "/cortex/preferences.md", atomically: true, encoding: .utf8)
        try "OPERATOR PROJECT CONFIG SURVIVES".write(
            toFile: project + "/AGENTS.md", atomically: true, encoding: .utf8)

        let mem = KistRunner.sessionMemory(
            root: project, opts: KistOptions(project: project))
        XCTAssertNotNil(mem)
        XCTAssertTrue(mem?.contains("OPERATOR PROJECT CONFIG SURVIVES") == true)
        XCTAssertFalse(mem?.contains("RAW CORTEX MARKER") == true)
    }

    func testCortexSlashSurfaceIsExplicitAuditOnlyAndCannotMutate() throws {
        let root = NSTemporaryDirectory() + "cortex-audit-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        let path = root + "/preferences.md"
        try "RAW AUDIT MARKER".write(
            toFile: path, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        let cortex = CortexMemory(root: root)

        let summary = KistREPL.handleCortex("", cortex: cortex)
        XCTAssertTrue(summary.contains("raw audit-only"))
        XCTAssertFalse(summary.contains("RAW AUDIT MARKER"),
                       "bare /cortex is not an operational recall path")
        XCTAssertTrue(KistREPL.handleCortex(
            "remember replacement", cortex: cortex).contains("raw audit-only"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertTrue(KistREPL.handleCortex(
            "show preferences.md", cortex: cortex).contains("RAW AUDIT MARKER"),
                      "explicit operator audit remains available")
    }

    // Operator-owned project context remains ahead of lower-priority lessons/persona in the brief.
    func testMemorySurvivesLargeContextBudget() {
        let roles = RoleBindings(default: ProviderBinding(providerId: "deepseek"))
        let hugeLessons = String(repeating: "prior lesson blah. ", count: 500)   // ~9.5k chars
        let ctx = KistRunner.briefContext(memoryContext: "WHAT KIST KNOWS ABOUT YOU: MARKER-XYZ-77",
                                          roles: roles, lessons: hugeLessons, specialists: hugeLessons)!
        // memory appears before lessons in the ordering…
        XCTAssertTrue(ctx.range(of: "MARKER-XYZ-77")!.lowerBound < ctx.range(of: "prior lesson")!.lowerBound)
        // …and survives into the compiled prompt despite the huge other context.
        let compiled = PromptCompiler.compiledPrompt("go", mode: .inline, projectContext: ctx)
        XCTAssertTrue(compiled.contains("MARKER-XYZ-77"), "project memory must not be truncated off")
    }

    func testSessionMemoryNilUnderNoMemory() {
        var opts = KistOptions(project: "/tmp"); opts.noMemory = true
        XCTAssertNil(KistRunner.sessionMemory(root: "/tmp", opts: opts))
    }

    func testRetiredAutoJournalNeverWritesRawCortex() throws {
        let home = NSTemporaryDirectory() + "autojournal-\(UUID().uuidString)"
        setenv("XDG_DATA_HOME", home, 1)
        defer { unsetenv("XDG_DATA_HOME"); try? FileManager.default.removeItem(atPath: home) }
        KistRunner.autoJournalRun(goal: "ship the symbols tool\nmore detail", success: true, root: "/tmp/kist", enabled: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/cortex"))
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
