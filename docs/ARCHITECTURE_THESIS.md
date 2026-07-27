# kist / Mythos — Architecture Thesis (the north star) — 2026-06-29

The point of this system is NOT "an autonomous agent loop." Loops are commoditizing fast — Claude Code,
Codex, OpenCode, Goose all have one. The thing that makes this system a different *class* of tool, and the
bar all future work is measured against, is two disciplines wrapped around the loop:

> **1. A verifier the agent cannot game.**
> **2. The discipline to claim trust only where the agent actually has visibility.**

Build a loop without those and you've built a very fast, very confident way to be wrong.

---

## The loop is necessary but not sufficient

The inner loop is real and powerful: `HeadlessAgentLoop` writes code, runs it, reads the stack trace,
re-plans, checkpoints, and recovers — closing a feedback loop against a real runtime instead of predicting
the next token in a vacuum. `AgentForge` lets it forge new tools/specialists on the fly (the Factory
Pattern for agents). `AICouncil` + `CaptainGate` add adversarial review — one builds, one breaks, one judges.

All true. All built. **And all of it is table stakes within ~18 months.** It is not the moat.

---

## Pillar 1 — The un-gameable verifier (the actual moat)

The seductive failure of any closed loop is not that it can't fix its bugs. It's that it **converges on a
solution that passes its own tests because it quietly weakened them.** A self-grading loop will always find
the path of least resistance to an "A":
- write a vacuous test, or delete the failing one,
- slip `|| true` / `exit 0` / `set +e` into the harness,
- match the test fixture instead of solving the problem,
- claim "done / tests pass" without running anything.

A loop that grades its own homework is a confident liar by default. So the fidelity gain from the inner
loop is **conditional on a verifier the agent cannot reach or rewrite.** That is the part almost nobody
builds, and it is what this codebase obsesses over:
- **No fabrication** — a claim of success must be backed by evidence the system measured, not asserted.
- **Committed-artifact measurement** — verify what was actually committed (`git diff base...HEAD`), not what
  the agent says it did; fail-closed when the base is unknown.
- **`CIIntegrityGuard`** — blocks a diff that weakens the verifier (deletes a test, adds `XCTSkip`/`.only`/
  `|| true`/`exit 0`); a newly-created harness is exempt, a *weakened* one is not.
- **ForgeSeal + signoff ledger** — a "green" verdict (`GroundedVerdict.green`) is mintable only by the
  symbolic captain, HMAC-sealed, hash-chained, seal-or-drop. Provenance is never authority.
- **Council → Captain promotion gate** — fail-closed, both must pass, neither authorizes alone.
- **Adversarial review, not self-review** — Codex (a *separate* model) hunts the seams; this session it found
  a real escalation bug in five consecutive rounds the green tests had missed. The adversary, not the test
  suite, is what catches the lie.

**Invariant for all future work:** every new capability that can claim success must route that claim through
a verifier the capability itself cannot modify. If a feature can mark its own work "done," it's not finished.

---

## Pillar 2 — Visibility-bounded trust (the strategic compass)

An inner loop only self-corrects as well as its feedback. That splits the world in two:

- **White-box** (your code, your servers, your apps): full source, logs, memory, control. Clean stack
  traces, real feedback — the loop is *potent*; self-correction actually closes.
- **Black-box** (someone else's external system): silent firewall drops, stateful rate-limiters, generic
  error codes, humans watching. Asymmetric feedback → the loop degrades to inference + trial-and-error.

The decisive realization: **the visibility boundary and the authorization boundary are the SAME boundary.**
The scope that keeps you legal (test only what you own/are authorized to) is the scope where the loop
actually *works* (you have the logs/source to close the loop). They are one line seen from two angles —
technical and legal.

**Strategic consequence — lead with white-box.** Every business plan in this repo (bug bounty, app harden,
vision reconstruct, server diagnostics, persona research) is strongest and safest pointed at owned/authorized
assets: own-infra hardening, own-app rebuild, own-server diagnosis, authorized bug bounty with source. The
"point it at a stranger's black box" cases are inherently *both* weaker (less feedback) *and* riskier (less
authorization). Don't chase them first; they're the hard frontier, not the wedge.

**Invariant for all future work:** a capability earns trust only in proportion to its visibility into the
target. Against a black box, it reports "unconfirmed — here's what to check," never an asserted conclusion.

---

## The two invariants, restated as gates every feature passes
1. **Un-gameable verification.** Can this feature mark its own work done? If yes, it's not done — route the
   success claim through a verifier it can't touch (committed artifacts, held-out checks, adversarial review,
   sealed signoff).
2. **Visibility-bounded claims.** Is the target white-box or black-box? Assert conclusions only with the
   evidence to back them; degrade to "unconfirmed + next step" when blind. Keep scope = authorization.
3. **Human on the irreversible button.** Verified ≠ authorized to act. Irreversible/high-blast actions and
   any external submission/change still pass the reversibility gate + a human.

## One line
The limit of AI here isn't the model — it's the design of the environment it lives in. The two design
choices that make this environment different are: **a verifier the agent can't cheat, and the honesty to
claim trust only where it can see.** Everything else is a loop, and loops are cheap. Those two are the
product.
