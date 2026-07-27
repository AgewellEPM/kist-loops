# A+ Implementation Plan — Skills & Cost-Caps to Production-Grade

**Date:** 2026-06-30
**Goal:** take the two features shipped this session from the council's grades (Skills **B+/C**,
Cost-caps **C+/D+**) to **A+** — validated against 2026 industry standards and grounded in kist's
*actual* code surfaces (mapped, with real type/function names).

> **The leverage:** kist already owns ~70% of the primitives. Ed25519 attestation
> (`PromotionAttestation`/`AttestationVerifier`), `ForgeSeal` HMAC + hash-chain, `ToolRegistry.scoped(to:)`
> capability scoping, per-vendor dollar math (`CompetitiveBenchmark.estimateCost`), and per-span
> attribution (`AgentSpan`/`TraceRecorder`) all exist. Most of this plan is **wiring** them into the
> skills + budget paths, plus standard-compliant additions (`allowed-tools`, per-model pricing,
> atomic reserve).

## Research basis (what "A+" means, externally validated)

- **agentskills.io spec** already defines `allowed-tools` (`Bash(git:*) Read`-style capability scoping),
  `license`, `compatibility`, `metadata.version`, and the 3-tier progressive-disclosure budget
  (~100-token metadata / <5000-token body / on-demand resources). Our impl is already spec-aligned on
  naming/size/dedup — we're missing `allowed-tools` + signing. *Skills are standard-compliant; make
  them standard-complete.*
- **Skill supply-chain is an active 2026 crisis, not theory:** Snyk's ToxicSkills found prompt
  injection in **36%** of audited skills; a marketplace was poisoned with 1,184 malicious skills; CSA
  named "SKILL.md context poisoning" a new attack surface (hidden Unicode-Tag injection, behavioral
  payload masking, repo-level persistence). Responses: **Sigstore keyless signing, SLSA provenance/
  trust-scoring, NVIDIA Verified Agent Skills.** The council's #1 finding is the industry's #1 finding.
- **CSA-recommended runtime defenses** (our trust model maps 1:1): cryptographic signing + content-hash
  allow-lists; semantic/behavioral scanning + **Unicode-class filtering**; approval workflow ("treat
  skills like third-party PRs"); least-privilege capability scoping + egress control; runtime logging
  of tool/network/fs with anomaly flags.
- **Cost governance standard** (LiteLLM/Portkey/Helicone): denominate in **dollars** via per-model
  pricing; **reserve-before-spend** then reconcile actual; per-tenant quotas on token/rate/concurrency;
  tag spend at the edge for attribution (showback/chargeback); soft warnings + hard caps + automated
  fallback (cheaper model). Tokens are an *input*, not the budget.

*(Full sources + the brutal council review in `honest-review-2026-06-30/`; raw web findings cited at end.)*

---

## PART 1 — SKILLS → A+

Five council gaps: trust/signing, typed/scoped, activation (proactivity), scale (retrieval),
lifecycle (global/`/skills`/hot-reload/forge). Phased by security-ROI × effort.

### S1 — Capability scoping via `allowed-tools` (STANDARD-COMPLIANT) — `[S, security-critical]`
**What:** parse the spec's `allowed-tools` frontmatter into `Skill.allowedTools: [String]`; when a skill
is loaded, scope the agent's registry to it for the duration.
**kist surfaces:** add field + validation in `Skill.swift` (`parseFlatYAML` already handles frontmatter;
`validate()` adds the rule). Enforce via the existing **`ToolRegistry.scoped(to:)`** (intersection-only,
fail-closed — a forged allowlist can only *remove* tools). Thread the active skill's allowlist through
`ToolContext` (it already carries `skillLocations`/`skillTracker`; add `activeSkillTools`).
**Why A+:** least-privilege per skill, matching the spec + CSA guidance. A `web-research` skill can't be
tricked into `write_file`/`run_command`. **Tests:** a skill with `allowed-tools: read_file search_code`
cannot invoke `write_file` even if the model tries (per-site: scoped registry refuses).

### S2 — Integrity, provenance & signing — `[M, security-critical]`
**What:** every skill gets a content hash; trust tiers by signature. Builtins = trusted (shipped).
Project/registry skills = a **content-hash allow-list** (`.kist/skills-trust.json`) + optional
**Ed25519 publisher signature**. Verify *before* `markLoaded`.
**kist surfaces:** clone the **`PromotionAttestation`/`AttestationVerifier`** pattern verbatim
(`SkillApproval{name, contentHash, publisherKeyID, nonce}` → `SignedSkill` → `VerifiedSkill` with a
`fileprivate` init so only the verifier mints trust). Hash via `MythosCrypto.sha256`; internal seal via
`ForgeSeal.sign/verify`; canonical strings via `ForgeSeal.field`. Optional audit log = a
`FleetSignoffLedger` clone. **Enforcement chokepoint:** `ReadFileTool.readProjectSkill` →
verify-then-`markLoaded` (the map already shows this is the single trigger site).
**Why A+:** Sigstore/SLSA-equivalent provenance using crypto kist already ships. A poisoned skill in a
fleet subproject can't silently poison the planner — unverified ⇒ quarantined (S4). **Tests:** tampered
SKILL.md (hash mismatch) refused; unsigned project skill quarantined; valid signature loads.

### S3 — Semantic / static validation — `[S, security-high]`
**What:** at parse/validate, reject the documented injection classes.
**kist surfaces:** extend the existing control-char strip in `parseFlatYAML`/`stripScalar` to **reject
Unicode Tag chars (U+E0000–U+E007F)** (invisible-injection vector) and normalize; add a behavioral
scanner flagging known-bad patterns (env-var/secret exfil like `$ANTHROPIC_API_KEY` in a URL,
"ignore…safety/instructions", base64 blobs, network egress directives) → surfaces as a `SkillState`
warning and forces approval (S4). **Why A+:** matches Snyk/SkillProbe-style scanning + CSA Unicode
filtering. **Tests:** a SKILL.md with a U+E0000 hidden instruction → rejected; an exfil pattern →
flagged, not silently loaded.

### S4 — Trust tiers + approval workflow — `[M, security-high]`
**What:** three tiers — **trusted** (builtin/signed), **quarantined** (unsigned project skill, first
sight), **blocked** (failed scan/hash). Quarantined skills require explicit approval (the `RuntimeInteractor`
gate already exists) and run with a *restricted* `allowed-tools` default until approved. "Treat skills
like third-party PRs."
**kist surfaces:** `SkillManager.overriddenBuiltins` already flags shadowing — extend to a full
`trust: TrustTier` per skill; gate via the existing approval interactor + `ToolRegistry.scoped`. Persist
approvals (hash-pinned) in `.kist/skills-trust.json`. **Tests:** first-load of an unsigned skill prompts;
approved hash auto-loads next run; a *changed* hash re-quarantines.

### S5 — Activation + scale (kills the proactivity problem) — `[M–H]`
**What:** stop relying on model volition. Add **activation conditions** (glob/path/keyword triggers in
frontmatter `metadata` or a `when:` field) so relevant skills are *surfaced/auto-loaded*, not hoped-for;
add **retrieval** (keyword pre-filter → optional embedding rerank) so the Tier-1 menu stays small past
~30 skills; add **namespacing** (`org/skill`).
**kist surfaces:** `SkillManager.promptXML()` becomes task-aware (filter by trigger match against the
goal/changed files); a `SkillIndex` ranks by description keywords. **Why A+:** Claude Code/Cursor parity
(triggers + conditions) — the proactivity gap was a *mechanism* gap. **Tests:** 100 skills → menu stays
bounded; a file-pattern-triggered skill is offered for a matching task.

### S6 — Lifecycle: global dir, `/skills`, hot-reload — `[S–M]`
**What:** discover `~/.kist/skills` (global, after a reviewed read_file-confinement widening — its own
gate); a `/skills` REPL command (list/inspect/trust/why-skipped, surfacing `SkillState` + `overriddenBuiltins`
+ trust tier); file-watch hot-reload.
**kist surfaces:** `SkillDiscovery` gains a global source; `SkillManager` exposes a `/skills` view (the
data already exists in `states`/`overriddenBuiltins`/tracker). **Tests:** global skill discovered;
`/skills` shows trust + load status; editing a SKILL.md reloads without restart.

### S7 — Skill-Forge (the compounding loop) — `[M]`
**What:** promote a *proven* `custom_tool`/procedure into a permanent, **signed** Agent Skill — a
governed "skill PR" verified before it's trusted. This is roadmap #4, now fused with S2's signing.
**kist surfaces:** `custom_tool` output (`.kist/generated-tools/<n>/tool.py`) + a generated SKILL.md,
verified (S3 scan + a smoke run), then **signed** (S2) and written to `.kist/skills`. **Why A+:** session
intelligence compounds into an attestable library instead of dying at exit. **Tests:** a forged skill is
signed, re-discovered next run as trusted, and runs.

---

## PART 2 — COST-CAPS → A+ (circuit-breaker → governance)

Council gaps: tokens-only (no $), TOCTOU, uncapped council/research, no attribution, no soft-degrade,
no hierarchical/per-tool/wall-clock budgets.

### C1 — Dollar-denominated budgets — `[S–M]`
**What:** `--budget` accepts tokens *or* a `$`-cap; live cost computed per call from per-model pricing.
**kist surfaces:** pricing math already exists — `CompetitiveBenchmark.ProviderTokenPrice
{inputPerMillionUSD, outputPerMillionUSD}` + `estimateCost`. Move it from post-hoc to live: add
`pricePerMillion` to `AIModel` (`Models.swift`) *or* key the price book by model id; `BudgetLedger` gains
a `maxUSD` ceiling and a `spentUSD` accumulator fed at `recordLLMSpan`. **Why A+:** users govern in
dollars; multi-provider-aware (a 1M-token Gemini call ≠ Claude). **Tests:** `--budget $0.50` halts at the
dollar line across two providers with different rates.

### C2 — Atomic reserve-before-spend (closes the TOCTOU) — `[M]`
**What:** the validated industry pattern — `reserve(estTokens)->Bool` debits an estimate *before* the
call; `commit(actualTokens)` reconciles after. No two parallel agents can both pass then both overspend.
**kist surfaces:** extend the `BudgetLedger` actor with `reserve/commit` (its actor isolation gives the
serialization primitive — today `add`+`isExceeded` aren't atomic as a pair). Wire **both** accounting
chokepoints — `HeadlessAgentLoop.recordLLMSpan` *and* `PlanExecuteLoop` (line 83) — to reserve before the
stream and commit after. **Why A+:** hard cap under parallel fleet load, not a soft guideline. **Tests:**
N concurrent reservers can't exceed the cap (the test the council demanded).

### C3 — Cap the holes: council/research — `[S]`
**What:** inject a `BudgetLedger` into `AICouncil` and account every mind turn + synthesis.
**kist surfaces:** `AICouncil` holds a `TraceRecorder?` but **no `BudgetLedger`** (the map confirms 0
refs) — its `record(...)` records spans without `budget.add`. Add the ledger + a pre-call `isExceeded`
guard. **Why A+:** the highest-spend paths stop being exempt. **Tests:** `--council --budget` halts
mid-council.

### C4 — Attribution & observability — `[S–M]`
**What:** answer "which agent/tool/model/task spent what." Tag every span; add per-model + per-agent +
`$` rollups; a `/cost` command.
**kist surfaces:** `AgentSpan` already carries `vendor/model/role/tokens`; `TraceRecorder` already does
`tokensByVendor()`/`tokensByRole()`. Add per-model + per-agent + USD; expose `/cost`. **Why A+:** teams
can't manage what they can't measure. **Tests:** `/cost` breaks down a multi-agent run by model + agent + $.

### C5 — Soft-degrade ladder — `[M]`
**What:** budget *pressure* (spent/max) drives graceful degradation before the hard halt: 70% → trim
context tighter; 80% → skip optional research, prefer cheaper model for sub-tasks; 95% → refuse fleet
expansion; 100% → honest halt.
**kist surfaces:** `BudgetLedger.remaining()` exists but is unused by the loops; feed it into the
plan/replan decision and let `ContextWindowManager.forModel` accept a pressure factor (today it has no
pressure input). **Why A+:** finishes the task with reduced resources instead of dumping an error on the
80% already spent. **Tests:** at 80% the loop drops optional research; at 100% it halts.

### C6 — Hierarchical / per-tool / wall-clock budgets — `[M]`
**What:** a budget *tree* mirroring the delegation tree (each sub-agent gets an allocation from its
parent — no single greedy worker starves the rest); per-tool ceilings (e.g. ≤50 web_search); wall-clock
timeout; per-tenant/per-day quotas.
**kist surfaces:** the shared-ledger plumbing already threads through `SpawnAgentTool`/fleet — extend to
sub-allocations; per-tool counting at `ToolRegistry.execute`; wall-clock in the loop. **Why A+:**
multi-agent cost allocation is table-stakes (per the cost-governance research). **Tests:** a sub-agent
capped at 20% can't consume the parent's budget; a wall-clock timeout halts a stuck run.

---

## PART 3 — THE CROSS-CUT (the council's #1 miss): Skills ↔ Cost integration

Once S1 (`allowed-tools`) + C1 ($-cost) + C5 (pressure) exist, the integration is cheap and is the
through-line that makes both features matter:
- **Skills declare a cost profile** — a `metadata.cost_weight` (low/med/high) + the `allowed-tools` they
  use (already parsed in S1).
- **Budget-aware planning** — the planner reads remaining budget (C5) and a plan's skill cost profiles,
  and prefers a cheaper plan / refuses a high-cost skill under pressure ("budget low → skip the vision
  skill, summarize instead of full e2e").
- **Pressure-gated skills** — at high pressure, expensive skills drop out of the Tier-1 menu (S5 filter +
  C5 pressure). **Tests:** under 85% budget pressure, a `cost_weight: high` skill is withheld from the menu.

---

## Sequencing (ROI × risk) — recommended build order

| Sprint | Phases | Why first |
|---|---|---|
| **1 — Safety floor** | **S1** (allowed-tools) + **S3** (Unicode/static scan) + **C3** (cap council/research) | Highest security-ROI, lowest effort; closes the two active-exploit classes (capability over-reach, hidden injection) + the biggest cost hole. All standard-compliant. |
| **2 — Trust spine** | **S2** (signing/hash, reuse PromotionAttestation) + **S4** (trust tiers/approval) | The council's #1 gap; the industry's #1 gap. Reuses existing Ed25519/ForgeSeal. |
| **3 — Real cost governance** | **C1** ($) + **C2** (atomic reserve) + **C4** (attribution) | Tokens→dollars, kills the TOCTOU, makes spend measurable. Mostly wiring existing pricing/attribution. |
| **4 — Scale + UX** | **S5** (triggers/retrieval) + **S6** (global/`/skills`/hot-reload) + **C5** (soft-degrade) | Fixes proactivity + 30-skill ceiling; graceful degradation. |
| **5 — Compounding + integration** | **S7** (Skill-Forge, signed) + **C6** (hierarchical budgets) + **Cross-cut** (skills↔cost) | Turns the foundation into a compounding, self-governing system. |

**Each phase:** own worktree/branch → built → tested (per-site regression assertions) → adversarial
council + Codex gate → ff-merge. Nothing auto-arms; signing keys + trust decisions stay Luke's.

## Grade trajectory
- After Sprint 1–2: Skills **C → A-** (trust model + scoping + scan; standard-complete). 
- After Sprint 3: Cost-caps **D+ → A-** (dollars + atomic + attribution = governance, not circuit-breaker).
- After Sprint 4–5: both **→ A+** (scale, lifecycle, compounding, integrated).

## Web research sources
- agentskills.io specification (allowed-tools, progressive-disclosure budget) — https://agentskills.io/specification
- Claude Code Agent Skills (allowed-tools, disable-model-invocation, least-privilege) — https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
- CSA: SKILL.md Agent Context Poisoning (attack surface + mitigations) — https://labs.cloudsecurityalliance.org/research/csa-research-note-skill-md-agent-context-poisoning-20260506/
- Snyk ToxicSkills (36% prompt-injection in skills) — https://snyk.io/blog/toxicskills-malicious-ai-agent-skills-clawhub/
- Reserve-before-spend / token-budget layers — https://aisecuritygateway.ai/blog/llm-token-budget-strategies-for-agents
- LLM cost allocation/attribution (LiteLLM/Portkey/Helicone) — https://amnic.com/blogs/llm-cost-allocation-tools
- Per-tenant LLM cost attribution — https://particula.tech/blog/per-tenant-llm-cost-attribution-multi-tenant-saas
