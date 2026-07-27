# Autopilot + Promotion policy — sandbox-always → council → captain-OK

**Luke's policy (2026-06-28):** *"Everything should always run through a sandbox until a
council of minds decides it's real, worth going live. Nothing should ever be pushed
without a captain's OK — AI-style."*

This is the trust spine stated as an operating rule. Two halves: (A) hands-off execution
is **isolated**, never raw; (B) leaving isolation ("going live") requires **council
judgment + captain sign-off**.

---

## A. Autopilot = autonomy bought with isolation (SHIPPED)

`--auto` / `--danger` (PILOT-READY): hands-off, no prompts, but **forced sandbox**.

- Implies `--yolo` (no approval prompts) + `--allow-shell` + **`--sandbox` forced on**
  (normalized in `KistOptions.parse`; cannot be disabled in auto mode).
- **Fail-closed:** Seatbelt is macOS-only; on a platform with no OS sandbox the wrap
  returns `.unavailable` and `run_command` REFUSES rather than run raw (`SeatbeltSandbox`).
  So "everything runs sandboxed" is enforced by *refusing to run unsandboxed*, not by a
  best-effort flag. **Linux autopilot shell is therefore blocked until the Linux tier
  (bubblewrap+seccomp) lands — by design.**
- Unmissable red banner in the REPL so armed-mode is never a surprise.
- Pinned: `KistOptionsTests.testAutoImpliesYoloShellAndForcedSandbox` (+ alias, + the
  negative: `--yolo` alone never forces a sandbox).

**What `--auto` deliberately does NOT do:** it does not arm the fleet to auto-merge into
`main`. The fleet already runs each agent in an isolated worktree and joins only
captain-signed branches onto a fresh integration branch — it NEVER writes main. Autopilot
removes the *human-approval* gate; it does not remove the *trust* gates.

---

## B. Going live = council + captain (the gate to wire next)

"Going live" in kist today = **merge to `main`** (there is no `git push` surface). That
merge is the promotion boundary and must be the captain/council boundary.

### What already exists
- **Captain sign-off:** `Foreman` verify-and-sign → `FleetSignoffLedger` (ForgeSeal
  HMAC, hash-chained, seal-or-drop). `joinSignedBranches` REFUSES unsigned / off-lease
  branches. `GroundedVerdict.green` is private-init — only `SymbolicCaptain` can mint it.
- **External attestation gate:** `FleetPromotionGate.decide` (FAIL-CLOSED) — integration→
  main needs internal-ready AND a valid Ed25519 attestation bound to this build + an
  unconsumed replay key.
- **Council of minds:** `AICouncil.run(goal)` → N minds (role-bound, different vendors) →
  `CouncilRunResult`. **Today it's a PLANNING council, not a promotion judge.**

### The gap → the build
A single **promotion decision** that fuses council judgment + captain sign-off before any
merge-to-main:

1. **`CouncilPromotionVerdict`** — extend/添加 a council pass that JUDGES a finished
   integration branch ("is this real? worth shipping?"), not just plans it. Each mind
   votes on the *built+verified* result (diff + test status + signoff ledger), returns
   real/not-real + reasons. Majority (or stronger) required.
2. **`CaptainGate`** — the promotion is allowed ONLY when BOTH hold:
   - council verdict = real/ship-worthy (B1), AND
   - captain sign-off present + valid (`FleetPromotionGate.decide` passes: internally
     ready + Ed25519 attestation + unconsumed replay key).
   FAIL-CLOSED: missing/with either → NO-GO. Never writes main itself — returns GO/NO-GO;
   the human (or an explicitly-armed promoter) performs the merge.
3. **Trust invariants (per the seam-hunting lesson — pin each, don't assume):**
   - Council verdict is ADVISORY *input* to the gate; it can only ever make promotion
     STRICTER, never bypass the captain sign-off. (Memory's authority rule: a verdict
     source confers no trust on its own.)
   - The build id the gate judges must be a TRUSTED id (HEAD SHA / sealed manifest),
     never user input (the documented `FleetPromotionGate` wiring constraint).
   - One regression test PER gate condition (no council → NO-GO; council-yes but no
     signoff → NO-GO; both → GO; replayed approval → NO-GO; cross-build attestation → NO-GO).

### Phases
- **P-G1** — `CouncilPromotionVerdict` (council judges a finished branch). Pure + tested.
- **P-G2** — `CaptainGate` fusing council + `FleetPromotionGate`. FAIL-CLOSED, per-condition tests.
- **P-G3** — Wire the gate as the ONLY path to merge-to-main in any armed/auto-merge mode;
  behind a flag (off by default), like `leaseRequired`. Manual `git branch -f main` stays
  available for Luke; the *autonomous* path must route through the gate.
- **P-G4** — If a real `git push` / deploy surface is ever added, it inherits the SAME gate.
  No push/go-live primitive ships without routing through `CaptainGate` first.

**Standing rule:** never arm an auto-merge/auto-promote path into main without Luke's
explicit say-so, even when the gate exists. The gate makes promotion *safe to arm*; it
does not pre-authorize arming.
