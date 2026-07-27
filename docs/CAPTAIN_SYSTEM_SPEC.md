# Captain System — Full Spec (where it is right now)

> Snapshot of **uncommitted** work in `kist-loops` (branch `feat/kist-flawless-loops`).
> ~10,000 lines across ~35 files. Read line-by-line by 7 parallel reader passes.
> Labels use the honest tier: what the code ACTUALLY is, not what it's named.

---

## 0. The one fact that reframes everything

There are **two model-selection systems**, and they are NOT the same:

| Path | Who chooses the model | Intelligence |
|---|---|---|
| **Interactive chat turn** | `AutoModelRouter` (`Kist/AutoModelRouter.swift`) | Dumb 3-rule keyword heuristic. Default = **stay on current model**. No project data, no learning. |
| **`--fleet` multi-agent** | `ModelAssignmentEngine.assign` (`AgentCore/CaptainIntelligence.swift:190`) | Real: scores every keyed provider per role using `ProjectSnapshot` + learned outcomes. |

**The smart Captain (project-data → best-model-per-job → learn from results) runs ONLY in the fleet path.** Every ordinary chat turn gets the dumb router. That is the central disconnect (KistRunner:214–302 interactive vs 1174–1281 fleet).

---

## 1. Maturity map (brutal, per subsystem)

| Subsystem | What it claims | What it IS | Tier |
|---|---|---|---|
| Fleet collision-prevention (leases + worktrees) | agents never write over each other | **Real, structurally enforced** | PILOT |
| Signoff trust chain (GroundedVerdict + ForgeSeal + hash chain) | unforgeable "done" | **Real, type-enforced, tamper-evident** | PILOT |
| Claim/CI guards (ClaimReconciler, CIIntegrityGuard) | catch fake "done" / harness sabotage | **Real** for crude forgeries | PILOT |
| Model assignment (ModelAssignmentEngine + CaptainLearning) | best model per job from data | **Real but fleet-only**; interactive uses dumb router | PROTOTYPE→PILOT |
| Promotion tier (CaptainGate + PromotionPipeline + FleetPromotionGate) | council + Ed25519 before main | **DEAD CODE — zero production callers** | UNWIRED |
| Reward-hacking guard (held-out eval) | catch "pass visible tests, fail intent" | **DEAD CODE — never called by Foreman** | UNWIRED |
| Drift detector ("world unconfirmed") | flag builds the world hasn't confirmed | **Neutered** — fed by the same local test exit | DECORATIVE |
| Strategy pipeline (CaptainStrategy 38 stages) | 26/36-stage execution model | **Not executed** — enum → prompt text | SCAFFOLDING |
| Simulation lab ("probabilistic trials") | sandbox simulation + risk | **No trials** — FNV hash ±6 on hardcoded constants | THEATER |
| Strategic/Dashboard planners | strategic intelligence | Canned competitor lists + keyword routers | SCAFFOLDING |
| Organizational learning store (1743 lines) | org gets better daily | **~80% record-and-render**; one advisory prompt inject | PROTOTYPE (monolith) |

---

## 2. Model assignment intelligence — `AgentCore/CaptainIntelligence.swift` + `CaptainLearning.swift`

**`ProjectSnapshot.capture(repo:registry:)`** (CaptainIntelligence.swift:47): gathers tracked files, manifests, test entrypoints, languages (top 6), `git status --porcelain` changed files, and **keyed-only** provider candidates with capabilities. Fed to the planner + assignment engine. Fail-soft on git errors.

**`ModelAssignmentEngine.assign(subtasks:snapshot:defaultRoles:learning:)`** (:191): per subtask →
1. `profile(for:)` (:262) keyword-classifies the task (research/vision/coding/reasoning/verification; default `["coding"]`).
2. `choose` each role (planner/coder/critic-avoiding-coder/worker) via `score()`.
3. `score()` (:306) = `40 base (keyed) + defaultProvider +4 / avoid −8 + context/100k (≤12) + nativeTools +5 + structuredOutput +4 + reasoning +12 + vision +18 + research +16 + fast worker±... + learning.scoreBoost` then a **hardcoded per-role vendor preference table** (:324–337, e.g. coder favors deepseek/mimo).
4. Fail-closed: no keyed providers → user's team (`defaultRoles`, :217). Confidence clamped 0.45–0.95.

**`CaptainLearningStore`** (CaptainLearning.swift:170): append-only JSONL at `.kist/captain-learning.jsonl` (ring buffer 5000). `record()` from fleet-signoff / bench / eval. `assignmentContext()` → `summarize()` → per-(role,provider,tag,lang) `CaptainLearningSummary`.
- **Promotion gate** (`CaptainLearningSummary.promoted`, :113): `samples>=3 && successRate>=0.67 && toolFailures<=max(1,samples/2)`. Sparse data is inert ("shadow").
- **`scoreBoost`** (:115): always **≥0** — learning can boost, never penalize. This is the honest "evidence not authority" contract, and it holds.

**Wiring:** `assign` called only at KistRunner:1202 (fleet). `ProjectSnapshot.capture` at 722(bench)/772(eval)/1174(fleet). Learning read only at 1178–1179 (fleet). **Interactive = `AutoModelRouter` (214–302).**

**Gaps:** worker role scored as coder when `!prefersResearch` (collapses heterogeneity); no HARD capability gate (a blind model can be assigned a screenshot task if it scores highest); `toolFailures` semantics differ across record sources; task taxonomy duplicated 3× (`profile`, `inferTaskTags`, `AutoModelRouter.looksLikeReasoning`); `ModelAssignmentDecision.legacy` dead.

---

## 3. Fleet orchestration + collision-prevention — `CaptainOrchestrator` + `FleetScopeValidator` + `Foreman` + `GitIsolation` + `Baton`

**Pipeline (KistRunner:1171–1281):** goal → `FleetPlanner.plan` (planner-vendor JSON, tolerant parse) → `FleetScopeValidator.validate` → `ModelAssignmentEngine.assign` → `CaptainOrchestrator.launchFleet` (worktree/agent) → `FleetSupervisor.supervise` → `joinSignedBranches` (never main).

**Disjoint leases (FleetScopeValidator.swift):**
- Pass 1 drop+canonicalize: `isCanonicalGrammar` accepts ONLY exact path or `<dir>/*` (:91); `isReal` refuses new top-level dirs + empty prefixes (:143); `canonicalScope` expands a dir to `[dir, dir/*]`.
- Pass 2 overlap: `overlaps()` = path-**component** prefix test (:153); a colliding pair clears **BOTH** steps to `[]`. Result: **an overlapping non-empty lease is unreachable.**

**Worktree isolation (GitIsolation.swift:32):** captures `base` SHA, branch `mythos/auto-<slug>-<epoch>-<uniq8>`, `git worktree add -b`. UUID suffix prevents same-epoch collision; failure → `launched:false`, never edits main.

**Lease enforcement (Foreman.swift):** `outOfScopePaths` (:341) = committed changed paths not covered by any CANONICAL lease glob (via `FleetMatcher` — the SAME matcher the validator uses). **Record-only at inspect** (GATE 3): an off-lease write still seals a `.green` signoff; refusal happens **downstream** at `FleetSupervisor.joinSignedBranches` (:323, `outOfScopeCount==0`). Belt: `leaseRequired` (GATE 0) blocks empty-scope multi-agent cells.

**Baton (Baton.swift):** 8-state forge-proof lifecycle; `canTransition` is the sole legality source; `advanced()` the only mutator (illegal → nil). Persisted atomically per store.

**Verdict:** collision-prevention **works** (disjoint leases + isolation). Weak points: (1) off-lease work still earns a green signoff — refusal is at merge, not signoff; (2) single-agent fleets have zero lease enforcement (`if chosen.count > 1`, CaptainOrchestrator:136); (3) empty-`base` fallback widens the diff instead of failing closed; (4) `Foreman.realRunTests` hardcodes `./test.sh` → **inert on this repo's actual Xcode build**.

---

## 4. Trust chain — `FleetSignoffLedger` + `ForgeSeal` + `GroundedVerdict` + `ClaimReconciler` + `CIIntegrityGuard` + `SymbolicCaptain`

**Unforgeable green:** `GroundedVerdict` has a **private init** (GroundedVerdict.swift:47); the only `.code` mint is `fromCode` (internal, runs `SymbolicCaptain.judge`); `FleetSignoffLedger.record` admits only `isAdmissibleCodeGreen` (:251). A "tests pass!" string collapses to `.driftFlagged`/`.blocked` and never seals.

**Tamper-evidence:** each entry = HMAC-SHA256 `ForgeSeal` (per-install 0600 key) + SHA-256 hash chain. `verifyChain()` finds the first break; `entries` returns `[]` on ANY break → nothing merges. Belt + suspenders.

**SymbolicCaptain (deterministic judge):** structural rules see **only BuildFacts** (type-enforced — `BuildFlag` has no world case), proxy rules see the world. Precedence: blocked > driftFlagged > green. 6 structural blockers (monolith ≤1500, done→tests/diff/codex, stepcap≠done, run-complete).

**ClaimReconciler:** catches claimed-files-not-committed (suffix match), symbols-not-present-as-whole-tokens-on-added-lines (comments/strings stripped), `tests_claim_false`. Reads **committed-only** artifacts. Only ever makes the gate stricter.

**CIIntegrityGuard:** catches test deletion, `XCTSkip`/`.only`/`|| true`/`exit 0`, harness mutation. New-file exempt from the blanket harness flag.

**Verdict:** **stops crude fake-done, narrated hallucination, harness sabotage** — a real, type-enforced defense. BUT "done" = "the agent's own committed tests pass + claims match the diff", NOT "the change is correct." Two gaps below.

---

## 5. Promotion tier — **BUILT, TESTED, DEAD**

`CaptainGate.decide` (council blessed AND Ed25519 captain-promoted, fail-closed), `PromotionPipeline`, `FleetPromotionGate` (5-gate ladder A–E: internal-ready, attestation present, verify valid, build-id bound, replay-unconsumed), `CouncilPromotionJudge` (4 LLM lenses, `tally` ship⟺`yes>=threshold && no==0`).

**Zero production callers.** Grep of `Sources/**` = only `PromotionPipeline.swift` internal + tests. `runFleet` ends at a **manual integration branch** ("promote it yourself — Mythos never writes main"). The entire "council + attestation before main" apparatus provides **zero runtime protection today**. Main is protected only because nothing writes it automatically.

Documented residual: `integrationBuildID` provenance unenforced; ForgeSeal same-user planted-key attack uncovered (its mitigation IS this dead tier).

---

## 6. Strategy pipeline — `AgentCore/CaptainStrategy.swift` (1136) + `SymbolicWorkflowCompiler.swift`

**`CaptainStrategyStage`** = **38 enum cases** (prompt said "26"; `operatingOrder` renders 35; 3 cases `.understand`/`.determineExpertise`/`.review` are **dead**). The enum's only behavior is `.title`. There is **no state machine, no dispatch, no cursor** — `orderedStages` is a compile-time constant assigned to every plan and consumed only as `map(\.title).joined(" -> ")` injected into LLM prompts (PromptCompiler:103/166, KistRunner:270/387/595).

Real gating that exists is **keyword-driven and stage-agnostic** (`CaptainDecisionCards.build`). `understandingAssessment` = invented magic-number heuristic (`confidence >= 80`) dressed as an engine. `CaptainStrategyPlan` is **not Codable / never persisted** — recomputed every turn; its "memory architecture" disk paths are aspirational strings this file never touches.

**`SymbolicWorkflowStore.run`** is the only real state mutation: seeds ≤7 gate `PlanTask`s (`.kist/learning/symbolic-workflows.jsonl`), marks the first in-progress. **No enforced ordering** — all gates seeded at once, no dependency edges.

**Verdict:** advisory prompt-context generator wearing a state-machine costume.

---

## 7. Simulation + planners — `CaptainSimulationLab`/`Enforcer` + `StrategicIntelligencePlanner` + `DashboardResearchPlanner`

**"Probabilistic trials" = theater.** `CaptainSimulationLab.materialize` (:415): `success = baseSuccess + FNV_hash(objective)%13−6`; `passedTrials = round(trials*success/100)`. **Zero Monte Carlo, zero sandbox, zero randomness** — `seed()` is FNV-1a. Every score is a hardcoded constant nudged by a deterministic ±6 hash. Real simulation is deferred to seeded specialist TODO tasks.

**`CaptainSimulationEnforcer`** IS a real launch gate (KistRunner:1156 fleet, 1457 plan-execute): `.fleet` is always high-risk; blocks launch on high/critical + failed gate; fails **closed**. This part is genuinely wired.

**Planners** (`StrategicIntelligencePlanner`, `DashboardResearchPlanner`): pure keyword routers over **hardcoded competitor/paper lists** (Claude Code, Cursor, OpenHands, MCP, DGM, SWE-bench…). No web, no model call. Wired into `/evolve`, dashboard, post-turn recording.

**Real bug:** `--no-memory` is a **dead parameter** — `CaptainSimulationEnforcer.preflight` accepts `noMemory` but never reads it, so `kist --fleet --no-memory` still writes the board, specialists, and disk memory (finding #1, a genuine side-effect leak). Also `passesGate`'s second clause is algebraically redundant.

---

## 8. Organizational learning — `Kist/UX/OrganizationalLearningStore.swift` (1743 lines)

Five knowledge kinds under `.kist/learning/`: per-turn capsules, knowledge-debt ledger, promoted org rules, industry-intelligence/evolution JSONL, and a re-summary of model-performance evidence.

**The headline:** this is **~80% record-and-render**. Its ONE live influence is `retrievalContext()` → advisory **prompt-text injection** (KistREPL:216→852/1115/1139/1260). The actual model assignment **bypasses it entirely** and reads `CaptainLearningStore` directly (KistRunner:1179). Org rules (`/teach`) and knowledge debt never gate or block anything. `makeCapsule` "learning" is canned boolean-driven boilerplate.

**Violates Luke's own rules:** 1743 lines > the 1500 HARD-STOP; ≥8 responsibilities in one file. Duplicates `CaptainLearningStore.summarize`. Dead code: `strategicIntelligenceAgenda`/`evolutionProposal`/`StrategicAgendaItem` (no caller), `knowledge-index.jsonl` read-but-never-written, `.retired`/decay never invoked. Unbounded JSONLs (no rotation).

---

## 9. Consolidated BUG / GAP list (ranked)

1. **[HIGH] Promotion tier is dead code.** Council + Ed25519 gate never called; `--fleet` stops at a manual branch. The "nothing reaches main without council+attestation" guarantee provides zero runtime protection.
2. **[HIGH] Reward-hacking guard is dead code.** The held-out-eval defense (the sophisticated "fake done") is never wired into Foreman. Pass-the-visible-tests-fail-intent is uncaught.
3. **[HIGH] Drift detector neutered.** `WorldFacts.fromMeasuredTest` feeds the "external world signal" from the SAME local test exit the structural rules already used → `.driftFlagged` never fires in the fleet path. The "verified outside the loop" promise is unmet.
4. **[MED] `--no-memory` ignored** by the simulation enforcer → still mutates board/specialists/disk.
5. **[MED] `done_needs_codex` bypassed by default** (`codexReviewed=false`) → the review-gate structural invariant isn't enforced on fleet agents.
6. **[MED] Off-lease work still seals green.** Enforcement is deferred to the merge gate; a signed branch asserts green for out-of-scope changes. Safety depends on the merge gate being the sole promotion path.
7. **[MED] Foreman hardcodes `./test.sh`** → the whole verify-and-sign layer is inert on this repo's actual Xcode/SPM build; missing script → nil → unreachable green.
8. **[LOW] Single-agent fleets have no lease enforcement** (`if chosen.count > 1`).
9. **[LOW] Interactive path gets none of the learning/assignment** — only the dumb router.
10. **[LOW] Empty-`base` measurement widens the diff** (lease/monolith gates don't fail closed like claim reconciliation does).
11. **[LOW] CaptainLearningStore not concurrency-safe** (load-modify-write, no lock) — fine today (single-writer), latent for parallel recording.
12. **[LOW] Simulation verdict can flip on an arbitrary objective-hash** (±6 near a threshold).

## 10. Consolidated DEAD / duplicated code

- `RewardHackingGuard` (whole file), `CaptainGate`/`PromotionPipeline`/`FleetPromotionGate` (no prod caller), `ModelAssignmentDecision.legacy`, `strategicIntelligenceAgenda`/`evolutionProposal`/`StrategicAgendaItem`, `knowledge-index.jsonl` (read-never-written), `.retired`/decay paths, `validEntries()` alias, 3 dead strategy stages.
- **Task taxonomy defined 3×** (`profile`, `inferTaskTags`, `looksLikeReasoning`) — drift risk.
- **Learning summary logic defined 2×** (`CaptainLearningStore.summarize` vs `captainLearningRetrievalSummaries`).
- 4 near-identical dedup helpers; identical `selfHealTaskExists`/`simulationTaskExists`.

---

## 11. Honest verdict

**The bottom third is excellent and real.** The fleet's collision-prevention (disjoint leases + worktree isolation) and the trust chain (private-init GroundedVerdict + HMAC seal + hash chain + claim/CI guards) are genuinely well-engineered, type-enforced, deterministic, fail-closed, and tested. That is the hard part, and it's done.

**The middle is real but incomplete or disconnected.** Model assignment is smart but fleet-only; the interactive turn — the thing you use all day — runs a dumb heuristic. The promotion tier and reward-hacking guard are built and tested but **never called**. The drift detector is decorative.

**The top third is scaffolding wearing production costumes.** The 38-stage "strategy pipeline" is prompt text, not a machine. The "probabilistic simulation" runs no trials. "Strategic intelligence" is a hardcoded competitor checklist. The 1743-line learning store mostly records and renders, and violates the repo's own size rule.

**None of it is committed.** ~48 files, ~10k lines, sweepable.

### What to do (priority order)
1. **Commit it to branches now** — it's a landmine uncommitted.
2. **Wire the interactive turn through `ModelAssignmentEngine`** (or explicitly decide the dumb router is correct for chat) — close the #1 disconnect.
3. **Either wire or delete the dead tiers** — promotion gate + reward-hacking guard are negative value as unwired code (false confidence + attack surface).
4. **Fix `--no-memory`** (real correctness bug) and the `./test.sh` assumption (the verify layer is inert on this repo).
5. **Stop calling heuristics "simulation/probabilistic/strategic intelligence"** in user-facing text — label them as the deterministic checklists they are.
6. **Split `OrganizationalLearningStore`** (past the hard-stop) before adding to it.
