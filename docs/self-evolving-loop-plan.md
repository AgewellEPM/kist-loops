# kist — The Self-Evolving Learning Loop (living status)

**Tier: PROTOTYPE overall; standing autonomy remains off.** This began as the 2026-08-07 design and was reconciled against `/Volumes/PRO-G40/kist-loops/Sources` on 2026-08-28. Several bounded organs and fail-closed data contracts now exist in the current source checkout; source status does not imply installation, production authority, or promotion. Exact-parent paired fitness, external rollback, aggregate containment, identity-distinct review, sealed activation, and witnessed-budget contracts are represented, but their production witnesses/runners are not wired. The ambition is that it's *real* — a loop that measures its own improvement with an oracle it cannot fake — not that it's flashy.

---

## 1. THE ONE-LINE VISION

Every locally checked grounded win may deposit an unsigned advisory lesson, a skill sample, and (on a capability gap) a sandboxed `self__` tool; those deposits can be read back into the next task's plan, route, and toolset, while receipt authority stays separate; and net compounding must be proven by a **parent-relative, ablation-controlled held-out transfer oracle over a corpus disjoint from the eval set** — a number minted only from execution-grounded evidence that can go *down* and therefore cannot be growth-hacked upward.

---

## 2. THE ARCHITECTURE — ONE CLOSED LOOP

One loop, eight stages. Each names the current kist component and its remaining seam. `[live]` =
wired in the current source checkout, not necessarily installed or promoted; `[opt-in]` = deliberately
not a default; and `[NEW]` = unbuilt.

```
PERCEIVE ─► ACT ─► VERIFY ─► CLASSIFY ─► LEARN ─► SELF-DIRECT ─► MEASURE ─┐
   ▲                                                                       │
   └───────────────────────────── repeat ◄────────────────────────────────┘
```

| Stage | Existing kist component | The ONE new thing |
|---|---|---|
| **PERCEIVE** | `SemanticMemoryService`; `HeadlessAgentLoop.recallLessons`; REPL/runner wiring | **recall→plan wire**: inject top typed locally checked, unsigned advisory lessons inside an untrusted-data frame. `[live, opt-in]` in the current source checkout — `KIST_RECALL_INJECT=1`; `--no-memory` hard-disables the service, tools, and injection. Semantic V2 is not installed or promoted. |
| **ACT** | `FlywheelStages.build`; hardened `SelfAuthoredToolStore` | **self__→toolset wire**: surface receipt-authorized tools *matching the task-shape* into the build toolset. `[UNAVAILABLE]` — the repaired public loader returns no legacy/test-authorized tool, production activation is unavailable, and the older installed loader must not be trusted. |
| **VERIFY (oracle)** | `GreatLoopVerifier` / `CompletionVerifier` — execution-grounded done-gate (real build/test after last edit) + anti-gaming blocklist | — (already the referee currency; reused as-is) `[live]` |
| **CLASSIFY** | `FailureClassifier` → `FailureRouter` → `SelfEvolutionEngine` (taskBug / knowledgeGap / toolLimit / blocked → distinct recovery) | — (already routes; feeds curriculum in Self-Direct) `[live]` |
| **LEARN — deposit** | `SemanticMemory.rememberLocallyCheckedLesson`; `CaptainLearningStore.record`; `ClosedEvolutionLoop` (gap→`self__` tool) | Grounded promotion → content-bound, unsigned advisory "winning approach" lesson is `[live]` in the current source checkout; persistence is awaited and surfaced. Semantic V2 is not installed or promoted. Recurring-obstacle curriculum remains incomplete. |
| **LEARN — read-back** | `CaptainLearningStore.modelVerdicts` → **routing (`KistRunner+GreatLoop.swift:71`)** | — this is the **one live read-back wire**. `[live]` The other two read-backs are the PERCEIVE/ACT rows above. |
| **SELF-DIRECT** | `CaptainLearningStore.byReason` histogram; `EvalHistoryStore`; `TrajectoryAnalyzer`; `/evolve` path into `ClosedEvolutionLoop.run` | **`CurriculumSelector`**: read own aggregate failure taxonomy, author the evolution brief itself (today the brief is human-supplied). `[NEW]` — no such symbol in tree. |
| **MEASURE** | `EvalRunner` / `EvalGoldenSuite` / `EvalHistoryStore`; pure COLD/WARM and exact-parent paired validators; `GroundedVerdict.fromCode`; `CostPerVerifiedSuccess`; `RunAnalytics.lift`; `FleetHeldOutRunner` | **production measurement authority**. `[PARTIAL]` — validators and fixtures exist, but no host-owned runner can mint a real paired fitness receipt or a longitudinal head-to-head result. |

The synthesis insight: **PERCEIVE + LEARN-read-back + MEASURE are one held-out, author-blind, corpus-disjoint measurement spine, not three.** The facets' "ablation oracle," "universal promotion gate," and "scoreboard" collapse into a single `GroundedVerdict`-minted harness. Building it once is the synthesis.

---

## 3. PHASES (ordered by leverage)

### Phase 0 — The Ablation Harness (COLD/WARM) — *do this first*
- **Goal:** a measurement that turns every later wire into a proven delta, not a hope.
- **Mechanism:** the source now has pure COLD/WARM and exact-parent paired comparison contracts. The remaining work is a host-owned runner that executes every `EvalGoldenSuite` case in two arms — **COLD** (all three stores ablated: empty `.recall`, no promoted profiles, no `self__` tools) and **WARM** (full accumulated state) — and durably binds arm, epoch, frozen inputs, and evidence. Metrics must be execution-grounded, never self-reported.
- **THE ORACLE:** verdicts are machine-checked: **TURNING** = `WARM.passRate ≥ COLD.passRate` AND `WARM.median_rounds < COLD`; **ACCELERATING** = slope of `advantage_t = (WARM−COLD)` vs `knowledge_size_t` across epochs is `> 0`; **PLATEAUED** = slope ≈ 0 (reported honestly — real flywheels plateau); **NEGATIVE TRANSFER** = `WARM < COLD` → alarm + quarantine. **Integrity linchpin:** the lesson/skill/tool corpus feeding WARM must be content-hash **disjoint** from the eval corpus, itself test-pinned — else WARM wins by memorization.
- **Tier:** VALIDATOR PROTOTYPE / RUNNER MISSING. **Reuses:** `EvalRunner`, `EvalGoldenSuite`, `EvalHistoryStore`, `GreatLoopVerifier`. **Depends on:** host-owned execution and evidence authority; it cannot establish production fitness today.

### Phase 1 — recall→plan read-back (implemented, opt-in)
- **Goal:** close the second read-back edge (memory→plan) without turning advisory memory into authority.
- **Mechanism:** `HeadlessAgentLoop.recallLessons` calls temporal `SemanticMemoryService` recall and injects only typed locally checked, content-bound unsigned advisory lessons in an untrusted-data frame.
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
- **Mechanism:** add `composes: [String]` to `SelfAuthoredManifest`; new `CompositeTool` runs each child through `ScriptTool.runContained`; discovery-before-authoring via `SemanticMemory` embedding of manifests; wild-failure ledger (via `CompletionVerifier`) retires rotted tools + transitively re-gates dependents. The current production `runContained` path intentionally refuses because no qualifying hard runner exists; a composite runner is not live until that backend can mint validated aggregate-containment authority.
- **THE ORACLE:** (A) composite correctness = end-to-end re-execution by the adversary on adversary-chosen input, never inheritance; (B) "more capable not bigger" = `EvalRunner` held-out solved-count strictly **up** at equal-or-lower tool count — else the addition is pruned.
- **Tier:** PROTOTYPE. **Reuses:** `ScriptTool.runContained`, `SelfAuthoredToolStore`, `CapabilityDiscovery`, `SelfEvolutionLedger`. **Depends on:** Phase 3 (spine) + `CurriculumSelector` optional.

### Phase 5 — `CurriculumSelector` (self-directed target) + **EARN A SEPARATE WAKE-UP DECISION**
- **Goal:** kist picks its own weakest capability and authors its own brief; only then can an operator consider a separately authorized wake-up.
- **Mechanism:** deterministic `CurriculumSelector` reads `CaptainLearningStore.byReason` + `EvalHistoryStore` trend + `TrajectoryAnalyzer` frequency → highest `(frequency × severity × recency)` bucket (excluding ledger-resolved/rate-capped) → pre-registers a hash-pinned held-out slice → hands the brief to `ClosedEvolutionLoop.run`. Post-check credits the target ONLY if the held-out slice improved AND nothing else regressed; a miss deprioritizes re-selection.
- **THE ORACLE:** pre-registration + held-out + counterfactual — the selector cannot mark its own pick correct by self-report; `targetMissed` is a first-class recorded outcome.
- **⚑ WAKE-UP REMAINS A DISTINCT OPERATION:** a green curriculum result is necessary but not sufficient. All six machine-readable readiness gates must carry fresh production authority: parent-relative held-out fitness, external rollback witness, hard aggregate containment, actual-route identity-distinct review, sealed activation, and witnessed pre-spawn budget reservation. The current source reports them blocked, and the installed binary is older than this hardened source. No document or model may flip the flags implicitly.
- **Tier:** PROTOTYPE (selector) → the flip itself is a config gate on proof. **Reuses:** `byReason`, `EvalHistoryStore`, `SelfEvolutionLedger` rate-cap, `/evolve`. **Depends on:** Phase 0 + 3.

**Dependency order:** 0 → 1 → 2 → 3 → (4, 5). Phase 0 gates everything, but its production runner is still missing. Phase 5 can only earn evidence for a separate wake-up decision.

---

## 4. THE MOAT + THE SCOREBOARD

Two mechanisms are proposed to test whether Kist improves. No host-owned production run has yet made
"kist is best" a measured fact:

**THE MOAT — a proposed promote gate that must not self-certify.** Historical disk state contains `self__reverse` rejection and an old `self__add` “promoted” row plus manifest/script. That pair has no hardened activation receipt and is sterile under the repaired public loader; it is evidence of a legacy experiment, not a valid promotion. The current source requires opaque host-validated identity-distinct review, one-use hard-containment authority, sealed activation bindings, and exact artifact digests. Production validation/execution intentionally refuses because those authorities are unavailable. The older installed binary may not enforce this boundary and must not run `/grow` or `--evolve`.

**THE SCOREBOARD — the proposed falsifiable metric.** It is **not** a rising success curve. It is:
1. **COLD-vs-WARM advantage slope** on a content-hash-disjoint, author-blind held-out corpus, minted **only** through `GroundedVerdict.fromCode` (`source == .code`, private init — no public path forges a `.green`, so a self-reported pass is *type-impossible*).
2. **Head-to-head vs a single frontier agent** in the *identical* `EvalRunner` harness, scored by `CostPerVerifiedSuccess` (`CompetitiveBenchmark.swift:44`) — the row shows **$/verified-success for both**, and can show **kist LOSING**.
3. **Per-case ratchet:** any previously-green held-out case regressing flips the curve **down** and is un-hideable (not averaged away).

The intended honesty signature is that **the metric can go down** — negative transfer alarms, Kist
can lose to frontier, and a red case drops the count. Those properties are contract/test behavior,
not evidence that a production scoreboard has run.

**Honest ceiling (do not round up):** the proposed gate combines execution evidence, a known-attack
blocklist, probabilistic review, and a domain-limited abstaining symbolic veto. It is **not** sound
like AlphaProof's Lean checker, and production authority is absent. Correct claim: *"the source
contracts are designed to reject self-certification"* — never *"cannot be gamed"* or *"shipped."*

---

## 5. HONEST DIFFERENTIATORS

| # | Claim | Rating | Why (prior art named) |
|---|---|---|---|
| 1 | **Promotion contract designed not to self-certify** — exact identities, held-out evidence, anti-tamper checks, identity-distinct review, hard-containment authority, and sealed activation are fail-closed in source. | **Promising prototype, not shipped proof.** The composition is unusual, but production reviewers, runners, witnesses, and activation are unavailable; legacy on-disk “promoted” rows are sterile. | The contract is valuable only after real host/external authorities exercise it end to end. |
| 2 | **Ablation-controlled COLD-vs-WARM held-out transfer contract** with corpus-disjointness guard and explicit negative-transfer result. | **Interesting prototype, not a field result.** Pure validators/fixtures exist; the host-owned runner and production evidence do not. | It can challenge growth-hacked curves only after real frozen-corpus executions are published. |
| 3 | **Routed failure taxonomy** (`FailureClassifier`→`FailureRouter`: taskBug/knowledgeGap/toolLimit/blocked → *distinct* recovery). | **Rare.** The field retries on "score didn't move." | Cheap, already live, genuinely uncommon. |

**Hype killed:** "self-improves / remembers / sandboxes" (labs ship all three), "runs local" (common), "Luke owns it" (ownership, not a technical edge), "owns its loop" (so do Claude Code and Codex).

---

## 6. CURRENT IMPLEMENTATION SNAPSHOT

| Component | State | Verified |
|---|---|---|
| `ClosedEvolutionLoop` (author→gate→veto→review→activation) | **QUARANTINED / source-only** | current production path cannot promote; legacy `self__add` lacks a hardened activation receipt and does not load through the repaired public authority path |
| `modelVerdicts` → routing read-back | **DONE (live)** | `KistRunner+GreatLoop.swift:71` |
| `SemanticMemory.remember` (deposit) | **DONE in source; not installed/promoted** | write side is source-wired |
| `CaptainLearningStore` referee scorecard + `byReason` | **DONE** | `CaptainLearning.swift:308` |
| `FailureClassifier`/`FailureRouter`/`SelfEvolutionEngine` | **DONE** | `SelfEvolution/*` |
| `EvalRunner`/`EvalGolden`/`EvalHistoryStore` (adjacent-baseline regression) | **DONE** | `EvalGolden.swift:90` |
| `GreatLoopVerifier`/`CompletionVerifier`, `GroundedVerdict.fromCode`, `CompetitiveBenchmark.CostPerVerifiedSuccess`, `RunAnalytics.lift`, `FleetHeldOutRunner` | **DONE (reusable)** | all present in tree |
| **`.recall`→plan wire** | **DONE in source, opt-in; not installed/promoted** | temporal V2 recall is wired into the source loop; `--no-memory` removes every memory surface |
| **`self__`→toolset wire + triangle close** | **QUARANTINED** | targeted source seams exist, but no production-authorized tool currently loads or executes; broader autonomous curriculum does not exist |
| **Ablation COLD/WARM harness + slope + disjointness guard** | **DONE, not sufficient for autonomy** | fixed/moving corpus probes and a pure exact-parent paired-delta validator exist; no host-owned runner can mint production fitness authority |
| **Universal `SelfChange` spine + growing ratchet** | **NEW** | loop is `extendTool`-only (`:89`) |
| **`CapabilityGraph` + `composes` + retirement** | **NEW** | no such field/symbol |
| **`CurriculumSelector` + pre-registration** | **NEW** | no such symbol |
| **Autonomy wake-up** | **UNAVAILABLE** | all six readiness gates require fresh production authority plus a separate operator-approved deployment/wake-up operation |

Accumulators, temporal advisory deposit/read-back, the ablation harness, and bounded evolution seams exist. Pure contracts also exist for parent-relative fitness, rollback anchoring, hard containment, identity-distinct review, activation, and budget witnessing. The blockers are the real authorities behind them: host-owned oracle execution, an external monotonic witness/CAS, a qualifying hard runner, an actual-route distinct reviewer, composed sealed activation, and an external pre-spawn budget reservation.

These implementation states describe the current source checkout. Semantic V2 has not been installed
into the live CLI, no live V2 store exists, and standing autonomy remains disabled.

---

## HIGHEST-LEVERAGE NEXT MOVE

**Wire and independently operate the authorities behind the contracts before considering any wake-up.** First supply a host-owned paired held-out oracle and configured external monotonic rollback witness; then add a qualifying aggregate descendant/resource runner, an actual-route identity-distinct reviewer, composed activation, and witnessed pre-spawn budget reservation. The existing COLD/WARM probes and pure validators are useful evidence, but they do not make a self-authored runtime change safe to promote unattended.
