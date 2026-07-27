# Council Review: kist / Mythos

## 1. Where Agentic AI Is Heading (Next 12–24 Months)

**The agent loop is becoming commodity. Governance is the new moat.**

Everyone will ship plan→act→observe by mid-2026. Open-source scaffolding (LangGraph, CrewAI, AutoGen) already makes this a weekend project. What won't be commodity: **trust infrastructure** — provenance, attestation, scoped authority, and audit trails. kist is early here, which matters.

**Bets I'd make:**

**Context is the bottleneck, not intelligence.** Models are converging in capability; the differentiator is how much relevant code, docs, and state you can reliably inject. The winning architecture is a **context engine** — retrieval-augmented generation with repo-aware sharding, dependency graphs, and relevance scoring — not a bigger context window. Context_brain is kist's most underrated feature. Double down.

**Native tool-calling convergence.** OpenAI, Anthropic, Google, and now Mistral are converging on structured tool-use as the primary actuation interface. The text-tool fallback ("write JSON to stdout") will die within 12 months. Systems that treat native tool-calling as the primary path with text as graceful degradation will win. kist's dual-path is correct but needs to be weighted.

**Agentic protocols will consolidate around two, maybe three.** MCP will win remote tool servers (Anthropic's network effect + OpenAI's adoption). A2A is a Google vanity project — I'd bet against it. What will matter is **agent-to-agent trust negotiation**: how one agent verifies another's scope, attestation, and lease before delegating. Nobody has standardized this yet.

**Evaluation becomes runtime, not offline.** Benchmark leaderboards are irrelevant to production agents. The shift is to **continuous runtime evaluation**: measuring task completion rate, tool-call efficiency, rollback frequency, and cost per completed task in production. Agents that can't self-measure will be opaque and untrustworthy.

**Local-first becomes real.** Ollama + MLX + llama.cpp + quantized 70B-class models on Apple Silicon means serious agents run locally. Provider-agnostic shells that work equally well against local and remote endpoints will dominate the developer segment. kist is positioned for this but hasn't committed.

**The "agent OS" abstraction will emerge.** Just as containers became the deployment primitive, an **agent execution environment** — with scoped filesystem, network policy, resource budgets, and identity — will become the unit of deployment. kist's sandbox is a proto-version of this. Seatbelt + ConfinedRoot is Unix-native and correct, but needs to become portable (Linux seccomp-bpf, container-native).

---

## 2. What kist Is MISSING

**No state persistence layer.** kist can plan, act, and observe across turns, but where does the agent's **episodic memory** live? What happens when a session dies mid-task? There's no mention of checkpointing, durable task state, or crash recovery. A governance-first system that loses its work on a dropped terminal session is a contradiction.

**No cost accounting or budget enforcement.** Fleet agents burn tokens. There's no mention of per-agent token budgets, cost tracking, circuit breakers on runaway loops, or cost-per-task measurement. In a multi-agent fleet, one rogue agent can rack up $50 in a loop. This is a production blocker.

**No streaming-first execution model.** Users want to see what the agent is doing in real-time. The plan→act→observe loop implies turn-based batch execution. Where's the streaming tool execution, progressive output, and intermediate artifact display? Terminal-first means the UX lives or dies on perceived latency and transparency.

**No inter-agent communication protocol beyond merge gates.** The fleet model is parallel-disjoint — agents work in worktrees and reconcile at merge. But many real tasks require **sequential dependency or data handoff**: agent B needs agent A's output file, agent C needs agent B's analysis. The "disjoint scope" model breaks for workflows that aren't embarrassingly parallel. There's no message bus, shared artifact store, or DAG-based dependency scheduler.

**No user-in-the-loop governance UI.** Fleet observability is mentioned, but where is the captain's interface? A terminal-only approval gate (type "yes" to merge) doesn't scale to 10-agent fleets. Needs a TUI dashboard at minimum showing agent status, pending claims, attestation chains, and one-click approve/reject with context.

**No plugin/extension system for governance rules.** The HMAC ledger + lease enforcement is a fixed policy. But real teams need customizable policies: "no agent touches production configs," "all agents must pass mypy before claiming completion," "this agent can only modify files under /src/ui." Governance rules need to be declarative and extensible, not hardcoded.

**No multi-session / background task support.** Terminal-first means foreground execution. But durable tasks (research_run, large refactorings) should be able to run in the background, with the user checking status later. No mention of daemon mode, tmux integration, or background task management.

**No test generation or verification tool.** Agents that write code but can't generate and run corresponding tests are flying blind. The claim-reconciliation system checks if artifacts match claims, but there's no automated testing primitive. This is the highest-leverage verification mechanism and it's absent.

---

## 3. What kist Should Build Next (Ranked)

### 1. Durable State & Crash Recovery
**Effort: M | Risk: Low**

Checkpoint agent state (plan, completed actions, pending observations, worktree diffs) to a local SQLite store after every action. Resume on session reconnect. Without this, every long-running task is a gamble. This is table-stakes for a production agent and directly contradicts the governance pitch — attested work that vanishes is useless.

### 2. Cost Engine with Per-Agent Budgets & Circuit Breakers
**Effort: S | Risk: Low**

Wrap every LLM call with token counting, cost estimation, and budget enforcement. Configurable per-agent hard limits (max tokens, max cost, max tool-call iterations). Auto-halt agents that exceed thresholds. Surface cost data in fleet observability. This is a few hundred lines of middleware and eliminates the #1 production objection.

### 3. Agent DAG Scheduler (Inter-Agent Dependencies)
**Effort: L | Risk: Medium**

Replace the flat "split into disjoint subtasks" model with a dependency DAG. Agents declare inputs (files/artifacts they need) and outputs (files/artifacts they produce). A scheduler ensures correct ordering, passes artifacts, and detects circular dependencies. This transforms the fleet from embarrassingly-parallel to general-purpose workflow orchestration. This is hard — requires redesigning the foreman's merge logic — but it's the difference between a script runner and an agent OS.

### 4. Streaming Tool Execution & Progressive Output
**Effort: M | Risk: Low**

Stream LLM responses and tool outputs incrementally to the terminal. Show tool calls as they execute, not after. For a terminal-first product, this is the entire UX. Use ANSI escape sequences, spinner states, and collapsible output sections. Agents that feel fast are trusted more than agents that feel correct.

### 5. Declarative Governance Policy DSL
**Effort: M | Risk: Medium**

Define agent permissions, scope constraints, and approval workflows in a YAML/TOML config file rather than code. Examples: `allowed_paths: ["/src/**"]`, `require_test_pass: true`, `auto_approve_if: [tests_pass AND no_secret_changes]`. This makes governance composable and team-shareable. The existing HMAC/lease system becomes the enforcement engine; the DSL is the policy language.

### 6. Test Generation & Execution Primitive
**Effort: M | Risk: Low**

Add a `run_tests` tool that detects the project's test framework and runs it. Add a `generate_tests` tool that creates tests for modified functions. Wire test results into claim reconciliation — if an agent claims "feature complete" but tests fail, block signoff. This closes the verification loop that's currently open.

### 7. TUI Fleet Dashboard
**Effort: M | Risk: Low**

A blessed/ink-style terminal UI showing: active agents, their current action, pending approvals, cost accumulator, claim chain visualization. Single-key approve/reject. This transforms the captain's role from typing "yes" in a loop to actually governing. Use Bubble Tea (Go) or Ink (Node) depending on kist's runtime.

### 8. Background/Daemon Task Mode
**Effort: S | Risk: Low**

Long-running tasks (research_run, large refactors) detach to background with a task ID. `kist status` shows running tasks. `kist attach <id>` reconnects. Implement with a Unix socket and process supervisor. Small effort, high utility, directly enables the "agent as colleague" interaction model.

### 9. Linux Sandbox Portability
**Effort: M | Risk: Medium**

Seatbelt is macOS-only. Port ConfinedRoot semantics to Linux via seccomp-bpf + landlock LSM + user namespaces. This is required for kist to run in CI/CD, Docker, and server environments — which is where 80% of production agent workloads live. The macOS-only sandbox is a dealbreaker for teams.

### 10. MCP Server Hosting (Not Just Client)
**Effort: M | Risk: Medium**

kist is an MCP client. But the real network effect play is making kist an **MCP server** — expose its tools (file ops, search, browser, research) as an MCP endpoint that other agents/IDEs can consume. This turns kist from a tool into infrastructure. Every IDE that supports MCP becomes a kist customer.

---

**Bottom line:** kist's governance architecture is 18 months ahead of competitors. But it's missing the foundational production primitives (state, cost, streaming) that make it usable day-to-day. Ship items 1–2 this sprint. Items 3–6 this quarter. The rest in H2. The governance moat is real but it's eroding — OpenAI and Anthropic will ship their own fleet governance within 12 months. kist has a window. Use it.