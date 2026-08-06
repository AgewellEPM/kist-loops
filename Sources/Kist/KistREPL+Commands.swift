import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Outcome of a slash-command dispatch: keep looping, or exit the REPL.
enum SlashOutcome { case handled, exit }

extension KistREPL {
    /// The slash-command dispatch, lifted out of run()'s loop (run() decomposition).
    func handleSlashCommand(name: String, args: String, input: String) async -> SlashOutcome {
                switch name.lowercased() {
                case "exit", "quit", "q": print("bye."); return .exit
                case "help": printHelp(); return .handled
                case "wu-tang", "wutang", "wu", "odb":
                    // 🥷 Easter egg: the gold Wu-Tang "W" rises + the AI takes on ODB — but as a switchable
                    // MODE (default is professional; /persona off or /persona captain turns it back).
                    WuTangEasterEgg.riseAndShow()
                    currentPersona = Persona.apply("wutang", to: &transcript)
                    print(WuTangEasterEgg.activationHype)
                    return .handled
                case "persona", "personality":
                    // Personality LAYER — same shell, different voice. captain (default) · minimal · hacker ·
                    // jarvis · wutang · off. Switching replaces the prior persona cleanly (no permanent stick).
                    let want = args.trimmingCharacters(in: .whitespaces).lowercased()
                    if want.isEmpty {
                        print("persona · \u{001B}[36m\(currentPersona)\u{001B}[0m  ·  options: "
                              + Persona.names.joined(separator: ", ") + ", off")
                        return .handled
                    }
                    currentPersona = Persona.apply(want, to: &transcript)
                    print(currentPersona == "captain"
                          ? "persona · \u{001B}[36mcaptain\u{001B}[0m (professional, default)"
                          : "persona · \u{001B}[36m\(currentPersona)\u{001B}[0m")
                    return .handled
                case "bug-bounty", "bounty", "bb":
                    // The bug-bounty assistant: ingest a program (scope+rules), then run the guided,
                    // verified-only, human-on-submit wizard. Never auto-submits.
                    print(await BountyConsole.handle(args, projectRoot: projectRoot, complete: bountyComplete))
                    return .handled
                case "clear":
                    transcript = []
                    humanTranscript = []
                    lastConfidenceReport = nil
                    print("\u{001B}[37m(context cleared)\u{001B}[0m")
                    return .handled
                case "plan":
                    let want: Bool
                    switch args.lowercased() {
                    case "on", "true", "1": want = true
                    case "off", "false", "0": want = false
                    case "": want = !perm.mode.isPlan             // bare /plan toggles
                    default: print("usage: /plan [on|off]"); return .handled
                    }
                    perm.set(want ? .plan : .normal)             // same source of truth as the shift+tab bar
                    print(want ? "\u{001B}[33m⚑ plan mode ON — read-only; the agent proposes a plan.\u{001B}[0m"
                               : "\u{001B}[32m✓ plan mode OFF — the agent can edit/run again.\u{001B}[0m")
                    return .handled
                case "commands":
                    let n = commands.names
                    print(n.isEmpty ? "\u{001B}[37m(no custom commands — add .kist/commands/<name>.md)\u{001B}[0m"
                                    : "custom: " + n.map { "/\($0)" }.joined(separator: "  "))
                    return .handled
                case "save-chat", "export-chat", "transcript":
                    guard let saveTranscript else { print("\u{001B}[31m/save-chat isn't available here\u{001B}[0m"); return .handled }
                    let path = args.isEmpty ? "kist-conversation.md" : args
                    do {
                        let written = try saveTranscript(transcript, path)
                        print("conversation saved · \(written)")
                    } catch {
                        print("\u{001B}[31m\(error)\u{001B}[0m")
                    }
                    return .handled
                case "providers":
                    print(providerLabels.isEmpty ? "providers: unavailable" : "providers: " + providerLabels.joined(separator: ", "))
                    return .handled
                case "health":
                    guard let providerHealth else { print("provider health: unavailable"); return .handled }
                    print(await providerHealth(false))
                    return .handled
                case "probe-providers", "probe":
                    guard let providerHealth else { print("provider probe: unavailable"); return .handled }
                    print(await providerHealth(true))
                    return .handled
                case "doctor", "providers-doctor":
                    // Live GET /models per keyed provider, diffed vs the catalog: flags dead ids
                    // (e.g. grok-2-latest), invalid defaults, and reasoning models — drift preflight.
                    guard let providerDoctor else { print("provider doctor: unavailable"); return .handled }
                    print(await providerDoctor())
                    return .handled
                case "usage", "cost", "tokens":
                    await printSessionUsage()
                    return .handled
                case "autonomy", "activity", "pulse":
                    // What the AI actually spent its time doing this session — Thinking / Researching /
                    // Coding / Running / Delegating — so you can see WHY a turn took what it took.
                    let spans = await traceRecorder?.all() ?? []
                    print(AutonomyMeter.render(spans: spans, color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
                    return .handled
                case "logs", "details", "proof":
                    print(proofStore?.renderLast() ?? "No proof log yet. Run a turn first.")
                    return .handled
                case "replay":
                    guard let replayRenderer else { print("replay: unavailable in this mode"); return .handled }
                    let id = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    print(replayRenderer(id.isEmpty ? nil : id))
                    return .handled
                case "tools", "capabilities", "contract":
                    // The live tool contract the model sees — exactly what's callable, what's disabled,
                    // and which actions DON'T exist. So you can see why a plan did/didn't reach for a tool.
                    print(loop.renderToolContract())
                    return .handled
                case "summary", "status":
                    let spans = await traceRecorder?.all() ?? []
                    let trajectory = recorder?.snapshot() ?? []
                    print(Self.renderSimpleSummary(projectRoot: projectRoot, spans: spans,
                                                   trajectory: trajectory, sessionStartedAt: sessionStart))
                    return .handled
                case "confidence", "why":
                    // Explain the exact report the panel showed for the last completed turn. Do not
                    // consult the recorder here: it was intentionally reset before slash dispatch.
                    if let report = lastConfidenceReport {
                        print(report.renderBreakdown(color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
                    } else {
                        print("No confidence to explain yet — that turn used no tools (a plain answer). Run a turn that reads/edits/searches first.")
                    }
                    return .handled
                case "version", "ver", "changelog", "whatsnew", "whats-new":
                    // What shipped in this version + when it was built (real commit/branch/date from
                    // the deployment manifest) + the changelog — so `/version` reads like a release note.
                    print(KistChangelog.render(provenance: KistBuildInfo.provenance(),
                                               color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
                    return .handled
                case "failures", "failure", "failure-analysis":
                    print(CaptainFailureAnalysis.handleCommand(args, projectRoot: projectRoot))
                    return .handled
                case "reflect", "reflection", "learn":
                    let store = OrganizationalLearningStore(projectRoot: projectRoot)
                    let action = args.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if action == "now" || action == "capture" {
                        let spans = await traceRecorder?.all() ?? []
                        let trajectory = recorder?.snapshot() ?? []
                        let capsule = store.makeManualReflection(plan: PlanStore(projectRoot: projectRoot).load(),
                                                                  spans: spans,
                                                                  trajectory: trajectory)
                        print(OrganizationalLearningStore.render(capsule))
                    } else if name.lowercased() == "learn" && !args.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        await runDomainLearningCommand("learn " + args)
                    } else {
                        print(store.renderLatestReflection())
                    }
                    return .handled
                case "knowledge", "knowledge-debt", "debt":
                    print(Self.handleKnowledgeCommand(args, projectRoot: projectRoot))
                    return .handled
                case "teach", "rules", "organizational-rules":
                    print(Self.handleTeachCommand(args, projectRoot: projectRoot))
                    return .handled
                case "learning", "model-learning", "captain-learning":
                    print(Self.handleCaptainLearningCommand(args, projectRoot: projectRoot))
                    return .handled
                case "industry", "intelligence", "strategic-intelligence", "strategic-intel":
                    print(Self.handleStrategicIntelligenceCommand(args, projectRoot: projectRoot))
                    return .handled
                case "self-heal", "heal", "fix-self":
                    await runSelfHealCommand(args)
                    return .handled
                case "legal", "legal-research", "law", "case-research":
                    let clean = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else {
                        print("usage: /legal-research <jurisdiction + legal issue + optional document path>")
                        return .handled
                    }
                    await runLegalResearchCommand(clean, forceResearch: true)
                    return .handled
                case "domain", "domain-learning", "research-first", "sme":
                    await runDomainLearningCommand(args)
                    return .handled
                case "model-run", "run-model-acquire", "model-acquisition-run":
                    let report = Self.handleLocalModelAcquisitionRunCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    let marker = report.markerPath.map { " · marker: \($0)" } ?? ""
                    let verdict = report.outcome?.succeeded == true ? "passed" : "blocked"
                    print("\u{001B}[2m\(persisted)\(marker) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                    return .handled
                case "model-acquire", "acquire-model":
                    let report = Self.handleLocalModelAcquisitionCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    let verdict = report.decision.accepted ? "verified" : "rejected"
                    print("\u{001B}[2m\(persisted) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                    return .handled
                case "local-model", "local-models", "model-scout", "hf", "huggingface":
                    if Self.isLocalModelAcquisitionRunIntent(command: name, args: args) {
                        let report = Self.handleLocalModelAcquisitionRunCommand(args, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let marker = report.markerPath.map { " · marker: \($0)" } ?? ""
                        let verdict = report.outcome?.succeeded == true ? "passed" : "blocked"
                        print("\u{001B}[2m\(persisted)\(marker) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        return .handled
                    }
                    if Self.isLocalModelAcquisitionIntent(command: name, args: args) {
                        let report = Self.handleLocalModelAcquisitionCommand(args, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision.accepted ? "verified" : "rejected"
                        print("\u{001B}[2m\(persisted) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        return .handled
                    }
                    if Self.isLiveModelMetadataGateIntent(command: name, args: args) {
                        let report = await Self.handleLiveModelMetadataGateCommand(args, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision?.accepted == true ? "accepted" : "rejected"
                        let manifest = report.acquisitionManifestPath.map { " · manifest: \($0)" } ?? ""
                        print("\u{001B}[2m\(persisted)\(manifest) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        return .handled
                    }
                    let report = Self.handleLocalModelScoutCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    print("\u{001B}[2m\(persisted) · candidates: \(report.candidates.count) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                    return .handled
                case "self-test", "selftest":
                    if let usage = Self.selfTestUsageIfNeeded(args) {
                        print(usage)
                        return .handled
                    }
                    let report = Self.handleSelfTestCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    print("\u{001B}[2m\(persisted) · checks: \(report.passed) pass / \(report.warnings) warn / \(report.failures) fail · seeded tasks: \(report.seededTasks)\u{001B}[0m")
                    return .handled
                case "immune", "immune-system", "immune-check":
                    if let usage = Self.immuneUsageIfNeeded(args) {
                        print(usage)
                        return .handled
                    }
                    let report = Self.handleImmuneCommand(args,
                                                          projectRoot: projectRoot,
                                                          trajectory: recorder?.snapshot() ?? [])
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    let mission = report.selfHealPath.map { " · self-heal: \($0)" } ?? ""
                    let simulation = report.simulationPath.map { " · simulation: \($0)" } ?? ""
                    print("\u{001B}[2m\(persisted) · status: \(report.status.rawValue) · self-test: \(report.selfTestPath)\(mission)\(simulation) · seeded tasks: \(report.seededTasks)\u{001B}[0m")
                    return .handled
                case "simulate", "simulation", "sim", "sandbox", "risk":
                    let report = Self.handleSimulationCommand(args,
                                                              projectRoot: projectRoot,
                                                              trajectory: recorder?.snapshot() ?? [])
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    print("\u{001B}[2m\(persisted) · recommended: \(report.recommendedStrategy) · success: \(report.estimatedSuccess)% · risk: \(report.failureRisk)% · seeded simulation tasks: \(report.seededTasks)\u{001B}[0m")
                    return .handled
                case "symbolic", "workflow", "workflows", "compile-workflow":
                    print(Self.handleSymbolicWorkflowCommand(args,
                                                             projectRoot: projectRoot,
                                                             trajectory: recorder?.snapshot() ?? []))
                    return .handled
                case "retrieve", "recall":
                    print(Self.handleRetrieveCommand(args, projectRoot: projectRoot))
                    return .handled
                case "captain", "strategy", "organize":
                    let objective = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !objective.isEmpty else {
                        print("usage: /captain <objective>")
                        return .handled
                    }
                    if Self.isSelfHealIntent(objective) {
                        await runSelfHealCommand(objective)
                        return .handled
                    }
                    if Self.isSimulationIntent(objective) {
                        let report = Self.handleSimulationCommand(objective,
                                                                  projectRoot: projectRoot,
                                                                  trajectory: recorder?.snapshot() ?? [])
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        print("\u{001B}[2m\(persisted) · recommended: \(report.recommendedStrategy) · success: \(report.estimatedSuccess)% · risk: \(report.failureRisk)%\u{001B}[0m")
                        return .handled
                    }
                    if Self.isDomainLearningIntent(objective) {
                        await runDomainLearningCommand(objective)
                        return .handled
                    }
                    print(Self.handleCaptainStrategyCommand(objective, projectRoot: projectRoot))
                    return .handled
                case "evolve":
                    let store = OrganizationalLearningStore(projectRoot: projectRoot)
                    let report = store.runBoardMeeting(plan: PlanStore(projectRoot: projectRoot).load(),
                                                       trajectory: recorder?.snapshot() ?? [])
                    print(report.text)
                    print("\u{001B}[2mwritten: \(report.path) · seeded research tasks: \(report.seededResearchTasks) · created specialists: \(report.createdSpecialists) · promoted rules: \(report.promotedRules)\u{001B}[0m")
                    return .handled
                case "protocols", "mcp-status", "a2a":
                    print(protocolStatus?() ?? "protocol status: unavailable")
                    return .handled
                case "bench":
                    guard let runBench else { print("\u{001B}[31m/bench isn't available here\u{001B}[0m"); return .handled }
                    guard !args.isEmpty else { print("usage: /bench <task>"); return .handled }
                    await runBench(args)
                    return .handled
                case "eval":
                    // No args or "suite" → the GOLDEN regression suite (replay fixed set, score, compare to
                    // baseline, flag a drop). `/eval <task>` → ad-hoc assertions for one task.
                    let evalArg = args.trimmingCharacters(in: .whitespaces).lowercased()
                    if evalArg.isEmpty || evalArg == "suite" || evalArg == "regression" || evalArg == "golden" {
                        guard let runEvalSuite else { print("\u{001B}[31m/eval isn't available here\u{001B}[0m"); return .handled }
                        await runEvalSuite()
                        return .handled
                    }
                    guard let runEval else { print("\u{001B}[31m/eval isn't available here\u{001B}[0m"); return .handled }
                    await runEval(args)
                    return .handled
                case "eval-suite", "evalsuite", "regression-suite":
                    guard let runEvalSuite else { print("\u{001B}[31m/eval-suite isn't available here\u{001B}[0m"); return .handled }
                    await runEvalSuite()
                    return .handled
                case "fleet-status", "cockpit", "fleetstatus":
                    // Terminal Captain cockpit: the latest fleet's per-agent status + honest merge-fate.
                    if let pic = FleetCockpitLoader.latestPicture() { print(pic.render()) }
                    else { print("\u{001B}[37mno fleet runs found — run /fleet <goal> first\u{001B}[0m") }
                    return .handled
                case "tasks", "task", "plan-tasks", "todo", "goals", "goal":
                    // The native runbook: the shared task list at <project>/.kist/plan.json. Both you and
                    // the agent (via the `tasks` tool) read/update it. `/tasks` shows it; subcommands edit.
                    print(Self.handleTasks(args, projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    return .handled
                case "cortex", "memory", "remember":
                    // The Cortex: what kist knows about YOU (preferences/projects/journal, all .md you can see).
                    // `/cortex` shows it · `/cortex files` lists the .md · `/cortex show <file>` ·
                    // `/cortex remember <fact>` teaches it · `/cortex project <name> <fact>`.
                    print(Self.handleCortex(name == "remember" ? "remember " + args : args, cortex: cortex))
                    return .handled
                case "agents", "agent", "specialists", "specialist":
                    // The specialist registry at <project>/.kist/agents/. `/agents` lists; `/agents show
                    // <name>` details; `/agents new <role description>` FORGES one (AgentForge, P3).
                    let aTrim = args.trimmingCharacters(in: .whitespaces)
                    let aLower = aTrim.lowercased()
                    if aLower == "new" || aLower == "forge" || aLower == "create"
                        || aLower.hasPrefix("new ") || aLower.hasPrefix("forge ") || aLower.hasPrefix("create ") {
                        let desc = aTrim.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
                        guard !desc.isEmpty else { print("usage: /agent new <role description>"); return .handled }
                        guard let forge else { print("\u{001B}[31mforging isn't available here\u{001B}[0m"); return .handled }
                        await forge(desc, roleSelection.bindings)
                    } else if aLower == "run" || aLower == "use" {
                        print("usage: /agents run <name> <task>")
                    } else if aLower.hasPrefix("run ") || aLower.hasPrefix("use ") {
                        // /agents run <name> <task> — HARD-spawn the named specialist (own context/tools/model).
                        let rest = aTrim.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
                        let name = String(rest.prefix(while: { $0 != " " }))
                        let task = String(rest.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !task.isEmpty else { print("usage: /agents run <name> <task>"); return .handled }
                        guard let runSpecialist else { print("\u{001B}[31mspecialist run isn't available here\u{001B}[0m"); return .handled }
                        // Tint the banner with the specialist's `color` (Claude parity) — nil ⇒ plain dim.
                        let agentColor = SpecialistRegistry(projectRoot: projectRoot).named(name).flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                        let tinted = agentColor.map { "\u{001B}[\($0)m\(name)\u{001B}[0m" } ?? name
                        print("\u{001B}[2m⇢ delegating to \(tinted)…\u{001B}[0m")
                        // Pass the parent's EFFECTIVE floor (honors the unconfirmed-bypass fail-safe — an
                        // unconfirmed bypass reads as normal, so it can't hand the child an empty floor).
                        if await runSpecialist(name, task, perm.effectiveApproval(), perm.effectivePlan) != nil {
                            // Output already streamed live through the spawner's
                            // TerminalEventSink; a concise marker avoids reprinting it.
                            print("\u{001B}[36;1m⇠ \(name)\u{001B}[0m")
                        } else {
                            print("\u{001B}[31mno specialist named '\(name)'\u{001B}[0m — /agents to list")
                        }
                    } else {
                        print(Self.handleAgents(args, projectRoot: projectRoot))
                    }
                    return .handled
                case "action":
                    guard !args.isEmpty else {
                        print(Self.handleTasks("", projectRoot: projectRoot,
                                               sessionStartedAt: sessionStart)); return .handled
                    }
                    print(Self.handleTasks("add ACTION: \(args)", projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    return .handled
                case "test":
                    guard !args.isEmpty else {
                        print(Self.handleTasks("", projectRoot: projectRoot,
                                               sessionStartedAt: sessionStart)); return .handled
                    }
                    print(Self.handleTasks("add TEST: \(args)", projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    return .handled
                case "review":
                    guard !args.isEmpty else {
                        print(Self.handleTasks("", projectRoot: projectRoot,
                                               sessionStartedAt: sessionStart)); return .handled
                    }
                    print(Self.handleTasks("add REVIEW: \(args)", projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    return .handled
                case "paste", "v":
                    // Pull media off the clipboard (screenshot/copy, or copied media/PDF file) and ask about it.
                    if let att = PasteboardReader.imageAttachment() {
                        // Resolve vision against the RUNNING model (activeBinding), mirroring the media path.
                        let provider = visionProviderId ?? activeBinding.providerId
                        if !clipboardVisionApprovedForSession {
                            FileHandle.standardOutput.write(Data(Self.pasteConfirmationPrompt(attachment: att, provider: provider).utf8))
                            let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            if Self.isAlways(answer) { clipboardVisionApprovedForSession = true }
                            guard Self.isAffirmative(answer) || clipboardVisionApprovedForSession else {
                                print("\u{001B}[37m↳ paste cancelled — clipboard media was not sent\u{001B}[0m")
                                return .handled
                            }
                        }
                        print("\u{001B}[37m↳ pasted \(att.kind.rawValue) from clipboard\u{001B}[0m")
                        let pastePrompt = args.trimmingCharacters(in: .whitespacesAndNewlines)
                        proofStore?.startTurn(goal: pastePrompt.isEmpty ? "pasted media" : pastePrompt)
                        await runMediaTurn([att], prompt: pastePrompt)
                        await printTurnSummary()
                    } else {
                        print("\u{001B}[31mclipboard has no image/video/audio/PDF — copy one or drag a file path into the prompt\u{001B}[0m")
                    }
                    return .handled
                case "media", "preview", "imgcat":
                    let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        print(TerminalMediaRenderer.status())
                    } else {
                        print(TerminalMediaRenderer.previewFile(trimmed, projectRoot: projectRoot))
                    }
                    return .handled
                case "watch", "play":
                    // Stream a video INSIDE the terminal via mpv (local path or http(s) URL). Kitty/Ghostty
                    // get the native graphics protocol; every other terminal gets ANSI cells (--vo=tct),
                    // so it plays in Terminal.app too. Honest fail: missing mpv/yt-dlp → exact brew command.
                    let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { print("usage: /watch <video-path-or-URL>"); return .handled }
                    let target: String
                    if TerminalVideoPlayer.isURL(raw) {
                        target = raw
                    } else {
                        let token = MediaResolver.tokenize(raw).first ?? raw
                        guard let (_, _, resolved) = MediaResolver.classify(token, projectRoot: projectRoot) else {
                            print("\u{001B}[31m/watch: '\(token)' is not a local video file or http(s) URL\u{001B}[0m"); return .handled
                        }
                        target = resolved
                    }
                    print("\u{001B}[37m↳ streaming in-terminal (q to quit)…\u{001B}[0m")
                    if let msg = TerminalVideoPlayer.play(target: target, columns: TerminalMediaRenderer.terminalColumns()) {
                        print("\u{001B}[33m\(msg)\u{001B}[0m")
                    }
                    return .handled
                case "auto", "autopilot":
                    // Flip hands-free autopilot on/off mid-session — auto-approve every tool (incl. shell)
                    // so a build rips through with no prompts. /auto off restores approval prompts.
                    guard let setAutopilot else { print("autopilot unavailable here"); return .handled }
                    let want: Bool
                    switch args.lowercased().trimmingCharacters(in: .whitespaces) {
                    case "on", "true", "1", "": want = true
                    case "off", "false", "0": want = false
                    default: print("usage: /auto [on|off]"); return .handled
                    }
                    await setAutopilot(want)
                    print(want
                        ? "\u{001B}[33m⚡ autopilot ON\u{001B}[0m — every tool auto-approved (incl. shell). /auto off to restore prompts."
                        : "autopilot off — sensitive tools will ask again.")
                    return .handled
                case "copilot", "co-pilot", "cp":
                    // Auto second-AI review after every coding turn. `/copilot on|off`, `/copilot lead
                    // <model>` (who codes), `/copilot co <model>` (who reviews). `/copilot on` explicitly
                    // enables bounded original-author repair; `/copilot off` revokes all automatic review.
                    switch Copilot.parseCommand(args) {
                    case .status:
                        print(copilot.statusLine(render: { Self.render($0) }))
                        if copilot.enabled && modelComplete == nil {
                            print("\u{001B}[33m↳ note: review completions aren't wired in this mode — it won't run\u{001B}[0m")
                        }
                    case .on:
                        copilot.enabled = true
                        copilot.automaticBuildReview = true
                        copilot.autoSecondOpinion = true
                        copilot.autoFix = true
                        print("\u{001B}[35m⎇ copilot ON\u{001B}[0m — review→repair enabled (original author, max 3); build/tests remain verification. " + copilot.statusLine(render: { Self.render($0) }))
                    case .off:
                        copilot.enabled = false
                        copilot.automaticBuildReview = false
                        copilot.autoFix = false
                        copilot.autoSecondOpinion = false
                        copilot.ultra = false
                        print("copilot off — no automatic review, second opinion, or fix.")
                    case .setLead(let spec):
                        guard let b = Self.resolveModelSpec(spec, currentProvider: roleSelection.fallback.providerId,
                                                            knownProviders: providerAliases, providerModels: providerModels) else {
                            print("\u{001B}[31munknown model '\(spec)'\u{001B}[0m — try /model for the catalog"); return .handled
                        }
                        copilot.lead = b
                        // The lead writes the code → make it the session default so the coding turn uses it.
                        if roleSelection.setDefault(b, knownProviders: providerAliases) == nil {
                            autoRouting = false
                            activeBinding = roleSelection.fallback   // stay in lockstep for a later /model auto (Codex HIGH)
                            if let loopFactory { loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                        }
                        print("copilot · lead: \(Self.render(b))")
                    case .setCo(let spec):
                        guard let b = Self.resolveModelSpec(spec, currentProvider: roleSelection.fallback.providerId,
                                                            knownProviders: providerAliases, providerModels: providerModels) else {
                            print("\u{001B}[31munknown model '\(spec)'\u{001B}[0m — try /model for the catalog"); return .handled
                        }
                        copilot.co = b
                        print("copilot · co-reviewer: \(Self.render(b))")
                    case .invalid:
                        print("usage: /copilot [on|off] · /copilot lead <model> · /copilot co <model>")
                    }
                    return .handled
                case "chain", "pipeline":
                    // Sequential task pipeline: run each step as its own turn, in order, in the same
                    // conversation. `/chain "scaffold" | "add tests" | "wire it up"`. Stops on the first
                    // failed step (later steps usually depend on earlier ones).
                    let steps = ChainParser.parse(args)
                    guard steps.count >= 1 else { print("usage: /chain \"task 1\" | \"task 2\" | \"task 3\""); return .handled }
                    print("\u{001B}[36m⛓ chain · \(steps.count) step(s)\u{001B}[0m")
                    for (i, step) in steps.enumerated() {
                        print("\u{001B}[36m⛓ step \(i + 1)/\(steps.count): \(step)\u{001B}[0m")
                        proofStore?.startTurn(goal: step)
                        resetTurnEvidence()
                        armTurnLoop()
                        let mode: PromptCompiler.Mode = perm.mode.isPlan ? .plan : .inline
                        let intent = PromptCompiler.inferIntent(step, mode: mode)
                        proofStore?.record(.init(kind: .routeSelected, tool: nil, success: nil,
                                                 text: "intent=\(intent.rawValue) outcome=\(PromptCompiler.expectedOutcome(intent: intent, mode: mode).rawValue) execution=chain-inline"))
                        let compiled = briefCompiler?(step, roleSelection.bindings, mode,
                                                      humanTranscript, intent) ?? step
                        let enriched = attachCaptainContext(to: compiled, objective: step)
                        let reviewBaseline = reviewBaselineIfArmed(intent: intent)
                        let oc = await runTurnInterruptible(loop: loop, userInput: enriched,
                                                            rawRequest: step, resolvedIntent: intent)
                        rememberHumanTurn(user: step, assistantSummary: oc.summary)
                        await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                        await runCopilotReview(task: step, baselineDiff: reviewBaseline,
                                               turnIntent: intent, turnSucceeded: oc.success)
                        let completedTurn = recordVerificationAndFinal(outcome: oc, intent: intent)
                        selfMonitor(goal: step, intent: intent, success: completedTurn)
                        await printTurnUsage()
                        recordSubmittedTurnLearning(outcomeSummary: oc.summary, success: completedTurn)
                        if !completedTurn {
                            print("\u{001B}[31m⛓ step \(i + 1) did not succeed — stopping the chain. Remaining: \(steps.count - i - 1)\u{001B}[0m")
                            break
                        }
                    }
                    print("\u{001B}[36m⛓ chain complete\u{001B}[0m")
                    return .handled
                case "code", "c":
                    // CODING MODE — one keystroke: pin the strong coder (DeepSeek V4 Pro), turn per-request
                    // routing OFF so the conversation stays on the coder (never drifts to a chat/research
                    // model), and set the .coder role too so spawned builders use it. Research stays opt-in
                    // (/research · /council · /plan) — this drops you straight into the build loop.
                    // `/code <prov[:model]>` pins a different coder (e.g. /code claude-cli for the Max sub).
                    let codeSpec = args.trimmingCharacters(in: .whitespaces)
                    // Bare `/code` default is configuration, not a baked-in model: KIST_CODER_DEFAULT=<prov[:model]>
                    // overrides the shipped DeepSeek pin without touching source.
                    let envDefault = ProcessInfo.processInfo.environment["KIST_CODER_DEFAULT"]?
                        .trimmingCharacters(in: .whitespaces)
                    let spec = !codeSpec.isEmpty ? codeSpec
                        : (envDefault?.isEmpty == false ? envDefault! : "deepseek:deepseek-v4-pro")
                    let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
                    let coderBinding = ProviderBinding(providerId: parts[0], model: parts.count > 1 ? parts[1] : nil)
                    if let error = roleSelection.setDefault(coderBinding, knownProviders: providerAliases) {
                        print("\u{001B}[31m\(error)\u{001B}[0m"); return .handled
                    }
                    _ = roleSelection.assign(.coder, to: coderBinding, knownProviders: providerAliases)
                    autoRouting = false
                    activeBinding = roleSelection.fallback
                    if let loopFactory { loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                    print("\u{001B}[36m⌨ coding mode\u{001B}[0m · \(Self.render(roleSelection.fallback)) · research OFF (opt-in via /research) · just describe what to build")
                    return .handled
                case "model", "m":
                    // Switch the SESSION DEFAULT model — the model the conversation itself talks to (and
                    // every role that isn't pinned with /roles). Bare /model lists the catalog.
                    let modelArg = args.trimmingCharacters(in: .whitespaces)
                    if modelArg.isEmpty {
                        // Interactive arrow-key picker (Claude-Code style) on a TTY; falls back to the static
                        // list off a TTY (pipes/tests). Picking pins the model, same as `/model <name>`.
                        let picker = ModelPicker.entries(
                            providerModels: providerModels,
                            providers: providerLabels.map { $0.split(separator: " ").first.map(String.init) ?? $0 },
                            hasKey: { providerHasKey?($0) ?? true })
                        if let chosen = ModelPicker.run(entries: picker, current: roleSelection.fallback) {
                            // Picked a RED (no-key) model? Offer to add its key right here — it turns green
                            // and works THIS session (the key store re-reads live). Blank skips.
                            if !(providerHasKey?(chosen.providerId) ?? true), let saveProviderKey {
                                FileHandle.standardOutput.write(Data("\u{001B}[31m\(chosen.providerId) has no API key.\u{001B}[0m paste one to enable it now (hidden, blank to skip): ".utf8))
                                let key = Self.readHiddenLine()
                                if !key.isEmpty {
                                    print(saveProviderKey(chosen.providerId, key)
                                        ? "\u{001B}[32m✓ key saved — \(chosen.providerId) is ready now.\u{001B}[0m"
                                        : "\u{001B}[31mcouldn't save the key — check permissions or try /model import.\u{001B}[0m")
                                }
                            }
                            let binding = ProviderBinding(providerId: chosen.providerId, model: chosen.model)
                            if let error = roleSelection.setDefault(binding, knownProviders: providerAliases) {
                                print("\u{001B}[31m\(error)\u{001B}[0m"); return .handled
                            }
                            autoRouting = false
                            activeBinding = roleSelection.fallback
                            if let loopFactory { loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                            router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                            print("model · \(Self.render(roleSelection.fallback)) · pinned · \(roleSelection.summary)")
                            return .handled
                        }
                        // Cancelled or not a TTY → show the catalog as before.
                        if autoRouting { print("model · \u{001B}[35mauto-routing\u{001B}[0m (kist picks per request) · /model <name> to pin") }
                        printModels(current: roleSelection.fallback)
                        return .handled
                    }
                    // /model auto → re-enable per-request routing. /model add → onboard a new model.
                    if modelArg.lowercased() == "auto" {
                        autoRouting = true
                        print("model · \u{001B}[35mauto-routing\u{001B}[0m on — kist picks the best model per request")
                        return .handled
                    }
                    if Self.isLocalModelAcquisitionRunIntent(command: "model", args: modelArg) {
                        let report = Self.handleLocalModelAcquisitionRunCommand(modelArg, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let marker = report.markerPath.map { " · marker: \($0)" } ?? ""
                        let verdict = report.outcome?.succeeded == true ? "passed" : "blocked"
                        print("\u{001B}[2m\(persisted)\(marker) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        return .handled
                    }
                    if Self.isLocalModelAcquisitionIntent(command: "model", args: modelArg) {
                        let report = Self.handleLocalModelAcquisitionCommand(modelArg, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision.accepted ? "verified" : "rejected"
                        print("\u{001B}[2m\(persisted) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        return .handled
                    }
                    if Self.isLiveModelMetadataGateIntent(command: "model", args: modelArg) {
                        let report = await Self.handleLiveModelMetadataGateCommand(modelArg, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision?.accepted == true ? "accepted" : "rejected"
                        let manifest = report.acquisitionManifestPath.map { " · manifest: \($0)" } ?? ""
                        print("\u{001B}[2m\(persisted)\(manifest) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        return .handled
                    }
                    if modelArg.lowercased() == "scout" || modelArg.lowercased().hasPrefix("scout ") {
                        let objective = modelArg.count > 5 ? String(modelArg.dropFirst(5)).trimmingCharacters(in: .whitespaces) : ""
                        let report = Self.handleLocalModelScoutCommand(objective, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        print("\u{001B}[2m\(persisted) · candidates: \(report.candidates.count) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        return .handled
                    }
                    if modelArg.lowercased() == "add" {
                        if let addModelFlow { await addModelFlow() } else { print("model add is unavailable here") }
                        return .handled
                    }
                    // /model import <url> → discover models at the URL, add a key, onboard, persist.
                    if modelArg.lowercased() == "import" || modelArg.lowercased().hasPrefix("import ") {
                        guard let importModelFlow else { print("model import is unavailable here"); return .handled }
                        let url = modelArg.count > 6 ? String(modelArg.dropFirst(6)).trimmingCharacters(in: .whitespaces) : ""
                        if let imported = await importModelFlow(url.isEmpty ? nil : url) {
                            print("model · imported '\(imported)' · restart kist to select it (it'll show green in /model)")
                        }
                        return .handled
                    }
                    guard let binding = Self.resolveModelSpec(modelArg, currentProvider: roleSelection.fallback.providerId,
                                                              knownProviders: providerAliases, providerModels: providerModels) else {
                        print("\u{001B}[31munknown model/provider '\(modelArg)'\u{001B}[0m — try bare /model for the catalog, /model auto, or /providers")
                        return .handled
                    }
                    if let error = roleSelection.setDefault(binding, knownProviders: providerAliases) {
                        print("\u{001B}[31m\(error)\u{001B}[0m")
                        return .handled
                    }
                    // Pinning a model turns OFF auto-routing — explicit user choice wins until /model auto.
                    autoRouting = false
                    activeBinding = roleSelection.fallback
                    // Rebuild the conversational loop on the new default; the unbound planner follows it,
                    // so rebuild the auto-router too.
                    if let loopFactory { loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                    print("model · \(Self.render(roleSelection.fallback)) · pinned · \(roleSelection.summary)")
                    return .handled
                case "reasoning":
                    // DISPLAY-only toggle: whether the reasoning stream is shown on screen.
                    let want: Bool
                    switch args.lowercased() {
                    case "on", "true", "1", "show": want = true
                    case "off", "false", "0", "hide": want = false
                    case "": want = !showReasoning
                    default: print("usage: /reasoning [on|off]"); return .handled
                    }
                    showReasoning = want
                    // INVARIANT: a settings-only change must PRESERVE the running model — rebuild from
                    // activeBinding, not the startup default (else an auto-routed model silently resets).
                    if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    print(want ? "reasoning · on" : "reasoning · off")
                    return .handled
                case "think", "thinking":
                    // EXTENDED THINKING: actually let the model reason before each action (vs the tight
                    // no-think loop). Turning it on also shows the reasoning so you can watch it; it's
                    // persisted to the replay either way.
                    let want: Bool
                    switch args.lowercased() {
                    case "on", "true", "1": want = true
                    case "off", "false", "0": want = false
                    case "": want = !extendedThinking
                    default: print("usage: /think [on|off]"); return .handled
                    }
                    extendedThinking = want
                    if want { showReasoning = true }
                    // INVARIANT: settings-only change ⇒ preserve the running model (rebuild from activeBinding).
                    if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    print(want ? "extended thinking · on (reasoning shown + replayed)" : "extended thinking · off")
                    return .handled
                case "config", "settings":
                    // Settings panel over .kist/settings.json (logic in KistREPL+SettingsCommands).
                    let outcome = Self.handleConfigCommand(args, projectRoot: projectRoot)
                    print(outcome.output)
                    if let r = outcome.reasoning {            // hot-apply the one live-changeable key
                        showReasoning = r
                        // INVARIANT: settings-only change ⇒ preserve the running model (rebuild from activeBinding).
                        if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    }
                    return .handled
                case "context", "ctx":
                    print(Self.handleContextCommand(transcript: transcript, projectRoot: projectRoot))
                    return .handled
                case "theme":
                    print(Self.handleThemeCommand(args, projectRoot: projectRoot))
                    return .handled
                case "skills":
                    print(Self.handleSkillsCommand(projectRoot: projectRoot))
                    return .handled
                case "mcp":
                    print(Self.handleMcpCommand(projectRoot: projectRoot))
                    return .handled
                case "hooks":
                    print(Self.handleHooksCommand(projectRoot: projectRoot))
                    return .handled
                case "permissions", "perms":
                    print(Self.handlePermissionsCommand(mode: perm.mode, sensitive: sensitiveTools,
                                                        editTools: editTools, projectRoot: projectRoot))
                    return .handled
                case "compact":
                    // Summarize the older transcript, keep recent turns verbatim. `transcript` IS the
                    // model-facing history (passed inout to l.turn), so this genuinely frees the window.
                    let keepRecent = 6
                    guard TranscriptCompactor.worthCompacting(transcript, keepRecent: keepRecent) else {
                        print("\u{001B}[2mnothing to compact yet — the conversation is still short\u{001B}[0m"); return .handled
                    }
                    guard let compactComplete else {
                        print("\u{001B}[2mcompaction unavailable (no model seam)\u{001B}[0m"); return .handled
                    }
                    let (toSummarize, toKeep) = TranscriptCompactor.plan(transcript, keepRecent: keepRecent)
                    print("\u{001B}[2m🗜 summarizing \(toSummarize.count) earlier message(s)…\u{001B}[0m")
                    let focus = args.trimmingCharacters(in: .whitespaces).isEmpty ? nil : args
                    // Summarize on the model the loop is ACTUALLY running (activeBinding). Since every rebuild
                    // now keeps activeBinding in lockstep (single-source-of-truth invariant), this is always
                    // the live model — the old "activeBinding goes stale" workaround (use fallback) is obsolete.
                    let compactBinding = activeBinding
                    let summary = await compactComplete(
                        compactBinding.providerId, compactBinding.model,
                        TranscriptCompactor.summarizationSystemPrompt,
                        TranscriptCompactor.summarizationPrompt(toSummarize, focus: focus))
                    guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        print("\u{001B}[31mcompaction failed — transcript unchanged\u{001B}[0m"); return .handled
                    }
                    let freed = TranscriptCompactor.tokensFreed(summarize: toSummarize, summary: summary)
                    transcript = TranscriptCompactor.fold(summary: summary, keep: toKeep)
                    print("\u{001B}[32m🗜 compacted\u{001B}[0m · ~\(ContextReport.fmt(freed)) tokens freed · kept last \(toKeep.count) message(s)")
                    return .handled
                case "roles", "role", "team-roles":
                    guard let command = Self.parseRoleCommand(args) else {
                        print("usage: /roles [planner|worker|researcher|coder|builder|critic <provider[:model]>]  or  /roles save|load|delete <name>")
                        return .handled
                    }
                    switch command {
                    case .show:
                        print("roles · \(roleSelection.summary)")
                    case .reset:
                        roleSelection.reset()
                        // PRESERVE-RUNNING: reset() clears only role OVERRIDES, NOT the default model
                        // (RoleSelection.reset does not touch fallback — Codex verified). So keep the running
                        // model; rebuild from activeBinding to pick up the reset role bindings.
                        if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                        router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                        print("roles · reset · \(roleSelection.summary)")
                    case .assign(let role, let binding):
                        if let error = roleSelection.assign(role, to: binding, knownProviders: providerAliases) {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                            return .handled
                        }
                        // PRESERVE-RUNNING: assigning a (non-default) role must not switch the interactive
                        // model — rebuild from activeBinding to pick up the new role bindings, keep the model.
                        if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                        if role == .planner {
                            router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                        }
                        let assigned = roleSelection.bindings.binding(for: role)
                        print("roles · \(role.rawValue)=\(Self.render(assigned)) · \(roleSelection.summary)")
                    case .save(let name):
                        guard let roleProfiles else { print("\u{001B}[31mrole profiles unavailable\u{001B}[0m"); return .handled }
                        do {
                            try roleProfiles.save(RoleProfileStore.Profile(bindings: roleSelection.bindings), named: name)
                            print("roles · saved \(name) · \(roleSelection.summary)")
                        } catch {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                        }
                    case .load(let name):
                        guard let roleProfiles else { print("\u{001B}[31mrole profiles unavailable\u{001B}[0m"); return .handled }
                        do {
                            var next = roleSelection
                            let profile = try roleProfiles.profile(named: name)
                            if let error = next.apply(profile, knownProviders: providerAliases) {
                                print("\u{001B}[31m\(error)\u{001B}[0m")
                                return .handled
                            }
                            roleSelection = next
                            // PRESERVE-RUNNING: a role profile stores only planner/worker/coder/critic — NO
                            // default model (RoleProfileStore.Profile; apply() assigns roles only — Codex
                            // verified). So loading a profile does NOT change the default; keep the running
                            // model and rebuild from activeBinding to pick up the new role bindings.
                            if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                            router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                            print("roles · loaded \(name) · \(roleSelection.summary)")
                        } catch {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                        }
                    case .delete(let name):
                        guard let roleProfiles else { print("\u{001B}[31mrole profiles unavailable\u{001B}[0m"); return .handled }
                        do {
                            let deleted = try roleProfiles.delete(named: name)
                            print(deleted ? "roles · deleted \(name)" : "roles · profile \(name) did not exist")
                        } catch {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                        }
                    case .profiles:
                        guard let roleProfiles else { print("role profiles: unavailable"); return .handled }
                        do {
                            let names = try roleProfiles.names()
                            print(names.isEmpty ? "role profiles: none" : "role profiles: " + names.joined(separator: ", "))
                        } catch {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                        }
                    }
                    return .handled
                case "fleet", "team", "swarm":
                    guard let fleet else { print("\u{001B}[31m/fleet isn't available here\u{001B}[0m"); return .handled }
                    guard let invocation = Self.parseFleetArgs(args, defaultAgents: defaultAgents) else {
                        print("usage: /fleet [--agents N|--agents=N] <goal>")
                        return .handled
                    }
                    await runHeavyRoute(goal: invocation.goal, intent: .fleet, mode: .fleet,
                                        execution: "fleet(\(invocation.agents))", startProof: true) {
                        await fleet(invocation.goal, invocation.agents, roleSelection.bindings)
                    }
                    return .handled
                case "bughunt", "monkey", "monkeybash", "hunt", "breakit":
                    // Real-life bug hunt / monkey-bash (Luke 2026-08-01): spin up a FLEET of isolated
                    // hunters (each its own sandbox/worktree, headless, spin up as many as needed) that
                    // actually RUN the target and try to BREAK it — reporting only reproduced failure points.
                    guard let fleet else { print("\u{001B}[31m/bughunt isn't available here\u{001B}[0m"); return .handled }
                    guard let inv = Self.parseFleetArgs(args, defaultAgents: max(3, defaultAgents)) else {
                        print("usage: /bughunt [--agents N] <app or target> — a fleet of isolated hunters runs it + tries to break it")
                        return .handled
                    }
                    print("\u{001B}[35m🐛 bug hunt · \(inv.agents) isolated hunters running + hammering: \(inv.goal)\u{001B}[0m")
                    let bugGoal = Self.bugHuntBrief(inv.goal)
                    await runHeavyRoute(goal: bugGoal, intent: .fleet, mode: .fleet,
                                        execution: "bughunt-fleet(\(inv.agents))", startProof: true) {
                        await fleet(bugGoal, inv.agents, roleSelection.bindings)
                    }
                    return .handled
                case "plan-execute", "pe", "dag":
                    guard let planExecute else { print("\u{001B}[31m/plan-execute isn't available here\u{001B}[0m"); return .handled }
                    guard !args.isEmpty else { print("usage: /plan-execute <goal>"); return .handled }
                    await runHeavyRoute(goal: args, intent: .build, mode: .planExecute,
                                        execution: "plan-execute", startProof: true) {
                        await planExecute(args, roleSelection.bindings)
                    }
                    return .handled
                case "build", "implement", "buildit", "ship-it", "makeit":
                    // THE BRIDGE from "here's the plan" to actually building it. `/build <goal>` fires the
                    // plan→execute worker (real code + build/tests), not another analysis turn. With NO
                    // args it BUILDS THE PLAN JUST PROPOSED — so after Kist lays out a plan you type
                    // `/build` and it executes it instead of researching forever. Compose with `/ultra`
                    // first for consensus review on the build.
                    guard let planExecute else { print("\u{001B}[31m/build isn't available here\u{001B}[0m"); return .handled }
                    let buildGoal: String
                    if !args.isEmpty {
                        buildGoal = Self.expandBoardReference(args, projectRoot: projectRoot,
                                                              sessionStartedAt: sessionStart)
                    } else {
                        let lastUser = humanTranscript.reversed().first { $0.role == .user }?.content
                        let lastPlan = humanTranscript.reversed().first { $0.role == .assistant }?.content
                        guard let lastUser else {
                            print("usage: /build <goal> — or run it right after a plan and it builds what was just proposed")
                            return .handled
                        }
                        buildGoal = "EXECUTE and BUILD the plan you just proposed — implement it now with real "
                            + "code and a passing build/test. Do NOT re-research, re-plan, or re-analyze; the "
                            + "plan is already decided.\n\nOriginal request: \(lastUser)"
                            + (lastPlan.map { "\n\nThe plan to execute:\n\($0)" } ?? "")
                    }
                    print("\u{001B}[36;1m🔨 build\u{001B}[0m\u{001B}[2m · firing plan→execute worker (real code + build/tests)\u{001B}[0m")
                    await runHeavyRoute(goal: buildGoal, intent: .build, mode: .planExecute,
                                        execution: "build", startProof: true) {
                        await planExecute(buildGoal, roleSelection.bindings)
                    }
                    return .handled
                case "council", "consult":
                    guard let council else { print("\u{001B}[31m/council isn't available here\u{001B}[0m"); return .handled }
                    guard let invocation = Self.parseCouncilArgs(args) else {
                        print("usage: /council [--execute|--build] <research/task>")
                        return .handled
                    }
                    let councilIntent: TaskBrief.Intent = invocation.execute ? .build : .plan
                    let councilMode: PromptCompiler.Mode = invocation.execute ? .planExecute : .inline
                    await runHeavyRoute(goal: invocation.goal, intent: councilIntent, mode: councilMode,
                                        execution: invocation.execute ? "council-execute" : "council",
                                        startProof: true) {
                        await council(invocation.goal, roleSelection.bindings, invocation.execute)
                    }
                    return .handled
                case "dig", "digdeep", "minds", "mind":
                    guard let digDeep else { print("\u{001B}[31m/dig isn't available here\u{001B}[0m"); return .handled }
                    guard !args.isEmpty else { print("usage: /dig <question> — ask every reachable model in parallel and synthesize"); return .handled }
                    await runHeavyRoute(goal: args, intent: .review, mode: .inline,
                                        execution: "dig-in-deep", startProof: true) {
                        await digDeep(args, roleSelection.bindings)
                    }
                    return .handled
                case "effort":
                    // The CONFLICT-ESCALATION LADDER: build solo (L1) → on a FAILED hard gate, escalate —
                    // a DISTINCT adversarial mind enters (L2), a rater enters (L3), then the full gauntlet
                    // (ultra). Cheap path ships fast; only failure spends more minds. `/effort <goal>` auto-
                    // escalates from L1; `/effort <1|2|3|ultra> <goal>` starts at that rung.
                    guard planExecute != nil else { print("\u{001B}[31m/effort isn't available here\u{001B}[0m"); return .handled }
                    let (startLevel, effortGoalRaw) = Self.parseEffortArgs(args)
                    let effortGoal: String
                    if !effortGoalRaw.isEmpty {
                        effortGoal = Self.expandBoardReference(effortGoalRaw, projectRoot: projectRoot, sessionStartedAt: sessionStart)
                    } else if let lastUser = humanTranscript.reversed().first(where: { $0.role == .user })?.content {
                        effortGoal = "BUILD this now with real code and a passing build/test: \(lastUser)"
                    } else {
                        print("usage: /effort [1|2|3|ultra] <what to build> — escalating multi-model build (solo → reviewer → rater → full gauntlet)")
                        return .handled
                    }
                    await runHeavyRoute(goal: effortGoal, intent: .build, mode: .planExecute,
                                        execution: "effort-ladder", startProof: true) {
                        await runEffort(goal: effortGoal, startLevel: startLevel)
                    }
                    return .handled
                case "dashboard", "kanban", "kist-dashboard", "fallout-dashboard", "pipboy", "pip-boy":
                    // The full Fallout/Pip-Boy GUI dashboard (talent tree, history, arch/cortex/sessions/vms).
                    // Restored after the re-home dropped it. Optional view: [conversation|flow|timeline|fleet|vms|plan].
                    await launchDashboard(command: name, args: args)
                    return .handled
                case "fix", "repair":
                    // THE CAPTAIN BUTTON: plan → force action → build → the symbolic judge rules "done"
                    // (never the model). Drives the proven /build worker in a bounded force-retry loop and
                    // refuses to stop until there's a VERIFIED, non-monolith artifact. `/fix` alone fixes
                    // the objective just discussed; `/fix <goal>` fixes that.
                    guard planExecute != nil else { print("\u{001B}[31m/fix isn't available here\u{001B}[0m"); return .handled }
                    let fixGoal: String
                    if !args.isEmpty {
                        fixGoal = Self.expandBoardReference(args, projectRoot: projectRoot, sessionStartedAt: sessionStart)
                    } else if let lastUser = humanTranscript.reversed().first(where: { $0.role == .user })?.content {
                        fixGoal = "FIX this — implement it now with real code and a passing build/test; do NOT "
                            + "just analyze or plan.\n\nRequest: \(lastUser)"
                    } else {
                        print("usage: /fix <what to fix> — or run it right after describing a problem and it fixes that")
                        return .handled
                    }
                    await runHeavyRoute(goal: fixGoal, intent: .build, mode: .planExecute,
                                        execution: "captain-fix", startProof: true) {
                        await runCaptainFix(goal: fixGoal)
                    }
                    return .handled
                case "audit", "security", "security-audit", "vuln", "sast", "secscan":
                    // Security audit: secret-scan + SAST + dependency check → severity-ranked report.
                    // `/audit owasp` → OWASP-Top-10-Agentic governance posture.
                    await runSecurityAudit(args: args)
                    return .handled
                case "scorecard", "models", "model-scorecard", "modelstats", "trackrecord":
                    // The Captain's per-model track record: successes/failures/loops + the rank nudge or
                    // auto-avoid it applies when picking. Makes "don't burn shit" legible.
                    showScorecard()
                    return .handled
                case "ballbusting", "ballbust", "ball-busting", "roast", "bustmyballs":
                    // The no-mercy review organ: point a skeptical reviewer at the current work, forbid
                    // gaslighting, name every flaw, propose a fix for each. `/ballbusting` reviews the
                    // working-tree diff; `/ballbusting <text>` roasts a plan/idea.
                    await runBallbusting(args: args)
                    return .handled
                case "ultra", "consensus", "flawless":
                    // Explicit consensus mode: heterogeneous reviewers report findings; the original author
                    // gets at most three repair rounds. Review consensus never substitutes for build/tests.
                    let level = args.trimmingCharacters(in: .whitespaces).lowercased()
                    switch level {
                    case "", "on", "ultra", "max", "consensus":
                        copilot.ultra = true
                        copilot.enabled = true
                        copilot.autoSecondOpinion = true
                        copilot.autoFix = true
                        let roster = ultraRoster(excluding: activeBinding).map { TeamLanguage.displayName($0.providerId) }
                        print("\u{001B}[35m⎇ ULTRA on — advisory consensus; original author repairs findings (max 3)\u{001B}[0m")
                        print("\u{001B}[2m  \(Copilot.verificationBoundary)\u{001B}[0m")
                        print("\u{001B}[2m  order: \(roster.isEmpty ? "(no other minds configured — add with /model)" : roster.joined(separator: " → "))\u{001B}[0m")
                    case "off", "normal", "single", "review":
                        copilot.ultra = false
                        print("\u{001B}[35m⎇ ULTRA off — single-review mode\u{001B}[0m")
                    case "status", "?":
                        print("ultra: \(copilot.ultra ? "ON (advisory consensus + author repair)" : "off (single review)") · /ultra | /ultra off")
                    default:
                        print("usage: /ultra | /ultra off   (review consensus; original author repairs, max 3)")
                    }
                    return .handled
                case "mode", "modes", "voice":
                    // Set HOW Kist talks: interaction mode / reading level / custom persona. Persisted.
                    let a = args.trimmingCharacters(in: .whitespaces)
                    func showMode() {
                        print("\u{001B}[36;1m/mode\u{001B}[0m \u{001B}[2m· current:\u{001B}[0m \(style.summary)")
                        print("\u{001B}[2m  interaction: conversation · science · build · friend · nobs · normal\u{001B}[0m")
                        print("\u{001B}[2m  reading level: /mode level <1..8 | highschool | college>\u{001B}[0m")
                        print("\u{001B}[2m  custom voice:  /mode persona <describe the partner you want>  (/mode persona off)\u{001B}[0m")
                    }
                    if a.isEmpty { showMode(); return .handled }
                    let parts = a.split(separator: " ", maxSplits: 1).map(String.init)
                    let head = parts[0].lowercased()
                    let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                    switch head {
                    case "off", "normal", "default", "reset", "clear":
                        style = ReplStyle()
                        print("\u{001B}[32m✓ mode reset to normal\u{001B}[0m")
                    case "level", "reading", "grade", "readinglevel":
                        if ["off", "none", "clear"].contains(rest.lowercased()) {
                            style.readingLevel = nil; print("\u{001B}[32m✓ reading level cleared\u{001B}[0m")
                        } else if let lvl = ReplStyle.ReadingLevel.parse(rest) {
                            style.readingLevel = lvl; print("\u{001B}[32m✓ reading level · \(lvl.label)\u{001B}[0m")
                        } else { print("\u{001B}[31musage: /mode level <1..8 | highschool | college>\u{001B}[0m"); return .handled }
                    case "persona", "personality":
                        if rest.isEmpty { print("usage: /mode persona <describe the partner you want>  (/mode persona off)"); return .handled }
                        if ["off", "none", "clear"].contains(rest.lowercased()) {
                            style.persona = nil; print("\u{001B}[32m✓ persona cleared\u{001B}[0m")
                        } else {
                            style.persona = rest; print("\u{001B}[32m✓ persona set\u{001B}[0m \u{001B}[2m· \(style.summary)\u{001B}[0m")
                        }
                    default:
                        if let m = ReplStyle.Mode.parse(a) {
                            style.mode = m; style.persona = nil       // picking a mode clears a custom persona
                            print("\u{001B}[32m✓ mode · \(m.rawValue)\u{001B}[0m \u{001B}[2m(\(style.summary))\u{001B}[0m")
                        } else { print("\u{001B}[31munknown mode '\(a)'\u{001B}[0m"); showMode(); return .handled }
                    }
                    style.save(projectRoot: projectRoot)
                    return .handled
                case "chain", "chains", "automate", "flow":
                    // The automation center — Zapier × LangGraph for Kist. `/chain` opens the visual
                    // web builder; `/chain list` lists saved chains; `/chain run <name>` runs one here.
                    let store = ChainStore(projectRoot: projectRoot)
                    let stepBinding = activeBinding
                    let complete = modelComplete
                    // Each "Kist step" runs as a completion on the active model (v1). Real tool-using
                    // turns per step (so a step can send email / edit files) are the next increment.
                    let runStep: @Sendable (String) async -> String = { prompt in
                        await complete?(stepBinding.providerId, stepBinding.model,
                                        "You are one step in a Kist automation chain. Do the task and return ONLY the result text.",
                                        prompt) ?? "(no model available for this step)"
                    }
                    let runChain: @Sendable (Chain) async -> ChainRunner.RunResult = { c in
                        await ChainRunner(runStep: runStep).run(c)
                    }
                    let sub = args.split(separator: " ", maxSplits: 1).map(String.init)
                    if sub.first?.lowercased() == "list" {
                        let cs = store.all()
                        print(cs.isEmpty ? "\u{001B}[2mno chains yet — type /chain to open the builder\u{001B}[0m"
                              : cs.map { "\u{001B}[36m⛓\u{001B}[0m \($0.name) \u{001B}[2m(\($0.id))\($0.schedule.map { " · \($0)" } ?? "")\u{001B}[0m" }.joined(separator: "\n"))
                        return .handled
                    }
                    if sub.first?.lowercased() == "run", sub.count > 1 {
                        guard let c = store.find(sub[1]) else { print("\u{001B}[31mno chain named '\(sub[1])'\u{001B}[0m — /chain list"); return .handled }
                        print("\u{001B}[36;1m⛓ running \(c.name)…\u{001B}[0m")
                        let r = await runChain(c)
                        for s in r.steps { print("\u{001B}[2m  \(s.title) [\(s.kind.rawValue)] →\u{001B}[0m \(s.output.prefix(200))") }
                        return .handled
                    }
                    // default: open the visual builder
                    let server = ChainServer(store: store, runChain: runChain)
                    guard let url = server.start() else { print("\u{001B}[31mcould not start the chain builder (port busy?)\u{001B}[0m"); return .handled }
                    chainServer = server   // keep it alive for the session
                    print("\u{001B}[36;1m⛓ chain builder\u{001B}[0m \u{001B}[2m· open\u{001B}[0m \u{001B}[94;1m\(url.absoluteString)\u{001B}[0m \u{001B}[2m(leave kist running)\u{001B}[0m")
                    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: [url.absoluteString])
                    return .handled
                case "research", "deepdive", "sweep", "deep":
                    let researchGoal = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !researchGoal.isEmpty else {
                        print("usage: /research <goal> — evidence dossier → council → task board")
                        return .handled
                    }
                    // Keep research on the dedicated evidence pipeline. That path enforces the current
                    // ToolContext read grants, records its search/repo evidence, remains ESC/typeahead
                    // interruptible, runs the role-bound council, and seeds the durable task board.
                    // Never inject an in-process HOME/Volumes crawl into an ordinary model turn.
                    guard let research else {
                        print("\u{001B}[31m/research isn't available here\u{001B}[0m")
                        return .handled
                    }
                    print("\u{001B}[2m↳ evidence dossier → role-bound council → durable task board\u{001B}[0m")
                    await runHeavyRoute(goal: researchGoal, intent: .research, mode: .inline,
                                        execution: "research", startProof: true) {
                        await research(researchGoal, roleSelection.bindings)
                    }
                    return .handled
                case "dive", "codebase", "read-code", "digest":
                    // MULTI-MODEL deep-dive of OUR OWN code — LOCAL and repo-scoped (no web, no cross-repo
                    // sweep). Reads the actual files under the project root, grounds a dossier in them, then
                    // fans that real code out to every reachable model for a synthesized, file-cited truth.
                    let diveGoal = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !diveGoal.isEmpty else {
                        print("usage: /dive <question about our code> — multi-model read of OUR repo (local, no web)")
                        return .handled
                    }
                    guard let dive else { print("\u{001B}[31m/dive isn't available here\u{001B}[0m"); return .handled }
                    print("\u{001B}[36;1m🔬 dive\u{001B}[0m\u{001B}[2m · reading our code (local, no web) → multi-model → truth\u{001B}[0m")
                    await runHeavyRoute(goal: diveGoal, intent: .research, mode: .inline,
                                        execution: "codebase-dive", startProof: true) {
                        await dive(diveGoal, roleSelection.bindings)
                    }
                    return .handled
                case "competitive", "compete", "competitor", "vs":
                    // Point Kist at a competitor/URL/product and get a deep, cited R&D cross-comparison
                    // of OUR project vs theirs. Rides the /research evidence pipeline (web + our own
                    // estate sweep + council), framed as head-to-head competitive analysis.
                    guard let research else { print("\u{001B}[31m/competitive isn't available here\u{001B}[0m"); return .handled }
                    let target = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !target.isEmpty else {
                        print("usage: /competitive <competitor, product, or URL> — deep R&D cross-compare vs our project")
                        return .handled
                    }
                    let competitiveGoal = """
                    Competitive analysis & R&D cross-comparison — head to head.
                    Compare OUR current project (repo root: \(projectRoot)) against the target: \(target)

                    Deliver a deep, evidence-cited report:
                    • THEM — what the target does and how (features, architecture, positioning, pricing/GTM), from primary sources.
                    • US — what our project actually does (use the estate sweep of our own files), our distinct approach and ownership.
                    • HEAD-TO-HEAD — what stands out on each side; where we win, where they win, where we're at parity.
                    • MARKET — who else plays here, what's table stakes, and where the space is heading.
                    • GAPS & R&D MOVES — concrete, prioritized things we could build to differentiate or leapfrog.
                    Ground every claim in a source; clearly separate verified facts from inference. Do not inflate.
                    Target: \(target)
                    """
                    print("\u{001B}[36;1m📊 competitive\u{001B}[0m\u{001B}[2m · cross-comparing our project vs \(target)\u{001B}[0m")
                    await runHeavyRoute(goal: competitiveGoal, intent: .research, mode: .inline,
                                        execution: "competitive-analysis", startProof: true) {
                        await research(competitiveGoal, roleSelection.bindings)
                    }
                    return .handled
                default:
                    if let expanded = commands.expand(name, args: args) {
                        proofStore?.startTurn(goal: expanded)
                        if let display = personaDisplay?(expanded) { print(Self.stdoutColorEnabled(projectRoot: projectRoot) ? "\u{001B}[95;1m🎭 \(display)\u{001B}[0m" : "↳ \(display)") }
                        armTurnLoop()   // arm the permission tier — never run a turn on a stale loop
                        let mode: PromptCompiler.Mode = perm.mode.isPlan ? .plan : .inline
                        let intent = PromptCompiler.inferIntent(expanded, mode: mode)
                        proofStore?.record(.init(kind: .routeSelected, tool: nil, success: nil,
                                                 text: "intent=\(intent.rawValue) outcome=\(PromptCompiler.expectedOutcome(intent: intent, mode: mode).rawValue) execution=command-inline"))
                        let compiled = briefCompiler?(expanded, roleSelection.bindings, mode,
                                                      humanTranscript, intent) ?? expanded
                        let enriched = attachCaptainContext(to: compiled, objective: expanded)
                        let reviewBaseline = reviewBaselineIfArmed(intent: intent)
                        let oc = await runTurnInterruptible(loop: loop, userInput: enriched,
                                                            rawRequest: expanded, resolvedIntent: intent)
                        rememberHumanTurn(user: expanded, assistantSummary: oc.summary)
                        await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                        await runCopilotReview(task: expanded, baselineDiff: reviewBaseline,
                                               turnIntent: intent, turnSucceeded: oc.success)
                        let completedTurn = recordVerificationAndFinal(outcome: oc, intent: intent)
                        selfMonitor(goal: expanded, intent: intent, success: completedTurn)
                        await printTurnUsage()
                        recordSubmittedTurnLearning(outcomeSummary: oc.summary, success: completedTurn)
                    } else {
                        print("\u{001B}[31munknown command /\(name)\u{001B}[0m — try /help or /commands")
                    }
                    return .handled
                }
    }
}
