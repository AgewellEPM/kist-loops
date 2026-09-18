import Foundation
import AgentCore

/// Tiny hand-rolled argument parser (no external deps — Mythos ships as one static binary).
struct KistOptions {
    var goal: String?
    var providerId: String?
    var model: String?
    /// Default-model selection policy: .power (strongest, default) or .cost (cheapest). Overridden by
    /// an explicit -p/--provider. Set via --by-cost/--by-power or config "selectBy"/the /cost·/power REPL cmds.
    var selectBy: ProviderSelectionPolicy?
    var project: String
    // 40, not 12 (dogfood 2026-08-06): every real build task (write→compile→run→fix→verify) died at
    // the 12-step ceiling with ~$1.30 spent and nothing verified, across 6 consecutive runs. The loop's
    // OTHER guards bound runaway spend (runaway-cycle detector, budget ledger, verify-before-done);
    // a too-small ceiling is the one guard that guarantees failure on real work. --max-iterations overrides.
    var maxIterations: Int = 40
    var allowShell = false          // run_command is OFF by default (file/search tools are safe)
    var allowReadPaths: [String] = []  // --allow-read <dir>: extra READ-ONLY roots for the file tools
                                    // (e.g. /Volumes for a CD/USB drive). Repeatable. Writes stay
                                    // project-confined; nested kist never inherits it (stripped below).
    var sandbox = false             // opt-in macOS Seatbelt OS sandbox
    var trustWorktreeTests = false  // --trust-worktree-tests: let the fleet verifier trust an IN-REPO test
                                    // harness (base-trusted test.sh / structural swift-test/npm). OFF by
                                    // default: only a held-out operator oracle (~/.kist/test-command)
                                    // verifies. Opt in ONLY for your OWN honest agents (a shell harness can
                                    // transitively run agent code — not adversarial-safe).
    var yolo = false                // REPL: skip approval prompts for sensitive tools
    var auto = false                // --auto/--danger: hands-off autopilot. Forces yolo + allow-shell +
                                    // sandbox (sandbox CANNOT be disabled in auto mode — fail-closed:
                                    // on a platform with no OS sandbox, shell refuses rather than run raw).
    var ship = false                // --ship: build hands-free in autopilot sandbox, then the council
                                    // of minds reviews the result → GO/NO-GO (deploy stays your call)
    var planMode = false            // start in plan mode: read-only, propose a plan (no edits/commands)
    var extendedThinking = false    // --think: let the model REASON before each action (surfaced + replayed)
    var headless = false            // --headless: explicitly select the governed direct Builder adapter
    var planExecute = false         // plan→execute: planner emits a typed DAG, approve, then build it
    var planExecuteResumeID: PlanExecuteMissionID? // exact PlanExecute mission; distinct from Headless --resume
    var mission = false             // autonomous doctrine: research → simulation/trials → execute/verify → review
    var autonomyReceipts = false    // emit machine-readable stage/review receipts for the Captain runtime
    var research = false            // --research: evidence run -> council -> task board
    var council = false             // --council/--consult: research -> multi-model council -> task board
    var councilExecute = false      // --council-execute: council first, then hand builder brief to plan→execute
    var digDeep = false             // --dig/--dig-in-deep: ask EVERY reachable model the same question, synthesize
    var fleet = false               // --fleet: launch a SUPERVISED parallel fleet (heterogeneous agents)
    var evolve = false              // --evolve: DGM-style self-improvement lab, isolated + benchmarked
    var evolveStatus = false        // --evolve-status: render the evolution archive (frontier, best, blocked)
    var evolveTree = false          // --evolve-tree: render the lineage/ancestry + best-score trajectory
    var evolveArm = false           // --evolve-arm: authorize autonomous cross-session evolution (explicit)
    var evolveDisarm = false        // --evolve-disarm: revoke autonomous authorization (back to fail-closed)
    var evolveSession = false       // --evolve-session: run ONE autonomous session IF armed (cron entry)
    var maxSessions = 10            // --max-sessions N: total autonomous sessions when arming
    var armHours = 24               // --arm-hours N: hard expiry for the arming authorization
    var agents = 5                  // --agents N: max fleet size (hard-capped; never a runaway swarm)
    var variants = 1                // --variants N: evolution candidates per generation (isolated worktrees)
    var generations = 1             // --generations N: open-ended DGM rounds; each breeds from the grown archive
    var evolvePatience = 0          // --evolve-patience N: early-stop after N stagnant generations (0 = off)
    var evolveBenchmarkCommands: [String] = [] // --evolve-test <cmd>: benchmark command(s) for evolution
    var evolveTimeout = 600         // --evolve-timeout N: per benchmark timeout
    var delegationDepth = 1         // --delegation-depth N: nested spawn_agent teammate calls (0...3)
    var plannerSpec: String?        // --planner <provider[:model]>: vendor for the PLANNER role
    var workerSpec: String?         // --worker <provider[:model]>: vendor for the WORKER/research role
    var coderSpec: String?          // --coder <provider[:model]>: vendor for the CODER (generate) role
    var criticSpec: String?         // --critic <provider[:model]>: vendor for the CRITIC (verify) role
    var reviewGrade: EvolutionReviewGrade? // --review-grade: explicit /grow or narrow Builder review grade
    var roleProfile: String?        // --roles <name>: saved role/team profile from ~/.config/kist/roles.json
    var budgetTokens: Int?          // --budget <n>: hard token ceiling for ANY run (one-shot, REPL,
                                    // resume, plan→execute); shared across the whole delegation tree
    var verifyReceipt = false       // --verify: run checks on the staged change, seal+store a Verification Receipt
    var guardReceipt = false        // --guard: admit the staged change only if a valid receipt covers it (hook)
    var installGuardHook = false    // --install-guard: install a git pre-commit hook that runs `kist --guard`
    var verifyCommand: String?      // --verify-cmd "<cmd>": extra deterministic check (compile/tests) for --verify
    var proofsPath: String?         // --proofs <file>: proof-carrying claims checked against the staged diff at --verify
    var ciGuard = false             // --ci-guard [base] [head]: server-authoritative gate over a COMMIT RANGE.
                                    // Every content-bearing commit in base..head must carry a valid receipt.
                                    // This is the UNBYPASSABLE gate (a CI required check; --no-verify can't skip it).
    var ciGuardBase: String?        // explicit base ref (else inferred from CI env / origin default branch)
    var ciGuardHead: String?        // explicit head ref (else HEAD)
    var genIssuerKey: String?       // --gen-issuer-key <keyID>: generate an Ed25519 issuer keypair (priv 0600 + pub)
    var trustIssuer: (keyID: String, pubB64: String)?  // --trust-issuer <keyID> <pubB64>: pin an issuer public key
    var unpinIssuer: String?        // --unpin-issuer <keyID>: stop trusting an issuer (removable pin, no record)
    var revokeIssuer: String?       // --revoke-issuer <keyID>: REVOKE a compromised issuer (sigs rejected; not re-pinnable)
    var unrevokeIssuer: String?     // --unrevoke-issuer <keyID>: lift a revocation
    var listIssuers = false         // --list-issuers: show pinned receipt issuer keys
    var signReceipt: String?        // --sign-receipt <digest|latest>: Ed25519-sign a stored receipt's change
    var issuerKeyPath: String?      // --issuer-key <path>: the issuer PRIVATE key file used by --sign-receipt
    var trustRoot: (keyID: String, pubB64: String)?  // --trust-root <keyID> <pubB64>: pin a TRUST ROOT public key
    var listRoots = false           // --list-roots: show pinned trust roots
    var makeBundle = false          // --make-bundle: sign the current issuer set into a distributable trust bundle
    var rootKeyPath: String?        // --root-key <path>: the ROOT private key file used by --make-bundle
    var bundleOut: String?          // --bundle-out <path>: where --make-bundle writes (default .kist/trust-bundle.json)
    var verifyBundle: String?       // --verify-bundle <path>: verify a signed trust bundle against pinned roots
    var enableComputerUse = false   // --enable-computer-use: ARM the desktop/screen/perception tools (real
                                    // mouse/keyboard injection + capture). DEFAULT-DENY: without this flag the
                                    // tools are NEVER registered, so they can't fire on any autonomous surface
                                    // (one-shot/eval/bench/fleet/spawn/coding loop). Council-mandated 2026-07-03.
    var nestedRefusedEscalation = false  // set when a nested kist (KIST_ACTIVE) had arming/guards-off refused
    var greatLoop = false           // --loop: long-horizon great-loop (self-assess effort, learn, safety-railed)
    var loopHours: Double?          // --loop-hours <h>: wall-clock cap for the great loop
    var maxCycles: Int?             // --max-cycles <n>: outer-loop cycle cap for the great loop
    var cobolo = false              // --cobolo/--cobol-loop: governed local COBOL builder
    var cobolTarget: String?        // required project-relative .cbl/.cob promotion target
    var cobolExpect: String?        // required stdout substring for deterministic replay
    var cobolMaxRevisions = 3       // --cobol-max-revisions <1...3>: bounded critic-driven revisions
    var maxCostUSD: Double?         // --max-cost <usd>: hard DOLLAR ceiling (priced per provider); either
                                    // cap halts the run (aplus C-series cost governance).
    var noMemory = false            // --no-memory: disable cross-run memory (facts + episode log)
    var listLearningSync = false    // one bounded LIST MCP import, no model or task execution
    var listLearningStatus = false  // read-only local advisory memory status
    var operatorAction = false     // one host-authorized JSON action; no model or MCP discovery
    var operatorActionArgumentsValid = true
    var fast = false                // --fast: lean solo dev tool — core code tools only (drop media/vision/
                                    // browse/pentest/research/workflow extras) → far smaller prompt, cheaper, faster.
    var toolMode: String = "auto"   // tool acquisition: auto (capability-routed) | native | text
    var tui = false                 // --tui: raw-mode persistent-input TUI (PROTOTYPE; off by default)
    var pinnedBar = true            // R2b: input bar glued to the bottom (scroll-region pinned). Default
                                    // ON for interactive TTYs; `--no-pinned-bar` reverts to the inline box.
    var stickyTurns = false         // Keep the pinned box during turns via the serialized screen owner.
                                    // OPT-IN ONLY (project CLAUDE.md contract). Briefly defaulted ON
                                    // 2026-08-02 after a self-test pass, but live use showed two
                                    // regressions (2026-08-03): during-turn stdout capture made every
                                    // isatty color check false → the whole UI rendered white, and the
                                    // DECSTBM scroll region corrupted the display on window resize.
                                    // Back OFF until both are fixed AND validated in a real Terminal.
    var stickyBarSelfTest = false   // hidden/offline Terminal.app diagnostic; no provider/MCP/network startup
    var fetchAllowedHosts: [String] = []  // --fetch-host <host>: restrict fetch_url to exact/wildcard hosts
    var providerHealth = false     // --health: offline provider/model/router health report
    var probeProviders = false     // --probe-providers: live one-token provider probes
    var providersDoctor = false    // --providers-doctor: live GET /models diff vs catalog (dead-id preflight)
    var mcpAuth: [String]?         // `mcp auth <server> <metadata-url> [client-id] [scope]`: one-time OAuth authorize
    var bench = false              // --bench: run a task across configured providers and compare
    var eval = false               // --eval: run agent regression assertions for a task
    var protocolStatus = false     // --protocols: MCP/A2A/computer-control surface status
    // host-snapshot (PROTOTYPE, SECURITY BOUNDARY): token-gated, signed macOS-host frame for a guest VM.
    var hostSnapshot = false       // `host-snapshot`: single signed frame
    var hostSnapshotStream = false // `host-snapshot --stream`: NDJSON stream of independently-signed frames
    var hostSnapshotPubkey = false // `host-snapshot --pubkey`: print ONLY the Ed25519 public key + key_id (no token, no frame)
    var authToken: String?         // --auth-token <token> (prefer env KIST_HOST_SNAPSHOT_TOKEN)
    var displayIndex: Int?         // --display <N>: which display to capture (default main/0)
    // Parse-error signals: a value was PRESENT for the flag but was not a valid Int. Kept OUT of the general
    // `optionErrors` list so the host-snapshot runner can emit an ATOMIC kist-cli-json-v1 error (not a plain
    // stderr line + generic exit 2) BEFORE auth/capture — a non-integer must fail closed, never capture 0.
    var hostSnapshotDisplayParseError = false // --display <non-int>: fail-closed "invalid --display index"
    var hostSnapshotFpsParseError = false     // --fps <non-int>: fail-closed "invalid --fps"
    var hostSnapshotMaxFramesParseError = false // --max-frames <non-int>: fail-closed "invalid --max-frames"
    var fps: Int?                  // --fps <N>: stream frame rate (clamped 1..5)
    var maxFrames: Int?            // --max-frames <N>: stream frame cap (hard-capped 300)
    var hostSnapshotNonce: String? // --nonce <hex>: client-planted per-request nonce (replay defense; echoed + signed)
    var noAudit = false            // --no-audit: disable the immutable tool audit log (.kist/audit/tools.jsonl)
    var replayId: String?          // --replay [id|latest]: render durable run replay from .kist/runs
    var trustSkill: String?        // --trust-skill <name>: pin a project skill's current content hash (trust it)
    var trustPublisher: (keyID: String, pubkeyB64: String)?  // --trust-publisher <keyID> <pubkeyB64>: pin an Ed25519 publisher key
    var listSkills = false         // --skills: list discovered skills with trust tier + scope
    var listProviders = false
    var geminiTest = false          // --gemini-test: live smoke-test of the Gemini clients
    var probeModel: String?         // --probe-model <provider[:model]>: canary-probe a model's tool loop
    var inspectModel: String?       // --inspect-model <path>: read a local model's chat template + stops
    var onboardModel: String?       // --onboard <provider[:model]>: zero-config verify a dropped model
    var onboardDoc: String?         // --onboard-doc <path>: local template/weights for the onboarded model
    var modelVet: String?           // --model-vet <hf:model|mlx:model|ollama:model>: live metadata gate
    var modelAcquire: String?       // --model-acquire <manifest.json>: verify acquisition manifest
    var modelRunStage: String?      // --model-run <stage> <manifest.json>: execute verified manifest stage
    var modelRunManifest: String?
    var smlOpenAPIImport: String?  // --sml-import-openapi <openapi.json>: propose HTTP capabilities/workflows
    var smlOpenAPIID: String?      // --sml-api-id <id>: stable id for --sml-import-openapi
    var smlRuntimeExport: String?   // --sml-runtime-export <source.json>: offline source/package -> REPL/API/model/Onyx/planning JSON
    var smlRuntimeLaunch: String?   // --sml-runtime-launch <source.json>: emit offline launch descriptor/receipt
    var smlRuntimeOpenAPI: String?  // --sml-runtime-openapi <source.json>: emit generated OpenAPI document
    var smlRuntimeModelRouter: String? // --sml-runtime-model-router <source.json>: emit model-router tool descriptor
    var smlRuntimeOnyx: String?     // --sml-runtime-onyx <source.json>: emit Onyx driver manifests
    var smlRuntimePlanning: String? // --sml-runtime-planning <source.json>: emit aggregate planning manifest
    var smlRuntimeCatalog: String?  // --sml-runtime-catalog <source.json>: emit mounted workflow catalog
    var smlRuntimeMount: String?    // --sml-runtime-mount <source.json>: emit host mount contract
    var smlRuntimeAgentGuide: String? // --sml-runtime-agent-guide <source.json>: emit agent operating guide
    var smlRuntimeHostGuide: String? // --sml-runtime-host-guide <source.json>: emit host wiring guide
    var smlRuntimeHostWiring: String? // --sml-runtime-host-wiring <source.json>: emit compact host wiring map
    var smlRuntimeRunbook: String? // --sml-runtime-runbook <source.json>: emit host scaffold runbook
    var smlRuntimeScaffold: String? // --sml-runtime-scaffold <source.json>: write all host-consumable runtime artifacts
    var smlRuntimeAttachments: String? // --sml-runtime-attachments <source.json>: emit generated workflow attachment manifests
    var smlRuntimeDurable = false   // --sml-runtime-durable: REPL/API verbs use the persistent project store, real clock, and .kist/sml authority/catalog files instead of the ephemeral rubber-stamp export host
    var smlRuntimeServe: String?    // --sml-runtime-serve <source.json>: long-lived durable harness — loopback HTTP + approval-gated capability pump
    var smlRuntimeServePort: UInt16? // --sml-port <port>: exact loopback port for --sml-runtime-serve (default: first free in 8850...8880)
    var smlStoreAction: String?
    var smlBackupPath: String?
    var smlArchiveBefore: String?
    var smlArchiveMaximum: Int?
    var smlReplaceSHA256: String?
    var smlRuntimeREPL: String?     // --sml-runtime-repl <source.json>: run one generated workflow REPL line offline
    var smlRuntimeREPLScript: String? // --sml-runtime-repl-script <source.json>: run a generated workflow REPL script offline
    var smlRuntimeWorkflowID: String? // --sml-workflow <id>: select workflow for --sml-runtime-repl/runbook/attachments
    var smlRuntimeREPLLine: String? // --sml-line <line>: optional one-shot line; omit for interactive REPL
    var smlRuntimeREPLScriptPath: String? // --sml-script <path>: generated workflow REPL script file to run
    var smlRuntimeAPI: String?      // --sml-runtime-api <source.json>: run one generated runtime API request offline
    var smlRuntimeAPIScript: String? // --sml-runtime-api-script <source.json>: run a generated runtime API request script offline
    var smlRuntimeAPIMethod: SMLWorkflowAPIMethod = .get // --sml-method <GET|POST>
    var smlRuntimeAPIPath: String?  // --sml-path <path>: generated runtime API path to invoke
    var smlRuntimeAPIBody: String?  // --sml-body <json>: generated runtime API request body
    var smlRuntimeAPIScriptPath: String? // --sml-api-script <path>: generated runtime API request script file
    var smlRuntimeModel: String?    // --sml-runtime-model <source.json>: let a native-tool model drive mounted workflows
    var smlRuntimeModelPrompt: String? // --sml-prompt <text>: user prompt for --sml-runtime-model
    var smlRuntimeModelScript: String? // --sml-runtime-model-script <source.json>: run a generated model prompt script
    var smlRuntimeModelScriptPath: String? // --sml-model-script <path>: prompt script file for --sml-runtime-model-script
    var smlRuntimeRole: String?     // --sml-role <role>: override mounted workflow role
    var smlRuntimeActor: String?    // --sml-actor <actor>: synthetic host actor for offline install proof
    var smlRuntimeAPIBasePath: String? // --sml-api-base <path>: override generated API base path
    var smlRuntimeAPIWorkflowPathOverrides: [String: String] = [:] // --sml-api-workflow-path <workflow-id>=<path>
    var smlRuntimeOutputDirectory: String? // --sml-out <dir>: output directory for --sml-runtime-scaffold
    var smlRuntimeTitle: String?    // --sml-title <title>: OpenAPI/runtime export title
    var smlRuntimeVersion: String?  // --sml-version <version>: OpenAPI/runtime export version
    var smlRuntimeModelRounds: Int? // --sml-model-rounds <1...8>: model-router command-round ceiling
    var optionErrors: [String] = []
    var resumeId: String?           // --resume <id>
    var resumeLast = false          // --resume-last
    var listRuns = false            // --list (resumable runs)
    var showHelp = false

    /// One ledger from BOTH cost dimensions (--budget tokens, --max-cost dollars). nil when neither
    /// is set (uncapped). The same instance is shared across the delegation tree / fleet.
    func makeBudget() -> BudgetLedger? {
        guard budgetTokens != nil || maxCostUSD != nil else { return nil }
        return BudgetLedger(maxTokens: budgetTokens, maxUSD: maxCostUSD)
    }

    static func parse(_ args: [String]) -> KistOptions {
        var o = KistOptions(project: FileManager.default.currentDirectoryPath)
        // The host action protocol has one exclusive switch. Do not allow generic options,
        // positional model instructions, help, or nested-shell defaults to alter its authority.
        if args.contains("--operator-action") {
            o.operatorAction = true
            o.operatorActionArgumentsValid = args == ["--operator-action"]
            return o
        }
        var positional: [String] = []
        var sawCobolMaxRevisions = false
        var sawSMLRuntimeAPIMethod = false
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "-h", "--help":            o.showHelp = true
            case "--list-providers":        o.listProviders = true
            case "--gemini-test":           o.geminiTest = true
            case "--probe-model":           if let v = next() { o.probeModel = v }
            case "--inspect-model":         if let v = next() { o.inspectModel = v }
            case "--onboard":               if let v = next() { o.onboardModel = v }
            case "--onboard-doc":           if let v = next() { o.onboardDoc = v }
            case let flag where ["--model-vet", "--vet-model"].contains(flag):
                                            if let v = next() { o.modelVet = v } else { o.optionErrors.append("\(flag) requires <hf:model|mlx:model|ollama:model>") }
            case let flag where ["--model-acquire", "--acquire-model"].contains(flag):
                                            if let v = next() { o.modelAcquire = v } else { o.optionErrors.append("\(flag) requires <manifest.json>") }
            case let flag where ["--model-run", "--run-model-acquire", "--model-acquisition-run"].contains(flag):
                                            if let s = next() {
                                                if let p = next() {
                                                    o.modelRunStage = s
                                                    o.modelRunManifest = p
                                                } else {
                                                    o.optionErrors.append("\(flag) requires <stage> <manifest.json>")
                                                }
                                            } else {
                                                o.optionErrors.append("\(flag) requires <stage> <manifest.json>")
                                            }
            case let flag where ["--sml-import-openapi", "--sml-openapi-import"].contains(flag):
                                            if let v = next() { o.smlOpenAPIImport = v }
                                            else { o.optionErrors.append("\(flag) requires <openapi.json>") }
            case "--sml-api-id":          if let v = next() { o.smlOpenAPIID = v }
                                            else { o.optionErrors.append("--sml-api-id requires <id>") }
            case "--sml-runtime-export":
                                            if let v = next() { o.smlRuntimeExport = v }
                                            else { o.optionErrors.append("--sml-runtime-export requires <source.json>") }
            case let flag where ["--sml-runtime-launch", "--sml-launch"].contains(flag):
                                            if let v = next() { o.smlRuntimeLaunch = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-openapi", "--sml-openapi"].contains(flag):
                                            if let v = next() { o.smlRuntimeOpenAPI = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-model-router", "--sml-model-router"].contains(flag):
                                            if let v = next() { o.smlRuntimeModelRouter = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-onyx", "--sml-onyx"].contains(flag):
                                            if let v = next() { o.smlRuntimeOnyx = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-planning", "--sml-planning"].contains(flag):
                                            if let v = next() { o.smlRuntimePlanning = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-catalog", "--sml-catalog"].contains(flag):
                                            if let v = next() { o.smlRuntimeCatalog = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-mount", "--sml-mount"].contains(flag):
                                            if let v = next() { o.smlRuntimeMount = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-agent-guide", "--sml-agent-guide"].contains(flag):
                                            if let v = next() { o.smlRuntimeAgentGuide = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-host-guide", "--sml-host-guide"].contains(flag):
                                            if let v = next() { o.smlRuntimeHostGuide = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-host-wiring", "--sml-host-wiring"].contains(flag):
                                            if let v = next() { o.smlRuntimeHostWiring = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-runbook", "--sml-runbook"].contains(flag):
                                            if let v = next() { o.smlRuntimeRunbook = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-scaffold", "--sml-scaffold"].contains(flag):
                                            if let v = next() { o.smlRuntimeScaffold = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-attachments", "--sml-attachments"].contains(flag):
                                            if let v = next() { o.smlRuntimeAttachments = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case "--sml-runtime-durable":   o.smlRuntimeDurable = true
            case "--sml-store":
                                            if let v = next(), ["verify", "backup", "restore", "archive"].contains(v) {
                                                o.smlStoreAction = v
                                            } else { o.optionErrors.append("--sml-store requires verify, backup, restore, or archive") }
            case "--sml-backup":
                                            if let v = next(), !v.isEmpty { o.smlBackupPath = v }
                                            else { o.optionErrors.append("--sml-backup requires <path>") }
            case "--sml-archive-before":
                                            if let v = next() { o.smlArchiveBefore = v }
                                            else { o.optionErrors.append("--sml-archive-before requires an ISO8601 timestamp") }
            case "--sml-archive-max":
                                            if let v = next(), let count = Int(v), (1...10_000).contains(count) {
                                                o.smlArchiveMaximum = count
                                            } else { o.optionErrors.append("--sml-archive-max requires an integer in 1...10000") }
            case "--sml-replace-sha256":
                                            if let v = next(), v.count == 64,
                                               v.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) {
                                                o.smlReplaceSHA256 = v
                                            } else { o.optionErrors.append("--sml-replace-sha256 requires 64 lowercase hexadecimal characters") }
            case "--sml-runtime-serve":
                                            if let v = next() { o.smlRuntimeServe = v }
                                            else { o.optionErrors.append("--sml-runtime-serve requires <source.json>") }
            case "--sml-port":
                                            if let v = next(), let port = UInt16(v), port >= 1_024 {
                                                o.smlRuntimeServePort = port
                                            } else { o.optionErrors.append("--sml-port requires a port number >= 1024") }
            case let flag where ["--sml-runtime-repl", "--sml-repl"].contains(flag):
                                            if let v = next() { o.smlRuntimeREPL = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-repl-script", "--sml-repl-script"].contains(flag):
                                            if let v = next() { o.smlRuntimeREPLScript = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-api", "--sml-api"].contains(flag):
                                            if let v = next() { o.smlRuntimeAPI = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-api-script", "--sml-api-batch"].contains(flag):
                                            if let v = next() { o.smlRuntimeAPIScript = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-model", "--sml-model-runtime"].contains(flag):
                                            if let v = next() { o.smlRuntimeModel = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case let flag where ["--sml-runtime-model-script", "--sml-model-batch"].contains(flag):
                                            if let v = next() { o.smlRuntimeModelScript = v }
                                            else { o.optionErrors.append("\(flag) requires <source.json>") }
            case "--sml-workflow":
                                            if let v = next() { o.smlRuntimeWorkflowID = v }
                                            else { o.optionErrors.append("--sml-workflow requires <workflow-id>") }
            case let flag where ["--sml-line", "--sml-repl-line"].contains(flag):
                                            if let v = next() { o.smlRuntimeREPLLine = v }
                                            else { o.optionErrors.append("\(flag) requires <line>") }
            case let flag where ["--sml-script", "--sml-lines"].contains(flag):
                                            if let v = next() { o.smlRuntimeREPLScriptPath = v }
                                            else { o.optionErrors.append("\(flag) requires <path>") }
            case "--sml-method":
                                            sawSMLRuntimeAPIMethod = true
                                            if let v = next() {
                                                let method = v.uppercased()
                                                if let parsed = SMLWorkflowAPIMethod(rawValue: method) {
                                                    o.smlRuntimeAPIMethod = parsed
                                                } else {
                                                    o.optionErrors.append("--sml-method requires GET or POST")
                                                }
                                            } else {
                                                o.optionErrors.append("--sml-method requires GET or POST")
                                            }
            case "--sml-path":              if let v = next() { o.smlRuntimeAPIPath = v }
                                            else { o.optionErrors.append("--sml-path requires <path>") }
            case "--sml-body":              if let v = next() { o.smlRuntimeAPIBody = v }
                                            else { o.optionErrors.append("--sml-body requires <json>") }
            case let flag where ["--sml-api-script", "--sml-requests"].contains(flag):
                                            if let v = next() { o.smlRuntimeAPIScriptPath = v }
                                            else { o.optionErrors.append("\(flag) requires <path>") }
            case let flag where ["--sml-prompt", "--sml-model-prompt"].contains(flag):
                                            if let v = next() { o.smlRuntimeModelPrompt = v }
                                            else { o.optionErrors.append("\(flag) requires <text>") }
            case let flag where ["--sml-model-script", "--sml-prompts"].contains(flag):
                                            if let v = next() { o.smlRuntimeModelScriptPath = v }
                                            else { o.optionErrors.append("\(flag) requires <path>") }
            case "--sml-role":              if let v = next() { o.smlRuntimeRole = v }
                                            else { o.optionErrors.append("--sml-role requires <role>") }
            case "--sml-actor":             if let v = next() { o.smlRuntimeActor = v }
                                            else { o.optionErrors.append("--sml-actor requires <actor>") }
            case "--sml-api-base":          if let v = next() { o.smlRuntimeAPIBasePath = v }
                                            else { o.optionErrors.append("--sml-api-base requires <path>") }
            case "--sml-api-workflow-path":
                                            if let v = next() {
                                                let parts = v.split(
                                                    separator: "=",
                                                    maxSplits: 1,
                                                    omittingEmptySubsequences: false
                                                )
                                                guard parts.count == 2 else {
                                                    o.optionErrors.append("--sml-api-workflow-path requires <workflow-id>=<path>")
                                                    break
                                                }
                                                let workflowID = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                                                let path = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                                                guard !workflowID.isEmpty, !path.isEmpty else {
                                                    o.optionErrors.append("--sml-api-workflow-path requires <workflow-id>=<path>")
                                                    break
                                                }
                                                guard o.smlRuntimeAPIWorkflowPathOverrides[workflowID] == nil else {
                                                    o.optionErrors.append("--sml-api-workflow-path repeats workflow id '\(workflowID)'")
                                                    break
                                                }
                                                o.smlRuntimeAPIWorkflowPathOverrides[workflowID] = path
                                            } else {
                                                o.optionErrors.append("--sml-api-workflow-path requires <workflow-id>=<path>")
                                            }
            case let flag where ["--sml-out", "--sml-output-dir"].contains(flag):
                                            if let v = next() { o.smlRuntimeOutputDirectory = v }
                                            else { o.optionErrors.append("\(flag) requires <dir>") }
            case "--sml-title":             if let v = next() { o.smlRuntimeTitle = v }
                                            else { o.optionErrors.append("--sml-title requires <title>") }
            case "--sml-version":           if let v = next() { o.smlRuntimeVersion = v }
                                            else { o.optionErrors.append("--sml-version requires <version>") }
            case "--sml-model-rounds":
                                            if let v = next(), let n = Int(v), (1...8).contains(n) {
                                                o.smlRuntimeModelRounds = n
                                            } else {
                                                o.optionErrors.append("--sml-model-rounds requires an integer from 1 through 8")
                                            }
            case "--list":                  o.listRuns = true
            case "--resume":
                                            let value = next()
                                            if o.planExecute {
                                                o.optionErrors.append("--resume cannot be combined with --plan-execute or --plan-execute-resume")
                                            } else {
                                                o.resumeId = value
                                            }
            case "--resume-last":
                                            if o.planExecute {
                                                o.optionErrors.append("--resume-last cannot be combined with --plan-execute or --plan-execute-resume")
                                            } else {
                                                o.resumeLast = true
                                            }
            case "--provider", "-p":        o.providerId = next()
            case "--by-cost", "--cost":     o.selectBy = .cost
            case "--by-power", "--power":   o.selectBy = .power
            case "--model", "-m":           o.model = next()
            case "--project", "-C":         if let v = next() { o.project = v }
            case "--max-iterations":        if let v = next(), let n = Int(v) { o.maxIterations = n }
            case "--loop":                  o.greatLoop = true
            case "--loop-hours":            if let v = next(), let h = Double(v) { o.loopHours = h }
            case "--max-cycles":            if let v = next(), let n = Int(v) { o.maxCycles = n }
            case "--ship":                  o.ship = true
            case "--allow-shell":           o.allowShell = true
            case "--allow-read":            if let v = next() { o.allowReadPaths.append(v) }
                                            else { o.optionErrors.append("--allow-read requires <dir>") }
            case "--sandbox":               o.sandbox = true
            case "--trust-worktree-tests":  o.trustWorktreeTests = true
            case "--yolo":                  o.yolo = true
            case "--auto", "--danger":      o.auto = true
            case "--enable-computer-use":   o.enableComputerUse = true
            case "--verify":                o.verifyReceipt = true      // produce+seal a receipt for the staged change
            case "--guard":                 o.guardReceipt = true       // gate: staged change needs a valid receipt
            case "--install-guard":         o.installGuardHook = true   // install the pre-commit receipt guard
            case "--verify-cmd":            if let v = next() { o.verifyCommand = v }
            case "--proofs":                if let v = next() { o.proofsPath = v }
            case "--ci-guard":
                // Optional positional [base] [head]. Only consume the NEXT tokens if they don't look like flags.
                o.ciGuard = true
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { o.ciGuardBase = next() }
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") { o.ciGuardHead = next() }
            case "--gen-issuer-key":        if let v = next() { o.genIssuerKey = v }
            case "--trust-issuer":          if let k = next(), let p = next() { o.trustIssuer = (k, p) }
            case "--unpin-issuer":          if let v = next() { o.unpinIssuer = v }
            case "--revoke-issuer":         if let v = next() { o.revokeIssuer = v }
            case "--unrevoke-issuer":       if let v = next() { o.unrevokeIssuer = v }
            case "--list-issuers":          o.listIssuers = true
            case "--sign-receipt":          o.signReceipt = next() ?? "latest"
            case "--issuer-key":            if let v = next() { o.issuerKeyPath = v }
            case "--trust-root":            if let k = next(), let p = next() { o.trustRoot = (k, p) }
            case "--list-roots":            o.listRoots = true
            case "--make-bundle":           o.makeBundle = true
            case "--root-key":              if let v = next() { o.rootKeyPath = v }
            case "--bundle-out":            if let v = next() { o.bundleOut = v }
            case "--verify-bundle":         if let v = next() { o.verifyBundle = v }
            case "--plan":                  o.planMode = true
            case "--think", "--thinking":   o.extendedThinking = true
            case "--headless":              o.headless = true
            case "--cobolo", "--cobol-loop": o.cobolo = true
            case "--cobol-target", "--cobolo-target":
                                            if i + 1 < args.count, !args[i + 1].hasPrefix("-"), let v = next() {
                                                o.cobolTarget = v
                                            }
                                            else { o.optionErrors.append("\(args[i]) requires <project-relative .cbl/.cob path>") }
            case "--cobol-expect", "--cobolo-expect":
                                            if i + 1 < args.count, !args[i + 1].hasPrefix("-"), let v = next() {
                                                o.cobolExpect = v
                                            }
                                            else { o.optionErrors.append("\(args[i]) requires <stdout substring>") }
            case "--cobol-max-revisions":
                                            sawCobolMaxRevisions = true
                                            if i + 1 < args.count, !args[i + 1].hasPrefix("-"), let raw = next() {
                                                if let revisions = Int(raw), (1...3).contains(revisions) {
                                                    o.cobolMaxRevisions = revisions
                                                } else {
                                                    o.optionErrors.append("--cobol-max-revisions requires an integer from 1 through 3")
                                                }
                                            } else {
                                                o.optionErrors.append("--cobol-max-revisions requires an integer from 1 through 3")
                                            }
            case "--plan-execute":
                                            if o.resumeId != nil || o.resumeLast {
                                                o.optionErrors.append("--plan-execute cannot be combined with Headless --resume or --resume-last")
                                            } else {
                                                o.planExecute = true
                                            }
            case "--plan-execute-resume":
                                            if let rawID = next() {
                                                if o.resumeId != nil || o.resumeLast {
                                                    o.optionErrors.append("--plan-execute-resume cannot be combined with Headless --resume or --resume-last")
                                                } else if let missionID = PlanExecuteMissionID(rawValue: rawID) {
                                                    o.planExecute = true
                                                    o.planExecuteResumeID = missionID
                                                } else {
                                                    o.optionErrors.append("--plan-execute-resume requires exactly 64 lowercase hexadecimal characters")
                                                }
                                            } else {
                                                o.optionErrors.append("--plan-execute-resume requires <mission-id>")
                                            }
            case "--mission":               o.mission = true
            case "--autonomy-receipts":     o.autonomyReceipts = true
            case "--research":              o.research = true
            case "--council", "--consult":  o.council = true
            case "--council-execute", "--council-build", "--consult-execute":
                                            o.council = true; o.councilExecute = true
            case "--dig", "--dig-in-deep", "--dig-deep":  o.digDeep = true
            case "--fleet":                 o.fleet = true
            case "--evolve":                o.evolve = true
            case "--evolve-status":         o.evolveStatus = true
            case "--evolve-tree":           o.evolveTree = true
            case "--evolve-arm":            o.evolveArm = true
            case "--evolve-disarm":         o.evolveDisarm = true
            case "--evolve-session":        o.evolveSession = true
            case "--max-sessions":          if let v = next(), let n = Int(v), n > 0 { o.maxSessions = min(n, 1000) }
            case "--arm-hours":             if let v = next(), let n = Int(v), n > 0 { o.armHours = min(n, 24 * 30) }
            case "--agents":                if let v = next(), let n = Int(v), n > 0 { o.agents = n }
            case "--variants":              if let v = next(), let n = Int(v), n > 0 { o.variants = min(n, 10) }
            case "--generations":           if let v = next(), let n = Int(v), n > 0 { o.generations = min(n, 20) }
            case "--evolve-patience":       if let v = next(), let n = Int(v), n >= 0 { o.evolvePatience = min(n, 20) }
            case "--evolve-test":           if let v = next() { o.evolveBenchmarkCommands.append(v) }
            case "--evolve-timeout":        if let v = next(), let n = Int(v), n > 0 { o.evolveTimeout = min(n, 3600) }
            case "--delegation-depth":      if let v = next(), let n = Int(v), n >= 0 { o.delegationDepth = min(n, 3) }
            case "--planner":               o.plannerSpec = next()
            case "--worker":                o.workerSpec = next()
            case "--coder", "--builder":    o.coderSpec = next()
            case "--critic":                o.criticSpec = next()
            case "--review-grade":
                if let raw = next(), let grade = EvolutionReviewGrade(rawValue: raw) {
                    o.reviewGrade = grade
                } else {
                    o.optionErrors.append("--review-grade requires independent or fresh_context_same_model")
                }
            case "--roles":                 o.roleProfile = next()
            case "--budget":                if let v = next(), let n = Int(v), n > 0 { o.budgetTokens = n }
            case "--max-cost":
                if let v = next() {
                    let d = Double(v.replacingOccurrences(of: "$", with: ""))
                    if let d, d.isFinite, d > 0 { o.maxCostUSD = d }
                    else { FileHandle.standardError.write(Data("error: --max-cost must be a positive dollar amount (got '\(v)') — ignoring; run is UNCAPPED unless --budget is set\n".utf8)) }
                }
            case "--no-memory":             o.noMemory = true
            case "--list-learning-sync":     o.listLearningSync = true
            case "--list-learning-status":   o.listLearningStatus = true
            case "--fast", "--solo":        o.fast = true
            case "--tui":                   o.tui = true
            case "--no-pinned-bar":         o.pinnedBar = false
            case "--pinned-bar":            o.pinnedBar = true
            case "--sticky-turns":          o.stickyTurns = true
            case "--no-sticky-turns":       o.stickyTurns = false
            case "--sticky-bar-self-test":  o.stickyBarSelfTest = true
            case "--tools":                 if let v = next()?.lowercased(), ["auto", "native", "text"].contains(v) { o.toolMode = v }
            case "--fetch-host":            if let v = next() { o.fetchAllowedHosts.append(v) }
            case "--health":                o.providerHealth = true
            case "--probe-providers":       o.probeProviders = true
            case "--providers-doctor":      o.providersDoctor = true
            case "--bench":                 o.bench = true
            case "--eval":                  o.eval = true
            case "--protocols":             o.protocolStatus = true
            case "--auth-token":            o.authToken = next()
            // host-snapshot numeric flags: a PRESENT-but-non-integer value is NOT silently swallowed (which
            // would proceed on display 0 / default rate). It sets a parse-error signal the host-snapshot
            // runner turns into an atomic kist-cli-json-v1 error + nonzero exit BEFORE auth/capture.
            case "--display":
                if let v = next() { if let n = Int(v) { o.displayIndex = n } else { o.hostSnapshotDisplayParseError = true } }
            case "--stream":                o.hostSnapshotStream = true
            case "--pubkey":                o.hostSnapshotPubkey = true
            case "--nonce":                 o.hostSnapshotNonce = next()
            case "--fps":
                if let v = next() { if let n = Int(v) { o.fps = n } else { o.hostSnapshotFpsParseError = true } }
            case "--max-frames":
                if let v = next() { if let n = Int(v) { o.maxFrames = n } else { o.hostSnapshotMaxFramesParseError = true } }
            case "--no-audit":              o.noAudit = true
            case "--trust-skill":           o.trustSkill = next()
            case "--trust-publisher":
                // Two args: <keyID> <pubkeyB64>. Both required; a missing second arg leaves it unset.
                if let keyID = next(), let pubkey = next() { o.trustPublisher = (keyID, pubkey) }
            case "--skills":                o.listSkills = true
            case "--replay":                o.replayId = next() ?? "latest"
            default:                        positional.append(args[i])
            }
            i += 1
        }
        // Subcommand: `kist mcp auth <server> <metadata-url> [client-id] [scope]` — the one-time OAuth
        // authorize for a remote MCP server. Captured before the positional becomes a goal.
        if positional.count >= 2, positional[0] == "mcp", positional[1] == "auth" {
            o.mcpAuth = Array(positional.dropFirst(2))
        } else if positional.first == "host-snapshot" {
            // Fixed CLI mode (SECURITY BOUNDARY): `host-snapshot` ⇒ single frame; `--stream` ⇒ NDJSON.
            // Not a goal, not a model-callable tool. hostSnapshotStream (set by --stream) branches dispatch.
            o.hostSnapshot = true
        } else if !positional.isEmpty {
            o.goal = positional.joined(separator: " ")
        }
        if o.planExecuteResumeID != nil,
           o.goal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            o.optionErrors.append("--plan-execute-resume requires the same nonempty goal")
        }
        if o.headless {
            let conflicts = [
                (o.planExecute, "--plan-execute"),
                (o.fleet, "--fleet"),
                (o.mission, "--mission"),
                (o.greatLoop, "--loop"),
                (o.cobolo, "--cobolo"),
            ].compactMap { enabled, flag in enabled ? flag : nil }
            if !conflicts.isEmpty {
                o.optionErrors.append(
                    "--headless conflicts with " + conflicts.joined(separator: ", "))
            }
        }
        if o.cobolo {
            if o.cobolTarget?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--cobolo requires --cobol-target <project-relative .cbl/.cob path>")
            }
            if o.cobolExpect?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--cobolo requires --cobol-expect <stdout substring>")
            }
            if o.mission || o.fleet || o.planExecute || o.greatLoop {
                o.optionErrors.append("--cobolo/--cobol-loop conflicts with --mission, --fleet, --plan-execute, and --loop")
            }
        } else if o.cobolTarget != nil || o.cobolExpect != nil {
            o.optionErrors.append("--cobol-target and --cobol-expect require --cobolo or --cobol-loop")
        }
        if sawCobolMaxRevisions && !o.cobolo {
            o.optionErrors.append("--cobol-max-revisions requires --cobolo or --cobol-loop")
        }
        let smlRuntimeModes: [(flag: String, active: Bool)] = [
            ("--sml-store", o.smlStoreAction != nil),
            ("--sml-import-openapi", o.smlOpenAPIImport != nil),
            ("--sml-runtime-export", o.smlRuntimeExport != nil),
            ("--sml-runtime-launch", o.smlRuntimeLaunch != nil),
            ("--sml-runtime-openapi", o.smlRuntimeOpenAPI != nil),
            ("--sml-runtime-model-router", o.smlRuntimeModelRouter != nil),
            ("--sml-runtime-onyx", o.smlRuntimeOnyx != nil),
            ("--sml-runtime-planning", o.smlRuntimePlanning != nil),
            ("--sml-runtime-catalog", o.smlRuntimeCatalog != nil),
            ("--sml-runtime-mount", o.smlRuntimeMount != nil),
            ("--sml-runtime-agent-guide", o.smlRuntimeAgentGuide != nil),
            ("--sml-runtime-host-guide", o.smlRuntimeHostGuide != nil),
            ("--sml-runtime-host-wiring", o.smlRuntimeHostWiring != nil),
            ("--sml-runtime-runbook", o.smlRuntimeRunbook != nil),
            ("--sml-runtime-scaffold", o.smlRuntimeScaffold != nil),
            ("--sml-runtime-attachments", o.smlRuntimeAttachments != nil),
            ("--sml-runtime-serve", o.smlRuntimeServe != nil),
            ("--sml-runtime-repl", o.smlRuntimeREPL != nil),
            ("--sml-runtime-repl-script", o.smlRuntimeREPLScript != nil),
            ("--sml-runtime-api", o.smlRuntimeAPI != nil),
            ("--sml-runtime-api-script", o.smlRuntimeAPIScript != nil),
            ("--sml-runtime-model", o.smlRuntimeModel != nil),
            ("--sml-runtime-model-script", o.smlRuntimeModelScript != nil),
        ]
        let activeSMLRuntimeModes = smlRuntimeModes.filter { $0.active }
        for firstIndex in activeSMLRuntimeModes.indices {
            for secondIndex in activeSMLRuntimeModes.indices where secondIndex > firstIndex {
                o.optionErrors.append(
                    "\(activeSMLRuntimeModes[firstIndex].flag) conflicts with \(activeSMLRuntimeModes[secondIndex].flag)"
                )
            }
        }
        if o.smlRuntimeServe == nil, o.smlRuntimeServePort != nil {
            o.optionErrors.append("--sml-port requires --sml-runtime-serve <source.json>")
        }
        if let action = o.smlStoreAction {
            if ["backup", "restore"].contains(action) {
                if o.smlBackupPath == nil { o.optionErrors.append("--sml-store \(action) requires --sml-backup <path>") }
            } else if o.smlBackupPath != nil {
                o.optionErrors.append("--sml-backup requires --sml-store backup or restore")
            }
            if action == "archive" {
                if o.smlArchiveBefore == nil { o.optionErrors.append("--sml-store archive requires --sml-archive-before <ISO8601>") }
            } else if o.smlArchiveBefore != nil || o.smlArchiveMaximum != nil {
                o.optionErrors.append("--sml-archive-before and --sml-archive-max require --sml-store archive")
            }
            if action != "restore", o.smlReplaceSHA256 != nil {
                o.optionErrors.append("--sml-replace-sha256 requires --sml-store restore")
            }
        } else if o.smlBackupPath != nil || o.smlArchiveBefore != nil
            || o.smlArchiveMaximum != nil || o.smlReplaceSHA256 != nil {
            o.optionErrors.append("SML maintenance options require --sml-store <action>")
        }
        if o.smlRuntimeREPL != nil {
            // No --sml-line means the INTERACTIVE loop (reads lines from stdin until exit/EOF).
            // A provided-but-blank line is still an operator mistake.
            if let line = o.smlRuntimeREPLLine,
               line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                o.optionErrors.append("--sml-line must not be blank")
            }
        } else if o.smlRuntimeREPLLine != nil {
            o.optionErrors.append("--sml-line requires --sml-runtime-repl <source.json>")
        }
        if o.smlRuntimeREPLScript != nil {
            if o.smlRuntimeREPLScriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--sml-runtime-repl-script requires --sml-script <path>")
            }
        } else if o.smlRuntimeREPLScriptPath != nil {
            o.optionErrors.append("--sml-script requires --sml-runtime-repl-script <source.json>")
        }
        if o.smlRuntimeWorkflowID != nil
            && o.smlRuntimeREPL == nil
            && o.smlRuntimeREPLScript == nil
            && o.smlRuntimeAttachments == nil
            && o.smlRuntimeOnyx == nil
            && o.smlRuntimeRunbook == nil {
            o.optionErrors.append(
                "--sml-workflow requires --sml-runtime-repl, --sml-runtime-repl-script, --sml-runtime-runbook, or --sml-runtime-attachments <source.json>; it can also filter --sml-runtime-onyx <source.json>"
            )
        }
        if o.smlRuntimeAPI != nil {
            if o.smlRuntimeAPIPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--sml-runtime-api requires --sml-path <path>")
            }
        } else {
            if sawSMLRuntimeAPIMethod {
                o.optionErrors.append("--sml-method requires --sml-runtime-api <source.json>")
            }
            if o.smlRuntimeAPIPath != nil {
                o.optionErrors.append("--sml-path requires --sml-runtime-api <source.json>")
            }
            if o.smlRuntimeAPIBody != nil {
                o.optionErrors.append("--sml-body requires --sml-runtime-api <source.json>")
            }
        }
        if o.smlRuntimeAPIScript != nil {
            if o.smlRuntimeAPIScriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--sml-runtime-api-script requires --sml-api-script <path>")
            }
        } else if o.smlRuntimeAPIScriptPath != nil {
            o.optionErrors.append("--sml-api-script requires --sml-runtime-api-script <source.json>")
        }
        if o.smlRuntimeScaffold != nil {
            if o.smlRuntimeOutputDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--sml-runtime-scaffold requires --sml-out <dir>")
            }
        } else if o.smlRuntimeOutputDirectory != nil && o.smlOpenAPIImport == nil {
            o.optionErrors.append(
                "--sml-out requires --sml-runtime-scaffold or --sml-import-openapi <source.json>")
        }
        if o.smlOpenAPIImport == nil, o.smlOpenAPIID != nil {
            o.optionErrors.append("--sml-api-id requires --sml-import-openapi <openapi.json>")
        } else if let apiID = o.smlOpenAPIID,
                  apiID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            o.optionErrors.append("--sml-api-id must not be blank")
        }
        if o.smlRuntimeModel != nil {
            let prompt = o.smlRuntimeModelPrompt ?? o.goal
            if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--sml-runtime-model requires --sml-prompt <text> or a positional prompt")
            }
        } else if o.smlRuntimeModelPrompt != nil {
            o.optionErrors.append("--sml-prompt requires --sml-runtime-model <source.json>")
        }
        if o.smlRuntimeModelScript != nil {
            if o.smlRuntimeModelScriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                o.optionErrors.append("--sml-runtime-model-script requires --sml-model-script <path>")
            }
        } else if o.smlRuntimeModelScriptPath != nil {
            o.optionErrors.append("--sml-model-script requires --sml-runtime-model-script <source.json>")
        }
        // Autopilot is an UMBRELLA: it implies no-prompt (yolo) + shell + a FORCED OS sandbox.
        // Forced last so it can never be silently un-set by flag order or a future --no-sandbox.
        // Rationale (Luke's policy): everything always runs through a sandbox — autonomy is bought
        // with isolation, not by removing verification. The fleet's captain/signoff gates still apply.
        if o.ship || o.mission || o.cobolo { o.auto = true } // mutation lanes are hands-free only inside the forced sandbox
        if o.auto { o.yolo = true; o.allowShell = true; o.sandbox = true }
        // SECURITY (council-mandated 2026-07-03): a kist spawned BY another kist (an agent's run_command →
        // `kist …`) inherits KIST_ACTIVE. A NESTED instance must not be able to self-escalate to unattended
        // desktop control or guards-off — that was the escalation path the council found. Refuse the arming
        // + guards-off flags when nested; the top-level user invocation (no KIST_ACTIVE) is unaffected.
        if ProcessInfo.processInfo.environment["KIST_ACTIVE"] != nil {
            o.enableComputerUse = false
            o.auto = false
            o.yolo = false
            // A nested kist must not self-widen its READ surface either (an agent spawning
            // `kist --allow-read /` would un-confine reads). Same fail-closed strip as arming.
            o.allowReadPaths = []
            o.nestedRefusedEscalation = true   // surfaced by the runner as a visible note, never silent
        }
        return o
    }

    static let helpText = """
    Mythos / kist — an open-source agent shell that runs on ANY model you bring a key for.

    USAGE:
      kist "<goal>"                 Run the goal to completion, streaming to the terminal.
      kist --headless "<goal>"      Force the governed direct Builder adapter for deterministic dogfood.
      kist --resume <id>            Resume a checkpointed run where it left off.
      kist --resume-last            Resume the most recent unfinished run.
      kist --plan-execute-resume <mission-id> "<same goal>"
                                    Resume exactly one PlanExecute mission; no latest/goal lookup.
      kist --list                   List resumable runs.
      kist --inspect-builder-evidence <sealed-run.json>  Inspect historical training evidence offline.
      kist --list-providers         Show providers and which have a key configured.
      kist --gemini-test            Live smoke-test of the Gemini clients (needs a Gemini key).
      kist --ship "<goal>"          Build hands-free in the autopilot sandbox, then the council of
                                    minds reviews the result → GO/NO-GO (deploy stays your call).
      kist --mission "<goal>"       Autonomous gated mission: research/council → measured simulation
                                    and trials → verified execution → independent review.
      kist --health                 Show provider/model/router health without spending tokens.
      kist --probe-providers        Full live probe of configured providers; may take 1-2 minutes.
      kist --model-vet hf:<repo>    Fetch live model metadata and hard-reject unsafe downloads.
      kist --model-acquire <json>   Verify an acquisition manifest before local-model download.
      kist --model-run <stage> <json>
                                    Run a verified acquisition stage: dry-run, download, inspect,
                                    onboard, or benchmark.
      kist --bench "<task>"         Run the task across configured providers and compare.
      kist --eval "<task>"          Run the task with deterministic agent-behavior assertions.
      kist --loop "<goal>"          Great-loop: self-assess effort per cycle, learn from history, and keep
                                    working (verify each cycle) until done-and-verified or a safety cap.
                                    Caps: --budget <tok> · --loop-hours <h> · --max-cycles <n>. (long-horizon)
      kist --cobolo --cobol-target <path.cbl> --cobol-expect <stdout> [--cobol-max-revisions <1...3>] "<goal>"
                                    Local-only COBOL specialist → sandboxed replay → independent reviews
                                    → lease-bound conditional promotion. Alias: --cobol-loop.
      kist --research "<goal>"      Evidence run → research dossier → council → task board.
      kist --dig "<question>"       Ask EVERY reachable model the same question, synthesize agree/disagree.
      kist --council "<goal>"       Research → council → decision → visible task board.
      kist --council-execute "<g>"  Same, then hand the builder brief to plan→execute.
      kist --protocols              Show MCP/A2A/browser/computer-control status.
      kist --replay [id]            Show a durable run replay from .kist/runs (default latest).
      kist --verify [--verify-cmd "<cmd>"] [--proofs <file>]
                                    Run deterministic checks on the STAGED change and seal a Verification
                                    Receipt (bound to the exact diff) under .kist/receipts/. Commit it.
                                    --proofs folds machine-checkable claims (proof-carrying patch) into the
                                    receipt; a false claim fails the verdict so a lying patch can't merge.
      kist --guard                  Local pre-commit gate: admit the staged change only if a valid receipt
                                    covers it. Bypassable (--no-verify) — defense-in-depth, not the boundary.
      kist --install-guard          Install the pre-commit --guard hook (honors core.hooksPath).
      kist --ci-guard [base] [head] SERVER-AUTHORITATIVE gate: every content-bearing commit in base..head must
                                    carry a valid receipt. Run as a CI REQUIRED CHECK — cannot be --no-verify'd.
                                    Refs inferred from CI env (GITHUB_BASE_REF/GITHUB_SHA) when omitted.
                                    When issuer keys are pinned, each change ALSO needs a valid Ed25519 signature.
      kist --gen-issuer-key <id>    Generate an Ed25519 issuer keypair (private 0600 + public to distribute).
      kist --trust-issuer <id> <pub>  Pin an issuer PUBLIC key — receipts it signs become trusted (cross-org tier).
      kist --unpin-issuer <id>      Stop trusting an issuer (removable; re-pinnable later).
      kist --revoke-issuer <id>     REVOKE a compromised issuer — its signatures are rejected and it can't be
                                    re-pinned until --unrevoke-issuer. Rotate: gen+trust a NEW key, re-sign.
      kist --unrevoke-issuer <id>   Lift a revocation.
      kist --list-issuers           Show pinned + revoked receipt issuer keys.
      kist --trust-root <id> <pub>  Pin a TRUST ROOT — trust bundles it signs distribute issuers (scales trust).
      kist --make-bundle --root-key <priv> [--bundle-out <path>]
                                    Sign the local issuer set into a distributable bundle (.kist/trust-bundle.json).
      kist --verify-bundle <path>   Verify a signed trust bundle against pinned roots.
      kist --list-roots             Show pinned trust roots.
      kist --sign-receipt <digest|latest> --issuer-key <priv>
                                    Ed25519-sign a stored receipt's change → .kist/receipts/<digest>.sig.json.

    OPTIONS:
      -p, --provider <id>           Provider id (default: first configured cloud provider, else local).
      -m, --model <id>              Model id (default: the provider's default).
          --by-cost / --by-power    Pick the DEFAULT model by cost (cheapest) or power (strongest,
                                    default). Persist with config "selectBy" or the /power · /economy
                                    REPL commands. An explicit -p/--provider always overrides.
      -C, --project <path>          Project root the agent is confined to (default: current dir).
          --max-iterations <n>      Max plan→act steps (default: 40).
          --allow-shell             Enable the run_command tool (OFF by default).
          --allow-read <dir>        ALSO allow the file/search tools to READ under <dir> (repeatable),
                                    e.g. --allow-read /Volumes to browse a mounted CD/USB drive.
                                    Read-only: write/edit/move/delete stay confined to the project
                                    root. Never inherited by a nested kist. "/" is refused.
          --sandbox                 Run shell commands inside the macOS Seatbelt OS sandbox.
          --sticky-turns            EXPERIMENTAL opt-in: keep the input box pinned DURING turns
                                    (scroll-region). Off by default — known to corrupt on window
                                    resize in some terminals; --no-sticky-turns restores the default.
          --trust-worktree-tests    Let the fleet verifier trust an IN-REPO test harness (base-trusted
                                    test.sh / swift-test / npm). OFF by default: only a held-out operator
                                    oracle (~/.kist/test-command) verifies. Opt in ONLY for your own honest
                                    agents (a shell harness can transitively run agent code).
          --yolo                    REPL: skip approval prompts for shell/file-write tools.
          --auto, --danger          Hands-off autopilot: implies --yolo + --allow-shell and FORCES
                                    --sandbox (cannot be disabled). Everything runs OS-sandboxed;
                                    on a platform with no sandbox, shell fails closed (won't run raw).
                                    Generated custom_tool helpers also run here without prompts, but
                                    only as project-local sandboxed Python scripts.
                                    Fleet trust gates (captain signoff, merge gate) still apply —
                                    autopilot never pushes/merges to main without a captain's OK.
          --think                   Extended thinking: the model reasons before each action (reasoning
                                    shown inline + saved to the replay). In the REPL, toggle with /think.
          --plan                    Plan mode: read-only; the agent proposes a step-by-step plan
                                    instead of editing. In the REPL, toggle with /plan.
          --headless                Force the typed direct Builder adapter. The run still uses a sealed
                                    preflight contract, scoped mutation tools, finite budgets,
                                    deterministic verification, and independent review.
          --plan-execute            Plan→execute: the planner emits a typed step DAG, you approve
                                    it (unless --yolo), then it runs to completion. (one-shot)
          --plan-execute-resume <mission-id>
                                    Resume the exact PlanExecute mission using the supplied same goal.
                                    The ID is 64 lowercase hex; never selects latest or Headless state.
          --cobolo                 High-assurance local COBOL builder. Alias: --cobol-loop.
              --cobol-target <path>    Required project-relative .cbl/.cob target; its parent must exist.
          --cobol-expect <text>    Required stdout substring; sandbox and exit 0 are also mandatory.
          --cobol-max-revisions <n>
                                    Maximum critic-driven candidate revisions (default 3; range 1...3).
          --research                Run an evidence-first research pipeline: web/source discovery,
                                    repo context, durable dossier, council synthesis, task board.
          --council, --consult      Run the AI council as a first-class surface: researcher →
                                    architect → coder → critic → UX → memory → final plan.
                                    Saves the full council artifact and seeds .kist/plan.json
                                    so /goals shows the kanban board immediately.
          --council-execute         Run the council, seed the task board, then hand the council's
                                    builder brief to plan→execute. Alias: --council-build.
          --fleet                   Launch a SUPERVISED parallel fleet: the planner splits the goal
                                    into DISJOINT-scoped subtasks, each runs in an isolated staged
                                    filesystem workspace (heterogeneous — bind roles per vendor), then
                                    one aggregate subject is deterministically verified + independently
                                    reviewed before a journaled global promotion. No Git repo required;
                                    partial child results never publish. (one-shot)
          --evolve                  Run a DGM-style evolution lab: create isolated candidate
                                    worktrees, ask the role-bound team to improve Mythos itself,
                                    benchmark each candidate, and append results to
                                    .mythos/evolution/archive.jsonl. NEVER auto-promotes.
          --agents <n>              Max fleet size for --fleet (default 5; hard-capped).
          --variants <n>            Candidate count for --evolve (default 1; max 10).
          --evolve-test <cmd>       Benchmark command for --evolve. Repeatable. Defaults to
                                    ./test.sh, swift test, or git diff --check depending on repo.
          --evolve-timeout <sec>    Per-benchmark timeout for --evolve (default 600; max 3600).
          --delegation-depth <n>    Nested teammate delegation for spawn_agent (default 1; max 3).
                                    0 = sub-agents cannot spawn helpers; 1 = a sub-agent can ask
                                    one more teammate for help while staying bounded.
          --planner <prov[:model]>  Vendor for the PLANNER role (default: the chosen provider).
          --worker  <prov[:model]>  Vendor for the WORKER/research role used by spawned sub-agents.
          --coder   <prov[:model]>  Vendor for the CODER/BUILDER role — the `generate` tool that produces
                                    content (code/prose) runs on this vendor.
          --builder <prov[:model]>  Alias for --coder.
          --critic  <prov[:model]>  Vendor for the CRITIC / verify-the-goal role. Bind different
                                    vendors per role for a team, e.g.:
                                    --provider openai --builder deepseek --critic gemini
                                    --fleet "big build" --coder mimo --worker deepseek --critic gemini
          --review-grade <grade>    Review evidence for /grow or Builder. Default `independent` requires
                                    a distinct provider. `fresh_context_same_model` is never independent
                                    or deployment authority. Builder permits it only with an explicit exact
                                    --critic on a sandboxed --headless --auto build in a non-Git disposable
                                    temp root, sealed to one file mutation and one deterministic verifier.
          --roles <name>            Load a saved role profile from ~/.config/kist/roles.json.
                                    Explicit role flags override it.
          --budget <tokens>         Hard TOKEN ceiling. Enforced on the agent loops — one-shot, REPL,
                                    resume, plan→execute, --council/--research, --fleet (planner + all
                                    workers share one cap), and --evolve. Halts honestly at the cap;
                                    shared across the delegation tree so no spawned agent overspends.
          --max-cost <usd>          Hard DOLLAR ceiling (e.g. --max-cost 0.50), priced per provider
                                    (a 1M-token Gemini call ≠ Claude). Either cap halts the run.
                                    Combine with --budget. Unpriced providers count toward tokens only.
          --list-learning-sync      Import recent project observations from LIST MCP; no model or execution.
          --list-learning-status    Show dated LIST advisory memory and review-only proposal counts.
          --operator-action         One bounded JSON action on stdin; requires an existing host grant.
          --no-memory               Disable cross-run memory (otherwise plan→execute ingests
                                    AGENTS.md/CLAUDE.md + recent run outcomes as planning context,
                                    and logs each run to .mythos/memory/).
          --tools <mode>            Tool-calling mode: auto (default; native when the model
                                    supports it, else the universal text protocol), native, or text.
          --fetch-host <host>       Restrict fetch_url to this host pattern. Repeatable. Exact
                                    hosts or wildcards like *.swift.org. Also configurable with
                                    {"fetchAllowedHosts":["docs.swift.org"]}.
          --health                  Offline provider health: keys, default model catalog, native/text route.
          --probe-providers         Full live provider health probe; waits for real provider latency and
                                    catches stale models like a 404 Grok id.
          --model-vet <spec>        Hard pre-download gate for local/Hugging Face models. Fetches live
                                    metadata, requires allowlisted license/provenance/size/safe-format weight files,
                                    writes .kist learning artifacts, and exits nonzero on rejection.
          --model-acquire <json>    Verify a model acquisition manifest: policy hash, approval id,
                                    pinned commands, project-local target, and next gate tasks.
          --model-run <stage> <json>
                                    Execute only the stage authorized by a verified acquisition
                                    manifest. Download requires a prior passing dry-run marker;
                                    inspect/onboard/benchmark require the prior stage markers.
          --sml-import-openapi <openapi.json> [--sml-api-id <id>] [--sml-out <dir>]
                                    Import a project-confined OpenAPI 3 JSON document into a
                                    secret-free, pinned HTTP endpoint bundle, create-only wrapper
                                    workflows/source set, and a review-required catalog proposal.
                                    Never modifies the live catalog or creates credentials.
          --sml-runtime-export <json>
                                    Offline-wrap a LangGraph manifest, SML workflow JSON, SML
                                    runtime source package, or runtime source set with optional
                                    per-workflow role/API-base/API-path/model-rounds into a host JSON
                                    payload containing the generated custom REPL mount,
                                    API/OpenAPI routes, native model-router tool, Onyx driver
                                    manifests, planning graph, and launch descriptor.
          --sml-runtime-launch <json>
                                    Launch the wrapped source offline and emit the exact launch
                                    descriptor/receipt for mounted REPL, API, model, Onyx, and
                                    planning adapters.
          --sml-runtime-openapi <json>
                                    Launch the wrapped source offline and emit the generated
                                    OpenAPI document plus its runtime endpoint and launch receipt.
          --sml-runtime-model-router <json>
                                    Launch the wrapped source offline and emit the native
                                    model-router tool descriptor plus launch receipt.
          --sml-runtime-onyx <json> [--sml-workflow <id>]
                                    Launch the wrapped source offline and emit all generated Onyx
                                    driver manifests, or one workflow's driver when filtered.
          --sml-runtime-planning <json>
                                    Launch the wrapped source offline and emit the aggregate
                                    planning manifest: skill index, tool index, graph units,
                                    approval gates, and command bindings.
          --sml-runtime-catalog <json>
                                    Launch the wrapped source offline and emit the mounted
                                    workflow runtime catalog.
          --sml-runtime-mount <json>
                                    Launch the wrapped source offline and emit the host mount
                                    contract for generated REPL/API/model/Onyx/planning surfaces.
          --sml-runtime-agent-guide <json>
                                    Launch the wrapped source offline and emit the canonical
                                    agent/model operating guide.
          --sml-runtime-host-guide <json>
                                    Launch the wrapped source offline and emit the canonical
                                    host integration guide.
          --sml-runtime-host-wiring <json>
                                    Launch the wrapped source offline and emit the compact host
                                    wiring map for REPL/API/model-router/Onyx/planning adapters.
          --sml-runtime-runbook <json> [--sml-workflow <id>]
                                    Launch the wrapped source offline and emit a machine-readable
                                    host runbook with artifact paths, inline scripts, command templates,
                                    API endpoints, model-router IDs, Onyx driver IDs, and planning IDs.
          --sml-runtime-scaffold <json> --sml-out <dir>
                                    Launch the wrapped source offline and write catalog, mount,
                                    OpenAPI, model-router, Onyx, planning, guide, wiring, runbook,
                                    and attachment artifacts into one host-consumable directory.
          --sml-runtime-attachments <json> [--sml-workflow <id>]
                                    Emit the per-workflow attachment manifests for generated REPL,
                                    API, model-router, Onyx driver, and planning adapters; optionally
                                    filter to one mounted workflow.
          --sml-runtime-repl <json> [--sml-line <line>] [--sml-workflow <id>]
                                    Open the generated workflow REPL on stdin/stdout. With --sml-line,
                                    run one command and return command/result JSON instead. Add
                                    --sml-runtime-durable for approval-gated live capability dispatch.
          --sml-runtime-repl-script <json> --sml-script <path> [--sml-workflow <id>]
                                    Launch the same wrapped source offline and run a multi-turn
                                    generated workflow REPL script, returning a transcript whose
                                    later commands can use the session's remembered task ID.
          --sml-runtime-api <json> --sml-path <path> [--sml-method <GET|POST>] [--sml-body <json>]
                                    Launch the same wrapped source offline and handle one generated
                                    runtime API request, returning route, command, result, and body JSON.
          --sml-runtime-api-script <json> --sml-api-script <path>
                                    Launch the same wrapped source offline and handle a JSON array of
                                    generated runtime API requests, returning a transcript of exchanges.
          --sml-runtime-model <json> [--sml-prompt <text>] [--provider <id>] [--model <id>]
                                    Launch the wrapped source and let the selected native-tool model
                                    drive mounted workflows through propose_sml_runtime_command.
          --sml-runtime-model-script <json> --sml-model-script <path> [--provider <id>] [--model <id>]
                                    Launch the wrapped source and run a multi-turn prompt script
                                    through one generated model-router session.
          --sml-runtime-serve <json> [--sml-port <port>]
                                    Long-lived durable harness: approval-gated workflows served
                                    over loopback HTTP with a per-session bearer token
                                    (.kist/sml/serve/session-token). GET /approvals lists pending
                                    human gates; approving through the generated task routes
                                    triggers the single-flight capability pump. Requires the
                                    human-owned .kist/sml/authority.json + catalog.json.
          --sml-store <verify|backup|restore|archive> --project <root>
                                    Offline durable-store maintenance; fails while a host owns
                                    the project. JSON report includes counts and runtime digest.
              --sml-backup <path>       New backup destination, or existing bundle to restore.
              --sml-archive-before <ISO8601>  Preserve older terminal tasks in queryable archives.
              --sml-archive-max <N>     Maximum tasks per archive operation (default 1000).
              --sml-replace-sha256 <digest>  Exact current runtime digest for existing-store restore.
              --sml-runtime-durable     REPL/API verbs use the persistent project store
                                        (.kist/sml/runtime.json), the real clock, and the
                                        human-owned .kist/sml/authority.json + catalog.json
                                        instead of the ephemeral rubber-stamp export host;
                                        takes the exclusive .kist/sml/host.lock while running.
              --sml-role <role>         Override workflow role for the generated mount.
              --sml-api-base <path>     Override API base path for generated endpoints.
              --sml-api-workflow-path <id>=<path>
                                        Override one generated workflow API path; repeat per workflow.
              --sml-out <dir>           Project-confined output directory for scaffold/import.
              --sml-script <path>       Script file for --sml-runtime-repl-script; blank lines and
                                        leading # comments are ignored.
              --sml-api-script <path>   JSON request array for --sml-runtime-api-script.
              --sml-model-script <path> Line-oriented prompt script for --sml-runtime-model-script;
                                        blank lines and leading # comments are ignored.
              --sml-model-rounds <n>    Override model-router round ceiling (1...8).
          --bench                   Provider bake-off for the given task: success, latency, usage/cost,
                                    tool failures, and tests evidence where available.
          --eval                    Agent regression check for the given task: output/trajectory assertions
                                    so behavior changes do not degrade silently.
          --protocols               Print protocol/tool-control status: MCP, A2A, browser, computer control.
          --replay [id]             Render a local replay ledger: model, tool events, outputs,
                                    failures, and proof artifact paths. Defaults to latest.
      -h, --help                    This help.

    KEYS (BYOK): resolved from the macOS Keychain or environment (e.g. OPENAI_API_KEY,
    ANTHROPIC_API_KEY, GEMINI_API_KEY). Local providers (Ollama, MLX) need no key.

    CONFIG: defaults in ~/.config/kist/config.json, e.g. {"provider":"openai","model":"gpt-5.5"}.
    Precedence: flags > config > built-in defaults.
    """
}
