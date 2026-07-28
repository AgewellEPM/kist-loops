# Captain UX Overhaul Plan — 2026-07-28

**Status: PLAN (approved scope from Luke, 2026-07-28). Each R-increment ships separately, tested, own branch.**

Luke's asks, verbatim intent:
1. **ESC works like Claude Code** — single ESC while working = interrupt and process what I typed; double ESC = cancel everything back to an empty prompt.
2. **Chat bar lives 24/7** — input line never disappears while the model works; I can type anytime.
3. **Micro-tasks, always visible** — no more one giant lump burning 78 minutes at "~0 tok"; every goal decomposed into small single-purpose steps with live per-step progress.
4. **Tag-team that actually works** — "bring in X" = model A codes, model B immediately reviews, A fixes what B found, auto-loop, then next section.
5. **Symbolic learning wheels + Tavily** — grounded evidence built and reused during coding, not just printed.
6. **Stuck-loop watchdog** — after X minutes of no progress, a DIFFERENT model comes in, diagnoses, breaks the pattern, steers back to work.

## Ground truth (from 7-agent recon + adversarial critique, all claims code-verified)

**What the 69–78 min / ~0 tok hang actually was (the screenshots):**
- `PlanExecuteLoop` emits `.planReady` then blocks in `requestApproval` (PlanExecuteLoop.swift:178-180). `TerminalEventSink` has **no case for `.planReady`** — it hits `default: break` (TerminalEventSink.swift:170-171). The planning spinner's 1s timer keeps writing `\r◇ …\e[K` over the prompt's input line. The prompt is alive but invisible; the session looks hung.
- The dangerous-step gate `approveDangerousStep` (PlanExecuteLoop.swift:116-118) calls `requestApproval` with **no event at all**, under the live "working" spinner (PlanExecutor.swift:61). Same burial, second site.
- "~0 tok" is a display lie: `meteredComplete` uses non-streaming `completeWithUsage` (PlanExecuteLoop.swift:85) and never emits `.usage`/`.tokenDelta` — `streamedChars` stays 0 for the whole planning window.
- (`HeadlessAgentLoop.approve()` is NOT the bug — it emits `.awaitingApproval` which correctly stops the spinner.)

**ESC today:**
- Chat turns (HeadlessAgentLoop plane) already have single-ESC cancel via `InterruptibleTurn` (raw-mode watcher, `readByteTimed() == 0x1B` → `task.cancel()`), checkpoint saved as resumable.
- **BUG: arrow keys cancel turns.** The watcher compares the raw first byte; Up-arrow sends `ESC [ A` → cancelled. KeyDecoder's ESC-vs-CSI logic exists only in the prompt readers, not the watcher (InterruptibleTurn.swift:42).
- **ESC is dead on the longest runs.** StdinArbiter's contract excludes plan-execute/fleet/council (StdinArbiter.swift:22-25) and `PlanExecuteLoop`/`PlanExecutor` contain zero `Task.isCancelled` checks — and the REPL auto-escalates plain chat into that plane (KistREPL.swift:1728). Luke's "ESC does nothing" experience is this.
- No double-ESC anywhere; typed keys during a turn are silently discarded (InterruptibleTurn.swift:12-14).

**Input bar today:** line-mode REPL blocks in `EnhancedPromptReader.readLine()`; prompt box only reappears after the turn (KistREPL.swift:721-756). The `--tui` PROTOTYPE (TerminalUI + scroll regions + LineEditor + RawMode) already has the persistent-bottom-box architecture but its `readLine()` also blocks during streaming. Deferred-input queues exist (TerminalInteractor.deferredInputs, KistREPL.deferredInput) but are only consumed between turns.

**Micro-tasks today:** PlanExecuteLoop builds a typed DAG (the E1..E8 in the screenshot) but the terminal never renders which step is live; steps are atomic (no sub-progress); the pirate spinner labels (ThinkingWords.swift) wrap whole phases.

**Tag-team today:** TagTeamKit (ReviewPanel, DeepSeekReviewer/CodexReviewer, ReviewClassifier) exists but **is not linked into the Kist target** (Package.swift: Kist depends only on AgentCore; TagTeamKit belongs to designflow). `bring` IS in ControlIntentParser's directive verbs but only as a bare model switch. Copilot review runs post-turn, advisory-only, never loops. Role bindings (coder/critic) exist but the REPL chat path ignores them.

**Watchdog today:** three uncoordinated recovery layers exist — ToolSpiralDetector (3 identical failures → steer), ProgressGovernor (intra-run stuck → one hard reset → fail), post-turn `modelSubstitutionDecision` (bench a failing model, re-run turn on a replacement, KistREPL.swift:1755-1771). Nothing observes token-rate stall from OUTSIDE the loop; nothing brings in a second model mid-run; unanswered approval prompts age invisibly.

**Symbolic research today:** `/research` shells to `~/bin/jeeves-research` (Tavily→PEEL→GraphReasoner) but its stdout is only printed, never captured/indexed. `researchArchiveRoot` EXISTS and is retrieved (`researchArchiveCandidates`, OrganizationalLearningStore.swift:3781) — but ResearchRunTool reports and bridge output are never written into it. No Tavily backend in WebSearchTool (Brave/DDG only). No auto-research on knowledge-miss.

## The load-bearing decision (critique's #3)

**One terminal owner.** Today stdin/rendering ownership is split across the watcher, two interactor paths, two prompt readers, and a spinner timer that doesn't know when prompts are alive — the burial class of bugs falls out of that split. Everything below builds toward a single **InputRouter** that owns stdin in raw mode 100% of the session, decodes keys once (KeyDecoder), and routes them: ESC-intent → turn control; text → the always-alive bottom bar; approval keys → whoever registered a pending prompt. Renderers (sink, prompt bar, approval banner) all draw through one screen coordinator that knows the scroll region. R1/R2 land it; R0 hotfixes don't wait for it.

---

## R0 — STOP THE BLEEDING (hotfixes, no architecture)

*The four one-file fixes that kill the live pain. Ship first.*

1. **Handle `.planReady` in TerminalEventSink**: stop the live spinner (`finishLiveStatus()`), render the plan summary (E1..EN one-liners) + a loud `⏸ WAITING FOR YOUR APPROVAL` banner. (TerminalEventSink.swift switch + PlanExecuteLoop planReady payload.)
2. **Event-wrap `approveDangerousStep`**: emit `.awaitingApproval` before and a resume event after, so the spinner stops for dangerous-step gates too (PlanExecuteLoop.swift:116-118, mirrors HeadlessAgentLoop.approve()).
3. **Watcher CSI disambiguation**: in InterruptibleTurn, after reading 0x1B, drain with a ~50ms window; `[`/`O` follow-byte ⇒ CSI/SS3 (arrow/function key) ⇒ swallow, do NOT cancel. Fixes "arrow key kills the turn" today and is the prerequisite decoder for double-ESC.
4. **Emit usage from `meteredComplete`**: forward provider usage to the sink so planning shows real token counts (kills the "~0 tok" lie).
- Tests: sink snapshot test for planReady (spinner stopped + banner), event-order test for the dangerous gate, watcher byte-sequence tests (ESC alone cancels; ESC-[-A does not), usage-emission test.
- Exit: a plan-approval prompt can no longer be buried; arrows are safe. **Label: PILOT-READY on merge.**

## R1 — ESC SEMANTICS (single = interject, double = cancel)

- Replace the watcher's byte-compare with a small key state machine (reuses R0.3 decoder): first ESC (not CSI) starts a ~350ms window → second ESC inside window = **double**; window expiry = **single**.
- `InterruptFlag` grows `reason: .interject | .cancel`.
- **Single ESC**: cancel the in-flight turn (checkpoint saved, resumable as today), then immediately process the queued input from the bottom bar (R2) — or if nothing typed, drop to the prompt with `⏸ interrupted — type your instruction (turn resumable: --resume)`.
- **Double ESC**: hard cancel — discard queued input, mark checkpoint `abandoned` (new state, not `paused`), fresh empty prompt.
- **Kill the dead zone**: add cooperative `Task.isCancelled` checks in `PlanExecuteLoop` (before/after `meteredComplete`, between DAG waves) and `PlanExecutor` (between steps), and run plan-execute turns under InterruptibleTurn (extend the StdinArbiter contract). ESC must work on EVERY interactive plane, or Luke hits the same wall on exactly the runs that matter.
- Tests: state-machine timing tests; per-plane cancellation tests (chat turn, plan-execute turn, dangerous-gate wait); abandoned-vs-paused checkpoint tests.
- Exit: ESC and double-ESC work identically in chat and plan-execute planes. **PILOT-READY.**

## R2 — PERSISTENT INPUT BAR (Claude-style, 24/7)

- Introduce **InputRouter** (the one terminal owner): raw mode for the whole session, `AsyncStream<TerminalKey>`, consumers register (turn-control, line editor, approval prompt). StdinArbiter's pause/resume becomes internal routing instead of mode flipping.
- Promote the TUI's scroll-region architecture into the DEFAULT REPL: output streams in the upper region (sink unchanged apart from a screen-coordinator handle); bottom 2–3 lines = PromptBar, always rendered, always accepting keys.
- Typing during a turn: text accumulates in the bar live; Enter queues the message (visible as `↳ queued`), consumed at turn end — or immediately on single-ESC (R1). Multiple queued messages FIFO.
- Approval prompts render IN the bar region (sticky, cannot scroll away), spinner pauses while pending, re-rendered after every output burst; `[Enter]/[n]/[a]` keys routed only when a prompt is registered.
- `--tui` flag becomes a no-op alias once stable.
- Tests: router unit tests (key routing per registered consumer); queued-message FIFO; approval-during-streaming pin (prompt visible after 500 output lines); no-regression pin for plain `kist "goal"` one-shot (no REPL).
- Exit: bar never disappears; typing mid-turn works; prompts physically cannot be buried. **PILOT-READY** (this is the R most likely to need a live-terminal shakedown before calling it more).

## R3 — MISSIONS + MICRO-TASKS AS SINGULAR LOOPS (kill the lump)

**The unit-of-work contract (Luke's rule, verbatim intent: "minify tasks into individual
singular loops, not 1 big-ass request"):**
- A **mission** = one coherent chunk of the goal (maps to a DAG wave / task-board card).
- A **micro-task** = ONE singular action (one tool, one intent, ~≤2 min) and it executes as its
  **own bounded loop invocation** — its own small iteration budget, its own verify-before-done
  check, its own visible start/finish line — not as an anonymous slice of one giant turn.
- Rendering hierarchy is always on screen: `Mission 2/3 · E3/E8 · <micro-task> · 12s · 4.1k tok`.
- A micro-task that fails verify retries or escalates ON ITS OWN, without restarting the mission;
  the mission card shows which micro-task is red. This is also the granularity the watchdog (R5)
  and tag-team (R4) hook into — per micro-task, not per mega-request.

- **Always-visible step line**: during execution the status line reads `E3/E8 · <step title> · 12s · 4.1k tok` (extend `.stateChanged`/`actionStarted` payloads + sink).
- **Plan DAG print at execution start** (compact E1..EN list with tool names — same list the approval banner shows in R0.1).
- **Planning-phase streaming**: switch `meteredComplete` to the streaming completion path so tokens tick during planning (R0.4 shows totals; this makes it live).
- **Sub-step progress for long tools**: a `ToolProgressSink` seam in `tools.execute` — RunCommandTool streams child stdout lines as progress events; generate-style tools stream LLM deltas. Sink renders as dim sub-lines under the current step.
- **Decomposition pressure**: planner prompt gains a hard rule — no step may bundle unrelated actions; target ≤ ~2 min of work per step; steps must be singular ("one tool, one intent"). Enforced by a plan-lint that REJECTS (not just warns on) a plan whose steps bundle >N tools, sending it back to the planner to split — a lumpy plan never reaches execution.
- **Micro-task = own loop invocation**: PlanExecutor runs each step through a bounded per-step loop (small iteration cap + per-step verify) instead of a bare `tools.execute` — failures retry/escalate at step granularity and every step gets a start/finish line. Missions = DAG waves, surfaced as task-board cards (`/tasks` and the status line agree).
- **Phase watchdog hook**: any spinner phase >5 min with zero tokens AND zero tool events emits a visible `⚠ no progress for 5m — <what we're waiting on>` line (feeds R5).
- Tests: event-payload tests; sink render snapshots; plan-lint reject/split tests; per-step-loop bound + verify tests; mission/card ↔ status-line consistency pin.
- Exit: at any moment the terminal answers "which micro-step are we on and what is it doing". **PILOT-READY.**

## R4 — TAG-TEAM AUTO-LOOP ("bring in X")

- **Package.swift first**: add TagTeamKit to the Kist target's dependencies (it is currently unlinkable — recon's build blocker).
- **Intent**: extend ControlIntentParser — `bring in <model> [to review/to code]`, `tag team <A> and <B>` → `tagTeam(coder:critic:)` intent (defaults: current model codes, named model critiques; role bindings honored when set via `--coder/--critic` or `/roles`).
- **TagTeamLoop** (new file, Sources/Kist/): per section —
  1. Coder turn runs (existing loop, coder binding).
  2. `workingTreeDiff(projectRoot)` → ReviewPanel (critic binding) → classified verdicts (BLOCKER/HIGH/…).
  3. Verdicts ≠ clean → feed findings back to the coder as a fix turn. Loop until clean or cap (default 3 rounds; configurable).
  4. Clean → next section (sections = plan steps from R3's DAG when present, else whole-turn granularity).
- Every round is visible in the R3 status line (`tag-team r2 · critic found 2 HIGH · coder fixing`).
- Budget: rounds draw from the shared BudgetLedger; cap halts honestly with findings listed.
- Tests: parser tests for the new intents; TagTeamLoop unit tests with stubbed reviewers (clean-first-round, fix-then-clean, cap-hit); Package link test (import TagTeamKit from Kist compiles).
- Exit: "bring in deepseek to review" in chat produces a visible code→review→fix loop. **PILOT-READY.**

## R5 — STUCK-LOOP WATCHDOG (second-model rescue)

- **StuckLoopWatchdog** observes from OUTSIDE the loop via the existing event stream + `recordLLMSpan` chokepoint: token-rate per iteration, identical-call fingerprints (below spiral threshold), unanswered-prompt age, wall-clock per phase.
- Trigger (any): 0 completion tokens across N spans; >X min in one phase with no tool events (R3's hook); prompt unanswered >Y min; governor about to hard-fail.
- Action: pause the primary loop at the next checkpoint boundary → invoke a DIFFERENT provider (prefer cross-vendor via ModelEscalator.pick) with checkpoint + TrajectoryAnalyzer summary + "why is this stuck; produce a pattern-breaking steer" → inject the steer as a user-role message (same mechanism as capabilityDenialSteer) → resume. One diagnosis per stretch, budget-capped, recorded in `LoopCheckpoint.diagnostics` (new field) so resume never re-diagnoses.
- **Precedence (must be explicit, we already have 3 arbiters):** ToolSpiralDetector (cheap, first) → ProgressGovernor (intra-run) → **Watchdog diagnosis (before governor's terminal fail)** → post-turn modelSubstitution (last resort, replaces the model). Watchdog defers when a cheaper layer just fired.
- Unanswered-prompt case: watchdog doesn't spend tokens — it re-renders the prompt banner + rings the terminal bell (R2 makes burial impossible anyway; this is the belt).
- Tests: trigger-condition unit tests with synthetic span streams; precedence tests (spiral fires ⇒ watchdog holds); diagnostics-in-checkpoint round-trip; budget-cap test.
- Exit: a deliberately-stalled loop (test harness) gets a cross-model diagnosis and resumes within the trigger window. **PILOT-READY.**

## R6 — SYMBOLIC LEARNING WHEELS + TAVILY GROUNDING

- **Capture the bridge**: `runSymbolicResearch` captures jeeves-research stdout (verbatim tiles + verdicts) instead of print-only; writes a run record.
- **Index into the EXISTING archive**: write ResearchRunTool `report.md` summaries AND bridge output into `researchArchiveRoot` in the exact format `researchArchiveCandidates` already consumes (do NOT build a parallel archive — recon's SeamA corrected).
- **Tavily backend in WebSearchTool**: `TAVILY_API_KEY` (already in `~/.config/kist/secrets.env`) → Tavily-first backend ahead of Brave/DDG; per-result verbatim content preserved for grounding.
- **Auto-research on knowledge-miss**: when captain retrieval returns empty for an unfamiliar objective (the existing domain-learning gate signal), auto-fire a bounded research pass FIRST (visible as an R3 micro-step: `E0 · researching <topic>`), findings indexed, then planning proceeds citing them.
- **Wheels as evidence in the loop**: retrievalContext injects matching archive entries with source attribution; decision cards' `evidenceIDs` become followable (store id → file path mapping).
- Tests: archive round-trip (write → `researchArchiveCandidates` retrieves); Tavily backend unit test (mocked HTTP); knowledge-miss trigger test; bridge-capture test.
- Exit: `/research` output is reusable in later sessions and the coding loop cites it. **PILOT-READY.**

---

## Sequencing & rules

- Order: **R0 → R1 → R2 → R3 → R4/R5/R6** (R4-R6 independent after R3; can interleave).
- Each R: own branch, tests green, Codex/adversarial review, deploy via the kist-loops recipe (`swift build -c release --product kist` → cp → `codesign -f -s -`), live-verify in a real terminal before the label sticks.
- Per multi-site discipline: every seam list above is a SURFACES list — one regression assertion per site, plus the R0.3 decoder gets both planes pinned.
- Honest labels: everything enters as PROTOTYPE on branch, becomes PILOT-READY only after live verification. Nothing here claims PRODUCTION-READY until the whole set has soaked in Luke's daily driver.

## Open questions for Luke (defaults chosen, override anytime)

1. Double-ESC window: 350ms default feel OK? (Claude Code-ish.)
2. Watchdog stall threshold: default 5 min no-tokens/no-tools before second-model diagnosis (configurable `--watchdog-mins`).
3. Tag-team default critic when none named: strongest OTHER configured provider (cross-vendor), or always ask?
