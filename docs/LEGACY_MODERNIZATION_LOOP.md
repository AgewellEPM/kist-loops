# kist × Perslis — The Legacy Modernization Loop

**Owner:** Luke · **Lead:** Claude (Fable) · **Council:** Codex/gpt-5.5, GPT-4o, DeepSeek-Reasoner, Grok-3, Gemini · **Date:** 2026-07-03

> The trillion-dollar wedge: point kist at trapped legacy software and safely move it onto modern architecture with **proven** equivalence. This plan is grounded in a code scan of what actually exists (kist substrate + the Perslis emulator) and pressure-tested by the full council. It is deliberately un-hyped, because the honest version is the one that ships.

---

## 1. The honest verdict (the brutal rating is correct)

The pasted self-assessment is accurate, not pessimistic. I confirmed it by scanning the code:

- **Architecture / substrate: ~60-70%.** Real and dense — see §4. The Captain/worker model, isolation, evidence gates, staged promotion, durable supervision, council, specialists, and the new RunLedger all exist.
- **Product capability: ~15-25%.**
- **Enterprise legacy-porting machine: <10%.** The *domain* primitives literally do not exist: `grep` for `golden`, `equivalence`, `characterization`, `simulation` across the whole codebase = **0 files**. The technical heart is unbuilt.

So: **the shape is right, the machine is not built.** That's a good place to be — the hard, generic substrate (the part most teams never finish) is done; what's missing is a bounded, buildable vertical.

---

## 2. The strategic synthesis nobody has said yet: **you already built both halves**

There are two ways to free trapped software, and Luke has a real codebase for each:

| | **Source path (kist)** | **Binary path (Perslis)** |
|---|---|---|
| Input | legacy *source* | legacy *binary* (`.exe`, source lost) |
| Method | understand → port → prove equivalence | run the old binary as-is via an in-house x86/PE interpreter |
| State | `~/Downloads/mythos-captain-substrate` (2286 tests) | `/Volumes/PRO-G40/Perslis` (~12k LOC, X86Interpreter 1757 loc, PE/DOS interp, kernel32/msvcrt shims, AI self-heal) — stalled on coverage Jan 2026 |

The council said, five times independently, that **90% of the difficulty of the whole loop is one thing: behavior capture + a deterministic oracle** (§3, §5). And:

> **Perslis is exactly that missing behavior-capture oracle — for the hardest case, where the source is gone.**

An in-house interpreter *owns every syscall* the legacy binary makes (clock, RNG, file I/O, kernel32 calls). That means it can (a) run the binary **deterministically** (fix the clock/seed/filesystem), and (b) **record every input and output** — which *is* golden-master generation. The council's #1 hard problem is the thing Perslis's architecture is uniquely shaped to solve.

**This reframes Perslis's stall.** It stalled trying to be a *general Windows runtime* — an infinite coverage surface (every Win32 API, GUI, etc.). That mission has no floor. But as a **deterministic, instrumented behavior-capture oracle for a bounded class of stateless console binaries**, the surface is finite and the value is unique: nobody else can port what they can't even read, but Perslis can *run and capture* it. Same code, a mission with a floor.

So the two projects are **one machine**: a shared behavior-capture layer with two backends — a **language-runtime harness** (when source exists) and **Perslis** (when only the binary exists) — both feeding the *same* golden-master → port → equivalence loop in kist.

### 2.5 The bigger pattern: the Captain **orchestrates** Luke's existing micro-projects — it does not rebuild them

Critical correction (Luke): **Perslis was the *first attempt at porting a system, and it was deterministic hand-built code — not an AI model.** It was shown as *raw material*, not a thing to productionize. The real point is larger: **Luke has a library of purpose-built micro-projects, each originally imagined as something the Captain would orchestrate.** Perslis is one exemplar of many.

This is a strategic unlock, and it inverts the default agent-framework assumption:

> The Captain's job when it hits an x86 binary is **not** to learn to emulate x86 — Perslis already does that, deterministically, better than any LLM ever will. The Captain's job is to **know Perslis exists and invoke it as a capability.**

That generalizes. Each micro-project Luke has already written is a **latent, deterministic specialist capability**. The "assemble expertise" limb of the self-improving-Captain vision is not only prompt-shaped specialists — it's a **registry of real tools Luke already built**. This is a moat no competitor has: their agents can only generate code; Luke's Captain can *call his arsenal*. Determinism, again, comes from these hand-built tools being the oracle/executor while the LLM only decides *which tool, when*.

Concretely this needs a **Capability Registry** primitive: each micro-project wrapped behind a thin, declared contract (name · what it does · inputs · outputs · determinism guarantees · invocation) so the Captain can discover and dispatch to it exactly the way it dispatches to a specialist or an MCP tool today. Wrapping is cheap (a manifest + an adapter); rebuilding is a sin. **Next concrete step: inventory the micro-projects and wrap each as a registered capability** — that alone moves capability % more than any single new feature, because it converts already-written value into Captain-callable power.

---

## 3. Kill the "unaligned models to smash safety friction" framing — it's the road to zero

The council was unanimous and emphatic. Every model called it a **trap** ("fast path to irrelevance," "the deal dies at security review," "you'll be reported to their regulators"). The reasons are not moral hand-wringing, they're market mechanics:

- 80% of the legacy-modernization market is **regulated** (banking, payroll, healthcare, insurance, government). They buy **auditability, reproducibility, fail-closed gates, rollback, signed evidence, liability that survives an audit** — the exact opposite of "we removed the friction."
- **In regulated modernization, friction IS the product.** The moat is *boring proof infrastructure around capable models*, not reckless models. An unaligned agent that silently miscalculates a tax and passes its own tests is not a feature; it's the company-ending bug.

This also *is* the safety line Luke already operates under. And it reconciles cleanly with "no human babysitting":

> kist runs the **entire loop autonomously** — capture, port, differential test, evidence — with **AI** verification in the loop, not humans. The only human is the **customer's** CISO/CFO signing off on kist's audit-grade evidence report at the final production cutover. That's not babysitting kist; that's kist producing the proof a regulated human accountability decision legally requires. **Autonomy for the agent; accountability for the enterprise.**

Determinism, therefore, does not come from the model (it never will). **It comes from the oracle: the original system executed in a sealed sandbox (fixed clock, seed, filesystem snapshot), and the port judged byte/row-for-byte against it. Replay + diff is the source of truth.** The model only ever proposes a candidate; the oracle disposes.

---

## 4. The 9 layers: what to build vs. what already exists

The council's core finding: **the new build is layers 2, 3, 6. Everything else reuses the substrate.** Grounded against the actual files:

| # | Layer | Build vs reuse | Concretely |
|---|---|---|---|
| 1 | System archaeology | **Extend** | `RepoMap` exists (symbol map). Add schema/protocol/job/side-effect mapping. |
| 2 | **Behavior capture** | **BUILD (hard core)** | *Does not exist.* Language-harness backend (source) + **Perslis** backend (binary). Record every input/output of the original in a sealed env. |
| 3 | **Golden-master tests** | **BUILD (hard core)** | *Does not exist.* Turn captured I/O into replayable, deterministic characterization tests. |
| 4 | Adapter generation | **Reuse+thin** | kist already writes code; the adapter *pattern* (strangler-fig behind an interface) is new but small. |
| 5 | Migration plan | **Reuse** | `PlanExecuteLoop`, `FleetPlanner`, `AgentPlanner`. |
| 6 | **Equivalence benchmark** | **BUILD (hard core)** | *Does not exist.* Differential harness: run original + port on the same inputs incl. **fuzzed** ones, canonicalize, diff. |
| 7 | Safe staged replacement | **Reuse (strong)** | `GitIsolation` (worktree/committed-only diff), `ReversibilityClassifier` (blast-radius gate), `Promotion*` pipeline, `FleetPromotionGate` (Ed25519, fail-closed). |
| 8 | Evidence report | **Reuse (strong)** | `GroundedVerdict`, `ClaimReconciler` (claims reconciled vs committed artifacts), signoff ledger. Must report **covered / equivalent / not-covered / unprovable** — never just "passed." |
| 9 | Captain lesson promotion | **Reuse (strong)** | `CycleReflection`/`LessonStore`, `PolicyEvolver`, `PromotionGate` (proven → queued, never auto-applied), `RunLedger`. |

**Read this table as the good news:** 6 of 9 layers are mostly-existing substrate. The whole program reduces to building a rock-solid **capture → golden-master → differential-equivalence** core and wiring it into machinery that already works.

---

## 5. The wedge (council consensus): one bounded slice, provable, then market *only* that

**Do NOT market "port anything."** Market one believable sentence (Codex):

> *"kist can replace one legacy API slice and prove equivalence against captured behavior before you cut over."*

Sequenced targets, easiest-provable first:

- **Wedge 0 — stateless transform (purest, start here).** A stateless input-file → output-file (or CLI stdin→stdout) transform. No DB, no clock, no network. Equivalence = **byte comparison**. DeepSeek: *"Start here or don't start."* This exists in **both** tracks: a small source-available CLI tool (language harness) OR a stateless DOS/Win32 console `.exe` (**Perslis** — the differentiated source-lost case). This proves the *entire 9-layer loop closes* with the fewest moving parts.
- **Wedge 1 — stateless JSON CRUD REST service + one SQL DB.** Capture = HTTP request/response pairs + JDBC traffic; equivalence = identical response + identical DB row-diff. The first *commercially real* slice (Grok/Gemini/Codex all converged here).
- **Later** — HTML flows, queues, batch jobs, third-party integrations, larger service extraction. COBOL is the giant prize but is a brutal enterprise sale needing domain tooling — **not first.**

---

## 6. The #1 failure mode (unanimous) and the defense

> **The golden master captures the easy/happy-path traffic, not the true behavioral envelope. The port passes every captured test and is still wrong in production** — on the rare branch, the auth edge case, the month-end/leap-day path, the legacy bug customers secretly depend on, the data-dependent behavior hidden in old DB state.

This is the whole ballgame. A loop that produces a confidently-wrong port is worse than no loop. Defenses (must be built into the equivalence layer, not optional):

1. **Differential fuzzing** — don't just replay the corpus; synthesize new valid inputs, run *both* systems, diff. Discover the divergence boundary.
2. **Property-based invariants** extracted from the original ("row count in = row count out", "no negative amounts", "PHI never logged").
3. **Coverage maps** against the *legacy* system (route/branch/DB-table-touch) so blind spots are visible.
4. **Boundary synthesis** — nulls, empty sets, duplicates, leap days, currency rounding, permission edges.
5. **Shadow mode** before cutover — run the port read-only alongside the legacy system on live traffic, compare.
6. **Canary + automatic rollback** at cutover.
7. **The evidence report tells the truth**: covered / equivalent / **not-covered** / **unprovable**. "If it only says passed, it is dangerous" (Codex).

This is where Perslis shines again: for a binary oracle you control the interpreter, so you can drive coverage *exhaustively* on a bounded binary in a way you can't with a black-box production system.

---

## 7. Sequencing: on top of adoption-first, capture-library in parallel

Council consensus (5/5): the loop **sits on top of** the adoption-first roadmap (`docs/STRATEGY_ROADMAP.md`), it does not replace it. The adoption gates *are* the trust base the loop stands on (GitIsolation, RunLedger, PromotionGate must be exercised daily by real users before an enterprise trusts them on their payroll system).

**Ordering:**
1. **Adoption-first core** (install → reliable wow → routing → persistence). Nobody reaches the modernization product without this.
2. **Reliable substrate** exercised daily (isolation, durable runs, committed-artifact evidence, approvals, rollback).
3. **Build the behavior-capture library IN PARALLEL, now** — it's independent of adoption and it's the long pole. Start with Wedge 0.
4. **Integrate the narrow vertical** as a high-level Captain action once 1-2 are solid.
5. **Expand boundaries** slice by slice.

---

## 8. The phased plan

**Phase L0 — Prove the loop closes on the purest wedge (the spike).**
- Pick one stateless transform. Build the minimum of each layer end-to-end: capture (language harness OR Perslis) → golden-master → generate port → differential diff → evidence report → promotion.
- Success = a real bounded transform ported, with a signed evidence report showing byte-equivalence over a fuzzed corpus, cut over behind an adapter, rollback proven.
- Label: **PROTOTYPE**. This is a spike to de-risk the architecture, not a product.

**Phase L1 — Harden the capture→golden-master→equivalence core as a real library.**
- `BehaviorCapture` (protocol; two backends: `RuntimeHarnessCapture`, `PerslisCapture`), `GoldenMaster` (deterministic replay corpus), `EquivalenceHarness` (differential run + canonicalize + diff + fuzz + coverage map). Pure cores + injected execution, unit-tested to the standard of the rest of kist. Council-reviewed each increment.

**Phase L2 — Build the Capability Registry; WRAP Perslis (don't rebuild it).**
- Build the `CapabilityRegistry` primitive (§2.5): a declared contract per micro-project (name · purpose · inputs · outputs · determinism guarantee · invocation) the Captain discovers and dispatches to like a specialist/MCP tool. This is the reusable unlock — Perslis is the first client of it, Luke's other micro-projects are the next N.
- Wrap Perslis behind that contract as the binary oracle: invoke the *existing* interpreter, add only the thin syscall/IO trace-capture hooks it needs to emit golden-masters (it already intercepts kernel32/msvcrt — the hook points exist). Its deterministic controls (fixed clock, seeded RNG, snapshotted virtual filesystem) are surfaces the interpreter already owns. **New mission for Perslis = bounded deterministic oracle, NOT general Windows runtime. Freeze GUI/coverage expansion.**

**Phase L3 — Wire into the Captain as a guided vertical + the honest evidence report.**
- A "modernize this module" Captain plan that orchestrates the 9 layers over existing fleet/promotion machinery. Evidence report emits covered/equivalent/not-covered/unprovable. Human cutover attestation is the customer's, at the boundary only.

**Phase L4 — Wedge 1 (REST+SQL) and shadow/canary rollout.**
- Add HTTP+JDBC capture, DB-state diffing, shadow mode, canary + auto-rollback.

---

## 9. What NOT to do

- **Don't** lead with COBOL or a stateful DB-heavy monolith. Wrong first battle.
- **Don't** pursue "unaligned models / less safety." It deletes the entire regulated market (§3).
- **Don't** let Perslis chase general Windows-runtime coverage again — that's the stall. Bounded oracle only.
- **Don't** market the trillion-dollar machine. Market the one provable slice until it works brutally well.
- **Don't** trust a green that only says "passed." No coverage + fuzz + unprovable-honesty = a dangerous port.

---

## 10. The one-paragraph strategy

kist and Perslis are the two halves of one machine. The council says 90% of the difficulty is behavior-capture + a deterministic oracle — and Perslis's interpreter is uniquely built to be exactly that, for the hardest (source-lost) case. Build the capture→golden-master→differential-equivalence core as a real library in parallel with the adoption roadmap; re-scope Perslis from "run any Windows app" to "deterministic oracle for bounded console binaries"; reuse the dense existing substrate (isolation, gates, promotion, supervision, council) for the other 6 layers; make the evidence report tell the whole truth including what's unprovable; and market exactly one believable sentence — *replace one legacy slice and prove equivalence before cutover* — until it's undeniable. The moat is proof infrastructure, not reckless models.
