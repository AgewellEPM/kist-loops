import Foundation
import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The conversational shell: read a line, run an agent turn on it (context carried across
/// turns), repeat. The Claude-Code-style interactive surface. The loop already streams its
/// actions/results to the `TerminalEventSink`, so the REPL just manages input + the transcript.
final class KistREPL {
    var loop: HeadlessAgentLoop
    let commands: KistCommands
    /// Escalate to a SUPERVISED FLEET from inside the conversation (nil when unavailable, e.g. resume).
    var fleet: ((_ goal: String, _ agents: Int, _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// Escalate to PLAN→EXECUTE (a typed DAG built by the team) from inside the conversation.
    var planExecute: ((_ goal: String, _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// Run an AI council (researcher -> architect -> coder -> critic -> UX -> memory -> final board).
    var council: ((_ goal: String, _ roles: RoleBindings, _ execute: Bool) async -> HeavyRouteResult)? = nil
    /// "Dig in deep" / "consult the minds": ask EVERY reachable model the same question in parallel and
    /// synthesize agree/disagree — the multi-model second opinion, instead of one model answering alone.
    var digDeep: ((_ goal: String, _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// Run an evidence-first research pass, feed the dossier to council, and seed the shared board.
    var research: ((_ goal: String, _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// Forge a specialist from a plain-English role description (AgentForge), bounded by the loop's tool
    /// ceiling, validated, and saved to the registry. nil = forging unavailable in this mode.
    var forge: ((_ description: String, _ roles: RoleBindings) async -> Void)? = nil
    /// The intent router (Increment B): classify a plain message as chat|build|plan|research|council|fleet and PROPOSE an
    /// escalation (never silently spend). nil = auto-route off (explicit slash commands only).
    var router: ConversationRouter? = nil
    /// Rebuild the auto-router when the planner role changes inside the REPL.
    var routerFactory: ((_ planner: ProviderBinding) -> ConversationRouter?)? = nil
    /// Role bindings assigned from the terminal with `/roles`.
    var roleSelection = RoleSelection(default: ProviderBinding(providerId: "unknown"))
    /// Rebuild the held loop when the session default model OR role bindings change, so the
    /// conversational turn AND `spawn_agent(role: ...)` both see the new model/team.
    var loopFactory: ((_ defaultBinding: ProviderBinding, _ roles: RoleBindings, _ planMode: Bool, _ showReasoning: Bool, _ extendedThinking: Bool) -> HeadlessAgentLoop)? = nil
    /// Provider alias -> canonical provider id, known to this terminal session. Empty means skip eager validation.
    var providerAliases: [String: String] = [:]
    /// Human-readable provider list for `/providers`.
    var providerLabels: [String] = []
    /// providerId (lowercased) -> available model ids, for `/model` listing + bare-model resolution.
    var providerModels: [String: [String]] = [:]
    /// Whether a provider has a usable API key (green in the picker) or needs one (red). Set by the runner
    /// from the live registry; nil ⇒ assume keyed (no red).
    var providerHasKey: ((String) -> Bool)? = nil
    /// Import a model by URL (`/model import <url>`): discover models, add a key, onboard, persist. Set by
    /// the runner; returns the onboarded provider id (or nil if cancelled/failed).
    var importModelFlow: ((_ url: String?) async -> String?)? = nil
    /// Save an API key for an EXISTING provider (used when you pick a red/no-key model in the picker).
    /// Writes to the owner-only secret file via the provider's key account; true on success. Takes effect
    /// live — FileKeyStore re-reads per lookup, so the model is usable this session (no restart).
    var saveProviderKey: ((_ providerId: String, _ key: String) -> Bool)? = nil
    /// Project root, for resolving dragged-in relative media paths.
    var projectRoot: String = "."
    /// Per-turn trajectory recorder (self-monitoring): reset before each turn, analyzed after.
    var recorder: TrajectoryRecorder? = nil
    /// Session token/cost spans. `/usage` reads it; each turn prints a short delta.
    var traceRecorder: TraceRecorder? = nil
    /// Calm-mode proof drawer: full event details captured during a turn and shown via /logs or /details.
    var proofStore: TurnProofStore? = nil
    /// Durable replay renderer for `.kist/runs/<id>` proof streams. nil = replay unavailable here.
    var replayRenderer: ((_ id: String?) -> String)? = nil
    /// Current run's durable replay id, shown in help/status.
    var replayRunID: String? = nil
    /// Durable lesson memory: records obstacles from unhealthy/failed turns (advisory, retrieval-only).
    var lessonStore: LessonStore? = nil
    /// The Cortex: human-readable .md memory of YOU (preferences/projects/journal). `/cortex` views + edits it.
    var cortex: CortexMemory? = nil
    /// Provider/model health reports. probe=true spends a tiny live completion per configured provider.
    var providerHealth: ((_ probe: Bool) async -> String)? = nil
    var providerDoctor: (() async -> String)? = nil   // /doctor: live /models diff vs catalog
    /// Protocol/tool-control status (MCP/A2A/browser/computer-control).
    var protocolStatus: (() -> String)? = nil
    /// Provider bake-off for a task.
    var runBench: ((_ goal: String) async -> Void)? = nil
    /// Eval assertions for a task.
    var runEval: ((_ goal: String) async -> Void)? = nil
    /// A configured vision-capable provider to borrow for media turns when the active model can't see
    /// (nil if none is configured). Set by the runner to e.g. "gemini" when its key is present.
    var visionProviderId: String? = nil
    /// Autopilot may send clipboard media without a per-paste prompt. Normal REPL still asks once.
    var autoApproveClipboardVision = false
    /// R2b: pin the input bar to the bottom via a scroll region (default on for TTYs; --no-pinned-bar off).
    var pinnedBarEnabled = true
    /// Keep the pinned box glued to the bottom DURING a turn through the serialized screen owner.
    /// Explicit opt-in (`--sticky-turns`); the default continues to suspend between prompts.
    var stickyTurnsEnabled = false
    /// Whether a given (provider, model) can interpret images/media — drives one-turn media routing.
    var providerSupportsVision: ((ProviderBinding) -> Bool)? = nil
    /// Upload over-cap media to the Gemini Files API, returning fileURI attachments (set by the
    /// runner when a Gemini key exists; nil otherwise). Failures are reported, never silently dropped.
    var uploadMedia: ((_ uploads: [MediaResolver.PendingUpload]) async -> [MediaAttachment])? = nil
    /// Saved role/team profiles.
    var roleProfiles: RoleProfileStore? = nil
    /// Deterministically save the current conversation transcript inside the project root.
    var saveTranscript: ((_ transcript: [ChatMessage], _ path: String) throws -> String)? = nil
    /// Compile messy user text into a clear, self-contained task brief before handing it to the loop.
    var briefCompiler: ((_ input: String, _ roles: RoleBindings, _ mode: PromptCompiler.Mode,
                        _ transcript: [ChatMessage], _ intent: TaskBrief.Intent) -> String)? = nil
    /// Human-visible specialist adoption for the next turn ("acting as: security-auditor").
    var personaDisplay: ((_ input: String) -> String?)? = nil
    /// Lines typed into an approval prompt that were not approval answers, queued for the next REPL turn.
    var deferredInput: (() async -> String?)? = nil
    /// Flip hands-free autopilot on/off mid-session (`/auto`). Wired to the terminal interactor.
    var setAutopilot: ((Bool) async -> Void)? = nil
    /// Default fleet size when `/fleet` is given no `--agents` (mirrors the CLI default).
    var defaultAgents: Int = 5
    /// AUTO-ROUTING: when on (the default for a bare `kist`), kist picks the best model PER request
    /// with a cheap heuristic. `/model <spec>` pins a model (turns this off); `/model auto` re-enables.
    var autoRouting = false
    /// Heuristic model picker for the current turn (set by the runner, which holds the registry).
    // `current` is the model in use RIGHT NOW (activeBinding). The Captain router's "stay" decision must
    // fall back to the CURRENT model, not the startup default — else every no-signal turn after a switch
    // route-flips back to the original (the churn C4 exists to prevent). Codex HIGH, 2026-07-03.
    var autoRoute: ((_ text: String, _ hasMedia: Bool, _ current: ProviderBinding) -> AutoModelRouter.Decision)? = nil
    /// Onboard a new OpenAI-compatible model from inside the REPL (`/model add`). Set by the runner.
    var addModelFlow: (() async -> Void)? = nil
    /// Model completion seam for the `/bug-bounty` adversarial panel (nil ⇒ deterministic panel). Set by
    /// the runner from the provider catalog. (system, user) -> assistant text.
    var bountyComplete: (@Sendable (String, String) async -> String?)? = nil
    /// Completion seam for a SPECIFIC (provider, model) — used by `/copilot` to have the co-reviewer model
    /// critique a diff. (providerId, model, system, user) -> assistant text. Set by the runner; nil ⇒
    /// copilot review unavailable. Distinct from `bountyComplete`, which is pinned to the session model.
    var modelComplete: (@Sendable (_ providerId: String, _ model: String?, _ system: String, _ user: String) async -> String?)? = nil
    /// Explicit specialist run seam (`/agents run <name> <task>`). Hard-spawns the named specialist and
    /// returns its summary, or nil if no such agent. The caller passes the PARENT's live approval set +
    /// plan flag so a file-controlled `permissionMode` can only make the child MORE restrictive, never less
    /// (a malicious `.claude/agents` bypass can't escalate a guarded session).
    var runSpecialist: (@Sendable (_ name: String, _ task: String,
                                   _ parentApproval: Set<String>, _ parentPlan: Bool) async -> String?)? = nil
    /// Summarizer seam for `/compact` — completes on a GIVEN (provider, model) with room for a real summary
    /// (larger maxTokens than the pinned `bountyComplete`). The REPL passes the ACTIVE binding so compaction
    /// follows `/model` switches instead of the stale launch model. Set by the runner; nil ⇒ unavailable.
    var compactComplete: (@Sendable (_ providerId: String, _ model: String?, _ system: String, _ user: String) async -> String?)? = nil
    /// Permission bar (shift+tab) config: the sensitive-tool baseline + the file-edit subset that
    /// `accept edits` auto-approves, and the tier the session launched in (bypass when --yolo/--auto).
    var sensitiveTools: Set<String> = []
    var editTools: Set<String> = []
    var initialPermissionMode: PermissionMode = .normal

    // MARK: - Per-session mutable state (promoted from run() locals so decomposed helpers can share it)
    // Assigned at the top of run(); the nested-func-turned-methods read/write these instead of captures.
    var perm: PermissionController!            // set first thing in run() (needs sensitiveTools/editTools)
    var activeBinding = ProviderBinding(providerId: "unknown")   // reassigned first thing in run()
    var extendedThinking = false
    var showReasoning = false
    var usageSnapshot: [AgentSpan] = []
    var submittedTurnSpans: [AgentSpan] = []
    var transcript: [ChatMessage] = []
    var humanTranscript: [ChatMessage] = []
    var style = ReplStyle()
    var currentPersona = "captain"
    var copilot = CopilotConfig()
    var archivedTurnEvidence: [ActionRecord] = []
    var repairPhaseFailed = false
    var noInlinePreviewHintShown = false
    var lastTurnInterrupted = false
    var lastConfidenceReport: ConfidenceReport?
    var sessionStart = Date()
    var pinnedBar: PinnedBar!                  // assigned at run() start (needs pinnedBarEnabled)
    var inputReader = EnhancedPromptReader()
    var cachedSymbols: [String]?
    var clipboardVisionApprovedForSession = false
    var activeInteractionSession: TurnInteractionSession?

    // KistREPL is a class (reference type) so run()'s decomposed helpers can share mutable session
    // state as properties instead of 30 captured locals. Only loop + commands are required; the rest
    // are configured by the runner after construction (repl.X = …).
    init(loop: HeadlessAgentLoop, commands: KistCommands) {
        self.loop = loop
        self.commands = commands
    }

    func run() async {
        // Per-session mutable state now lives on `self` (promoted from run() locals) so the decomposed
        // turn/review/self-heal helpers share it. `loop`, `roleSelection`, `router`, `autoRouting` are
        // already properties; assign the runtime-dependent ones here. `sessionStart` (property) is
        // captured so the status line can tell a plan THIS session worked from a stale prior plan.
        sessionStart = Date()
        perm = PermissionController(mode: initialPermissionMode, sensitive: sensitiveTools, edit: editTools)
        extendedThinking = loop.isExtendedThinking   // --think default; /think toggles it on the held loop
        showReasoning = loop.isExtendedThinking      // launched with --think ⇒ show reasoning
        activeBinding = roleSelection.fallback
        let headerMode = autoRouting ? "auto-routing"
            : (TeamLanguage.describeTeam(roleSelection.bindings)
               ?? Self.render(roleSelection.fallback))
        print(StartupHeader.render(mode: headerMode, projectRoot: projectRoot, planMode: loop.isPlanMode))
        if loop.isPlanMode { print("\u{001B}[33m⚑ plan mode ON — read-only; the agent proposes a plan. /plan off to execute.\u{001B}[0m") }
        // R2b: pin the input panel to the bottom (scroll-region). Activated AFTER the header so the
        // header lands in normal scrollback; deactivated on EVERY exit path so the shell is never left
        // with a stuck region. When disabled/non-TTY the leads below are byte-identical to the old inline box.
        pinnedBar = PinnedBar(enabled: pinnedBarEnabled)
        self.pinnedBar.activate()
        defer { self.pinnedBar.deactivate() }
        // `transcript`, `humanTranscript`, `currentPersona`, `copilot` are now properties (promoted).
        // `style` (set with `/mode`) loads from the project so it survives relaunches.
        style = ReplStyle.load(projectRoot: projectRoot)
        clipboardVisionApprovedForSession = autoApproveClipboardVision
        // The shared recorder is phase-local so substitution/review logic can make decisions about the
        // current attempt. Preserve drained phases separately so final review, verification, learning, and
        // replay still see the complete submitted-turn evidence in execution order.
        // archivedTurnEvidence + repairPhaseFailed are now properties (promoted).

        while true {
            // The previous submitted message is complete only now: post-review and usage rendering
            // have finished. `finish()` releases descriptor capture + DECSTBM while stdin is still
            // raw, then stops its one watcher and restores cooked mode. This is the no-lost-typeahead,
            // no-kernel-echo-through-the-panel handoff boundary.
            if let session = activeInteractionSession {
                await session.finish()
                activeInteractionSession = nil
                self.pinnedBar.endStickyTurn()
            }
            // Claude-Code-style rounded input box: a top border, then a `│ ❯` prompt line the reader edits
            // inside, a bottom border, and the hint. (Plan mode flags the prompt yellow.)
            let boxWidth = PromptBar.safeWidth(columns: TerminalMediaRenderer.terminalColumns(default: 80))
            let topBorder = PromptBar.topBorder(width: boxWidth)
            let promptPlain = perm.mode.isPlan ? "│ ⚑ ❯ " : "│ ❯ "
            let promptColor = perm.mode.isPlan
                ? "\u{001B}[2m│ \u{001B}[0m\u{001B}[33;1m⚑ ❯ \u{001B}[0m"
                : "\u{001B}[2m│ \u{001B}[0m\u{001B}[36;1m❯ \u{001B}[0m"
            let status = await renderStatusLine()
            // R2b: re-pin if the terminal was resized since the last prompt, then draw the panel in the
            // pinned strip. `panelLead()` is "\n" when the bar is off ⇒ identical to the old inline box.
            self.pinnedBar.resume()                 // re-pin the strip after a turn ran with the region torn down
            self.pinnedBar.refreshSizeIfNeeded()
            // Size the reserved strip to the ACTUAL status height (1 line, or 2 when a task board is
            // active) so the box never overflows the pinned region and corrupts the panel mid-plan.
            let statusRows = status.isEmpty ? 1 : status.split(separator: "\n", omittingEmptySubsequences: false).count
            let panelLead = self.pinnedBar.panelLead(statusRows: statusRows)
            let line: String
            let promptWasPinned = self.pinnedBar.active
            // R2a: a drained line was typed while the user may have WALKED AWAY — never block the
            // backlog on an interactive y/N confirm for it (router guard below).
            var lineFromQueue = false
            if let queued = await deferredInput?() {
                FileHandle.standardOutput.write(Data((panelLead + status + "\n" + topBorder + "\n" + promptColor + queued + "\n").utf8))
                line = queued
                lineFromQueue = true
                // There is no prompt reader/raw-mode defer on this path. Release the fixed screen
                // explicitly before the new turn session takes stdin ownership.
                self.pinnedBar.suspend()
            } else {
                FileHandle.standardOutput.write(Data((panelLead + status + "\n" + topBorder + "\n").utf8))
                let read = inputReader.readLine(prompt: promptColor,
                                                promptColumns: promptPlain.count,
                                                completionCandidates: completionCandidates,
                                                commandNames: InputCompleter.builtInCommands + commands.names.map { "/\($0)" },
                                                onPaste: { PasteboardReader.text() },
                                                barHint: { self.perm.barHint(includeInterrupt: true) },
                                                onCycle: { self.perm.cycle() },
                                                // Runs from the prompt reader's defer before RawMode.disable().
                                                // Kernel echo must never coexist with the fixed panel.
                                                beforeRawRestore: { self.pinnedBar.suspend() },
                                                // R2a: half-typed text from during the turn lands here.
                                                initialText: TurnInputQueue.shared.takePending())
                switch read {
                case .line(let l): line = l
                case .interrupt: print("\u{001B}[37m(input cleared)\u{001B}[0m"); continue
                case .eof: print(); return
                }
            }
            let input = Self.collapseFloodedPaths(line.trimmingCharacters(in: .whitespacesAndNewlines))
            if input.isEmpty { continue }
            let slashCommand = Self.isSlashCommand(input)
            var turnSession: TurnInteractionSession?
            if !slashCommand {
                var onInputChange: (@Sendable (String, Int) -> Void)?
                var onScreenLeaseBegin: (@Sendable () -> Bool)?
                var onScreenLeaseEnd: (@Sendable () -> Bool)?
                var onScreenReleaseBeforeFinish: (@Sendable () -> Void)?
                var setBracketedPasteMode: (@Sendable (Bool) -> Void)?
                if stickyTurnsEnabled, promptWasPinned {
                    onInputChange = { pending, queuedCount in
                        self.pinnedBar.updateStickyTypeahead(
                            pending: pending, queuedCount: queuedCount)
                    }
                    onScreenLeaseBegin = { self.pinnedBar.beginInputScreenLease() }
                    onScreenLeaseEnd = { self.pinnedBar.endInputScreenLease() }
                    onScreenReleaseBeforeFinish = { self.pinnedBar.suspend() }
                    setBracketedPasteMode = { self.pinnedBar.setBracketedPasteEnabled($0) }
                }
                let session = TurnInteractionSession(
                    queue: TurnInputQueue.shared,
                    onInputChange: onInputChange,
                    onScreenLeaseBegin: onScreenLeaseBegin,
                    onScreenLeaseEnd: onScreenLeaseEnd,
                    onScreenReleaseBeforeFinish: onScreenReleaseBeforeFinish,
                    setBracketedPasteMode: setBracketedPasteMode)
                session.start()
                turnSession = session
                activeInteractionSession = session
            }

            var stickyCaptureSucceeded = false
            var committedEchoWritten = false
            if promptWasPinned {
                if !slashCommand, stickyTurnsEnabled,
                   turnSession?.safelyOwnsRawStdin == true {
                    // The prompt reader released DECSTBM before restoring cooked mode. Re-pin only
                    // after this turn's one watcher has confirmed raw stdin ownership.
                    self.pinnedBar.resume()
                    if self.pinnedBar.active {
                        FileHandle.standardOutput.write(Data((self.pinnedBar.transcriptLead()
                            + "\u{001B}[36;1m❯ \u{001B}[0m" + input + "\r\n").utf8))
                        committedEchoWritten = true
                        let snapshot = TurnInputQueue.shared.preview()
                        let panel = TerminalScreenCoordinator.Panel(
                            status: status,
                            promptPrefix: promptPlain,
                            pending: snapshot.pending,
                            queuedCount: snapshot.queuedCount,
                            hint: perm.barHint(includeInterrupt: true))
                        stickyCaptureSucceeded = self.pinnedBar.beginStickyTurn(panel: panel)
                    }
                    if !stickyCaptureSucceeded {
                        // Raw ownership or capture setup failed. Stay on the full-screen fallback.
                        self.pinnedBar.suspend()
                    }
                }

                if !stickyCaptureSucceeded, !committedEchoWritten {
                    // The fixed prompt was cleared by the safe raw→cooked handoff, so preserve the
                    // committed text once in normal scrollback for slash and non-sticky turns.
                    FileHandle.standardOutput.write(Data(
                        ("\u{001B}[36;1m❯ \u{001B}[0m" + input + "\r\n").utf8))
                }
            }
            resetTurnEvidence()               // fresh complete evidence ledger per submitted turn

            // Slash commands: built-ins, /commands, then any custom .kist/commands/<name>.md.
            // Only a command-shaped leading "/" counts — a dragged-in path falls through
            // to the agent as a normal message (see isSlashCommand).
            if slashCommand {
                let body = input.dropFirst()
                let name: String, args: String
                if let sp = body.firstIndex(of: " ") {
                    name = String(body[..<sp]); args = String(body[body.index(after: sp)...]).trimmingCharacters(in: .whitespaces)
                } else { name = String(body); args = "" }

                switch name.lowercased() {
                case "exit", "quit", "q": print("bye."); return
                case "help": printHelp(); continue
                case "wu-tang", "wutang", "wu", "odb":
                    // 🥷 Easter egg: the gold Wu-Tang "W" rises + the AI takes on ODB — but as a switchable
                    // MODE (default is professional; /persona off or /persona captain turns it back).
                    WuTangEasterEgg.riseAndShow()
                    currentPersona = Persona.apply("wutang", to: &transcript)
                    print(WuTangEasterEgg.activationHype)
                    continue
                case "persona", "mode", "personality":
                    // Personality LAYER — same shell, different voice. captain (default) · minimal · hacker ·
                    // jarvis · wutang · off. Switching replaces the prior persona cleanly (no permanent stick).
                    let want = args.trimmingCharacters(in: .whitespaces).lowercased()
                    if want.isEmpty {
                        print("persona · \u{001B}[36m\(currentPersona)\u{001B}[0m  ·  options: "
                              + Persona.names.joined(separator: ", ") + ", off")
                        continue
                    }
                    currentPersona = Persona.apply(want, to: &transcript)
                    print(currentPersona == "captain"
                          ? "persona · \u{001B}[36mcaptain\u{001B}[0m (professional, default)"
                          : "persona · \u{001B}[36m\(currentPersona)\u{001B}[0m")
                    continue
                case "bug-bounty", "bounty", "bb":
                    // The bug-bounty assistant: ingest a program (scope+rules), then run the guided,
                    // verified-only, human-on-submit wizard. Never auto-submits.
                    print(await BountyConsole.handle(args, projectRoot: projectRoot, complete: bountyComplete))
                    continue
                case "clear":
                    transcript = []
                    humanTranscript = []
                    lastConfidenceReport = nil
                    print("\u{001B}[37m(context cleared)\u{001B}[0m")
                    continue
                case "plan":
                    let want: Bool
                    switch args.lowercased() {
                    case "on", "true", "1": want = true
                    case "off", "false", "0": want = false
                    case "": want = !perm.mode.isPlan             // bare /plan toggles
                    default: print("usage: /plan [on|off]"); continue
                    }
                    perm.set(want ? .plan : .normal)             // same source of truth as the shift+tab bar
                    print(want ? "\u{001B}[33m⚑ plan mode ON — read-only; the agent proposes a plan.\u{001B}[0m"
                               : "\u{001B}[32m✓ plan mode OFF — the agent can edit/run again.\u{001B}[0m")
                    continue
                case "commands":
                    let n = commands.names
                    print(n.isEmpty ? "\u{001B}[37m(no custom commands — add .kist/commands/<name>.md)\u{001B}[0m"
                                    : "custom: " + n.map { "/\($0)" }.joined(separator: "  "))
                    continue
                case "save-chat", "export-chat", "transcript":
                    guard let saveTranscript else { print("\u{001B}[31m/save-chat isn't available here\u{001B}[0m"); continue }
                    let path = args.isEmpty ? "kist-conversation.md" : args
                    do {
                        let written = try saveTranscript(transcript, path)
                        print("conversation saved · \(written)")
                    } catch {
                        print("\u{001B}[31m\(error)\u{001B}[0m")
                    }
                    continue
                case "providers":
                    print(providerLabels.isEmpty ? "providers: unavailable" : "providers: " + providerLabels.joined(separator: ", "))
                    continue
                case "health":
                    guard let providerHealth else { print("provider health: unavailable"); continue }
                    print(await providerHealth(false))
                    continue
                case "probe-providers", "probe":
                    guard let providerHealth else { print("provider probe: unavailable"); continue }
                    print(await providerHealth(true))
                    continue
                case "doctor", "providers-doctor":
                    // Live GET /models per keyed provider, diffed vs the catalog: flags dead ids
                    // (e.g. grok-2-latest), invalid defaults, and reasoning models — drift preflight.
                    guard let providerDoctor else { print("provider doctor: unavailable"); continue }
                    print(await providerDoctor())
                    continue
                case "usage", "cost", "tokens":
                    await printSessionUsage()
                    continue
                case "autonomy", "activity", "pulse":
                    // What the AI actually spent its time doing this session — Thinking / Researching /
                    // Coding / Running / Delegating — so you can see WHY a turn took what it took.
                    let spans = await traceRecorder?.all() ?? []
                    print(AutonomyMeter.render(spans: spans, color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
                    continue
                case "logs", "details", "proof":
                    print(proofStore?.renderLast() ?? "No proof log yet. Run a turn first.")
                    continue
                case "replay":
                    guard let replayRenderer else { print("replay: unavailable in this mode"); continue }
                    let id = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    print(replayRenderer(id.isEmpty ? nil : id))
                    continue
                case "tools", "capabilities", "contract":
                    // The live tool contract the model sees — exactly what's callable, what's disabled,
                    // and which actions DON'T exist. So you can see why a plan did/didn't reach for a tool.
                    print(loop.renderToolContract())
                    continue
                case "summary", "status":
                    let spans = await traceRecorder?.all() ?? []
                    let trajectory = recorder?.snapshot() ?? []
                    print(Self.renderSimpleSummary(projectRoot: projectRoot, spans: spans,
                                                   trajectory: trajectory, sessionStartedAt: sessionStart))
                    continue
                case "confidence", "why":
                    // Explain the exact report the panel showed for the last completed turn. Do not
                    // consult the recorder here: it was intentionally reset before slash dispatch.
                    if let report = lastConfidenceReport {
                        print(report.renderBreakdown(color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
                    } else {
                        print("No confidence to explain yet — that turn used no tools (a plain answer). Run a turn that reads/edits/searches first.")
                    }
                    continue
                case "version", "ver", "changelog", "whatsnew", "whats-new":
                    // What shipped in this version + when it was built (real commit/branch/date from
                    // the deployment manifest) + the changelog — so `/version` reads like a release note.
                    print(KistChangelog.render(provenance: KistBuildInfo.provenance(),
                                               color: Self.stdoutColorEnabled(projectRoot: projectRoot)))
                    continue
                case "failures", "failure", "failure-analysis":
                    print(CaptainFailureAnalysis.handleCommand(args, projectRoot: projectRoot))
                    continue
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
                    continue
                case "knowledge", "knowledge-debt", "debt":
                    print(Self.handleKnowledgeCommand(args, projectRoot: projectRoot))
                    continue
                case "teach", "rules", "organizational-rules":
                    print(Self.handleTeachCommand(args, projectRoot: projectRoot))
                    continue
                case "learning", "model-learning", "captain-learning":
                    print(Self.handleCaptainLearningCommand(args, projectRoot: projectRoot))
                    continue
                case "industry", "intelligence", "strategic-intelligence", "strategic-intel":
                    print(Self.handleStrategicIntelligenceCommand(args, projectRoot: projectRoot))
                    continue
                case "self-heal", "heal", "fix-self":
                    await runSelfHealCommand(args)
                    continue
                case "legal", "legal-research", "law", "case-research":
                    let clean = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else {
                        print("usage: /legal-research <jurisdiction + legal issue + optional document path>")
                        continue
                    }
                    await runLegalResearchCommand(clean, forceResearch: true)
                    continue
                case "domain", "domain-learning", "research-first", "sme":
                    await runDomainLearningCommand(args)
                    continue
                case "model-run", "run-model-acquire", "model-acquisition-run":
                    let report = Self.handleLocalModelAcquisitionRunCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    let marker = report.markerPath.map { " · marker: \($0)" } ?? ""
                    let verdict = report.outcome?.succeeded == true ? "passed" : "blocked"
                    print("\u{001B}[2m\(persisted)\(marker) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                    continue
                case "model-acquire", "acquire-model":
                    let report = Self.handleLocalModelAcquisitionCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    let verdict = report.decision.accepted ? "verified" : "rejected"
                    print("\u{001B}[2m\(persisted) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                    continue
                case "local-model", "local-models", "model-scout", "hf", "huggingface":
                    if Self.isLocalModelAcquisitionRunIntent(command: name, args: args) {
                        let report = Self.handleLocalModelAcquisitionRunCommand(args, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let marker = report.markerPath.map { " · marker: \($0)" } ?? ""
                        let verdict = report.outcome?.succeeded == true ? "passed" : "blocked"
                        print("\u{001B}[2m\(persisted)\(marker) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        continue
                    }
                    if Self.isLocalModelAcquisitionIntent(command: name, args: args) {
                        let report = Self.handleLocalModelAcquisitionCommand(args, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision.accepted ? "verified" : "rejected"
                        print("\u{001B}[2m\(persisted) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        continue
                    }
                    if Self.isLiveModelMetadataGateIntent(command: name, args: args) {
                        let report = await Self.handleLiveModelMetadataGateCommand(args, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision?.accepted == true ? "accepted" : "rejected"
                        let manifest = report.acquisitionManifestPath.map { " · manifest: \($0)" } ?? ""
                        print("\u{001B}[2m\(persisted)\(manifest) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        continue
                    }
                    let report = Self.handleLocalModelScoutCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    print("\u{001B}[2m\(persisted) · candidates: \(report.candidates.count) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                    continue
                case "self-test", "selftest":
                    if let usage = Self.selfTestUsageIfNeeded(args) {
                        print(usage)
                        continue
                    }
                    let report = Self.handleSelfTestCommand(args, projectRoot: projectRoot)
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    print("\u{001B}[2m\(persisted) · checks: \(report.passed) pass / \(report.warnings) warn / \(report.failures) fail · seeded tasks: \(report.seededTasks)\u{001B}[0m")
                    continue
                case "immune", "immune-system", "immune-check":
                    if let usage = Self.immuneUsageIfNeeded(args) {
                        print(usage)
                        continue
                    }
                    let report = Self.handleImmuneCommand(args,
                                                          projectRoot: projectRoot,
                                                          trajectory: recorder?.snapshot() ?? [])
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    let mission = report.selfHealPath.map { " · self-heal: \($0)" } ?? ""
                    let simulation = report.simulationPath.map { " · simulation: \($0)" } ?? ""
                    print("\u{001B}[2m\(persisted) · status: \(report.status.rawValue) · self-test: \(report.selfTestPath)\(mission)\(simulation) · seeded tasks: \(report.seededTasks)\u{001B}[0m")
                    continue
                case "simulate", "simulation", "sim", "sandbox", "risk":
                    let report = Self.handleSimulationCommand(args,
                                                              projectRoot: projectRoot,
                                                              trajectory: recorder?.snapshot() ?? [])
                    print(report.text)
                    let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                    print("\u{001B}[2m\(persisted) · recommended: \(report.recommendedStrategy) · success: \(report.estimatedSuccess)% · risk: \(report.failureRisk)% · seeded simulation tasks: \(report.seededTasks)\u{001B}[0m")
                    continue
                case "symbolic", "workflow", "workflows", "compile-workflow":
                    print(Self.handleSymbolicWorkflowCommand(args,
                                                             projectRoot: projectRoot,
                                                             trajectory: recorder?.snapshot() ?? []))
                    continue
                case "retrieve", "recall":
                    print(Self.handleRetrieveCommand(args, projectRoot: projectRoot))
                    continue
                case "captain", "strategy", "organize":
                    let objective = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !objective.isEmpty else {
                        print("usage: /captain <objective>")
                        continue
                    }
                    if Self.isSelfHealIntent(objective) {
                        await runSelfHealCommand(objective)
                        continue
                    }
                    if Self.isSimulationIntent(objective) {
                        let report = Self.handleSimulationCommand(objective,
                                                                  projectRoot: projectRoot,
                                                                  trajectory: recorder?.snapshot() ?? [])
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        print("\u{001B}[2m\(persisted) · recommended: \(report.recommendedStrategy) · success: \(report.estimatedSuccess)% · risk: \(report.failureRisk)%\u{001B}[0m")
                        continue
                    }
                    if Self.isDomainLearningIntent(objective) {
                        await runDomainLearningCommand(objective)
                        continue
                    }
                    print(Self.handleCaptainStrategyCommand(objective, projectRoot: projectRoot))
                    continue
                case "evolve":
                    let store = OrganizationalLearningStore(projectRoot: projectRoot)
                    let report = store.runBoardMeeting(plan: PlanStore(projectRoot: projectRoot).load(),
                                                       trajectory: recorder?.snapshot() ?? [])
                    print(report.text)
                    print("\u{001B}[2mwritten: \(report.path) · seeded research tasks: \(report.seededResearchTasks) · created specialists: \(report.createdSpecialists) · promoted rules: \(report.promotedRules)\u{001B}[0m")
                    continue
                case "protocols", "mcp-status", "a2a":
                    print(protocolStatus?() ?? "protocol status: unavailable")
                    continue
                case "bench":
                    guard let runBench else { print("\u{001B}[31m/bench isn't available here\u{001B}[0m"); continue }
                    guard !args.isEmpty else { print("usage: /bench <task>"); continue }
                    await runBench(args)
                    continue
                case "eval":
                    guard let runEval else { print("\u{001B}[31m/eval isn't available here\u{001B}[0m"); continue }
                    guard !args.isEmpty else { print("usage: /eval <task>"); continue }
                    await runEval(args)
                    continue
                case "fleet-status", "cockpit", "fleetstatus":
                    // Terminal Captain cockpit: the latest fleet's per-agent status + honest merge-fate.
                    if let pic = FleetCockpitLoader.latestPicture() { print(pic.render()) }
                    else { print("\u{001B}[37mno fleet runs found — run /fleet <goal> first\u{001B}[0m") }
                    continue
                case "tasks", "task", "plan-tasks", "todo", "goals", "goal":
                    // The native runbook: the shared task list at <project>/.kist/plan.json. Both you and
                    // the agent (via the `tasks` tool) read/update it. `/tasks` shows it; subcommands edit.
                    print(Self.handleTasks(args, projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    continue
                case "cortex", "memory", "remember":
                    // The Cortex: what kist knows about YOU (preferences/projects/journal, all .md you can see).
                    // `/cortex` shows it · `/cortex files` lists the .md · `/cortex show <file>` ·
                    // `/cortex remember <fact>` teaches it · `/cortex project <name> <fact>`.
                    print(Self.handleCortex(name == "remember" ? "remember " + args : args, cortex: cortex))
                    continue
                case "agents", "agent", "specialists", "specialist":
                    // The specialist registry at <project>/.kist/agents/. `/agents` lists; `/agents show
                    // <name>` details; `/agents new <role description>` FORGES one (AgentForge, P3).
                    let aTrim = args.trimmingCharacters(in: .whitespaces)
                    let aLower = aTrim.lowercased()
                    if aLower == "new" || aLower == "forge" || aLower == "create"
                        || aLower.hasPrefix("new ") || aLower.hasPrefix("forge ") || aLower.hasPrefix("create ") {
                        let desc = aTrim.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
                        guard !desc.isEmpty else { print("usage: /agent new <role description>"); continue }
                        guard let forge else { print("\u{001B}[31mforging isn't available here\u{001B}[0m"); continue }
                        await forge(desc, roleSelection.bindings)
                    } else if aLower == "run" || aLower == "use" {
                        print("usage: /agents run <name> <task>")
                    } else if aLower.hasPrefix("run ") || aLower.hasPrefix("use ") {
                        // /agents run <name> <task> — HARD-spawn the named specialist (own context/tools/model).
                        let rest = aTrim.drop(while: { $0 != " " }).trimmingCharacters(in: .whitespaces)
                        let name = String(rest.prefix(while: { $0 != " " }))
                        let task = String(rest.drop(while: { $0 != " " })).trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !task.isEmpty else { print("usage: /agents run <name> <task>"); continue }
                        guard let runSpecialist else { print("\u{001B}[31mspecialist run isn't available here\u{001B}[0m"); continue }
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
                    continue
                case "action":
                    guard !args.isEmpty else {
                        print(Self.handleTasks("", projectRoot: projectRoot,
                                               sessionStartedAt: sessionStart)); continue
                    }
                    print(Self.handleTasks("add ACTION: \(args)", projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    continue
                case "test":
                    guard !args.isEmpty else {
                        print(Self.handleTasks("", projectRoot: projectRoot,
                                               sessionStartedAt: sessionStart)); continue
                    }
                    print(Self.handleTasks("add TEST: \(args)", projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    continue
                case "review":
                    guard !args.isEmpty else {
                        print(Self.handleTasks("", projectRoot: projectRoot,
                                               sessionStartedAt: sessionStart)); continue
                    }
                    print(Self.handleTasks("add REVIEW: \(args)", projectRoot: projectRoot,
                                           sessionStartedAt: sessionStart))
                    continue
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
                                continue
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
                    continue
                case "media", "preview", "imgcat":
                    let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        print(TerminalMediaRenderer.status())
                    } else {
                        print(TerminalMediaRenderer.previewFile(trimmed, projectRoot: projectRoot))
                    }
                    continue
                case "watch", "play":
                    // Stream a video INSIDE the terminal via mpv (local path or http(s) URL). Kitty/Ghostty
                    // get the native graphics protocol; every other terminal gets ANSI cells (--vo=tct),
                    // so it plays in Terminal.app too. Honest fail: missing mpv/yt-dlp → exact brew command.
                    let raw = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { print("usage: /watch <video-path-or-URL>"); continue }
                    let target: String
                    if TerminalVideoPlayer.isURL(raw) {
                        target = raw
                    } else {
                        let token = MediaResolver.tokenize(raw).first ?? raw
                        guard let (_, _, resolved) = MediaResolver.classify(token, projectRoot: projectRoot) else {
                            print("\u{001B}[31m/watch: '\(token)' is not a local video file or http(s) URL\u{001B}[0m"); continue
                        }
                        target = resolved
                    }
                    print("\u{001B}[37m↳ streaming in-terminal (q to quit)…\u{001B}[0m")
                    if let msg = TerminalVideoPlayer.play(target: target, columns: TerminalMediaRenderer.terminalColumns()) {
                        print("\u{001B}[33m\(msg)\u{001B}[0m")
                    }
                    continue
                case "auto", "autopilot":
                    // Flip hands-free autopilot on/off mid-session — auto-approve every tool (incl. shell)
                    // so a build rips through with no prompts. /auto off restores approval prompts.
                    guard let setAutopilot else { print("autopilot unavailable here"); continue }
                    let want: Bool
                    switch args.lowercased().trimmingCharacters(in: .whitespaces) {
                    case "on", "true", "1", "": want = true
                    case "off", "false", "0": want = false
                    default: print("usage: /auto [on|off]"); continue
                    }
                    await setAutopilot(want)
                    print(want
                        ? "\u{001B}[33m⚡ autopilot ON\u{001B}[0m — every tool auto-approved (incl. shell). /auto off to restore prompts."
                        : "autopilot off — sensitive tools will ask again.")
                    continue
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
                            print("\u{001B}[31munknown model '\(spec)'\u{001B}[0m — try /model for the catalog"); continue
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
                            print("\u{001B}[31munknown model '\(spec)'\u{001B}[0m — try /model for the catalog"); continue
                        }
                        copilot.co = b
                        print("copilot · co-reviewer: \(Self.render(b))")
                    case .invalid:
                        print("usage: /copilot [on|off] · /copilot lead <model> · /copilot co <model>")
                    }
                    continue
                case "chain", "pipeline":
                    // Sequential task pipeline: run each step as its own turn, in order, in the same
                    // conversation. `/chain "scaffold" | "add tests" | "wire it up"`. Stops on the first
                    // failed step (later steps usually depend on earlier ones).
                    let steps = ChainParser.parse(args)
                    guard steps.count >= 1 else { print("usage: /chain \"task 1\" | \"task 2\" | \"task 3\""); continue }
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
                    continue
                case "code", "c":
                    // CODING MODE — one keystroke: pin the strong coder (DeepSeek V4 Pro), turn per-request
                    // routing OFF so the conversation stays on the coder (never drifts to a chat/research
                    // model), and set the .coder role too so spawned builders use it. Research stays opt-in
                    // (/research · /council · /plan) — this drops you straight into the build loop.
                    // `/code <prov[:model]>` pins a different coder (e.g. /code claude-cli for the Max sub).
                    let codeSpec = args.trimmingCharacters(in: .whitespaces)
                    let coderBinding: ProviderBinding = codeSpec.isEmpty
                        ? ProviderBinding(providerId: "deepseek", model: "deepseek-v4-pro")
                        : {
                            let parts = codeSpec.split(separator: ":", maxSplits: 1).map(String.init)
                            return ProviderBinding(providerId: parts[0], model: parts.count > 1 ? parts[1] : nil)
                          }()
                    if let error = roleSelection.setDefault(coderBinding, knownProviders: providerAliases) {
                        print("\u{001B}[31m\(error)\u{001B}[0m"); continue
                    }
                    _ = roleSelection.assign(.coder, to: coderBinding, knownProviders: providerAliases)
                    autoRouting = false
                    activeBinding = roleSelection.fallback
                    if let loopFactory { loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                    print("\u{001B}[36m⌨ coding mode\u{001B}[0m · \(Self.render(roleSelection.fallback)) · research OFF (opt-in via /research) · just describe what to build")
                    continue
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
                                print("\u{001B}[31m\(error)\u{001B}[0m"); continue
                            }
                            autoRouting = false
                            activeBinding = roleSelection.fallback
                            if let loopFactory { loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                            router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                            print("model · \(Self.render(roleSelection.fallback)) · pinned · \(roleSelection.summary)")
                            continue
                        }
                        // Cancelled or not a TTY → show the catalog as before.
                        if autoRouting { print("model · \u{001B}[35mauto-routing\u{001B}[0m (kist picks per request) · /model <name> to pin") }
                        printModels(current: roleSelection.fallback)
                        continue
                    }
                    // /model auto → re-enable per-request routing. /model add → onboard a new model.
                    if modelArg.lowercased() == "auto" {
                        autoRouting = true
                        print("model · \u{001B}[35mauto-routing\u{001B}[0m on — kist picks the best model per request")
                        continue
                    }
                    if Self.isLocalModelAcquisitionRunIntent(command: "model", args: modelArg) {
                        let report = Self.handleLocalModelAcquisitionRunCommand(modelArg, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let marker = report.markerPath.map { " · marker: \($0)" } ?? ""
                        let verdict = report.outcome?.succeeded == true ? "passed" : "blocked"
                        print("\u{001B}[2m\(persisted)\(marker) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        continue
                    }
                    if Self.isLocalModelAcquisitionIntent(command: "model", args: modelArg) {
                        let report = Self.handleLocalModelAcquisitionCommand(modelArg, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision.accepted ? "verified" : "rejected"
                        print("\u{001B}[2m\(persisted) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        continue
                    }
                    if Self.isLiveModelMetadataGateIntent(command: "model", args: modelArg) {
                        let report = await Self.handleLiveModelMetadataGateCommand(modelArg, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        let verdict = report.decision?.accepted == true ? "accepted" : "rejected"
                        let manifest = report.acquisitionManifestPath.map { " · manifest: \($0)" } ?? ""
                        print("\u{001B}[2m\(persisted)\(manifest) · \(verdict) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        continue
                    }
                    if modelArg.lowercased() == "scout" || modelArg.lowercased().hasPrefix("scout ") {
                        let objective = modelArg.count > 5 ? String(modelArg.dropFirst(5)).trimmingCharacters(in: .whitespaces) : ""
                        let report = Self.handleLocalModelScoutCommand(objective, projectRoot: projectRoot)
                        print(report.text)
                        let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                        print("\u{001B}[2m\(persisted) · candidates: \(report.candidates.count) · seeded tasks: \(report.seededTasks) · memory: \(report.memoryRecords)\u{001B}[0m")
                        continue
                    }
                    if modelArg.lowercased() == "add" {
                        if let addModelFlow { await addModelFlow() } else { print("model add is unavailable here") }
                        continue
                    }
                    // /model import <url> → discover models at the URL, add a key, onboard, persist.
                    if modelArg.lowercased() == "import" || modelArg.lowercased().hasPrefix("import ") {
                        guard let importModelFlow else { print("model import is unavailable here"); continue }
                        let url = modelArg.count > 6 ? String(modelArg.dropFirst(6)).trimmingCharacters(in: .whitespaces) : ""
                        if let imported = await importModelFlow(url.isEmpty ? nil : url) {
                            print("model · imported '\(imported)' · restart kist to select it (it'll show green in /model)")
                        }
                        continue
                    }
                    guard let binding = Self.resolveModelSpec(modelArg, currentProvider: roleSelection.fallback.providerId,
                                                              knownProviders: providerAliases, providerModels: providerModels) else {
                        print("\u{001B}[31munknown model/provider '\(modelArg)'\u{001B}[0m — try bare /model for the catalog, /model auto, or /providers")
                        continue
                    }
                    if let error = roleSelection.setDefault(binding, knownProviders: providerAliases) {
                        print("\u{001B}[31m\(error)\u{001B}[0m")
                        continue
                    }
                    // Pinning a model turns OFF auto-routing — explicit user choice wins until /model auto.
                    autoRouting = false
                    activeBinding = roleSelection.fallback
                    // Rebuild the conversational loop on the new default; the unbound planner follows it,
                    // so rebuild the auto-router too.
                    if let loopFactory { loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                    print("model · \(Self.render(roleSelection.fallback)) · pinned · \(roleSelection.summary)")
                    continue
                case "reasoning":
                    // DISPLAY-only toggle: whether the reasoning stream is shown on screen.
                    let want: Bool
                    switch args.lowercased() {
                    case "on", "true", "1", "show": want = true
                    case "off", "false", "0", "hide": want = false
                    case "": want = !showReasoning
                    default: print("usage: /reasoning [on|off]"); continue
                    }
                    showReasoning = want
                    // INVARIANT: a settings-only change must PRESERVE the running model — rebuild from
                    // activeBinding, not the startup default (else an auto-routed model silently resets).
                    if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    print(want ? "reasoning · on" : "reasoning · off")
                    continue
                case "think", "thinking":
                    // EXTENDED THINKING: actually let the model reason before each action (vs the tight
                    // no-think loop). Turning it on also shows the reasoning so you can watch it; it's
                    // persisted to the replay either way.
                    let want: Bool
                    switch args.lowercased() {
                    case "on", "true", "1": want = true
                    case "off", "false", "0": want = false
                    case "": want = !extendedThinking
                    default: print("usage: /think [on|off]"); continue
                    }
                    extendedThinking = want
                    if want { showReasoning = true }
                    // INVARIANT: settings-only change ⇒ preserve the running model (rebuild from activeBinding).
                    if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    print(want ? "extended thinking · on (reasoning shown + replayed)" : "extended thinking · off")
                    continue
                case "config", "settings":
                    // Settings panel over .kist/settings.json (logic in KistREPL+SettingsCommands).
                    let outcome = Self.handleConfigCommand(args, projectRoot: projectRoot)
                    print(outcome.output)
                    if let r = outcome.reasoning {            // hot-apply the one live-changeable key
                        showReasoning = r
                        // INVARIANT: settings-only change ⇒ preserve the running model (rebuild from activeBinding).
                        if let loopFactory { loop = loopFactory(activeBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                    }
                    continue
                case "context", "ctx":
                    print(Self.handleContextCommand(transcript: transcript, projectRoot: projectRoot))
                    continue
                case "theme":
                    print(Self.handleThemeCommand(args, projectRoot: projectRoot))
                    continue
                case "skills":
                    print(Self.handleSkillsCommand(projectRoot: projectRoot))
                    continue
                case "mcp":
                    print(Self.handleMcpCommand(projectRoot: projectRoot))
                    continue
                case "hooks":
                    print(Self.handleHooksCommand(projectRoot: projectRoot))
                    continue
                case "permissions", "perms":
                    print(Self.handlePermissionsCommand(mode: perm.mode, sensitive: sensitiveTools,
                                                        editTools: editTools, projectRoot: projectRoot))
                    continue
                case "compact":
                    // Summarize the older transcript, keep recent turns verbatim. `transcript` IS the
                    // model-facing history (passed inout to l.turn), so this genuinely frees the window.
                    let keepRecent = 6
                    guard TranscriptCompactor.worthCompacting(transcript, keepRecent: keepRecent) else {
                        print("\u{001B}[2mnothing to compact yet — the conversation is still short\u{001B}[0m"); continue
                    }
                    guard let compactComplete else {
                        print("\u{001B}[2mcompaction unavailable (no model seam)\u{001B}[0m"); continue
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
                        print("\u{001B}[31mcompaction failed — transcript unchanged\u{001B}[0m"); continue
                    }
                    let freed = TranscriptCompactor.tokensFreed(summarize: toSummarize, summary: summary)
                    transcript = TranscriptCompactor.fold(summary: summary, keep: toKeep)
                    print("\u{001B}[32m🗜 compacted\u{001B}[0m · ~\(ContextReport.fmt(freed)) tokens freed · kept last \(toKeep.count) message(s)")
                    continue
                case "roles", "role", "team-roles":
                    guard let command = Self.parseRoleCommand(args) else {
                        print("usage: /roles [planner|worker|researcher|coder|builder|critic <provider[:model]>]  or  /roles save|load|delete <name>")
                        continue
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
                            continue
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
                        guard let roleProfiles else { print("\u{001B}[31mrole profiles unavailable\u{001B}[0m"); continue }
                        do {
                            try roleProfiles.save(RoleProfileStore.Profile(bindings: roleSelection.bindings), named: name)
                            print("roles · saved \(name) · \(roleSelection.summary)")
                        } catch {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                        }
                    case .load(let name):
                        guard let roleProfiles else { print("\u{001B}[31mrole profiles unavailable\u{001B}[0m"); continue }
                        do {
                            var next = roleSelection
                            let profile = try roleProfiles.profile(named: name)
                            if let error = next.apply(profile, knownProviders: providerAliases) {
                                print("\u{001B}[31m\(error)\u{001B}[0m")
                                continue
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
                        guard let roleProfiles else { print("\u{001B}[31mrole profiles unavailable\u{001B}[0m"); continue }
                        do {
                            let deleted = try roleProfiles.delete(named: name)
                            print(deleted ? "roles · deleted \(name)" : "roles · profile \(name) did not exist")
                        } catch {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                        }
                    case .profiles:
                        guard let roleProfiles else { print("role profiles: unavailable"); continue }
                        do {
                            let names = try roleProfiles.names()
                            print(names.isEmpty ? "role profiles: none" : "role profiles: " + names.joined(separator: ", "))
                        } catch {
                            print("\u{001B}[31m\(error)\u{001B}[0m")
                        }
                    }
                    continue
                case "fleet", "team", "swarm":
                    guard let fleet else { print("\u{001B}[31m/fleet isn't available here\u{001B}[0m"); continue }
                    guard let invocation = Self.parseFleetArgs(args, defaultAgents: defaultAgents) else {
                        print("usage: /fleet [--agents N|--agents=N] <goal>")
                        continue
                    }
                    await runHeavyRoute(goal: invocation.goal, intent: .fleet, mode: .fleet,
                                        execution: "fleet(\(invocation.agents))", startProof: true) {
                        await fleet(invocation.goal, invocation.agents, roleSelection.bindings)
                    }
                    continue
                case "bughunt", "monkey", "monkeybash", "hunt", "breakit":
                    // Real-life bug hunt / monkey-bash (Luke 2026-08-01): spin up a FLEET of isolated
                    // hunters (each its own sandbox/worktree, headless, spin up as many as needed) that
                    // actually RUN the target and try to BREAK it — reporting only reproduced failure points.
                    guard let fleet else { print("\u{001B}[31m/bughunt isn't available here\u{001B}[0m"); continue }
                    guard let inv = Self.parseFleetArgs(args, defaultAgents: max(3, defaultAgents)) else {
                        print("usage: /bughunt [--agents N] <app or target> — a fleet of isolated hunters runs it + tries to break it")
                        continue
                    }
                    print("\u{001B}[35m🐛 bug hunt · \(inv.agents) isolated hunters running + hammering: \(inv.goal)\u{001B}[0m")
                    let bugGoal = Self.bugHuntBrief(inv.goal)
                    await runHeavyRoute(goal: bugGoal, intent: .fleet, mode: .fleet,
                                        execution: "bughunt-fleet(\(inv.agents))", startProof: true) {
                        await fleet(bugGoal, inv.agents, roleSelection.bindings)
                    }
                    continue
                case "plan-execute", "pe", "dag":
                    guard let planExecute else { print("\u{001B}[31m/plan-execute isn't available here\u{001B}[0m"); continue }
                    guard !args.isEmpty else { print("usage: /plan-execute <goal>"); continue }
                    await runHeavyRoute(goal: args, intent: .build, mode: .planExecute,
                                        execution: "plan-execute", startProof: true) {
                        await planExecute(args, roleSelection.bindings)
                    }
                    continue
                case "build", "implement", "buildit", "ship-it", "makeit":
                    // THE BRIDGE from "here's the plan" to actually building it. `/build <goal>` fires the
                    // plan→execute worker (real code + build/tests), not another analysis turn. With NO
                    // args it BUILDS THE PLAN JUST PROPOSED — so after Kist lays out a plan you type
                    // `/build` and it executes it instead of researching forever. Compose with `/ultra`
                    // first for consensus review on the build.
                    guard let planExecute else { print("\u{001B}[31m/build isn't available here\u{001B}[0m"); continue }
                    let buildGoal: String
                    if !args.isEmpty {
                        buildGoal = Self.expandBoardReference(args, projectRoot: projectRoot,
                                                              sessionStartedAt: sessionStart)
                    } else {
                        let lastUser = humanTranscript.reversed().first { $0.role == .user }?.content
                        let lastPlan = humanTranscript.reversed().first { $0.role == .assistant }?.content
                        guard let lastUser else {
                            print("usage: /build <goal> — or run it right after a plan and it builds what was just proposed")
                            continue
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
                    continue
                case "council", "consult":
                    guard let council else { print("\u{001B}[31m/council isn't available here\u{001B}[0m"); continue }
                    guard let invocation = Self.parseCouncilArgs(args) else {
                        print("usage: /council [--execute|--build] <research/task>")
                        continue
                    }
                    let councilIntent: TaskBrief.Intent = invocation.execute ? .build : .plan
                    let councilMode: PromptCompiler.Mode = invocation.execute ? .planExecute : .inline
                    await runHeavyRoute(goal: invocation.goal, intent: councilIntent, mode: councilMode,
                                        execution: invocation.execute ? "council-execute" : "council",
                                        startProof: true) {
                        await council(invocation.goal, roleSelection.bindings, invocation.execute)
                    }
                    continue
                case "dig", "digdeep", "minds", "mind", "effort":
                    guard let digDeep else { print("\u{001B}[31m/dig isn't available here\u{001B}[0m"); continue }
                    guard !args.isEmpty else { print("usage: /dig (a.k.a. /effort) <question> — ask every reachable model in parallel and synthesize"); continue }
                    await runHeavyRoute(goal: args, intent: .review, mode: .inline,
                                        execution: "dig-in-deep", startProof: true) {
                        await digDeep(args, roleSelection.bindings)
                    }
                    continue
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
                    continue
                case "mode", "modes", "voice":
                    // Set HOW Kist talks: interaction mode / reading level / custom persona. Persisted.
                    let a = args.trimmingCharacters(in: .whitespaces)
                    func showMode() {
                        print("\u{001B}[36;1m/mode\u{001B}[0m \u{001B}[2m· current:\u{001B}[0m \(style.summary)")
                        print("\u{001B}[2m  interaction: conversation · science · build · friend · nobs · normal\u{001B}[0m")
                        print("\u{001B}[2m  reading level: /mode level <1..8 | highschool | college>\u{001B}[0m")
                        print("\u{001B}[2m  custom voice:  /mode persona <describe the partner you want>  (/mode persona off)\u{001B}[0m")
                    }
                    if a.isEmpty { showMode(); continue }
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
                        } else { print("\u{001B}[31musage: /mode level <1..8 | highschool | college>\u{001B}[0m"); continue }
                    case "persona", "personality":
                        if rest.isEmpty { print("usage: /mode persona <describe the partner you want>  (/mode persona off)"); continue }
                        if ["off", "none", "clear"].contains(rest.lowercased()) {
                            style.persona = nil; print("\u{001B}[32m✓ persona cleared\u{001B}[0m")
                        } else {
                            style.persona = rest; print("\u{001B}[32m✓ persona set\u{001B}[0m \u{001B}[2m· \(style.summary)\u{001B}[0m")
                        }
                    default:
                        if let m = ReplStyle.Mode.parse(a) {
                            style.mode = m; style.persona = nil       // picking a mode clears a custom persona
                            print("\u{001B}[32m✓ mode · \(m.rawValue)\u{001B}[0m \u{001B}[2m(\(style.summary))\u{001B}[0m")
                        } else { print("\u{001B}[31munknown mode '\(a)'\u{001B}[0m"); showMode(); continue }
                    }
                    style.save(projectRoot: projectRoot)
                    continue
                case "research", "deepdive", "sweep", "deep":
                    let researchGoal = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !researchGoal.isEmpty else {
                        print("usage: /research <goal> — evidence dossier → council → task board")
                        continue
                    }
                    // Keep research on the dedicated evidence pipeline. That path enforces the current
                    // ToolContext read grants, records its search/repo evidence, remains ESC/typeahead
                    // interruptible, runs the role-bound council, and seeds the durable task board.
                    // Never inject an in-process HOME/Volumes crawl into an ordinary model turn.
                    guard let research else {
                        print("\u{001B}[31m/research isn't available here\u{001B}[0m")
                        continue
                    }
                    print("\u{001B}[2m↳ evidence dossier → role-bound council → durable task board\u{001B}[0m")
                    await runHeavyRoute(goal: researchGoal, intent: .research, mode: .inline,
                                        execution: "research", startProof: true) {
                        await research(researchGoal, roleSelection.bindings)
                    }
                    continue
                case "competitive", "compete", "competitor", "vs":
                    // Point Kist at a competitor/URL/product and get a deep, cited R&D cross-comparison
                    // of OUR project vs theirs. Rides the /research evidence pipeline (web + our own
                    // estate sweep + council), framed as head-to-head competitive analysis.
                    guard let research else { print("\u{001B}[31m/competitive isn't available here\u{001B}[0m"); continue }
                    let target = args.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !target.isEmpty else {
                        print("usage: /competitive <competitor, product, or URL> — deep R&D cross-compare vs our project")
                        continue
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
                    continue
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
                    continue
                }
            }

            if let task = Self.taskSelectedByUser(input, projectRoot: projectRoot,
                                                  sessionStartedAt: sessionStart) {
                let taskPrompt = Self.executionBrief(for: task, userInput: input)
                _ = PlanStore(projectRoot: projectRoot).update(id: task.id, status: .inProgress)
                if let planExecute {
                    print("\u{001B}[37m↳ running task [\(task.id)] through plan→execute · \(roleSelection.summary)\u{001B}[0m")
                    await runHeavyRoute(goal: taskPrompt, intent: .build, mode: .planExecute,
                                        execution: "task-plan-execute", startProof: true) {
                        await planExecute(taskPrompt, roleSelection.bindings)
                    }
                } else {
                    proofStore?.startTurn(goal: taskPrompt)
                    armTurnLoop()   // arm the permission tier — never run a turn on a stale loop
                    let mode: PromptCompiler.Mode = perm.mode.isPlan ? .plan : .inline
                    let intent = PromptCompiler.inferIntent(taskPrompt, mode: mode)
                    proofStore?.record(.init(kind: .routeSelected, tool: nil, success: nil,
                                             text: "intent=\(intent.rawValue) outcome=\(PromptCompiler.expectedOutcome(intent: intent, mode: mode).rawValue) execution=task-inline"))
                    let compiled = briefCompiler?(taskPrompt, roleSelection.bindings, mode,
                                                  humanTranscript, intent) ?? taskPrompt
                    let enriched = attachCaptainContext(to: compiled, objective: taskPrompt)
                    let reviewBaseline = reviewBaselineIfArmed(intent: intent)
                    let oc = await runTurnInterruptible(loop: loop, userInput: enriched,
                                                        rawRequest: taskPrompt, resolvedIntent: intent)
                    rememberHumanTurn(user: taskPrompt, assistantSummary: oc.summary)
                    await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                    await runCopilotReview(task: taskPrompt, baselineDiff: reviewBaseline,
                                           turnIntent: intent, turnSucceeded: oc.success)
                    let completedTurn = recordVerificationAndFinal(outcome: oc, intent: intent)
                    selfMonitor(goal: taskPrompt, intent: intent, success: completedTurn)
                    await printTurnUsage()
                    recordSubmittedTurnLearning(outcomeSummary: oc.summary, success: completedTurn)
                    // LOOP FIX: a RESEARCH item is a single-shot digest-and-decide unit (see ManageTasksTool),
                    // yet a plain research answer never calls `tasks done`, so `plan.active` re-served the same
                    // research task on every 'next'/'continue' forever. When a research-kind driving task's turn
                    // succeeds and was not interrupted, auto-close it (+advance) so it can never be re-selected.
                    if task.kind == .research, completedTurn, !perm.mode.isPlan {
                        let store = PlanStore(projectRoot: projectRoot)
                        _ = store.update(id: task.id, appendEvidence: ["auto-closed after research turn: " + oc.summary.prefix(160)])
                        _ = store.completeAndAdvance(id: task.id, sessionStartedAt: sessionStart)
                    }
                }
                continue
            }

            // NATURAL-LANGUAGE AGENT CREATION: "make me an agent that reviews Swift UI" should forge a
            // specialist, same as `/agent new ...`, instead of becoming a generic chat prompt.
            if let specialistDescription = Self.parseForgeIntent(input) {
                guard let forge else { print("\u{001B}[31mforging isn't available here\u{001B}[0m"); continue }
                await forge(specialistDescription, roleSelection.bindings)
                continue
            }

            // NATURAL-LANGUAGE CONTROL: a plain sentence like "use DeepSeek as builder and Gemini as
            // critic" or "switch to gemini" mutates the RUNTIME (role/model bindings) BEFORE the turn —
            // so talking changes the system, not just the prompt. Conservative: only fires on an explicit
            // agent-introduction structure (won't touch "build a login page" / "research the gemini api").
            var messageBody = input
            // When the user explicitly names a model this turn ("ask deepseek …", "use claude"),
            // that pin must WIN — the auto-router below must not silently re-route it (e.g. a task
            // with reasoning keywords would otherwise flip "ask deepseek architect X" to a different
            // reasoning model). Set on an explicit .setModel intent; gates the autoRoute block.
            var userPinnedModelThisTurn = false
            if let intent = ControlIntentParser.parse(input, knownProviders: providerAliases) {
                switch intent.action {
                case .setModel(let binding):
                    userPinnedModelThisTurn = true
                    if let err = roleSelection.setDefault(binding, knownProviders: providerAliases) {
                        print("\u{001B}[31m\(err)\u{001B}[0m")
                    } else {
                        print("\u{001B}[37mmodel · \u{001B}[0m\u{001B}[36m\(Self.render(roleSelection.fallback))\u{001B}[0m")
                    }
                case .setRoles(let assignments):
                    for a in assignments {
                        if let err = roleSelection.assign(a.role, to: a.binding, knownProviders: providerAliases) {
                            print("\u{001B}[31m\(err)\u{001B}[0m")
                        }
                    }
                    print("\u{001B}[37mroles · \(roleSelection.summary)\u{001B}[0m")
                case .setting(let s):
                    switch s {
                    case .planMode(let on):
                        perm.set(on ? .plan : .normal)   // perm is the source of truth; armTurnLoop applies it
                        print(on ? "\u{001B}[33m⚑ plan mode ON — read-only\u{001B}[0m" : "\u{001B}[32m✓ plan mode OFF\u{001B}[0m")
                    case .reasoning(let on):
                        showReasoning = on
                        print("\u{001B}[37mreasoning · \(on ? "on" : "off")\u{001B}[0m")
                    }
                }
                // Preserve the CURRENTLY-RUNNING (possibly auto-routed) model across role/settings-only NL
                // intents; ONLY an explicit model-switch intent moves it. Rebuilding unconditionally from
                // roleSelection.fallback would reset an auto-routed model back to the default AND desync
                // activeBinding — both were Codex findings (2026-07-03). activeBinding stays the single
                // source of truth for "the model the loop is running".
                let isModelSwitch: Bool = { if case .setModel = intent.action { return true }; return false }()
                let rebuildBinding = isModelSwitch ? roleSelection.fallback : activeBinding
                if let loopFactory { loop = loopFactory(rebuildBinding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking) }
                activeBinding = rebuildBinding
                router = routerFactory?(roleSelection.bindings.binding(for: .planner)) ?? router
                if intent.isControlOnly { continue }          // pure directive → applied; wait for the task
                // A team was named AND a task given → run it as a team (plan→execute) so the roles are
                // actually USED — a normal turn would only use the default model. Model-only → normal turn.
                if case .setRoles = intent.action, let planExecute {
                    let routedTask = Self.expandBoardReference(intent.residualTask, projectRoot: projectRoot,
                                                               sessionStartedAt: sessionStart)
                    print("\u{001B}[37m↳ running as your team (plan→execute) · \(roleSelection.summary)\u{001B}[0m")
                    await runHeavyRoute(goal: routedTask, intent: .build, mode: .planExecute,
                                        execution: "team-plan-execute", startProof: true) {
                        await planExecute(routedTask, roleSelection.bindings)
                    }
                    continue
                }
                messageBody = Self.expandBoardReference(intent.residualTask, projectRoot: projectRoot,
                                                        sessionStartedAt: sessionStart)
            }

            if let request = Self.selfCodebaseAuditRequest(messageBody, currentProjectRoot: projectRoot) {
                print("\u{001B}[37m↳ self-codebase audit · \(request.projectRoot)\u{001B}[0m")
                let report = CaptainImmuneSystem(projectRoot: request.projectRoot)
                    .run(seedRepairs: request.seedRepairs, trajectory: recorder?.snapshot() ?? [])
                print(report.text)
                let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
                let mission = report.selfHealPath.map { " · self-heal: \($0)" } ?? ""
                let simulation = report.simulationPath.map { " · simulation: \($0)" } ?? ""
                print("\u{001B}[2m\(persisted) · status: \(report.status.rawValue) · self-test: \(report.selfTestPath)\(mission)\(simulation) · seeded tasks: \(report.seededTasks)\u{001B}[0m")
                continue
            }

            if Self.isLegalResearchIntent(messageBody) {
                await runLegalResearchCommand(messageBody, forceResearch: false)
                continue
            }

            switch Self.handleDocumentExportRequest(messageBody,
                                                    humanTranscript: humanTranscript,
                                                    projectRoot: projectRoot) {
            case .notDocumentExport:
                break
            case .handled(let exportMessage):
                print(exportMessage)
                continue
            case .failed(let reason):
                print("\u{001B}[31mdocument export failed: \(reason)\u{001B}[0m")
                await openFailureAnalysis(goal: messageBody,
                                          summary: "document export failed: \(reason)",
                                          automaticRepair: true)
                continue
            }

            // MULTIMODAL: lift any dragged-in media paths out of the line into attachments. When the
            // active model can't see, borrow a vision provider for just this turn (disclosed), then
            // hand control back. Drag a photo / clip / sound file in → the AI actually sees/hears it.
            proofStore?.startTurn(goal: messageBody)
            let media = MediaResolver.resolve(messageBody, projectRoot: projectRoot)
            let touchedMedia = !media.attachments.isEmpty || !media.uploads.isEmpty || !media.notes.isEmpty
            for note in media.notes { print("\u{001B}[37m↳ \(note)\u{001B}[0m") }
            // Big/long media (video, >20MB) goes through the Gemini Files API first (Phase 2).
            var attachments = media.attachments
            if !media.uploads.isEmpty {
                if let uploadMedia {
                    attachments.append(contentsOf: await uploadMedia(media.uploads))
                } else {
                    print("\u{001B}[31m↳ \(media.uploads.count) large file(s) need the Gemini Files API but no Gemini key is set — skipped\u{001B}[0m")
                }
            }
            if !attachments.isEmpty {
                await runMediaTurn(attachments, prompt: media.prompt)
                await printTurnSummary()
                continue
            }
            // The message a normal turn acts on: path-stripped if we touched media, else the (possibly
            // control-stripped) message body.
            var messageText = touchedMedia ? media.prompt : messageBody

            // R4: natural-language TEAM assignment. "gemini be the eyes for deepseek", "deepseek codes
            // and gemini reviews", "work as a team to X" → arm the coder(lead)+reviewer(co) partnership
            // + review→fix loop, then run the residual task. No team phrasing ⇒ nil ⇒ a normal turn.
            var armedTeamThisTurn = false
            if !lineFromQueue, let team = TeamIntent.parse(messageText) {
                armTeam(team)
                armedTeamThisTurn = true
                messageText = team.goal
                if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }  // pure setup
            }
            // Resolve semantics once from the raw, current request. Routing, prompt compilation, the
            // headless progress governor, monitoring, and replay all consume this same value.
            let turnMode: PromptCompiler.Mode = perm.mode.isPlan ? .plan : .inline
            let turnIntent = PromptCompiler.inferIntent(messageText, mode: turnMode)

            // AUTO-ROUTE (Increment B): for a plain message, the router may PROPOSE an escalation to a
            // fleet / plan-DAG / research pass / council. It never spends big silently — we confirm first; a no falls through to a
            // normal turn. Slash commands above are the explicit path; this is the "just talk" path.
            // A team goal runs as a team-armed turn so the coder↔reviewer review→fix loop actually
            // fires — an accepted fleet/plan escalation would `continue` past runCopilotReview and drop
            // the partnership the user just asked for (review catch).
            // "Dig in deep" / "consult the minds": an explicit ask to hear from EVERY reachable model, not
            // one model answering (and re-answering) alone. Fires only on the narrow phrase set, so a normal
            // message is never hijacked; runs before the router so it isn't shadowed by a research proposal.
            if let digDeep, !lineFromQueue, AICouncil.looksLikeDigDeep(messageText) {
                await runHeavyRoute(goal: messageText, intent: turnIntent, mode: turnMode,
                                    execution: "dig-in-deep", startProof: false) {
                    await digDeep(messageText, roleSelection.bindings)
                }
                continue
            }
            // ACTION-FIRST (Luke 2026-08-02): a clear BUILD request fires the plan→execute WORKER, not an
            // inline chat turn that just analyzes. Research-first was the disease — Kist produced perfect
            // plans and never built them. Only for an explicit build intent, not in plan mode, not a
            // team/queued line. The worker's edits stay approval-gated; /plan (or "just plan …") keeps it
            // read-only. This is the main-turn half of the "stop researching, start building" contract.
            if turnIntent == .build, turnMode != .plan, !armedTeamThisTurn, !lineFromQueue, let planExecute {
                print("\u{001B}[36;1m🔨 build\u{001B}[0m\u{001B}[2m · action-first: firing the plan→execute worker (edits still ask; /plan for read-only)\u{001B}[0m")
                await runHeavyRoute(goal: messageText, intent: .build, mode: .planExecute,
                                    execution: "build", startProof: false) {
                    await planExecute(messageText, roleSelection.bindings)
                }
                await printTurnSummary()
                continue
            }
            let routingWasInterrupted = MutableBox(false)
            var routeProposal: ConversationRouter.Proposal?
            if let router, !lineFromQueue, !armedTeamThisTurn {
                routeProposal = await InterruptibleTurn.run(onInterrupt: { reason in
                    routingWasInterrupted.value = true
                    if reason == .cancel { TurnInputQueue.shared.clearAll() }
                    else { TurnInputQueue.shared.commitPending() }
                    print("\n\u{001B}[33m"
                          + (reason == .cancel ? "⎋⎋ routing cancelled" : "⎋ routing interrupted — your turn")
                          + "\u{001B}[0m")
                }) {
                    await router.propose(messageText, resolvedIntent: turnIntent)
                }
            }
            if routingWasInterrupted.value { continue }
            if let proposal = routeProposal {
                FileHandle.standardOutput.write(Data(("\u{001B}[33m" + proposal.prompt + " \u{001B}[0m").utf8))
                let ans = StdinArbiter.shared.withStdin {
                    (readLine(strippingNewline: true) ?? "")
                        .trimmingCharacters(in: .whitespaces).lowercased()
                }
                if ans == "y" || ans == "yes" {
                    switch proposal.route {
                    case .fleet(let agents):
                        await runHeavyRoute(goal: messageText, intent: turnIntent, mode: turnMode,
                                            execution: "fleet(\(agents))", startProof: false) {
                            guard let fleet else { return unavailableHeavyRoute("fleet") }
                            return await fleet(messageText, agents, roleSelection.bindings)
                        }
                    case .planExecute:
                        await runHeavyRoute(goal: messageText, intent: turnIntent, mode: turnMode,
                                            execution: "plan-execute", startProof: false) {
                            guard let planExecute else { return unavailableHeavyRoute("plan-execute") }
                            return await planExecute(messageText, roleSelection.bindings)
                        }
                    case .council:
                        await runHeavyRoute(goal: messageText, intent: turnIntent, mode: turnMode,
                                            execution: "council", startProof: false) {
                            guard let council else { return unavailableHeavyRoute("council") }
                            return await council(messageText, roleSelection.bindings, false)
                        }
                    case .research:
                        await runHeavyRoute(goal: messageText, intent: turnIntent, mode: turnMode,
                                            execution: "research", startProof: false) {
                            guard let research else { return unavailableHeavyRoute("research") }
                            return await research(messageText, roleSelection.bindings)
                        }
                    }
                    continue
                }
                // declined → handle inline as an ordinary turn.
            }

            // AUTO MODEL ROUTING: unless a model is pinned, pick the best one for THIS request (cheap
            // heuristic). Only rebuild the loop when the routed model actually changes, and disclose it.
            if autoRouting, !userPinnedModelThisTurn, let autoRoute {
                let decision = autoRoute(messageText, false, activeBinding)
                if decision.binding != activeBinding {
                    if let loopFactory {
                        loop = loopFactory(decision.binding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking)
                    }
                    activeBinding = decision.binding
                }
                if Self.stdoutColorEnabled(projectRoot: projectRoot) {
                    print("\u{001B}[2m↳ 🧭 routed to \u{001B}[0m\u{001B}[94;1m\(Self.render(decision.binding))\u{001B}[0m\u{001B}[2m (\(decision.reason))\u{001B}[0m")
                } else {
                    print("↳ routed to \(Self.render(decision.binding)) (\(decision.reason))")
                }
            }

            armTurnLoop()   // apply the permission tier (plan/approvals); confirm bypass if just armed
            proofStore?.record(.init(kind: .routeSelected, tool: nil, success: nil,
                                     text: "intent=\(turnIntent.rawValue) outcome=\(PromptCompiler.expectedOutcome(intent: turnIntent, mode: turnMode).rawValue) execution=inline model=\(Self.render(activeBinding))"))
            let compiled = briefCompiler?(messageText, roleSelection.bindings, turnMode,
                                          humanTranscript, turnIntent) ?? messageText
            if let display = personaDisplay?(messageText) { print(Self.stdoutColorEnabled(projectRoot: projectRoot) ? "\u{001B}[95;1m🎭 \(display)\u{001B}[0m" : "↳ \(display)") }
            var enriched = attachCaptainContext(to: compiled, objective: messageText)
            // STYLE (`/mode`): prepend the requested voice — interaction mode / reading level / custom
            // persona — so the model actually adopts it for this reply.
            if let styleDirective = style.directive() { enriched = styleDirective + "\n\n" + enriched }
            // AUTO-EXPLORE: a lookup/find/self question ("find what we did for tinkyspeak", "how does your
            // X work") is answered from OUR OWN FILES, not the model's memory. Search the estate in-process
            // (full FS read, bypassing the tool sandbox) and inject what we find so the model stops
            // hallucinating about work it can't see. Fail-soft: no hits ⇒ a normal answer.
            if EstateLookupIntent.matches(messageText) {
                let search = EstateSearch()
                let mt = messageText
                print("\u{001B}[35m🔎 searching our files for context…\u{001B}[0m")
                let searchTask = Task.detached(priority: .userInitiated) {
                    search.groundingBlock(for: mt)
                }
                let searchInterrupted = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
                let grounding = await InterruptibleTurn.run(onInterrupt: { reason in
                    searchInterrupted.value = reason
                    if reason == .cancel { TurnInputQueue.shared.clearAll() }
                    else { TurnInputQueue.shared.commitPending() }
                    print("\n\u{001B}[33m"
                          + (reason == .cancel ? "⎋⎋ file search cancelled" : "⎋ file search interrupted — your turn")
                          + "\u{001B}[0m")
                }) {
                    await withTaskCancellationHandler(operation: {
                        await searchTask.value
                    }, onCancel: {
                        searchTask.cancel()
                    })
                }
                if searchInterrupted.value != nil { continue }
                if let grounding {
                    let n = max(0, grounding.components(separatedBy: "\n### ").count - 1)
                    print("\u{001B}[35m🔎 grounded in \(n) file(s) from our estate\u{001B}[0m")
                    enriched = grounding + "\n\n" + enriched
                } else {
                    print("\u{001B}[37m🔎 no matching files — answering from general knowledge\u{001B}[0m")
                }
            }
            let transcriptBeforeModelAttempt = transcript
            let reviewBaseline = reviewBaselineIfArmed(intent: turnIntent)
            var turnAuthor = activeBinding
            var oc = await runTurnInterruptible(loop: loop, userInput: enriched,
                                                rawRequest: messageText, resolvedIntent: turnIntent)
            if let loopFactory,
               !lastTurnInterrupted,   // R2a: never re-run a turn the USER stopped (their queued instruction runs next)
               let substitution = Self.modelSubstitutionDecision(success: oc.success,
                                                                 summary: oc.summary,
                                                                 trajectory: recorder?.snapshot() ?? [],
                                                                 current: activeBinding,
                                                                 roles: roleSelection.bindings,
                                                                 providerHasKey: providerHasKey,
                                                                 providerModels: providerModels) {
                print("\u{001B}[33m↳ model substitution\u{001B}[0m · \(Self.render(substitution.current)) benched for \(substitution.reason); trying \(Self.render(substitution.replacement)) for this turn")
                transcript = transcriptBeforeModelAttempt
                archiveCurrentEvidencePhase()
                let replacementLoop = perm.arm(loopFactory(substitution.replacement,
                                                           roleSelection.bindings,
                                                           perm.mode.isPlan,
                                                           showReasoning,
                                                           extendedThinking))
                turnAuthor = substitution.replacement
                oc = await runTurnInterruptible(loop: replacementLoop, userInput: enriched,
                                                rawRequest: messageText, resolvedIntent: turnIntent)
            }
            rememberHumanTurn(user: messageText, assistantSummary: oc.summary)
            await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
            // Opt-in second opinion: ordinary Q&A returns one canonical answer unless the user armed review.
            await runCopilotReview(task: messageText, answer: oc.summary, allowAdvisory: true,
                                   authoredBy: turnAuthor, baselineDiff: reviewBaseline,
                                   turnIntent: turnIntent, turnSucceeded: oc.success)
            let completedTurn = recordVerificationAndFinal(outcome: oc, intent: turnIntent)
            selfMonitor(goal: messageText, intent: turnIntent, success: completedTurn)
            await printTurnUsage()
            recordSubmittedTurnLearning(outcomeSummary: oc.summary, success: completedTurn)
        }
    }
}
