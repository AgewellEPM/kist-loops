import Foundation
import AgentCore
import DesignFlowKit
import ConnectorKit
import DockerControl
import TagTeamKit

// Headless entry point. No UI, no window — just the loops.
//
// Usage:
//   designflow run [--once] [--dry-run] [--interval <sec>] [--pipeline <key>]
//   designflow pipeline --input "<brief>" [--dry-run] [--pipeline <key>]
//   designflow scan [--dry-run]
//   designflow help

struct CLI {
    let args: [String]
    let log = Log("designflow")

    func flag(_ name: String) -> Bool { args.contains("--\(name)") }
    func value(_ name: String) -> String? {
        guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func run() async -> Int32 {
        let command = args.first(where: { !$0.hasPrefix("-") }) ?? "help"
        let dryRun = flag("dry-run")
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        switch command {
        case "help", "--help", "-h":
            printUsage(); return 0

        case "scan":
            return await runScan(dryRun: dryRun)

        case "pipeline":
            guard let input = value("input") else {
                log.error("pipeline requires --input \"<brief>\""); return 2
            }
            return await runPipeline(input: input, dryRun: dryRun, cwd: cwd)

        case "run":
            return await runLoop(dryRun: dryRun, cwd: cwd)

        case "promote":
            return runPromote(cwd: cwd)

        case "connectors":
            return await runConnectors(cwd: cwd)

        case "sandbox":
            return runSandbox()

        case "tagteam":
            return await runTagTeam(cwd: cwd)

        default:
            log.error("unknown command: \(command)"); printUsage(); return 2
        }
    }

    private func makeConfig(dryRun: Bool, cwd: URL) -> AppConfig? {
        do {
            let interval = value("interval").flatMap { UInt64($0) }
            return try AppConfig.load(cwd: cwd, dryRun: dryRun, intervalOverride: interval)
        } catch {
            log.error("\(error)"); return nil
        }
    }

    private func makeLLM(_ config: AppConfig) -> LLMClient {
        if config.dryRun { return StubLLMClient() }
        return OpenAIClient(apiKey: config.openAIKey ?? "", model: config.model)
    }

    private func makeScanner(dryRun: Bool) -> SignalScanner {
        dryRun ? StubSignalScanner() : HackerNewsScanner()
    }

    private func runScan(dryRun: Bool) async -> Int32 {
        let scanner = makeScanner(dryRun: dryRun)
        let ranker = SignalRanker()
        do {
            let ranked = ranker.rank(try await scanner.scan())
            for (i, r) in ranked.prefix(10).enumerated() {
                print(String(format: "%2d. [%.1f] %@", i + 1, r.score, r.signal.title))
            }
            return 0
        } catch {
            log.error("scan failed: \(error)"); return 1
        }
    }

    /// A spend budget is ALWAYS applied (Codex HIGH-5) — never optional. --max-llm-calls
    /// overrides the default; `--max-llm-calls 0` is honored (refuses every call).
    private static let defaultMaxLLMCalls = 100
    private func makeBudget() -> LLMBudget {
        LLMBudget(maxCalls: value("max-llm-calls").flatMap { Int($0) } ?? Self.defaultMaxLLMCalls)
    }

    private func runPipeline(input: String, dryRun: Bool, cwd: URL) async -> Int32 {
        guard let config = makeConfig(dryRun: dryRun, cwd: cwd) else { return 2 }
        let budget = makeBudget()
        let llm = BudgetedLLMClient(makeLLM(config), budget: budget)
        let pipeline = Pipeline.named(value("pipeline"))
        let agents = AgentFactory.agents(for: pipeline, llm: llm)
        // Unique per-run dir (Codex MED-6): epoch + random token so two manual runs in
        // the same second never share a workspace/ledger.
        let uniq = String(UUID().uuidString.prefix(8)).lowercased()
        let dir = config.outputRoot.appendingPathComponent("manual-\(Int(Date().timeIntervalSince1970))-\(uniq)", isDirectory: true)
        let result = await InnerPipeline().run(brief: input, agents: agents, workspace: GitWorkspace(root: dir))
        return report(result)
    }

    private func runLoop(dryRun: Bool, cwd: URL) async -> Int32 {
        guard let config = makeConfig(dryRun: dryRun, cwd: cwd) else { return 2 }
        // Hard spend cap ALWAYS applied (Codex HIGH-5), plus optional cycle bound.
        let budget = makeBudget()
        let llm = BudgetedLLMClient(makeLLM(config), budget: budget)
        let maxCycles = value("max-cycles").flatMap { Int($0) }

        let loop = OuterLoop(
            scanner: makeScanner(dryRun: dryRun),
            pipeline: Pipeline.named(value("pipeline")),
            llm: llm,
            outputRoot: config.outputRoot,
            budget: budget
        )
        if flag("once") {
            do {
                guard let result = try await loop.runOnce() else { return 0 }
                return report(result)
            } catch { log.error("\(error)"); return 1 }
        }
        await loop.run(intervalSeconds: config.loopIntervalSeconds, maxCycles: maxCycles)
        return 0
    }

    /// DRY consultation of the external deploy gate. Never writes, never arms.
    /// Exit 0 = GO, 3 = NO-GO, 2 = bad invocation.
    private func runPromote(cwd: URL) -> Int32 {
        guard let wsPath = value("workspace") else {
            log.error("promote requires --workspace <project dir>"); return 2
        }
        let wsURL = URL(fileURLWithPath: wsPath, isDirectory: true)
        let ledger = StageSignoffLedger(fileURL: wsURL.appendingPathComponent(".designflow-signoff.jsonl"))

        // Build id is a TRUSTED source: the project's committed HEAD ONLY. No user
        // override — the gate's own wiring constraint requires a trusted build id, and
        // a user string could be set to match a stale approval (DeepSeek review, LOW).
        let buildID = GitWorkspace(root: wsURL).headSHA() ?? ""

        // Readiness requires the FULL pipeline, in order, bound to this HEAD (Codex
        // BLOCKER-3) — not just any intact ledger. Only a complete build is promotable.
        let ready = PromotionCheck.internallyReady(
            ledger, expectedStages: Pipeline.full.agents, headSHA: buildID)
        let attestation = value("approval").flatMap { readFile($0) }.flatMap { PromotionCheck.parseApproval($0) }
        let pins = value("pins").flatMap { readFile($0) }.map { PromotionCheck.parsePins($0) } ?? []
        let consumed = value("consumed").flatMap { readFile($0) }.map { PromotionCheck.parseConsumed($0) } ?? []

        let decision = PromotionCheck.decide(
            buildID: buildID, internallyReady: ready,
            attestation: attestation, pins: pins, consumedApprovals: consumed)

        print("\n── promotion check (DRY — writes nothing) ──")
        print("build:            \(buildID.isEmpty ? "(unknown)" : buildID)")
        print("internally ready: \(ready)   (sealed signoffs: \(ledger.entries().count), chain \(ledger.verifyChain() == nil ? "intact" : "BROKEN"))")
        print("pinned keys:      \(pins.count)")
        if decision.promotable {
            print("verdict: ✅ GO — externally attested for this build")
            return 0
        } else {
            print("verdict: ⛔ NO-GO — \(decision.refusalReason ?? "refused")")
            return 3
        }
    }

    private func readFile(_ path: String) -> String? {
        try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }

    /// Universal connector layer: list / invoke REST + MCP connectors, with a sealed
    /// audit history. `designflow connectors <list|invoke|history> [--dir …]`.
    private func runConnectors(cwd: URL) async -> Int32 {
        let cfg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
        let dir = URL(fileURLWithPath: value("dir") ?? (cfg + "/kist/connectors"), isDirectory: true)
        let registry = ConnectorRegistry.load(fromDir: dir)
        let audit = ConnectorAudit(fileURL: dir.appendingPathComponent(".connector-audit.jsonl"))
        let sub = args.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? "list"

        switch sub {
        case "list":
            print("connectors dir: \(dir.path)")
            if registry.names.isEmpty { print("(none — drop a <name>.json REST manifest or <name>.mcp.json here)") }
            for name in registry.names {
                if let c = registry.connector(name) {
                    print("• \(name) [REST]  \(c.manifest.baseURL)")
                    for a in c.actions() { print("    - \(a.name): \(a.method) \(a.path)") }
                } else if let m = registry.mcp[name] {
                    print("• \(name) [MCP]   \(m.server)  tools: \(m.tools.joined(separator: ", "))")
                }
            }
            return 0

        case "invoke":
            guard let cname = value("connector"), let action = value("action") else {
                log.error("invoke requires --connector <name> --action <name> [--input k=v,k=v]"); return 2
            }
            guard let c = registry.connector(cname) else {
                log.error("no REST connector “\(cname)” (MCP invoke bridges to kist's MCP client)"); return 2
            }
            let input = Self.parseKV(value("input") ?? "")
            do {
                let result = try await AuditedConnector(c, audit: audit).invoke(action: action, input: input)
                print("HTTP \(result.statusCode) \(result.ok ? "OK" : "ERR")")
                print(result.body.prefix(4000))
                return result.ok ? 0 : 1
            } catch {
                log.error("\(error)"); return 1
            }

        case "history":
            let entries = audit.entries()
            print("audit: \(entries.count) entries (chain \(audit.verifyChain() == nil ? "intact" : "BROKEN"))")
            for e in entries.suffix(20) {
                let invocation = e.invocationID.map { " id:\($0)" } ?? ""
                print("  #\(e.seq) \(e.connector)/\(e.action) [\(e.phase ?? "completed")\(invocation)] → \(e.statusCode) \(e.ok ? "OK" : "ERR")")
            }
            return 0

        default:
            log.error("unknown connectors subcommand: \(sub)"); return 2
        }
    }

    /// Fan a diff out to N reviewers in parallel and aggregate the verdict — the review
    /// half of /tagteam. Exit 0 = SHIP, 3 = must fix, 2 = bad args or incomplete review.
    /// `designflow tagteam review [--diff <file>] [--reviewers deepseek,codex]`
    private func runTagTeam(cwd: URL) async -> Int32 {
        let sub = args.dropFirst().first(where: { !$0.hasPrefix("-") }) ?? "review"
        guard sub == "review" else { log.error("unknown tagteam subcommand: \(sub)"); return 2 }

        // The diff: an explicit file, or the working-tree diff of the current repo.
        let diff: String
        if let f = value("diff") {
            guard let text = readFile(f) else {
                log.error("could not read the requested diff: \(f)"); return 2
            }
            diff = text
        } else {
            guard let text = await Self.gitDiff(cwd: cwd) else {
                log.error("git diff did not complete; pass --diff <file> or check the repository"); return 2
            }
            diff = text
        }
        guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log.error("no diff to review (pass --diff <file> or run in a repo with changes)"); return 2
        }

        let names = (value("reviewers") ?? "deepseek,codex").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let reviewers = names.compactMap { ReviewerFactory.make($0) }
        guard !reviewers.isEmpty, reviewers.count == names.count else {
            log.error("every requested reviewer must be recognized: \(names.joined(separator: ","))"); return 2
        }
        log.info("tag-team review by: \(reviewers.map(\.name).joined(separator: ", "))")

        let (results, verdict) = await ReviewPanel().run(diff: diff, reviewers: reviewers)
        for r in results {
            print("\n════ \(r.reviewer) — \(r.verdict.rawValue) (blockers \(r.blockers), highs \(r.highs)) ════")
            print(r.text.prefix(8000))
        }
        print("\n──────── PANEL VERDICT ────────")
        if verdict.mustFix {
            print("⛔ MUST FIX — objections from: \(verdict.objectors.joined(separator: ", "))")
            print("Builder: fix EVERY finding above, then re-run the tag team until it's clean.")
            return 3
        }
        guard verdict.verdict == .ship else {
            print("Review incomplete — every requested reviewer must return SHIP.")
            return 2
        }
        print("✅ SHIP")
        return 0
    }

    static func gitDiff(cwd: URL) async -> String? {
        let result = await BoundedProcessRunner.run(
            executable: "/usr/bin/env", arguments: ["git", "--no-pager", "diff", "--no-ext-diff", "HEAD"],
            cwd: cwd.path, environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 30, maximumOutputBytes: 1_048_576)
        return result.succeeded ? result.stdout : nil
    }

    /// Auto-configure + drive a Docker sandbox for a generated project. Dry by default
    /// (prints the plan + Dockerfile + exact hardened docker argv); --build/--run
    /// execute only if a daemon is available.
    private func runSandbox() -> Int32 {
        guard let wsPath = value("workspace") else {
            log.error("sandbox requires --workspace <project dir>"); return 2
        }
        let wsURL = URL(fileURLWithPath: wsPath, isDirectory: true)
        let name = value("name") ?? wsURL.lastPathComponent
        guard let plan = AutoConfigurator().configure(projectDir: wsURL, name: name) else {
            log.error("could not detect a known project kind in \(wsPath) — no safe Dockerfile"); return 1
        }
        print("kind:  \(plan.kind.displayName)")
        print("image: \(plan.imageTag)")
        print("\n── Dockerfile ──\n\(plan.dockerfile)\n")
        print("── run (hardened) ──\ndocker \(DockerCommand.run(plan.spec).joined(separator: " "))\n")

        let control = DockerControl()
        let availability = DockerEnvironment.detect()
        guard availability.isAvailable else {
            if case let .unavailable(r) = availability { print("docker: \(r) — plan above is ready when Docker is up") }
            return 4
        }
        print("docker: available")

        guard flag("build") || flag("run") else {
            print("(dry — pass --build and/or --run to execute)"); return 0
        }
        do {
            try plan.dockerfile.write(to: wsURL.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)
            if flag("build") {
                print("building \(plan.imageTag)…")
                _ = try control.buildImage(tag: plan.imageTag, contextDir: wsURL.path)
            }
            if flag("run") {
                print("running \(plan.spec.name)…")
                let out = try control.run(plan.spec)
                print(out.output.prefix(4000))
            }
            return 0
        } catch {
            log.error("\(error)"); return 1
        }
    }

    /// Parse "k=v,k2=v2" into a map.
    static func parseKV(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { out[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1]) }
        }
        return out
    }

    private func report(_ result: InnerPipeline.Result) -> Int32 {
        print("\n── result ──────────────────────────────")
        print("workspace: \(result.workspace.path)")
        print("artifacts: \(result.artifacts.count)")
        for a in result.artifacts {
            print("  ✓ \(a.stage.displayName) → \(a.relativePath) @ \(a.commitSHA ?? "-")")
        }
        if !result.signoffs.isEmpty {
            print("sealed signoffs: \(result.signoffs.count) (chain \(result.signoffChainIntact ? "intact" : "BROKEN"))")
        }
        if result.completed {
            print("status: COMPLETE")
            return 0
        } else {
            print("status: BLOCKED at \(result.blockedStage?.displayName ?? "?")")
            print("reason: \(result.blockReason ?? "")")
            return 1
        }
    }

    private func printUsage() {
        print("""
        designflow — headless autonomous design→code loop

        COMMANDS
          run [--once] [--dry-run] [--interval <sec>] [--pipeline <key>]
              [--max-cycles <n>] [--max-llm-calls <n>]
              Outer loop: scan → rank → run pipeline → repeat. Bounded by
              --max-cycles and/or a hard --max-llm-calls spend cap (fail-closed).
          pipeline --input "<brief>" [--dry-run] [--pipeline <key>]
              Run the inner assembly line once on a given brief.
          scan [--dry-run]
              Scan + rank signals; print the top 10.
          tagteam review [--diff <file>] [--reviewers deepseek,codex]
              Fan the diff out to N reviewers in parallel; aggregate to SHIP / MUST-FIX.
              Any objecting reviewer ⇒ MUST-FIX (exit 3). The build→review→fix-all loop
              itself is the /tagteam kist command driving the builder agent.
          sandbox --workspace <dir> [--name n] [--build] [--run]
              Auto-configure a hardened Docker sandbox (probe → Dockerfile + run spec).
              Dry by default; --build/--run execute if a daemon is up. Name-scoped,
              resource-capped, no --privileged, ephemeral.
          connectors <list|invoke|history> [--dir <path>]
              Universal connector layer (REST manifests + MCP). Drop a manifest and it
              auto-connects. invoke --connector X --action Y [--input k=v,k=v].
              Every call is sealed into a tamper-evident audit history. Secrets come
              from env vars named in the manifest — never stored in the manifest.
          promote --workspace <dir> [--approval f] [--pins f] [--consumed f]
              DRY consult the deploy gate (internal sealed chain + external Ed25519).
              Prints GO/NO-GO. Writes NOTHING, arms NOTHING. Exit 0=GO, 3=NO-GO.
          help

        PIPELINES  design | design-analysis | analysis-code | full (default)

        CONFIG  OPENAI_API_KEY env or ./config.json ; --dry-run needs no key.
        """)
    }
}

let code = await CLI(args: Array(CommandLine.arguments.dropFirst())).run()
exit(code)
