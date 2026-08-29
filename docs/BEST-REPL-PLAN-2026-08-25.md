# The Best REPL in the World — Verified-Estate Plan (2026-08-25)

**Provenance:** 12-agent deep campaign (6 estate readers → 3 independent architectures → 3
adversarial judges). Winning doctrine: **VERIFICATION-FIRST, 31/40** (estate-first 26, autonomy-first
27), with the best ideas of the losers grafted in. Full raw output:
`~/.claude/projects/-Users-lukekist/c6e64643-e1df-4e59-8f6c-59fe33bdb997/tasks/wnm1isa4z.output`.

## Thesis

The best REPL is not the prettiest TUI or the highest Terminal-Bench score — that race is
commoditized. The best REPL is **the first coding agent whose every "done" is cryptographically
re-checkable by a third party**, commanding an estate no other REPL has:

- **Perslis** — builds real Windows apps (Win98→Win11) over a frozen 22-tool MCP contract, signed
  construction receipts
- **GhostBridge** (its own project, `~/GhostBridge` + `~/GhostBridge-MacStandardStreamControllerV2`)
  — live VM desktops, QMP control, guest exec, clipboard bridge; **Codex is building
  `ghostbridge_legacy_mcp.mjs` right now** (modified today 13:42 + tests)
- **Jeeves** — symbolic floor, 1,708 typed relations, <50ms, **already trusted** in
  `ReversibilityClassifier.trustedReadOnlyServerLeaves` (since R6, Jul 29)
- **isolated-tester** — sealed-session UI verification
- **Receipt spine ~70% built**: `VerificationReceipt.swift`, `ReceiptSeal.swift`, `ForgeSeal.swift`
  (HMAC chains), 18+ Receipt files, promote-gate Ed25519 keys

Claude Code / Codex CLI generate-and-hope. kist proves. That is the categorical difference.

## Honest current-state (from the estate maps)

- REPL surface: 100+ commands, all major lanes live, feature-complete — but intent classification
  is a first-word verb match, plan-execute is opt-in `[y/N]`, `mayEscalate(.chat)` locks
  misclassifications inline.
- Tool layer: Perslis read-leaves trusted in `--loop` only (HEAD 5f6158c); `projectMCP: false` in
  the user config keeps project MCP servers dark per-turn.
- Evolution organs: **architecturally complete, operationally dead** — FailureRouter routes but
  CapabilityNominator has no live consumer; no production failure has ever fed a proposal.
- Routing availability gate (0.17.60, today): live at 7 sites, Codex-hardened through 4 review
  rounds.

## The 7 components (verification-first architecture)

1. **IntentDissector** — Jeeves as turn-zero: frame lexicon + `symbolic_query`/`check_contradiction`
   grounding → typed `IntentFrame` (replaces `isBuildDirective`); mid-turn re-dissection; kills the
   `.chat` lock. (= Luke's locked routing-v2 "dissect" stage.)
2. **RoutingReceipt** — every model pick + failover emits a ForgeSeal-chained signed receipt
   (intent digest, health snapshot digest, priors, candidates, choice). The just-shipped gate
   becomes *evidence*, not just behavior. Wire-or-excise the dead `local_first_for_code` keys.
3. **VerificationLedger + `kist verify`** — one append-only store unifying five receipt species
   (routing / build / UI / fact / gate), HMAC continuity + Ed25519 terminal signatures, offline
   third-party re-verification. **This is the product.**
4. **Plan-execute as the default spine** — DAG-default for dissector-typed build/mutate intents,
   chat stays inline, per-node receipts, kill-switch config.
5. **ghostbridge-mcp** — standalone first-class server (`gb_vm_status/snapshot/restore`,
   `gb_guest_exec`, `gb_clipboard_get/set`, `gb_display_topology`, `gb_workspace_spawn`) wrapping
   the proven controller contracts (`kist_repl_bridge.py` :49222, `clipboard_bridge.py` :49322).
   **Contracts-only coordination with the live Codex session; zero shared file edits.**
6. **Trusted-leaf wiring** — ghostbridge + isolated-tester read leaves join Jeeves/Perslis in
   `trustedReadOnlyServerLeaves` (autonomous firing in `--loop`), one invariant test per leaf.
7. **Anti-lying-upward gate** — every "done/built/verified/fixed" claim in a final answer must cite
   a ledger receipt id; unbacked claims render as "attempted, unverified". The mechanical form of
   the labeling doctrine.

## Workstreams (dependency-ordered, ~47 eng-days total)

| WS | What | Days | Depends on | Collision note |
|----|------|------|-----------|----------------|
| W1 | Intent Dissection v2 (Jeeves turn-zero, ≥50-utterance regression suite) | 5 | — | worktree-isolated; merge after Codex lands |
| W2 | RoutingReceipt (PEEL/ForgeSeal-receipted pick) | 4 | W1 | reads-only the hot provider files |
| W3 | VerificationLedger + `kist verify` + `/receipts` | 6 | W2 | new files + new REPL extension file |
| W4 | Plan-execute default spine (per-node receipts, kill-switch) | 6 | W1 hard, W3 | PlanExecuteLoop+Prompts is 5f6158c-hot |
| W5 | ghostbridge-mcp standalone server + launchd | 8 | Codex interface checkpoint | NEW dir under ~/GhostBridge/Tools; zero controller edits |
| W6 | Trusted-leaf + gate wiring | 2 | W5, Codex landed | ReversibilityClassifier is HOT — schedule last |
| W7 | Perslis default build organ (artifact→build→receipt ingestion) | 5 | W3, W4 | no ~/Perslis edits |
| W8 | Live ProjectSnapshot (digest-diff refresh, not full rescan) | 3 | wiring gated on Codex | extraction file now, 2-line wiring later |
| W9 | Receipt-grounded claims gate | 5 | W3 | ClaimReconciler/GroundedVerdict not hot — verify mtimes |
| W10 | Killer demo + tamper-FAIL test + honest labeling | 3 | W5, W7, W9 | demo fixtures only |

**Grafts from losing architectures** (judge-harvested): per-node calibrated autonomy gating
(40-node missions with ≤3 prompts) → fold into W4; multi-site receipt invariant checks
(co-attest launch receipt ↔ build digest ↔ PE32 output) → fold into W7; evolution-loop live
closure (first canary through FailureRouter→CapabilityNominator→promote gate) → **W11, after W10**
— do not arm autonomy before the receipt spine exists.

## The killer demo (W10)

One prompt, five minutes, zero trust required:
**"Build a working invoice-viewer for Windows 98 and prove it."**
Transcript shows: Jeeves-typed IntentFrame (fact receipt) → visible DAG, no [y/N] → PEEL-receipted
model pick (health data that excluded the degraded provider, receipted failover) → source over the
frozen Perslis artifact lane → build receipt → GhostBridge boots the guest, runs it, screenshots it
(sealed isolated-tester session) → final answer cites every receipt id → `kist verify <chain>` on a
DIFFERENT machine re-checks the whole chain, and a deliberately tampered byte makes it FAIL.
No other coding agent on earth can produce that artifact.

## Coordination protocol (Codex session, ~5h active)

Hot right now (do not edit): `GhostBridge-MacStandardStreamControllerV2/Tools/
Windows11PowerTerminalController/*` (ghostbridge_legacy_mcp.mjs + tests, 13:42 today),
`~/.ghostbridge/mcp/`, `ReversibilityClassifier.swift`, `PlanExecuteLoop+Prompts.swift`,
`CaptainIntelligence.swift` wiring seams, `KistRunner.swift` wiring seams, evolution files
(8f482b5 review fixes). Rule: new files now, two-line splices after Codex lands and rebases.
W5 consumes Codex's MCP contracts — checkpoint interfaces before building; if Codex's
`ghostbridge_legacy_mcp.mjs` already covers a lane, **wrap or adopt, never duplicate**.

## Labels (earned, current)

- Routing availability gate (0.17.60): **PILOT-READY** (4 Codex rounds, per-site pins, live-fired)
- Receipt spine: components PRODUCTION-grade primitives, ledger **missing** — spine target after
  W3: PILOT-READY
- Evolution organs: **PROTOTYPE** (operationally dead until W11)
- The plan itself: reviewed by 3 adversarial judges; effort figures are the architects', sanity
  range ±30%.
