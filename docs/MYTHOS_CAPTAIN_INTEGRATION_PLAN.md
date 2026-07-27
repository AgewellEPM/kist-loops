# Mythos × Terminal Captain — Integration Research & Plan

**Date:** 2026-06-26 · **Status:** cross-system analysis (3 read-only Explore agents mapped the
Captain in `/Users/lukekist/TinkySDRMac`; Mythos state is this session's work).

> **Question:** what's missing in each, and do we bring the Captain into Mythos now?
> **Answer:** the Captain IS Mythos's missing Phase 5 (supervised fan-out + trust), already built and
> Codex-hardened in the same language. The two are **complementary, not redundant** — bring it in.

---

## 0. The finding in one paragraph

Mythos has a **cross-vendor in-process team** (planner/coder/critic as different vendors, typed
plan-DAG, verify-the-goal critic, per-vendor OTel-style cost spans, BYOK 10 providers, minimal
memory) — but **no supervised parallel fan-out and no trust layer.** The TinkySDR Captain is exactly
that missing layer — **worktree-isolated parallel agents, a forge-proof signed signoff ledger,
lease-enforced disjoint scopes, a merge gate, an Ed25519 deploy gate, a claim-vs-evidence
anti-hallucination reconciler, a deterministic conscience/kill-switch, and cross-run lesson memory** —
~30 modules, each with a full test suite, ~80–90% Foundation-only pure logic. **But the Captain spawns
single-vendor Claude Code CLI subprocesses** (`cu` via Terminal AppleScript) and has no cross-vendor
roles, no typed plan-DAG, no per-vendor cost tracking. **Each system is the other's gap.**

---

## 1. Cross-compare: what each has, what each lacks

| Capability | Mythos (here) | Captain (TinkySDR) |
|---|---|---|
| Provider-agnostic, BYOK, cross-vendor ROLES (planner/coder/critic = different vendors) | ✅ live | ❌ Claude-only (`cu` subprocess) |
| Typed validated plan-DAG + replan | ✅ | ⚠️ ordered steps + scopeGlobs (AgentPlanner), not a typed DAG |
| LLM verify-the-goal critic + honest-fail | ✅ | ✅ (Foreman 6 evidence gates + SymbolicCaptain referee — **stronger**) |
| Per-vendor token/cost observability (OTel spans) + budget ceiling | ✅ (this is the Captain's G4 gap!) | ❌ bespoke cockpit, no cost tracking |
| Cross-run memory | ⚠️ minimal (facts+episodes) | ✅ consolidation+decay (FleetLessonStore) + EMA fitness (CaptainMemory) — **stronger** |
| **Supervised PARALLEL fan-out** (N agents) | ❌ (seam only) | ✅ FleetSupervisor bounded sweep loop |
| **Worktree isolation + committed-diff measurement** | ❌ | ✅ GitIsolation (`base...HEAD`) |
| **Forge-proof signed signoff** (HMAC + hash-chain) | ❌ | ✅ FleetSignoffLedger + ForgeSeal |
| **Lease enforcement** (disjoint scopes, merge gate refuses out-of-scope) | ❌ | ✅ FleetScopeValidator + joinSignedBranches |
| **Anti-hallucination** (claim vs measured diff/tests) | ❌ | ✅ ClaimReconciler |
| **Conscience** (deterministic kill-switch, drift/Goodhart detection, no-forge verdict) | ❌ | ✅ Governor + SymbolicCaptain + GroundedVerdict (private init) |
| **Ed25519 deploy gate** (replay-protected promotion) | ❌ | ✅ FleetPromotionGate |
| In-process agent loop (no subprocess/AppleScript) | ✅ | ❌ spawns external Claude Code CLI |

**The complementarity is near-total.** Mythos = the heterogeneous brain; the Captain = the supervised,
forge-proof body. Merged: **a fleet of DIFFERENT-vendor agents, each in a worktree lease, work
forge-proof-signed, merged through a critic+evidence gate, with per-vendor cost + cross-run lessons.**
That is the literal dream ("summon AI agents of other types, running as a team," at scale, safely).

---

## 2. Portability — it's a port, not a rewrite (~80–90% Foundation-only)

The Explore agents read every file and checked imports. Verdict by layer:

**Copy-as-is (Foundation-only, zero coupling):**
- `GitIsolation` (worktree + `base...HEAD` committed-diff + merge-to-integration, never main)
- `FleetScopeValidator` (disjoint-lease math), `ClaimReconciler` (claim vs evidence),
  `FleetPromotionGate` (logic), `Governor` (kill-switch), `DriftDetector`, `SymbolicCaptain` +
  `CaptainRule/Set/Facts`, `GroundedVerdict`, `DriftReconciler`, `FleetIntegrationVerifier`
- `FleetProgressReader` (advisory live signal), `FleetLessonStore` (consolidation+decay),
  `ProactiveInitiative`, `TurnDiffHarvester`
- `AgentPlanner`, `Baton` (state machine), `FleetBlackboard`, `LockTable.analyze`,
  `FleetRecoveryPlanner`, `FleetUpdateInbox` — value types + pure logic
- **Their unit tests come too** — run them first to validate the port.

**Adapt (small, well-understood):**
- **CryptoKit → swift-crypto** (Mythos is cross-platform; same API, open-source impl). Affects
  ForgeSeal, ConscienceLedger, FleetPromotionGate, OutcomeAttestation.
- **Keychain → file-based key** (macOS Security.framework isn't cross-platform). ForgeSeal's HMAC key
  storage. For a same-machine tool a protected file (or just the Foundation-only hash-chain without the
  HMAC seal) suffices; HMAC is belt-and-suspenders over the chain.
- **Type adapters:** `GroundedVerdict`/`CaptainVerdict` ↔ Mythos's critic verdict; `AgentCell` ↔
  Mythos agent state; `FleetSignoffEntry` ↔ Mythos signoff. FleetCockpitModel/CaptainMemory need these.

**Replace (the spawn seam — and this is an UPGRADE):**
- **`ClaudeCodeLaunch` (Terminal AppleScript → `cu` subprocess) → Mythos's in-process agent loop.** The
  Captain's orchestration core is **deliberately spawn-agnostic** (every seam injectable: `spawn`,
  `makeWorktree`, `readProgress`, `doneSentinel`, `merge`). Mythos plugs its **own in-process
  cross-vendor loop** in as the agent — no AppleScript, no Claude-only subprocess. *This is how the
  fleet becomes heterogeneous: each worktree agent is a Mythos role-bound loop on any vendor.*
- **`TerminalCaptainBrain` (NotepadAI/LocalAIKeys) → Mythos ProviderRegistry** (we have it).
- **Don't port the SwiftUI views** (`*CockpitView`, `CaptainDrive/*` AX/ScreenGrid) — port the pure
  `FleetCockpitModel`; render with our terminal trace.

**Effort (agents' estimate):** trust + isolation spine ≈ mostly copy + the crypto swap (~days);
full orchestration with the Mythos spawn seam ≈ 9–15 focused days. Realistically a **multi-week**
port, best done **staged**.

---

## 3. Recommendation: YES — bring it in, staged. It IS Phase 5.

Mythos's Phase 5 was always "supervised fan-out: single-writer + worktree lease + merge gate" — the
research even said "steal Bernstein's worktree+merge gate." **The Captain is a better, already-built,
Codex-hardened version of exactly that, in our language, with the trust layer Bernstein lacks.** Porting
it *is* building Phase 5 — by adapting proven code instead of writing fresh. Clear yes.

### Staged port (highest-value, most-portable, lowest-risk first)

**Stage 1 — Isolation + trust spine (copy + swift-crypto; no orchestration yet).**
`GitIsolation` + `FleetScopeValidator` + `ClaimReconciler` + `FleetSignoffLedger`/`ForgeSeal`
(swift-crypto, file key) + `GroundedVerdict`/`SymbolicCaptain` referee + their tests. Wire the
signoff/claim/scope gates onto our **existing** PlanExecutor as a single-agent "Foreman" pass first
(prove the trust layer on one agent before fan-out). Reuses our verify-the-goal critic as the
`GroundedVerdict` source.

**Stage 2 — Supervised fan-out with the Mythos in-process spawn seam.**
`CaptainOrchestrator.launchFleet` + `FleetSupervisor` + `Baton`/`FleetBlackboard`/`FleetUpdateInbox` +
`AgentPlanner` (emit disjoint scopeGlobs — feeds our typed DAG's `ownerRole`/`scopeGlobs` seam, which
already exists). The agent each worktree runs = a **Mythos role-bound loop** (cross-vendor!). Merge =
`joinSignedBranches` (signed + in-lease only, integration branch, never main).

**Stage 3 — Conscience + memory + deploy gate.**
`Governor` (kill-switch), `DriftDetector`, `FleetLessonStore` (upgrades our minimal memory to
consolidation+decay), `FleetPromotionGate` (Ed25519 deploy gate). Per-vendor cost spans (we have them)
become the Captain's missing G4.

**Cross-cutting:** keep the Captain's non-negotiables verbatim — **never auto-merge to main, fail-closed,
never arm without explicit say-so, measured-drives-trust / claimed-stays-advisory** (identical to our
own trace invariant — the two systems already share the philosophy).

---

## 4. What's STILL missing after the merge (from the Captain's own gap doc + ours)

The Captain ships its own `FLEET_INDUSTRY_GAP_ANALYSIS.md`. Cross-referenced with what Mythos already
has, the merged system's remaining gaps shrink:

| Gap (Captain's G-list) | Status after merge |
|---|---|
| G4 OTel span tracing | ✅ **Mythos already has it** (AgentTrace gen_ai spans) — port closes this |
| G7 cost tracking | ✅ **Mythos already has it** (BudgetLedger + per-vendor) |
| G5 memory consolidation+decay | ✅ Captain's FleetLessonStore has it → upgrades Mythos's minimal memory |
| G2 acceptance-criterion-as-test (TDD per subtask) | ⚠️ partial (AgentPlanner emits criterion; needs a green-test gate in our executor) |
| G1 trajectory anomaly (read-heavy/no-write/claims-done) | ❌ ~100 lines over FleetProgressReader — build |
| G3 re-plan on stall (dual-ledger) | ⚠️ we have replan; needs the stall-detector wiring |
| G9 checkpoint-resume of agents | ⚠️ we have loop resume; fleet-level resume is new |
| Keychain hardening / signed measurements | ⚠️ Captain's own honest gap (test runner signs its own results) |

Net: **the merge closes more gaps than it opens** — Mythos brings the observability/cost the Captain
lacked; the Captain brings the supervision/trust Mythos lacked.

---

## 5. Honest caveats (the challenge, not just the sell)
- **Scope:** this is a multi-week port across two repos, not a weekend. Stage it; don't big-bang.
- **Mythos isn't shipped** (you chose to keep building). Bringing in the Captain makes Mythos *much*
  more capable but also bigger/later. If the goal is users-soon, the minimal launch still beats a fleet.
  If the goal is *the dream, complete*, this is the path. Worth naming the trade.
- **Two spawn models:** the Captain supervises external CLI subprocesses; Mythos runs in-process.
  The injectable `spawn` seam makes this clean, but the in-process path needs per-agent worktree-cwd +
  the `.fleet-progress.jsonl`/`.fleet-done` sentinel protocol adapted to in-process tasks.
- **Crypto/Keychain:** swift-crypto is a real dependency add (Mythos is currently zero-dep Foundation);
  acceptable, but it's the first external dep. Or drop the HMAC seal and keep the Foundation-only
  hash-chain (slightly weaker, zero-dep).
- **Don't fork-and-drift:** port into AgentCore as the canonical copy; don't leave two diverging Captains.

---

## 6. Bottom line
**Yes — bring the Captain in. It's not a second system; it's the supervised, forge-proof fan-out layer
Mythos was always going to need, already built and hardened in our language, ~80–90% portable.** Merged,
the two become the actual dream: **a supervised fleet of heterogeneous-vendor agents, worktree-isolated,
forge-proof-signed, evidence-gated, cost-metered, learning across runs — in the terminal.** Stage it:
trust+isolation spine → fan-out with the in-process cross-vendor spawn seam → conscience+memory+deploy
gate. The honest counterweight: it's multi-week and it pushes "ship" further out — so the real decision
is *dream-complete vs users-soon*, and that's yours.
