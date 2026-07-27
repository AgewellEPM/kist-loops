# kist vs the industry — shell, sandbox, thinking, planning, replay (2026-06-30)

Your goal, restated: *think → plan → run the shell commands we need → build/test the whole thing in a
sandbox → watch replays of what the AI did* — i.e. mirror Claude Code / Codex / Cursor's agent. This maps
what kist ACTUALLY has (verified by 4 read-only subsystem audits, file:line) against those systems, and
names exactly what's missing + a build order.

(Benchmarked against the *documented/observable behavior* of Claude Code, Codex, and Cursor — not their
proprietary source. We close gaps by building our own, not by copying theirs.)

## Direct answer: yes, kist runs shell in the loop — here's the real shape
- `RunCommandTool` runs commands **agentically every iteration**. Default mode is **structured exec**
  (`executable`+`args`, real `exec`, NO `/bin/sh` — so `rm${IFS}-rf` tricks can't form). Raw `/bin/sh -c`
  is opt-in (`command`+`shell:true`).
- Hardened: 120s timeout (max 600), 100KB/stream output cap, cwd confinement, env scrubbed to an
  allowlist, all fds ≥3 closed, deny-list, `ulimit` cpu/mem/fsize, process-group kill.
- **"Unlimited" loop:** the only bound is `maxIterations` (default **12**) — there's no separate cap on
  shell calls, and each `--resume` grants a *fresh* budget, so across resumes it's effectively unbounded.
  No token/cost halt.
- Sandbox: `--auto` **forces** a macOS Seatbelt sandbox (deny network + confine writes to project/tmp).
  **On Linux there is no kernel sandbox — `--auto`/`--sandbox` makes shell *refuse to run* (fail-closed).**

## Cross-comparison
| Capability | kist today | Claude Code | Codex | Cursor |
|---|---|---|---|---|
| Agentic shell in loop | ✅ structured exec + opt-in raw | ✅ Bash tool | ✅ exec | ✅ terminal |
| **Persistent shell session** (cd/env across calls) | ❌ stateless per call | ✅ | ✅ | ✅ |
| **Background / long-running jobs** | ❌ sync only | ✅ run_in_background + poll | ✅ | ✅ background agents |
| Streaming command output to model | ❌ returns on completion | ✅ | ✅ | ✅ |
| PTY / interactive stdin | ❌ stdin=/dev/null | partial | partial | partial |
| **Extended / interleaved THINKING** | ✅ **SHIPPED** opt-in `--think`/`/think` (OpenAI-compat providers; Anthropic-native pending) | ✅ think budget | ✅ reasoning | ✅ |
| Auto-driven TODO (≤1 in-progress) | ◑ rich board, but loop never drives it | ✅ TodoWrite steered | ◑ | ◑ |
| Plan-approval handshake (freeze→approve→execute) | ◑ only in opt-in PlanExecuteLoop | ✅ ExitPlanMode | ◑ | ✅ plan mode |
| macOS kernel sandbox | ✅ Seatbelt (forced under --auto) | ✅ | ✅ | ✅ (cloud VM) |
| **Linux kernel sandbox** | ❌ fails closed | ✅ bubblewrap | ✅ Landlock+seccomp | ✅ VM |
| Read-confinement in sandbox | ❌ all reads allowed | partial | ✅ | ✅ |
| Crash-safe checkpoint/resume | ✅ strong (bracket-before-side-effect) | ✅ | ✅ | ✅ |
| Worktree isolation for parallel agents | ✅ GitIsolation | n/a | n/a | ✅ background agents |
| **Replay with real file DIFFS** | ❌ only "Edited X (+3 lines)" summaries | ✅ per-step diffs | ✅ | ✅ diff view |
| Replay scrub / step-through / pacing | ❌ static text dump (≤120 lines) | ◑ | ◑ | ✅ |
| Cost/token overlay in replay | ❌ usage not joined to runID | ◑ | ◑ | ◑ |
| Tamper-evident run log | ❌ append-by-convention | n/a | n/a | n/a |

Legend: ✅ have · ◑ partial · ❌ missing.

## The 5 gaps that matter (ranked to YOUR goal)
1. **Thinking is OFF.** ✅ **SHIPPED (2026-06-30).** Was: the loop hard-coded `disableThinking:true` in
   every model call. Now opt-in `--think` / `/think` lets the model reason before each action (default
   stays OFF for the tight loop); reasoning is surfaced inline + persisted to the replay, propagates to
   sub-agents, and reuses the Layer-A reasoning budget. **Follow-up:** Anthropic-native extended thinking
   (`thinking:{type:enabled,budget_tokens}` + thinking-delta parsing) is NOT wired yet — `--think` is a
   no-op on the Anthropic provider but honored by the 15 OpenAI-compatible providers (+ Gemini emits
   reasoning regardless). Wire AnthropicProvider next.
2. **Shell is stateless + foreground-only.** No persistent session (cd/env don't carry), no background
   jobs, no streamed output, raw-shell is even unreachable in the shipped CLI (no approval handler wired).
   "Unlimited shell commands / handle this loop" wants a real shell session, not 12 one-shot execs.
3. **No Linux kernel sandbox.** "build the whole thing in a sandbox and retest" works on your Mac
   (Seatbelt) but **fails closed on Linux** — where CI, Docker, and servers live. bubblewrap (or
   Landlock+seccomp) is the missing tier. Until then, autonomous shell is macOS-only.
4. **Replay can't show what changed.** `--replay` is a static, truncated text dump with **no file diffs**,
   no step-through, no cost. "Watch replays of what the AI did" (the Cursor-style diff timeline) needs
   real before/after hunks + scrubbing + per-run cost. The capture is solid; the *viewer* is thin.
5. **Plan isn't enforced.** Rich PlanTask board exists (acceptance/verification/evidence — richer than
   Claude Code's flat todo) but the loop never auto-drives it, there's no ≤1-in-progress invariant, and the
   default loop's "plan mode" is a free-text toggle, not a freeze→approve→execute handshake.

## What kist already does BETTER (don't rebuild these)
- Crash-safe checkpoint/resume with **bracket-before-side-effect** reconciliation — best-in-class.
- Provider-agnostic loop (text protocol + native tools) across all providers — true "uses every AI."
- Richer task model than a flat todo (Plan/Action/Test/Review + proof obligations).
- Git-worktree rollback-by-construction for parallel agents.
- Untrusted-data envelope on every tool output (prompt-injection defense) + reversibility/scope approval.

## Recommended build order (each = its own increment, tested + Codex-gated)
1. **Extended-thinking mode** (opt-in `--think` / `/think`): stop forcing `disableThinking`, add a thinking
   budget, surface the `reasoning` stream (already wired) in the loop + replay. Closes gap #1; reuses
   Layer A. *Smallest, highest goal-alignment.*
2. **Persistent + background shell**: a stateful shell session tool (cd/env persist) + `run_in_background`
   with a poll/`bash_output` tool + streamed output to the model. Closes gap #2.
3. **Linux sandbox tier** (bubblewrap → fallback Landlock+seccomp): so `--auto` runs sandboxed on Linux
   instead of refusing. Closes gap #3 — unlocks CI/server/Docker. *Biggest unlock, biggest effort.*
4. **Rich replay viewer**: store real unified diffs per file edit + full (capped) tool output, join usage
   to runID, add step-through/scrub. Closes gap #4 — the "watch what the AI did" feature.
5. **Loop-driven plan + approval handshake**: auto-seed/maintain the todo board each iteration, enforce
   ≤1 in-progress, and a freeze→approve→execute gate in the default loop. Closes gap #5.

Start with #1 — it's the most direct hit on "mimic Anthropic's thinking + planning," it's pure-kist (no
OS/network dependency), and it builds straight on the reasoning-budget work just shipped.
