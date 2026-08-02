import XCTest
@testable import Kist

/// Pins the CLI surface: argument parsing precedence + flag handling. The shell's contract with
/// the user — easy to break silently, so it's tested deterministically.
final class KistOptionsTests: XCTestCase {

    func testGoalFromPositionalArgs() {
        let o = KistOptions.parse(["list", "the", "files"])
        XCTAssertEqual(o.goal, "list the files")
        XCTAssertFalse(o.showHelp)
    }

    func testNoArgsIsInteractive() {
        let o = KistOptions.parse([])
        XCTAssertNil(o.goal)   // nil goal → REPL
    }

    // Autopilot is an UMBRELLA: --auto (and its --danger alias) MUST imply yolo + allow-shell +
    // a FORCED sandbox. The sandbox-forcing is the trust invariant — autonomy bought with isolation.
    func testAutoImpliesYoloShellAndForcedSandbox() {
        for flag in ["--auto", "--danger"] {
            let o = KistOptions.parse([flag, "go build it"])
            XCTAssertTrue(o.auto, "\(flag): auto set")
            XCTAssertTrue(o.yolo, "\(flag): implies yolo")
            XCTAssertTrue(o.allowShell, "\(flag): implies allow-shell")
            XCTAssertTrue(o.sandbox, "\(flag): FORCES sandbox")
            XCTAssertEqual(o.goal, "go build it")
        }
    }

    func testThinkFlagEnablesExtendedThinking() {
        for flag in ["--think", "--thinking"] {
            let o = KistOptions.parse([flag, "reason about this"])
            XCTAssertTrue(o.extendedThinking, "\(flag): enables extended thinking")
            XCTAssertEqual(o.goal, "reason about this")
        }
        XCTAssertFalse(KistOptions.parse(["just a goal"]).extendedThinking, "default: thinking off")
    }

    func testNonAutoLeavesSandboxOptIn() {
        let o = KistOptions.parse(["--yolo", "do a thing"])  // yolo alone must NOT force a sandbox
        XCTAssertTrue(o.yolo)
        XCTAssertFalse(o.auto)
        XCTAssertFalse(o.sandbox)
        XCTAssertFalse(o.allowShell)
    }

    func testProviderAndModelFlags() {
        let o = KistOptions.parse(["--provider", "gemini", "--model", "gemini-2.5-flash", "do a thing"])
        XCTAssertEqual(o.providerId, "gemini")
        XCTAssertEqual(o.model, "gemini-2.5-flash")
        XCTAssertEqual(o.goal, "do a thing")
    }

    func testModelVetFlag() {
        let o = KistOptions.parse(["--model-vet", "hf:owner/repo"])
        XCTAssertEqual(o.modelVet, "hf:owner/repo")
        XCTAssertNil(o.goal)

        let alias = KistOptions.parse(["--vet-model", "ollama:qwen2.5-coder:7b"])
        XCTAssertEqual(alias.modelVet, "ollama:qwen2.5-coder:7b")
        XCTAssertTrue(KistOptions.helpText.contains("--model-vet <spec>"))

        let acquire = KistOptions.parse(["--model-acquire", ".kist/learning/local-models/model.json"])
        XCTAssertEqual(acquire.modelAcquire, ".kist/learning/local-models/model.json")
        XCTAssertNil(acquire.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--model-acquire <json>"))

        let run = KistOptions.parse(["--model-run", "dry-run", ".kist/learning/local-models/model.json"])
        XCTAssertEqual(run.modelRunStage, "dry-run")
        XCTAssertEqual(run.modelRunManifest, ".kist/learning/local-models/model.json")
        XCTAssertNil(run.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--model-run <stage> <json>"))
    }

    func testModelCommandFlagsRequireOperands() {
        let vet = KistOptions.parse(["--model-vet"])
        XCTAssertTrue(vet.optionErrors.contains { $0.contains("--model-vet requires") })
        XCTAssertNil(vet.modelVet)

        let acquire = KistOptions.parse(["--model-acquire"])
        XCTAssertTrue(acquire.optionErrors.contains { $0.contains("--model-acquire requires") })
        XCTAssertNil(acquire.modelAcquire)

        let runNoArgs = KistOptions.parse(["--model-run"])
        XCTAssertTrue(runNoArgs.optionErrors.contains { $0.contains("--model-run requires") })
        XCTAssertNil(runNoArgs.modelRunStage)

        let runNoManifest = KistOptions.parse(["--model-run", "dry-run"])
        XCTAssertTrue(runNoManifest.optionErrors.contains { $0.contains("--model-run requires") })
        XCTAssertNil(runNoManifest.modelRunManifest)
    }

    func testShortFlags() {
        let o = KistOptions.parse(["-p", "openai", "-m", "gpt-4o", "-C", "/tmp/proj"])
        XCTAssertEqual(o.providerId, "openai")
        XCTAssertEqual(o.model, "gpt-4o")
        XCTAssertEqual(o.project, "/tmp/proj")
    }

    func testPlanAndYoloFlags() {
        let o = KistOptions.parse(["--plan", "--yolo", "build it"])
        XCTAssertTrue(o.planMode)
        XCTAssertTrue(o.yolo)
    }

    func testStickyTurnsFlag() {
        XCTAssertTrue(KistOptions.parse(["hi"]).stickyTurns)                     // default ON (2026-08-02, validated)
        XCTAssertTrue(KistOptions.parse(["--sticky-turns", "hi"]).stickyTurns)    // explicit on
        XCTAssertFalse(KistOptions.parse(["--no-sticky-turns", "hi"]).stickyTurns)         // opt-out disables it
        XCTAssertFalse(KistOptions.parse(["--sticky-turns", "--no-sticky-turns", "hi"]).stickyTurns)  // last-flag opt-out wins
        XCTAssertTrue(KistOptions.parse(["--pinned-bar", "x"]).pinnedBar)        // unrelated bar flag intact
    }

    func testPlanExecuteFlag() {
        XCTAssertTrue(KistOptions.parse(["--plan-execute", "build the thing"]).planExecute)
        XCTAssertFalse(KistOptions.parse(["build the thing"]).planExecute)   // default off
        XCTAssertFalse(KistOptions.parse(["--plan", "x"]).planExecute)        // --plan != --plan-execute
    }

    func testCouncilFlags() {
        let council = KistOptions.parse(["--council", "research", "then", "decide"])
        XCTAssertTrue(council.council)
        XCTAssertFalse(council.councilExecute)
        XCTAssertEqual(council.goal, "research then decide")

        let consult = KistOptions.parse(["--consult", "map", "the", "roadmap"])
        XCTAssertTrue(consult.council)
        XCTAssertFalse(consult.councilExecute)
        XCTAssertEqual(consult.goal, "map the roadmap")

        for flag in ["--council-execute", "--council-build", "--consult-execute"] {
            let o = KistOptions.parse([flag, "turn consensus into tasks"])
            XCTAssertTrue(o.council, "\(flag) should run the council")
            XCTAssertTrue(o.councilExecute, "\(flag) should hand off to plan-execute")
            XCTAssertEqual(o.goal, "turn consensus into tasks")
        }
        XCTAssertTrue(KistOptions.helpText.contains("--council \"<goal>\""))
        XCTAssertTrue(KistOptions.helpText.contains("--council-execute"))
        XCTAssertTrue(KistOptions.helpText.contains("seeds .kist/plan.json"))
    }

    func testEvolveFlags() {
        let o = KistOptions.parse([
            "--evolve",
            "--variants", "4",
            "--evolve-test", "swift test",
            "--evolve-test", "./test.sh",
            "--evolve-timeout", "120",
            "improve research citations",
        ])
        XCTAssertTrue(o.evolve)
        XCTAssertEqual(o.variants, 4)
        XCTAssertEqual(o.evolveBenchmarkCommands, ["swift test", "./test.sh"])
        XCTAssertEqual(o.evolveTimeout, 120)
        XCTAssertEqual(o.goal, "improve research citations")
        XCTAssertTrue(KistOptions.helpText.contains("--evolve"))
        XCTAssertTrue(KistOptions.helpText.contains("--variants <n>"))
    }

    func testEvolveVariantsAndTimeoutAreCapped() {
        let o = KistOptions.parse(["--evolve", "--variants", "99", "--evolve-timeout", "99999", "x"])
        XCTAssertEqual(o.variants, 10)
        XCTAssertEqual(o.evolveTimeout, 3600)
    }

    func testRoleVendorSpecs() {
        let o = KistOptions.parse([
            "--plan-execute",
            "--planner", "openai",
            "--worker", "anthropic:claude-3-5-sonnet",
            "--coder", "deepseek",
            "--critic", "gemini:gemini-2.5-flash",
            "go",
        ])
        XCTAssertEqual(o.plannerSpec, "openai")
        XCTAssertEqual(o.workerSpec, "anthropic:claude-3-5-sonnet")
        XCTAssertEqual(o.coderSpec, "deepseek")
        XCTAssertEqual(o.criticSpec, "gemini:gemini-2.5-flash")
        XCTAssertNil(KistOptions.parse(["go"]).criticSpec)   // defaults unset
        XCTAssertNil(KistOptions.parse(["go"]).coderSpec)
        XCTAssertNil(KistOptions.parse(["go"]).workerSpec)
        XCTAssertTrue(KistOptions.helpText.contains("--coder mimo --worker deepseek --critic gemini"))
    }

    func testBuilderFlagIsCoderAlias() {
        let o = KistOptions.parse(["--builder", "deepseek:deepseek-coder", "build it"])
        XCTAssertEqual(o.coderSpec, "deepseek:deepseek-coder")
        XCTAssertEqual(o.goal, "build it")
    }

    func testRoleProfileFlag() {
        let o = KistOptions.parse(["--roles", "dream", "--builder", "deepseek", "build it"])
        XCTAssertEqual(o.roleProfile, "dream")
        XCTAssertEqual(o.coderSpec, "deepseek")
        XCTAssertEqual(o.goal, "build it")
        XCTAssertTrue(KistOptions.helpText.contains("--roles <name>"))
    }

    func testDelegationDepthParsesAndCaps() {
        XCTAssertEqual(KistOptions.parse(["go"]).delegationDepth, 1)
        XCTAssertEqual(KistOptions.parse(["--delegation-depth", "0", "go"]).delegationDepth, 0)
        XCTAssertEqual(KistOptions.parse(["--delegation-depth", "2", "go"]).delegationDepth, 2)
        XCTAssertEqual(KistOptions.parse(["--delegation-depth", "9", "go"]).delegationDepth, 3)
        XCTAssertEqual(KistOptions.parse(["--delegation-depth", "-1", "go"]).delegationDepth, 1)
        XCTAssertTrue(KistOptions.helpText.contains("--delegation-depth <n>"))
    }

    func testBudgetFlag() {
        XCTAssertEqual(KistOptions.parse(["--budget", "50000", "go"]).budgetTokens, 50_000)
        XCTAssertNil(KistOptions.parse(["go"]).budgetTokens)              // default unset
        XCTAssertNil(KistOptions.parse(["--budget", "notanumber", "go"]).budgetTokens)  // garbage ignored
        XCTAssertNil(KistOptions.parse(["--budget", "0", "go"]).budgetTokens)           // non-positive ignored
    }

    func testNoMemoryFlag() {
        XCTAssertTrue(KistOptions.parse(["--no-memory", "go"]).noMemory)
        XCTAssertFalse(KistOptions.parse(["go"]).noMemory)   // memory ON by default
    }

    func testFetchHostFlagIsRepeatable() {
        let o = KistOptions.parse(["--fetch-host", "docs.swift.org", "--fetch-host", "*.swift.org", "go"])
        XCTAssertEqual(o.fetchAllowedHosts, ["docs.swift.org", "*.swift.org"])
        XCTAssertEqual(o.goal, "go")
        XCTAssertTrue(KistOptions.helpText.contains("--fetch-host <host>"))
    }

    func testPlanDefaultsOff() {
        XCTAssertFalse(KistOptions.parse(["x"]).planMode)
        XCTAssertFalse(KistOptions.parse(["x"]).yolo)
        XCTAssertFalse(KistOptions.parse(["x"]).allowShell)
    }

    func testShellAndSandboxFlags() {
        let o = KistOptions.parse(["--allow-shell", "--sandbox", "run"])
        XCTAssertTrue(o.allowShell)
        XCTAssertTrue(o.sandbox)
    }

    func testMaxIterationsParsesAndIgnoresGarbage() {
        XCTAssertEqual(KistOptions.parse(["--max-iterations", "30", "g"]).maxIterations, 30)
        XCTAssertEqual(KistOptions.parse(["--max-iterations", "notanumber", "g"]).maxIterations, 12)   // default kept
    }

    func testResumeFlags() {
        XCTAssertEqual(KistOptions.parse(["--resume", "abc123"]).resumeId, "abc123")
        XCTAssertTrue(KistOptions.parse(["--resume-last"]).resumeLast)
        XCTAssertTrue(KistOptions.parse(["--list"]).listRuns)
        XCTAssertTrue(KistOptions.parse(["--list-providers"]).listProviders)
    }

    func testOperatorSurfaceFlags() {
        XCTAssertTrue(KistOptions.parse(["--health"]).providerHealth)
        XCTAssertTrue(KistOptions.parse(["--probe-providers"]).probeProviders)
        XCTAssertTrue(KistOptions.parse(["--bench", "build x"]).bench)
        XCTAssertEqual(KistOptions.parse(["--bench", "build x"]).goal, "build x")
        XCTAssertTrue(KistOptions.parse(["--eval", "build x"]).eval)
        XCTAssertTrue(KistOptions.parse(["--research", "plan x"]).research)
        XCTAssertEqual(KistOptions.parse(["--research", "plan x"]).goal, "plan x")
        XCTAssertTrue(KistOptions.parse(["--protocols"]).protocolStatus)
        XCTAssertEqual(KistOptions.parse(["--replay"]).replayId, "latest")
        XCTAssertEqual(KistOptions.parse(["--replay", "abc123"]).replayId, "abc123")
        XCTAssertTrue(KistOptions.helpText.contains("--probe-providers"))
        XCTAssertTrue(KistOptions.helpText.contains("--bench"))
        XCTAssertTrue(KistOptions.helpText.contains("--eval"))
        XCTAssertTrue(KistOptions.helpText.contains("--research"))
        XCTAssertTrue(KistOptions.helpText.contains("--replay"))
    }

    func testHelpFlag() {
        XCTAssertTrue(KistOptions.parse(["--help"]).showHelp)
        XCTAssertTrue(KistOptions.parse(["-h"]).showHelp)
        XCTAssertFalse(KistOptions.helpText.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--plan"))   // help documents plan mode
    }

    func testUnknownFlagsBecomePartOfGoal() {
        // A bare token that isn't a known flag is treated as goal text (not an error).
        let o = KistOptions.parse(["explain", "--unknownish", "thing"])
        XCTAssertEqual(o.goal, "explain --unknownish thing")
    }

    // MARK: --ci-guard (server-authoritative range gate)
    func testCiGuardWithExplicitBaseHead() {
        let o = KistOptions.parse(["--ci-guard", "origin/main", "HEAD"])
        XCTAssertTrue(o.ciGuard)
        XCTAssertEqual(o.ciGuardBase, "origin/main")
        XCTAssertEqual(o.ciGuardHead, "HEAD")
        XCTAssertNil(o.goal, "the refs must be consumed as ci-guard args, not become a goal")
    }

    func testCiGuardWithNoArgsInfersRange() {
        let o = KistOptions.parse(["--ci-guard"])
        XCTAssertTrue(o.ciGuard)
        XCTAssertNil(o.ciGuardBase); XCTAssertNil(o.ciGuardHead)   // inferred from CI env at runtime
    }

    func testCiGuardStopsAtNextFlag() {
        // A following flag must NOT be swallowed as the base ref.
        let o = KistOptions.parse(["--ci-guard", "--project", "/tmp/x"])
        XCTAssertTrue(o.ciGuard)
        XCTAssertNil(o.ciGuardBase, "a flag after --ci-guard is not a ref")
        XCTAssertEqual(o.project, "/tmp/x")
    }
}
