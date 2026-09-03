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

    func testSMLRuntimeExportFlags() {
        let o = KistOptions.parse([
            "--sml-runtime-export", "graphs/review.langgraph.json",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-api-workflow-path", "langgraph.review=/retargeted-review",
            "--sml-api-workflow-path", "langgraph.audit=/retargeted-audit",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(o.smlRuntimeExport, "graphs/review.langgraph.json")
        XCTAssertEqual(o.smlRuntimeRole, "reviewer")
        XCTAssertEqual(o.smlRuntimeActor, "operator.test")
        XCTAssertEqual(o.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(o.smlRuntimeAPIWorkflowPathOverrides, [
            "langgraph.audit": "/retargeted-audit",
            "langgraph.review": "/retargeted-review",
        ])
        XCTAssertEqual(o.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(o.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(o.smlRuntimeModelRounds, 3)
        XCTAssertNil(o.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-export <json>"))
        XCTAssertTrue(KistOptions.helpText.contains("runtime source set"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-api-base <path>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-api-workflow-path <id>=<path>"))
    }

    func testSMLRuntimeLaunchFlags() {
        let o = KistOptions.parse([
            "--sml-runtime-launch", "graphs/review.langgraph.json",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(o.smlRuntimeLaunch, "graphs/review.langgraph.json")
        XCTAssertEqual(o.smlRuntimeRole, "reviewer")
        XCTAssertEqual(o.smlRuntimeActor, "operator.test")
        XCTAssertEqual(o.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(o.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(o.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(o.smlRuntimeModelRounds, 3)
        XCTAssertNil(o.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-launch <json>"))

        let alias = KistOptions.parse([
            "--sml-launch", "graphs/review.langgraph.json",
        ])
        XCTAssertEqual(alias.smlRuntimeLaunch, "graphs/review.langgraph.json")
    }

    func testSMLRuntimeOpenAPIFlags() {
        let o = KistOptions.parse([
            "--sml-runtime-openapi", "graphs/review.langgraph.json",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(o.smlRuntimeOpenAPI, "graphs/review.langgraph.json")
        XCTAssertEqual(o.smlRuntimeRole, "reviewer")
        XCTAssertEqual(o.smlRuntimeActor, "operator.test")
        XCTAssertEqual(o.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(o.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(o.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(o.smlRuntimeModelRounds, 3)
        XCTAssertNil(o.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-openapi <json>"))

        let alias = KistOptions.parse([
            "--sml-openapi", "graphs/review.langgraph.json",
        ])
        XCTAssertEqual(alias.smlRuntimeOpenAPI, "graphs/review.langgraph.json")
    }

    func testSMLRuntimeDescriptorAdapterFlags() {
        let modelRouter = KistOptions.parse([
            "--sml-runtime-model-router", "graphs/review.langgraph.json",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(modelRouter.smlRuntimeModelRouter, "graphs/review.langgraph.json")
        XCTAssertEqual(modelRouter.smlRuntimeRole, "reviewer")
        XCTAssertEqual(modelRouter.smlRuntimeActor, "operator.test")
        XCTAssertEqual(modelRouter.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(modelRouter.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(modelRouter.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(modelRouter.smlRuntimeModelRounds, 3)
        XCTAssertNil(modelRouter.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-model-router <json>"))

        let onyx = KistOptions.parse([
            "--sml-runtime-onyx", "graphs/review.langgraph.json",
            "--sml-workflow", "langgraph.review",
        ])
        XCTAssertEqual(onyx.smlRuntimeOnyx, "graphs/review.langgraph.json")
        XCTAssertEqual(onyx.smlRuntimeWorkflowID, "langgraph.review")
        XCTAssertTrue(onyx.optionErrors.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-onyx <json> [--sml-workflow <id>]"))

        let planning = KistOptions.parse([
            "--sml-runtime-planning", "graphs/review.langgraph.json",
        ])
        XCTAssertEqual(planning.smlRuntimePlanning, "graphs/review.langgraph.json")
        XCTAssertNil(planning.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-planning <json>"))

        XCTAssertEqual(
            KistOptions.parse(["--sml-model-router", "graphs/review.langgraph.json"]).smlRuntimeModelRouter,
            "graphs/review.langgraph.json"
        )
        XCTAssertEqual(
            KistOptions.parse(["--sml-onyx", "graphs/review.langgraph.json"]).smlRuntimeOnyx,
            "graphs/review.langgraph.json"
        )
        XCTAssertEqual(
            KistOptions.parse(["--sml-planning", "graphs/review.langgraph.json"]).smlRuntimePlanning,
            "graphs/review.langgraph.json"
        )
    }

    func testSMLRuntimeHostDescriptorFlags() {
        let catalog = KistOptions.parse(["--sml-runtime-catalog", "graphs/review.langgraph.json"])
        XCTAssertEqual(catalog.smlRuntimeCatalog, "graphs/review.langgraph.json")
        XCTAssertNil(catalog.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-catalog <json>"))

        let mount = KistOptions.parse(["--sml-runtime-mount", "graphs/review.langgraph.json"])
        XCTAssertEqual(mount.smlRuntimeMount, "graphs/review.langgraph.json")
        XCTAssertNil(mount.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-mount <json>"))

        let agentGuide = KistOptions.parse(["--sml-runtime-agent-guide", "graphs/review.langgraph.json"])
        XCTAssertEqual(agentGuide.smlRuntimeAgentGuide, "graphs/review.langgraph.json")
        XCTAssertNil(agentGuide.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-agent-guide <json>"))

        let hostGuide = KistOptions.parse(["--sml-runtime-host-guide", "graphs/review.langgraph.json"])
        XCTAssertEqual(hostGuide.smlRuntimeHostGuide, "graphs/review.langgraph.json")
        XCTAssertNil(hostGuide.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-host-guide <json>"))

        let hostWiring = KistOptions.parse(["--sml-runtime-host-wiring", "graphs/review.langgraph.json"])
        XCTAssertEqual(hostWiring.smlRuntimeHostWiring, "graphs/review.langgraph.json")
        XCTAssertNil(hostWiring.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-host-wiring <json>"))

        let runbook = KistOptions.parse([
            "--sml-runtime-runbook", "graphs/review.langgraph.json",
            "--sml-workflow", "langgraph.review",
        ])
        XCTAssertEqual(runbook.smlRuntimeRunbook, "graphs/review.langgraph.json")
        XCTAssertEqual(runbook.smlRuntimeWorkflowID, "langgraph.review")
        XCTAssertNil(runbook.goal)
        XCTAssertTrue(runbook.optionErrors.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-runbook <json> [--sml-workflow <id>]"))

        let scaffold = KistOptions.parse([
            "--sml-runtime-scaffold", "graphs/review.langgraph.json",
            "--sml-out", ".kist/generated/review-runtime",
        ])
        XCTAssertEqual(scaffold.smlRuntimeScaffold, "graphs/review.langgraph.json")
        XCTAssertEqual(scaffold.smlRuntimeOutputDirectory, ".kist/generated/review-runtime")
        XCTAssertNil(scaffold.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-scaffold <json> --sml-out <dir>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-out <dir>"))

        XCTAssertEqual(
            KistOptions.parse(["--sml-catalog", "graphs/review.langgraph.json"]).smlRuntimeCatalog,
            "graphs/review.langgraph.json"
        )
        XCTAssertEqual(
            KistOptions.parse(["--sml-mount", "graphs/review.langgraph.json"]).smlRuntimeMount,
            "graphs/review.langgraph.json"
        )
        XCTAssertEqual(
            KistOptions.parse(["--sml-agent-guide", "graphs/review.langgraph.json"]).smlRuntimeAgentGuide,
            "graphs/review.langgraph.json"
        )
        XCTAssertEqual(
            KistOptions.parse(["--sml-host-guide", "graphs/review.langgraph.json"]).smlRuntimeHostGuide,
            "graphs/review.langgraph.json"
        )
        XCTAssertEqual(
            KistOptions.parse(["--sml-host-wiring", "graphs/review.langgraph.json"]).smlRuntimeHostWiring,
            "graphs/review.langgraph.json"
        )
        XCTAssertEqual(
            KistOptions.parse(["--sml-runbook", "graphs/review.langgraph.json"]).smlRuntimeRunbook,
            "graphs/review.langgraph.json"
        )
        let scaffoldAlias = KistOptions.parse([
            "--sml-scaffold", "graphs/review.langgraph.json",
            "--sml-output-dir", ".kist/generated/review-runtime",
        ])
        XCTAssertEqual(scaffoldAlias.smlRuntimeScaffold, "graphs/review.langgraph.json")
        XCTAssertEqual(scaffoldAlias.smlRuntimeOutputDirectory, ".kist/generated/review-runtime")
    }

    func testSMLRuntimeAttachmentsFlags() {
        let o = KistOptions.parse([
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
            "--sml-workflow", "langgraph.review",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(o.smlRuntimeAttachments, "graphs/review.langgraph.json")
        XCTAssertEqual(o.smlRuntimeWorkflowID, "langgraph.review")
        XCTAssertEqual(o.smlRuntimeRole, "reviewer")
        XCTAssertEqual(o.smlRuntimeActor, "operator.test")
        XCTAssertEqual(o.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(o.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(o.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(o.smlRuntimeModelRounds, 3)
        XCTAssertNil(o.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-attachments <json> [--sml-workflow <id>]"))

        let alias = KistOptions.parse([
            "--sml-attachments", "graphs/review.langgraph.json",
        ])
        XCTAssertEqual(alias.smlRuntimeAttachments, "graphs/review.langgraph.json")
    }

    func testSMLRuntimeREPLFlags() {
        let o = KistOptions.parse([
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-workflow", "langgraph.review",
            "--sml-line", #"start TASK-CLI --state {"topic":"runtime"}"#,
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(o.smlRuntimeREPL, "graphs/review.langgraph.json")
        XCTAssertEqual(o.smlRuntimeWorkflowID, "langgraph.review")
        XCTAssertEqual(o.smlRuntimeREPLLine, #"start TASK-CLI --state {"topic":"runtime"}"#)
        XCTAssertEqual(o.smlRuntimeRole, "reviewer")
        XCTAssertEqual(o.smlRuntimeActor, "operator.test")
        XCTAssertEqual(o.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(o.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(o.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(o.smlRuntimeModelRounds, 3)
        XCTAssertNil(o.goal)
        XCTAssertTrue(o.optionErrors.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-repl <json>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-line <line>"))

        let alias = KistOptions.parse([
            "--sml-repl", "graphs/review.langgraph.json",
            "--sml-repl-line", "help",
        ])
        XCTAssertEqual(alias.smlRuntimeREPL, "graphs/review.langgraph.json")
        XCTAssertEqual(alias.smlRuntimeREPLLine, "help")

        let script = KistOptions.parse([
            "--sml-runtime-repl-script", "graphs/review.langgraph.json",
            "--sml-workflow", "langgraph.review",
            "--sml-script", "scripts/review.repl",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(script.smlRuntimeREPLScript, "graphs/review.langgraph.json")
        XCTAssertEqual(script.smlRuntimeWorkflowID, "langgraph.review")
        XCTAssertEqual(script.smlRuntimeREPLScriptPath, "scripts/review.repl")
        XCTAssertEqual(script.smlRuntimeRole, "reviewer")
        XCTAssertEqual(script.smlRuntimeActor, "operator.test")
        XCTAssertEqual(script.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(script.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(script.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(script.smlRuntimeModelRounds, 3)
        XCTAssertNil(script.goal)
        XCTAssertTrue(script.optionErrors.isEmpty)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-repl-script <json>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-script <path>"))

        let scriptAlias = KistOptions.parse([
            "--sml-repl-script", "graphs/review.langgraph.json",
            "--sml-lines", "scripts/review.repl",
        ])
        XCTAssertEqual(scriptAlias.smlRuntimeREPLScript, "graphs/review.langgraph.json")
        XCTAssertEqual(scriptAlias.smlRuntimeREPLScriptPath, "scripts/review.repl")
    }

    func testSMLRuntimeAPIFlags() {
        let o = KistOptions.parse([
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-method", "post",
            "--sml-path", "/source/workflows/langgraph.review/tasks",
            "--sml-body", #"{"task_id":"TASK-API","input":{"topic":"runtime"}}"#,
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(o.smlRuntimeAPI, "graphs/review.langgraph.json")
        XCTAssertEqual(o.smlRuntimeAPIMethod, .post)
        XCTAssertEqual(o.smlRuntimeAPIPath, "/source/workflows/langgraph.review/tasks")
        XCTAssertEqual(o.smlRuntimeAPIBody, #"{"task_id":"TASK-API","input":{"topic":"runtime"}}"#)
        XCTAssertEqual(o.smlRuntimeRole, "reviewer")
        XCTAssertEqual(o.smlRuntimeActor, "operator.test")
        XCTAssertEqual(o.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(o.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(o.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(o.smlRuntimeModelRounds, 3)
        XCTAssertNil(o.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-api <json>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-path <path>"))

        let defaultMethod = KistOptions.parse([
            "--sml-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
        ])
        XCTAssertEqual(defaultMethod.smlRuntimeAPI, "graphs/review.langgraph.json")
        XCTAssertEqual(defaultMethod.smlRuntimeAPIMethod, .get)

        let script = KistOptions.parse([
            "--sml-runtime-api-script", "graphs/review.langgraph.json",
            "--sml-api-script", "scripts/review-api.json",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(script.smlRuntimeAPIScript, "graphs/review.langgraph.json")
        XCTAssertEqual(script.smlRuntimeAPIScriptPath, "scripts/review-api.json")
        XCTAssertEqual(script.smlRuntimeRole, "reviewer")
        XCTAssertEqual(script.smlRuntimeActor, "operator.test")
        XCTAssertEqual(script.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(script.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(script.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(script.smlRuntimeModelRounds, 3)
        XCTAssertNil(script.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-api-script <json>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-api-script <path>"))

        let scriptAlias = KistOptions.parse([
            "--sml-api-batch", "graphs/review.langgraph.json",
            "--sml-requests", "scripts/review-api.json",
        ])
        XCTAssertEqual(scriptAlias.smlRuntimeAPIScript, "graphs/review.langgraph.json")
        XCTAssertEqual(scriptAlias.smlRuntimeAPIScriptPath, "scripts/review-api.json")
    }

    func testSMLRuntimeModelFlags() {
        let o = KistOptions.parse([
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start the review workflow",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(o.smlRuntimeModel, "graphs/review.langgraph.json")
        XCTAssertEqual(o.smlRuntimeModelPrompt, "start the review workflow")
        XCTAssertEqual(o.smlRuntimeRole, "reviewer")
        XCTAssertEqual(o.smlRuntimeActor, "operator.test")
        XCTAssertEqual(o.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(o.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(o.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(o.smlRuntimeModelRounds, 3)
        XCTAssertNil(o.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-model <json>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-prompt <text>"))

        let positionalPrompt = KistOptions.parse([
            "--sml-model-runtime", "graphs/review.langgraph.json",
            "start the review workflow",
        ])
        XCTAssertEqual(positionalPrompt.smlRuntimeModel, "graphs/review.langgraph.json")
        XCTAssertNil(positionalPrompt.smlRuntimeModelPrompt)
        XCTAssertEqual(positionalPrompt.goal, "start the review workflow")

        let script = KistOptions.parse([
            "--sml-runtime-model-script", "graphs/review.langgraph.json",
            "--sml-model-script", "scripts/review.prompts",
            "--sml-role", "reviewer",
            "--sml-actor", "operator.test",
            "--sml-api-base", "/source",
            "--sml-title", "Source Runtime",
            "--sml-version", "2026.08",
            "--sml-model-rounds", "3",
        ])
        XCTAssertEqual(script.smlRuntimeModelScript, "graphs/review.langgraph.json")
        XCTAssertEqual(script.smlRuntimeModelScriptPath, "scripts/review.prompts")
        XCTAssertEqual(script.smlRuntimeRole, "reviewer")
        XCTAssertEqual(script.smlRuntimeActor, "operator.test")
        XCTAssertEqual(script.smlRuntimeAPIBasePath, "/source")
        XCTAssertEqual(script.smlRuntimeTitle, "Source Runtime")
        XCTAssertEqual(script.smlRuntimeVersion, "2026.08")
        XCTAssertEqual(script.smlRuntimeModelRounds, 3)
        XCTAssertNil(script.goal)
        XCTAssertTrue(KistOptions.helpText.contains("--sml-runtime-model-script <json>"))
        XCTAssertTrue(KistOptions.helpText.contains("--sml-model-script <path>"))

        let scriptAlias = KistOptions.parse([
            "--sml-model-batch", "graphs/review.langgraph.json",
            "--sml-prompts", "scripts/review.prompts",
        ])
        XCTAssertEqual(scriptAlias.smlRuntimeModelScript, "graphs/review.langgraph.json")
        XCTAssertEqual(scriptAlias.smlRuntimeModelScriptPath, "scripts/review.prompts")
    }

    func testSMLRuntimeExportFlagsRequireOperands() {
        let export = KistOptions.parse(["--sml-runtime-export"])
        XCTAssertTrue(export.optionErrors.contains { $0.contains("--sml-runtime-export requires") })
        XCTAssertNil(export.smlRuntimeExport)

        let launch = KistOptions.parse(["--sml-runtime-launch"])
        XCTAssertTrue(launch.optionErrors.contains {
            $0.contains("--sml-runtime-launch requires <source.json>")
        })
        XCTAssertNil(launch.smlRuntimeLaunch)

        let openAPI = KistOptions.parse(["--sml-runtime-openapi"])
        XCTAssertTrue(openAPI.optionErrors.contains {
            $0.contains("--sml-runtime-openapi requires <source.json>")
        })
        XCTAssertNil(openAPI.smlRuntimeOpenAPI)

        let modelRouter = KistOptions.parse(["--sml-runtime-model-router"])
        XCTAssertTrue(modelRouter.optionErrors.contains {
            $0.contains("--sml-runtime-model-router requires <source.json>")
        })
        XCTAssertNil(modelRouter.smlRuntimeModelRouter)

        let onyx = KistOptions.parse(["--sml-runtime-onyx"])
        XCTAssertTrue(onyx.optionErrors.contains {
            $0.contains("--sml-runtime-onyx requires <source.json>")
        })
        XCTAssertNil(onyx.smlRuntimeOnyx)

        let planning = KistOptions.parse(["--sml-runtime-planning"])
        XCTAssertTrue(planning.optionErrors.contains {
            $0.contains("--sml-runtime-planning requires <source.json>")
        })
        XCTAssertNil(planning.smlRuntimePlanning)

        let catalog = KistOptions.parse(["--sml-runtime-catalog"])
        XCTAssertTrue(catalog.optionErrors.contains {
            $0.contains("--sml-runtime-catalog requires <source.json>")
        })
        XCTAssertNil(catalog.smlRuntimeCatalog)

        let mount = KistOptions.parse(["--sml-runtime-mount"])
        XCTAssertTrue(mount.optionErrors.contains {
            $0.contains("--sml-runtime-mount requires <source.json>")
        })
        XCTAssertNil(mount.smlRuntimeMount)

        let agentGuide = KistOptions.parse(["--sml-runtime-agent-guide"])
        XCTAssertTrue(agentGuide.optionErrors.contains {
            $0.contains("--sml-runtime-agent-guide requires <source.json>")
        })
        XCTAssertNil(agentGuide.smlRuntimeAgentGuide)

        let hostGuide = KistOptions.parse(["--sml-runtime-host-guide"])
        XCTAssertTrue(hostGuide.optionErrors.contains {
            $0.contains("--sml-runtime-host-guide requires <source.json>")
        })
        XCTAssertNil(hostGuide.smlRuntimeHostGuide)

        let hostWiring = KistOptions.parse(["--sml-runtime-host-wiring"])
        XCTAssertTrue(hostWiring.optionErrors.contains {
            $0.contains("--sml-runtime-host-wiring requires <source.json>")
        })
        XCTAssertNil(hostWiring.smlRuntimeHostWiring)

        let runbook = KistOptions.parse(["--sml-runtime-runbook"])
        XCTAssertTrue(runbook.optionErrors.contains {
            $0.contains("--sml-runtime-runbook requires <source.json>")
        })
        XCTAssertNil(runbook.smlRuntimeRunbook)

        let scaffold = KistOptions.parse(["--sml-runtime-scaffold"])
        XCTAssertTrue(scaffold.optionErrors.contains {
            $0.contains("--sml-runtime-scaffold requires <source.json>")
        })
        XCTAssertNil(scaffold.smlRuntimeScaffold)

        let scaffoldMissingOutput = KistOptions.parse([
            "--sml-runtime-scaffold", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(scaffoldMissingOutput.optionErrors.contains {
            $0.contains("--sml-runtime-scaffold requires --sml-out <dir>")
        })
        XCTAssertEqual(scaffoldMissingOutput.smlRuntimeScaffold, "graphs/review.langgraph.json")
        XCTAssertNil(scaffoldMissingOutput.smlRuntimeOutputDirectory)

        let output = KistOptions.parse(["--sml-out"])
        XCTAssertTrue(output.optionErrors.contains {
            $0.contains("--sml-out requires <dir>")
        })
        XCTAssertNil(output.smlRuntimeOutputDirectory)

        let outputOnly = KistOptions.parse(["--sml-out", ".kist/generated/review-runtime"])
        XCTAssertTrue(outputOnly.optionErrors.contains {
            $0.contains("--sml-out requires --sml-runtime-scaffold <source.json>")
        })
        XCTAssertEqual(outputOnly.smlRuntimeOutputDirectory, ".kist/generated/review-runtime")

        let role = KistOptions.parse(["--sml-role"])
        XCTAssertTrue(role.optionErrors.contains { $0.contains("--sml-role requires") })

        let apiBase = KistOptions.parse(["--sml-api-base"])
        XCTAssertTrue(apiBase.optionErrors.contains { $0.contains("--sml-api-base requires") })

        let apiWorkflowPathMissing = KistOptions.parse(["--sml-api-workflow-path"])
        XCTAssertTrue(apiWorkflowPathMissing.optionErrors.contains {
            $0.contains("--sml-api-workflow-path requires <workflow-id>=<path>")
        })
        XCTAssertTrue(apiWorkflowPathMissing.smlRuntimeAPIWorkflowPathOverrides.isEmpty)

        let apiWorkflowPathMalformed = KistOptions.parse([
            "--sml-api-workflow-path", "langgraph.review",
        ])
        XCTAssertTrue(apiWorkflowPathMalformed.optionErrors.contains {
            $0.contains("--sml-api-workflow-path requires <workflow-id>=<path>")
        })
        XCTAssertTrue(apiWorkflowPathMalformed.smlRuntimeAPIWorkflowPathOverrides.isEmpty)

        let apiWorkflowPathEmptyWorkflow = KistOptions.parse([
            "--sml-api-workflow-path", "=/review",
        ])
        XCTAssertTrue(apiWorkflowPathEmptyWorkflow.optionErrors.contains {
            $0.contains("--sml-api-workflow-path requires <workflow-id>=<path>")
        })
        XCTAssertTrue(apiWorkflowPathEmptyWorkflow.smlRuntimeAPIWorkflowPathOverrides.isEmpty)

        let apiWorkflowPathEmptyPath = KistOptions.parse([
            "--sml-api-workflow-path", "langgraph.review=",
        ])
        XCTAssertTrue(apiWorkflowPathEmptyPath.optionErrors.contains {
            $0.contains("--sml-api-workflow-path requires <workflow-id>=<path>")
        })
        XCTAssertTrue(apiWorkflowPathEmptyPath.smlRuntimeAPIWorkflowPathOverrides.isEmpty)

        let duplicateAPIWorkflowPath = KistOptions.parse([
            "--sml-api-workflow-path", "langgraph.review=/review",
            "--sml-api-workflow-path", "langgraph.review=/other",
        ])
        XCTAssertTrue(duplicateAPIWorkflowPath.optionErrors.contains {
            $0.contains("--sml-api-workflow-path repeats workflow id 'langgraph.review'")
        })
        XCTAssertEqual(duplicateAPIWorkflowPath.smlRuntimeAPIWorkflowPathOverrides, [
            "langgraph.review": "/review",
        ])

        let rounds = KistOptions.parse(["--sml-model-rounds", "9"])
        XCTAssertTrue(rounds.optionErrors.contains { $0.contains("--sml-model-rounds requires") })
        XCTAssertNil(rounds.smlRuntimeModelRounds)
    }

    func testSMLRuntimeAttachmentsFlagsRequireRunnableMode() {
        let attachments = KistOptions.parse(["--sml-runtime-attachments"])
        XCTAssertTrue(attachments.optionErrors.contains {
            $0.contains("--sml-runtime-attachments requires <source.json>")
        })
        XCTAssertNil(attachments.smlRuntimeAttachments)

        let exportConflict = KistOptions.parse([
            "--sml-runtime-export", "graphs/review.langgraph.json",
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(exportConflict.optionErrors.contains {
            $0.contains("--sml-runtime-export conflicts with --sml-runtime-attachments")
        })

        let launchConflict = KistOptions.parse([
            "--sml-runtime-launch", "graphs/review.langgraph.json",
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(launchConflict.optionErrors.contains {
            $0.contains("--sml-runtime-launch conflicts with --sml-runtime-attachments")
        })

        let replConflict = KistOptions.parse([
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "help",
        ])
        XCTAssertTrue(replConflict.optionErrors.contains {
            $0.contains("--sml-runtime-attachments conflicts with --sml-runtime-repl")
        })

        let apiConflict = KistOptions.parse([
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
        ])
        XCTAssertTrue(apiConflict.optionErrors.contains {
            $0.contains("--sml-runtime-attachments conflicts with --sml-runtime-api")
        })

        let openAPIConflict = KistOptions.parse([
            "--sml-runtime-openapi", "graphs/review.langgraph.json",
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(openAPIConflict.optionErrors.contains {
            $0.contains("--sml-runtime-openapi conflicts with --sml-runtime-attachments")
        })

        let onyxConflict = KistOptions.parse([
            "--sml-runtime-onyx", "graphs/review.langgraph.json",
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(onyxConflict.optionErrors.contains {
            $0.contains("--sml-runtime-onyx conflicts with --sml-runtime-attachments")
        })

        let modelConflict = KistOptions.parse([
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
        ])
        XCTAssertTrue(modelConflict.optionErrors.contains {
            $0.contains("--sml-runtime-attachments conflicts with --sml-runtime-model")
        })

        let descriptorConflict = KistOptions.parse([
            "--sml-runtime-catalog", "graphs/review.langgraph.json",
            "--sml-runtime-host-wiring", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(descriptorConflict.optionErrors.contains {
            $0.contains("--sml-runtime-catalog conflicts with --sml-runtime-host-wiring")
        })

        let scaffoldConflict = KistOptions.parse([
            "--sml-runtime-scaffold", "graphs/review.langgraph.json",
            "--sml-out", ".kist/generated/review-runtime",
            "--sml-runtime-attachments", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(scaffoldConflict.optionErrors.contains {
            $0.contains("--sml-runtime-scaffold conflicts with --sml-runtime-attachments")
        })
    }

    func testSMLRuntimeREPLFlagsRequireRunnableMode() {
        let repl = KistOptions.parse(["--sml-runtime-repl"])
        XCTAssertTrue(repl.optionErrors.contains { $0.contains("--sml-runtime-repl requires <source.json>") })
        XCTAssertNil(repl.smlRuntimeREPL)

        let interactive = KistOptions.parse([
            "--sml-runtime-repl", "graphs/review.langgraph.json",
        ])
        XCTAssertNil(interactive.smlRuntimeREPLLine)
        XCTAssertTrue(interactive.optionErrors.isEmpty,
                      "omitting --sml-line selects the interactive REPL")
        XCTAssertTrue(KistOptions.helpText.contains(
            "--sml-runtime-repl <json> [--sml-line <line>]"
        ))

        let blankLine = KistOptions.parse([
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "   ",
        ])
        XCTAssertTrue(blankLine.optionErrors.contains {
            $0.contains("--sml-line must not be blank")
        })

        let lineOnly = KistOptions.parse(["--sml-line", "help"])
        XCTAssertTrue(lineOnly.optionErrors.contains { $0.contains("--sml-line requires --sml-runtime-repl") })

        let replScript = KistOptions.parse(["--sml-runtime-repl-script"])
        XCTAssertTrue(replScript.optionErrors.contains {
            $0.contains("--sml-runtime-repl-script requires <source.json>")
        })
        XCTAssertNil(replScript.smlRuntimeREPLScript)

        let missingScript = KistOptions.parse([
            "--sml-runtime-repl-script", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(missingScript.optionErrors.contains {
            $0.contains("--sml-runtime-repl-script requires --sml-script <path>")
        })

        let scriptOnly = KistOptions.parse(["--sml-script", "scripts/review.repl"])
        XCTAssertTrue(scriptOnly.optionErrors.contains {
            $0.contains("--sml-script requires --sml-runtime-repl-script")
        })

        let workflowOnly = KistOptions.parse(["--sml-workflow", "langgraph.review"])
        XCTAssertTrue(workflowOnly.optionErrors.contains {
            $0.contains("--sml-workflow requires --sml-runtime-repl, --sml-runtime-repl-script, --sml-runtime-runbook, or --sml-runtime-attachments")
        })

        let conflict = KistOptions.parse([
            "--sml-runtime-export", "graphs/review.langgraph.json",
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "help",
        ])
        XCTAssertTrue(conflict.optionErrors.contains { $0.contains("--sml-runtime-export conflicts") })

        let launchConflict = KistOptions.parse([
            "--sml-runtime-launch", "graphs/review.langgraph.json",
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "help",
        ])
        XCTAssertTrue(launchConflict.optionErrors.contains { $0.contains("--sml-runtime-launch conflicts") })

        let openAPIConflict = KistOptions.parse([
            "--sml-runtime-openapi", "graphs/review.langgraph.json",
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "help",
        ])
        XCTAssertTrue(openAPIConflict.optionErrors.contains {
            $0.contains("--sml-runtime-openapi conflicts with --sml-runtime-repl")
        })

        let replScriptConflict = KistOptions.parse([
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "help",
            "--sml-runtime-repl-script", "graphs/review.langgraph.json",
            "--sml-script", "scripts/review.repl",
        ])
        XCTAssertTrue(replScriptConflict.optionErrors.contains {
            $0.contains("--sml-runtime-repl conflicts with --sml-runtime-repl-script")
        })
    }

    func testSMLRuntimeAPIFlagsRequireRunnableMode() {
        let api = KistOptions.parse(["--sml-runtime-api"])
        XCTAssertTrue(api.optionErrors.contains { $0.contains("--sml-runtime-api requires <source.json>") })
        XCTAssertNil(api.smlRuntimeAPI)

        let apiScript = KistOptions.parse(["--sml-runtime-api-script"])
        XCTAssertTrue(apiScript.optionErrors.contains {
            $0.contains("--sml-runtime-api-script requires <source.json>")
        })
        XCTAssertNil(apiScript.smlRuntimeAPIScript)

        let missingPath = KistOptions.parse(["--sml-runtime-api", "graphs/review.langgraph.json"])
        XCTAssertTrue(missingPath.optionErrors.contains { $0.contains("--sml-runtime-api requires --sml-path") })

        let missingScript = KistOptions.parse([
            "--sml-runtime-api-script", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(missingScript.optionErrors.contains {
            $0.contains("--sml-runtime-api-script requires --sml-api-script <path>")
        })

        let badMethod = KistOptions.parse([
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-method", "PATCH",
            "--sml-path", "/source/runtime/planning",
        ])
        XCTAssertTrue(badMethod.optionErrors.contains { $0.contains("--sml-method requires GET or POST") })

        let methodOnly = KistOptions.parse(["--sml-method", "GET"])
        XCTAssertTrue(methodOnly.optionErrors.contains { $0.contains("--sml-method requires --sml-runtime-api") })

        let pathOnly = KistOptions.parse(["--sml-path", "/source/runtime/planning"])
        XCTAssertTrue(pathOnly.optionErrors.contains { $0.contains("--sml-path requires --sml-runtime-api") })

        let bodyOnly = KistOptions.parse(["--sml-body", #"{"hello":"world"}"#])
        XCTAssertTrue(bodyOnly.optionErrors.contains { $0.contains("--sml-body requires --sml-runtime-api") })

        let apiScriptOnly = KistOptions.parse(["--sml-api-script", "scripts/review-api.json"])
        XCTAssertTrue(apiScriptOnly.optionErrors.contains {
            $0.contains("--sml-api-script requires --sml-runtime-api-script")
        })

        let exportConflict = KistOptions.parse([
            "--sml-runtime-export", "graphs/review.langgraph.json",
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
        ])
        XCTAssertTrue(exportConflict.optionErrors.contains { $0.contains("--sml-runtime-export conflicts with --sml-runtime-api") })

        let launchConflict = KistOptions.parse([
            "--sml-runtime-launch", "graphs/review.langgraph.json",
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
        ])
        XCTAssertTrue(launchConflict.optionErrors.contains { $0.contains("--sml-runtime-launch conflicts with --sml-runtime-api") })

        let openAPIConflict = KistOptions.parse([
            "--sml-runtime-openapi", "graphs/review.langgraph.json",
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
        ])
        XCTAssertTrue(openAPIConflict.optionErrors.contains {
            $0.contains("--sml-runtime-openapi conflicts with --sml-runtime-api")
        })

        let replConflict = KistOptions.parse([
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "help",
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
        ])
        XCTAssertTrue(replConflict.optionErrors.contains { $0.contains("--sml-runtime-repl conflicts with --sml-runtime-api") })

        let apiScriptConflict = KistOptions.parse([
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
            "--sml-runtime-api-script", "graphs/review.langgraph.json",
            "--sml-api-script", "scripts/review-api.json",
        ])
        XCTAssertTrue(apiScriptConflict.optionErrors.contains {
            $0.contains("--sml-runtime-api conflicts with --sml-runtime-api-script")
        })
    }

    func testSMLRuntimeModelFlagsRequireRunnableMode() {
        let model = KistOptions.parse(["--sml-runtime-model"])
        XCTAssertTrue(model.optionErrors.contains { $0.contains("--sml-runtime-model requires <source.json>") })
        XCTAssertNil(model.smlRuntimeModel)

        let missingPrompt = KistOptions.parse(["--sml-runtime-model", "graphs/review.langgraph.json"])
        XCTAssertTrue(missingPrompt.optionErrors.contains { $0.contains("--sml-runtime-model requires --sml-prompt") })

        let promptOnly = KistOptions.parse(["--sml-prompt", "start it"])
        XCTAssertTrue(promptOnly.optionErrors.contains { $0.contains("--sml-prompt requires --sml-runtime-model") })

        let exportConflict = KistOptions.parse([
            "--sml-runtime-export", "graphs/review.langgraph.json",
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
        ])
        XCTAssertTrue(exportConflict.optionErrors.contains { $0.contains("--sml-runtime-export conflicts with --sml-runtime-model") })

        let launchConflict = KistOptions.parse([
            "--sml-runtime-launch", "graphs/review.langgraph.json",
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
        ])
        XCTAssertTrue(launchConflict.optionErrors.contains { $0.contains("--sml-runtime-launch conflicts with --sml-runtime-model") })

        let openAPIConflict = KistOptions.parse([
            "--sml-runtime-openapi", "graphs/review.langgraph.json",
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
        ])
        XCTAssertTrue(openAPIConflict.optionErrors.contains {
            $0.contains("--sml-runtime-openapi conflicts with --sml-runtime-model")
        })

        let planningConflict = KistOptions.parse([
            "--sml-runtime-planning", "graphs/review.langgraph.json",
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
        ])
        XCTAssertTrue(planningConflict.optionErrors.contains {
            $0.contains("--sml-runtime-planning conflicts with --sml-runtime-model")
        })

        let replConflict = KistOptions.parse([
            "--sml-runtime-repl", "graphs/review.langgraph.json",
            "--sml-line", "help",
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
        ])
        XCTAssertTrue(replConflict.optionErrors.contains { $0.contains("--sml-runtime-repl conflicts with --sml-runtime-model") })

        let apiConflict = KistOptions.parse([
            "--sml-runtime-api", "graphs/review.langgraph.json",
            "--sml-path", "/source/runtime/planning",
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
        ])
        XCTAssertTrue(apiConflict.optionErrors.contains { $0.contains("--sml-runtime-api conflicts with --sml-runtime-model") })

        let modelScript = KistOptions.parse(["--sml-runtime-model-script"])
        XCTAssertTrue(modelScript.optionErrors.contains {
            $0.contains("--sml-runtime-model-script requires <source.json>")
        })
        XCTAssertNil(modelScript.smlRuntimeModelScript)

        let missingScript = KistOptions.parse([
            "--sml-runtime-model-script", "graphs/review.langgraph.json",
        ])
        XCTAssertTrue(missingScript.optionErrors.contains {
            $0.contains("--sml-runtime-model-script requires --sml-model-script <path>")
        })

        let scriptOnly = KistOptions.parse(["--sml-model-script", "scripts/review.prompts"])
        XCTAssertTrue(scriptOnly.optionErrors.contains {
            $0.contains("--sml-model-script requires --sml-runtime-model-script")
        })

        let modelScriptConflict = KistOptions.parse([
            "--sml-runtime-model", "graphs/review.langgraph.json",
            "--sml-prompt", "start it",
            "--sml-runtime-model-script", "graphs/review.langgraph.json",
            "--sml-model-script", "scripts/review.prompts",
        ])
        XCTAssertTrue(modelScriptConflict.optionErrors.contains {
            $0.contains("--sml-runtime-model conflicts with --sml-runtime-model-script")
        })
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
        // Default OFF (2026-08-03): the brief default-ON regressed live — during-turn stdout capture
        // bleached the UI white and DECSTBM corrupted on resize. Opt-in only per project CLAUDE.md.
        XCTAssertFalse(KistOptions.parse(["hi"]).stickyTurns)
        XCTAssertTrue(KistOptions.parse(["--sticky-turns", "hi"]).stickyTurns)    // explicit opt-in
        XCTAssertFalse(KistOptions.parse(["--no-sticky-turns", "hi"]).stickyTurns)         // opt-out disables it
        XCTAssertFalse(KistOptions.parse(["--sticky-turns", "--no-sticky-turns", "hi"]).stickyTurns)  // last-flag opt-out wins
        XCTAssertTrue(KistOptions.parse(["--pinned-bar", "x"]).pinnedBar)        // unrelated bar flag intact
    }

    func testPlanExecuteFlag() {
        XCTAssertTrue(KistOptions.parse(["--plan-execute", "build the thing"]).planExecute)
        XCTAssertFalse(KistOptions.parse(["build the thing"]).planExecute)   // default off
        XCTAssertFalse(KistOptions.parse(["--plan", "x"]).planExecute)        // --plan != --plan-execute
    }

    func testHeadlessFlagIsExplicitAndDefaultsOff() {
        let explicit = KistOptions.parse(["--headless", "build the thing"])
        XCTAssertTrue(explicit.headless)
        XCTAssertEqual(explicit.goal, "build the thing")
        XCTAssertFalse(KistOptions.parse(["build the thing"]).headless)
        XCTAssertTrue(KistOptions.helpText.contains("--headless"))
        XCTAssertTrue(KistOptions.helpText.contains("sealed"))
    }

    func testHeadlessConflictsWithEveryOtherBuilderRouteRegardlessOfFlagOrder() {
        let conflictingArguments = [
            ["--plan-execute"],
            ["--fleet"],
            ["--mission"],
            ["--loop"],
            ["--cobolo", "--cobol-target", "program.cbl", "--cobol-expect", "OK"],
        ]
        for otherRoute in conflictingArguments {
            for arguments in [
                ["--headless"] + otherRoute + ["build it"],
                otherRoute + ["--headless", "build it"],
            ] {
                let options = KistOptions.parse(arguments)
                XCTAssertTrue(
                    options.optionErrors.contains { $0.hasPrefix("--headless conflicts with ") },
                    "route flags must fail closed before runtime activation: \(arguments)")
            }
        }
    }

    func testPlanExecuteResumeRequiresCanonicalMissionIDAndRejectsHeadlessResume() {
        let missionID = String(repeating: "a", count: 64)
        let valid = KistOptions.parse(["--plan-execute-resume", missionID, "same", "goal"])
        XCTAssertTrue(valid.planExecute)
        XCTAssertEqual(valid.planExecuteResumeID?.rawValue, missionID)
        XCTAssertEqual(valid.goal, "same goal")
        XCTAssertNil(valid.resumeId)
        XCTAssertFalse(valid.resumeLast)
        XCTAssertNil(KistOptions.parse(["--plan-execute", "fresh goal"]).planExecuteResumeID)

        for invalidID in [
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
        ] {
            let invalid = KistOptions.parse(["--plan-execute-resume", invalidID, "same goal"])
            XCTAssertNil(invalid.planExecuteResumeID, "accepted invalid mission ID: \(invalidID)")
            XCTAssertFalse(invalid.optionErrors.isEmpty, "invalid mission ID must fail closed")
        }

        let missingID = KistOptions.parse(["--plan-execute-resume"])
        XCTAssertNil(missingID.planExecuteResumeID)
        XCTAssertFalse(missingID.optionErrors.isEmpty)

        let missingGoal = KistOptions.parse(["--plan-execute-resume", missionID])
        XCTAssertNil(missingGoal.goal)
        XCTAssertTrue(missingGoal.optionErrors.contains { $0.lowercased().contains("goal") },
                      "resume requires the same nonempty goal as an independent identity check")

        let conflicts = [
            ["--resume", "headless-id", "--plan-execute", "goal"],
            ["--plan-execute", "--resume", "headless-id", "goal"],
            ["--resume-last", "--plan-execute", "goal"],
            ["--plan-execute", "--resume-last", "goal"],
            ["--resume", "headless-id", "--plan-execute-resume", missionID, "goal"],
            ["--plan-execute-resume", missionID, "--resume-last", "goal"],
        ]
        for arguments in conflicts {
            let parsed = KistOptions.parse(arguments)
            XCTAssertFalse(parsed.optionErrors.isEmpty,
                           "Headless and PlanExecute resume namespaces must conflict: \(arguments)")
        }

        XCTAssertTrue(KistOptions.helpText.contains("--plan-execute-resume <mission-id>"))
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

    func testReviewGradeParsesExplicitlyAndRejectsMalformedValues() {
        let sameModel = KistOptions.parse([
            "--critic", "codex-cli:gpt-5.6-sol",
            "--review-grade", "fresh_context_same_model", "grow it",
        ])
        XCTAssertEqual(sameModel.reviewGrade, .freshContextSameModel)
        XCTAssertTrue(sameModel.optionErrors.isEmpty)
        XCTAssertNil(KistOptions.parse(["grow it"]).reviewGrade)

        let malformed = KistOptions.parse(["--review-grade", "same-ish", "grow it"])
        XCTAssertNil(malformed.reviewGrade)
        XCTAssertTrue(malformed.optionErrors.contains { $0.contains("--review-grade") })
        XCTAssertTrue(KistOptions.helpText.contains("fresh_context_same_model"))
        XCTAssertTrue(KistOptions.helpText.contains("never independent"))
        XCTAssertTrue(KistOptions.helpText.contains("non-Git disposable"))
        XCTAssertTrue(KistOptions.helpText.contains("one deterministic verifier"))
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
        XCTAssertEqual(KistOptions.parse(["--max-iterations", "notanumber", "g"]).maxIterations, 40)   // default kept (40 — dogfood 2026-08-06: 12 failed every real build task)
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

    func testOptionErrorsExitBeforeRuntimeActivationAndRunnerDispatch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Kist/main.swift"),
            encoding: .utf8)
        let optionErrorGate = try XCTUnwrap(source.range(of: "guard opts.optionErrors.isEmpty else"))
        let activeMarker = try XCTUnwrap(source.range(of: #"setenv("KIST_ACTIVE""#))
        let runnerDispatch = try XCTUnwrap(source.range(of: "KistRunner.run"))
        let gatedBody = String(source[optionErrorGate.lowerBound..<activeMarker.lowerBound])

        XCTAssertTrue(gatedBody.contains("exit(2)"),
                      "invalid options must terminate with usage error before runtime activation")
        XCTAssertLessThan(optionErrorGate.lowerBound, activeMarker.lowerBound)
        XCTAssertLessThan(optionErrorGate.lowerBound, runnerDispatch.lowerBound)
        XCTAssertLessThan(activeMarker.lowerBound, runnerDispatch.lowerBound)
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
