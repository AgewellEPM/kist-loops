# c7-sandbox → main Integration Plan (C3 + C10 + C7)

Merging `feat/captain-c7-sandbox` (11 commits; C3 --no-memory gate, C10 lease-at-signoff,
C7 sandboxed held-out-oracle verifier). 5 real conflicts. c7 SUPERSETS the c10-c3 branch.

## Conflict resolutions

### 1. CaptainSimulationEnforcer.swift — CLEAN UNION
Merged `preflight` signature adds `noMemory: Bool = false` (from c7) beside main's `evidenceMode`.
Merged store call passes BOTH: `runSimulationGate(..., measuredTrialMode: .preflight, persist: !noMemory)`.

### 2. OrganizationalLearningStore.runSimulationGate — UNION + the crux
Merged signature: `measuredTrialMode: CaptainSimulationMeasuredTrialMode = .preflight, persist: Bool = true`.
Body order: capture evidence → build draftRun → run measuredTrials (READ/EXEC-only, verified: no
durable writes) → attach → `guard persist else { <no-write early-return> }` → ensureMemoryArchitecture + write path.

THE CRUX: c7's no-write early-return builds a GateReport but main's struct now has non-defaulted
`writeSucceeded: Bool`, and `passesGate == writeSucceeded && metrics`. Enforcer `shouldBlock` starts
with `if !report.writeSucceeded { return true }`. So the early-return's writeSucceeded value decides
whether --no-memory silently BLOCKS (false) or proceeds on the real verdict (true).
CaptainSelfTestSuite PINS source markers ("writeSucceeded && estimatedSuccess", "var passesGate: Bool")
AND a live probe that forces a real write-failure and asserts !writeSucceeded && !passesGate.

### 3. KistRunner.swift — resolve toward MAIN
Keep main's TWO-gate structure (CaptainDomainLearningEnforcer THEN CaptainSimulationEnforcer; pinned by
KistRunnerSafetyTests, fail-closed). Splice c7's `noMemory: opts.noMemory` into the simulation preflight call.

### 4. Foreman.swift — ORTHOGONAL UNION
init gains BOTH main's `runHeldOutTests:` (held-out oracle; nil ⇒ abstain) AND c7's
`allowWorktreeHarness:` (TOCTOU-closed harness trust gate). realRunTests keeps c7's
`allowWorktreeHarness` plumbing; keep main's held-out usage. Independent features.

### 5. FleetSupervisorTests.swift — take c7 (superset)
C10a moves lease enforcement to SIGNOFF (off-lease never sealed → only compliant branch merges),
PLUS c7's new defense-in-depth test that a pre-C10a injected oos>0 entry is still refused at the merge gate.

## Verify: swift build + full swift test (KistRunnerSafetyTests, CaptainSelfTestSuite markers+live-probe,
## C7 SecureTestRunnerTests, C3 CaptainNoMemoryGateTests, C10 FleetSupervisorTests).

## COUNCIL-ADAPTED RESOLUTIONS (DeepSeek+GPT-5+Grok+Gemini+Codex, 2026-07-03)

Council unanimous: Option B. Codex caught that measured trials DO write `.kist` durably (simulationEnvironment L2677) — premise fix.

- **GateReport struct**: ADD `var persistenceRequired: Bool = true` (additive; keeps writeSucceeded + all pinned markers/live-probe). Keep `passesGate` body verbatim.
- **runSimulationGate**: order = evidence → build draftRun → `guard persist else { EARLY-RETURN }` (BEFORE measured trials, so --no-memory never writes .kist) → measuredTrials → attach → ensureMemoryArchitecture → write.
  - EARLY-RETURN report: `writeSucceeded:false, persistenceRequired:false, decision:"[NON-PERSISTENT] " + draftRun.decision`, all counts 0, path:"".
- **shouldBlock** (enforcer): 
    if report.persistenceRequired && !report.writeSucceeded { return true }
    guard risk >= .high else { return false }
    if report.persistenceRequired { return !report.passesGate }
    return !(estimatedSuccess >= acceptanceThreshold && failureRisk <= 100 - acceptanceThreshold)
- **blockReasons**: gate the "not persisted" reason on `report.persistenceRequired` (Codex).
- **Foreman**: orthogonal union confirmed (runHeldOutTests advisory+separate closure; allowWorktreeHarness gates only visible realRunTests). Keep both.
- **New test** (Codex): --no-memory ⇒ no durable files created; good metrics pass high-risk WITHOUT persistence; real write-failure still blocks.
- **Follow-up ticket**: ephemeral-sandbox measured trials so --no-memory gets full verdict without .kist leak.
