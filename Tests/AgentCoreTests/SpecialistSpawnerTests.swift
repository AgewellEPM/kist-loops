import XCTest
@testable import AgentCore

/// Pins the PURE spawn plan: model/tools/turns/goal resolution for a hard specialist delegation.
final class SpecialistSpawnerTests: XCTestCase {

    private func def(tools: [String]? = nil, disallowed: [String]? = nil,
                     alias: String? = nil, model: ProviderBinding? = nil, maxTurns: Int? = nil)
        -> SpecialistDefinition {
        SpecialistDefinition(name: "auditor", description: "audits security",
                             systemPrompt: "Find vulnerabilities. Report only real issues.",
                             toolAllowlist: tools, disallowedTools: disallowed,
                             model: model, modelAlias: alias, maxTurns: maxTurns)
    }

    func testGoalInjectsPersonaThenTask() {
        let p = SpecialistSpawner.plan(specialist: def(), task: "audit the login flow",
                                       ceiling: ["read_file"], aliasTable: [:],
                                       roleDefault: ProviderBinding(providerId: "gemini"),
                                       defaultMaxIterations: 50, planMode: false)
        XCTAssertTrue(p.goal.contains("\"auditor\" specialist"))
        XCTAssertTrue(p.goal.contains("Find vulnerabilities"))
        XCTAssertTrue(p.goal.contains("audit the login flow"))
    }

    func testToolsScopedToResolvedList() {
        let ceiling = ["read_file", "write_file", "run_command"]
        let p = SpecialistSpawner.plan(specialist: def(tools: ["read_file", "write_file"], disallowed: ["write_file"]),
                                       task: "t", ceiling: ceiling, aliasTable: [:], roleDefault: nil,
                                       defaultMaxIterations: 50, planMode: false)
        XCTAssertEqual(p.toolNames, ["read_file"], "allowlist ∩ ceiling − denylist")
    }

    func testMaxTurnsOverridesDefault() {
        let capped = SpecialistSpawner.plan(specialist: def(maxTurns: 7), task: "t", ceiling: [],
                                            aliasTable: [:], roleDefault: nil, defaultMaxIterations: 50, planMode: false)
        XCTAssertEqual(capped.maxIterations, 7)
        let dflt = SpecialistSpawner.plan(specialist: def(), task: "t", ceiling: [],
                                          aliasTable: [:], roleDefault: nil, defaultMaxIterations: 50, planMode: false)
        XCTAssertEqual(dflt.maxIterations, 50)
    }

    func testModelResolutionExplicitAliasInherit() {
        let explicit = SpecialistSpawner.plan(specialist: def(model: ProviderBinding(providerId: "deepseek")),
                                              task: "t", ceiling: [], aliasTable: [:],
                                              roleDefault: ProviderBinding(providerId: "gemini"),
                                              defaultMaxIterations: 50, planMode: false)
        XCTAssertEqual(explicit.binding.providerId, "deepseek")

        let aliased = SpecialistSpawner.plan(specialist: def(alias: "sonnet"), task: "t", ceiling: [],
                                             aliasTable: ["sonnet": ProviderBinding(providerId: "anthropic")],
                                             roleDefault: ProviderBinding(providerId: "gemini"),
                                             defaultMaxIterations: 50, planMode: false)
        XCTAssertEqual(aliased.binding.providerId, "anthropic")

        let inherited = SpecialistSpawner.plan(specialist: def(alias: "inherit"), task: "t", ceiling: [],
                                               aliasTable: [:], roleDefault: ProviderBinding(providerId: "gemini"),
                                               defaultMaxIterations: 50, planMode: false)
        XCTAssertEqual(inherited.binding.providerId, "gemini")
    }

    func testInitialPromptPrependedBeforeTask() {
        let d = SpecialistDefinition(name: "auditor", description: "x", systemPrompt: "audit.",
                                     initialPrompt: "First read CLAUDE.md.")
        let p = SpecialistSpawner.plan(specialist: d, task: "check auth", ceiling: [], aliasTable: [:],
                                       roleDefault: nil, defaultMaxIterations: 50, planMode: false)
        XCTAssertTrue(p.goal.contains("First read CLAUDE.md."))
        // initialPrompt appears before the TASK section.
        let iIdx = p.goal.range(of: "First read")!.lowerBound
        let tIdx = p.goal.range(of: "TASK:")!.lowerBound
        XCTAssertTrue(iIdx < tIdx, "initialPrompt precedes the task")
    }

    func testPreloadedSkillsInjectedIntoGoal() {
        let p = SpecialistSpawner.plan(specialist: def(), task: "t", ceiling: [], aliasTable: [:],
                                       roleDefault: nil, defaultMaxIterations: 50, planMode: false,
                                       preloadedSkills: [("git-hygiene", "Always branch before editing.")])
        XCTAssertTrue(p.goal.contains("Preloaded skills"))
        XCTAssertTrue(p.goal.contains("git-hygiene"))
        XCTAssertTrue(p.goal.contains("Always branch before editing."))
    }

    func testNoPreloadedSkillsNoBlock() {
        let p = SpecialistSpawner.plan(specialist: def(), task: "t", ceiling: [], aliasTable: [:],
                                       roleDefault: nil, defaultMaxIterations: 50, planMode: false)
        XCTAssertFalse(p.goal.contains("Preloaded skills"))
    }

    func testMcpScopingKeepsOnlyListedServers() {
        let ceiling = ["read_file", "github__create_issue", "slack__post", "jira__ticket", "ask_user"]
        let scoped = SpecialistSpawner.mcpScopedCeiling(ceiling, mcpServers: ["github"])
        XCTAssertEqual(scoped, ["read_file", "github__create_issue", "ask_user"],
                       "non-MCP tools pass; only github MCP tools survive; slack/jira dropped")
    }

    func testMcpScopingNilInheritsAll() {
        let ceiling = ["read_file", "github__x", "slack__y"]
        XCTAssertEqual(SpecialistSpawner.mcpScopedCeiling(ceiling, mcpServers: nil), ceiling)
    }

    func testMcpScopingEmptyDropsAllMcp() {
        let ceiling = ["read_file", "github__x"]
        XCTAssertEqual(SpecialistSpawner.mcpScopedCeiling(ceiling, mcpServers: []), ["read_file"],
                       "empty list ⇒ no MCP servers allowed")
    }

    func testPlanModePropagates() {
        let p = SpecialistSpawner.plan(specialist: def(), task: "t", ceiling: [], aliasTable: [:],
                                       roleDefault: nil, defaultMaxIterations: 50, planMode: true)
        XCTAssertTrue(p.planMode)
    }

    // Codex CRITICAL: isolation:worktree must FAIL CLOSED — a non-git dir cannot be isolated, so the run
    // must REFUSE, never silently execute a write-capable specialist against the main tree.
    func testIsolationFailsClosedWhenNotAGitRepo() async throws {
        let dir = NSTemporaryDirectory() + "not-a-repo-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let spawner = SpecialistSpawner(providers: ProviderRegistry(), baseTools: ToolRegistry([]),
                                        context: ToolContext(projectRoot: dir))
        let d = SpecialistDefinition(name: "iso", description: "d", systemPrompt: "p", isolation: "worktree")
        let outcome = await spawner.run(specialist: d, task: "edit things", now: 1)
        XCTAssertFalse(outcome.success, "no worktree ⇒ refuse")
        XCTAssertEqual(outcome.iterations, 0, "the loop never ran")
        XCTAssertTrue(outcome.summary.contains("Refusing to run against the main tree"))
    }

    // Real-git integration: isolation:worktree must create a worktree, and (with no changes) discard it —
    // leaving the main tree and the temp dir clean. Skipped where git is unavailable.
    func testIsolationWorktreeLifecycle() async throws {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("git not available") }
        let repo = NSTemporaryDirectory() + "spawn-wt-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        func sh(_ args: [String]) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: git); p.arguments = ["-C", repo] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        sh(["init"]); sh(["config", "user.email", "t@t"]); sh(["config", "user.name", "t"])
        try "hi".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        sh(["add", "-A"]); sh(["commit", "-m", "init"])

        let spawner = SpecialistSpawner(providers: ProviderRegistry(), baseTools: ToolRegistry([]),
                                        context: ToolContext(projectRoot: repo))
        let d = SpecialistDefinition(name: "isolated", description: "d", systemPrompt: "p", isolation: "worktree")
        // No provider ⇒ the loop fails fast and changes nothing; isolation post-processing still runs.
        let outcome = await spawner.run(specialist: d, task: "do nothing", now: 1_000_000)
        XCTAssertTrue(outcome.summary.contains("isolated"), "summary carries an isolation note")
        // No changes ⇒ worktree discarded; no stray mythos worktree/branch remains.
        let branches = try? FileManager.default.contentsOfDirectory(atPath: repo + "/.git/worktrees")
        XCTAssertTrue((branches ?? []).isEmpty, "empty worktree was cleaned up")
    }
}
