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
struct KistREPL {
    let loop: HeadlessAgentLoop
    let commands: KistCommands
    /// Escalate to a SUPERVISED FLEET from inside the conversation (nil when unavailable, e.g. resume).
    var fleet: ((_ goal: String, _ agents: Int, _ roles: RoleBindings) async -> Void)? = nil
    /// Escalate to PLAN→EXECUTE (a typed DAG built by the team) from inside the conversation.
    var planExecute: ((_ goal: String, _ roles: RoleBindings) async -> Void)? = nil
    /// Run an AI council (researcher -> architect -> coder -> critic -> UX -> memory -> final board).
    var council: ((_ goal: String, _ roles: RoleBindings, _ execute: Bool) async -> Void)? = nil
    /// "Dig in deep" / "consult the minds": ask EVERY reachable model the same question in parallel and
    /// synthesize agree/disagree — the multi-model second opinion, instead of one model answering alone.
    var digDeep: ((_ goal: String, _ roles: RoleBindings) async -> Void)? = nil
    /// Run an evidence-first research pass, feed the dossier to council, and seed the shared board.
    var research: ((_ goal: String, _ roles: RoleBindings) async -> Void)? = nil
    /// Forge a specialist from a plain-English role description (AgentForge), bounded by the loop's tool
    /// ceiling, validated, and saved to the registry. nil = forging unavailable in this mode.
    var forge: ((_ description: String, _ roles: RoleBindings) async -> Void)? = nil
    /// The intent router (Increment B): classify a plain message as chat|build|plan|fleet and PROPOSE an
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
    var briefCompiler: ((_ input: String, _ roles: RoleBindings, _ mode: PromptCompiler.Mode, _ transcript: [ChatMessage]) -> String)? = nil
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

    func run() async {
        // Captured at session start so the status line can tell a plan THIS session is working
        // from a stale plan a prior session (or a council seed) left on disk — see PlanStatusVisibility.
        let sessionStart = Date()
        var loop = self.loop   // mutable local: /plan toggles plan mode on the held loop
        // The interactive permission tier (shift+tab bar). Source of truth for plan-mode + approvals;
        // applied to `loop` before each turn via armTurnLoop(). See PermissionController.
        var perm = PermissionController(mode: initialPermissionMode, sensitive: sensitiveTools, edit: editTools)
        var roleSelection = self.roleSelection
        var router = self.router
        var autoRouting = self.autoRouting   // /model pins (off) · /model auto re-enables
        var extendedThinking = loop.isExtendedThinking   // --think default; /think toggles it on the held loop
        var showReasoning = loop.isExtendedThinking      // launched with --think ⇒ show reasoning (stays consistent across /model rebuilds)
        var usageSnapshot: [AgentSpan] = []
        // The model the conversation is currently talking to. In auto mode it changes per turn as the
        // heuristic routes; pinning with /model fixes it. Drives the loop rebuild + the routed banner.
        var activeBinding = roleSelection.fallback
        let headerMode = autoRouting ? "auto-routing"
            : (TeamLanguage.describeTeam(roleSelection.bindings)
               ?? Self.render(roleSelection.fallback))
        print(StartupHeader.render(mode: headerMode, projectRoot: projectRoot, planMode: loop.isPlanMode))
        if loop.isPlanMode { print("\u{001B}[33m⚑ plan mode ON — read-only; the agent proposes a plan. /plan off to execute.\u{001B}[0m") }
        // R2b: pin the input panel to the bottom (scroll-region). Activated AFTER the header so the
        // header lands in normal scrollback; deactivated on EVERY exit path so the shell is never left
        // with a stuck region. When disabled/non-TTY the leads below are byte-identical to the old inline box.
        let pinnedBar = PinnedBar(enabled: pinnedBarEnabled)
        pinnedBar.activate()
        defer { pinnedBar.deactivate() }
        var transcript: [ChatMessage] = []
        var humanTranscript: [ChatMessage] = []
        let inputReader = EnhancedPromptReader()
        var cachedSymbols: [String]?
        var clipboardVisionApprovedForSession = autoApproveClipboardVision
        var currentPersona = "captain"   // personality layer; professional default, /persona to switch
        var copilot = CopilotConfig()    // /copilot: auto second-AI review of the diff after a coding turn
        // Show the "this terminal can't render inline images" hint at most once per session, so a
        // user on Terminal.app (no inline-image protocol) isn't left thinking the drop silently broke.
        var noInlinePreviewHintShown = false

        func rememberHumanTurn(user: String, assistantSummary: String) {
            humanTranscript.append(ChatMessage(role: .user, content: user))
            if !assistantSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                humanTranscript.append(ChatMessage(role: .assistant, content: assistantSummary))
            }
            if humanTranscript.count > 20 { humanTranscript = Array(humanTranscript.suffix(20)) }
        }

        // Apply the active permission tier to `loop` right before a turn runs. If the user shuffled onto
        // bypass (guards off), confirm ONCE this session with a typed y/N before it takes effect — a
        // declined confirm drops to normal. Cycling the bar never arms guards-off by itself.
        func armTurnLoop() {
            if perm.needsBypassConfirm {
                FileHandle.standardOutput.write(Data("\u{001B}[31;1m⚠ Arm bypass permissions (guards OFF)? Skips ALL approval prompts this session. (y/N) \u{001B}[0m".utf8))
                let ans = StdinArbiter.shared.withStdin {
                    (Swift.readLine(strippingNewline: true) ?? "")
                        .trimmingCharacters(in: .whitespaces).lowercased()
                }
                if ans == "y" || ans == "yes" {
                    perm.confirmBypass()
                    print("\u{001B}[31;1m⚠ bypass armed — guards off for this session (shift+tab to leave)\u{001B}[0m")
                } else {
                    perm.declineBypass()
                    print("\u{001B}[37m↳ staying in normal mode (approvals on)\u{001B}[0m")
                }
            }
            loop = perm.arm(loop)
        }

        // R1: set by runTurnInterruptible when ESC stopped the turn; selfMonitor consults + resets
        // it so a user interrupt never books a false "task failed" obstacle lesson.
        var lastTurnInterrupted = false

        // Preserve the exact report shown by the last completed turn. The recorder is reset before
        // slash-command dispatch, so rebuilding `/confidence` from it would always explain an empty turn.
        var lastConfidenceReport: ConfidenceReport?

        // The SINGLE safe path for every conversational turn: run it under the esc-interrupt watcher,
        // shuttling the inout transcript through a box (it can't cross the escaping work closure). The
        // caller MUST arm the loop first (armTurnLoop / perm.arm) — this is why direct `loop.turn(...)`
        // calls are forbidden: a stale guards-off loop could otherwise run a /command or task turn after
        // the user left bypass (Codex CRITICAL). Source-pinned: the only `.turn(transcript:` is here.
        func runTurnInterruptible(loop l: HeadlessAgentLoop, userInput: String,
                                  attachments: [MediaAttachment] = []) async -> HeadlessAgentLoop.Outcome {
            let preTurnTranscript = transcript
            let tBox = MutableBox(transcript)
            lastTurnInterrupted = false   // fresh turn; post-turn guards read it, next turn resets it
            // Collection is session-wide (submit → routing → model → post-review). InterruptibleTurn
            // borrows that session's one watcher and only registers this active model task.
            // R1: single ESC = interject (take over, work stays resumable); double ESC = hard
            // cancel (transcript restored + checkpoint marked ABANDONED — kept on disk so a
            // panic ESC-hammer is never irreversible, but hidden from --list/--resume-last).
            let reasonBox = MutableBox<InterruptibleTurn.InterruptReason?>(nil)
            let oc = await InterruptibleTurn.run(onInterrupt: { reason in
                reasonBox.value = reason
                switch reason {
                case .interject:
                    print("\n\u{001B}[33m⎋ interrupted — stopping after the current step; your turn (progress saved)\u{001B}[0m")
                case .cancel:
                    print("\n\u{001B}[33m⎋⎋ cancelled — dropping this turn\u{001B}[0m")
                }
            }) {
                var t = tBox.value
                let outcome = await l.turn(transcript: &t, userInput: userInput, attachments: attachments)
                tBox.value = t
                return outcome
            }
            // "Dropping this turn" must MEAN dropped: on cancel the cancelled turn's user message +
            // partial output must not keep colouring future context (review catch).
            transcript = (reasonBox.value == .cancel) ? preTurnTranscript : tBox.value
            lastTurnInterrupted = reasonBox.value != nil
            // R2a: interject = what you typed IS the next instruction (queued + drained right
            // away); hard cancel = typed + queued input is dropped with the turn.
            switch reasonBox.value {
            case .interject: TurnInputQueue.shared.commitPending()
            case .cancel:    TurnInputQueue.shared.clearAll()
            case nil:        break
            }
            if reasonBox.value == .cancel, !oc.success, !oc.checkpointId.isEmpty {
                LoopCheckpointStore().abandon(id: oc.checkpointId)
            }
            if reasonBox.value == .interject, !oc.success, !oc.checkpointId.isEmpty {
                print("\u{001B}[2m· paused — resume later with: kist --resume \(oc.checkpointId)\u{001B}[0m")
            }
            return oc
        }

        func retrievalContext(for objective: String) -> CaptainRetrievalContext? {
            let clean = objective.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let evidence = CaptainProjectEvidence.capture(projectRoot: projectRoot)
            let specialists = SpecialistRegistry(projectRoot: projectRoot).load()
            let strategy = CaptainStrategist.plan(objective: clean,
                                                  evidence: evidence,
                                                  specialists: specialists)
            return OrganizationalLearningStore(projectRoot: projectRoot)
                .retrievalContext(objective: clean, strategy: strategy, limit: 6)
        }

        func attachCaptainContext(to compiled: String, objective: String) -> String {
            // SELF-AWARENESS: the Captain must always know WHAT IT IS. Without this, a bare
            // "assess this system" gets a generic "what system do you mean?" — because the model has
            // no sense of self. Injected on every turn so "this system / you / yourself / kist" is never
            // ambiguous, and self-assessment reads its OWN source instead of asking clarifying questions.
            var out = kistSelfContext() + "\n\n" + compiled
            if let retrieval = retrievalContext(for: objective) {
                print("\u{001B}[37m↳ Captain retrieval · \(retrieval.retrieved.count) memory · \(retrieval.decisionCards.count) decision cards\u{001B}[0m")
                out = Self.attachCaptainRetrievalContext(to: out, retrieval: retrieval)
            }
            return out
        }

        /// Kist's sense of self — who it is, where its own code lives, and that self-referential words
        /// mean IT. Concise on purpose (a few sentences); it rides every turn so the Captain never loses
        /// the thread of its own identity.
        func kistSelfContext() -> String {
            """
            [WHO YOU ARE — read before answering]
            You are Kist: an autonomous coding + research Captain that orchestrates models, tools, a \
            research/discovery loop, an AI council of specialists, durable memory, and a worker fleet. \
            You are NOT a generic chat assistant. Your OWN source code (Swift) lives at \
            /Volumes/PRO-G40/kist-loops. Right now you are operating in the project: \(projectRoot).
            When the operator says "this system", "yourself", "you", "your code", "the captain", or \
            "kist", they mean YOU — Kist. Never answer a question about yourself with "what system do \
            you mean". To assess or improve yourself, READ your own source under /Volumes/PRO-G40/kist-loops \
            (list_files / read_file), take stock of your capabilities (/code, /research, /council, \
            /fleet, /model, local Qwen + cloud models, memory/retrieval), then give a concrete grounded \
            verdict — real strengths, honest gaps, and the single highest-value next move. Operator TASKS \
            (build/fix/edit) still act on the current project above; only questions about YOURSELF read \
            your own source.
            """
        }

        // Send a turn that carries media, routing to a vision model. Images go to any vision model;
        // video/audio + Gemini file refs are Gemini-only, so we borrow Gemini (disclosed) unless the
        // active model already is it. Shared by the drag-a-path and clipboard /paste flows.
        func runMediaTurn(_ atts: [MediaAttachment], prompt: String) async {
            // Inline image protocols (OSC/APC), ANSI previews, and binary/fullscreen media renderers
            // must own a normal terminal. Abandon sticky capture before emitting even the first byte.
            pinnedBar.suspend()
            armTurnLoop()
            if let preview = TerminalMediaRenderer.preview(attachments: atts) {
                FileHandle.standardOutput.write(Data(("\n" + preview + "\n").utf8))
            } else if !noInlinePreviewHintShown {
                // No inline preview here (e.g. Terminal.app). The model still SEES the media —
                // tell the user why nothing rendered + how to get inline previews, just once.
                noInlinePreviewHintShown = true
                print("\u{001B}[37m↳ \(TerminalMediaRenderer.status()) (the model still receives the media)\u{001B}[0m")
            }
            // A dropped-media turn is "look at THIS and answer" — NOT an agentic build. Do NOT run it
            // through the heavy agent brief (which bleeds prior-task context and pushes tool use). Send a
            // focused instruction that the media is ALREADY attached, so the model describes it directly
            // instead of hunting for a file via view_image/read_file (which it then hallucinates a path for).
            let text = prompt.isEmpty ? "Describe what's in the attached media and note anything important." : prompt
            let compiled = """
            \(text)

            The media is ATTACHED directly to this message — look at it and answer from what you actually see/hear. It is ALREADY provided to you; do NOT call view_image, read_file, run_command, or any tool to find, open, load, or fetch it, and do NOT ask for a file path. Answer directly and finish.
            """
            let mustUseGemini = atts.contains { $0.kind != .image || $0.fileURI != nil }
            // Vision capability is a property of the model the loop is ACTUALLY running (activeBinding),
            // NOT the default — after an auto-route switch these differ, and keying off the default could
            // send media to a non-vision model (Codex, 2026-07-03). Single-source-of-truth invariant.
            let activeIsBorrow = activeBinding.providerId == visionProviderId
            let activeHandles = activeIsBorrow || (!mustUseGemini && (providerSupportsVision?(activeBinding) ?? false))
            let oc: HeadlessAgentLoop.Outcome
            if activeHandles {
                oc = await runTurnInterruptible(loop: loop, userInput: compiled, attachments: atts)
            } else if let vid = visionProviderId, let loopFactory {
                print("\u{001B}[37m↳ \(activeBinding.providerId) can't see this media — routing this turn to \(vid), back to \(activeBinding.providerId) after\u{001B}[0m")
                let visionLoop = perm.arm(loopFactory(ProviderBinding(providerId: vid), roleSelection.bindings, perm.mode.isPlan, showReasoning, extendedThinking))
                oc = await runTurnInterruptible(loop: visionLoop, userInput: compiled, attachments: atts)
            } else {
                print("\u{001B}[31m↳ no vision-capable provider configured (add a Gemini key) — sending text only\u{001B}[0m")
                oc = await runTurnInterruptible(loop: loop, userInput: compiled)
            }
            rememberHumanTurn(user: text, assistantSummary: oc.summary)
            selfMonitor(goal: text, success: oc.success)
            await printTurnUsage()
        }

        // SELF-MONITOR: analyze the just-finished turn's trajectory for reliability issues (runaway
        // loop / failure spike / read-only spin) and learn an obstacle from anything unhealthy or
        // failed. Surfaced dimly; recorded as advisory memory for future briefs.
        func selfMonitor(goal: String, success: Bool) {
            // R1: an ESC'd turn is a user decision, not a reliability signal — recording it as a
            // failure/obstacle would teach kist that interrupted goals fail. (Read-only: the flag
            // is reset at the START of the next turn so the other post-turn guards can read it too.)
            if lastTurnInterrupted { return }
            var issueLabels: [String] = []
            if let recorder {
                let report = TrajectoryAnalyzer.analyze(recorder.snapshot())
                issueLabels = report.issues.map { $0.kind.rawValue }
                if !report.healthy {
                    print("\u{001B}[37m⚙ self-check · \(issueLabels.joined(separator: ", "))\u{001B}[0m")
                }
                if let lessonStore {
                    let at = Date().timeIntervalSince1970
                    for issue in report.issues {
                        lessonStore.record(Lesson(kind: .obstacle,
                            text: "\(issue.kind.rawValue): \(issue.detail) [goal: \(goal.prefix(80))]", source: nil, at: at))
                    }
                    if !success {
                        lessonStore.record(Lesson(kind: .obstacle, text: "task failed: \(goal.prefix(120))", source: nil, at: at))
                    }
                }
            }
        }

        // /copilot: after a turn that MUTATED files, have the assigned co-reviewer model critique the actual
        // working-tree diff. Advisory only — it prints findings and never edits/reverts. Skips silently when
        // copilot is off, the turn changed nothing, no completion seam is wired, or the diff is empty.
        // Pick the reviewer: a model DIFFERENT from the one that just answered — never self-review (that's
        // the "just repeat yourself" anti-pattern Luke called out). Team mode's explicit `co` wins if it's
        // distinct; otherwise auto-pick a configured provider ≠ the answering one, cheap/reliable first.
        // nil ⇒ no distinct reviewer available (skip the review rather than let a model grade its own work).
        func autoReviewer(answeredBy: ProviderBinding) -> ProviderBinding? {
            if let co = copilot.co, co.providerId != answeredBy.providerId { return co }
            let configured = Set(providerAliases.values)
            let prefer = ["claude-cli", "gemini", "deepseek", "mimo", "codex-cli", "moonshot", "zhipu", "grok"]
            if let pid = prefer.first(where: { $0 != answeredBy.providerId && configured.contains($0) }) {
                return ProviderBinding(providerId: pid)
            }
            if let pid = configured.first(where: { $0 != answeredBy.providerId }) {
                return ProviderBinding(providerId: pid)
            }
            return nil
        }

        // The grounding handed to the second-opinion reviewer so it isn't context-blind. Same self-identity
        // brief the primary turn rides on (so the reviewer knows what "Kist" IS) + durable project memory
        // (AGENTS.md/CLAUDE.md/facts). Without this the reviewer answers "I've never heard of this system,
        // can't verify the claims" instead of actually reviewing — the brain-dead second opinion.
        func reviewerGrounding() -> String {
            var parts = [kistSelfContext()]
            let facts = ProjectMemory(root: projectRoot).facts()
            if !facts.isEmpty { parts.append("[PROJECT MEMORY]\n" + facts) }
            return parts.joined(separator: "\n\n")
        }

        // One review pass. Reviews the working-tree DIFF for a coding turn, else the substantive ANSWER
        // text. Reviewer is a DIFFERENT model than the one that answered (autoReviewer). Returns the review
        // text (nil = nothing worth reviewing / no distinct reviewer / no response).
        func runOneReview(task: String, answer: String = "", reviewer: ProviderBinding? = nil) async -> String? {
            guard let modelComplete else { return nil }
            // `reviewer` lets ULTRA mode rotate the second opinion through a roster of minds; nil ⇒ the
            // default top-ranked distinct reviewer.
            guard let co = reviewer ?? autoReviewer(answeredBy: activeBinding) else { return nil }
            let isCoding = Copilot.shouldReview(trajectory: recorder?.snapshot() ?? [])
            let diff = isCoding ? Self.workingTreeDiff(projectRoot: projectRoot) : ""
            // Ground the reviewer in the SAME context the primary turn had — its self-identity brief plus
            // durable project memory. Without this the second model is context-blind about the domain (it
            // has never heard of "Kist") and answers "I can't verify these claims" instead of reviewing.
            let grounding = reviewerGrounding()
            let system: String, userPrompt: String
            if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                system = Copilot.reviewSystemPrompt
                userPrompt = Copilot.reviewPrompt(task: task, diff: diff, projectContext: grounding)
            } else if Copilot.isSubstantiveAnswer(answer) {
                system = Copilot.answerReviewSystemPrompt
                userPrompt = Copilot.answerReviewPrompt(task: task, answer: answer, projectContext: grounding)
            } else {
                return nil   // read-only/failed coding turn or chit-chat answer — nothing to second-opinion
            }
            print("\u{001B}[35m⎇ second opinion · \(TeamLanguage.displayName(co.providerId)) reviewing…\u{001B}[0m")
            let review = await InterruptibleTurn.run(onInterrupt: { reason in
                if reason == .cancel { TurnInputQueue.shared.clearAll() }
                else { TurnInputQueue.shared.commitPending() }
                print("\n\u{001B}[33m"
                      + (reason == .cancel ? "⎋⎋ review cancelled" : "⎋ review interrupted — your turn")
                      + "\u{001B}[0m")
            }) {
                await modelComplete(co.providerId, co.model, system, userPrompt)
            }
            guard let review, !review.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("\u{001B}[37m⎇ second opinion · \(TeamLanguage.displayName(co.providerId)) had no response\u{001B}[0m")
                return nil
            }
            print("\u{001B}[35m⎇ review (\(TeamLanguage.displayName(co.providerId))):\u{001B}[0m\n\(review)")
            return review
        }

        // ULTRA MODE (Luke 2026-08-01): the consensus of minds. The captain orders every reachable model by
        // capability (Claude → Codex → DeepSeek → …); each mind REVIEWS the current work and, if it's not
        // clean, GOES IN AND FIXES it, handing the improved work to the next mind — until a mind signs off
        // clean (flawless) or the roster is exhausted. `/mode ultra` turns it on; `/mode normal` off.
        func ultraRoster(excluding answered: ProviderBinding) -> [ProviderBinding] {
            let configured = Set(providerAliases.values)
            // Capability order — Claude leads, Codex second, then the rest (matches the operator's mental model).
            let prefer = ["claude-cli", "codex-cli", "gemini", "deepseek", "mimo", "moonshot", "zhipu", "grok", "openai", "anthropic"]
            var seen = Set<String>(); var out: [ProviderBinding] = []
            for pid in prefer where configured.contains(pid) && pid != answered.providerId && seen.insert(pid).inserted {
                out.append(ProviderBinding(providerId: pid))
            }
            return out
        }

        func runUltraReview(task: String, answer: String) async {
            guard let loopFactory else { return }
            let roster = ultraRoster(excluding: activeBinding)
            guard !roster.isEmpty else { print("\u{001B}[37m⎇ ultra · no other minds configured — add models with /model\u{001B}[0m"); return }
            let maxPasses = 2   // bound so a stubborn nitpick can't loop forever; FLAWLESS = a full pass all-clean
            print("\u{001B}[35m⎇ ultra · consensus of minds: \(roster.map { TeamLanguage.displayName($0.providerId) }.joined(separator: " → "))\u{001B}[0m")
            print("\u{001B}[2m  up to \(maxPasses) passes · FLAWLESS = every mind signs off in one full pass\u{001B}[0m")
            var current = answer
            for pass in 1...maxPasses {
                guard !lastTurnInterrupted else { return }
                var allClean = true   // did EVERY mind sign off this pass (no fix needed)?
                for mind in roster {
                    guard !lastTurnInterrupted else { return }
                    guard let review = await runOneReview(task: task, answer: current, reviewer: mind) else { continue }
                    if Copilot.reviewIsClean(review) {
                        print("\u{001B}[32m⎇ ultra · \(TeamLanguage.displayName(mind.providerId)) signs off ✓ (pass \(pass))\u{001B}[0m")
                        continue
                    }
                    // Not clean → this mind goes in and fixes it; the improved work is what the rest review.
                    allClean = false
                    print("\u{001B}[35m⎇ ultra · \(TeamLanguage.displayName(mind.providerId)) going in to fix its findings (pass \(pass))…\u{001B}[0m")
                    armTurnLoop()
                    let fixLoop = perm.arm(loopFactory(mind, roleSelection.bindings, perm.mode.isPlan,
                                                       showReasoning, extendedThinking))
                    recorder?.reset()
                    let oc = await runTurnInterruptible(loop: fixLoop, userInput: Copilot.fixPrompt(task: task, review: review))
                    await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                    current = oc.summary
                }
                if allClean {
                    print("\u{001B}[1;32m⎇ ultra · FLAWLESS — all \(roster.count) minds signed off (pass \(pass))\u{001B}[0m")
                    return
                }
            }
            print("\u{001B}[33m⎇ ultra · reached the \(maxPasses)-pass limit — not every mind is satisfied yet; best effort committed\u{001B}[0m")
        }

        // R4: the coder↔reviewer partnership. The co-reviewer critiques the diff; if it flags blocking
        // issues AND auto-fix is armed (team mode), the LEAD runs a bounded fix turn to address them,
        // then the reviewer re-checks — a real team accomplishing the goal, not an advisory print.
        func runCopilotReview(task: String, answer: String = "", allowAdvisory: Bool = false) async {
            // R2a (review catch): after an interject the user's typed instruction must run NEXT —
            // not after a copilot model call they didn't ask for.
            guard !lastTurnInterrupted else { return }
            // Run the review when team mode is on (enabled) OR the default-on advisory second opinion applies
            // to this DIRECT turn (allowAdvisory). Team mode adds the fix loop below; advisory just prints.
            let advisory = allowAdvisory && copilot.autoSecondOpinion
            guard copilot.enabled || advisory else { return }
            // ULTRA MODE: hand off to the consensus-of-minds chain (every mind reviews→fixes in turn) instead
            // of the single second opinion.
            if copilot.ultra { await runUltraReview(task: task, answer: answer); return }
            guard var review = await runOneReview(task: task, answer: answer) else { return }

            // AUTO-FIX BY DEFAULT (Luke 2026-08-01): the reviewer must JUMP IN THE DRIVER'S SEAT and fix
            // what it finds — not critique and stop. Any non-clean review with a lead loop now closes the
            // loop and fixes it (team mode `/copilot on` is just the explicit form). `/copilot off` disables
            // it. Bounded by maxFixRounds so a stubborn critique can't loop forever.
            //
            // WHO fixes (Luke 2026-08-01): the REVIEWER goes in LAST and fixes it — the capable model that
            // FOUND the problem (Claude, via autoReviewer), NOT the primary model that already produced the
            // bad work and would just botch it again. Order is: primary works → reviewer critiques →
            // reviewer goes in and fixes. Fall back to the team lead / session model only if there's no
            // distinct reviewer.
            guard let loopFactory, !Copilot.reviewIsClean(review) else { return }
            var round = 0
            while round < max(1, copilot.maxFixRounds), !Copilot.reviewIsClean(review) {
                round += 1
                let fixer = autoReviewer(answeredBy: activeBinding) ?? copilot.lead ?? roleSelection.fallback
                print("\u{001B}[35m⎇ review done → \(TeamLanguage.displayName(fixer.providerId)) going in to fix the findings (round \(round))…\u{001B}[0m")
                armTurnLoop()
                let fixLoop = perm.arm(loopFactory(fixer, roleSelection.bindings, perm.mode.isPlan,
                                                   showReasoning, extendedThinking))
                // Fresh trajectory for the fix turn so the re-review's shouldReview reflects ONLY what
                // the fix changed — a no-op fix (coder pushed back) then converges instead of
                // re-reviewing the unchanged diff on the stale coding-turn records (review catch).
                recorder?.reset()
                let oc = await runTurnInterruptible(loop: fixLoop, userInput: Copilot.fixPrompt(task: task, review: review))
                await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                if lastTurnInterrupted { return }     // user stepped in — stop the team loop
                // Re-review the fix so the loop converges (or exhausts its bounded rounds).
                guard let next = await runOneReview(task: task) else { return }
                review = next
            }
            if Copilot.reviewIsClean(review) {
                print("\u{001B}[32m⎇ team · review clean — findings resolved\u{001B}[0m")
            }
        }

        // R4: arm a natural-language TEAM ("gemini be the eyes for deepseek", "deepseek codes and mimo
        // reviews", "work as a team"). Binds the lead (coder) + co (reviewer) across vendors and turns on
        // the review→fix loop, so a single goal is accomplished by the AIs working together, not one model.
        func armTeam(_ team: TeamIntent) {
            func resolve(_ name: String?) -> ProviderBinding? {
                guard let name, !name.isEmpty else { return nil }
                return Self.resolveModelSpec(name, currentProvider: roleSelection.fallback.providerId,
                                             knownProviders: providerAliases, providerModels: providerModels)
            }
            if let name = team.lead, resolve(name) == nil {
                print("\u{001B}[37m↳ team: no configured model for '\(name)' — keeping current lead\u{001B}[0m")
            }
            if let name = team.co, resolve(name) == nil {
                print("\u{001B}[37m↳ team: no configured model for '\(name)' — keeping current reviewer\u{001B}[0m")
            }
            if let lead = resolve(team.lead) {
                copilot.lead = lead
                _ = roleSelection.setDefault(lead, knownProviders: providerAliases)
                _ = roleSelection.assign(.coder, to: lead, knownProviders: providerAliases)
                autoRouting = false                          // a named lead pins the coding model
                activeBinding = roleSelection.fallback
                if let loopFactory {
                    loop = loopFactory(roleSelection.fallback, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking)
                }
            }
            if let co = resolve(team.co) {
                copilot.co = co
                _ = roleSelection.assign(.critic, to: co, knownProviders: providerAliases)
            }
            copilot.enabled = true
            let leadB = copilot.lead ?? roleSelection.fallback
            let coB = copilot.co ?? roleSelection.fallback
            // Don't let one model review AND fix its own code (no second model resolved). Keep the
            // review (advisory) but leave auto-fix off — a self-critique-then-self-fix is a no-op that
            // just burns tokens (review catch).
            let sameModel = leadB.providerId == coB.providerId && leadB.model == coB.model
            copilot.autoFix = !sameModel
            if sameModel {
                print("\u{001B}[35m⎇ team\u{001B}[0m · only one model configured — \(TeamLanguage.displayName(coB.providerId)) will review (advisory). Name a second model to enable review→fix.")
            } else {
                print("\u{001B}[35m⎇ team armed\u{001B}[0m · \(TeamLanguage.displayName(leadB.providerId)) building · "
                    + "\(TeamLanguage.displayName(coB.providerId)) reviewing · review→fix on")
            }
        }

        func consumeTurnUsageDelta() async -> [AgentSpan] {
            guard let traceRecorder else { return [] }
            let spans = await traceRecorder.all()
            let before = Set(usageSnapshot.map(\.id))
            let delta = spans.filter { !before.contains($0.id) }
            usageSnapshot = spans
            if !UsageLedger.append(projectRoot: projectRoot, spans: delta) {
                print("\u{001B}[37musage ledger warning · could not persist local usage accounting\u{001B}[0m")
            }
            return delta
        }

        func printTurnUsage() async {
            let delta = await consumeTurnUsageDelta()
            let summary = UsageCost.summarize(spans: delta)
            guard summary.tokens > 0 else { return }
            print("\u{001B}[37m\(summary.render(label: "usage"))\u{001B}[0m")
        }

        func printSessionUsage() async {
            guard let traceRecorder else { print("usage: unavailable"); return }
            let spans = await traceRecorder.all()
            if !UsageLedger.append(projectRoot: projectRoot, spans: spans) {
                print("\u{001B}[37musage ledger warning · could not persist local usage accounting\u{001B}[0m")
            }
            print(UsagePanel.render(sessionSpans: spans, projectRoot: projectRoot))
        }

        func dispatchSelfHealAgents(report: SelfHealMissionReport,
                                    objective: String,
                                    automatic: Bool) async {
            guard report.writeSucceeded else {
                print("\u{001B}[31mself-heal dispatch blocked: mission report was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mself-heal dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            let store = OrganizationalLearningStore(projectRoot: projectRoot)
            var priorEvidence: [String] = []
            if automatic {
                print("\u{001B}[33mCaptain supervisor dispatch\u{001B}[0m · \(report.agentAssignments.count) repair specialist(s) · evidence chained")
            }
            for assignment in report.agentAssignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                let evidenceBrief = priorEvidence.isEmpty
                    ? ""
                    : "\n\nEvidence from earlier self-heal specialists:\n" + priorEvidence.joined(separator: "\n\n")
                print("\u{001B}[2m⇢ self-heal delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      assignment.task + evidenceBrief,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m\n\(summary)")
                    priorEvidence.append("## \(assignment.specialistName)\n\(summary)")
                    if let artifact = store.recordSelfHealSpecialistOutput(objective: objective,
                                                                            assignment: assignment,
                                                                            summary: summary) {
                        let memory = artifact.memoryRecorded ? "indexed" : "not indexed"
                        let ledger = artifact.evidenceLedgerRecorded ? "ledgered" : "ledger failed"
                        let taskIDs = artifact.updatedTaskIDs.isEmpty
                            ? "no task ids"
                            : "tasks " + artifact.updatedTaskIDs.map(String.init).joined(separator: ",")
                        print("\u{001B}[2mself-heal evidence: \(artifact.path) · \(memory) · \(ledger) · \(taskIDs) · task evidence updated: \(artifact.taskEvidenceUpdated)\u{001B}[0m")
                        let verificationEvidence = CaptainFailureAnalysis.extractStructuredEvidence(from: priorEvidence.joined(separator: "\n\n"))
                        if verificationEvidence.isEmpty {
                            print("\u{001B}[2mself-heal repair verification: awaiting explicit VERIFY/proof lines\u{001B}[0m")
                        } else if let verification = try? CaptainFailureAnalysis(projectRoot: projectRoot)
                            .recordRepairVerificationIfChanged(evidence: verificationEvidence) {
                                let missing = verification.missingVerification.isEmpty
                                    ? "all verification checks matched"
                                    : "\(verification.missingVerification.count) missing check(s)"
                                print("\u{001B}[2mself-heal repair verification: \(verification.status.rawValue) · \(missing)\u{001B}[0m")
                                if let evidence = verification.structuredEvidence, !evidence.isEmpty {
                                    let proof = CaptainFailureAnalysis.renderVerificationEvidenceSummary(evidence)
                                    print("\u{001B}[2mself-heal proof: \(proof)\u{001B}[0m")
                                }
                        }
                    } else {
                        print("\u{001B}[31mself-heal evidence capture failed for \(assignment.specialistName)\u{001B}[0m")
                    }
                } else {
                    print("\u{001B}[31mself-heal agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        @discardableResult
        func openFailureAnalysis(goal: String,
                                 summary: String,
                                 automaticRepair: Bool) async -> CaptainFailureAnalysisReport {
            let failure = CaptainFailureAnalysis(projectRoot: projectRoot)
                .analyze(goal: goal,
                         summary: summary,
                         trajectory: recorder?.snapshot() ?? [],
                         proofEntries: proofStore?.lastEntries() ?? [])
            let persisted = failure.writeSucceeded
                ? failure.path
                : "write failed: \(failure.writeError ?? "unknown error")"
            print("\u{001B}[33mCaptain failure analysis\u{001B}[0m · \(failure.capsule.likelyLayer.rawValue) · confidence \(failure.capsule.confidence)% · \(persisted) · seeded \(failure.seededTasks) task(s)")
            guard automaticRepair,
                  failure.writeSucceeded,
                  Self.shouldAutoSuperviseFailure(goal: goal)
            else { return failure }

            let objective = Self.supervisorRepairObjective(for: failure.capsule)
            let report = Self.handleSelfHealCommand("self-heal run \(objective)",
                                                    projectRoot: projectRoot,
                                                    trajectory: recorder?.snapshot() ?? [])
            let mission = report.writeSucceeded ? report.path : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[33mCaptain supervisor opened repair mission\u{001B}[0m · \(mission) · seeded \(report.seededTasks) task(s)")
            await dispatchSelfHealAgents(report: report, objective: objective, automatic: true)
            return failure
        }

        func printTurnSummary(outcomeSummary: String? = nil, success: Bool = true) async {
            let trajectory = recorder?.snapshot() ?? []
            // `outcomeSummary` is the MODEL'S prose — it was ALREADY shown live (streamed token-by-token
            // during the turn), so we deliberately do NOT reprint it here (that caused "every answer twice").
            // It is not thrown away: it drives the grounding check that sets the dashboard confidence.
            let grounded = outcomeSummary.map { GroundedReviewValidator.audit($0, projectRoot: projectRoot).isGrounded } ?? true
            // The deterministic four-part recap (happened / changed / failed / next) — the at-a-glance
            // operating summary, shown ABOVE the panel (Active Minds · Tasks · Next). Full detail: /summary.
            let spans = await consumeTurnUsageDelta()
            if let outcomeSummary, !outcomeSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let plan = PlanStore(projectRoot: projectRoot).load()
                let insights = DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                               trajectory: trajectory)
                _ = OrganizationalLearningStore(projectRoot: projectRoot)
                    .recordTurn(plan: plan, spans: spans, trajectory: trajectory,
                                outcomeSummary: outcomeSummary, success: success,
                                insights: insights)
            }
            print(Self.renderSimpleSummary(projectRoot: projectRoot, spans: spans, trajectory: trajectory))
            // R2a (review catch): an ESC'd turn is not a failure — auto-opening a repair mission
            // (self-heal dispatch, token spend) before the user's queued instruction is the exact
            // opposite of "your turn".
            if !success, !lastTurnInterrupted {
                let goal = humanTranscript.reversed().first { $0.role == .user }?.content ?? "unknown turn"
                await openFailureAnalysis(goal: goal,
                                          summary: outcomeSummary ?? "turn failed without a model summary",
                                          automaticRepair: true)
            }
            let dashboard = Self.buildDashboard(roles: roleSelection, projectRoot: projectRoot,
                                                trajectory: trajectory, grounded: grounded)
            lastConfidenceReport = dashboard.confidenceReport
            let compact = !success || !Self.turnHasMutatingWork(trajectory)
            let panelColor = Self.stdoutColorEnabled
            print(compact ? dashboard.renderCompact(color: panelColor) : dashboard.render(color: panelColor))
            let hint = "proof: /logs · cost: /usage · board: /tasks · /summary for detail"
            print(panelColor ? "\u{001B}[2m\(hint)\u{001B}[0m" : hint)
        }

        func runSelfHealCommand(_ rawArgs: String) async {
            let report = Self.handleSelfHealCommand(rawArgs,
                                                    projectRoot: projectRoot,
                                                    trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[2m\(persisted) · board meeting: \(report.boardMeetingPath) · seeded self-heal tasks: \(report.seededTasks) · created specialists: \(report.createdSpecialists)\u{001B}[0m")
            guard Self.selfHealShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to dispatch the self-heal agents\u{001B}[0m")
                return
            }
            let objective = Self.normalizedSelfHealObjective(rawArgs)
            await dispatchSelfHealAgents(report: report, objective: objective, automatic: false)
        }

        func runDomainLearningCommand(_ rawArgs: String) async {
            let report = Self.handleDomainLearningCommand(rawArgs,
                                                          projectRoot: projectRoot,
                                                          trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            print("\u{001B}[2m\(persisted) · confidence: \(report.understandingConfidence)%/\(report.confidenceThreshold)% · seeded tasks: \(report.seededTasks) · knowledge debt: \(report.knowledgeDebtCreated) · created specialists: \(report.createdSpecialists)\u{001B}[0m")
            guard Self.domainLearningShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to dispatch the domain-learning specialists\u{001B}[0m")
                return
            }
            guard report.writeSucceeded else {
                print("\u{001B}[31mdomain-learning dispatch blocked: report was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mdomain-learning dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            let assignments = report.canExecute
                ? report.agentAssignments
                : report.agentAssignments.filter { assignment in
                    let name = assignment.specialistName.lowercased()
                    return name.contains("research") || name.contains("critic")
                        || name.contains("simulation") || name.contains("scout")
                        || name.contains("symbolic")
                }
            if !report.canExecute {
                print("\u{001B}[33mdomain-learning gate HOLD — dispatching research/simulation/critic specialists only\u{001B}[0m")
            }
            for assignment in assignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                print("\u{001B}[2m⇢ domain learning delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      assignment.task,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m\n\(summary)")
                    if let artifact = OrganizationalLearningStore(projectRoot: projectRoot)
                        .recordDomainLearningSpecialistOutput(objective: report.objective,
                                                              assignment: assignment,
                                                              summary: summary) {
                        let memory = artifact.memoryRecorded ? "indexed" : "not indexed"
                        let ledger = artifact.evidenceLedgerRecorded ? "ledgered" : "ledger failed"
                        let taskIDs = artifact.updatedTaskIDs.isEmpty
                            ? "no task ids"
                            : "tasks " + artifact.updatedTaskIDs.map(String.init).joined(separator: ",")
                        print("\u{001B}[2mdomain-learning evidence: \(artifact.path) · \(memory) · \(ledger) · \(taskIDs) · task evidence updated: \(artifact.taskEvidenceUpdated)\u{001B}[0m")
                    } else {
                        print("\u{001B}[31mdomain-learning evidence capture failed for \(assignment.specialistName)\u{001B}[0m")
                    }
                } else {
                    print("\u{001B}[31mdomain-learning agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        func dispatchLegalResearchAgents(report: LegalResearchReport) async {
            guard report.writeSucceeded else {
                print("\u{001B}[31mlegal research dispatch blocked: dossier was not durably written\u{001B}[0m")
                return
            }
            guard let runSpecialist else {
                print("\u{001B}[31mlegal research dispatch needs specialist run support in this REPL\u{001B}[0m")
                return
            }
            var priorEvidence: [String] = []
            for assignment in report.agentAssignments {
                let agentColor = SpecialistRegistry(projectRoot: projectRoot)
                    .named(assignment.specialistName)
                    .flatMap { SpecialistDefinition.ansi(forColor: $0.color) }
                let tinted = agentColor.map { "\u{001B}[\($0)m\(assignment.specialistName)\u{001B}[0m" }
                    ?? assignment.specialistName
                let evidenceBrief = priorEvidence.isEmpty
                    ? ""
                    : "\n\nEvidence from earlier legal-research specialists:\n" + priorEvidence.joined(separator: "\n\n")
                print("\u{001B}[2m⇢ legal research delegating to \(tinted) · \(assignment.role) · preferred \(assignment.preferredModel)\u{001B}[0m")
                if let summary = await runSpecialist(assignment.specialistName,
                                                      assignment.task + evidenceBrief,
                                                      perm.effectiveApproval(),
                                                      perm.effectivePlan) {
                    print("\u{001B}[36;1m⇠ \(assignment.specialistName)\u{001B}[0m\n\(summary)")
                    priorEvidence.append("## \(assignment.specialistName)\n\(summary)")
                } else {
                    print("\u{001B}[31mlegal research agent unavailable: \(assignment.specialistName)\u{001B}[0m")
                }
            }
        }

        func runLegalResearchCommand(_ rawArgs: String, forceResearch: Bool) async {
            let report = Self.handleLegalResearchCommand(rawArgs,
                                                         projectRoot: projectRoot,
                                                         trajectory: recorder?.snapshot() ?? [])
            print(report.text)
            let persisted = report.writeSucceeded ? "written: \(report.path)" : "write failed: \(report.writeError ?? "unknown error")"
            let jurisdiction = report.jurisdiction ?? "unknown jurisdiction"
            print("\u{001B}[2m\(persisted) · \(jurisdiction) · sources: \(report.extractedSourceCount)/\(report.sourceCount) extracted · seeded tasks: \(report.seededTasks) · created specialists: \(report.createdSpecialists) · memory: \(report.memoryRecords)\u{001B}[0m")

            guard report.writeSucceeded else {
                await openFailureAnalysis(goal: rawArgs,
                                          summary: "legal research workflow failed to write dossier: \(report.writeError ?? "unknown error")",
                                          automaticRepair: true)
                return
            }

            guard report.readyForResearch else {
                print("\u{001B}[33mlegal research gate HOLD\u{001B}[0m · " + report.blockers.joined(separator: "; "))
                print("\u{001B}[2manswer the blocker(s), then run \(report.dispatchCommand)\u{001B}[0m")
                return
            }

            guard forceResearch || Self.legalResearchShouldRun(rawArgs) else {
                print("\u{001B}[2mrun \(report.dispatchCommand) to hand this into evidence-first research\u{001B}[0m")
                return
            }

            if report.extractedSourceCount > 0 && !Self.legalResearchHasExternalDocumentConsent(rawArgs) {
                print("\u{001B}[33mlegal privacy gate HOLD\u{001B}[0m · document text was extracted locally but not sent to external research/models")
                print("\u{001B}[2mrerun with --send-docs or --allow-external after confirming you want this legal document text included in model/research handoff\u{001B}[0m")
                return
            }

            if let research {
                print("\u{001B}[33mlegal research handoff\u{001B}[0m · evidence-first /research")
                await research(report.researchGoal, roleSelection.bindings)
            } else if runSpecialist != nil {
                print("\u{001B}[33mlegal research handoff\u{001B}[0m · specialist fallback")
                await dispatchLegalResearchAgents(report: report)
            } else {
                print("\u{001B}[31mlegal research handoff unavailable: no /research runner or specialist runner in this mode\u{001B}[0m")
                print("\u{001B}[2mmanual handoff: /research \(report.researchGoal.prefix(180))...\u{001B}[0m")
            }
        }

        func compactCost(_ s: UsageCostSummary) -> String {
            guard s.tokens > 0 else { return "—" }
            let tok = s.tokens >= 1000 ? String(format: "%.1fk tok", Double(s.tokens) / 1000) : "\(s.tokens) tok"
            return (s.knownUSD > 0 ? String(format: "$%.4f · ", s.knownUSD) : "") + tok
        }

        // The always-visible status line (#3): model/team in plain words, mode, cost, active + next task.
        // The persisted plan's doing:/next: line shows ONLY when the plan belongs to THIS session (its
        // file was written at/after sessionStart). A plan left on disk by a prior session — or auto-seeded
        // by an earlier council run — must not greet a cold start as "next:" (confusing, unrelated noise);
        // it stays silent until this session advances it, and is always reachable via /tasks.
        func renderStatusLine() async -> String {
            let bindings = roleSelection.bindings
            // Non-team case shows the model the loop is ACTUALLY running (activeBinding), not the startup
            // default — so the always-visible status line never lies after an auto-route switch (invariant).
            let modelLabel = TeamLanguage.describeTeam(bindings)
                ?? (TeamLanguage.displayName(activeBinding.providerId)
                    + (activeBinding.model.map { " (\($0))" } ?? ""))
            let cost = traceRecorder == nil ? "—" : compactCost(UsageCost.summarize(spans: await traceRecorder!.all()))
            let store = PlanStore(projectRoot: projectRoot)
            let persisted = store.load()
            // Show doing:/next: for work THIS session is on — but never greet a cold start with a stale
            // prior-session task (see PlanStatusVisibility). The board is always on /tasks.
            let showPlan = PlanStatusVisibility.shouldShow(planModifiedAt: store.modifiedAt(),
                                                           sessionStart: sessionStart,
                                                           hasActiveTask: persisted.active != nil)
            let plan = showPlan ? persisted : Plan()
            let modeLabel: String
            switch perm.mode {
            case .normal: modeLabel = "chat"
            case .acceptEdits: modeLabel = "accept-edits"
            case .plan: modeLabel = "plan"
            case .bypass: modeLabel = "bypass"
            }
            return StatusLine(modelLabel: modelLabel,
                              mode: modeLabel,
                              cost: cost,
                              activeTask: plan.active.map { "[\($0.id)] \($0.title)" },
                              nextStep: (plan.active ?? plan.nextActionable ?? plan.next).map { "[\($0.id)] \($0.title)" }).render()
        }

        func completionCandidates() -> [String] {
            if cachedSymbols == nil {
                cachedSymbols = InputCompleter.projectSymbols(projectRoot: projectRoot)
            }
            let providers = providerLabels.map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            let models = providerModels.values.flatMap { $0 }
            return InputCompleter.candidates(commands: commands.names,
                                             providers: providers,
                                             models: models,
                                             projectRoot: projectRoot,
                                             symbolCache: { cachedSymbols ?? [] })
        }

        var activeInteractionSession: TurnInteractionSession?
        while true {
            // The previous submitted message is complete only now: post-review and usage rendering
            // have finished. `finish()` releases descriptor capture + DECSTBM while stdin is still
            // raw, then stops its one watcher and restores cooked mode. This is the no-lost-typeahead,
            // no-kernel-echo-through-the-panel handoff boundary.
            if let session = activeInteractionSession {
                await session.finish()
                activeInteractionSession = nil
                pinnedBar.endStickyTurn()
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
            pinnedBar.resume()                 // re-pin the strip after a turn ran with the region torn down
            pinnedBar.refreshSizeIfNeeded()
            // Size the reserved strip to the ACTUAL status height (1 line, or 2 when a task board is
            // active) so the box never overflows the pinned region and corrupts the panel mid-plan.
            let statusRows = status.isEmpty ? 1 : status.split(separator: "\n", omittingEmptySubsequences: false).count
            let panelLead = pinnedBar.panelLead(statusRows: statusRows)
            let line: String
            let promptWasPinned = pinnedBar.active
            // R2a: a drained line was typed while the user may have WALKED AWAY — never block the
            // backlog on an interactive y/N confirm for it (router guard below).
            var lineFromQueue = false
            if let queued = await deferredInput?() {
                FileHandle.standardOutput.write(Data((panelLead + status + "\n" + topBorder + "\n" + promptColor + queued + "\n").utf8))
                line = queued
                lineFromQueue = true
                // There is no prompt reader/raw-mode defer on this path. Release the fixed screen
                // explicitly before the new turn session takes stdin ownership.
                pinnedBar.suspend()
            } else {
                FileHandle.standardOutput.write(Data((panelLead + status + "\n" + topBorder + "\n").utf8))
                let read = inputReader.readLine(prompt: promptColor,
                                                promptColumns: promptPlain.count,
                                                completionCandidates: completionCandidates,
                                                commandNames: InputCompleter.builtInCommands + commands.names.map { "/\($0)" },
                                                onPaste: { PasteboardReader.text() },
                                                barHint: { perm.barHint(includeInterrupt: true) },
                                                onCycle: { perm.cycle() },
                                                // Runs from the prompt reader's defer before RawMode.disable().
                                                // Kernel echo must never coexist with the fixed panel.
                                                beforeRawRestore: { pinnedBar.suspend() },
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
                        pinnedBar.updateStickyTypeahead(
                            pending: pending, queuedCount: queuedCount)
                    }
                    onScreenLeaseBegin = { pinnedBar.beginInputScreenLease() }
                    onScreenLeaseEnd = { pinnedBar.endInputScreenLease() }
                    onScreenReleaseBeforeFinish = { pinnedBar.suspend() }
                    setBracketedPasteMode = { pinnedBar.setBracketedPasteEnabled($0) }
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
                    pinnedBar.resume()
                    if pinnedBar.active {
                        FileHandle.standardOutput.write(Data((pinnedBar.transcriptLead()
                            + "\u{001B}[36;1m❯ \u{001B}[0m" + input + "\r\n").utf8))
                        committedEchoWritten = true
                        let snapshot = TurnInputQueue.shared.preview()
                        let panel = TerminalScreenCoordinator.Panel(
                            status: status,
                            promptPrefix: promptPlain,
                            pending: snapshot.pending,
                            queuedCount: snapshot.queuedCount,
                            hint: perm.barHint(includeInterrupt: true))
                        stickyCaptureSucceeded = pinnedBar.beginStickyTurn(panel: panel)
                    }
                    if !stickyCaptureSucceeded {
                        // Raw ownership or capture setup failed. Stay on the full-screen fallback.
                        pinnedBar.suspend()
                    }
                }

                if !stickyCaptureSucceeded, !committedEchoWritten {
                    // The fixed prompt was cleared by the safe raw→cooked handoff, so preserve the
                    // committed text once in normal scrollback for slash and non-sticky turns.
                    FileHandle.standardOutput.write(Data(
                        ("\u{001B}[36;1m❯ \u{001B}[0m" + input + "\r\n").utf8))
                }
            }
            recorder?.reset()                 // fresh trajectory per turn for self-monitoring

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
                    print(Self.renderSimpleSummary(projectRoot: projectRoot, spans: spans, trajectory: trajectory))
                    continue
                case "confidence", "why":
                    // Explain the exact report the panel showed for the last completed turn. Do not
                    // consult the recorder here: it was intentionally reset before slash dispatch.
                    if let report = lastConfidenceReport {
                        print(report.renderBreakdown(color: Self.stdoutColorEnabled))
                    } else {
                        print("No confidence to explain yet — that turn used no tools (a plain answer). Run a turn that reads/edits/searches first.")
                    }
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
                    print(Self.handleTasks(args, projectRoot: projectRoot))
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
                        if let summary = await runSpecialist(name, task, perm.effectiveApproval(), perm.effectivePlan) {
                            print("\u{001B}[36;1m⇠ \(name)\u{001B}[0m\n\(summary)")
                        } else {
                            print("\u{001B}[31mno specialist named '\(name)'\u{001B}[0m — /agents to list")
                        }
                    } else {
                        print(Self.handleAgents(args, projectRoot: projectRoot))
                    }
                    continue
                case "action":
                    guard !args.isEmpty else { print(Self.handleTasks("", projectRoot: projectRoot)); continue }
                    print(Self.handleTasks("add ACTION: \(args)", projectRoot: projectRoot))
                    continue
                case "test":
                    guard !args.isEmpty else { print(Self.handleTasks("", projectRoot: projectRoot)); continue }
                    print(Self.handleTasks("add TEST: \(args)", projectRoot: projectRoot))
                    continue
                case "review":
                    guard !args.isEmpty else { print(Self.handleTasks("", projectRoot: projectRoot)); continue }
                    print(Self.handleTasks("add REVIEW: \(args)", projectRoot: projectRoot))
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
                    // <model>` (who codes), `/copilot co <model>` (who reviews). Advisory only.
                    switch Copilot.parseCommand(args) {
                    case .status:
                        print(copilot.statusLine(render: { Self.render($0) }))
                        if copilot.enabled && modelComplete == nil {
                            print("\u{001B}[33m↳ note: review completions aren't wired in this mode — it won't run\u{001B}[0m")
                        }
                    case .on:
                        copilot.enabled = true
                        copilot.autoSecondOpinion = true   // /copilot on restores the second opinion if it was silenced
                        print("\u{001B}[35m⎇ copilot ON\u{001B}[0m — the co-reviewer critiques the diff after each coding turn. " + copilot.statusLine(render: { Self.render($0) }))
                    case .off:
                        copilot.enabled = false
                        copilot.autoFix = false   // also disarm the team review→fix loop (never resurrect it via /copilot on)
                        copilot.autoSecondOpinion = false   // fully silence — also turns off the default-on advisory second opinion
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
                        recorder?.reset()
                        armTurnLoop()
                        let compiled = briefCompiler?(step, roleSelection.bindings, perm.mode.isPlan ? .plan : .inline, humanTranscript) ?? step
                        let enriched = attachCaptainContext(to: compiled, objective: step)
                        let oc = await runTurnInterruptible(loop: loop, userInput: enriched)
                        rememberHumanTurn(user: step, assistantSummary: oc.summary)
                        selfMonitor(goal: step, success: oc.success)
                        await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                        await runCopilotReview(task: step)
                        await printTurnUsage()
                        if !oc.success {
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
                    await fleet(invocation.goal, invocation.agents, roleSelection.bindings)
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
                    await fleet(Self.bugHuntBrief(inv.goal), inv.agents, roleSelection.bindings)
                    continue
                case "plan-execute", "pe", "dag":
                    guard let planExecute else { print("\u{001B}[31m/plan-execute isn't available here\u{001B}[0m"); continue }
                    guard !args.isEmpty else { print("usage: /plan-execute <goal>"); continue }
                    await planExecute(args, roleSelection.bindings)
                    continue
                case "council", "consult":
                    guard let council else { print("\u{001B}[31m/council isn't available here\u{001B}[0m"); continue }
                    guard let invocation = Self.parseCouncilArgs(args) else {
                        print("usage: /council [--execute|--build] <research/task>")
                        continue
                    }
                    await council(invocation.goal, roleSelection.bindings, invocation.execute)
                    continue
                case "dig", "digdeep", "minds", "mind":
                    guard let digDeep else { print("\u{001B}[31m/dig isn't available here\u{001B}[0m"); continue }
                    guard !args.isEmpty else { print("usage: /dig <question> — ask every reachable model in parallel and synthesize"); continue }
                    await digDeep(args, roleSelection.bindings)
                    continue
                case "ultra", "consensus", "flawless":
                    // The review "slider" (/mode is taken by persona): /ultra → consensus of minds (every
                    // reachable model reviews→fixes in turn until flawless); /ultra off → single second opinion.
                    let level = args.trimmingCharacters(in: .whitespaces).lowercased()
                    switch level {
                    case "", "on", "ultra", "max", "consensus":
                        copilot.ultra = true; copilot.autoSecondOpinion = true
                        let roster = ultraRoster(excluding: activeBinding).map { TeamLanguage.displayName($0.providerId) }
                        print("\u{001B}[35m⎇ ULTRA on — consensus of minds after each turn (review→fix until flawless)\u{001B}[0m")
                        print("\u{001B}[2m  order: \(roster.isEmpty ? "(no other minds configured — add with /model)" : roster.joined(separator: " → "))\u{001B}[0m")
                    case "off", "normal", "single", "review":
                        copilot.ultra = false
                        print("\u{001B}[35m⎇ ULTRA off — single second opinion (review→fix)\u{001B}[0m")
                    case "status", "?":
                        print("ultra: \(copilot.ultra ? "ON (consensus of minds)" : "off (single second opinion)") · /ultra | /ultra off")
                    default:
                        print("usage: /ultra | /ultra off   (ultra = every reachable mind reviews→fixes until flawless)")
                    }
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
                    await research(researchGoal, roleSelection.bindings)
                    continue
                default:
                    if let expanded = commands.expand(name, args: args) {
                        proofStore?.startTurn(goal: expanded)
                        if let display = personaDisplay?(expanded) { print("\u{001B}[37m↳ \(display)\u{001B}[0m") }
                        armTurnLoop()   // arm the permission tier — never run a turn on a stale loop
                        let compiled = briefCompiler?(expanded, roleSelection.bindings, perm.mode.isPlan ? .plan : .inline, humanTranscript) ?? expanded
                        let enriched = attachCaptainContext(to: compiled, objective: expanded)
                        let oc = await runTurnInterruptible(loop: loop, userInput: enriched)
                        rememberHumanTurn(user: expanded, assistantSummary: oc.summary)
                        selfMonitor(goal: expanded, success: oc.success)
                        await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                        await runCopilotReview(task: expanded)
                        await printTurnUsage()
                    } else {
                        print("\u{001B}[31munknown command /\(name)\u{001B}[0m — try /help or /commands")
                    }
                    continue
                }
            }

            if let task = Self.taskSelectedByUser(input, projectRoot: projectRoot) {
                let taskPrompt = Self.executionBrief(for: task, userInput: input)
                _ = PlanStore(projectRoot: projectRoot).update(id: task.id, status: .inProgress)
                if let planExecute {
                    print("\u{001B}[37m↳ running task [\(task.id)] through plan→execute · \(roleSelection.summary)\u{001B}[0m")
                    await planExecute(taskPrompt, roleSelection.bindings)
                } else {
                    proofStore?.startTurn(goal: taskPrompt)
                    armTurnLoop()   // arm the permission tier — never run a turn on a stale loop
                    let compiled = briefCompiler?(taskPrompt, roleSelection.bindings, perm.mode.isPlan ? .plan : .inline, humanTranscript) ?? taskPrompt
                    let enriched = attachCaptainContext(to: compiled, objective: taskPrompt)
                    let oc = await runTurnInterruptible(loop: loop, userInput: enriched)
                    rememberHumanTurn(user: taskPrompt, assistantSummary: oc.summary)
                    selfMonitor(goal: taskPrompt, success: oc.success)
                    await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
                    await runCopilotReview(task: taskPrompt)
                    await printTurnUsage()
                    // LOOP FIX: a RESEARCH item is a single-shot digest-and-decide unit (see ManageTasksTool),
                    // yet a plain research answer never calls `tasks done`, so `plan.active` re-served the same
                    // research task on every 'next'/'continue' forever. When a research-kind driving task's turn
                    // succeeds and was not interrupted, auto-close it (+advance) so it can never be re-selected.
                    if task.kind == .research, oc.success, !lastTurnInterrupted, !perm.mode.isPlan {
                        let store = PlanStore(projectRoot: projectRoot)
                        _ = store.update(id: task.id, appendEvidence: ["auto-closed after research turn: " + oc.summary.prefix(160)])
                        _ = store.completeAndAdvance(id: task.id)
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
            if let intent = ControlIntentParser.parse(input, knownProviders: providerAliases) {
                switch intent.action {
                case .setModel(let binding):
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
                    let routedTask = Self.expandBoardReference(intent.residualTask, projectRoot: projectRoot)
                    print("\u{001B}[37m↳ running as your team (plan→execute) · \(roleSelection.summary)\u{001B}[0m")
                    await planExecute(routedTask, roleSelection.bindings)
                    continue
                }
                messageBody = Self.expandBoardReference(intent.residualTask, projectRoot: projectRoot)
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

            // AUTO-ROUTE (Increment B): for a plain message, the router may PROPOSE an escalation to a
            // fleet / plan-DAG. It never spends big silently — we confirm first; a no falls through to a
            // normal turn. Slash commands above are the explicit path; this is the "just talk" path.
            // A team goal runs as a team-armed turn so the coder↔reviewer review→fix loop actually
            // fires — an accepted fleet/plan escalation would `continue` past runCopilotReview and drop
            // the partnership the user just asked for (review catch).
            // "Dig in deep" / "consult the minds": an explicit ask to hear from EVERY reachable model, not
            // one model answering (and re-answering) alone. Fires only on the narrow phrase set, so a normal
            // message is never hijacked; runs before the router so it isn't shadowed by a research proposal.
            if let digDeep, !lineFromQueue, AICouncil.looksLikeDigDeep(messageText) {
                await digDeep(messageText, roleSelection.bindings)
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
                    await router.propose(messageText)
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
                    case .fleet(let agents): if let fleet { await fleet(messageText, agents, roleSelection.bindings) }
                    case .planExecute: if let planExecute { await planExecute(messageText, roleSelection.bindings) }
                    case .council: if let council { await council(messageText, roleSelection.bindings, false) }
                    }
                    continue
                }
                // declined → handle inline as an ordinary turn.
            }

            // AUTO MODEL ROUTING: unless a model is pinned, pick the best one for THIS request (cheap
            // heuristic). Only rebuild the loop when the routed model actually changes, and disclose it.
            if autoRouting, let autoRoute {
                let decision = autoRoute(messageText, false, activeBinding)
                if decision.binding != activeBinding {
                    if let loopFactory {
                        loop = loopFactory(decision.binding, roleSelection.bindings, loop.isPlanMode, showReasoning, extendedThinking)
                    }
                    activeBinding = decision.binding
                }
                print("\u{001B}[37m↳ routed to \(Self.render(decision.binding)) (\(decision.reason))\u{001B}[0m")
            }

            armTurnLoop()   // apply the permission tier (plan/approvals); confirm bypass if just armed
            let compiled = briefCompiler?(messageText, roleSelection.bindings, perm.mode.isPlan ? .plan : .inline, humanTranscript) ?? messageText
            if let display = personaDisplay?(messageText) { print("\u{001B}[37m↳ \(display)\u{001B}[0m") }
            var enriched = attachCaptainContext(to: compiled, objective: messageText)
            // AUTO-EXPLORE: a lookup/find/self question ("find what we did for tinkyspeak", "how does your
            // X work") is answered from OUR OWN FILES, not the model's memory. Search the estate in-process
            // (full FS read, bypassing the tool sandbox) and inject what we find so the model stops
            // hallucinating about work it can't see. Fail-soft: no hits ⇒ a normal answer.
            if EstateLookupIntent.matches(messageText) {
                let search = EstateSearch()
                let mt = messageText
                print("\u{001B}[35m🔎 searching our files for context…\u{001B}[0m")
                if let grounding = await Task.detached(priority: .userInitiated, operation: { search.groundingBlock(for: mt) }).value {
                    let n = max(0, grounding.components(separatedBy: "\n### ").count - 1)
                    print("\u{001B}[35m🔎 grounded in \(n) file(s) from our estate\u{001B}[0m")
                    enriched = grounding + "\n\n" + enriched
                } else {
                    print("\u{001B}[37m🔎 no matching files — answering from general knowledge\u{001B}[0m")
                }
            }
            let transcriptBeforeModelAttempt = transcript
            var oc = await runTurnInterruptible(loop: loop, userInput: enriched)
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
                recorder?.reset()
                let replacementLoop = perm.arm(loopFactory(substitution.replacement,
                                                           roleSelection.bindings,
                                                           perm.mode.isPlan,
                                                           showReasoning,
                                                           extendedThinking))
                oc = await runTurnInterruptible(loop: replacementLoop, userInput: enriched)
            }
            rememberHumanTurn(user: messageText, assistantSummary: oc.summary)
            selfMonitor(goal: messageText, success: oc.success)
            await printTurnSummary(outcomeSummary: oc.summary, success: oc.success)
            // Default-on second opinion: a DIFFERENT model reviews this direct turn's work (diff or answer).
            await runCopilotReview(task: messageText, answer: oc.summary, allowAdvisory: true)
            await printTurnUsage()
        }
    }

    /// Read a line without echoing it (for pasting an API key inline). Falls back to a visible readLine
    /// when there's no controlling TTY (pipes/tests).
    static func readHiddenLine() -> String {
        if let c = getpass("") { return String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum DocumentExportRequestResult: Equatable {
        case notDocumentExport
        case handled(String)
        case failed(String)
    }

    static func handleDocumentExportRequest(_ input: String,
                                            humanTranscript: [ChatMessage],
                                            projectRoot: String,
                                            now: Date = Date()) -> DocumentExportRequestResult {
        guard DocumentExport.parseIntent(input) != nil else { return .notDocumentExport }
        do {
            guard let message = try DocumentExport.writeLatestAssistantDocument(input: input,
                                                                                transcript: humanTranscript,
                                                                                projectRoot: projectRoot,
                                                                                now: now) else {
                return .notDocumentExport
            }
            return .handled(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    struct SelfCodebaseAuditRequest: Equatable {
        var projectRoot: String
        var seedRepairs: Bool
    }

    static func selfCodebaseAuditRequest(_ input: String,
                                         currentProjectRoot: String,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) -> SelfCodebaseAuditRequest? {
        guard isSelfCodebaseAuditIntent(input) else { return nil }
        let current = ToolContext.canonicalize(currentProjectRoot) ?? currentProjectRoot
        if isKistSourceRoot(current) {
            return SelfCodebaseAuditRequest(projectRoot: current,
                                            seedRepairs: selfCodebaseAuditShouldSeedRepairs(input))
        }
        guard !isConcreteCodeProjectRoot(current) else { return nil }
        guard let root = resolveKistSourceRoot(currentProjectRoot: current, environment: environment) else {
            return nil
        }
        return SelfCodebaseAuditRequest(projectRoot: root,
                                        seedRepairs: selfCodebaseAuditShouldSeedRepairs(input))
    }

    static func isSelfCodebaseAuditIntent(_ input: String) -> Bool {
        let lower = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }
        let selfRefs = [
            "your codebase", "your code base", "your source", "your repo", "your repository",
            "your project", "your own code", "kist codebase", "kist source", "kist repo",
            "check yourself", "audit yourself", "self-test", "self test", "immune"
        ]
        guard selfRefs.contains(where: { lower.contains($0) }) else { return false }
        let auditWords = [
            "check", "chck", "audit", "review", "go through", "look through", "scan",
            "error", "errors", "bug", "bugs", "issue", "issues", "broken", "self-test",
            "self test", "immune", "fix", "repair", "heal"
        ]
        return auditWords.contains { lower.contains($0) }
    }

    static func selfCodebaseAuditShouldSeedRepairs(_ input: String) -> Bool {
        let lower = input.lowercased()
        let repairWords = ["fix", "repair", "heal", "patch", "apply", "resolve", "build it", "install"]
        return repairWords.contains { lower.contains($0) }
    }

    static func resolveKistSourceRoot(currentProjectRoot: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let current = ToolContext.canonicalize(currentProjectRoot) ?? currentProjectRoot
        if isKistSourceRoot(current) { return current }
        let home = environment["HOME"] ?? NSHomeDirectory()
        let envRoot = environment["KIST_SOURCE_ROOT"].flatMap { ToolContext.canonicalize($0) }
        var candidates = [
            envRoot,
            home + "/Downloads/kist-loops",
            home + "/kist-loops",
            home + "/Projects/kist-loops",
            home + "/Developer/kist-loops",
        ].compactMap { $0 }
        candidates.append(contentsOf: shallowKistSourceCandidates(in: home + "/Downloads"))
        candidates.append(contentsOf: shallowKistSourceCandidates(in: home))
        for candidate in uniquePaths(candidates) {
            if isKistSourceRoot(candidate) {
                return ToolContext.canonicalize(candidate) ?? candidate
            }
        }
        return nil
    }

    private static func isKistSourceRoot(_ path: String) -> Bool {
        let root = ToolContext.canonicalize(path) ?? path
        let fm = FileManager.default
        return fm.fileExists(atPath: root + "/Package.swift")
            && fm.fileExists(atPath: root + "/Sources/Kist/KistREPL.swift")
            && fm.fileExists(atPath: root + "/Sources/AgentCore")
    }

    private static func isConcreteCodeProjectRoot(_ path: String) -> Bool {
        let root = ToolContext.canonicalize(path) ?? path
        let fm = FileManager.default
        let markers = ["Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod", "deno.json"]
        if markers.contains(where: { fm.fileExists(atPath: root + "/" + $0) }) { return true }
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return false }
        return names.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    private static func shallowKistSourceCandidates(in directory: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names
            .filter { name in
                let lower = name.lowercased()
                return lower.contains("kist") || lower.contains("mythos")
            }
            .map { (directory as NSString).appendingPathComponent($0) }
    }

    private static func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in paths {
            let clean = ToolContext.canonicalize(path) ?? path
            guard !seen.contains(clean) else { continue }
            seen.insert(clean)
            out.append(clean)
        }
        return out
    }

    static func attachCaptainRetrievalContext(to prompt: String,
                                              retrieval: CaptainRetrievalContext) -> String {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = """
        ---
        CAPTAIN WORKING MEMORY
        This section is retrieved disk-backed memory for the current objective. Treat it as evidence, constraints, and decision rationale. Use it to research before expertise, expertise before organization, and organization before execution.

        \(retrieval.briefing)
        ---
        """
        if base.isEmpty { return block }
        return base + "\n\n" + block
    }

    /// Dragging a screenshot thumbnail into Terminal.app fires many drop events → the SAME file path gets
    /// typed dozens/hundreds of times (Luke: "1 image repeated 1000x"). Bracketed-paste de-dup misses it
    /// because a drag arrives as raw keystrokes, not a paste. So: at submit time, any path-like token that
    /// appears 3+ times is a flood — keep the FIRST occurrence, drop the rest, leave the real message intact.
    static func collapseFloodedPaths(_ input: String) -> String {
        let toks = input.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard toks.count > 3 else { return input }
        var counts: [String: Int] = [:]
        for t in toks where t.contains("/") && t.count > 12 { counts[t, default: 0] += 1 }
        let flooded = Set(counts.filter { $0.value >= 3 }.keys)
        guard !flooded.isEmpty else { return input }
        var seen = Set<String>()
        var out: [String] = []
        for t in toks {
            if flooded.contains(t) {
                if seen.contains(t) { continue }
                seen.insert(t)
            }
            out.append(t)
        }
        return out.joined(separator: " ")
    }

    /// The uncommitted working-tree diff vs HEAD (staged + unstaged) PLUS untracked NEW files. `git diff
    /// HEAD` omits untracked files entirely, so a turn that CREATES a file (very common — "write a new
    /// module") would otherwise produce an empty diff and the `/copilot` co-reviewer would review nothing.
    /// Untracked files are appended as synthetic `new file` blocks, bounded so a huge new asset can't blow
    /// context. Empty string when git is absent, not a repo, or nothing changed.
    static func workingTreeDiff(projectRoot: String) -> String {
        func git(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", projectRoot] + args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            // Read BEFORE waitUntilExit so a large diff can't deadlock on a full pipe buffer.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        var out = git(["diff", "HEAD"]) ?? ""
        let untracked = (git(["ls-files", "--others", "--exclude-standard"]) ?? "")
            .split(separator: "\n").map(String.init)
        var budget = 20_000   // total chars of untracked content to append (reviewPrompt re-clips to 12k)
        for rel in untracked where budget > 0 && !rel.isEmpty {
            let full = (projectRoot as NSString).appendingPathComponent(rel)
            // Skip binaries / unreadable files (non-UTF8 decode fails) — nothing textual to review.
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            out += Self.syntheticNewFileDiff(path: rel, content: content, maxChars: budget)
            budget -= min(content.count, budget)
        }
        return out
    }

    /// Format an untracked file as a synthetic unified-diff `new file` block so the co-reviewer reads a
    /// freshly-created file like any other change. Pure + testable; content clipped to `maxChars`.
    static func syntheticNewFileDiff(path: String, content: String, maxChars: Int) -> String {
        let clipped = content.count > maxChars
            ? String(content.prefix(maxChars)) + "\n… [new file truncated at \(maxChars) chars]"
            : content
        let body = clipped.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "+" + $0 }.joined(separator: "\n")
        return "\ndiff --git a/\(path) b/\(path)\nnew file\n--- /dev/null\n+++ b/\(path)\n\(body)\n"
    }

    /// The uncommitted changed file paths vs HEAD (name-only) — for the great-loop verifier's anti-gaming
    /// check (which files did this cycle touch). Empty when git is absent or nothing changed.
    static func workingTreeChangedFiles(projectRoot: String) -> [String] {
        // `git status --porcelain` — NOT `git diff --name-only HEAD` — because a from-scratch task's files
        // are UNTRACKED (the loop never `git add`s), and `git diff HEAD` misses untracked files entirely.
        // That made the continuity note empty → the loop re-created work already done → DUPLICATE packages
        // (root + subdir). Porcelain covers modified + added + untracked in one shot; `-uall` lists the
        // individual files inside new dirs, not just the dir.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", projectRoot, "status", "--porcelain", "--untracked-files=all"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return parseGitStatusPorcelain(String(decoding: data, as: UTF8.self))
    }

    /// Parse `git status --porcelain` output to a list of paths. Each line is `XY <path>` (2 status columns
    /// + a space); a rename is `R  old -> new` (we take the NEW path). Git-quoted paths (spaces/unicode) are
    /// unquoted. Pure, so the parsing is unit-tested without a git repo.
    static func parseGitStatusPorcelain(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line -> String? in
            let s = String(line)
            guard s.count > 3 else { return nil }
            var path = String(s.dropFirst(3))                 // drop the 2 status columns + the space
            if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }   // rename → new name
            path = path.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path = String(path.dropFirst().dropLast())     // git quotes paths with odd chars
            }
            return path.isEmpty ? nil : path
        }
    }

    /// Build the glanceable turn dashboard from live session state: the active model/team, the board, a
    /// derived confidence, and what's next. Pure over its inputs → the REPL just feeds it.
    static func buildDashboard(roles: RoleSelection, projectRoot: String,
                               trajectory: [ActionRecord], grounded: Bool) -> StatusDashboard {
        // Active Minds — the Captain is the orchestration process; models are workers it can assign.
        let fb = roles.fallback
        var minds: [StatusDashboard.Mind] = [
            .init(name: "Kist", role: "Captain"),
            .init(name: TeamLanguage.displayName(fb.providerId), role: "Default model")
        ]
        let bindings = roles.bindings
        for (role, label) in [(AgentRole.worker, "Research"), (.coder, "Builder"), (.critic, "Review")] {
            let b = bindings.binding(for: role)
            if b.providerId != fb.providerId {
                minds.append(.init(name: TeamLanguage.displayName(b.providerId), role: label))
            }
        }
        // Build Queue — actionable items only. Completed tasks drop away so the
        // board advances instead of repeating the same finished work each turn.
        let plan = PlanStore(projectRoot: projectRoot).load()
        let tasks = plan.buildQueue(limit: 6).map { t -> StatusDashboard.Item in
            let st: StatusDashboard.Item.State
            switch t.status { case .done: st = .done; case .blocked: st = .blocked; default: st = .pending }
            return .init(title: t.boardTitle, state: st)
        }
        let insights = DashboardResearchPlanner.build(for: plan, projectRoot: projectRoot,
                                                       trajectory: trajectory)
        let learning = OrganizationalLearningStore(projectRoot: projectRoot)
        let debts = learning.openKnowledgeDebt(limit: 8)
        let latestCapsule = learning.latestCapsule()
        let persistedResearch = debts.map { debt -> StatusDashboard.ResearchItem in
            .init(title: debt.topic,
                  priority: debt.priority == .high ? .high : .medium,
                  reason: debt.reason,
                  visit: debt.visit,
                  impact: debt.impact,
                  estimatedLearning: debt.estimatedLearning,
                  expectedBenefit: debt.expectedBenefit)
        }
        let persistedKnowledge = debts.map { debt -> StatusDashboard.KnowledgeDebt in
            .init(need: "Need to research", topic: debt.topic,
                  impact: debt.expectedBenefit.first ?? debt.reason,
                  severity: debt.impact)
        }
        // Confidence — grounded, healthy, low-failure ⇒ high. The ConfidenceReport keeps the FACTORS
        // (reliability/health/grounding) so the panel shows a battery gauge + the top drag and
        // `/confidence` can explain why. nil when there were no actions (a plain answer).
        let confidenceReport = ConfidenceReport.compute(report: TrajectoryAnalyzer.analyze(trajectory),
                                                        grounded: grounded)
        // "Next" must not FREEZE on a stale board task when the user just asked a QUESTION that never
        // touched the board (Luke's "I asked something and Next never changed" bug — a task stuck
        // inProgress made plan.active return it forever). Only surface a specific board Next when THIS
        // turn actually worked the board (a file mutation or the `tasks` tool); otherwise "Continue".
        let workedBoard = trajectory.contains { ($0.success && Copilot.mutatingTools.contains($0.tool)) || $0.tool == "tasks" }
        let next = workedBoard
            ? (plan.active?.boardTitle ?? plan.nextActionable?.boardTitle ?? plan.next?.boardTitle ?? "Continue")
            : "Continue"
        return StatusDashboard(minds: minds,
                               tasks: Array(tasks),
                               learned: latestCapsule?.learned ?? [],
                               research: Self.mergeResearch(insights.research + persistedResearch),
                               knowledgeDebt: Self.mergeKnowledgeDebt(insights.knowledgeDebt + persistedKnowledge),
                               questions: insights.questions,
                               futureEvolution: latestCapsule.map {
                                   .init(capability: $0.futureEvolution,
                                         estimatedImpact: "High")
                               },
                               observation: insights.observation,
                               confidenceReport: confidenceReport,
                               next: next)
    }

    private static func mergeResearch(_ items: [StatusDashboard.ResearchItem]) -> [StatusDashboard.ResearchItem] {
        var seen = Set<String>()
        var out: [StatusDashboard.ResearchItem] = []
        for item in items {
            let key = item.title.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(item)
            if out.count == 6 { break }
        }
        return out
    }

    private static func mergeKnowledgeDebt(_ items: [StatusDashboard.KnowledgeDebt]) -> [StatusDashboard.KnowledgeDebt] {
        var seen = Set<String>()
        var out: [StatusDashboard.KnowledgeDebt] = []
        for item in items {
            let key = item.topic.lowercased()
            guard seen.insert(key).inserted else { continue }
            out.append(item)
            if out.count == 5 { break }
        }
        return out
    }

    private func printHelp() {
        print("""
        \u{001B}[37m  /help             this help
          /code [prov[:m]]  coding mode — pin the strong coder (DeepSeek V4 Pro), routing off, research opt-in;
                            just describe what to build (e.g. /code claude-cli for the Max sub)  [alias /c]
          /model            arrow-key model picker (↑/↓ · filter · enter/esc); green = ready, red = needs a key  [alias /m]
          /model import <url>
                            import any OpenAI-compatible model: discover models at the URL → add API key →
                            self-heal/self-test/pen-test onboard → persists (shows green in the picker)
          /model scout <g> safe local/Hugging Face model acquisition plan; no downloads, writes eval gates
          /model vet <hf:model|mlx:model|ollama:model>
                            fetch live metadata and apply license/provenance/size gates before any download
          /model acquire <manifest.json>
                            verify acquisition manifest hash/commands and seed dry-run/download/onboard gates
          /model <prov[:m]> switch the model this conversation talks to (e.g. /model openai:gpt-5.5,
                            /model gemini, or /model :<model> to change model on the current provider)
          /chain "a" | "b"  run tasks in sequence, each as its own turn (stops on first failure)  [alias /pipeline]
          /copilot [on|off] auto second-AI review of the diff after each coding turn (advisory only)  [alias /cp]
          /copilot lead <m> · /copilot co <m>
                            assign who writes the code (lead) and who reviews the diff (co)
          /paste [question] read clipboard media (screenshot, image file, video, audio, PDF) and ask  [alias /v]
          <drag a file in>  drag an image / video / audio / PDF from Finder onto the line — the path
                            is detected, attached, and read by a vision model (Gemini for video/audio)
          /media <path>     preview an image/video poster inline in iTerm2, WezTerm, Kitty, or Ghostty
          /reasoning [on|off]
                            show/hide provider reasoning streams. Off by default; tool scratch text stays hidden.
          /plan [on|off]    plan mode: read-only; the agent proposes a plan (bare /plan toggles)
          /config [k=v]     settings panel over .kist/settings.json (bare shows, k=v sets)  [alias /settings]
          /context          estimated context-window breakdown (what's filling it)  [alias /ctx]
          /compact [focus]  summarize older history to free context; keeps recent turns verbatim
          /theme [name]     color palette: default/dark/light/daltonized(CVD)/high-contrast/mono(screen-reader)
          /skills           list discovered skills + token cost (what agents can preload)
          /mcp              list configured MCP servers (what agents can reach)
          /hooks            list lifecycle hooks (.kist/hooks.json)
          /permissions      current permission tier + which tools still prompt  [alias /perms]
          /goals            show the shared goal/action/test board  [aliases /goal /tasks /todo]
          1                 run task [1] from the board through plan→execute
          /action <step>    add an ACTION step to the shared board
          /test <step>      add a TEST step to the shared board
          /review <step>    add a REVIEW step to the shared board
                            add acceptance/proof with: | acceptance: ... | verify: ... | evidence: ...
          /plan-execute <g> build it as a typed plan-DAG (your team: planner→coder→critic)  [alias /pe]
          /council [--execute] <g>
                            ask researcher/architect/coder/critic/UX/memory minds, save a kanban board,
                            and optionally hand the builder brief to plan-execute  [alias /consult]
          /research <g>     gather an evidence dossier, run council over it, and seed the task board
          /legal-research <g + optional doc path>
                            legal research mode: ingest/OCR-extract docs where possible, require jurisdiction,
                            official sources first, then hand off to /research for a cited memo
          /fleet-status     the Terminal Captain cockpit: latest fleet's per-agent status + merge-fate  [alias /cockpit]
          /fleet [--agents N|--agents=N] <g>
                            spawn a SUPERVISED parallel fleet for the goal — disjoint-lease agents,
                            forge-proof signoff, joined to a fresh integration branch (never main)  [alias /team]
          /roles            show role bindings used by /fleet and /plan-execute
          /roles coder deepseek
                            assign a provider/model to a role. Roles: planner, worker/researcher, coder/builder, critic
                            model form: provider:model, e.g. /roles critic gemini:gemini-3.1-pro
          /roles reset      reset every role to the default provider/model
          /roles save <n>   save the current AI team as a named profile
          /roles load <n>   load a saved AI team profile
          /roles profiles   list saved AI team profiles
          /roles delete <n> delete a saved AI team profile
          /agent new <desc> forge a reusable specialist/personality from plain English
                            aliases: /agents new, /persona new, /specialist new
          /agents           list saved specialists; /agents show <name> shows the prompt/tools/model
          /agents run <name> <task>
                            hard-spawn a specialist (own context/tools/model/limits); returns its summary
          /tasks            show the shared Plan/Action/Test/Review board (.kist/plan.json)
                            add/start/done/block/evidence/validate/clear; the agent uses this same board
          <plain English>   you can also just SAY it: "use deepseek as builder and gemini as critic",
                            "switch to gemini", "make me an agent that audits SwiftUI" — it rebinds
                            the runtime or forges the specialist
          /providers        list provider ids available for /roles
          /health           offline provider/model/router health
          /probe            live one-token provider probe (catches stale model ids)
          /usage            rich session + local-week token/cost panel
          /summary          simple human summary: happened / changed / failed / next
          /confidence       explain the last turn's score and what would raise it  [alias /why]
          /failures         show latest failure capsule; /failures verify <evidence> closes repair loop
          /reflect          show the latest Learning Capsule; /reflect now captures one from current state
          /knowledge        show persistent Knowledge Debt; add/done manage debt items
          /teach            show permanent organizational rules; add promotes a lesson into Captain
          /learning         show benchmark/live-eval model learning and promotion status
          /industry         show Strategic Intelligence records and evolution proposals
          /retrieve <g>     retrieve relevant disk-backed memory into Captain's context window
          /captain <g>      show research-first strategy, expertise needs, and specialist gaps for an objective
          /legal <g>        alias for /legal-research; research support only, not legal advice
          /domain <g>       learn an unfamiliar domain first; add run/now to dispatch research/simulation/critic specialists
          /model-acquire <manifest.json>
                            verify a local-model acquisition manifest without downloading
          /model run <stage> <manifest.json>
                            run a verified local-model acquisition stage: dry-run, download, inspect,
                            onboard, or benchmark
          /self-heal [run]  turn Captain's own observation into assigned repair agents + gated tasks
          /self-test        run Captain's deterministic self-audit and write a report; add run/--seed for repair tasks
          /immune [check]   run self-test + repair/simulation evidence loop; default seeds repair tasks
          /simulate <g>     sandbox-simulate a plan, run probabilistic trials, compare risk, seed evidence gates
          /symbolic         compile/reuse deterministic workflow gates: list · compile <g> · run <id> <target>
          /evolve           board meeting: reflect, rank knowledge debt, create specialists, seed research tasks
          /logs             proof drawer for the last turn: tools, outputs, failures  [alias /details]
          /replay [id]      durable run replay from .kist/runs (current: \(replayRunID ?? "none"))
          /bench <task>     provider bake-off for this task
          /eval <task>      deterministic agent-behavior eval for this task
          /protocols        MCP/A2A/browser/computer-control status
          /commands         list custom .kist/commands
          /save-chat [path] export this conversation to Markdown in the project root
          /clear            forget the conversation so far
          /exit /quit /q    leave
          prompt keys       ↑/↓ history · Tab completion · live command/code highlighting
          Enter sends only when the » prompt is visible; while a turn streams, wait for the next prompt.
          <anything else>   ask / build with the agent (it can read/search/edit/run in the project
                            and, with approval, control apps/browser/Desktop)\u{001B}[0m
        """)
    }

    private func printModels(current: ProviderBinding) {
        print("model · \(Self.render(current))")
        guard !providerLabels.isEmpty else {
            print("\u{001B}[37m(provider catalog unavailable — use /providers)\u{001B}[0m")
            return
        }
        print("\u{001B}[37mswitch with: /model <provider[:model]>  or  /model :<model> (keep current provider)\u{001B}[0m")
        for label in providerLabels {
            // providerLabels entries look like "openai" or "openai (missing key)".
            let id = label.split(separator: " ").first.map(String.init) ?? label
            let models = providerModels[id.lowercased()] ?? []
            let modelList = models.isEmpty ? "" : "  \u{001B}[37m" + models.joined(separator: ", ") + "\u{001B}[0m"
            print("  \(label)\(modelList)")
        }
    }

    private static func render(_ binding: ProviderBinding) -> String {
        binding.providerId + (binding.model.map { ":\($0)" } ?? "")
    }
}
