# Brutally-Honest Council Review — This Session's Work (Skills + Cost-Caps)

**Date:** 2026-06-30
**Council:** Gemini 2.5 Pro · Grok-4 · DeepSeek-reasoner · MiMo v2.5 Pro · GPT-4.1
**Mandate:** no flattery — find what's weak, behind the industry, or quietly broken. Raw verbatim
responses in this folder. This is the synthesis, with my grounded corrections where the council
overstated (I know the actual code; they reviewed a written description).

---

## The one-paragraph verdict

The council is near-unanimous and harsh: **both features are honest v0 — "good enough for a solo
hacker, not even close to team/enterprise/ecosystem."** That actually *matches* our own PILOT-READY
labeling (we never claimed PRODUCTION), so the labels are honest. But the council found two things we
should sit with: (1) **the single most important thing we did NOT do is connect the two features** —
skills should declare a cost profile and the budget system should reason about it at plan time; we
shipped two siloed features when their integration is where the value is; and (2) **skills have no
trust model** — a `SKILL.md` is untrusted instruction text (prompt injection), and in a fleet a
compromised skill in a subproject can poison the planner. Everything else is a feature gap; that one
is a security-architecture decision that gets harder to retrofit with every user.

Grades the council assigned: **Skills architecture B+, completeness C; Cost-cap enforcement C+,
completeness D+.** I think that's fair.

---

## SKILLS — the harsh consensus (and where they're wrong)

### What 4–5 of 5 agreed is genuinely missing / weak
1. **No trust/security model (5/5 — the #1 gap).** No signing, versioning, provenance, per-skill
   capability scoping, sandboxing, or approval. A skill is a system-prompt append; an untrusted one
   is a prompt-injection / supply-chain vector. MiMo: *"you shipped a prompt-injection delivery
   mechanism with no defenses."* The fleet's HMAC/Ed25519 machinery protects deployments but a
   runtime-loaded skill bypasses all of it.
2. **Not structured/typed (4/5).** Prose `SKILL.md` has no input/output schema, no parameters, no
   declared tool/capability dependencies, no composition. "Markdown doc as API hell" — untestable,
   un-lintable, no plan-time validation.
3. **Proactivity is a MECHANISM failure, not a nudge (4/5).** Relying on model volition to read a
   file means weaker models silently skip skills. Claude Code / Cursor make skills *triggerable*
   (glob/regex/file-pattern conditions, priority-ordered, load-before-interaction). We have none.
4. **The flat menu doesn't scale past ~30 skills (4/5).** 150 skills ≈ 2–4k tokens of menu *every
   turn, every model* — a real tax on context-limited/local providers. Needs retrieval (keyword
   pre-filter → embedding rerank), namespacing (`org/skill`), conflict/dependency declaration.
5. **Missing table-stakes (5/5):** global `~/.kist/skills`, `/skills` command, hot-reload, versioning,
   the **skill-forge** (custom_tool → proven → signed permanent skill), marketplace/sharing.

### Where the council OVERSTATED — my grounded correction
- **Gemini/Grok/OpenAI/DeepSeek call the `read_file` loader a "security catastrophe" and say rip it
  out for a dedicated `use_skill(name,version)` tool. MiMo argues the opposite — that reusing
  `read_file` is the *right* call (no context tax, model-as-router).** The specific attacks the
  hawks cite — "model reads README.md or /etc/passwd and executes it as a skill" — are **already
  mitigated** in our code: skill behavior keys ONLY on the exact advertised `skillLocations` entries,
  not any path the model reads; an arbitrary path is just a normal confined file read, never
  skill-interpreted; builtin reads are traversal-guarded and bounded to the bundle. So the *loader*
  is not the catastrophe they describe. **But the deeper point survives regardless of loader: a
  loaded SKILL.md is untrusted instruction text.** Conclusion: don't rip out `read_file` (MiMo is
  right); add the trust layer the others demand (signing + capability scoping + approval). The
  disagreement resolves to "keep the mechanism, add governance."

---

## COST-CAPS — the harsh consensus (all 5 agree: it's a circuit breaker, not governance)

1. **Tokens-only is a toy (5/5).** Real governance is denominated in **dollars** (pricing map per
   provider+model; a 1M-token Gemini call ≠ a 1M-token Claude call). We're "measuring the cost of
   thinking, not the cost of acting" — a `custom_tool` spinning a GPU or a paid API call is invisible.
2. **The TOCTOU is a real bug, not a footnote (5/5).** Under parallel fleet load, N workers each read
   "budget remaining," all pass, all spend → overshoot. The fix is atomic **reserve-before-spend**
   (`reserve(est) -> bool`, reconcile actual after). Our actor gives the serialization primitive; we
   didn't use it that way.
3. **Council/research uncapped = a cost bomb we shipped knowingly (5/5).** The highest-spend paths are
   exempt — "a fire alarm that doesn't work in the kitchen." First thing a tired dev does is `--council`.
4. **No attribution/audit (5/5).** The ledger just decrements — can't answer "which agent / tool /
   task / model spent it." Non-starter for teams.
5. **No soft-warn / graceful degrade (4/5).** Hard halt at 100% wastes the 80% already spent. Real
   systems warn at 70/80/95% and degrade: cheaper model, skip optional research, shorter contexts.
6. **No hierarchical / per-tool / per-agent / per-tenant / per-day / wall-clock budgets (5/5).** One
   integer. One greedy sub-agent starves the rest. Plus: estimate fallback is a silent integrity
   risk (flag it, apply a 1.2× margin), and budget-across-`--resume` semantics are ambiguous.

---

## THE cross-cutting miss (DeepSeek + Gemini independently named this #1)

**Skills and Cost-Caps are siloed; they should be one system.** A skill should declare its cost
profile (`cost_weight` / `tools_used` in frontmatter); the budget system should reason at *plan
time*: *"this plan needs the high-cost `run_e2e_tests` skill and my budget is low → choose an
alternative plan / downgrade / refuse."* And budget pressure should gate skills (disable the vision
skill at 80%). DeepSeek: *"a race car with no steering wheel (skills) and a fuel gauge that reads
liters where gas stations charge per gallon (cost-caps)."* This integration is cheap relative to its
value and is the through-line that makes both features matter.

---

## Ranked gaps (council-synthesized, effort/risk)

| # | Gap | Effort | Risk | Notes |
|---|-----|--------|------|-------|
| 1 | **Skill trust model** — signing (Ed25519, reuse fleet machinery), capability declaration + runtime scoping, approval workflow, static "does it fight safety?" check | H | **Critical** | The one liability vs. feature-gap. Build before any sharing/marketplace. |
| 2 | **$-cost + attribution** — pricing map per provider+model; tag every ledger entry (session/agent/tool); `/cost` breakdown | M | High | ~Pricing table + chokepoint refactor. Tokens stay as the input. |
| 3 | **Skills↔cost integration** — `cost_weight` in SKILL.md; budget-aware planner; pressure-gated skills | M | High | The synergy. Cheap once 1+2 exist. |
| 4 | **Atomic reserve-before-spend** — `reserve/commit` on BudgetLedger; cap council/research; per-agent sub-allocations | M | High | Closes the TOCTOU + the uncapped holes + starvation. |
| 5 | **Skill activation + scale** — glob/pattern triggers (kills the proactivity problem), retrieval index for 100s, namespacing, hot-reload, `/skills`, global dir | H | Med | Turns "model might read it" into "the right skills are offered." |
| 6 | **Skill-forge** — custom_tool → verified → signed permanent skill (this was already the roadmap's #4) | M | Med | Makes session intelligence compound instead of dying at exit. |
| + | Soft-warn/degrade ladder; wall-clock + per-tool limits; budget-resume semantics | L–M | Med | The "governance, not circuit-breaker" finish. |

---

## What this means for the roadmap

The council just reordered priorities. Before the original sequence (#1 memory → #3 eval → #5 cockpit),
two things it surfaced jump the queue:
- **Skill-Forge (#4) should carry the trust model with it** — signing + capability scoping aren't a
  separate project, they're how a forged skill earns "permanent." Build them together.
- **Cost-caps needs a v2 pass** — $-cost + attribution + atomic reserve + cap the council/research
  paths — to graduate from "circuit breaker" to "governance." It's mostly contained (pricing table,
  ledger API, a few call sites).

Honest bottom line: nothing we shipped is *wrong*, and the labels were truthful (PILOT, not
PRODUCTION). But the council is right that we optimized for minimal surface area, and the bill for
that comes due the moment kist has teams, untrusted skills, or real money on the line. The trust
model and the dollar/attribution layer are the two things that would be embarrassing to still be
missing in 12 months.
