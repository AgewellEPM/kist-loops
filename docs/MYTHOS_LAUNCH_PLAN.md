# Mythos — Launch Plan (ship before more phases)

**Date:** 2026-06-26 · **Status:** strategy doc (research-grounded, post-Phase-3) · Revises
`MYTHOS_PHASE3_RESEARCH_AND_PLAN.md` by inserting a **SHIP milestone before Phase 4/5.**

> Fourth research pass (4 live-web agents: distribution/launch, cross-run memory, competitive delta,
> proof/benchmarking), grounded in what we've now shipped: Phase 1 (plan→execute), Phase 2 (live
> 3-vendor team), Phase 3 (per-vendor observability + budget ceiling). 315 tests.

---

## 0. The verdict (all four streams converge)

**SHIP a soft launch next — a packaging + proof sprint, NOT Phase 4/5.** The reasoning is unanimous:

- **Distribution:** our gap is **not product maturity, it's packaging** (no LICENSE, unpushed repo,
  no brew/npm, no README demo, no docs). None of that is Phase 4/5. Building more first =
  "polishing the engine while the car has no doors," and starving ourselves of the real-user
  feedback that should *steer* Phase 4/5. The adoption playbooks: ship when your unknown is demand —
  and ours is.
- **Timing tailwind:** June 2026 is **token-bill-shock month** (a company ran up a ~$500M Claude bill
  forgetting limits; Uber reportedly burned its 2026 AI budget by April). Our per-vendor cost
  attribution + hard `--budget` ceiling is *exactly* the pain the market just started screaming about.
- **Competitive clock:** our two leads (typed-DAG+goal-critic; native cross-vendor roles in one loop)
  **still hold but are narrowing to months** — Goose/Goosetown is converging (multi-model adversarial
  review, but multi-process, no typed DAG). Plant the flag before they close it.
- **Memory (Phase 4) is small, not a big build:** the *hard* verified-skill library has **near-zero
  shipped organic demand** (arXiv only); the *trivial* capture/inject version is what's popular
  (claude-mem, 83.9k★). So Phase 4 is a minimal file-based thing done *after* launch — not a reason
  to delay shipping.

**The packaged launch surface IS the next feature, per our own quality bar ("foundation to ship is
feature #1").**

---

## 1. Where we are: product-ready, packaging-unready

| Launch requirement | Status |
|---|---|
| Differentiated working core (3-vendor team, typed DAG, verify gate, replan, honest-fail) | ✅ HAVE |
| Per-vendor cost attribution + hard budget ceiling | ✅ HAVE (the timely card) |
| ~315 tests + CI (macOS+Linux) | ✅ HAVE (surface as a badge) |
| **LICENSE** | ❌ MISSING — blocker (decision needed) |
| **Pushed/public repo** (scrub secrets from history first) | ❌ MISSING — blocker |
| **Install one-liner** (brew / curl\|sh) | ❌ MISSING — blocker |
| **README with a demo GIF above the fold** | ❌ MISSING — highest-leverage asset |
| **60-sec demo video** (OpenAI plans → DeepSeek codes → Gemini reviews + live cost meter) | ❌ MISSING |
| **Docs**: quickstart + BYOK key setup | ❌ MISSING |
| **Telemetry stance** (opt-in, stated loudly) | ❌ decide — we currently send none; say so |
| **`mythos doctor`** key validator (10 providers = 10× key footguns) | ⚠️ GAP |
| **Budget ceiling ON by default** + dry-run cost estimate (avoid demo bill-shock) | ⚠️ verify |
| **Name cleared** on npm/brew/GitHub; avoid Claude-trademark-adjacent identity (claude-flow→Ruflo) | ⚠️ verify |
| Users / dogfood proof | ⚠️ GAP — "I ship N products with this" is the Goose-style substitute |

Everything in the "missing" column is **days of packaging work, not Phase 4/5 features.**

---

## 2. Positioning (lead with the critic + the team; cost is now table stakes)

Per-vendor cost tracking is **becoming commodity** (Goose ships it native; gateways everywhere) — so
don't lead with "observability." Lead with the two things still un-replicated:

1. **"A team of rival vendors, one loop."** Not one model at a time (OpenCode) — *different vendors
   with different jobs simultaneously, sharing one state*. Demoable, not commoditized.
2. **"A typed plan you approve + a verify-the-goal critic = it won't pretend it succeeded."** The
   typed-DAG validate/repair + LLM goal-critic + honest-fail is the **single most defensible,
   un-replicated asset** (Goose has adversarial *review*; nobody has goal-state verification gating a
   *typed DAG*). This is a *trust/correctness* story, not a "framework" story.
3. **Cost as the Trojan horse, stated as a nuance:** "in-loop, per-role budget ceiling that
   hard-stops" (rivals push budgets to an external gateway). Rides the token-shock headlines.

**Never pitch:** "agent framework," "orchestration platform," "swarms" (framework fatigue is real;
claude-flow owns the swarm language + the SWE-bench-number game).

The one-liner: *"Claude Code runs one vendor's model. Mythos runs a team of rival AI vendors as
teammates in one loop — OpenAI plans it, DeepSeek writes it, Gemini reviews it — with a typed plan you
approve and a per-vendor cost meter so you see exactly who spent what."*

---

## 3. The launch sprint (concrete, ~1–2 weeks, mostly not feature work)

**A. Packaging (blockers):**
1. **LICENSE** — decision: Apache-2.0 (patent grant + enterprise comfort; defensible for an
   AI-orchestration tool) vs MIT (max reach). *Recommend Apache-2.0.*
2. **Scrub secrets from git history, push** the branch to a public repo. Verify the name is clear.
3. **README** with a demo GIF above the fold + the one-liner positioning + the 315-tests/CI badge.
4. **Install one-liner** (brew tap and/or `curl | sh`). The static Swift binary helps.
5. **Docs**: a quickstart + a per-provider BYOK key page.
6. **60-sec demo video**: the 3-vendor loop + the live per-vendor token trace + `--budget`.

**B. Cold-start hardening (so a stranger's first run works — the MLP bar):**
7. **`mythos doctor`** — pings each configured provider key, clear pass/fail (kills the 10-provider
   key-footgun rage).
8. **Budget ceiling ON by default** with a sane cap + a dry-run cost estimate before execute (so a
   demo user never eats a surprise bill — fatal for a cost-control pitch).
9. **Telemetry: none, opt-in only, said in the README.** (GitHub CLI's silent opt-out telemetry drew
   419 pts / 302 furious HN comments — this is the one thing that can hijack the whole thread.)

**C. The proof asset (the demo's credibility, also the eval harness):**
10. A small **same-harness A/B**: Arm A = best single model; Arm B = **budget-matched** single model
    (controls for "team win = just more compute"); Arm C = heterogeneous team; optional Arm D =
    homogeneous team (isolates vendor-diversity vs role-structure). Tasks: **30–60 private authored
    tasks** (contamination-immune) + an **Aider Polyglot subset** (~$1–30, low contamination).
    Verdicts from **sealed build/test gates** (strip git history, deny network), never self-report.
    Report **quality-per-dollar (Pareto), per-task outcomes, and WHERE IT LOSES**, with transcripts.
    The honest frame (publish this, don't over-claim): *"a heterogeneous team isn't a general
    upgrade; it pays its 3–8× token premium only on decomposable, gate-verifiable tasks — especially
    a cross-vendor reviewer — and loses to a budget-matched single model on tightly-coupled or
    reasoning-bound work. Here's the per-task data showing both."*

**D. Launch day:** Show HN with the demo GIF; founder lives in the thread, agrees-first with critics,
no sock-puppets.

---

## 4. After launch (steered by feedback, not before)

- **Phase 4 (minimal memory):** project-facts file (build/test commands = highest-value) + episodic
  run-log (write at end, inject at start), plain files mirroring Claude's memory-tool shape. ~80% of
  felt value, days. The **verified-skill library stays a critic-gated PROTOTYPE** (our typed-schema
  retrieval + reused critic is ahead of vector-similarity incumbents; add **re-verify-on-reuse +
  provenance/expiry** to fix store-time-only trust — the OWASP ASI06 memory-poisoning vector).
- **Phase 5 (supervised fan-out):** still the settled design (parallel read frontiers, serialized
  single-writer via worktree lease, merge = critic-gated, carry decision-trace, cap ≤5–7) — but **now
  safe** because observable + cost-bounded, and **demand-validated** by launch feedback.
- **Interop:** speak MCP (have a client) + AGENTS.md; consider an A2A adapter (be a node in the
  federated mesh, ride the rails, don't rebuild them).

---

## 5. Risks at launch
| Risk | Mitigation |
|---|---|
| Telemetry backlash | none by default, opt-in, stated in README |
| Demo cost surprise (ironic, fatal) | budget ceiling ON by default + dry-run estimate |
| "Yet another agent framework" fatigue | ruthless wedge discipline; lead with team+critic, never "framework" |
| BYOK key footguns × 10 providers | `mythos doctor` pre-flight validator |
| Name/trademark (claude-flow→Ruflo) | clear the name; keep "Claude Code but…" as comparison copy, not identity |
| Cold-start flakiness on a stranger's box | test BYOK cold-start on a clean machine before launch |
| Over-claiming the team win | publish the A/B with losses + cost; never a public-benchmark SOTA number (radioactive post-Berkeley) |

---

## 6. Decisions only Luke can make (these now gate the critical path)
1. **Ship now (packaging sprint) vs keep building Phase 4/5?** — research strongly says ship.
2. **LICENSE:** Apache-2.0 (recommended) vs MIT vs GPL.
3. **Go public** — push to a public repo now (after secret-scrub)?
4. **Name** — keep "Mythos"? (clear it on registries; avoid Claude-trademark-adjacent identity.)

---

## 7. Caveats on this research
- **Reddit blocked again** (env) — Reddit sentiment is secondhand. Star/adoption numbers are
  order-of-magnitude (sources disagree: OpenCode 160–178k, Goose 27–48k, Ruflo 31–59k).
- **All memory/benchmark vendor numbers are self-reported and routinely inflated** (Zep's 84%→58.44%
  correction is the proof) — none are decision-grade; we weighted primary docs / arXiv / OWASP / the
  GitHub disputes over SEO blogs.
- The "315 tests / live-proven" basis is ours and real, but the SHIP verdict assumes a **cold-start
  BYOK run works for a stranger** — verify on a clean box before launch.

---

## 8. Bottom line
We are **product-ready and packaging-unready**, at a moment when the market is unusually hungry for
exactly our strongest axes (cost control + a trustworthy multi-vendor loop) and our competitive window
is open but closing. The highest-value next move is **not another phase — it's the launch surface +
an honest proof**, then let real users steer Phase 4/5. The two decisions I've parked all session
(LICENSE, push the branch) are no longer housekeeping — they're the critical path.
