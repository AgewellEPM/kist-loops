# Council of Minds — The Future of Agentic AI & kist's Next Level

**Date:** 2026-06-30
**Method:** Five frontier models were each given the *same grounded briefing* on kist/Mythos's real
current state and asked three questions: (1) where agentic AI is heading in 12–24 months, (2) what
kist is missing, (3) what to build next, ranked with effort/risk. Their raw responses are preserved
verbatim in [`council-2026-06-30/`](./council-2026-06-30/). This document is the synthesis, **graded
against kist's actual modules** so each recommendation says whether it's *extend-what-exists* or
*greenfield*.

**The council:** Gemini 2.5 Pro · Grok-4 · DeepSeek-reasoner · MiMo v2.5 Pro · GPT-4.1.

---

## Part I — Where agentic AI is heading (the field)

Five-way consensus, strongest first:

1. **The agent loop is now a commodity; governance/trust/attestation is the moat.** Four of five said
   this unprompted (MiMo, Grok, DeepSeek, OpenAI). "Plan→act→observe" is a weekend project with
   LangGraph/CrewAI. What won't commoditize: provenance, scoped authority, signed traces, audit. **This
   validates kist's core bet** — and means the window is real but closing (OpenAI/Anthropic will ship
   their own fleet governance within ~12 months — MiMo, DeepSeek).

2. **The context window is a dead end; persistent structured memory is the architectural shift.** All
   five. The winner is a hybrid **vector + knowledge-graph + fact store** with provenance, decay, and
   self-compaction — a living world model that learns *across* runs, not a bigger prompt. An open
   standard for agent memory (an "MCP for memory") is predicted within ~18 months (DeepSeek).

3. **Native tool-calling wins; the text-tool fallback dies within 12 months** (MiMo). kist's dual-path
   is correct but should weight native as primary, text as graceful degradation.

4. **Per-subtask model arbitrage becomes learned, not hardcoded** (DeepSeek, Gemini, MiMo, OpenAI).
   Route planning→one model, coding→another, search→another, local sandbox→Ollama. RL-tuned routers in
   production by mid-2026.

5. **The "agent OS" abstraction emerges** (MiMo): a scoped execution environment (filesystem + network
   policy + resource budget + identity) becomes the unit of deployment, like containers did. kist's
   sandbox is a proto-version — but must go portable (Linux seccomp-bpf/landlock, WASM) and
   network-aware (eBPF egress control, TEE binding).

6. **Standards fight is attestation + agent-to-agent *trust* negotiation, not model size** (Grok, all).
   MCP wins remote tools. A2A is contested — DeepSeek/OpenAI bullish on A2A negotiation protocols;
   **MiMo bets against A2A as a "Google vanity project."** The genuinely unstandardized, up-for-grabs
   piece: how one agent verifies another's scope/attestation/lease *before* delegating.

---

## Part II — What kist is missing (consensus, graded against real code)

Ruthless gaps, with how many minds flagged each and what kist *actually* has today:

| Gap | Minds | kist today | Verdict |
|---|---|---|---|
| **Cross-run learning memory / world model** | 5/5 | `Memory/LessonStore`, `CortexMemory`, `ProjectMemory`, `context_brain` (repo shards), `LoopCheckpoint` (run resume) | **Partial.** Has lessons + repo shards + resumable runs, but no *queryable, provenance-tagged* memory that records past plans/failures/user-corrections and retrieves them into future runs. The seeds exist — unify + make queryable. |
| **Human-facing fleet UI / live debugger / HITL** | 5/5 | terminal stream + fleet-observability layer + captain merge gate | **Real gap.** Observability is machine-level, not a steerable surface. No step-through, no plan-DAG view, no signed-artifact diff, no per-action approval for destructive ops, no one-key approve/reject. |
| **Fleet-level cost/budget enforcement + circuit breakers** | 4/5 | `BudgetLedger`, `UsageCost` exist | **Partial → quick win.** Accounting exists; it is *not enforced* at the planner/foreman as hard per-agent caps (tokens/cost/iterations) with auto-halt. Mostly policy wiring on top of the existing kill switch. |
| **Self-improvement loop (custom_tool → permanent skill)** | 4/5 | `custom_tool` (ephemeral), Agent Skills (static), Fleet signoff ledger | **Real gap — uniquely kist's to win.** No governed path to promote a proven custom_tool/strategy into a permanent, versioned, *signed* Agent Skill. |
| **Eval / regression-gating harness** | 4/5 | `Eval/EvalSuite`, `EvalRunner`, `TrajectoryAnalyzer/Recorder` | **Partial.** The harness scaffolding exists; it isn't wired to *gate* merges/skill-updates on score/scope/cost regression. Make agent claims falsifiable. |
| **Per-subtask model routing/ensemble** | 4/5 | `ModelRouter` fallback ids, provider catalog | **Partial.** Routing is fallback-only; no learned per-subtask selection. |
| **Inter-agent dependency scheduling (DAG)** | 3/5 | Fleet = disjoint-parallel worktrees | **Real gap.** Breaks for sequential handoff (agent B needs A's output). Needs declared inputs/outputs + scheduler + artifact passing. |
| **Linux sandbox portability** | 3/5 | Seatbelt (macOS) + ConfinedRoot (portable) + process-group | **Real gap.** Seatbelt is macOS-only → blocks CI/Docker/server, where ~80% of prod agent workloads live. Port to seccomp-bpf + landlock. |
| **MCP *server* hosting (not just client)** | 1/5 (high-leverage) | MCP client + A2A cards | **Network-effect gap.** Expose kist's tools as an MCP endpoint → every MCP-capable IDE becomes a consumer. Turns a tool into infrastructure. |

> Note: MiMo/OpenAI flagged "no durable state/crash recovery" — **partially wrong**, `LoopCheckpoint`
> already gives resumable runs. The real gap there is cross-run *learning* memory (row 1), not run resume.

---

## Part III — The Council Roadmap (ranked, grounded)

Ordered by (consensus × leverage × moat-fit), with effort/risk and the concrete kist move.

### Tier 1 — do first (compounding + quick wins)

1. **Persistent World Model — generalize `LessonStore`/`CortexMemory` into a queryable, provenance-tagged
   memory.** `[L, risk M]` `5/5`
   Vector + lightweight graph + fact store with decay/compaction. Instrument the loop to read/write it
   each turn; record plans, failures, user corrections with provenance. **This is the highest-leverage
   move all five named** — it turns kist from stateless executions into a learning system and is the
   substrate for self-improvement. *kist already has the seeds; the work is unify + query + wire-in.*

2. **Fleet Cost Engine — enforce `BudgetLedger`/`UsageCost` as hard caps.** `[S, risk L]` `4/5`
   Per-agent token/cost/iteration budgets, checked at dispatch, enforced by killing worktrees that
   exceed them; surface in observability. **Few hundred lines on top of the existing kill switch;
   eliminates the #1 production objection (a rogue agent looping $50).** Quick win.

3. **Regression-Gating Eval Harness — wire `Eval/EvalSuite` into the merge/skill gate.** `[M, risk L/H]` `4/5`
   A task suite that scores trace quality, scope adherence, artifact correctness, and cost, and *blocks*
   merges or skill updates on regression. **Makes every other improvement measurable** and AgentForge
   claims falsifiable. (Risk is in authoring tasks that survive model changes.)

### Tier 2 — the differentiators (lean into the moat)

4. **Skill-Forge — governed self-improvement: `custom_tool` → signed, versioned Agent Skill.** `[M, risk M]` `4/5`
   A "Skill Pull Request": an agent promotes a proven custom_tool/strategy; the foreman verifies it
   against the eval harness and *signs* it into the permanent skill library. **This is the move only
   kist can make well** — it fuses the just-shipped Skills with the Fleet signoff ledger into
   governance-gated compounding capability. Pairs with a **versioned skill manifest** (entry condition +
   procedure + verification predicate) so new agents inherit a growing, attested library (Grok #5, OpenAI #2).

5. **Captain Cockpit — interactive fleet UI / step-through debugger / HITL.** `[M–L, risk M]` `5/5`
   Render the existing ledger/lease/signoff event stream as a live plan-DAG with signed-artifact diffs,
   one-key approve/reject, lease-violation inspection, and **per-action approval for destructive ops**
   (delete / sensitive-path write / network). Strongest UX-axis consensus. *Plumbing over existing
   ledger data — start in the TUI, web later.*

6. **Per-subtask Model Router — extend `ModelRouter` to learned selection.** `[S→M, risk L]` `4/5`
   Map subtask type (plan/code/search/vision) → ranked capable models; heuristics first, learned from
   execution logs later. Plays directly to kist's provider breadth.

### Tier 3 — platform reach (unlock new deployment surfaces)

7. **Linux Sandbox Portability — seccomp-bpf + landlock parity for ConfinedRoot/Seatbelt.** `[M, risk M]` `3/5`
   Required to run in CI/Docker/servers. Without it, the governance pitch is macOS-bound.

8. **Agent DAG Scheduler — inter-agent dependencies + artifact handoff.** `[L, risk M]` `3/5`
   Agents declare inputs/outputs; a scheduler orders them, passes artifacts, detects cycles. Turns the
   fleet from embarrassingly-parallel into general workflow orchestration. (Redesigns foreman merge logic.)

9. **MCP Server Hosting — expose kist's tools as an MCP endpoint.** `[M, risk M]` `1/5, high-leverage`
   The network-effect play: every MCP-capable IDE/agent becomes a kist consumer. Infrastructure, not a tool.

### Frontier (high-risk / high-reward, later)
Network-level sandboxing (eBPF egress, TEE binding) · agent-to-agent trust-negotiation protocol (the
unstandardized standard) · portable agent identity + reputation · multimodal cross-context reasoning ·
RL/meta-learned self-improvement on session logs.

---

## Part IV — Dissents & singular insights worth keeping

- **MiMo:** bet *against* A2A ("Google vanity project"); the durable bet is agent-to-agent *trust*
  negotiation, which nobody has standardized. Also the sharpest framing: *"governance moat is real but
  eroding — you have a window, use it."*
- **DeepSeek:** formal correctness proofs (Lean-style) + agentic verification loops for infra changes;
  a memory open-standard from an Anthropic/OpenAI/HF consortium within 18 months.
- **Grok:** the compounding architecture is the one that *refuses invalid state before it reaches disk* —
  reframes everything as extending claim-reconciliation + the HMAC ledger, not new subsystems.
- **Gemini:** the "agent microservice" economy — agents *procure* services from specialized peers at
  runtime with capability negotiation and token billing.
- **OpenAI:** portable, cryptographically-attested agent **identity + reputation** across fleets;
  reusable workflow/artifact templates as an onboarding accelerant.

---

## Bottom line

The council is unanimous on the thesis kist already bet on: **governance + trust + sandbox + provider
breadth is the moat, and the agent loop is commodity.** kist is ~12–18 months ahead there — but the gap
the field is racing to close is **cross-run memory** and the *human-facing* governance surface, both of
which kist has the seeds for and neither of which it has finished.

The decision-ready sequence: **(1) persistent world model → (2) enforce cost caps → (3) regression-gating
eval → (4) Skill-Forge → (5) Captain Cockpit.** The first three are mostly *extend-what-exists*; (4) and
(5) are where kist turns its unique governance machinery into a durable, compounding lead before the
incumbents ship their own.
