# PlanExecuteLoop.swift split plan (required: file is over the 1,500-line hard stop)

`Sources/AgentCore/PlanExecuteLoop.swift` is 1,8xx lines. The global rule forbids adding to a
file over 1,500 lines without a split plan. 0.17.63 made ONE emergency patch inside it (the
host-receipt replay trigger, ~10 lines, with the logic itself in
`CompletionVerifier+HostReceipt.swift`) because every finished, council-approved build was
reporting failure. This document is the split plan that patch owes.

## What is already outside the file (keep using these seams)

- `PlanExecuteLoop+FunctionalEvidence.swift` — workspace manifest / lifecycle heads, snapshot
  freshness (`snapshotMatchesWorkspace`), functional evidence review sections.
- `PlanExecuteLoop+VerificationReplay.swift` — deterministic replay recipes, restore, receipts.
- `CompletionVerifier.swift` (+ `+HostReceipt`) — the done-gate rules.

## The `run(goal:)` body, in execution order, and where each part should go

| Section (approx. lines today) | Responsibility | Target file |
|---|---|---|
| 380–700 | mission binding, resume, lifecycle configure, snapshot restore | `PlanExecuteLoop+MissionResume.swift` |
| 700–950 | planning turn: prompt, PlanLint, repair prompts, approval | `PlanExecuteLoop+Planning.swift` |
| 950–1330 | verify gate 4a (deterministic) + 4b (critic) + final review binding | `PlanExecuteLoop+VerifyGate.swift` |
| 1330–1480 | replan steering, budget/noProgress bookkeeping | `PlanExecuteLoop+Replan.swift` |
| 1530–1680 | `coordinateWorkspaceAction` (durable intents/receipts around a tool call) | `PlanExecuteLoop+WorkspaceActions.swift` |
| 1780–1817 | `verifyGoalMet` (critic call) | `PlanExecuteLoop+Critic.swift` |

## Mechanics (behavior-identical, one section per commit)

1. Introduce a `private struct VerifyGateState` holding the mutable locals the verify gate
   threads today (`completionVerdict`, `finalVerificationReceipt`, `deterministicReplaysUsed`,
   `seenDeterministicReplayStates`, `governedDigestDepartureObserved`, `verificationHistory`,
   `retainedVerificationReplays`). Move section 950–1330 into
   `runVerifyGate(_ state: inout VerifyGateState, …) async throws -> VerifyGateOutcome` in
   `PlanExecuteLoop+VerifyGate.swift`. The loop body keeps a single call.
2. Move `coordinateWorkspaceAction` verbatim (it is already a standalone method).
3. Move `verifyGoalMet` verbatim.
4. Move the planning turn; the replan steering last (it references the most locals).
5. After each move: `swift build`, then `swift test --filter 'PlanExecuteLoopTests|PlanSnapshotOwnActionsTests|PlanExecuteHostReceiptTests|WorkspaceLifecycleRegressionTests|AcceptedRunPersistence'`, then commit.

Exit criterion: `PlanExecuteLoop.swift` under 1,000 lines, every extension under 1,000 lines, test
count unchanged, `swift test` green. No behavior change is permitted inside the split commits.
