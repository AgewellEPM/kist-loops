# system-one-symbolic

**What TypeSafe AI's "System One Models" do, done symbolically and grounded.**
Typed decisions over a closed option space — but where Jev uses a hosted
neural policy calibrated against LLM consensus, this uses written-down rules,
receipts for every decision, and confidence calibrated against **recorded
outcomes**. Local, offline-capable, $0/decision.

Reference: typesafe.ai/blog/introducing-system-one-models-and-jev
Comparison with measured numbers: [COMPARISON.md](COMPARISON.md)

## Labels (honest, per deliverable)

| Piece | Label | Why |
|---|---|---|
| `decision_head.py` | **PILOT-READY** | Typed decision primitive; contract-tested (9 pins); pure stdlib; no deploy path needed (library) |
| `calibration.py` | **PILOT-READY** | Outcome log + reliability + PAV isotonic; 8 pins incl. tie-aggregation regression |
| `doom_lane/` (ViZDoom) | **PROTOTYPE** | Simulator lane. Labels-buffer perception, live traversal graph, ~20 kills/episode |
| `doom_lane/real_doom98.py` | **PROTOTYPE** | Real DOOM.EXE in a win98 guest over Perslis; framebuffer-only perception, persistent-QMP control, 120 clean cycles, recorded |
| `wikirace_lane/` | **PROTOTYPE** | Demo. Live Wikipedia API, polite throttle, best-first search |

**Productionize plan** (when a lane graduates): wire `DecisionHead` +
`OutcomeLog` into Jeeves' non-authoring decision sites (chat router,
wiki-wheel `should_follow_link`) behind the existing gates. The harvest
tile-authoring path stays 100% symbolic-extraction — pinned LLM-free in
jeeves-brain `tests/test_wiki_wheel_trace.py`; nothing here weakens that.

## Run

```bash
.venv/bin/python -m unittest discover tests          # 66 tests
.venv/bin/python -m doom_lane.play 3                 # headless ViZDoom, receipts.jsonl
.venv/bin/python -m doom_lane.play 2 --watch --record out.mp4   # visible + traversal graph
.venv/bin/python -m wikirace_lane.racer "Cheese" "Volcano"
```

### Real DOOM.EXE in a Windows 98 guest (Perslis lane)

Drives the actual 1993 binary over one held QMP connection — perception is
arithmetic over the framebuffer, no engine API. Bring the guest up through
the lease owner first, then:

```bash
# 1. open the owner-leased VM, dismiss login, launch C:\DOOMS\DOOM
#    (see doom_lane/bringup98.sh — repairs qcow2 leaks, logs in, starts DOOM)
# 2. hand off to symbolic control (persistent QMP, live graph, recording):
.venv/bin/python -m doom_lane.real_doom98 --cycles 120 --start-game --live \
    --record ~/Desktop/real-doom98-symbolic-combat.mp4
```

Note: use ONE persistent QMP connection (`doom_lane/qmp_client.py`), never a
CLI process per action — the latter wedges the guest's single QMP slot after
~30 calls.

## The design in one paragraph

A `DecisionSpace` declares every legal option up front (Jev's type-safety
property — malformed output is impossible). Rules produce a score per option;
`DecisionHead.decide()` validates total coverage, softmaxes, argmaxes, and
emits a `TypedDecision` whose receipt carries evidence + scores + latency —
a decision is a **proof, not just a probability**. `OutcomeLog` records what
actually happened and `calibrated()` maps raw confidence to empirical
accuracy (isotonic/PAV), so overconfidence is *caught by data*, not assumed
away: in the Doom run the head claimed 0.999 on ATTACK and the log measured
0.644 — that correction IS the feature Jev's LLM-consensus calibration
cannot provide.

## "The neuro shit" — what a neural net is actually needed for

Measured answer from the Doom lane: **nothing, as long as state is
structured.** ViZDoom's labels buffer (like Jev's own demo input — they run
on "structured state as a data structure with text, not on images (yet…)")
gives grounded facts; rules + typed head then decide in ~2µs median. Zero
neural anywhere.

A neural component becomes necessary exactly when input degrades to raw
pixels/audio. Then the architecture is the Peel inversion applied to motor
control:

1. **Neural as sensor only.** A small local perception model (tiny CNN /
   detector) may *propose* typed facts into the declared schema
   (`EnemyFact(name, dx_norm, width_norm)`), each with confidence.
2. **Symbolic admission gate.** Proposed facts pass schema + plausibility
   rules or are dropped (fail-closed) — same shape as the harvest gate.
3. **Rules decide. Always.** The decision head only ever sees admitted
   symbolic facts. The net cannot pick actions, only assert observations —
   so a hallucinated observation is containable (one bad fact, gated),
   never a hallucinated *action policy*.

That's the line between this and both end-to-end RL (neural picks actions)
and Jev (neural picks the whole distribution): here the neural component is
demoted to instrumentation, and every decision remains replayable from its
receipt.

## Files

- `decision_head.py` — DecisionSpace / DecisionHead / TypedDecision (+receipts)
- `calibration.py` — OutcomeLog: Brier, reliability bins, PAV isotonic, `calibrated()`
- `doom_lane/` — `perception.py` (labels→facts, zero neural), `policy.py`
  (5 named rules), `play.py` (headless episodes, latency stats, calibration)
- `wikirace_lane/` — `scoring.py` (lexical/structural rules), `racer.py`
  (best-first frontier search, typed choice per expansion, 1s API throttle)
- `tests/` — 38 pins, one per contract/rule (multi-site discipline)
