# kist-loops — Project Context (CLAUDE.md)

## What this is
**The live kist captain.** A Swift Package (SPM, NOT Xcode) building the `kist` CLI —
an agent shell (REPL + one-shot goals + plan→execute + fleet/council/research) that runs
on any model (BYOK cloud, local Ollama, keyless claude-cli/codex-cli subscription providers).
This repo is what runs when Luke types `kist`. Treat every change as production.

- Remote: private `github.com/AgewellEPM/kist-loops` (branch `main`).
- ⚠️ `/Volumes/PRO-G40/Downloads/kist-loops` is a DEAD worktree of a different ancestor —
  never build from or sync to it.

## Build / test / deploy (the only sanctioned path)
```
swift test                                   # full suite must be green (3300+)
swift build -c release --product kist
cp .build/release/kist ~/bin/kist-current
codesign -f -s - ~/bin/kist-current          # cp BREAKS the signature → SIGKILL 137; ALWAYS re-sign
```
Wrapper `~/bin/kist` arms `--enable-computer-use --allow-shell --allow-read /Volumes` and
sources `~/.config/kist/secrets.env`, then execs `~/bin/kist-current`.
A running kist session does NOT pick up a redeploy — start a new session to test.
If the release module cache goes stale: `rm -rf .build/*/release/ModuleCache && find .build -name '*.pch' -delete`.

## Architecture (where things live)
- `Sources/AgentCore/` — provider-agnostic engine: `PlanExecuteLoop` (plan→execute→replan→verify),
  `PlanExecutor` (DAG waves, approval gate at BOTH launch and repaired-retry sites), `PlanLint`
  (singular-step contract), `RuntimeEvent`/sinks, tools + `ReversibilityClassifier`,
  `ToolContext.externalReadRoots` (read-only /Volumes).
- `Sources/Kist/` — the terminal host: `KistREPL` (slash commands), `KistRunner`,
  `TerminalEventSink` (calm renderer, live status line, stall alarm), `TUI/`.
- `Sources/Kist/UX/` — REPL UX units: `InterruptibleTurn` (ESC semantics), `TurnInputQueue`
  (type-while-working), `EnhancedPromptReader`, `StdinArbiter`, `TurnProofStore`.
- UX roadmap: `docs/CAPTAIN_UX_OVERHAUL_PLAN_2026_07_28.md` (R0-R2a+R3 shipped; R2b bottom bar,
  R4 tag-team, R5 watchdog, R6 wheels remain). Trust its recon notes over intuition.

## Rules of the road (inherits ~/.claude/CLAUDE.md)
- New RuntimeEvent cases: audit EVERY sink/switch (TerminalEventSink previously dropped
  `.planReady` via `default: break` → 78-min silent hang). A dropped event is a UX lie.
- Multi-site fixes need per-site regression assertions (see R3MicroTaskTests gate-site pins).
- Commit each tested increment; push to origin. Files ≤1000 lines target.
- MCP servers come from `~/.mcp.json` (`kist --protocols` to verify; perslis = legacy-systems limb).
- Codex/adversarial review before declaring done; label deliverables honestly.
