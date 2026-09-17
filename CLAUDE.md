# kist-loops — Project Context (CLAUDE.md)

## What this is
**The canonical kist source, not proof of the installed or running captain.** This is a Swift Package
(SPM, NOT Xcode) building the `kist` CLI —
an agent shell (REPL + one-shot goals + plan→execute + fleet/council/research) that runs
on any model (BYOK cloud, local Ollama, keyless claude-cli/codex-cli subscription providers).
Treat every change as production-impacting, but verify the deployment manifest, binary digest, and
running-process start time before claiming this checkout is what Luke invokes. At the 2026-08-28
recovery checkpoint, `~/bin/kist-current` is older than the hardened release build and a Cortex
daemon predates the Python repair commits; neither running surface may be credited with source-only
temporal/evolution gates until a separately authorized drain/deploy/restart succeeds.

- Remote: private `github.com/AgewellEPM/kist-loops` (branch `main`).
- ⚠️ `/Volumes/PRO-G40/Downloads/kist-loops` is a DEAD worktree of a different ancestor —
  never build from or sync to it.

## symbolic-floor — the bio verification floor (subtree)
`symbolic-floor/` — git subtree of `~/.kist/workspaces/captain/symbolic_floor`
(the RUNTIME copy; floor DBs + dashboard run there, `data/` never travels
through git). Typed six-relation Peel floor w/ functional hard-veto,
floor-proposer gate lane (local model proposes, floor verdicts), research
loop with reflect/ponder + grounded lab notebook, floor dashboard
(localhost:8977; /api/research is the ONLY write lane, via the Store).
Sync contract: `symbolic-floor/SUBTREE.md`.
Test: `cd symbolic-floor && .venv/bin/python -m pytest tests/`.

## Build / test / deploy
```
swift test                                           # local verification
swift build -c release --product kist                # local release build only
.build/release/kist --version                        # exact semantic product identity

# The ONLY sanctioned production promotion path:
MYTHOS_REPO=/Volumes/PRO-G40/kist-loops ~/bin/kist-rebuild --force
```
`kist-rebuild` runs the test/build/sign/smoke gates, then performs a lease-serialized, journaled
promotion of the binary plus its tracked wrapper/dashboard/rebuild/safe-rebuild scripts. The
individual path replacements are not globally atomic for readers that bypass the deployment lease;
failed promotions roll back, and operators must not launch a new Kist process while promotion is
in progress. Never manually `cp` a binary or deployment script into `~/bin`; that bypasses the
artifact closure and leaves installed provenance stale. `scripts/kist-wrapper`,
`scripts/kist-dashboard`, `scripts/kist-rebuild`, and `scripts/kist-safe-rebuild.sh` are the
canonical deployed sources.

Bootstrap from a legacy closure is deliberately two-pass: run the exact promotion command above
once to install the compatibility-aware dashboard/rebuild gate and produce a transitional v2
manifest, validate it, then run the same command again to transactionally install the safe helper
and produce the five-payload v3 closure. Never archive the transitional deployment. V3 release
closure covers only rollback-restorable deployed payloads; mutable dashboard runtime/cortex state
is trust-validated independently at each dashboard launch.
Pre-v3 registry records are explicitly labeled `best-effort-legacy-non-self-contained`: their
runtime/cortex dependencies were never archived, and a compatibility rollback leaves the newer
safe-rebuild helper outside the legacy closure. The gate dry-validates that operational closure
before activation; use v3 archives for exact rollback.
Repository-root `.kist/usage.jsonl` and `.kist/runs/**` are operational telemetry: promotion neither
hashes nor modifies them. Other `.kist/` inputs—including `.kist/agents/**`, plan data, and checked-in
learning policy—remain in the source identity and private build snapshot. Tracked source and
deployment scripts remain in that identity, and persistent source churn fails promotion.

Wrapper `~/bin/kist` sources `~/.config/kist/secrets.env`, defaults
`--enable-computer-use --allow-shell --allow-read /Volumes` unless the caller supplied each
authority explicitly, then execs `~/bin/kist-current`.
The during-turn pinned input panel is opt-in only via `--sticky-turns`. Production and the default
wrapper must keep it OFF unless a separate change is approved after direct Terminal.app validation;
never add that flag to the wrapper or rebuild path implicitly.
A running kist session does NOT pick up a redeploy — start a new session to test.
If the release module cache goes stale: `rm -rf .build/*/release/ModuleCache && find .build -name '*.pch' -delete`.

Provenance restoration note (2026-07-30): `scripts/kist-rebuild` began as an emergency port of the
audited installed promotion gate and now carries the compatibility-aware v3 closure protocol.
Follow-up: split its evidence validation, transaction, release-registry, and build/promotion
phases into separately tested modules without changing behavior before adding more features.

## Architecture (where things live)
- `Sources/AgentCore/` — provider-agnostic engine: `PlanExecuteLoop` (plan→execute→replan→verify),
  `PlanExecutor` (DAG waves, approval gate at BOTH launch and repaired-retry sites), `PlanLint`
  (singular-step contract), `RuntimeEvent`/sinks, tools + `ReversibilityClassifier`,
  `ToolContext.externalReadRoots` (read-only /Volumes).
- `Sources/Kist/` — the terminal host: `KistREPL` (slash commands), `KistRunner`,
  `TerminalEventSink` (calm renderer, live status line, stall alarm), `TUI/`.
- `Sources/Kist/UX/` — REPL UX units: `InterruptibleTurn` (ESC semantics), `TurnInputQueue`
  (type-while-working), `EnhancedPromptReader`, `StdinArbiter`, `TurnProofStore`.
- Historical UX roadmap: `docs/CAPTAIN_UX_OVERHAUL_PLAN_2026_07_28.md`. It is a dated planning
  snapshot, not current status. Trust executable tests and `docs/FEATURE_STATUS_MATRIX.md` instead.

## Rules of the road (inherits ~/.claude/CLAUDE.md)
- New RuntimeEvent cases: audit EVERY sink/switch (TerminalEventSink previously dropped
  `.planReady` via `default: break` → 78-min silent hang). A dropped event is a UX lie.
- Multi-site fixes need per-site regression assertions (see R3MicroTaskTests gate-site pins).
- Commit each tested increment; push to origin. Files ≤1000 lines target.
- MCP servers come from `~/.mcp.json` (`kist --protocols` to verify; perslis = legacy-systems limb).
- Codex/adversarial review before declaring done; label deliverables honestly.
