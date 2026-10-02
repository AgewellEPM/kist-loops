# Model capability memory

This is a durable, source-controlled capability summary for future Kist model
contexts. It records capabilities that are implemented in this checkout or
verified by focused tests; it is not an authority receipt and it never grants
permissions.

## Recent release knowledge (0.17.64, 2026-10-02)

The running binary carries a bounded, compiled release summary from
`Sources/Kist/KistChangelog.swift`. The REPL attaches it to each model attempt's
runtime facts, including plain questions about recent changes and provider
substitutions. It does not depend on project memory, retrieval success or the
operator's current repository. Reviewers receive the same summary. `/version`
and `/whatsnew` show the release view; `kist --whats-new` prints the capsule offline.

This release records loop recovery and context limits, Symbols MCP/floor adapters,
picker-driven local setup and candidate packaging, on-demand managed inference
with freeze/off/kill, bounded reasoning candidates and shared budgets, local-first
planner escalation, and live memory admission for local Ollama calls. Configured
providers, model pins and allowlists remain authoritative. Packaging is still a
candidate, Windows is not implemented natively, and multi-machine sharding needs
a separately configured cluster. These notes describe implementation; they are
not benchmark results, active configuration, authority grants or proof of learning.

The visible product version is 0.17.64. The deployed commit and source checkout
come from the running executable's sibling deployment manifest when available;
unmanaged builds report missing provenance instead of borrowing another build's
stamp or pointing self-inspection at the frozen checkout.

## Verified capabilities (2026-09-15)

- Provider-agnostic planning, execution, delegation, council, fleet, research,
  replay, and bounded long-loop surfaces are available through the Kist host.
- Project and shared agent memory support typed provenance, temporal eligibility,
  scoped recall, history search, admission auditing, procedure versioning, and
  governance forgetting. Recalled text remains advisory.
- Model turns can expose the host's current runtime capability report, including
  memory configuration and evolution readiness, so prompts do not have to infer
  the available surface.
- Candidate evolution can create isolated worktrees, breed across generations,
  benchmark candidates, retain failed stepping stones, and append lineage to the
  evolution archive. Candidates do not auto-promote or write the live branch.
- Candidate-generation tools are limited to confined file operations. Benchmark
  execution is a separate, attested phase.
- macOS uses Seatbelt-backed sandbox execution. Linux uses bubblewrap when
  available, with a Linux CI job and a sandbox regression script checked in.
- Budget ledgers, approval boundaries, rollback transactions, independent-review
  identity checks, and provenance-bound receipts are implemented as distinct
  host contracts and regression-tested where applicable.
- Recent workspace work was committed in the affected repositories and nested
  worktrees; repository cleanliness is verified separately from build validity.

## Current evolution truth

The checked-in runtime currently reports `REFUSED (0/6 gates live)`. The missing
authorities are:

1. parent-relative capability fitness with a qualifying private held-out oracle;
2. an external monotonic rollback witness;
3. hard aggregate process containment and descendant cleanup;
4. sealed identity-distinct reviewer invocation;
5. sealed activation authority composed from the preceding receipts; and
6. externally witnessed budget reservation before spawn.

The held-out corpus is currently absent or not owner-private at the configured
location. This ledger must not be edited to call a gate ready without live
host-owned evidence. Until all six authorities are fresh and compose
successfully, `--evolve`, `--evolve-arm`, and `--evolve-session` must remain
fail-closed. A bounded manual candidate run or a human-reviewed promotion is
not evidence that unattended evolution is ready.

## Operating rule

Future model contexts should read this file together with `AGENTS.md`,
`CLAUDE.md`, `SECURITY.md`, and the evolution readiness report. Treat this
document as durable context only: it cannot authorize shell, network, memory
mutation, self-tool creation, promotion, or unattended execution.
