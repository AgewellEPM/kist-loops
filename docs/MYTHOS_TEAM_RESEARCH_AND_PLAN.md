# Mythos — Heterogeneous AI Team: Research Synthesis & Action Plan

**Date:** 2026-06-26 · **Status:** strategy doc (research-grounded) · **Owner:** Luke

> **The vision.** A unified, open-source, terminal-first AI wrapper — like Claude Code — except
> instead of one model (Claude) spinning up copies of *itself* as sub-agents, Mythos orchestrates a
> **team of DIFFERENT AI vendors** as first-class teammates in one shared loop: Claude plans, GPT
> codes, Gemini reviews, a local model does the cheap grunt work. Map → analyze → propose → plan →
> build off what it discovered → summon agents → learn. All in the terminal.

---

## 0. How this was researched (and the honesty caveats)

Four parallel live-web research agents (June 2026), disjoint scopes: **GitHub/OSS landscape**,
**HackerNews sentiment**, **Reddit practitioners**, **architecture & technique literature**.

**Caveats that constrain confidence — do not launder these away:**
- **Reddit was environmentally blocked** (WebSearch rejects reddit.com; fetch + mirrors 403'd). That
  agent's Reddit-attributed signal is **secondhand** (aggregators paraphrasing Reddit) plus
  *verified* GitHub-issue / Cursor-forum primary sources. **Open task: re-run with Reddit API auth.**
- **Star counts and benchmark numbers are unreliable** across 2026 listicles (AI-generated SEO
  blogspam; sources contradict each other). Treat all adoption/benchmark figures as order-of-magnitude.
- Some cited papers carry forward-dated arXiv IDs; load-bearing claims rest on primary engineering
  sources (Anthropic, Cognition, LangChain), not those.

---

## 1. The landscape & the white space (GitHub agent)

The market splits into three groups, **each structurally unable to be "a team of different vendors":**

| Group | Examples | What they do | The structural flaw |
|---|---|---|---|
| **Clone-armies** | claude-flow/Ruflo, OpenCode subagents, Goose | Excellent orchestration machinery (memory, swarm, plan-graph) | Spin up copies of **one** vendor. claude-flow is the most advanced *and single-vendor by design* — the exact pattern we reject |
| **Subprocess wrappers** | Mysti, "Let Them Talk", agent-of-empires, OpenCastle, ORCH | DO mix Claude+GPT+Gemini… | …by shelling out to each vendor's **own CLI as an opaque subprocess**. No shared reasoning state, ~3× tokens, no benchmarks, brittle tmux/worktree glue |
| **Libraries** | LangGraph, CrewAI, AutoGen/AG2, OpenAI Agents SDK | Can mix vendors as first-class agents with real patterns | They're **SDKs you build an app with**, not a ready terminal product |

**Aider** is the proof-of-value: its architect/editor split (strong model plans, cheap model writes
diffs — can be cross-vendor) is **30–50% cheaper** and the clearest evidence that heterogeneous role
specialization *works* — but it's only two roles, no orchestration, no memory.

**Verdict: the quadrant "terminal-first, ready-to-use shell where DIFFERENT vendors are first-class
native teammates in ONE shared loop (not subprocessed), with a closed plan→execute loop and cross-run
memory" is genuinely unoccupied.** That is exactly Mythos's stated vision. Nobody owns it.

---

## 2. What the market validated — and what it warns (HN + Reddit)

**Validated demand (build with confidence):**
- **BYOK / no lock-in is table stakes and a wedge.** The Cursor BYOK-removal backlash + OpenCode's
  *un-disableable telemetry on local models* are gifts: a provably-local, OSS, BYOK-by-construction
  tool wins the privacy/anti-lock-in segment those tools alienated.
- **Local+cloud routing is a near-universal, concretely-described want.** Practitioners already
  hand-roll "route 60–80% routine work to a local/cheap model, escalate the hard 20% to frontier"
  (via LiteLLM / Claude-Code-Router glue). Mythos can make this first-class.
- **"No single model dominates"** is the consensus — people *already* mix Claude(plan)/GPT(code)/
  Gemini(context) by hand. We're productizing a hand-rolled pattern, not inventing demand.
- **Plan→inspect→approve→execute is the single most-cited success factor** ("plans are a must";
  Cline's Plan/Act is the cited gold standard). This maps to our biggest current gap.

**Warnings (the design must answer these, not wish them away):**
- **HN's center of gravity is skeptical of swarms.** Cognition's *Don't Build Multi-Agents* is the
  canonical reference. The four recurring objections: **(1) observability** ("you can't observe what
  20 agents are doing"), **(2) context/framing fragmentation** (worse across *different* vendors),
  **(3) inter-agent "verbose non-decisions",** **(4) silent race conditions on shared state.**
- **Multi-agent costs ~15× chat tokens** (Anthropic's own number). Extreme anecdotes ($916 / 339M
  tokens for one toy). Cost governance is not optional.
- **The single strong agent + great context engineering is the baseline to beat.** "Agents aren't a
  model problem, they're a tools/systems/process problem." Sell the team as an *optimization with
  verification*, **not** as inherently better.
- **Cross-run learning has almost no organic demand on HN/Reddit** — either an unmet need we define,
  or something users don't yet want. **Validate before betting the core loop on it.**

The reassuring part: Mythos's existing discipline (disjoint lease/scope-globs, signoff-ledger,
claim-vs-evidence reconciler, Fleet Cockpit) maps **almost 1:1** onto objections (1)(2)(4). The risk
is that heterogeneous models make framing-leak (2) *harder*, not easier.

---

## 3. Architecture consensus — what to build, what to resist (technique agent)

Both Anthropic ("do, carefully") and Cognition (evolved: "multiple agents contribute intelligence,
but **writes stay single-threaded**") now converge on the **same shape**:

- **Supervisor / hierarchical, with a strict single-writer invariant.** Exactly one agent holds the
  write lock on any artifact; everyone else is read-only or proposes diffs the writer applies.
  **Default to this. Do NOT build a free-for-all swarm or multi-writer blackboard** — that's the
  documented failure mode (Cognition's incoherent-merge example).
- **Parallelism should be read-heavy** (fan-out search/analysis = the safest multi-agent win);
  **writes serialized.**
- **Generator–verifier (debate/critique) is the one "multiple intelligences" pattern everyone
  agrees works** — give the verifier a *deliberately clean context* (combats context rot). This is
  the natural home for a *different vendor* (the cross-vendor critic).
- **Cross-vendor routing is the real, defensible moat** — *lean in here harder than on swarm.* But
  the pitfalls bite multi-vendor systems specifically: **context-handoff loss**, **tool-call format
  drift** (different vendors' JSON shapes; fidelity <80% = broken), **session non-sharing**. The
  documented fix: **hand off structured artifacts, not raw transcripts**, and **normalize tool I/O
  to one canonical schema.** Mythos's uniform text-protocol loop already de-risks format drift *by
  construction* — a genuine edge over LangGraph/CrewAI.
- **Memory = a *verified skill library* (Voyager), not transcript RAG.** Distill a *succeeded +
  verified* plan into a reusable skill indexed by NL description; gate every stored skill behind
  self-verification (un-verified memory is worse than none — caches mistakes). Long-horizon
  compounding asset; barely helps the first dozen runs. RAG-over-old-chats inherits lossy
  compression — keep it a thin, clearly-labeled experimental tier.

---

## 4. The agents/roles Mythos needs

Ship **four role ARCHETYPES, not a persona zoo.** "Role" must mean *different tools + different
context window + real parallelism* — if a proposed role shares tools and context with its parent,
it's a *phase*, keep it in one agent.

1. **Orchestrator / lead** — decomposes the task, emits the plan, spawns workers, synthesizes,
   decides done. The most load-bearing role. (→ natural fit: a strong planner model, e.g. Claude.)
2. **Read-only Worker** — parallel research/search/analysis. The **safest** multi-agent path; **build
   this first.** No write conflicts. (→ any model, route cheap where possible.)
3. **Critic / Reviewer** — generator–verifier loop, **read-only by design, clean context.** The
   highest-confidence multi-agent win and the natural home for a *different vendor* than the coder.
4. **Coder / Writer** — the single writer for a given artifact (single-writer invariant). (→ e.g.
   GPT for execution.) Plus a thin **deterministic utility role** (format/lint/cite) where useful.

**Vendor binding** is the differentiator: let the user (or a cost/capability router) bind a *specific
vendor* to each role — as **first-class agents in Mythos's own uniform loop**, NOT subprocessed
vendor CLIs (the thing every wrapper gets wrong).

---

## 5. Mythos gap analysis (current → target)

| Capability | Today | Target |
|---|---|---|
| Provider-agnostic loop (text+native, capability routing) | ✅ done (P1) | keep |
| Tool I/O normalized across vendors | ⚠️ text-protocol gives it by construction; native paths differ | one canonical schema at the boundary |
| Plan → execute | ❌ plan-mode proposes **prose**; loop re-derives | **typed plan-DAG**, scheduler, replan node, verify gate |
| Multi-agent | ⚠️ one-level `spawn_agent`, no result-bubbling | supervisor + single-writer + parallel read fan-out + critic gate |
| Vendor-per-role binding | ❌ | first-class role→vendor binding |
| Cross-run learning | ❌ (engine is amnesiac) | verified skill library (opt-in, gated) |
| Cost governance | ❌ | hard budget ceiling, per-agent token caps |
| Observability | partial (Fleet Cockpit infra exists GUI-side) | terminal cockpit + per-agent live state |
| Proof team > single | ❌ | benchmark harness (team vs single, $ + quality) |

---

## 6. THE ACTION PLAN (phased, ordered by confidence × leverage)

The research **reorders** the naive "plan → learning → orchestration." Lead with the two
highest-confidence wedges; make multi-agent supervised and *measured*; learning last.

### Phase 1 — Close the plan→execute loop *(highest-confidence wedge; foundation for everything)*
- Plan-mode emits a **typed, executable artifact**: a DAG of `{id, tool, args, dependsOn[],
  scopeGlobs, ownerRole}` steps — not prose.
- A **scheduler** runs ready steps (start sequential; add LLMCompiler-style parallel dispatch once
  stable). Adopt **ReWOO-style variable refs** (`#E2`) so steps chain without re-invoking the planner.
- A **mandatory replan node** after each step/failure (`Execute → Re-plan → Execute`) + a final
  **verify gate** (does the result satisfy the goal?) before "done."
- Approval freezes the plan as the execution spine — no re-derivation. The DAG **doubles as the
  multi-agent work-assignment graph** (disjoint subtrees → parallel workers), so planning and
  orchestration share one artifact.

### Phase 2 — Cross-vendor role binding + normalized routing *(the moat)*
- **Canonical tool-I/O schema** at the boundary so a plan is provider-portable; track **tool-call
  fidelity per provider**, auto-failover/downgrade below ~80%.
- **Role→vendor binding**: bind a specific vendor to each archetype (Claude=plan, GPT=code,
  Gemini=critic, local=grunt) as native agents in the one loop.
- **Hand off structured artifacts, never raw transcripts** (dodge lossy compression + session
  non-sharing). Minimize cross-vendor hops — route *once per phase*, don't ping-pong.
- Extend the existing capability+cost router with a RouteLLM-style difficulty signal.

### Phase 3 — Supervised multi-agent *(the differentiator — but boxed)*
- Supervisor + **strict single-writer invariant** (one writer per artifact; others read-only/diff).
- **Read-heavy parallel fan-out** (workers); **writes serialized.** Extend the existing one-level
  `spawn_agent` + add **result-bubbling**. Reuse the lease/scope-glob isolation already designed.
- **Generator–verifier critic gate** (clean-context reviewer, ideally a *different* vendor) as a
  first-class, cheap-to-enable mode.
- **Resist the swarm / multi-writer blackboard.**

### Phase 4 — Verified skill library *(cross-run learning — opt-in, validate demand first)*
- On a plan-DAG that **succeeds + passes verify**, distill a reusable skill (code/structured),
  indexed by NL description; planner retrieves+composes on future tasks.
- **Gate every stored skill behind self-verification** (Voyager's 73% lesson; matches our
  no-fabrication discipline). Ship opt-in; measure plateau-avoidance, not instant lift.

### Cross-cutting (every phase)
- **Cost governance**: hard budget ceiling, per-agent token caps, "why am I spawning N agents" gate
  that surfaces the 15×-token reality before the user opts in.
- **Observability**: terminal cockpit + per-agent live state (the #1 multi-agent objection — DOA
  without it).
- **Benchmark harness**: prove *team vs single* on $ **and** quality. The market is "crowded with
  launches but starved of validated traction" — **winning = measuring, not asserting.**

---

## 7. THE RESEARCH PLAN (open questions to close before/with each phase)

1. **Re-run Reddit with API auth** — the one primary source we couldn't verify firsthand. Confirm the
   local+cloud routing workflows and BYOK sentiment with real threads.
2. **Validate cross-run-learning demand** — near-zero organic demand found. Interview/poll target
   users before investing in Phase 4. (It may be a "define the category" bet, not a "meet demand" one.)
3. **Quantify the heterogeneous-team premium** — does Claude-plan/GPT-code/Gemini-review *measurably*
   beat one strong model at equal/lower cost? Build the benchmark *early*; it's the whole pitch.
4. **Tool-call fidelity per vendor** — measure real-world JSON tool-format drift across providers on
   our schema; sets the auto-failover threshold.
5. **Context-handoff loss** — measure quality loss when handing structured artifacts vs raw
   transcripts across vendors; confirms the "structured handoff" design empirically.
6. **Deep-dive the reference implementations** — claude-flow's ReasoningBank/SQLite memory + Roo's
   Boomerang summary-back context isolation + OpenHands' typed event-stream bus. Steal the machinery.

---

## 8. Risk register (skeptic objection → our answer)

| Objection (from HN/Cognition) | Mythos's answer |
|---|---|
| "You can't observe what N agents do" | Terminal cockpit + per-agent live state + append-only signoff ledger |
| Context/framing fragmentation (worse across vendors) | Structured-artifact handoffs (not transcripts); route once per phase; single shared plan-DAG |
| Inter-agent "verbose non-decisions" | Supervisor with role clarity + veto; single-writer invariant; no peer negotiation |
| Silent race conditions on shared state | Disjoint lease/scope-globs (already designed) + single-writer lock |
| 15× token cost | Hard budget ceilings, per-agent caps, cheap-local routing for grunt work, opt-in cost gate |
| "Single strong agent is the baseline" | Sell team as *measured optimization*; ship the benchmark; default to one agent when the plan-DAG isn't parallelizable |
| Multi-agent is unproven ROI | Benchmark harness is a Phase-0 cross-cutting deliverable, not an afterthought |

---

## 9. Bottom line

The niche is **genuinely open**. The leaders are either mono-vendor clone-armies or fragile
subprocess wrappers. Mythos's edge: **the first unified provider-agnostic loop where different
vendors are native teammates** — backed by an executable plan-DAG, structured cross-vendor handoffs,
supervised single-writer orchestration, verified skill memory, and — critically — **benchmarks that
prove the team beats one model**. Lead with the plan→execute loop and cross-vendor routing (highest
confidence); make multi-agent supervised and measured; treat learning as an opt-in, demand-validated
bet. Resist the swarm. Win on reliability — the only metric that matters for a terminal coding tool.

---

### Sources
Consolidated from four research agents; full URL lists in the session transcript. Primary anchors:
Anthropic *multi-agent research system* & *subagents* engineering posts; Cognition *Don't Build
Multi-Agents* + *Multi-Agents: What's Actually Working*; LangChain *Plan-and-Execute* + LangGraph
supervisor/swarm docs; OpenCode/Aider/Goose/OpenHands/Roo primary docs+repos; RouteLLM (ICLR'25);
Voyager (skill library). Adoption/benchmark numbers are order-of-magnitude (see §0 caveats).
