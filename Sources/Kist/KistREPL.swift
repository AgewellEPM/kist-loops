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
    /// Resume one exact PLAN→EXECUTE mission. Kept separate so every existing build route stays fresh.
    var resumePlanExecute: ((_ missionID: PlanExecuteMissionID, _ goal: String,
                            _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// Run an AI council (researcher -> architect -> coder -> critic -> UX -> memory -> final board).
    var council: ((_ goal: String, _ roles: RoleBindings, _ execute: Bool) async -> HeavyRouteResult)? = nil
    /// "Dig in deep" / "consult the minds": ask EVERY reachable model the same question in parallel and
    /// synthesize agree/disagree — the multi-model second opinion, instead of one model answering alone.
    var digDeep: ((_ goal: String, _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// Run an evidence-first research pass, feed the dossier to council, and seed the shared board.
    var research: ((_ goal: String, _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// `/dive` — a LOCAL, repo-scoped multi-model read of OUR OWN code (no web, no cross-repo estate sweep).
    /// Grounds a dossier in the actual files under the project root, then fans it to every reachable model.
    var dive: ((_ goal: String, _ roles: RoleBindings) async -> HeavyRouteResult)? = nil
    /// `/evolve <brief>` — on-demand, transparent proof of the closed evolution loop: author a self__ tool,
    /// gate + symbolic-veto + independent-adversary it, activate only on surviving all. Prints the artifacts.
    var evolve: ((_ brief: String) async -> Int32)? = nil
    /// `/ablation` — run the COLD-vs-WARM ablation oracle: is the accumulated state actually compounding on
    /// held-out work? Reports an un-fakeable advantage that can be flat or negative.
    var ablation: ((_ corpus: String) async -> Int32)? = nil
    /// `/advise` — convene the best-matching advisor persona (dynamic-advisor A1.5): reads the task's domain,
    /// runs the matched expert isolated + READ-ONLY, prints its advice with provenance + a regulated disclaimer.
    var advise: ((_ task: String) async -> Void)? = nil
    /// Forge a specialist from a plain-English role description (AgentForge), bounded by the loop's tool
    /// ceiling, validated, and saved to the registry. nil = forging unavailable in this mode.
    var forge: ((_ description: String, _ roles: RoleBindings) async -> Void)? = nil
    /// The Captain's deterministic model pick for a Captain-driven turn (`/fix`): the STRONGEST reachable
    /// frontier provider (keyed cloud + subscription hitters), NEVER a known-weak/dead one (MiMo, cold
    /// local endpoints). Returns nil when the session is ALREADY on the strongest — no needless override.
    /// Set by the runner (which holds the registry). This is the scoped, opt-in first step of "the Captain
    /// decides what model to call" — it does NOT change the global per-turn router.
    var captainStrongRoles: (@Sendable () -> RoleBindings?)? = nil
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
    /// Run the GOLDEN eval suite (regression gate): replay the fixed task set, score, compare to baseline.
    var runEvalSuite: (() async -> Void)? = nil
    /// Auto-capture a durable lesson into SEMANTIC (vector) memory on a verified win, so a future session
    /// can recall it. nil when no embedder is configured. Fail-soft — never blocks or throws into a turn.
    var rememberLesson: (@Sendable (_ text: String) async -> Void)? = nil
    /// A configured vision-capable provider to borrow for media turns when the active model can't see
    /// (nil if none is configured). Set by the runner to e.g. "gemini" when its key is present.
    var visionProviderId: String? = nil
    /// Ordered vision-capable fallback lane for media turns (preferred engine first — normally
    /// `visionProviderId` at index 0). The media reroute walks this list, skipping providers in live
    /// cooldown, so one rate-limited vision engine no longer kills every media turn.
    var visionProviderCandidates: [String] = []
    /// Cross-process live-failure state (ProviderCooldownStore): is this provider currently cooling
    /// down after a rate limit/outage another kist process observed? nil = no knowledge (not cooling).
    var providerCoolingDown: ((String) -> Bool)? = nil
    /// Bench a provider cross-process after a live transient failure so one-shot lanes and future
    /// sessions don't walk into the same wall. nil = no-op (tests / minimal wiring).
    var recordProviderCooldown: ((String) -> Void)? = nil
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
    var chainServer: ChainServer?              // /chain — the local automation-builder web server (kept alive for the session)
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
                    setBracketedPasteMode: setBracketedPasteMode,
                    onInterruptUnavailable: {
                        if self.stickyTurnsEnabled, promptWasPinned { self.pinnedBar.suspend() }
                        let warning = "warning: keyboard interrupt unavailable for this turn; provider liveness timeout remains active\n"
                        FileHandle.standardError.write(Data(warning.utf8))
                    })
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

                switch await handleSlashCommand(name: name, args: args, input: input) {
                case .handled: continue
                case .exit: return
                }
            }

            if let task = Self.taskSelectedByUser(input, projectRoot: projectRoot,
                                                  sessionStartedAt: sessionStart) {
                if Self.isSimulationRemediationTask(task) {
                    print("\u{001B}[37m↳ running simulation remediation task [\(task.id)] directly · plan→execute bypassed\u{001B}[0m")
                    print(Self.runSimulationRemediationTask(
                        task,
                        projectRoot: projectRoot,
                        trajectory: recorder?.snapshot() ?? []))
                    continue
                }
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

            // NATURAL-LANGUAGE SANDBOX CONTROL: "run it headless" / "run it in a small window at the
            // top of my screen" drive the isolated macOS-guest sandbox (~/bin/vmsandbox) directly —
            // deterministic device command, no LLM turn. Conservative parser; see SandboxIntent.
            if let sandbox = SandboxIntent.parse(input) {
                SandboxIntent.execute(sandbox)
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
            // A transient live failure (rate limit / outage) benches this provider CROSS-PROCESS
            // even when no substitute exists — one-shot lanes and future sessions must not walk
            // into the same wall (parity with KistRunner+OneShotResilience, 2026-08-14).
            if !oc.success, !lastTurnInterrupted, Self.transientProviderFailure(summary: oc.summary) {
                recordProviderCooldown?(activeBinding.providerId)
            }
            if let loopFactory,
               !lastTurnInterrupted,   // R2a: never re-run a turn the USER stopped (their queued instruction runs next)
               let substitution = Self.modelSubstitutionDecision(success: oc.success,
                                                                 summary: oc.summary,
                                                                 trajectory: recorder?.snapshot() ?? [],
                                                                 current: activeBinding,
                                                                 roles: roleSelection.bindings,
                                                                 // Cooldown-gated: never substitute onto a provider
                                                                 // another kist process just watched fail live.
                                                                 providerHasKey: { [providerCoolingDown, providerHasKey] pid in
                                                                     guard providerCoolingDown?(pid) != true else { return false }
                                                                     return providerHasKey?(pid) ?? true
                                                                 },
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
