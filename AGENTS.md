# Kist recovery instructions for Codex

This repository is the canonical Kist source at `/Volumes/PRO-G40/kist-loops`. It is production
software under bounded recovery, not an autonomy-ready agent.

Before changing recovery, memory, self-heal, or self-evolution code, read:

1. `CLAUDE.md`
2. `docs/KIST_AUTONOMY_FLATLINE_AUTOPSY_2026-08-27.md`
3. `docs/KIST_MEMORY_GOVERNANCE_STATUS_2026-08-28.md`
4. `docs/kist/GREAT_LOOP_EVOLUTION_ROADMAP.md`
5. `docs/CODEX_CAPABILITY_FAILURE_ZONE_CAMPAIGN_2026-08-27.md`

## Non-negotiable recovery state

- Leave `~/.kist/runtime/config.json` `.autonomy.enabled`,
  `.autonomy.canonical_execution`, `.autonomy.allow_shell_execution`, and
  `.autonomy.allow_self_tool_creation` false. Do not arm autonomy or unattended evolution unless
  Luke explicitly authorizes a separate wake-up operation after every documented gate is fresh and
  green.
- Treat process exit, model prose, dashboard status, unsigned memory, and same-model critique as
  advisory, not proof. Only the applicable host-owned accepted or sealed receipt may establish
  verified completion.
- The current inference route is GPT/Codex only. A fresh-context review by the same provider and
  model must remain `independent=false`; never relabel it as independent review.
- Do not launch or control a browser, UI, VM, guest, physical device, GhostBridge, Perslis actuation,
  or live external system without Luke's explicit authorization.
- Preserve the dirty worktree and unrelated user changes. Do not commit, push, reset, discard, or
  overwrite them unless Luke explicitly asks. This recovery rule overrides `CLAUDE.md`'s generic
  commit/push instruction.

## Memory and evolution invariants

- Separate authority from relevance: sealed receipts and sealed evolution lineage do not decay;
  advisory memory does.
- Never infer a season. A recurrence must be explicit in structured fields.
- Never rejuvenate memory by reading, access count, file modification time, copy time, or ordinary
  transaction update. Unknown-age generic rows stay raw audit-only.
- Break long work into bounded, contextual microtasks. Carry the same host-owned mission ID through
  plans, evidence, ledger rows, and receipts; inspect the mission graph before claiming completion.
- DGM-style work stays confined and manual. Do not claim self-improvement without an exact-parent,
  held-out, host-owned positive capability delta. Do not auto-promote candidates.

## Verification and promotion

Run focused tests first, then the relevant full Swift, Cortex-memory, dashboard, and campaign
regressions. Report failures; never weaken or skip a safety test to obtain green. Run
`git diff --check` before handoff.

The only sanctioned production promotion command is:

```sh
MYTHOS_REPO=/Volumes/PRO-G40/kist-loops /Users/lukekist/bin/kist-rebuild --force
```

Do not manually copy installed binaries or deployment scripts. Keep semantic version `0.17.60`; use
build manifests and receipts to distinguish this recovery build. Promotion and a fresh bounded
self-assessment happen only after all verification is green.
