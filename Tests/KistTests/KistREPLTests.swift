import XCTest
import AgentCore
@testable import Kist

final class KistREPLTests: XCTestCase {

    // REGRESSION (the folder-drop screenshot): a dragged-in path begins with "/" but is NOT a
    // slash command — it must reach the agent as a normal message, not "unknown command /Users…".
    func testDraggedPathsAreNotSlashCommands() {
        XCTAssertFalse(KistREPL.isSlashCommand("/Users/lukekist/Desktop/untitled\\ folder whats in this folder"))
        XCTAssertFalse(KistREPL.isSlashCommand("/tmp/a.txt"))
        XCTAssertFalse(KistREPL.isSlashCommand("/Users/luke/Downloads summarize this"))
        XCTAssertFalse(KistREPL.isSlashCommand("/"))                  // bare slash → message
        XCTAssertFalse(KistREPL.isSlashCommand("/var/folders/x.png")) // dot/slash in token
    }

    func testRealSlashCommandsStillParse() {
        for cmd in ["/help", "/exit", "/model", "/fleet-status", "/tasks", "/clear", "/role gemini",
                    "/fleet --agents 3 build it", "/cockpit"] {
            XCTAssertTrue(KistREPL.isSlashCommand(cmd), "\(cmd) should be a command")
        }
        XCTAssertFalse(KistREPL.isSlashCommand("hello world"))        // no leading slash
        XCTAssertFalse(KistREPL.isSlashCommand(""))
    }

    func testFleetArgsUseDefaultAgents() {
        XCTAssertEqual(KistREPL.parseFleetArgs("build the modules", defaultAgents: 5),
                       KistREPL.FleetInvocation(goal: "build the modules", agents: 5))
        XCTAssertEqual(KistREPL.parseFleetArgs("build", defaultAgents: 0),
                       KistREPL.FleetInvocation(goal: "build", agents: 1))
    }

    func testFleetArgsParseAgentCountForms() {
        XCTAssertEqual(KistREPL.parseFleetArgs("--agents 3 build the modules", defaultAgents: 5),
                       KistREPL.FleetInvocation(goal: "build the modules", agents: 3))
        XCTAssertEqual(KistREPL.parseFleetArgs("--agents=2 build the modules", defaultAgents: 5),
                       KistREPL.FleetInvocation(goal: "build the modules", agents: 2))
    }

    func testFleetArgsRejectMalformedAgentCounts() {
        XCTAssertNil(KistREPL.parseFleetArgs("", defaultAgents: 5))
        XCTAssertNil(KistREPL.parseFleetArgs("--agents", defaultAgents: 5))
        XCTAssertNil(KistREPL.parseFleetArgs("--agents nope build", defaultAgents: 5))
        XCTAssertNil(KistREPL.parseFleetArgs("--agents 0 build", defaultAgents: 5))
        XCTAssertNil(KistREPL.parseFleetArgs("--agents=0 build", defaultAgents: 5))
    }

    func testCouncilArgsParseExecuteFlags() {
        XCTAssertEqual(KistREPL.parseCouncilArgs("turn research into a task graph"),
                       KistREPL.CouncilInvocation(goal: "turn research into a task graph", execute: false))
        XCTAssertEqual(KistREPL.parseCouncilArgs("--execute turn research into a task graph"),
                       KistREPL.CouncilInvocation(goal: "turn research into a task graph", execute: true))
        XCTAssertEqual(KistREPL.parseCouncilArgs("--build start the builder"),
                       KistREPL.CouncilInvocation(goal: "start the builder", execute: true))
        XCTAssertEqual(KistREPL.parseCouncilArgs("--start start the builder"),
                       KistREPL.CouncilInvocation(goal: "start the builder", execute: true))
        XCTAssertNil(KistREPL.parseCouncilArgs(""))
        XCTAssertNil(KistREPL.parseCouncilArgs("--execute"))
    }

    func testPlainEnglishForgeIntentParsesAgentCreation() {
        XCTAssertEqual(KistREPL.parseForgeIntent("make me an agent that audits SwiftUI accessibility"),
                       "audits SwiftUI accessibility")
        XCTAssertEqual(KistREPL.parseForgeIntent("spin up an agent for security review of auth flows"),
                       "security review of auth flows")
        XCTAssertEqual(KistREPL.parseForgeIntent("create a persona: calm UX reviewer for terminal output"),
                       "calm UX reviewer for terminal output")
        XCTAssertEqual(KistREPL.parseForgeIntent("forge a specialist who can review provider adapters"),
                       "review provider adapters")
    }

    func testPlainEnglishForgeIntentDoesNotStealNormalAgentTalk() {
        XCTAssertNil(KistREPL.parseForgeIntent("what agents do we have?"))
        XCTAssertNil(KistREPL.parseForgeIntent("have the agent inspect this file"))
        XCTAssertNil(KistREPL.parseForgeIntent("make agent"))
        XCTAssertNil(KistREPL.parseForgeIntent("research agentic coding systems"))
    }

    func testPasteConfirmationSupportsOneTimeAndAlwaysApproval() {
        let att = MediaAttachment(kind: .image, mimeType: "image/png", payload: .inline(Data([1, 2, 3])))
        let prompt = KistREPL.pasteConfirmationPrompt(attachment: att, provider: "gemini")
        XCTAssertTrue(prompt.contains("image/png"))
        XCTAssertTrue(prompt.contains("3 bytes"))
        XCTAssertTrue(prompt.contains("[y/N/a]"))
        XCTAssertTrue(KistREPL.isAffirmative("yes"))
        XCTAssertTrue(KistREPL.isAlways("a"))
        XCTAssertTrue(KistREPL.isAlways("yolo"))
        XCTAssertFalse(KistREPL.isAffirmative("a"))
        XCTAssertFalse(KistREPL.isAlways("no"))
    }

    func testRoleCommandParsesAssignmentsAliasesAndReset() {
        XCTAssertEqual(KistREPL.parseRoleCommand(""), .show)
        XCTAssertEqual(KistREPL.parseRoleCommand("show"), .show)
        XCTAssertEqual(KistREPL.parseRoleCommand("reset"), .reset)
        XCTAssertEqual(KistREPL.parseRoleCommand("profiles"), .profiles)
        XCTAssertEqual(KistREPL.parseRoleCommand("save dream"), .save("dream"))
        XCTAssertEqual(KistREPL.parseRoleCommand("load dream"), .load("dream"))
        XCTAssertEqual(KistREPL.parseRoleCommand("use dream"), .load("dream"))
        XCTAssertEqual(KistREPL.parseRoleCommand("delete dream"), .delete("dream"))
        XCTAssertEqual(KistREPL.parseRoleCommand("rm dream"), .delete("dream"))
        XCTAssertEqual(KistREPL.parseRoleCommand("builder deepseek"),
                       .assign(.coder, ProviderBinding(providerId: "deepseek")))
        XCTAssertEqual(KistREPL.parseRoleCommand("builder=deepseek"),
                       .assign(.coder, ProviderBinding(providerId: "deepseek")))
        XCTAssertEqual(KistREPL.parseRoleCommand("set critic gemini:gemini-2.5-flash"),
                       .assign(.critic, ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash")))
        XCTAssertEqual(KistREPL.parseRoleCommand("researcher anthropic"),
                       .assign(.worker, ProviderBinding(providerId: "anthropic")))
        XCTAssertNil(KistREPL.parseRoleCommand("builder"))
        XCTAssertNil(KistREPL.parseRoleCommand("unknown deepseek"))
        XCTAssertNil(KistREPL.parseRoleCommand("coder"))
        XCTAssertNil(KistREPL.parseRoleCommand("save"))
        XCTAssertNil(KistREPL.parseRoleCommand("load"))
    }

    func testResolveModelSpecForms() {
        let known = ["mimo": "mimo", "openai": "openai", "gemini": "gemini"]
        let models = ["mimo": ["mimo-v2.5-pro", "mimo-v2.5-flash"], "openai": ["gpt-4o"]]

        // Explicit provider / provider:model.
        XCTAssertEqual(KistREPL.resolveModelSpec("openai", currentProvider: "mimo", knownProviders: known, providerModels: models),
                       ProviderBinding(providerId: "openai"))
        XCTAssertEqual(KistREPL.resolveModelSpec("openai:gpt-4o", currentProvider: "mimo", knownProviders: known, providerModels: models),
                       ProviderBinding(providerId: "openai", model: "gpt-4o"))

        // ":model" keeps the current provider, switches model.
        XCTAssertEqual(KistREPL.resolveModelSpec(":mimo-v2.5-flash", currentProvider: "mimo", knownProviders: known, providerModels: models),
                       ProviderBinding(providerId: "mimo", model: "mimo-v2.5-flash"))

        // A bare token that names a model of the CURRENT provider switches model only.
        XCTAssertEqual(KistREPL.resolveModelSpec("mimo-v2.5-flash", currentProvider: "mimo", knownProviders: known, providerModels: models),
                       ProviderBinding(providerId: "mimo", model: "mimo-v2.5-flash"))

        // Unknown provider / model / empty → nil.
        XCTAssertNil(KistREPL.resolveModelSpec("nonsense", currentProvider: "mimo", knownProviders: known, providerModels: models))
        XCTAssertNil(KistREPL.resolveModelSpec(":", currentProvider: "mimo", knownProviders: known, providerModels: models))
        XCTAssertNil(KistREPL.resolveModelSpec("", currentProvider: "mimo", knownProviders: known, providerModels: models))

        // Eager validation off (empty knownProviders) → permissive, parsed as-is.
        XCTAssertEqual(KistREPL.resolveModelSpec("whatever:x", currentProvider: "mimo", knownProviders: [:], providerModels: [:]),
                       ProviderBinding(providerId: "whatever", model: "x"))
    }

    func testSetDefaultSwitchesFallbackAndKeepsPinnedRoles() {
        var roles = KistREPL.RoleSelection(default: ProviderBinding(providerId: "mimo"))
        let known = ["mimo": "mimo", "openai": "openai", "gemini": "gemini"]

        // Pin one role, then switch the session default.
        XCTAssertNil(roles.assign(.critic, to: ProviderBinding(providerId: "gemini"), knownProviders: known))
        XCTAssertNil(roles.setDefault(ProviderBinding(providerId: "openai", model: "gpt-4o"), knownProviders: known))

        // Default + every UNBOUND role follow the new model; the pinned critic is untouched.
        XCTAssertEqual(roles.fallback, ProviderBinding(providerId: "openai", model: "gpt-4o"))
        XCTAssertEqual(roles.bindings.binding(for: .planner), ProviderBinding(providerId: "openai", model: "gpt-4o"))
        XCTAssertEqual(roles.bindings.binding(for: .coder), ProviderBinding(providerId: "openai", model: "gpt-4o"))
        XCTAssertEqual(roles.bindings.binding(for: .critic), ProviderBinding(providerId: "gemini"))

        // Unknown provider leaves the default unchanged.
        let before = roles
        XCTAssertNotNil(roles.setDefault(ProviderBinding(providerId: "missing"), knownProviders: known))
        XCTAssertEqual(roles, before)

        // Case-insensitive provider id is canonicalized.
        XCTAssertNil(roles.setDefault(ProviderBinding(providerId: "OpenAI"), knownProviders: known))
        XCTAssertEqual(roles.fallback, ProviderBinding(providerId: "openai"))
    }

    func testRoleSelectionAssignsAndValidatesProviders() {
        var roles = KistREPL.RoleSelection(default: ProviderBinding(providerId: "openai", model: "gpt-4.1"))

        XCTAssertNil(roles.assign(.coder, to: ProviderBinding(providerId: "deepseek"), knownProviders: ["openai": "openai", "deepseek": "deepseek"]))
        XCTAssertEqual(roles.bindings.binding(for: .coder), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(roles.bindings.binding(for: .planner), ProviderBinding(providerId: "openai", model: "gpt-4.1"))
        XCTAssertTrue(roles.summary.contains("coder=deepseek"))

        let error = roles.assign(.critic, to: ProviderBinding(providerId: "missing"), knownProviders: ["openai": "openai", "deepseek": "deepseek"])
        XCTAssertNotNil(error)
        XCTAssertEqual(roles.bindings.binding(for: .critic), ProviderBinding(providerId: "openai", model: "gpt-4.1"))

        XCTAssertNil(roles.assign(.planner, to: ProviderBinding(providerId: "OpenAI"), knownProviders: ["openai": "openai", "deepseek": "deepseek"]))
        XCTAssertEqual(roles.bindings.binding(for: .planner), ProviderBinding(providerId: "openai"))

        roles.reset()
        XCTAssertEqual(roles.bindings.binding(for: .coder), ProviderBinding(providerId: "openai", model: "gpt-4.1"))
    }

    func testRoleSelectionValidatesInitialCLIProviders() {
        let valid = KistREPL.RoleSelection(default: ProviderBinding(providerId: "openai"),
                                           coderSpec: "deepseek")
        XCTAssertNil(valid.validationError(knownProviders: ["openai": "openai", "deepseek": "deepseek"]))

        let invalid = KistREPL.RoleSelection(default: ProviderBinding(providerId: "openai"),
                                             criticSpec: "missing")
        XCTAssertEqual(invalid.validationError(knownProviders: ["openai": "openai", "deepseek": "deepseek"]),
                       "unknown critic provider 'missing'")

        let malformed = KistREPL.RoleSelection(default: ProviderBinding(providerId: "openai"),
                                               plannerSpec: ":gpt-4.1")
        XCTAssertEqual(malformed.validationError(knownProviders: ["openai": "openai", "deepseek": "deepseek"]),
                       "invalid planner binding ':gpt-4.1'")
    }

    func testRoleSelectionCanonicalizesProviderAliases() {
        var roles = KistREPL.RoleSelection(default: ProviderBinding(providerId: "OpenAI"),
                                           coderSpec: "DeepSeek",
                                           criticSpec: "Gemini")
        let aliases = ["openai": "openai", "deepseek": "deepseek", "gemini": "gemini"]

        XCTAssertNil(roles.validationError(knownProviders: aliases))
        roles.canonicalizeProviders(knownProviders: aliases)

        XCTAssertEqual(roles.bindings.binding(for: .planner), ProviderBinding(providerId: "openai"))
        XCTAssertEqual(roles.bindings.binding(for: .coder), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(roles.bindings.binding(for: .critic), ProviderBinding(providerId: "gemini"))
    }

    func testRoleSelectionCanStartFromCLIFlags() {
        let roles = KistREPL.RoleSelection(
            default: ProviderBinding(providerId: "openai"),
            plannerSpec: "anthropic:claude-3-5-sonnet",
            workerSpec: "perplexity",
            coderSpec: "deepseek",
            criticSpec: "gemini:gemini-2.5-flash"
        )

        XCTAssertEqual(roles.bindings.binding(for: .planner),
                       ProviderBinding(providerId: "anthropic", model: "claude-3-5-sonnet"))
        XCTAssertEqual(roles.bindings.binding(for: .worker), ProviderBinding(providerId: "perplexity"))
        XCTAssertEqual(roles.bindings.binding(for: .coder), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(roles.bindings.binding(for: .critic),
                       ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
    }

    func testRoleSelectionCanSwitchSessionDefaultModel() {
        var roles = KistREPL.RoleSelection(default: ProviderBinding(providerId: "openai", model: "gpt-4o"))

        XCTAssertNil(roles.setDefault(ProviderBinding(providerId: "DeepSeek"), knownProviders: ["openai": "openai", "deepseek": "deepseek"]))
        XCTAssertEqual(roles.bindings.binding(for: .planner), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(roles.bindings.binding(for: .coder), ProviderBinding(providerId: "deepseek"))

        XCTAssertNil(roles.assign(.critic, to: ProviderBinding(providerId: "gemini"), knownProviders: ["deepseek": "deepseek", "gemini": "gemini"]))
        XCTAssertNil(roles.setDefault(ProviderBinding(providerId: "openai", model: "gpt-4.1"), knownProviders: ["openai": "openai", "gemini": "gemini"]))
        XCTAssertEqual(roles.bindings.binding(for: .planner), ProviderBinding(providerId: "openai", model: "gpt-4.1"))
        XCTAssertEqual(roles.bindings.binding(for: .critic), ProviderBinding(providerId: "gemini"))
    }

    func testModelSpecResolutionSupportsProviderModelAndCurrentProviderModel() {
        let providers = ["openai": "openai", "deepseek": "deepseek"]
        let models = ["openai": ["gpt-4o", "gpt-4.1"], "deepseek": ["deepseek-chat"]]

        XCTAssertEqual(KistREPL.resolveModelSpec("deepseek", currentProvider: "openai",
                                                 knownProviders: providers, providerModels: models),
                       ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(KistREPL.resolveModelSpec("deepseek:deepseek-chat", currentProvider: "openai",
                                                 knownProviders: providers, providerModels: models),
                       ProviderBinding(providerId: "deepseek", model: "deepseek-chat"))
        XCTAssertEqual(KistREPL.resolveModelSpec(":gpt-4.1", currentProvider: "openai",
                                                 knownProviders: providers, providerModels: models),
                       ProviderBinding(providerId: "openai", model: "gpt-4.1"))
        XCTAssertEqual(KistREPL.resolveModelSpec("gpt-4o", currentProvider: "openai",
                                                 knownProviders: providers, providerModels: models),
                       ProviderBinding(providerId: "openai", model: "gpt-4o"))
        XCTAssertNil(KistREPL.resolveModelSpec("missing", currentProvider: "openai",
                                               knownProviders: providers, providerModels: models))
    }

    func testRoleSelectionAppliesSavedProfileAtomically() {
        var roles = KistREPL.RoleSelection(default: ProviderBinding(providerId: "openai"))
        let profile = RoleProfileStore.Profile(
            planner: "OpenAI:gpt-4.1",
            worker: "perplexity",
            coder: "DeepSeek",
            critic: "gemini:gemini-2.5-flash"
        )
        let aliases = ["openai": "openai", "deepseek": "deepseek", "gemini": "gemini", "perplexity": "perplexity"]

        XCTAssertNil(roles.apply(profile, knownProviders: aliases))

        XCTAssertEqual(roles.bindings.binding(for: .planner), ProviderBinding(providerId: "openai", model: "gpt-4.1"))
        XCTAssertEqual(roles.bindings.binding(for: .worker), ProviderBinding(providerId: "perplexity"))
        XCTAssertEqual(roles.bindings.binding(for: .coder), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(roles.bindings.binding(for: .critic), ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))

        let before = roles
        let badProfile = RoleProfileStore.Profile(planner: "missing", worker: "perplexity", coder: "deepseek", critic: "gemini")
        XCTAssertNotNil(roles.apply(badProfile, knownProviders: aliases))
        XCTAssertEqual(roles, before)
    }

    func testSimpleSummaryRendersHumanFourPartShape() {
        let dir = NSTemporaryDirectory() + "summary_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = PlanStore(projectRoot: dir).add(title: "ACTION: finish router")
        let now = Date()
        let spans = [AgentSpan(id: "s1", traceId: "t", kind: .llmCall, vendor: "openai",
                               promptTokens: 100, completionTokens: 20, startedAt: now, endedAt: now)]
        let trajectory = [ActionRecord(tool: "write_file", argsFingerprint: "a", success: true)]

        let summary = KistREPL.renderSimpleSummary(projectRoot: dir, spans: spans, trajectory: trajectory)

        XCTAssertTrue(summary.contains("What happened:"))
        XCTAssertTrue(summary.contains("What changed:"))
        XCTAssertTrue(summary.contains("Tool errors:"))
        XCTAssertTrue(summary.contains("What to do next: [1] ACTION: finish router"))
    }

    /// Dogfood regression: a single recovered tool error (a `run_command` that returned
    /// non-zero, then the agent recovered and finished) must NOT be framed as a run
    /// failure. Old wording "What failed: run_command" read as a run verdict.
    func testToolErrorSummaryDoesNotImplyRunFailure() {
        // No errors → explicit "none", never blank.
        let clean = [ActionRecord(tool: "write_file", argsFingerprint: "a", success: true)]
        XCTAssertEqual(KistREPL.toolErrorSummary(clean), "none recorded")

        // One recovered run_command error + surrounding successes.
        let recovered = [
            ActionRecord(tool: "write_file", argsFingerprint: "a", success: true),
            ActionRecord(tool: "run_command", argsFingerprint: "b", success: false),
            ActionRecord(tool: "run_command", argsFingerprint: "c", success: true),
        ]
        let line = KistREPL.toolErrorSummary(recovered)
        XCTAssertTrue(line.contains("run_command ×1"), "should count the errored tool: \(line)")
        XCTAssertTrue(line.contains("not a run verdict"), "must not imply the run failed: \(line)")
        XCTAssertFalse(line.hasPrefix("run_command,"), "old bare-name framing must be gone: \(line)")

        // Multiple tools → deterministic count-desc, name-asc ordering.
        let multi = [
            ActionRecord(tool: "run_command", argsFingerprint: "x", success: false),
            ActionRecord(tool: "run_command", argsFingerprint: "y", success: false),
            ActionRecord(tool: "edit_file", argsFingerprint: "z", success: false),
        ]
        XCTAssertTrue(KistREPL.toolErrorSummary(multi).hasPrefix("run_command ×2, edit_file ×1"))
    }
}
