# FOLLOW-UP (required): unify KistREPL model-state — single source of truth

Surfaced by Codex during the c4-routing merge review (2026-07-03). **Pre-existing debt** — c4 never
touched KistREPL.swift; interactive auto-routing merely made the drift observable, and that instance
(the churn) is FIXED. This ticket is the systemic cleanup.

## The drift
Three notions of "current model" diverge:
- `roleSelection.fallback` — the user's DEFAULT (pinned) model.
- `activeBinding` — the model the loop is ACTUALLY running (auto-routing can move it off the default).
- the built `loop` — whatever model it was last constructed with.

Many handlers rebuild the loop from `roleSelection.fallback`, silently RESETTING an auto-routed model
back to the default and desyncing `activeBinding`. A following no-signal auto-route turn then reads a
stale `current` and runs one model while displaying another.

## Sites to fix (rebuild from the running model, i.e. activeBinding, unless the intent is a model switch)
- KistREPL.swift ~1302, ~1318, ~1327, ~1387, ~1395, ~1419 — /think, /reasoning, /config, /roles handlers.
- KistREPL.swift ~253 — media "activeHandles" check keys off roleSelection.fallback; should use activeBinding
  (else media can go to an auto-routed non-vision model instead of borrowing the vision provider).
- KistREPL.swift ~1365 — /compact summarizes on roleSelection.fallback; should use activeBinding.

## Done in the c4 merge (in-scope, correct)
- autoRoute closure threads `current` (activeBinding) as the stay target (r1).
- AutoModelRouter.route gains `current` stay-target (MED).
- NL block: rebuild preserves activeBinding for role/settings intents; only .setModel moves it (r3).

## Recommended approach
One helper: `rebuildLoop(to binding: preserveActive: Bool)` that sets loop AND activeBinding together,
so no handler can rebuild one without the other. Route media + compact through activeBinding. Add a REPL
invariant test: after an auto-route switch, /reasoning|/roles|/compact|media keep the running model.
Own plan + 5-model council + Codex gate (it touches ~8 interactive paths).

---
## RESOLVED 2026-07-03 (this refactor)
Single-source-of-truth invariant applied. activeBinding == the running loop model, synced at every
persistent rebuild. Sites changed:
- PRESERVE-RUNNING (rebuild from activeBinding): /reasoning, /think, /config, /roles assign,
  /roles reset, /roles load. **Codex correction applied**: reset/load do NOT change the default
  (reset clears only role overrides; profiles store no default), so they PRESERVE the running model
  (not model-change as the 4 API council models assumed).
- READ activeBinding not fallback: media capability check + banner, /compact binding, status line
  (non-team), paste vision provider.
- Model-change sites (/model, /copilot lead, NL setModel) already synced activeBinding — unchanged.
- Mechanism: direct pairing (council 4/4 preferred B over a mutable-local-capture closure). A helper
  method is impossible here (loop/activeBinding/etc. are run()-locals, not properties).

### Remaining follow-up (separate, smaller)
- REPL-sequence integration test (auto-route→switch, then /reasoning|/roles|/compact|media all see the
  switched model) needs an INPUT-INJECTION seam: inputReader is hardcoded `EnhancedPromptReader()` at
  KistREPL.swift:158. Add an injectable reader + a loopFactory that records bindings, then script the
  sequence. Pure routing invariants (captainDecision, route(current:)) are already unit-tested.
- Optional: `/roles load --keep-model` power-user flag (GPT-5 suggestion) — not needed now that
  load preserves the running model by default.
