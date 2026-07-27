# Mythos — Phase 3 Research, Cross-Compare & Revised Plan

**Date:** 2026-06-26 · **Status:** strategy doc (research-grounded, post-build) · Supersedes the
"next = worker fan-out" assumption in `MYTHOS_TEAM_RESEARCH_AND_PLAN.md`.

> Researched AFTER building Phase 1 (closed plan→execute loop) and Phase 2 (live 3-vendor team), so
> this cross-compares **what we actually shipped** against the frontier — four live-web agents:
> big-tech labs + interop protocols, the OSS landscape, HN/Reddit practitioners, and the
> engineering best-practices literature for the five unbuilt pieces.

---

## 0. The headline (the research overturned our next step)

We were about to build **Phase 3 = worker parallel fan-out / supervised multi-agent.** All four
research streams independently say **don't — build OBSERVABILITY + COST GOVERNANCE first.** The
evidence is unusually consistent:

- **Practitioners (HN):** parallel fan-out is the **least unmet** need — "Toxic Flow," "3–5 agents is
  the sweet spot; beyond that you spend more merging than you save," "I never use sub-agents."
  **Observability is the #1 felt pain** ("you can't trace which agent's context was polluted"); **cost
  is the #1 thing that gets tools BANNED** (Microsoft pulled Claude Code licenses over $500–2000/eng/mo).
- **Best-practices:** multi-agent is **~15× chat tokens** (Anthropic's own number). "Build the meter
  and the trace first, or the multi-vendor loop is undebuggable and unaffordable."
- **Big-tech:** observability is "the biggest credibility gap for a team-of-models product — you can't
  debug a 4-vendor loop blind." Cost governance + tracing **before** fan-out.
- **OSS:** we trail on exactly cost-gov / observability / memory; clean license-compatible donors exist.

**Revised order: make the loop LEGIBLE and BOUNDED before making it WIDER.** Fan-out comes after, and
becomes *safe* once it's observable and cost-capped (you can't fan out 15× cost blind).

---

## 1. Where we are vs where we need to be

| Capability | Built? | Evidence | Industry expectation |
|---|---|---|---|
| Provider-agnostic loop (native+text, capability routing) | ✅ live | OpenAI+Gemini+DeepSeek live | table stakes |
| **Typed validated plan-DAG + replan + LLM goal-critic gate** | ✅ live | 293 tests, live runs | **we LEAD — nobody pairs both** |
| **Cross-vendor native roles in one loop (planner/coder/critic)** | ✅ live | 3-vendor haiku/limerick | **we LEAD — unique in OSS** |
| Hooks / plan-mode / slash-commands / resume / MCP client | ✅ | tested | parity |
| Observability / tracing | ❌ | none | **everyone ships it; our biggest gap** |
| Cost / token governance | ❌ | none | **#1 abandonment trigger; we have nothing** |
| Cross-run memory / verified skills | ❌ | amnesiac | strong want; donors exist |
| Supervised multi-agent (worker fan-out, single-writer) | ❌ (seam only) | `worker` role unwired | shipped by peers, but OVER-hyped |
| Benchmark (team-vs-single, cost+quality) | ❌ | none | needed for the pitch — but a minefield |

---

## 2. Cross-compare: where Mythos LEADS / TIES / TRAILS

**LEADS (real, defensible — confirmed by the OSS survey finding no tool pairs both):**
1. **Typed-validated-DAG + an LLM verify-the-goal critic gate.** Closest peer (Bernstein) uses
   *deterministic* gates (tests/lint) and a plan-once scheduler — no semantic completion gate. Everyone
   else is prose/ReAct/mode-routing.
2. **Heterogeneous vendors as NATIVE-API roles in one loop.** Every other "multi-vendor" orchestrator
   (Bernstein 44 CLIs, Claude Squad, Emdash, Vibe Kanban, Composio) **shells out to vendor CLIs as
   subprocesses** — opaque context, no shared loop. Only **Aider** binds different vendors natively
   (architect+editor) — 2 roles, single pass, no critic. Mythos's planner/coder/critic-in-one-loop is
   **unique in OSS as of June 2026.**

**TIES:** replan-on-failure (Bernstein/OpenHands retry too); BYOK/provider-agnostic (now table stakes).

**TRAILS:** supervised fan-out (Bernstein/Ruflo/OpenHands ship it); **and the whole table-stakes trio —
cost gov, observability, memory — we have none, the field has all three mature.**

**Donors to steal from (license-compatible):** **Bernstein** (worktree-per-task + owned-files +
deterministic scheduler + merge gate) for fan-out *later*; **LiteLLM** (per-session/max-iteration
budgets, spend attribution) for cost; **OTel `gen_ai.*` spans + MLflow** for observability; **Voyager /
Ruflo** for verified-skill memory.

---

## 3. Strategic positioning — the federation tailwind (don't fight A2A)

The labs standardized on **federation**: **MCP** = the tool layer (Anthropic; now in the Linux
Foundation's Agentic AI Foundation, Dec 2025), **A2A** = opaque agents messaging as *separate services*
(Google → LF; 150+ orgs incl. AWS/MS/Salesforce/IBM). "MCP is the API inside a micro-service; A2A is the
HTTP between micro-services."

**That's the OPPOSITE axis from Mythos's thesis** (one shared loop, vendors as roles *inside* it) — which
means **it's not a competitor, it's the unclaimed interior.** The move:

- **Speak MCP + A2A at the edges, own the unified-loop interior.** Consume MCP tools (we have a client);
  honor **AGENTS.md**; add an **A2A adapter** so "the unified multi-vendor loop is *one* high-quality
  A2A agent that also calls other A2A agents." That turns the "but the world is federated" objection
  into a feature.
- **Don't become "another agent framework"** (ADK/Agents SDK/MAF own that, cloud-backed). **Don't invent
  a wire protocol** (A2A won). **Don't lean on BYOK as the whole moat** (everyone claims model-agnostic
  via LiteLLM). The moat is the **disciplined unified loop + live cross-vendor roles + verify gate.**

---

## 4. The revised roadmap

### Phase 3 — make the loop LEGIBLE + BOUNDED (observability + cost; same surface)
**3a. Observability (terminal-native, trustworthy-by-construction).**
- Adopt the OTel `gen_ai.*` span shape as a `Codable` struct: `{traceId, spanId, parentSpanId, agentId,
  vendor, role, model, tokensIn, tokensOut, finishReason, toolName, startedAt, endedAt, status}`. Emit one
  per LLM call + per tool call.
- Thread **one `traceId` through every call/spawn** (fixes the documented context-propagation gap before
  fan-out exists). Render to TTY: live indented tree (per-role token burn) + post-hoc summary.
- **Trust boundary (our existing instinct, ahead of the literature): measured spans (tokens/durations)
  may drive display; anything an agent *claims* is advisory until the critic verifies it.**
- Per-role/per-vendor attribution answers the multi-vendor question "which vendor is burning budget."

**3b. Cost governance (the #1 abandonment trigger).**
- `BudgetLedger` (Foundation actor, thread-safe across future workers). Hard run-cap → "stop at the
  ceiling" = halt + **honest-fail with the partial result** (reuse our honest-fail path).
- Per-role token budgets; `max-iterations` already exists (maxReplans). Bind **role → cost tier**
  (critic/final = frontier — **never cheap-route the critic**; planner-scan/triage = cheap/local).
- **Exact prompt-prefix caching** (system prompt + tool defs are identical across our uniform-protocol
  calls → free 40–60% savings). Semantic caching only on read steps, **never on write steps**.

### Phase 4 — cross-run memory (verified skill library, built on the EXISTING critic)
- A skill = a **verified plan-DAG fragment + goal + critic verdict**, stored `Codable` on disk; **only a
  critic "accomplished" verdict admits a skill** (unverified memory is worse than none — caches mistakes).
- Three separate files: `facts.jsonl` (semantic — ship now), `episodes.jsonl` (episodic, timestamped
  outcomes — ship now), `skills/` (procedural — **label PROTOTYPE**, gate behind a flag).
- **Retrieval gated on typed-schema match, not embedding vibes** (our DAG is already typed). Re-verify on
  reuse; demote stale skills.

### Phase 5 — supervised multi-agent (NOW safe: observable + cost-bounded)
- **The settled synthesis (Anthropic × Cognition): parallel for disjoint READ/explore frontiers,
  serialized single-writer for anything mutating.** Partition the DAG: a node fans out iff read-only +
  no path to another running node.
- Writes serialize through **worktree leases** (own named path-globs); **merge = a critic-gated DAG node**
  (reuse verify-the-goal), never a parallel one. **Carry the decision TRACE, not just the task string**
  (Cognition's #1 anti-incoherence move). **Cap fan-out by task class (≤5–7).**

### Cross-cutting — benchmark harness (adversarially honest, or don't bother)
- **Fixed harness, vary ONLY the team config** (A = single strong model, B = multi-vendor team) — else
  you've changed an unmeasured confound (Harness-Bench).
- **Report quality-PER-DOLLAR, never quality alone** (the 15× multiplier means a quality win at 15× cost
  is not a win for most tasks — say so).
- **Private, held-out, self-authored task set** (20–50 real tasks) — public benchmarks are contaminated
  (SWE-bench 5–15pt inflation) and reward-hackable (UC Berkeley hacked all 8 to ~100% without solving
  anything). Verdicts from **real build/test gates, not self-report.** Pre-register; **publish the losses.**

---

## 5. Honest risk register (label these PROTOTYPE; don't ship earned-less confidence)

| Risk | Why | Mitigation |
|---|---|---|
| Plan-mode as mandatory ceremony | practitioners punish it ("skip the spec if a follow-up prompt fixes it") | auto-skip/lightweight path for obvious tasks; plan **editing** not just approve/reject; replan only the affected subtree |
| Parallel *coding* agents → incoherent merges | Cognition's unrefuted structural argument | single-writer + worktree lease + carry decision trace; cap fan-out |
| Auto-compounding skill library | procedural memory is least-developed, research-stage | verified-only, schema-matched retrieval, PROTOTYPE label, re-verify on reuse |
| Self-reported "team beats single" | the most reward-hack-prone claim; self-grading "wins" | fixed harness, private tasks, build/test verdicts, quality-per-dollar, publish losses |
| Cost blowup at fan-out | 10–100× tokens; gets tools banned | BudgetLedger + hard cap BEFORE Phase 5 |
| Default-on telemetry | trust wound (GitHub CLI backlash) | local-only spans, no network, opt-in, documented |

---

## 6. Caveats on this research
- **Reddit was blocked again** (env): Reddit-attributed sentiment is secondhand via aggregators —
  directionally consistent, not thread-verified. Re-run with API auth if a primary cite is needed.
- **Star/benchmark numbers are order-of-magnitude** (2026 listicles are noisy/SEO).
- Some cited papers are forward-dated; load-bearing claims rest on primary lab/LF/OTel/Voyager/Cognition
  sources, not those.
- "Absence of a tool matching our exact combo" is absence-of-evidence in a noisy ecosystem — strong but
  not a proof of uniqueness.

---

## 7. Bottom line
We genuinely **lead** on the two hard bets (typed-DAG + goal-critic; native cross-vendor roles in one
loop) — confirmed against the whole field. We **trail** on the unglamorous trio that actually drives
adoption and prevents abandonment. **The research changed our next move: build observability + cost
governance (Phase 3), then memory (Phase 4), then — only then — supervised fan-out (Phase 5), with an
adversarially-honest benchmark throughout.** Make the loop legible and bounded before wider. Position as
a first-class node in the MCP+A2A federation while owning the unified-loop interior the protocols don't touch.
