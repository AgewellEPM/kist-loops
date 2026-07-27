# Captain System — Roadmap (industry standard → gaps → task list)

> Companion to `CAPTAIN_SYSTEM_SPEC.md`. Built from 6 parallel industry-research passes
> (multi-agent isolation, build provenance, LLM routing, merge/promotion, eval integrity,
> orchestration/memory/simulation/research). Every task names what it revives/replaces.

## The two findings that shape everything

1. **The `./test.sh` keystone.** `Foreman.realRunTests` hardcodes `./test.sh`, which doesn't exist on this Xcode/SPM repo → the ENTIRE verify-and-sign layer is **inert** (nil → unreachable green). Three separate research passes independently concluded: **nothing else matters until the verifier actually runs.** It's the cheapest, highest-leverage fix and a hard dependency for the merge queue, held-out eval, drift signal, and dry-run.

2. **Most of the "middle tier" is reviving code you already own.** The Ed25519 promotion gate, the held-out `RewardHackingGuard`, and the combined-tree integration verifier are **built + tested + dead**. The Seatbelt/bwrap sandbox exists on the security branch. This isn't greenfield — it's wiring.

---

## Industry standard vs. us, per layer

### Isolation / collision-prevention — **we're AT/AHEAD of standard on partitioning, BELOW on sandbox + merge**
- **Standard:** worktree-per-agent (Claude Code, Cursor, Copilot) for collision; **containers/microVMs** (OpenHands=Docker, SWE-agent=Docker, Devin=Firecracker) for untrusted code; **merge queues** (GitHub/Mergify/Graphite) that re-test the *combined* tree before main.
- **Us:** disjoint write-set leases (stronger than most tools — overlapping non-empty lease is structurally unreachable) + worktree isolation. **Missing: kernel sandbox** (worktree ≠ security; a hijacked agent can `rm -rf`/exfiltrate) and **combined-tree merge queue** (two green agents can break main together — the exact failure the AgenticFlict research documents).
- Sources: OpenHands Docker sandbox, Northflank "sandbox AI agents" (Firecracker/gVisor), GitHub Merge Queue, Mergify parallel checks, CodeCRDT (arXiv 2510.18893).

### Build trust / provenance — **real defense, wrong crypto primitive, unwired top tier**
- **Standard:** SLSA levels + in-toto/DSSE attestation format + Sigstore (cosign/Fulcio/Rekor) **signature-based, identity-bound** provenance + transparency log; enforced at deploy (GitHub Artifact Attestations, Kyverno/OPA). AI-specific: TEE remote attestation, tamper-evident agent logs.
- **Us:** `GroundedVerdict` (private init — unforgeable mint) + **HMAC** ForgeSeal + hash chain + ClaimReconciler + CIIntegrityGuard = genuinely strong tamper-evidence, BUT **HMAC = shared secret** (the verifier can forge; no non-repudiation → the same-user planted-key hole). The **Ed25519 signature gate already exists** in the repo — it's the dead promotion tier.
- Sources: slsa.dev, in-toto, docs.sigstore.dev, GitHub Artifact Attestations, Attestable Audits (arXiv 2506.23706).

### LLM routing / model assignment — **smart engine, but fleet-only + vendor-biased + no cost objective**
- **Standard:** learned routers (RouteLLM, NotDiamond, Martian) predicting per-model quality against an **explicit cost/quality/latency objective**; **cascades** (FrugalGPT, up to 98% cost cut); **online bandits** (LinUCB/Thompson); **capability HARD-gate** before scoring; benchmark-driven priors (Artificial Analysis/LMArena), not vendor loyalty.
- **Us:** real per-role scoring + a real learning store (evidence-not-authority, boost-only) — but **fleet-only** (interactive chat uses a dumb 3-rule router), priors are a **hardcoded deepseek/mimo table**, **zero cost/latency term**, capability is a soft bonus not a gate, no cascade/bandit.
- Sources: RouteLLM (arXiv 2406.18665), FrugalGPT (2305.05176), semantic-router, OpenRouter.

### Merge / promotion / delivery — **partial merge gate, dead promotion, no progressive delivery**
- **Standard:** branch protection/rulesets → **merge queue (combined-tree re-test, eject culprit)** → policy-as-code admission (OPA/Kyverno) → **progressive delivery** (canary/flags/auto-rollback, Argo Rollouts/Flagger/LaunchDarkly). Agent platforms land via the same PR gate.
- **Us:** signed-branch merge into a **manual integration branch (never main)** with off-lease refusal — but **no combined-tree re-test**, the **promotion-to-main gate is dead code**, and **no progressive delivery** (no flags/canary/rollback). Main is safe only because nothing auto-writes it.
- Sources: GitHub merge queue, Mergify, Graphite stack-aware queue, Argo Rollouts, LaunchDarkly.

### Eval integrity / reward-hacking / drift — **strong crude-forgery defense, dead sophisticated defense, neutered drift**
- **Standard:** held-out/hidden tests (SWE-bench Pro private set — overfitting alarm), capped+randomized tests, **mutation testing** (≥80% on new AI code, differential per-diff), property/differential testing, **independent external world-signal** (not the agent's own tests), trajectory monitoring (cut hacked-rate 28%→0.6%), LLM-judge kept advisory.
- **Us:** deterministic `SymbolicCaptain` + ClaimReconciler + CIIntegrityGuard genuinely stop fake-done/hallucination/harness-sabotage (matches the Anthropic `sys.exit(0)` attack class) — BUT the **held-out `RewardHackingGuard` is dead**, the **drift detector is neutered** (fed by the same local test exit it should independently confirm), and no test-quality (mutation) gate.
- Sources: Anthropic reward-hacking→misalignment (2025), SWE-bench Pro (2509.16941), "Do Coding Agents Deceive Us?" (2606.07379), Stryker, Evidently, The Verification Horizon (2606.26300).

### Orchestration / memory / simulation / research — **scaffolding vs. executed systems**
- **Standard:** executed state machines (LangGraph typed-state graphs, Temporal durable execution), planning patterns (ReAct/Reflexion/LATS); **decision-driving memory** (Letta/MemGPT tiered, Zep temporal graph, Generative-Agents recency×importance×relevance + reflection); **real simulation** (LLM-world-model + MCTS rollouts, or sandbox execution); **live research agents** (Deep Research, GPT-Researcher — decompose→search→cite).
- **Us:** 38-stage "pipeline" = **prompt text, not a machine**; "probabilistic simulation" = **FNV hash ±6, zero trials**; "strategic intelligence" = **hardcoded competitor checklist**; org-learning = **1743-line monolith, ~80% record-and-render**. The one real lever is advisory prompt injection.
- Sources: LangGraph/Temporal, Generative Agents (2304.03442), LLM-MCTS, GPT-Researcher.

---

## Consolidated task list (deduplicated, sequenced)

Effort: **S** ≤1d · **M** 2–4d · **L** 1–2wk. Each names the code it **revives/replaces**.

### P0 — the keystone, biggest gaps, cheap integrity wins

| ID | Task | Why | Effort | Revives/Replaces |
|---|---|---|---|---|
| **C1** | **Fix the test runner — kill `./test.sh`.** Pluggable `TestRunner` protocol, auto-detect Xcode scheme / SPM / test.sh / npm from `ProjectSnapshot`; **fail closed** if none resolves. | KEYSTONE. The whole verify-and-sign layer is inert on this repo; C5/C6/C13/C14 all depend on a real signal. | S | `Foreman.realRunTests` (inert) |
| **C2** | **Delete/relabel fake-intelligence.** Remove the FNV "probabilistic simulation" scoring, 3 dead strategy stages, the hardcoded "strategic intelligence" checklist, and dead org-learning code. **Stop labeling heuristics as simulation/strategic/probabilistic** in user-facing text. | Highest-integrity move — negative-value scaffolding manufactures false confidence. | S | `CaptainSimulationLab.materialize`, dead strategy stages, `StrategicIntelligencePlanner` label |
| **C3** | **Fix `--no-memory` side-effect leak.** Enforcer accepts `noMemory` but never reads it → still writes board/specialists/disk. | Real correctness bug. | S | `CaptainSimulationEnforcer.preflight` |
| **C4** | **Wire interactive turns through `ModelAssignmentEngine`** — unify the 3× task taxonomy into one `TaskProfiler` first, add a **capability HARD gate** (drop models lacking required vision/tools/context before scoring). | Closes the #1 disconnect: the path you use all day runs the dumb router while the smart engine sits idle. | M | `AutoModelRouter` (interactive), `ModelAssignmentEngine` |
| **C5** | **Combined-tree merge queue.** After signed branches assemble, re-run the **full real suite on the combined tree**; eject the branch that turns it red; only the green batch integrates. | The single biggest correctness gap — two green-in-isolation agents can break main together. | M | dead `FleetIntegrationVerifier`; needs C1 |
| **C6** | **Wire held-out `RewardHackingGuard` + give drift a real independent world-signal.** Split tests into visible/held-out; run held-out post-signoff; feed `WorldFacts` from a source structurally distinct from the structural-rule test exit (type-enforce the independence). | The sophisticated fake-done (pass seen tests, fail unseen) is currently uncaught; drift never fires. | M | dead `RewardHackingGuard`, neutered drift proxy; needs C1 |
| **C7** | **Wire the kernel sandbox into fleet command execution.** Connect the existing Seatbelt (macOS) / bubblewrap (Linux) sandbox to agent-run commands; default-on for `--auto`. | Biggest security gap vs. Devin/OpenHands — worktree ≠ isolation; a hijacked agent has full host access. | M | Seatbelt/bwrap sandbox (built on security branch) |

### P1 — crypto root, correctness holes, make the real machine/memory real

| ID | Task | Why | Effort | Revives/Replaces |
|---|---|---|---|---|
| **C8** | **Wire OR delete the Ed25519 promotion gate.** Recommended: wire `FleetPromotionGate`/`CaptainGate` as the *only* main-promotion path (trusted `integrationBuildID` = HEAD SHA, persist replay nonces, fail-closed). Never auto-arm the main write without Luke's say-so. | Built-tested-dead = false confidence + attack surface. Make promotion *impossible* without the gate. | M | dead `CaptainGate`/`FleetPromotionGate`/`PromotionPipeline` |
| **C9** | **Move root-of-trust HMAC → Ed25519 signatures.** Sign each signoff/ledger head with an Ed25519 private key (reuse the repo's existing Curve25519 `AttestationVerifier`); separate signing identity (agent) from promoting identity. Dual-write one release, then drop HMAC. | HMAC = shared secret → verifier can forge, no non-repudiation (the same-user planted-key hole). | M | `ForgeSeal` (HMAC) |
| **C10** | **Enforce leases harder.** Refuse off-lease work **at signoff** (not just merge); enforce leases on **single-agent** fleets (drop `if chosen.count > 1`); **fail-closed** on empty-`base`. | Three "silently unprotected" paths; off-lease work currently seals green. | M | `Foreman` GATE 3, `CaptainOrchestrator:136`, `GitIsolation` base fallback |
| **C11** | **Evidence-driven routing.** Replace the hardcoded vendor table with a **versioned benchmark-prior data file** the learning store adjusts; add a **cost/latency term** (single tunable knob, RouteLLM-style); allow **bounded demotion** (learning can penalize, gated stricter); make `CaptainLearningStore` **concurrency-safe**. | Vendor loyalty → evidence; add the missing cost objective; fix latent corruption. | M | `ModelAssignmentEngine.score` table, `CaptainLearningStore` |
| **C12** | **Split `OrganizationalLearningStore` (<1500) + merge into `CaptainLearningStore`.** Delete duplicated summarize + dead code; keep the one real path (advisory retrieval). | Violates the 1500-line hard-stop; ~80% dead weight. | M | `OrganizationalLearningStore` (1743 LOC) |
| **C13** | **Real dry-run trial.** Replace the FNV fantasy with an actual rollout: run the candidate plan in a throwaway worktree, read the `SymbolicCaptain`/test-harness outcome as the trial. Keep the fail-closed enforcer, feed it real signal. | Turn theater into a genuine what-if using infra you already have. | M | `CaptainSimulationLab` (post-C2); needs C1 |
| **C14** | **Differential mutation testing on changed lines.** ≥80%-mutants-killed on new/changed code, per-diff via the C1 runner; unkilled mutants → block/flag. | The strongest answer to "the agent's tests pass but assert nothing." | L | new; needs C1 |
| **C15** | **Executed strategy state machine.** Convert `CaptainStrategy` from prompt-string enum into a real typed-state + edges + cursor + checkpoint machine (LangGraph pattern; aligns with the planned `AgentCheckpoint`/`ReplanEngine`). | Make the 38-stage costume a real machine or drop it. | L | `CaptainStrategy` (prompt text) |
| **C16** | **Independent evaluator/rubric verifier.** A separate agent decomposes the goal into a checklist and scores the committed diff with **read-only observations only** (evidence, not judgment); advisory proxy rule, never overrides deterministic blockers. | A real correctness signal the agent didn't author. | L | new (extends ClaimReconciler contract) |

### P2 — advanced routing, delivery, research, scale, hardening

| ID | Task | Why | Effort |
|---|---|---|---|
| **C17** | Feature-flag / kill-switch + metric-gated post-promotion health check (canary analogue, auto-revert on breach). | No progressive delivery today; "merged ≠ live". | M |
| **C18** | Confidence-triggered **cascade** (cheap→strong) + **online contextual bandit** routing on the learning store's reward log. | Biggest cost lever (FrugalGPT) + real exploration. | L |
| **C19** | Externalize the promotion ladder as **policy-as-code** (declarative, versioned, Codable) the gate evaluates. | Auditable "what must be true to promote" (OPA/Kyverno pattern). | M |
| **C20** | Real **deep-research agent** (decompose→WebSearch/WebFetch→cite, GPT-Researcher pattern) OR delete the planner. | Live intelligence vs. a frozen checklist. | L |
| **C21** | Reflective memory upgrades: **recency×importance×relevance** scored retrieval, **reflection synthesis**, episodic/semantic split, actually-invoked decay/rotation. | Generative-Agents blueprint; memory that *decides*, not just renders. | L |
| **C22** | Transparency log / external anchor for the signoff ledger (Rekor-analogue: signed periodic checkpoints to a protected ref). | Monitorability the local hash chain lacks. | M |
| **C23** | Parallel merge queues by scope + per-agent resource/egress quotas (once C7 container tier exists). | Scale + blast-radius bound. | L |
| **C24** | **TEE / attested-execution spike (PROTOTYPE).** Run the verifier in an attested environment (SEV-SNP/TDX). Scope as a spike to decide if the threat model warrants it. | Verification currently trusts the host. | L |
| **C25** | Hardening bundle: trajectory/shortcut-behavior monitor, canary/contamination tripwire for held-out tests, LLM-judge bias guards (order-randomization + panel diversity), property-based tests for trust invariants. | Long-tail eval-integrity + judge reliability. | M |

---

## Recommended sequencing

**Sprint 1 (integrity + keystone, mostly S):** C1 → C2 → C3 → C4. Cheap, high-integrity, and C1 unblocks the rest. After this, the verifier actually runs, the interactive turn is smart, and nothing is mislabeled as "simulation/intelligence."

**Sprint 2 (close the real gaps, P0 remainder):** C5 (merge queue) · C6 (held-out + drift) · C7 (sandbox floor). These three are the biggest security/correctness wins and all revive existing code.

**Sprint 3 (crypto + correctness holes):** C8 (wire/delete promotion) · C9 (Ed25519 root) · C10 (lease enforcement) · C11 (evidence routing) · C12 (split the monolith).

**Sprint 4+ (make the top third real):** C13 (real dry-run) · C15 (real state machine) · C14/C16 (test-quality + independent verifier) · then P2 as capacity allows.

**Cross-cutting invariant to preserve on every task:** advisory/proxy signals may only make a gate *stricter, never mint trust* — the "evidence not authority" contract that already makes `ClaimReconciler`/`SymbolicCaptain` sound, and that the LLM-judge research independently validates.

---

# v2 — Council revisions (6-model review)

Reviewed by Codex, DeepSeek, GPT, MiMo, Grok (Gemini punted). Fact settled by grep:
the Ed25519 promotion tier + CryptoKit crypto **do exist** (`CaptainGate`,
`FleetPromotionGate`, `PromotionAttestation`/`AttestationVerifier`, `CouncilPromotionJudge`,
`RewardHackingGuard`) — DeepSeek's "never built" claim was a bad grep. So C8 is a WIRE task.

## Strong consensus — corrections to v1
1. **C1 is NOT "THE keystone" — reframe.** It unblocks only the test-signal tasks (C5/C6/C13/C14).
   It does NOT unblock C4, C7, C8, C10, C11, C12. Overstated. (all 5 reviewers)
2. **C1 effort S→M**, and **scope to `swift test` FIRST** (this is an SPM repo); Xcode/xcodebuild
   auto-detect is a fast-follow, not day one. (Codex, DeepSeek, GPT, Grok)
3. **Highest-ROI is C10 (integrity) and C4 (daily impact), not C1.** Do BOTH in Sprint 1.
   - **C10** — closes 3 real trust holes (off-lease seals green, single-agent lease bypass,
     empty-base fail-open), surgical, independent of everything. (Codex + DeepSeek = #1)
   - **C4** — the interactive turn is used ~100× more than fleet; wiring it to the existing smart
     engine is the biggest user-visible win. (Grok = #1)
4. **C9 is architecturally WRONG — CUT/merge into C8.** HMAC (internal builder seal) and Ed25519
   (external attestation) are TWO INTENTIONAL TIERS; don't collapse them. The correct task is
   "enforce external Ed25519 **at promotion time**" — which IS C8. (Grok's catch, confirmed by grep)
5. **CUT/defer the platform-scale P2s to backlog:** C15 (state machine — "most over-rated"),
   C18 (bandits), C20 (research agent), C21 (reflective memory), C23 (parallel queues), C24 (TEE).
   Over-engineering while the core loop is inert. (Codex, DeepSeek, MiMo, Grok)
6. **Effort re-estimates:** C1 S→M · C4 M→L · C5 M→L · C6 M→L (split) · C7 M→L (cross-platform) ·
   C14 stays L (optimistic).
7. **C2 needs an EXACT deletion list**, not a blanket "delete dead code" — a wrong deletion breaks
   prompt assembly and the whole Captain stops. Enumerate precisely before deleting. (DeepSeek)
8. **C6's "independent world-signal" is hand-waved** — no second oracle exists today. The task must
   DEFINE a real external signal (external CI run / git-history verification / differential run) or
   drop the independence claim. (Grok, DeepSeek)

## Missing categories — NEW tasks
| ID | Task | Why | Effort |
|---|---|---|---|
| **C26** | **Observability for the new gates** — metrics, audit view, machine-readable failure reasons, false-positive debugging for C5/C6/C8/C10. | Adding blockers without visibility = undebuggable false positives. | M |
| **C27** | **Cost controls** — per-run/per-agent budget ceiling, runaway-loop kill condition, cost attribution for fleet runs. | No spend cap today (one council review here cost $1.06). | M |
| **C28** | **Acceptance criteria per C-task** — each task ships with a deterministic "done means" check + a before/after invariant. | v1 has "why"+effort but no definition-of-done. | S |
| **C29** | **Negative/adversarial tests for trust invariants** — prove BLOCKED: off-lease edit, harness mutation, replayed nonce, broken hash chain, empty base, single-agent off-lease, sandbox escape. | The gates are only real if tested to refuse. | M |
| **C30** | **Source-control hygiene** — stale worktree cleanup, branch TTL, failed-agent GC, disk-growth bound. | Fleet mode leaks worktrees/branches/disk fast. | S |
| **C31** | **Shared-state atomicity** — file-lock/atomic writes across ledger, board, JSONL memories, promotion nonces (not just CaptainLearningStore). | Multi-agent systems fail at shared-state boundaries. | M |

## Rejected feedback
- Grok: "C8's never-auto-arm-without-Luke contradicts autonomy → make it opt-in override." **REJECTED** —
  never auto-arming the fleet without Luke's explicit say-so is a hard standing rule. Keep the human gate.

## Revised Sprint 1 (post-council)
**C10 (lease enforcement) + C4 (interactive routing) + C1 (swift-test-first, M) + C3 (--no-memory) +
C2 (with an exact deletion list) + minimal C7 (sandbox for unsafe exec).**
Rationale: lead with the two highest-ROI items (trust hole + daily impact), both independent of C1;
keep C1 but scoped to SPM; C2 only after enumerating exact deletions.
