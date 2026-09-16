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

## Build / test / deploy
```
swift test                                           # local verification
swift build -c release --product kist                # local release build only
.build/release/kist --version                        # exact semantic product identity

# The ONLY sanctioned production promotion path:
MYTHOS_REPO=/Volumes/PRO-G40/kist-loops ~/bin/kist-rebuild --force
```
`kist-rebuild` runs the test/build/sign/smoke gates, then performs a lease-serialized, journaled
promotion of the binary, tracked wrapper/dashboard/rebuild/safe-rebuild scripts, and the complete
two-file SwiftPM builtin skill bundle. The
individual path replacements are not globally atomic for readers that bypass the deployment lease;
failed promotions roll back, and operators must not launch a new Kist process while promotion is
in progress. Never manually `cp` a binary or deployment script into `~/bin`; that bypasses the
artifact closure and leaves installed provenance stale. `scripts/kist-wrapper`,
`scripts/kist-dashboard`, `scripts/kist-rebuild`, and `scripts/kist-safe-rebuild.sh` are the
canonical deployed sources.

Bootstrap from a legacy closure is deliberately two-pass: run the exact promotion command above
once to install the compatibility-aware dashboard/rebuild gate, validate the transitional v2 or v3
manifest, then run the same command again to install the seven-payload v4 closure. Never archive or
benchmark the transitional deployment: its resource bytes are not bound. V4 archives contain the
five executable payloads, both resource files, and three metadata files; rollback restores all ten.
The built resource inventory must exactly match the private source snapshot. Extra, missing,
linked or unsafe resources fail validation. Mutable dashboard runtime/cortex state remains bound
through separate operational digests and is trust-validated independently at each launch.
Pre-v4 archives have explicit compatibility grades: v3 is
`best-effort-v3-resources-not-archived`; older records are
`best-effort-legacy-non-self-contained`. Their unarchived dependencies cannot establish exact
resource rollback. The gate dry-validates operational compatibility before activation. Old rollback
plans must be regenerated with the current compatibility grade; use v4 archives for exact rollback.
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

Deployment authoring: edit the bounded modules in `scripts/deployment/rebuild/` and
`scripts/deployment/dashboard/`, then run `python3 scripts/deployment/render_launchers.py`.
The resource contract lives in `scripts/deployment/resource_inventory.py`. The tracked
`scripts/kist-rebuild` and `scripts/kist-dashboard` are generated, self-contained deployment
artifacts. Installed execution never imports checkout helpers. A Swift regression requires exact
rendered-byte agreement, and the generator rejects source modules over 1,000 lines.

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

For the durable model-facing capability summary and the current, evidence-backed evolution
readiness truth, read `docs/MODEL_CAPABILITY_MEMORY.md`. It is context, not an authority grant.

## Rules of the road (inherits ~/.claude/CLAUDE.md)
- New RuntimeEvent cases: audit EVERY sink/switch (TerminalEventSink previously dropped
  `.planReady` via `default: break` → 78-min silent hang). A dropped event is a UX lie.
- Multi-site fixes need per-site regression assertions (see R3MicroTaskTests gate-site pins).
- Commit each tested increment; push to origin. Files ≤1000 lines target.
- MCP servers come from `~/.mcp.json` (`kist --protocols` to verify; perslis = legacy-systems limb).
- Codex/adversarial review before declaring done; label deliverables honestly.
