# Legacy Modernization — Research-Grounded Build Plan

**Date:** 2026-07-03 · **Method:** map → research (5 parallel specialists, ~40 cited sources) → learn/adapt → plan → council. This binds every component of the architecture (`docs/LEGACY_ARCHITECTURE.md`) to a **proven technique + named blueprint**, so we build on what the field already knows instead of reinventing it.

---

## The one-line thesis the research confirmed

> **The EvidenceReport is the product; the port is the commodity.** Determinism comes from a deterministic *oracle + diff harness + honest coverage*, never from the model. Every credible player (Google, IBM, Amazon) lands here; every "trust the smarter/unaligned model" pitch is uninvestable to the regulated buyer who is 80% of the market.

We claim **evidence-bounded equivalence over a stated corpus + invariant set**, never "PROVEN equivalence" — full proof is unavailable for most legacy modules and the overclaim is exactly the dishonesty this system exists to prevent (council).

## ⚠️ Council revisions (5-model REVISE — applied below)

The council pressure-tested this plan and returned REVISE, near-unanimous, with one dominant fix. All corrections are folded into the tables/sequence below; recorded here so the reasoning isn't lost:

1. **The Diffy noise-floor was MISAPPLIED (all 5 flagged).** Diffy learns its floor from two *nondeterministic production* instances that naturally disagree. Our oracle is *sealed-deterministic*, so running it twice is trivially identical — the "floor" is zero and it dangerously over-trusts "both agreed" (a systematic oracle bug hits both runs equally). **Fix:** split the one conflated "noise floor" into **three separate concerns** — (a) a **determinism/capture-integrity check** (oracle replayed twice MUST be byte-identical; nonzero = capture is broken, STOP — do not emit evidence), (b) a **coverage/sample-size** gate (N≥30 smoke, N≥100–300 before "equivalent within corpus"; rare/error paths stay NOT-COVERED unless synthesized), (c) **candidate equivalence** (any unexplained semantic delta after canonicalization is suspect). A *learned* noise floor is legitimate ONLY for nondeterminism we deliberately do NOT seal, learned from *multiple real captures*, never from duplicating one sealed run.
2. **Drop Restate (5/5).** Extend kist's OWN checkpoint+signoff-ledger with a thin layer: stable idempotency keys per (step, input, tool-version), workflow version pinned into the journal, artifact-addressed outputs, skip/replay semantics, explicit per-step compensation. Adopt the journal-and-skip *pattern*, not the external dependency (a dependency trap unless we need distributed durable execution soon — we don't).
3. **Mutation testing = incremental/scoped from day one, and coverage STAYS.** "Mutation not coverage" was too absolute: coverage distinguishes NOT-COVERED from weak assertions; mutation is the *strength* meter on covered code. Mutate only slice-reachable code, prioritize money/date/state-transition/SQL-predicate/validation logic, cheap mutants continuous + expensive nightly. Classify survivors: **KILLED / SURVIVED-ACTIONABLE / SURVIVED-EQUIVALENT / SURVIVED-OUT-OF-SCOPE**; require evidence for SURVIVED-EQUIVALENT (invariant proof or SME rule) so equivalent mutants don't skew the score.
4. **L0 relabeled "harness shakedown," with an explicit ladder.** A stateless pure transform proves the *plumbing* (capture/canonicalize/diff/mutation/report), NOT modernization — calling it a modernization proof is the false-confidence trap 3 of 5 warned about. Sequence: **L0 pure deterministic transform → L1 stateless HTTP boundary → L2 SQL read/write transaction → L3 side-effecting workflow.** State/DB is L1–L2, explicitly *not* "later."
5. **Human gate = risk-acceptance at cutover, never inside the loop.** Autonomy is real *because* the report can emit UNPROVABLE/NOT-COVERED without stalling. The one hidden human gate the council caught — archaeology's "never migrate on an unverified inferred FK/rule" — is fixed by routing low-confidence inferences into the **UNPROVABLE bucket** (optionally auto-verified by a generated differential constraint-test run against both systems), never a silent stall and never a silent proceed.
6. **Perslis's "rr/PANDA fidelity" is a claim to PROVE, not assume.** Instruction/syscall/signal/FP-SIMD/memory-model/thread-scheduling/external-IO fidelity must pass a fidelity-proof gate before PerslisCapture is trusted. The determinism check (#1a) is the mechanism that catches infidelity early.

---

## Component → adopted technique → blueprint

| Spine component | Adopted technique | Named blueprint / tool | Why this one |
|---|---|---|---|
| **SystemOracle** (run original deterministically) | Instruction/syscall-indexed record-replay + unified clock/RNG/FS sealing | **`rr` / PANDA** (record nondeterminism keyed by instruction index) · **libfaketime** (`FAKERANDOM_SEED` seals clock+RNG+FS-timestamps from one shim) | Perslis's interpreter already owns every nondeterministic event → it gets `rr`/PANDA fidelity **without** their single-core/Linux/ptrace limits. Deterministic by construction. |
| **BehaviorCapture / RuntimeHarnessCapture** (source) | Method-level I/O capture + protocol cassettes | JVM agents (**ASM/JVMTI**) · **VCR / Polly.js / WireMock** record-mode (HTTP) · **datasource-proxy / P6Spy** (JDBC) | Standard characterization shape; cassettes are the canonical way to freeze external deps. NOTE: JDBC **result-set** capture is DIY on top of the proxy hook. |
| **BehaviorCapture / PerslisCapture** (binary) | Interpreter-as-recorder, PANDA event model | **PANDA** (guest-instruction-indexed events + periodic state checkpoints for seek) | The differentiated source-lost path; unique moat. |
| **GoldenMaster corpus store** | Approval/snapshot storage with scrubbers + deliberate review | **Verify** (multi-artifact snapshots) · **ApprovalTests** (scrubbers/reporters) · **insta** (review gate) | Durable `.approved` corpus, checked in; **approval must be costly & legible** (avoid the Jest `-u` rubber-stamp rot). |
| **InvariantExtractor** (the oracle for UNPROVABLE) | Property-based + metamorphic relations | **Hypothesis** (persistent example DB) · metamorphic relations (EMI/compiler MT) | Invariants are the part of the corpus that survives when exact output *legitimately* changes; the only oracle when there's no captured answer. |
| **InputSynthesizer** (fill coverage holes) | Coverage-guided fuzzing seeded by captured traffic + boundary catalog | **AFL++ / libFuzzer** (keep inputs hitting new edges; `afl-cmin`/`-merge` distill) · **BVA + equivalence partitioning** catalog | Defeats the happy-path trap by *manufacturing* the inputs traffic never sent. |
| **Corpus-strength meter** | **Coverage for holes + mutation score for strength** (incremental) | **Stryker / PITest / cargo-mutants** (slice-reachable only) · "Mind the Gap" | Coverage finds NOT-COVERED; a surviving mutant = COVERED-but-not-actually-pinned. Both, not either (council: "mutation not coverage" was too absolute). Scoped + sampled from day one; survivor taxonomy KILLED/ACTIONABLE/EQUIVALENT/OUT-OF-SCOPE. |
| **EquivalenceHarness** *(council-corrected)* | **Three separated concerns**, NOT a single noise floor | determinism check (oracle×2 = **must be 0**) · coverage/sample gate (N≥30/100–300) · candidate semantic-delta; Diffy learned-floor ONLY for deliberately-unsealed nondeterminism across **multiple real captures** | A sealed-deterministic oracle has no noise to learn by running twice — that's a capture-integrity check, not equivalence. Conflating them over-trusts "both agreed" (all 5 council). |
| **Canonicalizer / differ** | Two-tier: deterministic + learned | **RFC 8785 (JCS)** canonical JSON + declared volatile-field projection, THEN path-addressed structured diff → feed path-frequencies to Diffy filter | Deterministic filter for known noise; learned floor for the rest. Keep the ignore-list *minimal* (every stripped field is a permanent blind spot). |
| **Fuzz driver fitness** | Divergence-guided, not coverage-guided | **NEZHA δ-diversity** (prioritize inputs that produce new *relative* behaviors between oracle & candidate) | Hunts equivalence-breaking inputs directly. |
| **MigrationPlan** | Strangler sequencing (stateless/clean-boundary first, each step its own rollback) | **Strangler Fig** (Fowler; AWS/Azure/Thoughtworks-blessed) | The recognized safe shape a regulated architect already trusts. Not big-bang (70-79% failure). |
| **AdapterScaffold** | Façade + Anti-Corruption Layer + Branch-by-Abstraction | Fowler / Evans (DDD) | One swappable interface old & new both satisfy → equivalence can diff them; new code never inherits legacy quirks. |
| **ShadowRunner** | Production traffic mirroring (read-only, side-effect-gated) | **Envoy/Istio request mirroring** · **GoReplay** | Highest-fidelity corpus (real input distributions); grows GoldenCorpus. |
| **Canary** | Staged rollout, **auto-rollback on semantic diff-rate** (not just error rate) | **Argo Rollouts / Flagger** with the harness diff-rate as a custom metric | Rolls back on *behavioral divergence*, catching silent-wrong-answers metrics miss. |
| **SystemArchaeologist → SystemMap** | Statistics-first, LLM-second, per-item confidence | **DBAutoDoc** (statistical FK/PK then LLM naming) · **AgentModernize** rule schema `{desc, sourceLocation, inputs, outputs, confidence}` · **dependency-cruiser/ArchUnit/Structure101** DSM | LLM never *invents* an edge the data doesn't support; every inferred FK/rule is confidence-scored and source-bound. Never migrate on an unverified edge. |
| **Durable supervision (stages 6-8)** *(council-corrected)* | **Extend kist's OWN ledger** with journal-and-skip pattern (NOT Restate) + OTP supervision + sagas | kist checkpoints+signoff-ledger + idempotency-key per (step,input,tool-ver) + workflow-version pin + artifact-addressed outputs + per-step compensation · **OTP one-for-one** + restart cap · worktree-discard = free compensation | External durable-execution engine = dependency trap unless distributed exec is near-term (it's not). Adopt the *pattern*, not the dependency (5/5 council). |
| **Formal equivalence** | Reserve for small pure kernels only | **UC-KLEE / ARDiff** (SMT/Z3) | Total proof where tractable (a parser, a tax formula); does NOT scale to a whole service — don't design as if it will. |

---

## The four-state honesty contract, now mechanized

**Gate 0 — capture integrity (council-added, runs first):** replay the oracle twice on every case; the two runs MUST be byte-identical after canonicalization. Any divergence means the capture/sealing is broken (unsealed clock, RNG, socket, ordering, thread schedule) → the whole slice is **CAPTURE-FAILED**, emit no equivalence verdict. This gate is also the early-warning for the #1 real-world first failure.

Then each `EquivalenceReport` row is exactly one of — with its producing mechanism:

- **EQUIVALENT** — candidate matches oracle after canonicalization, on a path with sufficient samples (N≥100–300 common paths). Strongest tier (formal proof) only for small pure kernels via UC-KLEE.
- **NOT-EQUIVALENT** — an unexplained semantic delta between candidate and oracle (outside any deliberately-unsealed, learned-tolerated field). A real regression.
- **NOT-COVERED** — a legacy branch/path with zero or below-threshold corpus coverage (from the coverage map) or a surviving mutant with no killing case. Unverified — surfaced, never hidden.
- **UNPROVABLE** — a genuinely nondeterministic field with no stable canonical projection, a synthesized input with no oracle, or a low-confidence archaeology inference. Fall back to invariants/metamorphic relations or a generated differential constraint-test; if none resolve it, label it and move the risk into the open — never fake a green, never silently stall on a human.

**The headline number is the honest weakest link (coverage % + mutation score), never the green count.** "If it only says passed, it is dangerous."

---

## Refined build sequence

**L0 — "Harness shakedown" (spike, PROTOTYPE) — proves the PLUMBING, not modernization.**
- Target: a **stateless pure transform** (a parser / pricing-tax calculator / batch file transform) — cheapest oracle, strongest proof. Explicitly labeled a harness shakedown: it validates capture → canonicalize → diff → mutation → 4-state report, and NOTHING about state/DB/side-effects (council: calling it a modernization proof is the false-confidence trap).
- Minimum of each: capture (harness OR Perslis) → golden-master (`.approved` w/ scrubbers) → coverage + incremental mutation score → generate port → **Gate 0 determinism check (oracle×2 must be 0)** then candidate differential diff → 4-state EvidenceReport → promotion. Byte-equivalence over a *fuzzed* corpus, cut over behind an adapter, rollback proven.
- **Then the explicit slice-complexity ladder (state/DB is NOT "later"; S-rungs are a different axis from the L-phases):** **S0** pure transform (this) → **S1** stateless HTTP boundary → **S2** SQL read/write transaction → **S3** side-effecting workflow. Each rung adds exactly one hard capability (protocol capture, DB-state sealing, side-effect isolation) so a failure localizes to that rung.

**L1 — Harden the core as a real library (the hard core, per §component table).**
- `SystemOracle` (+ libfaketime-style sealing) with the **Gate-0 determinism check** built in, `BehaviorCapture` (2 backends), `GoldenMaster` + `InvariantExtractor` + `InputSynthesizer`, `EquivalenceHarness` (**three-concern verdict model** — determinism/coverage/candidate — + JCS canonicalizer + NEZHA-fitness fuzz; learned-floor only for deliberately-unsealed fields). Pure cores + injected execution, unit-tested to kist's standard, council-reviewed each increment. Coverage + incremental mutation as the corpus meter.

**L2 — CapabilityRegistry; wrap Perslis as the binary oracle (don't rebuild it).**
- Registry contract (name/purpose/in/out/determinism/invocation). Add PANDA-style instruction-indexed trace hooks to the *existing* interpreter. Re-scope Perslis to bounded oracle, freeze GUI coverage.

**L3 — Wire into the Captain + durable supervision + honest EvidenceReport.**
- Journal-and-skip over kist's OWN checkpoints/ledger (idempotency keys + workflow-version pin + artifact-addressed outputs — **no external engine**); OTP one-for-one restart + compensating sagas (worktree discard). SystemArchaeologist (statistics-first, confidence-scored; low-confidence inferences → UNPROVABLE bucket, never a silent stall). EvidenceReport as the audit artifact.

**L4 — Wedge 1 (the first commercial slice: stateless JSON CRUD REST + one SQL DB) + shadow/canary.**
- HTTP+JDBC capture, DB-state diffing, ShadowRunner (Envoy/GoReplay), Canary on diff-rate. (This is slice-tier S1→S2 running on the hardened L1 core.)

---

## Council-resolved answers (was: open questions)

1. **L0 slice** → pure transform, but **relabeled "harness shakedown"** (proves plumbing, not modernization) with the explicit S0→S3 ladder so state/DB is a named next rung, not "later." (Codex/Grok framing; defuses the DeepSeek/GPT/Gemini false-confidence concern.)
2. **Diffy noise floor** → **misapplied to a deterministic oracle** (all 5). Split into determinism-check (×2 must be 0) / coverage-sample-size (N≥30 smoke, 100–300 common, rare=NOT-COVERED) / candidate-equivalence. Learned floor only for deliberately-unsealed fields across multiple real captures.
3. **Mutation testing** → **incremental/scoped from day one** (slice-reachable code, prioritize money/date/state/SQL/validation), cheap continuous + expensive nightly, survivor taxonomy with evidence required for SURVIVED-EQUIVALENT. Coverage stays for NOT-COVERED.
4. **Restate** → **dropped**; extend kist's own ledger with idempotency-key + workflow-version + artifact-addressed outputs + per-step compensation (5/5).
5. **Human gate** → **risk-acceptance at cutover only**, not inside the loop — sound *because* the report emits UNPROVABLE/NOT-COVERED without stalling. Low-confidence archaeology → UNPROVABLE (or a generated differential constraint-test), never a silent human stall.
6. **First real-world failure** → **capture, not translation**: the oracle can't be made deterministic enough on a real abandoned system (unsealed sockets/batch jobs/external services/prod-only data/time-locale-config leakage). Gate 0 (determinism check) is precisely the early-warning that catches this and refuses to emit false evidence.

## Still genuinely open (for a later round)
- Fidelity-proof gate for PerslisCapture: what's the concrete conformance suite that certifies interpreter fidelity (instruction/syscall/FP-SIMD/memory-model/threading) before its evidence is trusted?
- The exact learned-tolerance mechanism for deliberately-unsealed fields (which fields, learned from how many real captures, at what confidence).
