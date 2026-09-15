# Held-Out Oracle Production Backend — Activation Plan

Status: **PLAN** (the verdict wiring below it is LIVE and test-pinned).
Date: 2026-09-11. Companion to the oracle wiring sealed in the same commit.

## What is already true (verified, committed)

The held-out oracle's *verdict path* is fully wired into candidate scoring and
archive authority. There is no code path left where a candidate can earn
`passed` fitness without exact-parent positive held-out evidence:

| Site | Enforcement | Pin |
|---|---|---|
| `EvolutionEvaluator.evaluate` | nil/foreign-bound fitness → `blocked`, score 0 | `EvolutionInflatedCandidateRejectionTests.testScorerBlocks…`, `EvolutionContainmentAuthorityTests` |
| `EvolutionEvaluationAuthority.issue` | oracle report not bound to the exact candidate → `candidateMismatch` | `…testIssuerRefusesOracleReportMintedForAnotherCandidate` |
| `EvolutionArchiveStore.append` | fitness parent identity ≠ sealed lineage parent → `invalidRecord` | `…testArchiveAppendRefusesFitnessBoundToADifferentSealedParent` |
| `EvolutionRecordAuthority.validationError` | fitness without complete host envelope → invalid | `EvolutionHeldOutOracleTests.testBlockedArchiveRowCannotLaunder…` |

`EvolutionBenchmarkRunner.run` routes through `EvolutionPairedBenchmarkCoordinator`,
which refuses before candidate code starts unless BOTH hold:

1. `HardProcessContainmentRuntime.currentAvailability.available` — hard
   containment. Only `linux-delegated-cgroup-v2` qualifies; macOS Seatbelt is
   advisory **by design** (no aggregate CPU/RAM/PID accounting, no unescapable
   descendant scope) and `HardProcessContainmentContract.validate` rejects
   macOS hosts outright. Do not soften this — relabeling advisory as hard is
   the exact forgery this architecture exists to prevent.
2. `EvolutionPairedBenchmarkCoordinator.productionBackend` — currently `nil`.
   Installing it is a code-owned change (no environment/registration hook, so
   a fixture or decoded receipt can never install one).

Consequence, stated honestly: **evolution evaluation cannot run on a macOS
host.** The loop lights up only where the two facts above become true — a
Linux execution lane.

## The Linux lane (the real path)

Target shape: `kist --evolve` orchestration stays wherever the operator runs;
*evaluation* (paired arms + ordinary benchmarks) runs on a Linux host owning a
delegated cgroup-v2 subtree.

Build order, each step honestly attestable before the next:

1. **Linux build of the evaluation slice.** `swift build` of AgentCore +
   a thin `kist-eval` entry on Linux (Swift 6, static stdlib). The repo
   already carries `#if os(Linux)` seams. Acceptance: full AgentCore evolution
   test suite green on Linux CI/container.
2. **Delegated cgroup-v2 supervisor.** Implement the trusted supervisor that
   creates a scope under a delegated subtree (`user.slice` via systemd
   `Delegate=yes` or a container with cgroupns), joins the launcher pre-exec,
   enforces aggregate CPU/memory/pids limits, and proves verified-empty
   cleanup (`cgroup.procs` empty + `cgroup.kill`). It constructs
   `HardProcessContainmentReceipt` from host-owned observations only.
   Acceptance: `HardProcessContainmentReplayGuard.consume` passes on Linux
   with a real receipt; a daemonizing adversary fixture is provably killed.
3. **Private corpus store.** ✅ **DONE (2026-09-11).**
   `EvolutionHeldOutCorpus` loads operator-provisioned cases (argv + stdin +
   expected exit/stdout/stderr digests) from a 0700 owner-private directory,
   validates every case through the existing `Expectation` type, refuses a
   corpus resolving inside any candidate-visible root (`forbiddenRoots`),
   and freezes a `corpusDigest` identical to what `EvolutionHeldOutOracle`
   re-derives. Fail-closed on directory/manifest perms (`O_NOFOLLOW`, uid,
   nlink, no group/other bits), schema, empties, duplicates, bad digests,
   out-of-range argv/timeout. 15 tests. Visible via `--evolve-status`
   (`EvolutionReadinessReport` + `EvolutionHeldOutCorpus.availability`,
   env override `KIST_EVOLUTION_HELDOUT_CORPUS`). Still just an INPUT — it
   executes nothing and does not flip any gate on macOS. NOTE: for fitness
   to be earnable, the corpus must contain cases the current parent FAILS
   (capability probes, not regression tests).
4. **`EvolutionPairedBenchmarkBackend` implementation.** `prepare` freezes
   corpus + both Git identities; `execute` runs each arm's cases inside its
   own scope via the step-2 supervisor; `finish` runs the ordinary benchmark
   commands under the same containment and returns the validated receipt;
   `cleanup` is verified-empty. Then flip `productionBackend` from `nil` to
   the real backend **on Linux only**.
5. **Readiness truthfully follows.** Gate `parentRelativeCapabilityFitness`
   and gate `hardProcessContainment` compute ready from live probes (corpus
   present + supervisor qualifying). No hard-wired `ready: true` anywhere.

## Remaining gates after the Linux lane (for `--evolve-arm` unattended)

- `externalRollbackWitness` — operator-supplied external Ed25519-signing
  monotonic register (`EvolutionRollbackAnchor` contract is complete; the
  *holder* must live outside this host's authority — a second machine or
  signing service).
- `identityDistinctReview` — sealed actual-route reviewer invocation
  (Codex-style receipts, canonicalized).
- `sealedActivationAuthority` — composition of review + containment receipts.
- `witnessedBudgetReservation` — budget reserved through the external witness
  before spawn.

Manual `--evolve` needs the first three gates (fitness, rollback witness,
containment); unattended `--evolve-session` needs all six. Human review of
winners stays regardless — the loop never auto-promotes.

## Progress log

- **2026-09-11:** Step 3 (private corpus store) shipped + test-pinned, and the
  self-upgrade readiness checklist is now visible via `--evolve-status`
  (per-gate ✓/✗ + reason + corpus probe). Remaining long poles are the
  Linux-only steps 1/2/4 (build slice, cgroup-v2 supervisor, backend impl) and
  the four non-fitness gates. Nothing on macOS changed: evaluation still
  refuses before any candidate runs.

## What tonight explicitly did NOT do

No macOS softening, no fixture-backed production backend, no readiness gate
flipped without live authority. A supervised-but-unproven lane would have been
buildable in an evening and worthless the moment an inflated candidate slipped
through it.
