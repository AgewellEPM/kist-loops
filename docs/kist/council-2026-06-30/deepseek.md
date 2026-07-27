## 1. Where agentic AI is heading (next 12–24 months)

The graph is moving from “anthropomorphic chatbots” to **industrial-grade autonomous workforces**. The three seismic shifts:

- **Multi-agent orchestration as the default architecture** – single-mind agents top out at ~70% SWE-bench resolve without retries. The next leap comes from hierarchical swarms with scoped subtasks, deterministic merge gates, and forensic audit trails. Kist’s fleet model anticipates this, but standards (MCP/A2A) are still immature – expect **A2A negotiation protocols** to add formal dispute-resolution and counter-offer mechanisms within 12 months.

- **Verifiable agent outputs** – trust tokens (HMAC signoff, chain hash, Ed25519 attestations) are the minimal floor. The ceiling is **formal correctness proofs of agent-generated code**, especially for infra changes. I’m betting on **Lean/Metal v0 + agentic verification loops** becoming a critical capability – models will call a theorem prover to certify invariants before committing.

- **Personalised, persistent, privacy-preserving context** – context windows are a dead end. The winning architectures will use **structured agentic memory** (vector + graph + fact stores) with expiration, access control, and self-supervised compaction. Expect **open standard** for agent memory (analogous to MCP) within 18 months, likely from a consortium including Anthropic, OpenAI, and Hugging Face.

- **Model arbitrage at the subtask level** – no single model excels at everything. Cost-conscious agents will route planning to Gemini, coding to Claude, web search to Grok, local sandbox to Ollama. Kist already does this, but the **model-selection policy** must become learned, not hardcoded. Expect reinforcement-learned routers in production agents by Q2 2026.

- **Sandbox consensus** – OS-level isolation (Seatbelt, ConfinedRoot) will be table stakes. The next frontier is **network-level sandboxing** (e.g., eBPF-determined outgoing calls) and **attestation-to-execution binding** where the agent’s key material is locked to the execution environment. TEE enclaves will appear in production agent hosts within 2 years.

**My bet**: The agent that ships a provable, auditable, multi-model fleet with personal memory and self-improvement will capture the market. Claude Code and Crush are ghosts – they lack governance and sandbox depth. Kist has the foundation, but needs to build the next layer fast.

## 2. What kist is MISSING

**Ruthless list** (excluding what exists):

- **No persistent personal memory** (only repo context_brain). Agents forget user preferences, prior failures, and learned optimizations across sessions. This caps long-term autonomy.

- **No agent introspection / debugging** – you can’t pause, step, modify internal state, or replay chain-of-thought. Makes trust-building impossible for complex tasks.

- **No self-improvement feedback loop** – agents never learn from past mistakes. `research_run` and `custom_tool` are outputs, not training signals. No prompt/strategy meta-optimization.

- **No general shell command execution** – only sandboxed Python. Missing ability to run arbitrary binaries, Docker containers, or scripts that require native OS interfaces.

- **No automated evaluation harness** – no regression suite to measure agent performance against benchmarks (e.g., SWE-bench, HumanEval, custom user tasks). Cannot compare models or detect regressions.

- **No granular human-in-the-loop for critical tool calls** – only captain OK on merge. Users need per-action approval for destructive operations (delete, write to sensitive paths, execute network commands).

- **No cost/performance model routing per subtask** – currently a single model per agent. Should select cheapest capable model for each subtask (e.g., Grok for web search, Claude for code, Gemini for vision).

- **No multimodal support beyond vision** – missing audio input/output, video stream processing (beyond single frame), structured data ingestion (CSV, JSONL).

- **No versioned agent strategies** – `AgentForge` creates specialists but they’re static. No way to fork, A/B test, or rollback agent behaviors.

- **No real-time streaming interaction** – agents are batch-style (plan→act→observe). Humans cannot interrupt mid-action or provide incremental feedback.

## 3. What kist should BUILD NEXT (ranked)

### 1. **Persistent personal memory store & retrieval** (M, Risk: Low)
Vector + fact + graph memory with temporal decay, access control, and auto-compaction. Agents can recall user preferences, prior problem-solving patterns, and learned tool usage. Without it, every session is a cold start. Effort: medium (add a DB layer, integrate with context_brain). Risk: low – many open-source vector stores.

### 2. **Agent introspection & debugger** (L, Risk: Medium)
TTY-mode stepping, chain-of-thought logging, state snapshots, and state mutation tools (pause, edit thoughts, re-run from checkpoint). Enables trust, fine-tuning, and root-cause analysis of failures. Effort: large (require modifications to core loop, UI, and IPC). Risk: medium – may slow execution; need opt-in.

### 3. **Self-improvement via meta-learning** (XL, Risk: High)
Log each session (goals, actions, outcomes, user feedback) into a training corpus. Periodically fine-tune a lightweight model (e.g., Llama-3B) to optimize prompt templates, tool selection, and error-handling heuristics. Or use RL from human feedback (RLHF on agent logs). Effort: very large (data pipeline, training infra, evaluation). Risk: high – could produce regressions; needs careful monitoring.

### 4. **Automated evaluation harness** (M, Risk: Low)
Define benchmark tasks (SWE-bench, custom user tasks), run agent against them, collect pass/fail + cost + latency. Integrate into CI. Allows objective comparisons when changing models or prompt strategies. Effort: medium (build task runner, metrics DB, dashboard). Risk: low – no runtime changes.

### 5. **Granular human-in-the-loop for destructive actions** (S, Risk: Low)
Add per-tool approval gates (e.g., `write` to system paths: confirm; `delete` any file: confirm; `exec` outside sandbox: deny unless explicit). Support timeouts and session-level policies. Effort: small (add confirmation UI and config flags). Risk: low – purely additive.

### 6. **General shell command execution in sandbox** (M, Risk: Medium)
Extend `custom_tool` beyond Python to support any executable (bash, Go, Node) within the existing ConfinedRoot/Seatbelt cage. Enable `exec` with argument validation and secret masking. Effort: medium (wrap syscalls, add security checks). Risk: medium – increases attack surface; must enforce O_NOFOLLOW, process-group kill, and timeout.

### 7. **Cost/performance model router** (S, Risk: Low)
Build a lightweight policy that maps subtask type (planning, coding, search, vision) to a ranked list of available models. Use simple heuristics initially (e.g., `model_priority.json`), then learn from execution logs. Effort: small (router module + config). Risk: low – no new infrastructure.

**Next 6-month priority order**: 1, 4, 5, 7, 2, 6, 3. Ship fast on memory and evaluation to build a moat; then invest in introspection and learning to cross the chasm.