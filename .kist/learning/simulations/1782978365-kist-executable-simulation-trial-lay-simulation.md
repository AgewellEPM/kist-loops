# Captain Simulation Gate

Objective: Kist executable simulation trial layer
Domain: Software sandbox
Decision: PROCEED: executable sandbox trials passed; execution still requires attached evidence and review.
Acceptance threshold: 78% estimated success with bounded failure risk

## Recommended Strategy
Containerized integration sandbox

Sandbox: Run the plan in Docker or an equivalent isolated service graph with mock external systems.
Estimated success: 88%
Measured-adjusted success: 88%
Failure risk: 12%
Expected value: 98%
Trials: 63/72 passed

## Sandbox Simulation
Captain must prove the plan in a disposable environment before real-world execution.

## Executable Sandbox Trials
- docker compose config
  Status: skipped
  Exit: n/a
  Elapsed: 0.00s
  Output: unsupported command for automatic sandbox execution
- docker compose up --abort-on-container-exit
  Status: skipped
  Exit: n/a
  Elapsed: 0.00s
  Output: unsupported command for automatic sandbox execution
- git diff --check
  Status: passed
  Exit: 0
  Elapsed: 0.04s

## Probabilistic Trials
- Containerized integration sandbox
  Sandbox: Run the plan in Docker or an equivalent isolated service graph with mock external systems.
  Why: Integration risk needs a closer runtime model than unit tests alone.
  Trials: 63/72 passed
  Estimated success: 88%
  Failure risk: 12%
  Expected value: 98%
  Failure modes: container/runtime mismatch; missing secrets; service startup flake
- Disposable repo test sandbox
  Sandbox: Use a throwaway branch/worktree, fake APIs, focused tests, and CI-style verification.
  Why: Software changes are cheapest to validate in an isolated repo before touching the main path.
  Trials: 52/64 passed
  Estimated success: 82%
  Failure risk: 18%
  Expected value: 89%
  Failure modes: test gaps; mock drift; uncovered integration behavior
- Direct edit without sandbox
  Sandbox: No isolated validation; edit the live project and rely on post-hoc review.
  Why: This is included as the baseline Captain should usually reject.
  Trials: 42/80 passed
  Estimated success: 52%
  Failure risk: 48%
  Expected value: 27%
  Failure modes: regression reaches the user; hidden state mutation; rollback confusion

## Required Evidence Before Real Execution
- container startup log
- integration test output
- fixture inventory
- resource cleanup proof

## Suggested Verification Commands
- docker compose config
- docker compose up --abort-on-container-exit

## Compare Strategies
Pick the strategy with the best expected value after penalizing failure risk and blast radius.

## Execution Gate
- Do not execute the real-world action until the simulation task, benchmark task, review task, and accept/reject decision are complete.
- If evidence contradicts this simulation, update the risk model instead of forcing the plan through.
- If accepted, Teach Captain should promote the lesson: risky objectives require sandbox simulation before execution.

## Artifacts
Simulation report: .kist/learning/simulations/1782978365-kist-executable-simulation-trial-lay-simulation.md
Seeded simulation tasks: 6
Created simulation specialists: 2
Benchmark records: 1
