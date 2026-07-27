# substrate-hardening → main — integration plan (research-grounded)

CLEAN auto-merge (0 conflicts). 63 files, +7472/-79. Build clean. **2839 tests, 0 failures** (+322).

## What it is (3 additive subsystems)
1. **Computer-Use / desktop control** — DesktopControlTool (CGEvent mouse/keyboard injection + screen
   capture, macOS), Moondream point-to-click (locate/tap/point_click), perception (StreamingPerception,
   PerceptionMonitor, look/wait_for_screen/watch_screen), Accessibility grounding (ui_elements, ax_press),
   multi-display (DisplayGeometry), computer_use preflight+selftest, screen-driver specialist.
2. **Equivalence "cathedral"** (legacy modernization) — EquivalenceVerdict/Run/Report, CanonicalForm,
   JSONCanonicalizer, InputSynthesizer, BoundaryCatalog, MutationMeter, PortEvidence/Verifier, GoldenCorpus.
   Self-contained; not wired into the agent loop.
3. **RunLedger / TaskRouter / RunAnalytics** — decision→outcome spine + complexity routing. Additive.

## 5 modified files (integration surface)
- **AgentHooks.swift** — hook `decision(fromOutput:)` now fail-SAFE across multiple JSON objects (any
  `block:true` wins immediately; else last decision). Depends on ActionParser.candidateJSONObjects.
- **HeadlessAgentLoop.swift** — inline `ActionParser` DELETED (extracted to new ActionProtocolParser.swift).
- **KistRunner.swift** — wires computer-use tools + gating (below).
- **KistRunnerSafetyTests + LoopToolFilterTests** — assert every new desktop tool is approval-gated + loop-dropped.

## Security posture for desktop_control (input injection) — LAYERED, verified in source
1. `sensitiveTools` → interactive approval (human confirms).
2. `isLoopIrrelevantTool` → DROPPED from the autonomous great-loop (runGreatLoop uses filtered loopTools),
   so an autonomous coding agent CANNOT call it.
3. `AXIsProcessTrusted()` OS gate (DesktopControlTool:150) — input actions physically fail without OS-granted
   Accessibility. Hard backstop everywhere.
4. Moondream tools only wired when MOONDREAM_API_KEY / MOONDREAM_BASE_URL set (no silent network dep).

## Exposure points (explicit user invocations; OS gate still applies)
- `--yolo`: auto-approves (explicit guards-off opt-out).
- `--eval`: dev harness (AutoApproveInteractor + full unfiltered tools).
- **Note**: PentestTool comment says "never headless set" but it's appended in buildTools which starts
  from ToolRegistry.headless() — comment appears STALE (pentest has its own allowlist+approval+audit).

## Plan
Land the clean additive merge. Council scrutiny points (below) before commit; then Codex gate.

---
## COUNCIL VERDICT (2026-07-03): NO-SHIP as-is — unanimous (DeepSeek/GPT-5/Grok/Gemini/Codex)

### CRITICAL: unattended desktop input injection (bigger than first modeled)
`desktop_control` is classified `.mutating` (NOT `.dangerous`), and the NORMAL one-shot path calls the
loop with no approvalTools → it FALLS THROUGH and runs UNATTENDED in ordinary `kist "goal"` (no --yolo
needed). Same on --eval/--bench (AutoApprove+full tools), spawned sub-agents (inherit baseTools), and
fleet plan-execute (requireApproval:false). `isLoopIrrelevantTool` only filters the great-loop, not these.
With Accessibility granted (which every computer-use user grants), mouse/key injection can fire unattended.
Plus self-reinvocation: the filtered agent still has run_command → can spawn `kist --eval`/`--yolo`.

### REQUIRED before landing
1. **Computer-use = default-deny CAPABILITY at registry construction.** Only include desktop_control/AX/
   screen tools under an explicit computer-use mode (e.g. --enable-computer-use), and FILTER them from
   one-shot, eval, bench, fleet, spawned-agent, and coding loops unless deliberately armed. Consider
   reclassifying desktop_control `.dangerous` so the approval floor catches it everywhere.
2. **Block elevated self-reinvocation** — a spawned/child kist refuses --eval/--yolo/sensitive-tools
   (parent marks the environment; child fail-closed).
3. **ActionParser differential golden test** — old(inline ~71-line, first-object) vs new(417-line, ranked
   candidates, relaxed JSON, first-vs-last CHANGED) over the transcript corpus + fuzz; assert identical
   dispatch for all previously-valid outputs. NOTE: the parser was NOT extracted verbatim — semantics
   changed; this needs reconciliation, not just a test.
4. **SPLIT the merge** — 3 unrelated subsystems / 7472 lines. Land: (a) parser(+golden test)+hooks,
   (b) equivalence cathedral, (c) RunLedger/TaskRouter analytics — THEN (d) computer-use behind the
   default-deny capability gate as its own hardened merge.

### NOT a blocker (Codex, real-code read; overrules 3 API models)
- AgentHooks "any block wins, else last decision": block:true can NEVER be overridden; "last" only affects
  allow/reason METADATA, not enforcement. Directionally fine — do not block on it.

### Status: trial merge ABORTED (analysis only, nothing committed). Awaiting Luke's chosen path.

---
## MECHANICS CORRECTION (2026-07-03): file-split is UNSAFE — must be merge-then-harden

The branch's MODIFIED files (AgentHooks.swift, HeadlessAgentLoop.swift) are based on an OLDER main and,
if cherry-picked directly, would SILENTLY REGRESS HEAD security:
- AgentHooks: drops `rlimitPreamble` (hook resource limits) AND `loadTrusted`/`userHookPaths`/`projectHookPath`
  (the untrusted-workspace-hooks RCE protection — the "kist-modularized security fix") AND lifecycle events.
- HeadlessAgentLoop: reverts the aplus budget work (driveNative/recordLLMSpan) + drops userPromptSubmit hook firing.
The full 3-way `git merge` reconciles these correctly (HEAD's newer security is kept as HEAD-only additions;
only the branch's genuine new work — ActionProtocolParser extraction, decision() fail-safe — applies).

### Corrected execution: MERGE (3-way, safe) → then HARDEN in place
1. Full 3-way merge onto a fresh branch (correct reconciliation; clean, 2839 tests).
2. Harden computer-use to DEFAULT-DENY at registry construction (armed only under an explicit computer-use
   mode; filtered from one-shot/eval/bench/fleet/spawn/coding loops); reclassify desktop_control .dangerous;
   block elevated self-reinvocation (child kist refuses --eval/--yolo/sensitive when spawned).
3. ActionParser differential golden test (single-object parity proven; multi-object last-intent documented
   as intentional).
4. Council + Codex gate; land.
Reviewability (the council's split rationale) is served by reviewing the computer-use hardening diff in isolation.

---
## GATE ROUND 2 (Codex on 90db0de): named hole FIXED, adjacent host-control paths found → fixed + deferred

Codex confirmed DesktopControlTool default-deny + .dangerous + merge kept hook security. Found MORE
host-control paths. Fixed this round:
- **live_screen_watch** (screencapture) — was ungated; now under `if opts.enableComputerUse`.
- **computer_control** (app launcher, sandbox-bypass) — moved out of the unconditional base into the armed block.
- **shell host-control binaries** — `osascript`/`cliclick`/`screencapture`/`shortcuts run`/`system events`
  now classify `.dangerous` (refused by NonDestructive/--loop + interactive; the shell route to the same
  capability the tool arming-gate covers).

### DEFERRED — deeper architecture, own council pass (NOT introduced by this merge; pre-existing surfaces)
1. **AutoApproveInteractor approves `.dangerous`.** On `--auto`/`--yolo` (guards-off + FORCED sandbox), a
   `.dangerous` host-control op is auto-approved. Right fix: host-control must be HARD-denied unless
   `--enable-computer-use`, independent of the interactor — AND/OR verify the `--auto` Seatbelt sandbox
   actually blocks AppleEvents/Accessibility (containment). Today: tools are registration-gated (absent
   unless armed); the residual is shell automation under `--auto` (guards-off is the user's explicit choice).
2. **MCP tools are not arming-gated.** A user-configured desktop MCP (screenshot=safe verb; click=.dangerous
   but AutoApprove-approved) bypasses `--enable-computer-use`. Needs: dangerous-verb MCP tools require arming,
   or AutoApprove fail-closed on `.dangerous`. MCP is user-configured trust, so lower immediate risk.
3. **Nested kist doesn't clear `allowShell`** (only enableComputerUse/auto/yolo). With automation binaries now
   `.dangerous` this is partially mitigated; full fix pairs with #1.

These three share ONE root: make host-control a HARD capability (deny-without-arming) rather than approval-
dependent, and confirm sandbox containment for `--auto`. That's a focused approval-model change deserving its
own council + Codex pass — not a marathon-session tail edit.
