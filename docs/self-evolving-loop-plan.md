# kist — The Self-Evolving Learning Loop (0.17.45)

**Tier: PROTOTYPE overall** (one PILOT slice inside it: the promote gate — verified live on disk). Nothing new here is built; this is the DESIGN. Every claim below was checked against `/Volumes/PRO-G40/kist-loops/Sources` on 2026-08-07. The ambition is that it's *real* — a loop that measures its own improvement with an oracle it cannot fake — not that it's flashy.

---

## 1. THE ONE-LINE VISION

Every verified win deposits a lesson, a skill sample, and (on a capability gap) a sandboxed `self__` tool; those deposits are read back into the next task's plan, route, and toolset; and the net compounding is proven by an **ablation-controlled COLD-vs-WARM held-out transfer oracle over a corpus disjoint from the eval set** — a number minted only from an execution-grounded `GroundedVerdict` that can go *down* (negative transfer, or losing to a frontier agent) and therefore cannot be growth-hacked upward.

---

## 2. THE ARCHITECTURE — ONE CLOSED LOOP

One loop, eight stages. Each names the **existing kist component** and the **ONE new thing** that stage needs. `[live]` = wired today, `[NEW]` = unbuilt.

```
PERCEIVE ─► ACT ─► VERIFY ─► CLASSIFY ─► LEARN ─► SELF-DIRECT ─► MEASURE ─┐
   ▲                                                                       │
   └───────────────────────────── repeat ◄────────────────────────────────┘
```

| Stage | Existing kist component | The ONE new thing |
|---|---|---|
| **PERCEIVE** | `FlywheelStages.plan` seam; `SemanticMemoryService` (vector store) | **recall→plan wire**: call `.recall(taskShape)`, inject top *verified* lessons into the plan prompt. `[NEW]` — `.recall` is invoked nowhere outside its own tool wrapper (verified: only hit is `SemanticMemory.swift:80`). |
| **ACT** | `FlywheelStages.build`; `SelfAuthoredToolStore` (`self__` tools load at startup) | **self__→toolset wire**: surface promoted tools *matching the task-shape* into the build toolset. `[NEW]` — promoted tools load globally at startup, not task-targeted. |
| **VERIFY (oracle)** | `GreatLoopVerifier` / `CompletionVerifier` — execution-grounded done-gate (real build/test after last edit) + anti-gaming blocklist | — (already the referee currency; reused as-is) `[live]` |
| **CLASSIFY** | `FailureClassifier` → `FailureRouter` → `SelfEvolutionEngine` (taskBug / knowledgeGap / toolLimit / blocked → distinct recovery) | — (already routes; feeds curriculum in Self-Direct) `[live]` |
| **LEARN — deposit** | `SemanticMemory.remember` (auto-lesson on verified win); `CaptainLearningStore.record` (referee-measured); `ClosedEvolutionLoop` (gap→`self__` tool) | **the triangle close**: repeated obstacle in recall → nominate a capability; promoted skill → recallable "winning approach" lesson. `[NEW]` (deposit sides exist; the *edges between corners* don't) |
| **LEARN — read-back** | `CaptainLearningStore.modelVerdicts` → **routing (`KistRunner+GreatLoop.swift:71`)** | — this is the **one live read-back wire**. `[live]` The other two read-backs are the PERCEIVE/ACT rows above. |
| **SELF-DIRECT** | `CaptainLearningStore.byReason` histogram; `EvalHistoryStore`; `TrajectoryAnalyzer`; `/evolve` path into `ClosedEvolutionLoop.run` | **`CurriculumSelector`**: read own aggregate failure taxonomy, author the evolution brief itself (today the brief is human-supplied). `[NEW]` — no such symbol in tree. |
| **MEASURE** | `EvalRunner` / `EvalGoldenSuite` / `EvalHistoryStore`; `GroundedVerdict.fromCode` (private-init `.code` verdict, `GroundedVerdict.swift:59/71`); `CompetitiveBenchmark.CostPerVerifiedSuccess`; `RunAnalytics.lift`; `FleetHeldOutRunner` | **ablation COLD/WARM + slope + head-to-head scoreboard**. `[NEW]` — `EvalRegression.compare` only compares vs the *immediately-prior same-version* baseline (verified `EvalGolden.swift:90–102`); it cannot see cross-epoch transfer. |

The synthesis insight: **PERCEIVE + LEARN-read-back + MEASURE are one held-out, author-blind, corpus-disjoint measurement spine, not three.** The facets' "ablation oracle," "universal promotion gate," and "scoreboard" collapse into a single `GroundedVerdict`-minted harness. Building it once is the synthesis.

---

## 3. PHASES (ordered by leverage)

### Phase 0 — The Ablation Harness (COLD/WARM) — *do this first*
- **Goal:** a measurement that turns every later wire into a proven delta, not a hope.
- **Mechanism:** each epoch, run every `EvalGoldenSuite` case in two arms — **COLD** (all three stores ablated: empty `.recall`, no promoted profiles, no `self__` tools) and **WARM** (full accumulated state). Extend `EvalRunner`/`EvalHistoryStore` with an arm tag and a `CurriculumTarget`-style epoch key. Metrics are `GreatLoopVerifier`-grounded (rounds + tokens to VERIFIED), never self-reported.
- **THE ORACLE:** verdicts are machine-checked: **TURNING** = `WARM.passRate ≥ COLD.passRate` AND `WARM.median_rounds < COLD`; **ACCELERATING** = slope of `advantage_t = (WARM−COLD)` vs `knowledge_size_t` across epochs is `> 0`; **PLATEAUED** = slope ≈ 0 (reported honestly — real flywheels plateau); **NEGATIVE TRANSFER** = `WARM < COLD` → alarm + quarantine. **Integrity linchpin:** the lesson/skill/tool corpus feeding WARM must be content-hash **disjoint** from the eval corpus, itself test-pinned — else WARM wins by memorization.
- **Tier:** PROTOTYPE. **Reuses:** `EvalRunner`, `EvalGoldenSuite`, `EvalHistoryStore`, `GreatLoopVerifier`. **Depends on:** nothing — can run **today** against routing-only state to establish COLD.

### Phase 1 — recall→plan read-back (the cheapest missing wire)
- **Goal:** close the second read-back edge (memory→plan).
- **Mechanism:** at `FlywheelStages.plan`, call `SemanticMemoryService.recall(taskShape)`, inject top verified lessons into the plan prompt.
- **THE ORACLE:** the Phase-0 COLD/WARM advantage on the disjoint held-out set moves up **and** no case regresses (`EvalRegression`). If the delta is flat, the wire is inert — reported as PLATEAUED, not spun.
- **Tier:** PROTOTYPE. **Reuses:** `SemanticMemory.recall`, `FlywheelStages.plan`. **Depends on:** Phase 0 (else unfalsifiable).

### Phase 2 — self__→toolset read-back + triangle close
- **Goal:** third read-back edge (capability→toolset) + turn logging into compounding.
- **Mechanism:** surface promoted `self__` tools matching the task-shape into the build toolset; wire the three triangle edges — obstacle→capability (`BuildResult.createdTools` is the trigger, verified in `FlywheelTypes.swift:20`), capability→skill (reuse the `samples≥3 & successRate≥0.67` promote gate), skill→memory (write the promoted profile back as a recallable lesson).
- **THE ORACLE:** COLD/WARM advantage slope stays `> 0` as `knowledge_size` grows (compounding, not just a one-time bump); negative-transfer alarm stays silent.
- **Tier:** PROTOTYPE. **Reuses:** `SelfAuthoredToolStore`, `ClosedEvolutionLoop`, `CaptainLearningStore` promote gate. **Depends on:** Phase 0 + 1.

### Phase 3 — Universal Promotion Spine + growing ratchet
- **Goal:** every self-change kind, not just tools, passes one fail-closed gate; the eval suite grows anti-gaming-first.
- **Mechanism:** lift `ClosedEvolutionLoop.run` from `extendTool`-only (verified: `guard decision.kind == .extendTool`, `ClosedEvolutionLoop.swift:89`) to a `SelfChange` sum type {tool, prompt, routerPolicy, modelAssignment}; all funnel through the identical sequence (provider-distinctness fail-closed → `CIIntegrityGuard`+build/test → jeeves-floor veto → different-provider adversary → `AdversarialPromoteGate`). Feed a companion append-only case store from `CompletionVerifier`-passed records only (**not** `SemanticMemory` — its auto-lessons are ungated). Metric = **monotonic COUNT of held-out cases passing at frozen difficulty** (never a rate — rate is gameable by adding easy cases), author-distinct, surviving `EvalGoldenSuite.version` bumps.
- **THE ORACLE:** a previously-green held-out case regressing = mechanical hard reject; author-distinctness (analog of the existing provider-distinctness rule) prevents a change authoring the case that proves it.
- **Tier:** PROTOTYPE. **Reuses:** `ClosedEvolutionLoop`, `AdversarialPromoteGate`, `CIIntegrityGuard`, `jeeves-floor check_contradiction`, `EvalGolden*`. **Depends on:** Phase 0.

### Phase 4 — Capability Graph + retirement
- **Goal:** flat `self__` store → a composing, self-pruning capability graph that grows *more capable*, not just bigger.
- **Mechanism:** add `composes: [String]` to `SelfAuthoredManifest`; new `CompositeTool` runs each child through the existing `ScriptTool.runContained` (network-denied, writes-confined, fail-closed); discovery-before-authoring via `SemanticMemory` embedding of manifests; wild-failure ledger (via `CompletionVerifier`) retires rotted tools + transitively re-gates dependents.
- **THE ORACLE:** (A) composite correctness = end-to-end re-execution by the adversary on adversary-chosen input, never inheritance; (B) "more capable not bigger" = `EvalRunner` held-out solved-count strictly **up** at equal-or-lower tool count — else the addition is pruned.
- **Tier:** PROTOTYPE. **Reuses:** `ScriptTool.runContained`, `SelfAuthoredToolStore`, `CapabilityDiscovery`, `SelfEvolutionLedger`. **Depends on:** Phase 3 (spine) + `CurriculumSelector` optional.

### Phase 5 — `CurriculumSelector` (self-directed target) + **FLIP STANDING AUTONOMY**
- **Goal:** kist picks its own weakest capability and authors its own brief; then flip the already-built autonomy flag.
- **Mechanism:** deterministic `CurriculumSelector` reads `CaptainLearningStore.byReason` + `EvalHistoryStore` trend + `TrajectoryAnalyzer` frequency → highest `(frequency × severity × recency)` bucket (excluding ledger-resolved/rate-capped) → pre-registers a hash-pinned held-out slice → hands the brief to `ClosedEvolutionLoop.run`. Post-check credits the target ONLY if the held-out slice improved AND nothing else regressed; a miss deprioritizes re-selection.
- **THE ORACLE:** pre-registration + held-out + counterfactual — the selector cannot mark its own pick correct by self-report; `targetMissed` is a first-class recorded outcome.
- **⚑ FLIP STANDING AUTONOMY:** this is **not** new code — standing autonomy is **already built, off-by-default**. This phase *flips the flag*, gated on Phases 0/5 oracles having run on **real held-out cases** (COLD/WARM proven to compound, curriculum post-check green). Autonomy turns on because the proof exists, not because the code got written.
- **Tier:** PROTOTYPE (selector) → the flip itself is a config gate on proof. **Reuses:** `byReason`, `EvalHistoryStore`, `SelfEvolutionLedger` rate-cap, `/evolve`. **Depends on:** Phase 0 + 3.

**Dependency order:** 0 → 1 → 2 → 3 → (4, 5). Phase 0 gates everything (it's the oracle). Phase 5's second half is the autonomy flip.

---

## 4. THE MOAT + THE SCOREBOARD

Two things make "kist is best" a **measured fact**, both anti-growth-hack:

**THE MOAT — a promote gate that structurally cannot self-certify.** Verified live on disk: `.kist/self-evolution.jsonl` shows `self__reverse` REJECTED, `self__add` REJECTED then PROMOTED; the promoted tool is durable at `.kist/self-tools/self__add/` and loads at startup. Provider-distinctness is **fail-closed** (`guard adversary.provider != cand.authorProvider`, `ClosedEvolutionLoop.swift:116`) — an adversary sharing the author's provider returns `.rejectedSameProvider`. This is the one PILOT slice.

**THE SCOREBOARD — the un-fakeable metric.** It is **not** a rising success curve. It is:
1. **COLD-vs-WARM advantage slope** on a content-hash-disjoint, author-blind held-out corpus, minted **only** through `GroundedVerdict.fromCode` (`source == .code`, private init — no public path forges a `.green`, so a self-reported pass is *type-impossible*).
2. **Head-to-head vs a single frontier agent** in the *identical* `EvalRunner` harness, scored by `CostPerVerifiedSuccess` (`CompetitiveBenchmark.swift:44`) — the row shows **$/verified-success for both**, and can show **kist LOSING**.
3. **Per-case ratchet:** any previously-green held-out case regressing flips the curve **down** and is un-hideable (not averaged away).

The honesty signature: **the metric can go down** — negative transfer alarms, kist loses to frontier, a red case drops the count. A metric that can only rise is the growth-hack the whole design rejects.

**Honest ceiling (do not round up):** the gate is execution-grounded + a KNOWN-attack blocklist + a probabilistic LLM adversary + a domain-limited abstaining symbolic veto. It is **NOT** sound like AlphaProof's Lean checker. Correct claim: *"structurally cannot self-certify, and raises the bar past shipped self-improvers that got gamed"* — **never** *"cannot be gamed."*

---

## 5. HONEST DIFFERENTIATORS

| # | Claim | Rating | Why (prior art named) |
|---|---|---|---|
| 1 | **Promotion that is structurally impossible to self-certify** — fail-closed on provider identity + a blocklist built against DGM's *exact documented cheats* (faked logs, deleted detectors), shipped & live-proven on disk. | **Rare** (uncommon composition of known parts, shipped-and-enforced). Not world-first: DGM/AlphaEvolve shipped the closed loop (and got gamed); Voyager shipped persistent verified skills; multi-agent debate exists. The *composition as one enforced gate* is what no shipped self-improver combines. | The single "I wish ours did that" for a frontier engineer. |
| 2 | **Ablation-controlled COLD-vs-WARM held-out *transfer* oracle** with corpus-disjointness guard + explicit **negative-transfer alarm**, over three self-improvement stores. | **Rare — closest to world-first at the shipped-composition level.** The field ships the loop and reports rising (confounded, saturating) success curves. I found no shipped self-improver proving compounding via an ablation-arm causal transfer measurement with a disjointness guard. Not claiming the flywheel concept is new — claiming *this causal oracle over these stores*. | Kills the growth-hack the field lives on. |
| 3 | **Routed failure taxonomy** (`FailureClassifier`→`FailureRouter`: taskBug/knowledgeGap/toolLimit/blocked → *distinct* recovery). | **Rare.** The field retries on "score didn't move." | Cheap, already live, genuinely uncommon. |

**Hype killed:** "self-improves / remembers / sandboxes" (labs ship all three), "runs local" (common), "Luke owns it" (ownership, not a technical edge), "owns its loop" (so do Claude Code and Codex).

---

## 6. WHAT'S DONE vs WHAT'S NEW (we're ~60%+ there)

| Component | State | Verified |
|---|---|---|
| `ClosedEvolutionLoop` (author→gate→veto→adversary→promote, fail-closed) | **DONE (PILOT, live on disk)** | `.jsonl` ledger + `.kist/self-tools/self__add` |
| `modelVerdicts` → routing read-back | **DONE (live)** | `KistRunner+GreatLoop.swift:71` |
| `SemanticMemory.remember` (deposit) | **DONE** | write side live |
| `CaptainLearningStore` referee scorecard + `byReason` | **DONE** | `CaptainLearning.swift:308` |
| `FailureClassifier`/`FailureRouter`/`SelfEvolutionEngine` | **DONE** | `SelfEvolution/*` |
| `EvalRunner`/`EvalGolden`/`EvalHistoryStore` (adjacent-baseline regression) | **DONE** | `EvalGolden.swift:90` |
| `GreatLoopVerifier`/`CompletionVerifier`, `GroundedVerdict.fromCode`, `CompetitiveBenchmark.CostPerVerifiedSuccess`, `RunAnalytics.lift`, `FleetHeldOutRunner` | **DONE (reusable)** | all present in tree |
| **`.recall`→plan wire** | **NEW** | `.recall` unwired (`SemanticMemory.swift:80` only) |
| **`self__`→toolset wire + triangle close** | **NEW** | promoted tools not task-targeted |
| **Ablation COLD/WARM harness + slope + disjointness guard** | **NEW** | `compare()` is adjacent-baseline only |
| **Universal `SelfChange` spine + growing ratchet** | **NEW** | loop is `extendTool`-only (`:89`) |
| **`CapabilityGraph` + `composes` + retirement** | **NEW** | no such field/symbol |
| **`CurriculumSelector` + pre-registration** | **NEW** | no such symbol |
| **Autonomy flip** | **Built, off-by-default** | flag flip gated on proof, not new code |

Accumulators, deposit seams, the referee currency, the gate, and one read-back wire all exist. The missing pieces are two read-back wires, the triangle edges, and the measurement spine.

---

## HIGHEST-LEVERAGE NEXT MOVE

**Build the ablation harness (Phase 0) — COLD/WARM on the existing `EvalGoldenSuite`, run today against routing-only state to establish the COLD baseline.** It reuses `EvalRunner`/`EvalHistoryStore` with only an arm tag + epoch key, needs no other phase, and converts every subsequent wire (recall→plan, self__→toolset, curriculum) from an unfalsifiable hope into a measured delta on a disjoint held-out corpus. Per Luke's rule #1, no improvement counts until a machine-checkable oracle proves it — so the oracle is the thing that unlocks the rest.
