# kist — Strategic Roadmap

**Owner:** Luke · **Lead (strategic authority delegated):** Claude (Fable) · **Reviewed by:** 5-model council (Codex/gpt-5.5, GPT-4o, DeepSeek-Reasoner, Grok-3, Gemini) · **Date:** 2026-07-03

> Luke handed strategic ownership to the lead engineer: *"I have no idea what I'm doing... you understand the vision, you understand the architecture, you have the consensus of minds — I need you to strategically decide, plan it out, research the next phases."* This document is that plan. The council was convened specifically to pressure-test it. Their verdict was near-unanimous, and it **changes our sequencing**.

---

## The one hard truth (read this first)

**We have been building the roof before the walls.**

This session built a complete, council-hardened computer-use subsystem and a large amount of self-improving-Captain substrate. That work is real and it is good. But all 5 council models, independently, said the same thing:

> The critical path is **adoption first** (install → reliable wow → routing → persistence). Serious investment in the self-improving Captain should **not** happen until the product is used daily — otherwise the improvement loop optimizes for toy tasks and you prove nothing.

In plain terms: **nobody will ever see the self-improving Captain if they can't install kist and watch it succeed once.** The computer-use stack and Captain machinery are Phase 4–5 capability. The thing with 10× the leverage right now is Phase 1: a bulletproof zero-config install and **one** task it completes *every single time* on a fresh machine.

**This is not wasted work.** The council reconciled the two visions for us: the Phase-1 "wow" *should be* a computer-use demo (Grok and Gemini both said this unprompted — "open Xcode, create a SwiftUI project, add a button that prints hello"). The "watch the Fallout man walk" moment and the adoption moment are the **same moment**. We make computer-use the hero of the front door instead of a deep capability nobody reaches.

So the strategic call I'm making as lead: **stop adding Captain capabilities. Make the front door bulletproof. Turn what we built into the demo that sells it.**

---

## The blunt part — what we've been underestimating

The council was asked to be blunt about what the owner/lead is missing. Every model hit the **same** nerve:

1. **The chasm between "working machinery" and "reliable product."** We have a garage full of perfectly engineered parts. That is not a car. The gap between "works in tests / works on my machine" and "works unattended for 30 minutes on a stranger's Mac" is enormous and is 90% of the remaining work. Our 2260 green tests measure the parts, not the drive.
2. **BYOK is real friction, not a footnote.** Users get stuck on API keys, quotas, billing, "which model." The "5-minute wow" has to assume **zero** prior API experience. We need a no-credit-card test path (e.g. a cheap/free-tier model) or the wow dies at the key prompt.
3. **Computer-use is a maintenance liability, not a finished feature.** CGEvent / Accessibility trees / Moondream break on OS updates. "Hardened" ≠ "done" — it needs a recurring CI job that pokes supported macOS versions, plus notarization + permissions + entitlements for a distributable computer-use binary. Grok flagged distribution mechanics as the thing most agent projects never solve.
4. **Proving self-improvement honestly is hard.** It's trivial to overfit to a small test set and declare victory. The meta-loop must be evaluated on a hold-out it *never sees*, or the benchmark becomes a leaky pipe.

I'm putting these in writing because a label is worthless the moment it's aspirational. Today's honest label for the whole system is **PROTOTYPE** — impressive components, unproven as a product. Everything below is the path to earning a real tier.

---

## The phased roadmap

**Critical path: Phase 1 → 2 → 3 are adoption gates and must ship before serious 4–5 work. Phase 3.5 (instrumentation) is the bridge; it's cheap and unlocks 4–5, so it runs in parallel from Phase 2 on.**

### Phase 1 — "First Contact": the bulletproof wow
- **The one outcome:** On a clean Mac, a user installs kist with one command, gives it **one** well-defined task, and kist completes it end-to-end, verifiably, in under 5 minutes — *every time*.
- **Concrete shape:** `brew install kist` (or `curl | sh`) → `kist "add a button to this SwiftUI app that prints hello"` → working, visible result. Make computer-use the hero if it's reliable enough; otherwise a pure code task first, computer-use as the second demo.
- **Why first:** Every other priority is irrelevant without users who can run it. This is owner priority #1 and #2 (simple-task routing) fused.
- **Biggest risk:** Over-scoping "simple." One narrow, high-confidence task done flawlessly beats five flaky ones. A flaky wow is worse than no wow.
- **Includes:** self-contained binary (no "install Xcode CLT first" surprises), a no-key/cheap-key test mode, first-run permission flow for computer-use, honest error messages on the key/quota path.

### Phase 2 — "The Workhorse": routing users actually feel
- **The one outcome:** Simple edits respond in ~2s; moderate tasks get one planning step; genuinely complex tasks escalate to the pipeline. Measured: TaskRouter + EffortController route ≥80% correctly on a 100-task internal corpus, and the user *feels* lower latency/cost on easy work.
- **Why here:** This is the qualitative difference vs. Claude Code / Cursor — otherwise kist is "an expensive wrapper." TaskRouter already exists; this phase is **wiring + tuning**, not new invention.
- **Biggest risk:** Over-confident routing sending a hard task to the fast lane and destroying trust. Mitigation the council pushed: use cheap **static heuristics** (file count, diff size, function count) *before* LLM-based scoring.
- **Lead decisions already made (see below):** fast-lane = lean loop; wire opt-in first, default-on after the modularize branches land.

### Phase 3 — "The Persistent Professional": background + local
- **The one outcome:** Kick off a long task, close the terminal, come back, `kist resume` shows the result or continues. Plus: simple tasks work on a local model when offline / for privacy, with an honest degradation message (never silent failure).
- **Why here:** Removes the "I have to keep my laptop open" objection (#4) and serves offline/privacy users (#5). Last phase that directly serves adoption before differentiation.
- **Biggest risk:** State corruption / partial edits on resume. Mitigation: transactional log + checkpoint on every significant action (tool call, file write), atomic restore with rollback. The signoff ledger helps but isn't sufficient alone.

### Phase 3.5 — "Clean Traces" (the bridge, runs parallel from Phase 2)
- **The one outcome:** Every run emits a structured, queryable, replayable trace: routing decision, EffortController score, specialists used, tool calls, where it failed, final outcome (pass/fail, time, retries).
- **Why this is separate and early:** Grok's sharpest insight — **the self-improvement loop is downstream of having clean, attributable data.** Build the instrumentation while real usage accumulates, so Phase 4 improves on *real* traces, not synthetic ones. Cheap to build, and it's the single prerequisite for the entire differentiation bet.
- **Biggest risk:** None significant. This is the highest-ROI Captain-side move available right now (see B).

### Phase 4 — "The Captain's First Lesson": the minimum-viable self-improvement loop
- **The one outcome:** kist detects one recurring failure pattern, proposes one concrete testable change to its own routing/effort rules or a reusable skill, validates it on a held-out set, and **measurably** improves its success rate on that pattern.
- **Why here:** First tangible step to the vision — contained and measurable, not a rewrite. Requires Phase 3.5 traces + real usage.
- **The loop (council-converged design — all 5 described the same thing):**
  1. **Capture** — serialize every task's full trace + outcome (Phase 3.5).
  2. **Meta-review** — a meta-agent reads the trace and proposes **one** structured, atomic improvement (e.g. "when the error is a missing import, run the installer before editing"). Stored as a versioned rule / Agent Skill in EffortMemory.
  3. **Validate** — run the candidate against a small **held-out** set of past similar tasks the meta-loop never trained on. Promote only on a statistically clear lift (e.g. ≥5% success or ≥20% fewer correction loops). Otherwise discard.
  4. **Incorporate** — versioned, timestamped, rollbackable. Never a blind merge.
  5. **Prune** — every N tasks, drop rules that didn't help.
- **How we PROVE it (non-negotiable):** a fixed benchmark suite, run before the loop is enabled and after ~100 real tasks. Improvement is *only* real if the lift shows on the held-out set. A public before/after diff + the exact config change that produced it = proof. Anything else is a demo.
- **Biggest risk:** Catastrophic forgetting / overfitting to the eval. Mitigation is the held-out discipline above.

### Phase 5 — "The Specialist Architect": organizational self-improvement
- **The one outcome:** Given an unfamiliar domain, kist researches it, identifies missing specialist roles, defines and integrates them, and shows a measurable lift on subsequent tasks in that domain. This is the full "improves its own organization" vision.
- **Why last:** It builds directly on Phase 4's proven loop, applied to the *structure* of the fleet. Proving causality (was it the new specialist, or just more attempts?) is the hard part.
- **Biggest risk:** Combinatorial explosion of specialists; an internal structure that's complex without being better.

### Phase 6 — Benchmarks, demos, community (ongoing, starts after Phase 3)
- Public SWE-bench (+ human eval + internal suite — never a single benchmark), 3–5 reproducible one-command demo repos, a triaged feedback channel with real engineering time allocated (~10% from Phase 2 on). Benchmarks are a **marketing tool after you have users**, not a way to get them.

---

## (B) The single highest-leverage move on each axis

- **For adoption:** Phase 1, ruthlessly narrowed. Pick one task type, make it succeed on every fresh install within 5 minutes. This is the viral "holy shit" moment; everything else is a harder sell without it.
- **For the self-improving Captain:** **Phase 3.5 instrumentation** — clean, attributable before/after traces on the EffortController + TaskRouter decision points. It's the only data source that can ever drive genuine organizational improvement, and it's cheap. Everything in Phase 4–5 is downstream of it. This is the one Captain-side thing worth doing *now*, in parallel, because it doesn't block adoption and it de-risks the entire differentiation bet.

---

## (D) What we will NOT build (council-unanimous traps)

- **Generic sub-agents** ("Planner Agent," "Coder Agent"). We have purpose-built specialists — that's the superior design. Keep them focused and tool-rich.
- **A custom IDE / GUI / web dashboard** before the CLI is great. Massive maintenance multiplier, distracts from core reliability. Terminal + existing tools (Xcode/VS Code) first.
- **Self-modifying source code.** That's a research project, not a product milestone — it will burn months for negative reliability. Phase 4–5 change *rules and skills*, never the agent's own source.
- **Benchmark-chasing before Phases 1–3.** No users → benchmarks are vanity.
- **Custom base models, blockchain/decentralized compute.** No differentiation, pure time-sink.
- **Vision-as-primary.** Accessibility grounding is the moat; Moondream vision stays a narrow fallback. (Validates the grounding-first work already done.)

---

## Lead decisions I'm making now (so Luke doesn't have to)

These are the tactical calls Luke correctly declined to make — they're mine:

1. **Fast lane = lean loop.** The `.fast` route runs: economy model tier + read-only tools only + a low iteration cap + async/skipped heavy memory retrieval. It's for "what does this function do?"-class questions, nothing that mutates.
2. **TaskRouter wiring is Phase 2, not urgent.** It wires into `KistRunner.run()`, which is a 1860-line monolith that 6 of 7 active branches are already editing (merge-hostile). So: land it **opt-in behind a `--smart` flag** first (low collision), flip it **default-on** after the `kist-modularize` / `integration/kist-modularized` branches merge and the tree quiets. Do not rush a monolith edit into a collision zone for a Phase-2 feature.
3. **The KistRunner split waits for the modularize branches** — re-implementing it now duplicates in-flight work. Coordinate, don't collide.
4. **The computer-use live run stays gated on Luke's host setup** (Accessibility + Screen Recording perms + Moondream key). It becomes the Phase-1 demo candidate once proven on a real machine.

---

## Immediate next actions (in order)

1. **Prove the front door.** Define the ONE Phase-1 wow task and a clean-machine install path. This is the next real increment — not another Captain capability.
2. **Build Phase 3.5 instrumentation in parallel** — structured run traces. Cheap, unblocks everything on the differentiation side, zero adoption cost. Strong candidate for the next council-reviewed increment because it's low-collision (new files, like the parser and computer-use work were).
3. **Everything else waits its turn.** No new tools, no self-improvement loop, no benchmarks until 1–3 are real.

**Standing rule:** every increment is council-reviewed before it's called done. The fleet is never armed or auto-merged without Luke's explicit say-so.
