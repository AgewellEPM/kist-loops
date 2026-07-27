# Mythos — Master Build Plan (the Fleet, the Cockpit, the Ship)

**Date:** 2026-06-26 · **Status:** the execution roadmap we build from. Supersedes the scattered
plan docs for *forward* work; the strategic "why" lives in
`MYTHOS_PHASE3_RESEARCH_AND_PLAN.md` / `MYTHOS_LAUNCH_PLAN.md` /
`MYTHOS_CAPTAIN_INTEGRATION_PLAN.md`; this is the *how/what/order*.

> **Where we are:** the engine is ~75% built and live-proven — provider-agnostic loop, typed
> plan→execute DAG, verify-the-goal critic, cross-vendor 3-role team (planner/coder/critic = different
> vendors), per-vendor observability + budget ceiling, minimal cross-run memory. 326 tests.
> **What's left = three things:** the FLEET (supervised parallel fan-out — the Captain port), the
> COCKPIT (mission control), the SHIP (public launch). This plan builds all three.

---

## 0. Research resolved (the build-critical findings that shape this plan)
- **swift-crypto = drop-in CryptoKit** (same API, cross-platform via BoringSSL, shared test suite,
  `HMAC<SHA256>` + Curve25519/Ed25519 + SHA256). → the Captain's ForgeSeal/SignoffLedger/PromotionGate
  port as a **dependency swap**; only Keychain→file storage changes. (First external dep — pin it.)
- **Cross-platform Swift TUI exists** (SwiftTUI / TUIkit / TermKit, macOS+Linux). → the cockpit is
  **terminal-native + cross-platform**, not a separate Mac GUI. Pick **SwiftTUI** (most complete) or
  **TUIkit** (RGB/themes) at Stage 4.
- **The Captain orchestration is spawn-AGNOSTIC** (every seam injectable). → we replace its
  `cu`-subprocess spawn with **Mythos's in-process cross-vendor loop** — the upgrade that makes the
  fleet *heterogeneous* (each worktree agent is any vendor, not Claude-only).
- **Settled multi-agent design** (prior research): parallel for READ frontiers, **serialized
  single-writer** for mutations; worktree = lease; **merge = a critic-gated node**; carry the
  decision-trace not just the task; cap fan-out ≤5–7; never auto-merge to main.
- **~80–90% of the Captain is Foundation-only pure logic** (verified per-file by 3 read-only agents in
  `MYTHOS_CAPTAIN_INTEGRATION_PLAN.md`) — and its unit tests come with it.

---

## 0b. Competitive findings → backlog (2026-06-27 — 4-lens web research)
Full writeup + sources: `MYTHOS_COMPETITIVE_SYNTHESIS_2026_06_27.md`. Verdict: the moat is **real but
narrow** — *disjoint-lease PREVENTION + by-construction-no-fake-green + deterministic-referee-fused-with-
cryptographic-seal + in-process typed-plan team* — and it points at the exact failure the field just
admitted aloud (AgenticFlict: 27.67% silent-merge conflicts; Anthropic + AWS now say "gate on measured
evidence, not the agent's word"). The session's TOCTOU fix IS the live EvilGenie / SWE-bench-Pro exploit.

**LEAD with** the trust spine + disjoint leases + in-process heterogeneous typed-plan team. **NEVER lead
with** worktrees / BYOK / multi-model / routing — all commodity (Claude Code native worktrees, RouteLLM/
OpenRouter/LiteLLM/Portkey, Goose/CrewAI). Closest competitor (Thomson Reuters "Claude Forge") is
subprocessed CLIs + proxy + file-handoffs — exactly what we differentiate against.

**Steals folded into the stages (ranked by leverage/cost):**
1. **[Stage 3 / quick win] Wire `tinky-verify` (our Gemini visual verifier) into `FleetIntegrationVerifier`.**
   The gate today = test exit + diff + size; Factory's validators *launch the app + click flows*. We
   already OWN the hardest part for a different product. Closes green-but-broken-UI. **Cheapest big win.**
2. **[Stage 2b] Promote a Council critic's falsifiable repro into the PERMANENT gavel test suite.** When a
   skeptic constructs a reproducing input, auto-add it as a regression test → the adversary's value becomes
   permanent coverage; "bounded by the gavel" gets strictly tighter over time. Synthesis may only ADD a
   constraint, never DROP a real objection (our multi-site per-assertion discipline, applied to debate).
3. **[Stage 1 hardening] Held-out / mutation-test oracle.** ~31% of "passing" SWE patches pass *weak*
   tests (green but wrong). Run the patch against tests it never saw + mutation-test the suite, so "green
   on a weak suite" can't certify. (TDFlow reproduction-first + EvilGenie held-out.)
4. **[Stage 3 deploy gate] Move the signoff toward Ed25519 + an in-toto/SLSA attestation envelope.**
   Symmetric HMAC = the minter can self-forge (fine for same-user/same-machine; documented residual). For
   external verifiability use the Ed25519 primitive we already built + the in-toto envelope (free interop
   with Sigstore/policy engines; the format EU AI Act Art. 12 is coalescing on). Optional Rekor-style log.
5. **[Stage 2 planner] Aider repo-map (PageRank over the call graph)** to choose leases along dependency
   seams instead of a raw dir-tree → tighter disjoint scopes, fewer forced cross-lease edits.
6. **[Stage 2 merge gate] Rebase-on-latest-before-merge + re-run the gate** for the non-disjoint residual
   (shared interfaces / generated files) — where AgenticFlict says the real conflicts live.
7. **[Stage 2b cost gate] Self-consistency MIDDLE tier:** trivial → fast; medium → self-consistency (N-sample
   vote — cheaper, equal quality to debate on most problems); risky concurrency/IO/security → full Council.
   Don't pay Council cost where SC wins. Cap distinct lenses at 2–3 (more agents ≠ better; raises conformity).
8. **[Stage 2] Race mode:** K agents take the SAME lease; the objective gate score picks the winner. Our
   deterministic gate is uniquely suited to make racing trustworthy (Factory races solution approaches).
9. **[Stage 3+ / interop] ACP (Agent Client Protocol)** so foreign agents (Codex/OpenCode) can join a
   Mythos-supervised fleet under our lease+gate discipline — turns the gate into a *governance layer over
   any agent*, not just ours.

**Two honest caveats (label discipline — carry into every "done"):**
- The **text-protocol loop is a TRADE**, not a pure win: provider-agnostic by construction, at the cost of
  native tool-use reliability + provider prompt-cache savings (LiteLLM/Vercel-AI-SDK exploit those). A
  sharp enterprise eval probes exactly there. Don't sell it as free.
- **"A flaw is real only if a test fails it" is a SAFETY guarantee (no regression ships), NOT a correctness
  one** (untested failure modes are invisible). The gavel must never breed false completeness → PILOT-READY
  framing, not "verified correct." Also: the Council **synthesizer must stay non-authoritative** (the gavel
  decides; LLM-judge bias is real) and ideally be a *different* vendor than the debaters.

---

## 1. The arc + the order
**The Fleet and the Cockpit are ONE build** — the Captain *is* the supervised fleet *and* its cockpit.
So the main thrust is the **Fleet+Cockpit arc** (completes the engine + delivers mission control).
**The Ship is a parallel packaging sprint** — days of work, gated only on two decisions (license, name).

**Recommended sequence:** Stage 0 → 1 → 2, then Ship the swarm demo, then Stages 3 → 4.
Rationale: Stage 1 (trust spine on one agent) is low-risk and everything hangs off it; Stage 2 (fan-out)
is the "swarm" payoff and the demo that makes the launch land; Ship rides Stage 2's demo; Stages 3–4
(conscience/memory/deploy + cockpit) harden and visualize.

**Discipline (every stage, non-negotiable):** small tested increments, Codex-gated; each ported file =
copy → swift-crypto/type-adapt → adapt its TinkySDR test → commit; never auto-merge to main; fail-closed;
never arm the fleet without explicit go; **measured drives trust, claimed stays advisory**; honest labels.

---

## 2. THE FLEET + COCKPIT BUILD (the heavy detail)

### Stage 0 — Foundations: deps + the spawn seam + isolation (~2–3 days)
1. **Add `swift-crypto`** to `Package.swift` (pinned exact version). First external dep — document why
   in the commit. Re-verify all 326 tests + Linux CI green with the dep added.
2. **Port `GitIsolation`** → `Sources/AgentCore/GitIsolation.swift` (Foundation-only: worktree create
   with captured `base` SHA, `git diff base...HEAD` committed-diff, `mergeIntoIntegration` never-touches-
   main, commit/discard, branchHasCommits). Bring its `GitIsolationTests`. *Increment 1.*
3. **Define the in-process spawn seam** — `AgentSpawner` protocol: `spawn(task, worktreeCwd) async ->
   Bool`, plus the sentinel protocol (`.fleet-progress.jsonl` writer + `.fleet-done` marker) adapted to
   an **in-process Mythos loop** running cwd'd to the worktree. (We already have `FleetProgressReader`
   to consume it — it ports clean.) *Increment 2.*
- **Gate:** Codex review; both builds green; isolation tests pass on macOS + (CI) Linux.

### Stage 1 — Trust + isolation spine, on ONE agent (~1 week)
Prove the forge-proof trust gates on a *single* agent before any fan-out — wire them onto the
**existing** `PlanExecutor` as a one-agent "Foreman pass."
- **Port (each its own increment: copy → swift-crypto/type-adapt → adapt test → commit):**
  - `FleetScopeValidator` (disjoint-lease math — 100% Foundation, copy)
  - `ClaimReconciler` (claim-vs-committed-diff/tests — Foundation, copy)
  - `ForgeSeal` (swift-crypto `HMAC<SHA256>`; **Keychain→file key** in `~/.mythos/keys/`, 0600)
  - `FleetSignoffLedger` (hash-chain + seal; pure once ForgeSeal is swapped)
  - `SymbolicCaptain` + `CaptainRule/RuleSet/Facts` + `GroundedVerdict` (private-init no-forge) +
    `FleetIntegrationVerifier` (all Foundation, copy)
- **Wire:** after `PlanExecutor` runs, run a `Foreman.inspect`: committed? diff present? in-lease?
  tests green? claims reconciled? → build `CaptainFacts` → `GroundedVerdict.fromCode` → on `.green`
  only, `FleetSignoffLedger.record` mints a sealed signoff. **Feed our existing verify-the-goal critic
  in as a WorldFacts/proxy signal.** *Increment N.*
- **Outcome:** a single agent's "done" is now **forge-proof-signed + claim-reconciled** — the trust
  layer is alive, proven on one agent. Honest label: PILOT.
- **Gate:** Codex; the ported TinkySDR trust tests pass under swift-crypto; a discriminator test proves a
  forged "done" / out-of-scope file is refused.

### Stage 2 — Supervised fan-out: the swarm (~1.5–2 weeks)
Port the orchestration; plug in the **in-process cross-vendor** spawn seam.
- **Port (per-increment):** `AgentPlanner` (emit DISJOINT `scopeGlobs` — feeds our plan-DAG's existing
  `ownerRole`/`scopeGlobs` seam), `Baton`+`FleetBatonStore`, `FleetBlackboard`+`Store`,
  `LockTable.analyze`, `FleetUpdateInbox`, `FleetRecoveryPlanner`, `CaptainOrchestrator.launchFleet`,
  `FleetSupervisor` (bounded sweep: drain → fold progress → surrender/timeout → inspect → sign →
  refresh slices → merge).
- **The spawn upgrade:** each worktree runs a **Mythos role-bound `PlanExecuteLoop`** (so different
  agents = different vendors), launched via `AgentSpawner` (in-process detached `Task`, cwd'd to its
  worktree, writing the progress/done sentinels). NOT a `cu` subprocess. This is the heterogeneous fleet.
- **Merge gate:** `joinSignedBranches` — only **signed + in-lease (outOfScopeCount==0)** branches merge
  onto the `integration` branch (NEVER main); then run **integration tests on the combined tree**
  (catches cross-agent regressions). Merge is a serialized, critic-gated node.
- **Invariants:** single-writer per artifact; **cap fan-out ≤5–7** (hard-refuse a planner asking more);
  **carry the decision-trace** (resolved `${id}` outputs + rationale) into each worker's brief.
- **Kist surface:** `kist fleet "<goal>" [--agents N] [--planner … --coder … --critic …]` → launches the
  supervised heterogeneous fleet. Off by default; bounded; never auto-merges main.
- **Outcome:** a real **supervised heterogeneous swarm you command** — the gap between "a team" and "a
  fleet." Label: PILOT (live-fleet verify required).
- **Gate:** Codex (point it AT the seams — orchestrator↔supervisor↔foreman); a real-git integration test
  (XCTSkip if git absent) proving two agents in disjoint leases merge, an out-of-lease one is refused.

### Stage 2b — Orchestration MODES (the fleet supports two coordination shapes)
Same fleet substrate (Stage 2), two modes, picked by problem shape:
- **Disjoint-scope fan-out** (default) — for DECOMPOSABLE work: split into disjoint-lease lanes,
  parallel workers, merge. *"Build feature X across these files."*
- **Adversarial debate-synthesis ("Council" / the 4-phase protocol)** — for ONE HARD problem where max
  solution quality matters: **(1) isolated research** (each vendor researches blind — cross-vendor =
  built-in cognitive diversity) → **(2) adversarial cross-critique** (skeptic-PRIMED, NOT
  forced-disagree; each critic a DISTINCT lens — correctness/security/perf/repro — a panel, not N
  clones) → **(3) synthesis** (neutral context folds the debate log into one plan, MoA-style) →
  **(4) deterministic GAVEL** (real tests + the forge-proof signoff — = Stage 1's ForgeSeal/
  FleetSignoffLedger; an "HMAC-sealed `sealed=1`" outcome). KEY INVARIANT: the adversary's value is
  BOUNDED BY THE GAVEL — a raised flaw is real ONLY if it fails a deterministic test; without the
  gavel it's just louder wrong (so Phase 4 must exist before Phase 2 is trustworthy → gavel = Stage 1,
  debate-synthesis = here). EXPENSIVE (15×-token-squared) → an opt-in MODE for hard/high-value tasks,
  gated + measured (quality-per-dollar), never the default. Frame adversarial = *falsifiable-flaw-
  finding*, never *hostile*.

  **Implementation contract (Luke 2026-06-27 — locked):**
  1. **Falsifiable Skepticism ("show me the input").** A critic's objection is only LOGGED if it ships a
     concrete, reproducible trigger — a specific input, a mock state, or a precise thread/interleaving
     sequence that reaches a crash or state-mismatch. If it cannot construct that path, it is REQUIRED to
     sign the seam clean. (Exactly how the 2026-06-26/27 Codex pass behaved: 3 real findings WITH triggers
     — key-file trust, concurrency race, silent row-drop — seams 3/5/6 cleared. Put-up-or-shut-up kills the
     manufactured-pedantry / hallucinated-edge-case failure mode that mandated hostility creates.)
  2. **Multi-lens panel, not N hostile clones.** Each critic gets ONE distinct prism and audits only it:
     Performance Architect (exec speed / allocations / loop efficiency) · Security Auditor (privilege
     isolation / sanitization / state-injection) · State-Machine Rigorist (thread boundaries / actor
     isolation / determinism). Specialization > spite; diversity catches failure modes redundancy misses.
  3. **Dynamic complexity gating (the opt-in moat's router).** Match spend to blast radius: minor
     UI/text/format edit → FAST loop (standard execution, low tokens); core concurrency / I/O / security /
     data-integrity change → FULL gated moat (isolated research → falsifiable debate → synthesis → ledger
     gavel). Running Phases 1–4 on a string-format tweak is token suicide; the router decides per-task.
     Ties into Stage 3's cost governance (budget-aware mode selection).

### → SHIP CHECKPOINT (see §3) — ride Stage 2's swarm demo.

### Stage 3 — Conscience + memory + deploy gate (~1 week)
- **Port:** `Governor` (one-way kill-switch + budget/scope/rate gates), `DriftDetector` (Goodhart gap),
  `FleetLessonStore` (consolidation + decay — upgrades our minimal memory), `FleetPromotionGate`
  (Ed25519 deploy gate via swift-crypto, replay-protected), `Conscience` facade.
- **Wire:** kill-switch + drift into `FleetSupervisor`; lessons into the planner's context (extends
  `ProjectMemory`); `FleetPromotionGate.decide` as the **integration→main** gate — returns GO/NO-GO,
  **never writes main itself**, needs a trusted buildID + a valid external attestation + unconsumed nonce.
- **Outcome:** the fleet is governed (killable, drift-aware), learns across runs, and has a fail-closed
  deploy gate. The **full Captain, in Mythos, cross-vendor.**
- **Gate:** Codex; kill-switch + replay + drift discriminator tests.

### Stage 4 — The Cockpit: mission control (~1.5–2 weeks)
- **Decide TUI:** SwiftTUI (most complete) or TUIkit. Add as a dep (cockpit-only target so the core
  `kist` stays lean).
- **Port + build:** `FleetCockpitModel` (trustworthy-by-construction: `willMerge` mirrors the merge gate
  EXACTLY) → render a TUI **board** (TO DO / DOING / DONE, the **drift alarm**, **verified-vs-claimed**,
  per-vendor token trace from `AgentTrace`).
- **Add the ModularCode-mined wins** (`MYTHOS_COCKPIT_IDEAS_FROM_MODULARCODE.md`): **FleetReplay** (scrub
  a run from the span log — the standout, near-free over `AgentTrace`); **CapabilityLedger** (learned
  per-(role,vendor) routing on *verified* outcomes); **longitudinal analytics** (cost-per-verified-
  success + export — also the benchmark substrate).
- **Kist surface:** `kist cockpit` → live mission control; `kist replay <traceId>` → post-hoc scrub.
- **Close the loop the screenshot didn't:** the drift alarm becomes a real **claimed-vs-verified ratio**
  (Foreman evidence turns claims green), so it reads as "847/4154 verified" not "0 verified" — the
  difference between "tells the truth" and "scares the user."
- **Outcome:** the visual command center — the screenshot, but Mythos-native, cross-vendor, terminal,
  cross-platform. Label: PILOT.

---

## 3. THE SHIP (parallel packaging sprint — ~days, gated on 2 decisions)
**Decisions only you can make (these are the ONLY blockers):**
- **LICENSE** — recommend **Apache-2.0** (patent grant + enterprise comfort; "free for all", and the
  patent-retaliation clause is a small shield given the ban-worry). MIT if you want pure reach.
- **NAME** — keep **Mythos** (project) + **`kist`** (command)? Clear both on Homebrew/npm/GitHub; keep
  "Claude" as comparison copy, never identity (claude-flow→Ruflo lesson).

**Then (no further input needed):**
1. Scrub secrets from git history → push public.
2. **README refresh** — current stats are stale ("130+ tests" → **326**; "no native tool-calling" → built;
   no mention of the cross-vendor team / cost meter / memory — the real cards). Add the demo GIF + the
   `kist` = "chest of tools / my surname" line.
3. **Demo GIF/video (60s)** — the 3-vendor team + live per-vendor cost trace (your strongest 15s). If
   after Stage 2, show the **swarm + drift alarm** instead.
4. **Install one-liner** — Homebrew tap and/or `curl | sh` (static Swift binary helps).
5. ✅ Already done: `SECURITY.md`, no-telemetry stance, safe defaults.
- **Timing:** ship after Stage 2 (demo the swarm) OR now (ship the engine, fleet "coming"). Your call.

**Business layer (later, not this plan):** free+open BYOK core → monthly all-models sub (tiered/metered,
routed via an aggregator for ToS — never flat-unlimited) → the hosted **Captain cockpit** (team/enterprise)
as the high-margin tier. Keep BYOK forever.

---

## 4. Effort + sequence summary

| Stage | What | Effort | Outcome | Gate |
|---|---|---|---|---|
| 0 | swift-crypto dep + GitIsolation + spawn seam | 2–3 d | isolation lives, deps in | Codex, builds green |
| 1 | Trust spine on one agent (forge-proof signoff) | ~1 wk | one agent's "done" is unforgeable | Codex, forged-done refused |
| 2 | Supervised heterogeneous fan-out | 1.5–2 wk | **the swarm you command** | Codex@seams, real-git merge test |
| → | **SHIP** (ride the swarm demo) | days | **public, free, on Reddit** | your license+name calls |
| 3 | Conscience + lesson memory + deploy gate | ~1 wk | governed, learns, fail-closed deploy | Codex, kill/replay/drift tests |
| 4 | Cockpit (board + FleetReplay + analytics) | 1.5–2 wk | **mission control**, verified-vs-claimed | live-fleet visual verify |

**Total fleet+cockpit ≈ 5–7 focused weeks**; **ship ≈ days** (parallel). Each stage independently
shippable + honestly labeled.

---

## 5. The decisions that gate progress (yours)
1. **Start point:** Stage 0 (foundations) — recommended; low-risk, everything hangs off it.
2. **Ship timing:** after the Stage-2 swarm demo (recommended) or now.
3. **LICENSE + NAME** (blocks the push only).
4. **Arm the fleet:** default OFF; you flip it on, per-run, with the kill-switch live. Never autonomous-to-main.

---

## 6. The one-line plan
**Port the Captain into Mythos in four staged increments — trust spine → swarm → conscience/memory/deploy
→ cockpit — replacing its Claude-only subprocess spawn with Mythos's in-process cross-vendor loop, so the
result is a supervised, forge-proof, observable fleet of *rival-vendor* agents you command from a terminal
mission-control board. Ship the free open BYOK `kist` to Reddit off the swarm demo. ~5–7 weeks to the full
dream; days to the public drop.** Start at Stage 0.
