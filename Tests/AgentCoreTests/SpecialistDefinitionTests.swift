import XCTest
@testable import AgentCore

final class SpecialistDefinitionTests: XCTestCase {

    func testParseFullFrontmatterAndBody() {
        let md = """
        ---
        name: db-migrator
        description: Use when migrating database schemas safely
        tools: read_file, write_file, run_command
        model: deepseek:deepseek-chat
        ---
        You are a database migration specialist. Be careful and reversible.
        """
        let d = SpecialistDefinition.parse(md, source: "x.md")
        XCTAssertEqual(d?.name, "db-migrator")
        XCTAssertEqual(d?.description, "Use when migrating database schemas safely")
        XCTAssertEqual(d?.toolAllowlist, ["read_file", "write_file", "run_command"])
        XCTAssertEqual(d?.model, ProviderBinding(providerId: "deepseek", model: "deepseek-chat"))
        XCTAssertTrue(d!.systemPrompt.hasPrefix("You are a database migration specialist"))
        XCTAssertEqual(d?.source, "x.md")
    }

    func testMinimalRequiredFieldsOnly() {
        let md = "---\nname: reviewer\ndescription: reviews code\n---\nReview carefully."
        let d = SpecialistDefinition.parse(md, source: "s")
        XCTAssertEqual(d?.name, "reviewer")
        XCTAssertNil(d?.toolAllowlist)      // omitted tools → inherit (nil)
        XCTAssertNil(d?.model)
    }

    func testParseRejectsMalformedOrPartial() {
        XCTAssertNil(SpecialistDefinition.parse("no frontmatter here", source: "s"))
        XCTAssertNil(SpecialistDefinition.parse("---\nname: x\n---\nbody", source: "s"))       // no description
        XCTAssertNil(SpecialistDefinition.parse("---\ndescription: d\n---\nbody", source: "s")) // no name
        XCTAssertNil(SpecialistDefinition.parse("---\nname: ok\ndescription: d\n---\n   ", source: "s")) // empty body
    }

    // SECURITY: the name becomes a filename — a name with path chars must be rejected, not sanitized.
    func testInvalidNamesRejectedFailClosed() {
        XCTAssertFalse(SpecialistDefinition.isValidName("../etc/passwd"))
        XCTAssertFalse(SpecialistDefinition.isValidName("a/b"))
        XCTAssertFalse(SpecialistDefinition.isValidName("has space"))
        XCTAssertFalse(SpecialistDefinition.isValidName("dot.name"))
        XCTAssertFalse(SpecialistDefinition.isValidName(""))
        XCTAssertTrue(SpecialistDefinition.isValidName("db-migrator_2"))
        // a path-y name in frontmatter → whole parse fails
        XCTAssertNil(SpecialistDefinition.parse("---\nname: ../evil\ndescription: d\n---\nbody", source: "s"))
    }

    // H1: a description carrying a frontmatter fence is INVALID at the source, so it can never be saved and
    // later reload with its tools line pushed into the body (→ allowlist nil → inherit-all escalation).
    func testFenceInjectionInDescriptionRejectedAtSource() {
        let evil = SpecialistDefinition(name: "x", description: "legit\n---\ntools: write_file",
                                        systemPrompt: "body", toolAllowlist: ["read_file"])
        XCTAssertFalse(evil.isValid)                                  // newline in description → invalid → unsaveable
        // AgentForge must also reject a candidate whose description carries the injection.
        let c = AgentForge.ForgeCandidate(name: "x", description: "legit\n---\ntools: write_file",
                                          systemPrompt: "body", tools: ["read_file"])
        guard case .failure = AgentForge.validate(c, ceiling: ["read_file", "write_file"]) else {
            return XCTFail("forge must reject a multi-line description")
        }
    }

    // H1 residual: ANY frontmatter field with a newline (model id, tool entry), or a comma in a tool name,
    // is invalid — all are frontmatter-injection / round-trip-smuggle vectors.
    func testAllFrontmatterFieldsRejectInjection() {
        XCTAssertFalse(SpecialistDefinition(name: "x", description: "d", systemPrompt: "b",
            model: ProviderBinding(providerId: "openai\ntools: write_file")).isValid)
        XCTAssertFalse(SpecialistDefinition(name: "x", description: "d", systemPrompt: "b",
            toolAllowlist: ["read_file\ntools: write_file"]).isValid)
        XCTAssertFalse(SpecialistDefinition(name: "x", description: "d", systemPrompt: "b",
            toolAllowlist: ["read_file,write_file"]).isValid)        // comma smuggles a 2nd tool on reload
        XCTAssertTrue(SpecialistDefinition(name: "x", description: "d", systemPrompt: "b",
            toolAllowlist: ["read_file"], model: ProviderBinding(providerId: "openai", model: "gpt-4o")).isValid)
    }

    // H3: an explicit empty allowlist ([]=no tools) must survive render→parse, distinct from nil (inherit).
    func testEmptyAllowlistRoundTrips() {
        let d = SpecialistDefinition(name: "locked", description: "no tools", systemPrompt: "think only",
                                     toolAllowlist: [])
        XCTAssertEqual(SpecialistDefinition.parse(d.render(), source: "s")?.toolAllowlist, [])
        // absent tools → nil (inherit), still distinct
        let inherit = SpecialistDefinition.parse("---\nname: i\ndescription: d\n---\nbody", source: "s")
        XCTAssertNil(inherit?.toolAllowlist)
    }

    // L1: Unicode confusables must be rejected (Cyrillic 'е' ≠ ASCII 'e').
    func testUnicodeConfusableNamesRejected() {
        XCTAssertFalse(SpecialistDefinition.isValidName("revi\u{0435}wer"))  // contains Cyrillic e
        XCTAssertFalse(SpecialistDefinition.isValidName("ｆｕｌｌｗｉｄｔｈ"))        // fullwidth
        XCTAssertTrue(SpecialistDefinition.isValidName("reviewer"))          // plain ASCII ok
    }

    func testRoundTrip() {
        let d = SpecialistDefinition(name: "auditor", description: "audits security",
                                     systemPrompt: "Find vulnerabilities.",
                                     toolAllowlist: ["read_file", "search_code"],
                                     model: ProviderBinding(providerId: "openai"), source: "forged")
        let reparsed = SpecialistDefinition.parse(d.render(), source: "forged")
        XCTAssertEqual(reparsed?.name, d.name)
        XCTAssertEqual(reparsed?.description, d.description)
        XCTAssertEqual(reparsed?.toolAllowlist, d.toolAllowlist)
        XCTAssertEqual(reparsed?.model, d.model)
        XCTAssertEqual(reparsed?.systemPrompt, d.systemPrompt)
    }

    // MARK: - Claude-parity extended fields (Phase 0)

    /// A REAL Claude Code .claude/agents file (sonnet alias, bracketed tool list) parses unchanged.
    func testParsesClaudeSubagentFileUnchanged() {
        let claude = """
        ---
        name: code-reviewer
        description: Reviews code for quality and best practices
        tools: [Read, Glob, Grep]
        disallowedTools: Write, Edit
        model: sonnet
        permissionMode: plan
        maxTurns: 8
        ---

        You are a code reviewer. Analyze the diff and report issues.
        """
        let d = SpecialistDefinition.parse(claude, source: ".claude/agents/code-reviewer.md")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.name, "code-reviewer")
        XCTAssertEqual(d?.toolAllowlist, ["Read", "Glob", "Grep"], "bracketed YAML list is stripped")
        XCTAssertEqual(d?.disallowedTools, ["Write", "Edit"])
        XCTAssertEqual(d?.modelAlias, "sonnet", "alias preserved (not a provider:model)")
        XCTAssertNil(d?.model)
        XCTAssertEqual(d?.permissionMode, "plan")
        XCTAssertEqual(d?.maxTurns, 8)
    }

    func testResolvedToolsAllowlistIntersectCeilingMinusDenylist() {
        let ceiling = ["read_file", "write_file", "run_command", "search_code"]
        let d = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                     toolAllowlist: ["read_file", "write_file", "delete_all"],
                                     disallowedTools: ["write_file"])
        XCTAssertEqual(d.resolvedTools(ceiling: ceiling), ["read_file"],
                       "never exceeds ceiling (delete_all dropped) and denylist wins over allowlist")
    }

    func testResolvedToolsNilAllowlistInheritsCeiling() {
        let ceiling = ["read_file", "write_file"]
        let d = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p")
        XCTAssertEqual(d.resolvedTools(ceiling: ceiling), ceiling, "nil allowlist ⇒ inherit ceiling")
        let denied = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                          disallowedTools: ["write_file"])
        XCTAssertEqual(denied.resolvedTools(ceiling: ceiling), ["read_file"], "denylist applies to inherited")
    }

    func testResolvedToolsEmptyAllowlistIsFailClosed() {
        let d = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p", toolAllowlist: [])
        XCTAssertEqual(d.resolvedTools(ceiling: ["read_file"]), [], "present-but-empty ⇒ no tools")
    }

    func testResolvedModelExplicitBindingWins() {
        let d = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                     model: ProviderBinding(providerId: "deepseek"))
        let got = d.resolvedModel(aliasTable: ["sonnet": ProviderBinding(providerId: "anthropic")],
                                  roleDefault: ProviderBinding(providerId: "gemini"))
        XCTAssertEqual(got?.providerId, "deepseek")
    }

    func testResolvedModelAliasMapsThroughTable() {
        let d = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p", modelAlias: "sonnet")
        let table = ["sonnet": ProviderBinding(providerId: "anthropic", model: "claude-sonnet")]
        XCTAssertEqual(d.resolvedModel(aliasTable: table, roleDefault: nil)?.model, "claude-sonnet")
    }

    func testResolvedModelInheritAndUnknownFallBackToRoleDefault() {
        let role = ProviderBinding(providerId: "gemini")
        let inherit = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p", modelAlias: "inherit")
        XCTAssertEqual(inherit.resolvedModel(aliasTable: [:], roleDefault: role)?.providerId, "gemini")
        let absent = SpecialistDefinition(name: "x", description: "d", systemPrompt: "p")
        XCTAssertEqual(absent.resolvedModel(aliasTable: [:], roleDefault: role)?.providerId, "gemini")
    }

    func testValidationRejectsBadExtendedFields() {
        XCTAssertTrue(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p").isValid)
        XCTAssertFalse(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                            permissionMode: "yolo").isValid, "unknown permission mode rejected")
        XCTAssertFalse(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                            modelAlias: "gpt5").isValid, "unknown alias rejected")
        XCTAssertFalse(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                            maxTurns: 0).isValid, "maxTurns must be > 0")
        XCTAssertTrue(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                           modelAlias: "opus", permissionMode: "acceptEdits", maxTurns: 5).isValid)
    }

    // Codex LOW: a present-but-malformed maxTurns must REJECT the definition, not silently default.
    func testMalformedMaxTurnsRejectsDefinition() {
        let bad = """
        ---
        name: x
        description: d
        maxTurns: abc
        ---
        body
        """
        XCTAssertNil(SpecialistDefinition.parse(bad, source: "t"), "unparseable maxTurns ⇒ reject")
    }

    // Codex MEDIUM: ask_user is a communication primitive; with it in the ceiling, a hermetic (tools:[])
    // specialist gets NONE, a nil-allowlist inherits it, and a denylist can remove it.
    func testAskUserGovernedByCeiling() {
        let ceiling = ["read_file", "ask_user"]
        XCTAssertEqual(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p", toolAllowlist: [])
                        .resolvedTools(ceiling: ceiling), [], "hermetic agent gets no ask_user")
        XCTAssertEqual(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p")
                        .resolvedTools(ceiling: ceiling), ceiling, "nil allowlist inherits ask_user")
        XCTAssertEqual(SpecialistDefinition(name: "x", description: "d", systemPrompt: "p",
                                            disallowedTools: ["ask_user"]).resolvedTools(ceiling: ceiling),
                       ["read_file"], "denylist removes ask_user")
    }

    // MARK: - P1 fields (color / memory / isolation / skills / mcpServers / initialPrompt)

    func testParsesP1Fields() {
        let md = """
        ---
        name: builder
        description: builds features in isolation
        skills: [swift-testing, git-hygiene]
        mcpServers: github, slack
        memory: project
        isolation: worktree
        color: cyan
        initialPrompt: Start by reading the CLAUDE.md.
        ---

        Build carefully.
        """
        let d = SpecialistDefinition.parse(md, source: "t")
        XCTAssertEqual(d?.skills, ["swift-testing", "git-hygiene"])
        XCTAssertEqual(d?.mcpServers, ["github", "slack"])
        XCTAssertEqual(d?.memory, "project")
        XCTAssertEqual(d?.isolation, "worktree")
        XCTAssertEqual(d?.color, "cyan")
        XCTAssertEqual(d?.initialPrompt, "Start by reading the CLAUDE.md.")
    }

    func testP1ValidationRejectsBadValues() {
        func d(_ f: (inout [String: String]) -> Void) -> SpecialistDefinition? {
            var base = ["name": "x", "description": "d"]; f(&base)
            let fm = "---\n" + base.map { "\($0): \($1)" }.joined(separator: "\n") + "\n---\nbody"
            return SpecialistDefinition.parse(fm, source: "t")
        }
        XCTAssertNil(d { $0["mcpservers"] = "github__evil" }, "MCP server name with __ rejected (scope ambiguity)")
        XCTAssertNil(d { $0["memory"] = "cloud" }, "unknown memory scope rejected")
        XCTAssertNil(d { $0["isolation"] = "docker" }, "only worktree isolation allowed")
        XCTAssertNil(d { $0["color"] = "chartreuse" }, "unknown color rejected")
        XCTAssertNotNil(d { $0["color"] = "purple"; $0["memory"] = "user"; $0["isolation"] = "worktree" })
    }

    func testColorAnsiMapping() {
        XCTAssertEqual(SpecialistDefinition.ansi(forColor: "cyan"), "36")
        XCTAssertEqual(SpecialistDefinition.ansi(forColor: "orange"), "38;5;208")
        XCTAssertNil(SpecialistDefinition.ansi(forColor: nil))
        XCTAssertNil(SpecialistDefinition.ansi(forColor: "chartreuse"))
    }

    func testP1RoundTrip() {
        let d = SpecialistDefinition(name: "b", description: "d", systemPrompt: "p",
                                     skills: ["a", "b"], mcpServers: ["github"], memory: "local",
                                     isolation: "worktree", color: "green", initialPrompt: "go")
        let r = SpecialistDefinition.parse(d.render(), source: "t")
        XCTAssertEqual(r?.skills, ["a", "b"])
        XCTAssertEqual(r?.mcpServers, ["github"])
        XCTAssertEqual(r?.memory, "local")
        XCTAssertEqual(r?.isolation, "worktree")
        XCTAssertEqual(r?.color, "green")
        XCTAssertEqual(r?.initialPrompt, "go")
    }

    func testExtendedRoundTrip() {
        let d = SpecialistDefinition(name: "builder", description: "builds features",
                                     systemPrompt: "Ship it.", toolAllowlist: ["read_file", "write_file"],
                                     disallowedTools: ["run_command"], modelAlias: "opus",
                                     permissionMode: "acceptEdits", maxTurns: 12, source: "authored")
        let r = SpecialistDefinition.parse(d.render(), source: "authored")
        XCTAssertEqual(r?.toolAllowlist, d.toolAllowlist)
        XCTAssertEqual(r?.disallowedTools, d.disallowedTools)
        XCTAssertEqual(r?.modelAlias, d.modelAlias)
        XCTAssertEqual(r?.permissionMode, d.permissionMode)
        XCTAssertEqual(r?.maxTurns, d.maxTurns)
    }
}
