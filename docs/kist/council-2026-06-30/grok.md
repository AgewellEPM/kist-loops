## 1. Where agentic AI is heading (next 12–24 months)

Agentic systems will converge on cryptographically attested multi-agent execution with standardized remote tool protocols. MCP and A2A will win over ad-hoc function calling because they enforce scope, provenance, and remote auditability; raw shell or single-coordinator designs will be relegated to toys. The decisive capability will be verifiable traces: every plan, tool call, and artifact must carry an Ed25519 or equivalent signature plus a chain hash so that merges, deploys, and claims can be rejected automatically.

Long-horizon reliability will come from lease-scoped worktrees, claim-reconciliation gates, and deterministic replay rather than bigger context windows. Models will improve at self-critique and patch generation, but the architecture that compounds is the one that refuses invalid state changes before they reach disk or production. Local and open-weight models will dominate high-trust workloads once sandbox primitives (Seatbelt-style, capability-based openat, process-group isolation) become portable across Linux, macOS, and WASM.

The standards fight that matters is not model size but attestation and policy: who can prove an agent stayed inside its declared scope and that its outputs match committed artifacts. Systems without these primitives will be blocked from enterprise or autonomous deployment. Single-threaded "agent loop" products will lose to fleets that can split, verify, and sign work in parallel.

## 2. What kist is MISSING

kist lacks any persistent, queryable memory layer that survives across invocations or agent lifetimes. Context_brain is a repo shard loader, not a durable store of past plans, failures, or user corrections that agents can retrieve with provenance.

There is no evaluation harness that can run an agent against a fixed task suite, score trace quality, measure scope violations, and feed results back into AgentForge or skill definitions. Without this, claims of improvement remain anecdotal.

The terminal UI provides no structured debugging surface for fleet interactions: no ability to step through a multi-agent plan, inspect lease violations, or diff signed artifacts before captain approval. Observability is present but not actionable for humans.

No cost, latency, or token accounting exists at the fleet level. Agents cannot be told "stay under $X and Y tokens" with enforcement at the planner or foreman layer.

Finally, there is no mechanism for agents to publish or consume reusable, versioned skills beyond the current progressive-disclosure menu. The system cannot bootstrap a growing library of validated procedures that new agents inherit automatically.

## 3. What kist should BUILD NEXT (ranked)

1. Persistent, signed memory graph with claim indexing (M, medium risk).  
Agents need a durable store that records every signed artifact, plan, and contradiction so future agents can query "what did we learn the last time this scope failed." This directly amplifies the existing claim-reconciliation and HMAC ledger without changing the core loop. Implementation cost is moderate because the signing and worktree machinery already exists; the risk is schema drift if the graph format is not kept minimal.

2. Agent evaluation harness with automatic regression gating (L, high risk).  
Build a task suite that replays goals, measures scope adherence, artifact correctness, and token spend, then blocks merges or skill updates when scores regress. This is the only way to make AgentForge and multi-agent claims falsifiable. High leverage because every other improvement can be measured; high risk because creating representative tasks that survive model changes is genuinely hard.

3. Structured fleet debugger and trace visualizer (M, low risk).  
Expose a machine-readable event stream (plan, lease, signoff, contradiction) that a terminal or lightweight web view can render as a DAG with diff links to artifacts. Current observability is too low-level for captains to make fast decisions. This raises effective governance quality immediately and requires only plumbing existing ledger data.

4. Fleet-level budget and policy enforcement (S, low risk).  
Add a planner-level budget object (max tokens, max cost, max wall time) that is checked before task dispatch and enforced by killing worktrees that exceed it. The sandbox and lease machinery already provide the kill switch; this is mostly policy wiring. Prevents runaway spend and makes kist usable in real budgets where competitors still rely on manual monitoring.

5. Versioned, signed skill exchange protocol (M, medium risk).  
Define a minimal manifest format for skills (entry condition, procedure, verification predicate) that agents can fetch, execute, and re-sign on success. Wire it into Agent Skills so that successful runs automatically produce candidate updates. This turns the current menu into an evolving, attestable library and creates a direct path to compounding capability without central coordination.