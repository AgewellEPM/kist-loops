Brutal, prioritized, and specific. No flattery, no padding. Here’s what’s weak, missing, or quietly broken in your SKILLS and COST-CAPS, benchmarked against the real state of the art.

---

## 1. SKILLS — How Far Behind / Ahead? Where Is It Broken?

### **Harsh Truths First**

**A. LACK OF TRUST, GOVERNANCE, AND SUPPLY-CHAIN SECURITY**

- **No skill signing, versioning, or provenance:** You’re shipping skills as plaintext blobs with zero cryptographic authenticity, trust, or auditability. This is **years behind** OpenAI Agents SDK, Devin, and even Cursor, which are all moving toward signed, versioned, and reviewable skill/agent artifacts.  
- **No untrusted skill sandboxing:** You allow project-level skills, but there’s no runtime isolation or permissioning per skill. This is a massive attack surface for malicious or buggy skills, especially if you ever allow a marketplace or sharing.  
- **No per-skill approval or user consent:** The agent can silently load and execute arbitrary skill logic, with no workflow for user review or approval. This is a glaring omission for any real-world, multi-user, or enterprise context.  

**B. NAIVE SCALABILITY, DISCOVERY, AND MANAGEMENT**

- **No indexing, search, or tagging:** With 100+ skills, your flat last-wins dedup is unmanageable. No search, no categorization, no way to see what’s available or relevant.  
- **No versioning or dependency management:** Skills are static blobs, not composable or upgradable modules. No way to pin to a version, roll back, or resolve conflicts.  
- **No global (~/.kist/skills) or multi-repo support:** You’re missing the most common use-case: organization-wide or user-wide skills.  
- **No hot-reload or live update:** Skills are only loaded at startup or on read. No way to update, reload, or patch skills on the fly. This is table stakes for anything “agentic” at scale.  

**C. PROGRESSIVE DISCLOSURE VIA read_file IS A HACK**

- **Why is the agent “reading” skills as files?** This is a leaky abstraction. Real agent frameworks (LangGraph, OpenAI Agents, Devin) treat skills/tools as first-class, queryable objects, not just text files.  
- **No dedicated skill API or tool:** You’re overloading read_file to fetch skill docs. This is fragile, and will break as soon as you want richer metadata, structured skill manifests, or dynamic skill querying.  
- **No separation of skill interface vs. implementation:** You’re just injecting markdown docs as prompts. There’s no way to express structured input/output schemas, parameter types, or capabilities. This is a major limitation compared to OpenAI’s tool schemas, Cursor’s rules, or LangGraph’s node interfaces.  

**D. NO MARKETPLACE OR COMMUNITY ECOSYSTEM**

- **No “skill forge,” no sharing, no review, no discoverability:** You have no path to a real ecosystem. Cursor and OpenAI are already moving toward skill marketplaces with review, trust, and sharing workflows.  

**E. WEAK MODEL PROACTIVITY**

- **Skills are only loaded if the model “notices” them:** You admit weaker models ignore skills unless nudged. This is a fundamental flaw—real frameworks use explicit tool selection, not hoping the model reads the docs.  

---

**Industry Comparison Table:**

| Feature           | kist/Mythos | OpenAI Agents | Cursor | LangGraph | Devin | MCP+skills |
|-------------------|-------------|---------------|--------|-----------|-------|------------|
| Skill signing     | ❌          | ✅            | ✅     | n/a       | ✅    | Partial    |
| Versioning        | ❌          | ✅            | ✅     | Partial   | ✅    | Partial    |
| Skill sandboxing  | Partial     | Partial       | Partial| n/a       | ✅    | Partial    |
| Discovery/search  | ❌          | ✅            | ✅     | Partial   | ✅    | Partial    |
| Hot reload        | ❌          | ✅            | ✅     | Partial   | ✅    | Partial    |
| Structured I/O    | ❌          | ✅            | ✅     | ✅        | ✅    | Partial    |
| Marketplace       | ❌          | WIP           | WIP    | n/a       | WIP   | n/a        |

---

**Bottom Line:**  
You’re **one to two years behind** the state of the art in skill governance, trust, and scale. The “progressive disclosure via read_file” is a **stopgap, not a foundation**. Fine for a solo hacker; not even close for enterprise, teams, or an ecosystem.

---

## 2. COST-CAPS — Is This Real Cost Control or a Toy?

### **Harsh Truths First**

**A. TOKENS-ONLY IS NOT REAL COST CONTROL**

- **No $-cost, no wall-clock, no per-tool, no per-user, no soft warnings:**  
  - Real orgs care about dollars, not tokens. You’re blind to actual spend, especially as provider pricing diverges (input/output, context window, model, etc).  
  - No wall-clock control = runaway jobs can burn time, even if token use is capped.  
  - No per-tool or per-agent limits = one tool or agent can starve the rest.  
  - No soft warnings, degrade modes, or tiered budgets = all-or-nothing is not how real systems degrade.  

**B. TOCTOU IS A REAL RACE CONDITION**

- **No atomic reserve-before-spend:**  
  - Under parallel fleet load, you can overspend the budget. This is a classic “bounded race” but can still lead to real overages.  
  - Incumbents (OpenAI, enterprise LLM ops) use atomic budget reservations, often with distributed locks or transactional ledgers.  

**C. NO ATTRIBUTION OR AUDIT**

- **No per-agent, per-tool, per-task cost tracking:**  
  - You can’t answer “who spent the budget?” or “what did this agent/tool cost?”  
  - This is a non-starter for any team, org, or multi-tenant deployment.  

**D. UNCAPPED MODES = HOLES**

- **Council/research synthesis is uncapped:**  
  - You have known, documented holes. This is not production-grade.  

**E. NO BUDGET POLICY OR SCHEDULING**

- **No per-day, per-user, per-tenant, or rolling budgets:**  
  - No support for time-based or user-based quotas.  
  - No way to “pause” or “throttle” agents as they approach the cap.  

**Industry Comparison Table:**

| Feature                | kist/Mythos | OpenAI Agents | Enterprise LLM Ops | Cursor | Devin |
|------------------------|-------------|---------------|--------------------|--------|-------|
| $-cost enforcement     | ❌          | ✅            | ✅                 | Partial| ✅    |
| Wall-clock limit       | ❌          | ✅            | ✅                 | ❌     | ✅    |
| Per-tool/agent budget  | ❌          | ✅            | ✅                 | Partial| ✅    |
| Attribution/audit      | ❌          | ✅            | ✅                 | Partial| ✅    |
| Soft warn/degrade      | ❌          | ✅            | ✅                 | ✅     | ✅    |
| Atomic reserve         | ❌          | ✅            | ✅                 | ❌     | ✅    |

---

**Bottom Line:**  
This is **MVP-level, not production**. It’s a toy cap, not real cost governance. You need at least $-cost, attribution, atomicity, and soft degrade to be credible.

---

## 3. THE FUTURE + WHAT WE’RE MISSING (Top 5 Gaps)

### **#1: NO SKILL SIGNING, VERSIONING, OR GOVERNANCE**  
**Effort:** Medium-High (crypto + workflow + UX)  
**Risk:** Catastrophic if you ever allow shared/marketplace skills.  
**If you don’t fix:** You’ll be locked out of any real org or community use. Skills will be a malware vector and an unmanageable mess.

### **#2: NO $-COST OR ATTRIBUTED COST CONTROL**  
**Effort:** Medium (provider APIs, ledger, UI)  
**Risk:** Real users will get burned by runaway spend. You’ll never get adopted in teams/orgs.  
**If you don’t fix:** Your cost cap is a fig leaf; you’ll get laughed out of any serious deployment.

### **#3: NO STRUCTURED SKILL SCHEMA OR INTERFACE**  
**Effort:** Medium (schema, validation, prompt plumbing)  
**Risk:** Skills will be brittle, non-composable, and hard to evolve.  
**If you don’t fix:** You can’t build a real skill ecosystem or marketplace. You’ll be stuck in “markdown doc as API” hell.

### **#4: NO SKILL DISCOVERY, SEARCH, OR HOT RELOAD**  
**Effort:** Medium-Low  
**Risk:** With 10+ skills, users will be lost. With 100+, it’s unusable.  
**If you don’t fix:** Skills become a graveyard of dead code; users can’t find or update what they need.

### **#5: NO PER-AGENT, PER-TOOL, OR TIME-BASED BUDGETS**  
**Effort:** Medium  
**Risk:** Single rogue agent/tool can starve the rest; no way to allocate or schedule work.  
**If you don’t fix:** Your fleet will be unmanageable at scale.

---

## SUMMARY TABLE

| Gap                                    | Effort | Risk if Unfixed                | Industry Status      |
|-----------------------------------------|--------|-------------------------------|---------------------|
| Skill signing/versioning/governance     | Med-Hi | Security, trust, adoption     | Standardizing fast  |
| $-cost/attribution cost control         | Med    | Real spend, org adoption      | Table stakes        |
| Structured skill schema/interface       | Med    | Ecosystem, composability      | Incumbent standard  |
| Skill discovery/search/hot reload       | Med-Lo | Usability, scale              | Table stakes        |
| Per-agent/tool/time-based budgets       | Med    | Fleet starvation, scale       | Table stakes        |

---

## TL;DR

- **Skills:** You’re a generation behind on trust, scale, and composability. “Progressive disclosure via read_file” is a hack, not a foundation.  
- **Cost-caps:** Tokens-only is a toy. No $-cost, attribution, or atomicity = not credible for real use.  
- **Biggest miss:** No skill signing/governance. You’re building a malware vector, not a platform.  
- **Next most urgent:** Real $-cost and attribution.  
- **If you don’t fix these, you’ll be irrelevant in a year.**  

**Brutal verdict:** You shipped two features that are “good enough for a solo hacker,” but **not even close** to production, team, or ecosystem standards. Fix trust, cost, and composability—**or get left behind.**