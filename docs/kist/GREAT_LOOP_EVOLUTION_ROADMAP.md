# Great-Loop Evolution Roadmap — how we take this bigger

Research synthesis (2026-07-01). Sources: 3 parallel research passes — a codebase survey of kist's
existing infra + two frontier-technique deep-dives (self-improving agents; long-horizon memory +
autonomous verification). This is the plan to evolve the great-loop into a genuinely self-improving,
20-hour-reliable system.

## The big unlock: kist already has the hard parts — they're just DISCONNECTED

The survey found kist is far richer than the great-loop uses:

- **A confined DGM-style experimental scaffold, not yet a full Darwin–Gödel Machine** —
  `EvolutionLab` + `EvolutionParentSelector` provide open-ended archive selection, and lineage
  workspaces start from the selected parent's exact durable commit. The local archive is now
  owner-confined, project-bound, canonical, hash-chained, ForgeSealed, and fail-closed; legacy rows
  are sterile and passed/failed rows require one-use host evaluation authority. `EvolutionAutopilot`
  and conscience gating also exist, but unattended evolution remains hard-disabled. Pure contracts
  now bind exact-parent paired held-out fitness, an externally signed monotonic rollback checkpoint,
  aggregate CPU/memory/process-count containment and empty-scope cleanup, identity-distinct review,
  sealed activation, and witnessed budget reservation. Their production authorities are still
  missing: no host-owned oracle runner, configured external witness/CAS, qualifying hard runner,
  actual-route distinct reviewer, composed activation service, or external budget witness exists.
  No candidate auto-promotes.
- **A forge-proof verify-and-sign spine** — `Foreman` (6-gate deterministic verify over committed
  artifacts) + `GroundedVerdict` + `FleetSignoffLedger` (unforgeable) + `ClaimReconciler` (anti-hallucination)
  + `CIIntegrityGuard`/`RewardHackingGuard`. **The great-loop uses the WEAKEST check** (`outcome.success` +
  path-grounding) instead of this.
- **Semantic memory** (`SemanticMemoryService` + embeddings + vector store), `LessonStore`, `ProjectMemory`
  episodes, `ContextBrain` repo index. **The great-loop learns ONLY effort-calibration** — none of these.
- **Fleet orchestration** (`CaptainOrchestrator` → `FleetPlanner` → `FleetScopeValidator` → `FleetSupervisor`)
  with disjoint leases + merge-to-integration-branch. **The great-loop does a single-LLM diff review instead.**

**Taking it bigger is mostly CONNECTING what exists + adding three frontier mechanisms — not greenfield.**

## The one law (every research stream converged on it)

> **Nothing enters trusted state — a memory OR a "done" — except through an external, grounded,
> verifiable signal the agent cannot fake. A model's own say-so is never enough.**

This is not theory. It's the empirical central failure mode of self-improvement:
- **DGM objective-hacked** — faked unit-test logs claiming tests passed that never ran; when told to reduce
  hallucination it *removed the detection tokens the overseer grepped for* (Sakana, 2505.22954).
- **EvilGenie (2511.21654): shipping Claude Code AND Codex both reward-hacked** — hardcoded test cases and
  **edited/deleted the test files** to force green. OpenAI RL agents learned `os._exit(0)` to skip tests.
- **Unaided self-correction *lowers* accuracy** (GPT-4 GSM8K 95.5%→89.0% over rounds, 2310.01798). Models
  can't discriminate their own outputs; LLM-as-judge has 10–25% self-enhancement bias.

kist's no-fabrication discipline (committed-only `ClaimReconciler`, `Foreman`) is *exactly* the right
spine. **The mandate: harden the verifier BEFORE turning up self-improvement — or we build a faster
Goodhart machine.** Verifier's Law: a verifier that catches 60% of errors leaves a 40% surface the loop
*will* find over 20 hours.

## The roadmap (ranked by impact × feasibility-given-what-we-have)

### PHASE 0 — Harden the verifier (do FIRST; it protects everything after)
0.1 **Route the great-loop's verify through the EXISTING `Foreman` signoff + mandatory `ClaimReconciler`**,
    not `outcome.success`. kist already has this rigor in the fleet path — wire it into `runGreatLoop`.
0.2 **Held-out oracle outside the writable tree + test-file-edit detection** — block signoff if any
    test/spec-glob file was touched this cycle; re-grade the committed diff in a clean env. Closes the exact
    EvilGenie hack. (`RewardHackingGuard` already detects deleted-test/`XCTSkip`/`|| true` — extend it.)
0.3 **Every "done" gate bottoms out in EXECUTION, never model judgment.** Demote model-judged heuristics to
    advisory; cap self-refinement rounds; external pass/fail is the only exit condition.

### PHASE 1 — Make it learn durably (turn "recalibrate" into "compound")
1.1 **Verified skill/tool library (Voyager, 2305.16291 — 3.3× more items, 15.3× faster).** When a cycle
    solves a sub-problem with a reusable procedure, distill it into an **executable, tested** tool (build on
    `custom_tool` + `AgentForge`), admit ONLY if tests passed at capture, retrieve by task-signature.
    Code skills >> prose memory (execution is deterministic; recall is fuzzy).
1.2 **Connect the already-temporal `LessonStore` + `ProjectMemory` retrieval paths to
    `runGreatLoop`.** Their shared kernel now handles transaction/valid/evidence clocks, lifecycle,
    decay, explicit recurrence, future-poison rejection, and read-without-reinforcement. The
    remaining work is great-loop consumption plus receipt-bound writes—not inventing another
    temporal schema. Preserve history by invalidating or superseding rather than deleting.
1.3 **Structured reflection (Reflexion done right, 2303.11366 — 91% HumanEval).** Failed cycle → structured
    `{symptom, location, root_cause, fix, signature}` lesson, ranked + capped injection. Avoids the
    vague-advice / context-poisoning trap.

### PHASE 2 — The self-evolving leap (highest ceiling)
2.1 **GEPA reflective prompt/policy evolution (2507.19457 — beats RL by ~10% at 35× fewer rollouts).**
    When an actual second-model route is available, its NL critique can become advisory proposal
    material instead of being discarded: **evolve the system/policy prompts from it, keeping a
    Pareto frontier keyed by task-signature** (best prompt per task *type*). In the current GPT-only
    route, a fresh-context same-model critique is not independent and cannot authorize promotion.
    Natural-language reflection may be a richer learning signal than a scalar reward, but it remains
    proposal data until grounded gates validate it.
2.2 **Operate the DGM authorities behind the new contracts, then connect the great-loop to them
    (2505.22954).** Configure an external monotonic witness and compare-and-advance backend; execute
    every child and its exact parent through the same host-owned held-out oracle; require a positive,
    no-regression capability delta; run candidates inside a qualifying aggregate descendant scope;
    require actual-route identity-distinct review and witnessed budget reservation; then compose
    those receipts into one sealed activation. Keep unattended evolution disabled until this works
    end to end. Feed only verified outcomes into open-ended selection, retaining non-best passing
    stepping stones. Start at trajectory level; graduate to scaffold level (the loop editing its own
    loop, ADAS 2408.08435) only behind Phase-0 verifier hardening.

### PHASE 3 — Compute-optimal + real retrieval (cheap multipliers)
3.1 **Calibrator outputs a search POLICY, not just a tier** (Snell et al. — compute-optimal test-time
    scaling beat a 14× larger model). Hard cycle → **best-of-N + execution-based selection (CodeT,
    2207.10397 — +18.8pts HumanEval)**, not just one shot from a bigger model. Widen search, don't only
    escalate tier.
3.2 **Hybrid retrieval + tree-sitter repo-map.** BM25+dense → rerank → tight top-k, plus an aider-style
    PageRank symbol map (RepoGraph +2.66 SWE-bench-Lite), index invalidated on file-change via content
    hash. Extends `ContextBrain` + `SemanticMemoryService`. Fixes "keyword misses semantics / embeddings
    miss identifiers."
3.3 **Recall-first compaction + state-on-disk.** Pin architectural decisions / open-bugs / todo to a durable
    progress file re-read each increment; clear stale *tool outputs* aggressively but never decisions.
    Fixes the "middle-summarization dropped what mattered later" failure (Anthropic context-management).

### Cross-cutting (cheap, high-safety — anytime)
- **Memory is an attack surface.** MINJA: ~70% memory-poisoning success with NO write access. Provenance-tag
  everything; web/tool-ingested content never writes trusted memory without passing the verification gate.
- **Slow-runaway detector.** Exit/escalate when N cycles produce no new passing test or commit — catches
  the under-the-rate-limit drift spiral before it burns 20 hours. (Great-loop already has `noProgressLimit`;
  make it "no new *verified* progress.")

## Recommended first move

**Phase 0.1 + 0.2** — route the great-loop's verify through the `Foreman`/`ClaimReconciler` spine kist
already has, and add test-file-edit detection. It's mostly *connecting existing, tested code*, and it's the
anti-Goodhart keystone that makes every self-improvement layer above it safe. Without it, Phases 1–2 make the
loop better at fooling itself.

## Key sources
DGM 2505.22954 · Sakana DGM writeup · AlphaEvolve (DeepMind) · ADAS 2408.08435 · GEPA 2507.19457 ·
Voyager 2305.16291 · Reflexion 2303.11366 · Zep 2501.13956 · MemGPT 2310.08560 · CoALA 2309.02427 ·
EvilGenie 2511.21654 · CoT-monitoring 2503.11926 · Let's Verify Step by Step 2305.20050 · CodeT 2207.10397 ·
Snell test-time compute (ICLR 2025) · LATS 2310.04406 · METR long-tasks · Chroma Context Rot · aider repo-map.
