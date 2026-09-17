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

- **2026-09-16 (later):** Steps 1 and 2a landed on `feat/linux-evolution-supervisor`.
  - **Step 1 — AgentCore builds on Linux** (`1e08aa6`). Empirically scoped by a
    real Linux build (Swift 6.1), not guessed: 13 files, resolved to Darwin-guarded
    swift-corelibs-foundation shims (a `URLSession.bytes(for:)` buffered shim +
    `autoreleasepool` pass-through in `LinuxFoundationCompat.swift`,
    `FoundationNetworking` imports, CFBoolean→objCType checks, Glibc socket-constant
    casts). `swift build --target AgentCore` is green on Linux and macOS.
  - **Step 2a — attested seccomp-BPF escape-syscall deny** (`67fad7d`).
    `EvolutionSeccompFilter` compiles a classic BPF program denying
    link/linkat/symlink/symlinkat + mount/namespace/ptrace/keyring/module/kexec/bpf
    /mknod for x86_64 and aarch64, and KILLs non-native-arch syscalls (closes the
    32-bit-compat-ABI bypass). Content-addressed via `programDigest` for attestation.
    Proven two ways on a real kernel (both compile the exact shipped source):
    (i) `scripts/evolution/linux-seccomp-proof` installs it via prctl(PR_SET_SECCOMP)
    — link/symlink/unshare all EPERM, no-filter control shows link succeeds, allowed
    syscalls still work; (ii) the real deployment path — `bwrap --seccomp <fd>` with
    our filter — blocks a hardlink ("Operation not permitted") while writes succeed.
    5 macOS structural unit tests pin the assembly.
  - **Remaining in step 2 (2b, not yet done):** wire the filter into the bubblewrap
    attestor (`--seccomp` fd plumbing through the spawn path) + bind `programDigest`
    into the sandbox policy, then implement `EvolutionPairedBenchmarkBackend`
    (per-arm git worktrees run under BOTH the cgroup supervisor and the filtered
    sandbox). Step 3 flips the gate under review; the external witness (step 4) is
    operator infra. Held un-merged pending review — this is the evolution-gate code
    that most needs a second reviewer.

- **2026-09-16:** Step 2 (delegated cgroup-v2 supervisor) implemented and proven.
  `LinuxDelegatedCgroupSupervisor` (Sources/AgentCore/LinuxDelegatedCgroupSupervisor.swift)
  creates a scope under the operator-delegated subtree, joins the launcher into
  `cgroup.procs` *before* exec and verifies membership host-side (fork + sync
  pipe: the parent reads `cgroup.procs` and confirms the launcher PID before
  releasing the child to `execve`), writes and reads back `memory.max`/`pids.max`,
  runs a live `cpu.stat` aggregate CPU-time watcher, then issues `cgroup.kill` and
  fails closed unless `cgroup.procs` drains to empty. It builds a
  `HardProcessContainmentReceipt` from host-owned observations only; on non-Linux
  hosts every entry point throws `.unavailable`. Proven against a real cgroup2
  host (Ubuntu 6.8, Swift 6.1.3) by `scripts/evolution/linux-supervisor-proof`,
  which compiles the **exact shipped source** and passes three checks: (A) a
  benign run whose receipt clears the real `HardProcessContainmentContract` +
  one-use `HardProcessContainmentReplayGuard` (replay rejected); (B) a `setsid`
  daemon that outlives its launcher is reaped by `cgroup.kill` and the scope
  verifies empty — a process-group kill would miss it; (C) `pids.max=4` caps a
  50-process adversary and the scope still drains. Held on branch
  `feat/linux-evolution-supervisor`, un-merged pending review.
  **Explicitly NOT done (and why):** `HardProcessContainmentRuntime.currentAvailability`
  and `EvolutionPairedBenchmarkCoordinator.productionBackend` are unchanged — the
  readiness gate stays fail-closed. Flipping them (step 4) requires step 1 (the
  full AgentCore Linux build green) so the backend that consumes this supervisor
  is exercised on the only platform where it goes live; activating a gate against
  code unproven on its live platform is the exact "buildable in an evening and
  worthless" trap this plan rejects. The supervisor is the reviewed, proven unit;
  wiring it into the coordinator is the next reviewed step, not this one.

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
