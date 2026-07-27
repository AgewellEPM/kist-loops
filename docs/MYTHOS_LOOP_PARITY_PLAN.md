# Mythos Loop Parity — "make our loop think and chain exactly like the frontier does"

Goal: the kist REPL/agent loop should *feel* like Claude Code — it plans, it chains ("I did X, now Y,
then Z"), it reflects on each result, and it survives long sessions without losing the thread. This doc
is the gap analysis (ours vs the SOTA loop anatomy) + the ranked plan to close it.

Sources for the SOTA anatomy: Anthropic Agent SDK "agent loop" docs, "Building effective agents",
TodoWrite/compaction/interleaved-thinking docs, SWE-agent ACI paper (arXiv 2405.15793), OpenHands CodeAct
(arXiv 2407.16741), ReAct (arXiv 2210.03629). (Full URLs in the research brief.)

## What we ALREADY have (don't rebuild)
- **The core agentic loop** — `HeadlessAgentLoop.driveText` (ReAct text protocol) + `driveNative`
  (function-calling). Observe→think→act→observe, runs until a `done`. PROVEN LIVE (MiMo/DeepSeek chained
  glob→list→read→answer, self-recovering).
- **Replan on failure** — `replanThreshold` (2 consecutive tool failures → steer a re-plan), `maxReplans`.
- **Typed up-front plan** — `PlanExecuteLoop` (the DAG *is* "step1→step2→step3", with approve + verify-goal).
- **Sub-agent delegation** — `spawn_agent` + the supervised fleet (context-isolated workers).
- **Capability-aware routing** — native vs text per provider (the MiMo fix), prompt caching surface.
- **Checkpoint/resume**, hooks, budgets, per-turn trace — governance is solid.

## The GAPS (ranked by impact — SWE-agent/Anthropic say tools+context are the ceiling)

### #1 — Tool / ACI quality (HIGHEST leverage)
SWE-agent: better tool surface ~3×'d solve rate with NO model change. The loop's ceiling is here.
- **Do:** audit every tool's output for conciseness + a model-friendly shape (we just fixed `glob **/x`
  root-level live; that's the pattern). Consolidate overlapping tools, tighten descriptions, make failure
  messages corrective ("no match — try `list_files`"). Add a `apply_patch`-style multi-edit if missing.
- **Why:** cheap, compounding, helps every model + the whole fleet.

### #2 — Summarizing context COMPACTION (not just trim)
`ContextWindowManager` today = sliding window (keepFirst + keepLast, **drop the middle**). The SOTA
SUMMARIZES the middle into a block that preserves: *objective, files touched, test results/errors,
decisions + reasoning, next steps* — then continues. Dropping loses the thread; summarizing keeps it.
- **Do:** add a compaction pass (an LLM summarize-the-middle call, or a structured rolling summary the
  loop maintains) that fires near a capacity threshold (~60%, not 95%), emits a compaction boundary, and
  preserves the objective/files/tests/decisions. Keep the trim as the fallback.
- **Why:** this is what lets the loop run dozens-to-hundreds of steps instead of falling apart. Without
  it, long conversational sessions degrade.

### #3 — Explicit, re-injected TODO / plan-tracking (THE "knows the next step" mechanic)
The thing that makes the loop *feel* like it chains. Claude Code's first move on a multi-step task is
`TodoWrite` — a structured list it rewrites as it works (pending→in_progress→completed), **re-injected
after tool calls** so the plan keeps re-surfacing and the model can't drift. We have this ONLY in
plan-execute mode (the DAG); the conversational loop has nothing.
- **Do:** add an `update_plan` (todo) tool the model maintains: a list of {step, status}. After each tool
  result, RE-INJECT the current plan into the context as a reminder. Surface it in the REPL so the user
  SEES "✓ step 1 · ▶ step 2 · ○ step 3". Make it advisory (never gates trust — same invariant as the fleet).
- **Why:** this is exactly the "I did X, now I must do Y" experience Luke loves. Highest *felt* impact.

### #4 — Interleaved thinking ON the result, before the next call
Our text protocol reasons per-step (a `thinking` field). The frontier reflects on the tool RESULT before
choosing the next action (Claude's interleaved-thinking; reasoning_content for reasoning models).
- **Do:** for native-capable providers, request interleaved/extended thinking so the model thinks AFTER a
  tool result; for the text protocol, the per-step `thinking` already approximates it — make the prompt
  explicitly ask "reflect on the last result, THEN choose the next action."

### #5 — Parallel read-only tool calls
One tool per ReAct step today. The SOTA fans out read-only tools (read/glob/grep) concurrently, runs
mutating tools (write/edit/run) sequentially.
- **Do:** in `driveNative`, when the model emits multiple read-only tool calls, execute them concurrently
  (TaskGroup); keep mutating tools sequential. Mark tools read-only (a `readOnly` flag, like MCP's
  `readOnlyHint`). Speeds up the context-gathering phase.

### #6 — Per-turn rule re-injection (survives compaction)
Must-obey rules (CLAUDE.md/AGENTS.md) should be re-injected EVERY turn so compaction can't eat them.
`ProjectMemory` ingests them once (plan-execute); the conversational loop should re-inject the durable
rules on each turn (prompt-cached).

## Ship order (each a small tested increment, Codex-gated)
1. **#3 TODO plan-tracking + re-injection** — highest *felt* impact, it's the thing Luke loves; medium size.
2. **#2 summarizing compaction** — unlocks long sessions; medium.
3. **#1 ACI/tool audit** — continuous; start now (glob fix shipped).
4. **#5 parallel read-only tools** — speed; small-medium.
5. **#4 interleaved thinking** — quality; small (mostly prompt + a header for native).
6. **#6 per-turn rule re-injection** — safety on long sessions; small.

## Honest framing
We are NOT starting from zero — the agentic chain, replanning, planning (DAG), and delegation are real and
live-proven. The gap to "feels exactly like Claude Code" is two things: **(a) an explicit, re-surfaced
todo list in the conversational loop** (#3) and **(b) summarizing compaction so long sessions don't lose
the thread** (#2). Close those two and the loop *chains visibly* and *endures*. The rest (#1,#4,#5,#6) is
polish that compounds. Label: the loop is PILOT-quality now; #2+#3 take it to "frontier-feel."
