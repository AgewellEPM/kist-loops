# Legacy Rebuild/Port System — Architecture Map

**Date:** 2026-07-03 · grounded against the kist codebase. This is the *component + data-flow* map: what the machine is made of, what flows between the parts, and what exists vs. is net-new.

## The shape: a pipeline of artifact transforms

The whole system is a chain where each stage consumes a durable **artifact** and produces the next. The artifacts ARE the interfaces (versioned, stored like the ledgers). If you know the artifacts, you know the architecture.

```
legacy system (repo OR binary)
      │
 [1] ARCHAEOLOGY ────────────► SystemMap
      │                        (files, symbols, deps, schemas, protocols, jobs, side-effects, entry points)
 [2] BOUNDARY MAP ───────────► BoundarySpec + DeterminismClass
      │                        (the recordable seams; is-this-portable-with-proof?)
 [3] BEHAVIOR CAPTURE ───────► BehaviorTrace         ◄── SystemOracle (run original deterministically)
      │                        (recorded input→output + side effects)
 [4] GOLDEN MASTER ──────────► GoldenCorpus
      │                        (replayable tests + coverage map + property invariants + fuzz/boundary inputs)
 [5] MIGRATION PLAN ─────────► MigrationPlan
      │                        (target arch, module decomposition, order, risk)
 [6] PORT + ADAPTER ─────────► candidate code (in isolated worktree, behind a strangler adapter)
      │
 [7] EQUIVALENCE ────────────► EquivalenceReport     ◄── SystemOracle (differential: original vs port)
      │                        (per-case match/diff, fuzz results, covered/equivalent/NOT-covered/UNPROVABLE)
 [8] STAGED REPLACE ─────────► shadow → canary → cutover (+ rollback)
      │
 [9] EVIDENCE ───────────────► EvidenceReport (signed, audit-grade)
      │
[10] LESSON PROMOTION ───────► promoted policy/lessons (queued, never auto-applied)
```

## Per-stage: module · artifact · status

| # | Stage | Module (new or reused) | Produces | Status |
|---|-------|------------------------|----------|--------|
| 1 | Archaeology | extend `RepoMap` → **`SystemArchaeologist`** (+ schema/protocol/job/side-effect scanners) | `SystemMap` | RepoMap EXISTS; scanners **NEW** |
| 2 | Boundary map | **`BoundaryMapper`** | `BoundarySpec`, `DeterminismClass` | **NEW** (the wedge selector — decides if a module is provable) |
| 3 | Behavior capture | **`BehaviorCapture`** protocol; backends `RuntimeHarnessCapture`, `PerslisCapture` | `BehaviorTrace` | **NEW — hard core** |
| 4 | Golden master | **`GoldenMaster`** + **`InputSynthesizer`** (fuzz/boundary) + **`InvariantExtractor`** | `GoldenCorpus` | **NEW — hard core** |
| 5 | Migration plan | reuse `AgentPlanner` / `PlanExecuteLoop` / `FleetPlanner` | `MigrationPlan` | EXISTS |
| 6 | Port + adapter | reuse code-writing loop + `GitIsolation`; thin **`AdapterScaffold`** | candidate code | mostly EXISTS |
| 7 | Equivalence | **`EquivalenceHarness`** (differential runner + canonicalizer + differ + fuzz driver + coverage) | `EquivalenceReport` | **NEW — hard core (the oracle gate)** |
| 8 | Staged replace | reuse `ReversibilityClassifier` / `Promotion*` / `FleetPromotionGate`; **`ShadowRunner`** + **`Canary`** | rollout | gates EXIST; shadow/canary **NEW** |
| 9 | Evidence | reuse `GroundedVerdict` / `ClaimReconciler` / signoff ledger; **`EvidenceCompiler`** | `EvidenceReport` | mostly EXISTS |
| 10 | Lesson promotion | reuse `LessonStore` / `PolicyEvolver` / `PromotionGate` / `RunLedger` | promoted policy | EXISTS |

## The spine — the cross-cutting things "everything" depends on

These are not stages; they are the load-bearing abstractions every stage leans on. **This is the real "everything we need."**

1. **`SystemOracle`** (protocol) — *run the original deterministically: given input → output + side-effects.* Backends: `RuntimeHarnessOracle` (source available), `PerslisOracle` (binary only), `LiveShadowOracle` (production, read-only). **This is the determinism spine — replay+diff is the source of truth, not the model.** Stages 3 and 7 both call it. **NEW, and it's the keystone.**
2. **Deterministic sandbox** — sealed clock, seeded RNG, filesystem snapshot. Needed by every Oracle backend so a run is reproducible. Partially exists (kist `sandbox` tiers); the determinism controls are **NEW**.
3. **Artifact store** — `SystemMap` / `BehaviorTrace` / `GoldenCorpus` / `EquivalenceReport` are durable, versioned, signed. Mirror the `RunLedger`/`FleetSignoffLedger` pattern. **NEW (thin — the pattern exists).**
4. **`CapabilityRegistry`** — lets the Captain invoke existing tools as capabilities. Cross-cutting infra. **NEW.**
5. **Honesty contract** — every report distinguishes **covered / equivalent / not-covered / unprovable**. Never just "passed." A property of the `EvidenceReport` + `EquivalenceReport` schemas.

## Critical path (build order of the spine)

```
SystemOracle (+ deterministic sandbox)   ← the keystone; nothing proves equivalence without it
        │
   BehaviorCapture  ──►  GoldenMaster  ──►  EquivalenceHarness
        └──────────── these 4 ARE the machine ────────────┘
```

Everything in stages 1, 5, 6, 8, 9, 10 largely reuses existing kist substrate. **The net-new engineering is: the Oracle abstraction + Capture + GoldenMaster + Equivalence.** Nail those four and the pipeline closes; bolt them onto machinery that already works for the rest.

## What "exists vs. need" reduces to

- **EXISTS (reuse):** repo mapping, planning, code-gen, isolation, reversibility/blast-radius gating, staged promotion (Ed25519, fail-closed), evidence/claim-reconciliation, durable supervision, lesson/policy promotion, RunLedger.
- **NET-NEW (the mission):** `SystemOracle` + deterministic sandbox · `BehaviorCapture` (2 backends) · `GoldenMaster` (+ fuzz/invariants) · `EquivalenceHarness` · `BoundaryMapper` · thin `AdapterScaffold`/`ShadowRunner`/`Canary` · `CapabilityRegistry` · artifact store.
- **The wedge selector** (`BoundaryMapper` + `DeterminismClass`) is what keeps us honest about *which* legacy modules are portable-with-proof today vs. not yet.
