**Brutal review:**

### 1. SKILLS — how far behind / ahead of the industry?

This is mediocre and architecturally naive.

Progressive disclosure via `read_file` is a hack, not a design. It works for tiny demos but creates several structural problems:

- **Discovery and reliability are broken.** Weaker models (explicitly called out with Gemini) simply ignore skills on non-trivial tasks. This is fatal. Claude Code and Cursor both solved this by making skills/commands *triggerable* rather than purely opt-in via reading a file. LangGraph and OpenAI Agents SDK treat skills/tools as structured, validated objects with explicit registration — not "maybe the model will read this markdown file."
- **No first-class loading mechanism.** Reusing `read_file` means you get zero control over loading behavior, caching, partial loading, or error handling. Real systems (Cognition/Devin, proper MCP skill implementations, LangGraph) have dedicated skill loaders with validation and lifecycle.
- **Security and trust model is missing.** At 100+ skills or with any marketplace, you have no signing, versioning, provenance, or approval gates. The current "last-wins + ConfinedRoot" approach collapses under untrusted skills. This is the same mistake many early agent frameworks made in 2023-2024.
- **Composition and scale are unaddressed.** No namespacing, no dependency declaration between skills, no conflict resolution beyond crude dedup. Multi-repo usage will be painful.

**Verdict:** This is behind Claude Code's command/skill system and Cursor's rules, and significantly behind typed agent frameworks. The "progressive disclosure" idea is directionally correct but implemented at the wrong layer.

### 2. COST-CAPS — is this real cost control or a toy?

This is a toy.

Token-only hard stop with a shared ledger is the minimum viable thing that can be called "budgeting." Production cost governance requires more:

- Real systems (Anthropic, OpenAI, internal agent platforms at scale) track **dollar cost** as the primary dimension, not tokens. Token counting is just an input.
- No wall-clock time, no per-tool cost/rate limits, no degradation paths (only hard halt).
- The TOCTOU window under fleet parallelism is real and acknowledged — this will leak budget under load.
- `--council` and `--research` being uncapped is an obvious, large hole.
- No attribution, no hierarchical budgets (org/project/agent), no soft warnings, no per-day/per-tenant quotas.

This will stop obvious runaway loops but provides almost no operational control once you have multiple agents, long-running work, or expensive tools (browser, web search, vision).

### 3. THE FUTURE + WHAT WE'RE MISSING

The single most important thing not done this session is **making skills first-class, validated, loadable objects** instead of markdown files read through the existing tool. Everything else is secondary to this.

Without this, both features will age poorly. Skills will remain brittle and unscalable, and cost control will stay superficial because you can't attach budgets or policies to skills themselves.

**Top 5 gaps ranked (harsh priority):**

1. **Skills as first-class objects with schema + loader** (highest risk)  
   Current file-based approach will not survive 50+ skills or any external distribution. This should have been the foundation.

2. **No cost attribution or multi-dimensional limits**  
   Token-only + global cap is too coarse. You cannot run this in any real production setting without knowing *which* agent/skill consumed what.

3. **Missing skill security model (signing, versioning, approval)**  
   Once skills become useful, the lack of provenance becomes the dominant risk. This is more urgent than hot-reload or global directories.

4. **Council/research paths left uncapped**  
   These are exactly the expensive, long-running operations that need governance most. Leaving them out makes the budget feature incomplete by design.

5. **No soft limits or degradation strategies**  
   Hard halt is brittle. Real systems need warning thresholds, model downgrades, tool restrictions, or task shedding before total shutdown.

The pattern across both features is the same: minimal surface area was prioritized over proper abstraction boundaries. This works for early demos but creates technical debt that will be expensive to fix once real usage appears.