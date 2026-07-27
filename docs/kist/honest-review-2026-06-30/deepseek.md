## 1. SKILLS — How far behind / ahead of the industry?

**Short verdict: Mediocre design disguised as clever.** The progressive-disclosure trick (read_file from prompt) is a hack that works *sometimes* for text-heavy models, but it’s brittle, unscalable, and already behind every serious contender. You haven’t solved the hard problem: skill selection, conflict resolution, and trust at scale.

### What they got right (barely)
- Low upfront prompt cost via `available_skills` list.
- Reuse of existing read_file infrastructure (no new tool).
- Dedup last-wins is correct for simple overrides.

### What is quietly broken or naive

**1. Progressive disclosure via read_file is a hack, not an architecture.**  
- It works only if the model *chooses* to read the file. Weaker models skip it even on nontrivial tasks. You already saw that with Gemini. This is not a "nudge" problem — it’s a fundamental failure of the mechanism. A skill that is not loaded cannot influence behavior.  
- Claude Code skills are injected as structured rules that *always* apply (priority-ordered, regex-gated). Cursor rules are loaded *before* every interaction. LangGraph nodes have explicit skill bindings. You are relying on model volition to execute a side-effect. That’s unacceptable for production.  
- Workaround: injecting the nudge into the system prompt is fragile; you’ll have to tune per-model. This will break when model providers update their default behavior.

**2. No skill matching/routing logic — just flat file names.**  
- `available_skills` is a plain list. No semantic matching, no file-type/pattern triggers, no dependency resolution. For 10 skills it’s fine. For 100 skills (realistic team repo), the list becomes noise. The model will ignore it or get confused.  
- Incumbents like Claude Code use glob patterns (`*.ts`, `test/**`), Cursor uses per-project rules with regex conditions, Devin uses learned skill selection. You have nothing.  
- Without pattern-based activation, every skill must be manually remembered by the user or guessed by the model. That’s not scalable.

**3. Trust model is absent.**  
- Skills are just `SKILL.md` files. They can contain arbitrary instructions including prompt injection, shell commands, or malicious file writes. Currently you only have frontmatter dedup and a 1 MiB cap. No signing, no version pinning, no permission scoping, no sandbox for skill execution.  
- The MCP ecosystem already has signed tool contracts. LangGraph has versioned graphs. OpenAI’s Agents SDK has manifest validation. Your skills are worse than a raw `custom_tool` because they are invisible until read — and can hijack the agent’s behavior retroactively.  
- The planned “skill forge” and signing are *not built*. That means every skill from a third party is a supply-chain risk. In a multi-repo fleet, a compromised skill in a subproject can poison the planner agent. This will explode in your face.

**4. No skill lifecycle management.**  
- No command to list, install, remove, or inspect skills (`/skills`). No hot-reload means you must restart the agent to see new skills (or rely on model reading at runtime, which is unreliable).  
- No versioning means rollbacks are impossible. CI/CD integration? Forget it.  
- The “proven custom_tool into signed skill” is a *not-yet* that should have been *this-session*. It’s the whole point of skills: turning ad-hoc behaviours into reusable, auditable capabilities. Right now skills are just static docs.

**5. Global skills and cross-project sharing are missing.**  
- `~/.kist/skills` not implemented. That means every team member must copy skill files into every project. No company-wide skill registry. No marketplace.  
- Claude Code’s global config, Cursor’s `.cursorrules` inheritance, and LangGraph’s shared library all support this. You don’t.

**6. “Builtins” via `kist:` prefix are fragile.**  
- The traversal guard is okay, but it adds a special-cased virtual filesystem. Why not just embed them as a simple library that the agent can load via `custom_tool` or a dedicated skill reflector? This complexity will haunt you when you want to update a builtin skill — you have to rebuild the app bundle. That’s not “open” for users.

### Benchmark alignment (brutal)
- **Claude Code skills**: you are 3–6 months behind in maturity (pattern matching, override stack, rule-style composition).  
- **Cursor rules**: you don’t have anything equivalent; Cursor rules are a superset (conditions, per-file, per-language, priority). You have flat text files.  
- **LangGraph**: you are in a different universe — graph-based orchestration with explicit skill nodes is far more predictable.  
- **OpenAI Agents SDK**: their function tool declarations are richer, validated, and versioned.  
- **Devin/ Cognition**: they use learned skill decomposition — you are manual.

**Real risk:** In 12 months, every serious coding agent will have structured, versioned, condition-triggered skills with signatures and sandboxed execution. You will be scrambling to retrofit.

---

## 2. COST-CAPS — Is this real cost control or a toy?

**Short verdict: It’s a toy. Honest halt-at-cap is a pedagogical minimum, not a production cost-governance system. You have no spending limits, no budget attribution, no graceful degradation, and a known race condition.**

### What works (only as a demo)
- One shared `BudgetLedger` across the fleet is correct — total cap prevents runaway scaling.  
- Estimate fallback for missing provider usage is necessary.  
- Honest halt (no soft failure) is better than no halt.

### What is quietly broken or naive

**1. Tokens-only is useless for cost control.**  
- Real money is spent in dollars, not tokens. Providers charge different rates per token, per model tier, per caching, per context length. A token cap of 1M on GPT-4 is $20; on DeepSeek it’s $0.20. Your users will burn through budget without knowing the actual cost.  
- The only metric that matters for governance is **cost in currency** or at least **provider-relative cost units**. Without it, you cannot set a per-task budget in a multi-provider environment.  
- All serious cost tools (LangSmith, Braintrust, Helicone, Portkey) compute actual cost from token/pricing tables. You don’t.

**2. No wall-clock or per-tool limits.**  
- A long-running single tool (e.g., `web_fetch` on a 50MB page) can consume 100k tokens from one tool call. That’s fine under token-cap, but you can’t cap per-tool waste.  
- No wall-clock timeout means a slow model block can hold the fleet hostage. Should be trivial to add a time budget but you chose not to.  
- In production, you need hierarchical budgets: per-agent, per-tool, per-step, per-minute. Tokens-only is insufficient.

**3. TOCTOU is a real problem, not just doc-worthy.**  
- “Bounded TOCTOU under parallel fleet load” is euphemism for a bug. Without atomic reserve-before-spend, two concurrent agents can both check `budget - cost > 0`, both pass, both spend, and exceed the cap.  
- The fix is an atomic `reserve(tokens) -> bool` that decrements the ledger immediately. You deliberately didn’t implement it. That means in a fleet of 10 agents, the cap is a soft guideline, not a hard limit.

**4. Council and research synthesis are uncapped — big hole.**  
- The most expensive components (council deliberation, research synthesis) are *outside* the budget enforcement. The council can spend unlimited tokens before the planner even starts. This is a massive escape hatch.  
- You document it as a gap — that’s fine, but it means the cost-cap `--budget` is a half-measure. The first thing any attacker (or tired developer) will do is bypass it via `--council`.

**5. No soft-warn or degrade mode.**  
- Hard halt at 100% is the worst user experience. Real cost systems (e.g., AWS Budget Actions) fire warnings at 50%, 80%, 95% and allow graceful degradation: reduce model tier, switch to cheaper provider, cache aggressively, or just alert the user.  
- Your agent just drops dead mid-task. That will frustrate users and break long-running workflows. A simple “budget critical — switching to cheap model” would be 10 lines of code and change everything.

**6. No per-tenant, per-day, per-user budgets.**  
- If I run a fleet of 10 agents for 10 developers, I can set a global cap of 100M tokens. But I can’t limit each developer to 10M tokens/day. That’s a basic multi-tenant requirement.  
- Incumbents (LangSmith, Braintrust) support hierarchical budget policies. You have a single integer. That’s not a “minimum” — it’s a starting point that will need a complete rearchitecture.

**7. No cost attribution or audit trail.**  
- The ledger just decrements. There’s no record of *which* agent, *which* tool, *which* model call consumed the tokens. For debugging cost overruns or billing, you have zero visibility.  
- Every production system logs cost per span. You could trivially print to a file, but you didn’t.

### Right architecture (what you should have done)
- Use a `CostPolicy` struct with fields: `tokens`, `dollars`, `time_seconds`, `per_tool`, `soft_limit`, `hard_limit`.  
- Atomic reserve-with-rollback: `reserve(est_tokens, agent_id) -> bool`. On completion: `commit(actual_tokens)`.  
- Per-agent and per-fleet budgets, reconciled at end.  
- Cost calculation using a pricing map keyed by provider+model+region (configurable).  
- Graceful degradation: when budget > 80%, switch to a cheaper model. When > 95%, stop all new agents, finish current tasks.  
- All logs sent to an external sink (OpenTelemetry, file, REST) for audit.

---

## 3. THE FUTURE + WHAT WE’RE MISSING (ruthless)

**Single most important thing you did NOT do this session: You did not build the bridge between skills and cost-caps.** These two features are completely siloed. They should not be — skills can be cost-gated (e.g., “only use expensive web fetch skill if budget > 50%”), and cost-caps should trigger skill degradation (e.g., “disable vision skill when budget low”). You gave us two orthogonal features when a cross-cutting integration is the only thing that makes them matter.

### Top 5 gaps across the session (ranked by impact, effort/risk)

| Rank | Gap | Effort | Risk | Why it matters |
|------|-----|--------|------|----------------|
| 1 | **Missing skill-aware cost governance** — skills have no cost metadata, cost-caps have no skill-level gating. | Medium | High | Without it, budgets are useless (vision skill can blow 100x your cap) and skills are blind to resource constraints. Should have been a single afternoon: add `cost_weight` to SKILL.md frontmatter, use it in the ledger to prioritize cheap skills. |
| 2 | **No pattern-based skill activation** — skills are ambient, not triggered by context. | High | Critical | Without triggers, 100 skills are noise. You need regex/glob conditions so only relevant skills are even offered. Claude Code has it. Cursor has it. You are left behind. |
| 3 | **Skill trust model absent** — no signing, no sandbox, no audit. | High | Critical | One compromised skill can exfiltrate the entire fleet. The HMAC/hash-chain in the fleet layer doesn’t protect against skills themselves being malicious. You need skill signing (Ed25519) and execution sandboxing *per skill*. |
| 4 | **Cost-caps are tokens-only, no dollar conversion** — makes the feature a toy for real-world deployments. | Low | High | Adding a pricing map and unit-conversion is ~30 lines of code. Your users are already asking for it. Leaving it out is negligence. |
| 5 | **No hot-reload for skills, no `/skills` command** — the developer experience is terrible. | Low | Medium | You ship a feature that requires restart or runtime file read (unreliable). A simple CLI command (`kist skills list`, `kist skills install`) and file watcher would double the usability for trivial effort. |

### Embarrassment timeline
- **3 months**: Someone builds a skill marketplace where skills have versioned, signed manifests and pattern triggers. Your users will ask “why can’t I just `kist skill install github.com/foo/bar`?” — you will have no answer.
- **6 months**: A large team using kist blows through $500 in 10 minutes because the `vision` skill used 1M tokens before the token cap caught it (the cap was 2M). They will realize the cost-cap doesn’t constrain dollars.
- **12 months**: The MCP ecosystem will have skill/rule standards that require trigger conditions and permission scopes. Your progressive-disclosure read_file approach will be seen as a curiosity.

### Final brutal truth
This session shipped two features that each address a real need, but both are **MVP-level incomplete and mutually isolated**. The real value of an autonomous coding agent is in *reliable, resource-conscious behavior*. You have neither reliability (skills are optional, unversioned, untrusted) nor resource consciousness (token-only, no skill-level cost control). You are building a race car with no steering wheel (skills) and a fuel gauge that only reads liters when gas stations charge per gallon (cost-caps). Fix the integration, add the missing foundations, and stop shipping half-done features for the sake of a release.