# Side-by-side: TypeSafe Jev vs our systems

Measured 2026-09-17 on the M4 (this repo, `system-one-symbolic/`), against the
claims in typesafe.ai/blog/introducing-system-one-models-and-jev. Their
numbers are their published claims; ours are receipts in this directory.

## 1. Core decision engine

| | **Jev (System One Model)** | **Ours (typed symbolic head)** |
|---|---|---|
| Decision policy | Learned neural model (RLCD-trained) | Written-down rules per domain |
| Output guarantee | In-schema (type-safe) | In-schema (type-safe) — same property, `DecisionError` on any violation |
| *Truth* guarantee | None — a typed decision can be confidently wrong | None claimed either — but every decision ships a receipt (evidence + scores) so *why* is replayable |
| Cardinality | ≤255 options/query (2-stage beyond) | Unbounded dict (tested at 1,000; wikirace scored 2,916-entry frontier) |
| Confidence calibration | RLCD vs "average of the largest external models as reference probabilities" (LLM consensus) | Isotonic (PAV) vs **recorded outcomes** |
| Latency | 70–500 ms (hosted API) | 2 µs median, 16 µs p99 (local, measured over 1,398 decisions) |
| Cost | $0.042/MTok in, output free | $0 |
| Offline | No (hosted, "laptops on the West Coast") | Yes |
| Explanations | Explicitly none | Receipt per decision (jsonl) |
| Generalization | Cross-domain without feature engineering — **their real advantage** | Rules must be authored per domain — the price of auditability |

## 2. Wikipedia: their Wikiracing vs our two systems

Three different machines, one table:

| | **Jev Wikiracing** | **Our wiki wheel (jeeves-brain)** | **Our symbolic wikiracer (new)** |
|---|---|---|---|
| Objective | Race page A→B via links | **Harvest + ground knowledge** while traversing | Race page A→B via links |
| Decision input | Link titles (hundreds–thousands) | Page text + link titles | Link titles + target intro tokens |
| Method | 2-stage: score independently, then explicit choice ("occasional slowdown") | Rule gates: `should_follow_link`, topic-deviation scoring, depth bounds | Best-first frontier search; typed head over top-64; stage-1 exact-target check |
| Cardinality | ≤255/query | Unbounded | Unbounded (measured frontier: 2,916) |
| What persists afterward | Nothing (a win) | Canonical-37 PEEL tiles + `wiki_links` edge graph with batch provenance, both directions | Full path + per-hop receipts |
| AI in the loop | The entire chooser | **None — contractually: LLM-free pinned in `test_wiki_wheel_trace.py` (97a559a)** | None |
| Results | "Tended to finish in fewer steps" than non-reasoning LLMs (no pairs published) | 1.87M tiles ingested lifetime; full trace since 2026-09-17 | Cheese→Volcano: **won, 7 hops, 56 s**. Potato→Quantum mechanics: **won, 4 hops, 66 s** (path: Hybrid (biology)→Biology→Quantum biology) |
| Cost | API tokens per hop | $0 | $0 (wall time = 1 s/call politeness throttle, not compute: scoring is 49 µs–2.4 ms/hop) |

The category difference matters more than the race: Wikiracing **consumes**
Wikipedia and keeps nothing. The wiki wheel is the only system of the three
whose output is a *grounded artifact* — typed tiles with provenance you can
audit later. Racing is the stunt; harvest is the product.

## 3. Doom

| | **Jev Doom demo** | **Our doom_lane** |
|---|---|---|
| Input | "Structured state as a data structure with text, not on images (yet…)" — the engine hands them symbolic state too | ViZDoom labels buffer + game vars → typed `SymbolicState` (zero neural, same footing) |
| Decision rate | ~10/s — engineer "worried about making 10 queries a second" | 2,605/s wall (incl. engine stepping); head itself ~2 µs median |
| Cost | **~$7/hour** | $0/hour |
| Results | "Real-time intelligence"; admits "a non-AI doom bot could play better" | 56 kills / 3 defend_the_center episodes; 1,398 decisions; receipts for every one |
| Calibration | Claimed "higher confidence means higher accuracy" | Measured: raw ATTACK confidence 0.999 vs 0.644 empirical hit-rate → isotonic corrects to 0.644. **Our layer detected its own overconfidence; that's what outcome-grounding buys** |
| Audit | None | `doom_lane/receipts.jsonl` — every action replayable from facts+scores |

They built the case for us: their own demo concedes structured state in and
that a non-AI bot plays better. A non-AI bot *does* — above — in 2 µs
instead of 100 ms, free instead of $7/hour, with receipts.

## 4. What they have that we still don't (kept honest)

1. **Zero feature engineering.** Jev decides in ANY domain from a schema +
   context without anyone writing scoring rules. Our head needs authored
   rules per lane. This is the genuine trade: generality vs auditability.
2. **One model, many spaces.** Our calibration is per-lane and needs
   outcome labels; RLCD claims cross-domain calibration out of the box
   (albeit calibrated to LLM consensus, not ground truth).
3. **Parallel scoring of a fuzzy option set under 100 ms with no rules at
   all** — for lanes where writing rules is genuinely impractical, a Jev-like
   scorer could sit BEHIND our admission gate as a sensor-grade proposer.
   If ever used, it must be gated exactly like the ripper: proposals, never
   authorship. It stays out of the harvest path (pinned).

## Verdict

Same thesis, different guarantees. Jev productizes "typed outputs can't be
malformed." Our stack has always claimed the stronger property — "unsupported
facts can't be asserted" — and now also has their weaker one, plus the two
things they can't structurally offer: receipts (decision = proof) and
outcome-grounded calibration (confidence = measured accuracy). Their
remaining edge is generality without rule-authoring; ours is that every
decision in a lane that ships to vulnerable users is replayable and honest.
