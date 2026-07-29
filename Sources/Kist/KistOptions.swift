import Foundation
import AgentCore

/// Tiny hand-rolled argument parser (no external deps — Mythos ships as one static binary).
struct KistOptions {
    var goal: String?
    var providerId: String?
    var model: String?
    var project: String
    var maxIterations: Int = 12
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
    var planExecute = false         // plan→execute: planner emits a typed DAG, approve, then build it
    var research = false            // --research: evidence run -> council -> task board
    var council = false             // --council/--consult: research -> multi-model council -> task board
    var councilExecute = false      // --council-execute: council first, then hand builder brief to plan→execute
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
    var maxCostUSD: Double?         // --max-cost <usd>: hard DOLLAR ceiling (priced per provider); either
                                    // cap halts the run (aplus C-series cost governance).
    var noMemory = false            // --no-memory: disable cross-run memory (facts + episode log)
    var fast = false                // --fast: lean solo dev tool — core code tools only (drop media/vision/
                                    // browse/pentest/research/workflow extras) → far smaller prompt, cheaper, faster.
    var toolMode: String = "auto"   // tool acquisition: auto (capability-routed) | native | text
    var tui = false                 // --tui: raw-mode persistent-input TUI (PROTOTYPE; off by default)
    var pinnedBar = true            // R2b: input bar glued to the bottom (scroll-region pinned). Default
                                    // ON for interactive TTYs; `--no-pinned-bar` reverts to the inline box.
    var fetchAllowedHosts: [String] = []  // --fetch-host <host>: restrict fetch_url to exact/wildcard hosts
    var providerHealth = false     // --health: offline provider/model/router health report
    var probeProviders = false     // --probe-providers: live one-token provider probes
    var providersDoctor = false    // --providers-doctor: live GET /models diff vs catalog (dead-id preflight)
    var mcpAuth: [String]?         // `mcp auth <server> <metadata-url> [client-id] [scope]`: one-time OAuth authorize
    var bench = false              // --bench: run a task across configured providers and compare
    var eval = false               // --eval: run agent regression assertions for a task
    var protocolStatus = false     // --protocols: MCP/A2A/computer-control surface status
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
        var positional: [String] = []
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
            case "--list":                  o.listRuns = true
            case "--resume":                o.resumeId = next()
            case "--resume-last":           o.resumeLast = true
            case "--provider", "-p":        o.providerId = next()
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
            case "--plan-execute":          o.planExecute = true
            case "--research":              o.research = true
            case "--council", "--consult":  o.council = true
            case "--council-execute", "--council-build", "--consult-execute":
                                            o.council = true; o.councilExecute = true
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
            case "--roles":                 o.roleProfile = next()
            case "--budget":                if let v = next(), let n = Int(v), n > 0 { o.budgetTokens = n }
            case "--max-cost":
                if let v = next() {
                    let d = Double(v.replacingOccurrences(of: "$", with: ""))
                    if let d, d.isFinite, d > 0 { o.maxCostUSD = d }
                    else { FileHandle.standardError.write(Data("error: --max-cost must be a positive dollar amount (got '\(v)') — ignoring; run is UNCAPPED unless --budget is set\n".utf8)) }
                }
            case "--no-memory":             o.noMemory = true
            case "--fast", "--solo":        o.fast = true
            case "--tui":                   o.tui = true
            case "--no-pinned-bar":         o.pinnedBar = false
            case "--pinned-bar":            o.pinnedBar = true
            case "--tools":                 if let v = next()?.lowercased(), ["auto", "native", "text"].contains(v) { o.toolMode = v }
            case "--fetch-host":            if let v = next() { o.fetchAllowedHosts.append(v) }
            case "--health":                o.providerHealth = true
            case "--probe-providers":       o.probeProviders = true
            case "--providers-doctor":      o.providersDoctor = true
            case "--bench":                 o.bench = true
            case "--eval":                  o.eval = true
            case "--protocols":             o.protocolStatus = true
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
        } else if !positional.isEmpty {
            o.goal = positional.joined(separator: " ")
        }
        // Autopilot is an UMBRELLA: it implies no-prompt (yolo) + shell + a FORCED OS sandbox.
        // Forced last so it can never be silently un-set by flag order or a future --no-sandbox.
        // Rationale (Luke's policy): everything always runs through a sandbox — autonomy is bought
        // with isolation, not by removing verification. The fleet's captain/signoff gates still apply.
        if o.ship { o.auto = true }   // --ship builds hands-free in the autopilot sandbox first
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
      kist --resume <id>            Resume a checkpointed run where it left off.
      kist --resume-last            Resume the most recent unfinished run.
      kist --list                   List resumable runs.
      kist --list-providers         Show providers and which have a key configured.
      kist --gemini-test            Live smoke-test of the Gemini clients (needs a Gemini key).
      kist --ship "<goal>"          Build hands-free in the autopilot sandbox, then the council of
                                    minds reviews the result → GO/NO-GO (deploy stays your call).
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
      kist --research "<goal>"      Evidence run → research dossier → council → task board.
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
      -C, --project <path>          Project root the agent is confined to (default: current dir).
          --max-iterations <n>      Max plan→act steps (default: 12).
          --allow-shell             Enable the run_command tool (OFF by default).
          --allow-read <dir>        ALSO allow the file/search tools to READ under <dir> (repeatable),
                                    e.g. --allow-read /Volumes to browse a mounted CD/USB drive.
                                    Read-only: write/edit/move/delete stay confined to the project
                                    root. Never inherited by a nested kist. "/" is refused.
          --sandbox                 Run shell commands inside the macOS Seatbelt OS sandbox.
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
          --plan-execute            Plan→execute: the planner emits a typed step DAG, you approve
                                    it (unless --yolo), then it runs to completion. (one-shot)
          --research                Run an evidence-first research pipeline: web/source discovery,
                                    repo context, durable dossier, council synthesis, task board.
          --council, --consult      Run the AI council as a first-class surface: researcher →
                                    architect → coder → critic → UX → memory → final plan.
                                    Saves the full council artifact and seeds .kist/plan.json
                                    so /goals shows the kanban board immediately.
          --council-execute         Run the council, seed the task board, then hand the council's
                                    builder brief to plan→execute. Alias: --council-build.
          --fleet                   Launch a SUPERVISED parallel fleet: the planner splits the goal
                                    into DISJOINT-scoped subtasks, one agent runs each in its OWN git
                                    worktree (heterogeneous — bind roles per vendor), and a foreman
                                    VERIFIES + forge-proof SIGNS each before joining onto a fresh
                                    integration branch. NEVER touches main. (one-shot)
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
          --roles <name>            Load a saved role profile from ~/.config/kist/roles.json.
                                    Explicit role flags override it.
          --budget <tokens>         Hard TOKEN ceiling. Enforced on the agent loops — one-shot, REPL,
                                    resume, plan→execute, --council/--research, --fleet (planner + all
                                    workers share one cap), and --evolve. Halts honestly at the cap;
                                    shared across the delegation tree so no spawned agent overspends.
          --max-cost <usd>          Hard DOLLAR ceiling (e.g. --max-cost 0.50), priced per provider
                                    (a 1M-token Gemini call ≠ Claude). Either cap halts the run.
                                    Combine with --budget. Unpriced providers count toward tokens only.
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
