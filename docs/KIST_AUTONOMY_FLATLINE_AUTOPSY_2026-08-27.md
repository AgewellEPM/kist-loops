# Kist autonomy flatline autopsy

Date: 2026-08-27<br>
Scope: Kist CLI, cortex autonomy runtime, dashboard task runner, provider routing, and self-evolution<br>
Recovery posture: **autonomy disabled; diagnosis and bounded repair only**

## Executive finding

Kist did not fail because one component crashed. It entered a false-progress loop: unavailable
providers, interface misuse, incomplete work, and unverified process exits could all be folded into
states that looked terminal or complete. Retry accounting then forgot sufficiently old attempts, so
the system could repeat work without accumulating a durable reason to stop. The dashboard made this
worse by presenting some terminal states as successful completion.

The historical runtime snapshot at `~/.kist/runtime/autonomy.json` makes the mismatch measurable:

- 178 recorded goals: 165 `done`, 13 `blocked`.
- Only 23 of the 165 `done` goals have `lastAcceptance.accepted == true`.
- 142 `done` goals therefore have no positive host acceptance record.

Those numbers describe historical state; they are not a claim that all 142 goals failed. They prove
that `done` cannot be used as evidence that an objective was achieved.

## Recovery checkpoint — 2026-08-28

Kist has now performed one bounded, read-only internal autopsy through its own CLI. The campaign
process receipt is:

`/private/tmp/kist-self-assessment-20260828.xvl8VW/campaign.receipt.json`

Its assessed stdout is:

`/private/tmp/kist-self-assessment-20260828.xvl8VW/codex-kist-read-probe/attempt-0001/process.stdout`

The campaign receipt says `status: passed` because the constrained process, provider policy,
resource lease, executable binding, and cleanup checks passed. That is not an autonomy verdict. The
CLI's own terminal assessment is:

`AUTOPSY_ASSESSMENT: RECOVERY-IN-PROGRESS / NOT AUTONOMY-READY`

The recovery has materially advanced since the original autopsy:

- Accepted-run receipt v2 binds a host verdict to the physical project identity and exact run-ledger
  bytes under ForgeSeal. Dashboard and autonomy projections no longer trust unsigned stdout or a raw
  `verified` bit.
- `context_brain(action="mission_graph", mission_id="<64hex>")` now projects a bounded, read-only,
  project-scoped graph over the reasoning DAG, project episodes, project-bound lessons, ledger rows,
  and accepted receipts. Fresh exact v2 acceptance is `sealed`; expired authentic v2 is only
  `historical-seal`; v1 and legacy/unbound checkpoints remain advisory.
- Fresh focused verification for that boundary passed 159 tests: MissionEvidenceGraph 19,
  PlanExecuteLoop 63, AcceptedRun 31, ContextBrainTool 10, ReasoningControlStore 8, and RunLedger 28.
  Both `AgentCore` and `Kist` targets built successfully, and `git diff --check` passed.
- Oversized or repeatedly under-decomposed PlanExecute plans now stop with
  `decompositionExhausted` before execution/evidence rather than consuming an unbounded context.
- Python Cortex memory and Swift `MemoryTemporalEnvelope` now share transaction, valid, evidence,
  lifecycle, exponential-decay, and explicit-recurrence semantics. Decay is
  `0.5^(elapsed/half-life)`, anchored to the last verified confirmation or creation; reading, access
  counters, and ordinary transaction updates never refresh truth. Explicit seasons support months,
  Monday-zero weekdays, and local half-open hours in an IANA timezone. They are bounded relevance
  multipliers—default `1.15` in season and `0.35` off season—and are never inferred from prose, tags,
  filenames, or one observation. On 2026-08-28, the live Cortex memory suite passed 468/468 tests;
  its broader runtime passed 716, and the full live dashboard suite passed 268.
- Swift Captain retrieval now applies the shared temporal kernel to organizational rules, knowledge
  debt, learning capsules, ProjectMemory episodes, LessonStore lessons, evidence-ledger projections,
  and generic organizational shelves. Generic unsigned rows are admitted only with internally
  consistent event/transaction clocks and an unprivileged envelope: no pin, `none` decay,
  confirmation, reinforcement, or access-based rejuvenation. Unknown-age generic rows remain raw
  audit-only and reads never invent timestamps or rewrite them.
- At this checkpoint the checked-in generic shelves contain 26 unknown-age audit-only rows—10
  industry observations, 6 evolution proposals, and 10 benchmarks—and zero clocked rows. One
  unindexed research artifact also remains raw audit-only. A later genuine observation may append a
  newly clocked revision, but file modification time is never used to fabricate age.
- The separate live Cortex record directory contains 1,625 physical JSON rows, but only one is
  retrieval-eligible under the repaired decoder. Of the remainder, 940 are undecodable without a
  trustworthy event clock and 684 decode only as `unverified-source-event-time`. This is visible
  migration debt, not evidence of 1,625 usable memories; the audit was read-only and did not touch
  access telemetry or rewrite a row.
- Memory authority and memory relevance remain separate. ForgeSeal/AcceptedRun receipts and sealed
  evolution-archive rows are never promoted or demoted by salience or season. Accepted-run freshness
  may expire under its own policy and become `historical-seal`; that does not erase authenticity.
- Root `AGENTS.md` now attaches this autopsy, the memory-governance status, the DGM roadmap, and the
  capability campaign to Codex CLI. The bounded campaign self-probe explicitly requires those files
  and their names in observed output before its process receipt can pass.

Semantic/vector V2 source now shares this kernel: undated V1 rows are audit-only; V2 ranks
non-negative cosine by temporal salience, binds checked prose to its exact digest, binds embeddings
to a model/manifest identity, and renders recalled text inside a bounded untrusted-data frame. Its
strict parser rejects unknown and duplicate keys; append ordering and terminal lifecycle transitions
are fail-closed; partial-query salvage reports sticky degraded health; and persistence is
cross-process locked with owner/mode/link revalidation. The V2 path is separate from the timeless
store so an old writer cannot strip V2 fields. It is source-only until the explicit old-process drain
and rollback/no-memory policy are completed.

Several boundaries remain explicit. EffortMemory, CaptainLearning scorecards, and other
purpose-built ledgers do not yet share this temporal kernel. CaptainLearning uses a separate
30-day, unsigned advisory policy and may bias routing only; it is not benchmark or receipt
authority. Verified reinforcement remains an internal trusted-call gate rather than a
ForgeSeal/AcceptedRun binding. Pure fail-closed contracts now exist for exact-parent paired held-out
fitness, an externally signed compare-and-advance rollback checkpoint, aggregate descendant
containment, identity-distinct review, and sealed activation. They are deliberately not live
authorities: there is no host-owned fitness runner, configured external witness/CAS backend,
qualifying hard-containment runner on this host, actual-route identity-distinct reviewer receipt,
composed activation authority, or externally witnessed pre-spawn budget reservation. Current
readiness therefore reports all required gates as blocked. None of these contracts arms autonomy.

The full Python temporal repair is durably preserved by local commit
`08be5e4af15c7c93821378c66f27e0150bc5d22b` and the verified complete-history bundle
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-runtime-temporal-08be5e4.bundle` (SHA-256
`3f46824757b88c08402e796fd61fc8a34b6d0f69fdfc062859772ffacd10091e`, mode `0600`). Its exact staged
snapshot passed 160 affected tests; the integrated checkout passed 468/468 memory tests. The prior
`99ea435` checkpoint remains historical. A separate canonical reviewer-identity repair is commit
`e19019c100b411c3b6a44bce2233ab603877fa3e`, preserved through
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-runtime-recovery-e19019c.bundle` (SHA-256
`639eed705b59318235dacab7fd68504410af3aba32141161444fd918fb0f9d28`). The subsequent persistence and
source-publication repair is commit `773112d12dd4e85b7051ab2ccb1bb0d9d36cacaa`, preserved in the
complete-history bundle
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-runtime-memory-773112d.bundle` (SHA-256
`84b62ea7453b06cae292802f96756231fc21b05c19e9d7cb8edab01b34f56f64`, mode `0600`). Its exact
detached snapshot passed 435/435 tracked memory tests; the focused store/indexer suite passed 93/93,
and the integrated checkout passed 513/513. No push was performed. Python `HEAD` is four commits
ahead of the recorded origin-tracking commit; the remote server was not
queried during reconciliation. The broader checkout is still dirty with unrelated
autonomy/runtime/security/provider/budget work. Seven tracked supporting memory-test files and seven
untracked supporting memory-test files remain outside the temporal lineage. The five temporal
production files and five direct temporal tests are clean and byte-identical to the repaired
lineage. The older
`/Volumes/PRO-G40/mythos-cortex-memory` sidecar remains a separate July 2026 lineage without this work.

The working Swift semantic/evolution slice remains uncommitted in the separate Kist checkout. Its
217-file recovery/dependency closure is preserved at
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-recovery-source-5f6158c-20260829-final3.tar.gz`, mode
`0600`; every member is checked byte-for-byte against the live checkout. The prior 142-file `final2`
and earlier 69-file semantic overlays are historical predecessors. The final overlay is
preservation, not a Git commit, installation, or promotion.

## Verification lineage — 2026-08-28

- The final combined temporal/evolution/security gate passed 392/392. A fresh full Swift package run
  executed 4,914 tests with 6 intentional skips and 0 failures.
- Focused post-repair runs passed 9/9 CustomTool tests, 15/15 deployment-provenance tests, and
  12/12 budget/evolution-security tests.
- The live Python runtime checkpoint previously passed 716/716 tests. On 2026-08-28, the current
  memory subset passed 468/468. After persistence/publication hardening on 2026-08-29, the integrated
  memory checkout passed 513/513 and its exact detached tracked snapshot passed 435/435. The live
  dashboard previously passed 268/268.
- The capability-campaign runner passed 39/39 tests, its manifest parsed, and `git diff --check`
  passed.

These are source-checkout results. The installed `~/bin/kist-current` has a different digest from
the repo release build, contains the old timeless `vectors.json` path, and lacks the V2 path and new
evolution-refusal strings. It was not promoted or exercised through `/grow` or `--evolve` during
this recovery. Installed behavior must therefore be treated as old/unsafe for self-evolution until
the sanctioned deployment gate is separately authorized and completed.

The Python daemon was likewise not restarted. At this checkpoint PID 8579 had been resident since
2026-08-27, before commits `08be5e4`, `e19019c`, and `773112d`, and continued non-autonomy indexing cycles even
with goal execution disabled. The repaired files cannot be called production-live until an
authorized drain/restart and post-restart identity check. The live record directory remains mode
`0755`; neither the safe `0700` migration nor either new lock sidecar has been invoked there. The standalone `models route` CLI also
omits the configured provider allowlist when constructing its advisory planner; no execution
consumer of that output was found, but its display can contradict the GPT-only policy and must be
fixed before it is treated as authoritative routing evidence.

The broad Swift run first exposed a real custom-tool regression: outer `sandbox=disabled` had been
forwarded into a runner whose contract requires confinement. Removing only that override restored
the mandatory confined policy. The same run also exposed a v3 deployment fixture that lacked the
runtime/Cortex inputs now required by the fail-closed provenance evaluator, and a stale source-pin
test that still demanded raw shell for pre-commit evolution. The fixtures now preserve the stronger
validator, and the evolution test instead pins denied shell, strict confinement, and the concrete
in-process tool ceiling.

## Failure chain

1. A model could call an advertised skill name as though it were an executable tool. The registry
   returned only an unknown-tool failure.
2. The failure classifier could interpret that response as a missing capability (`toolLimit`) rather
   than interface misuse, nominating a ghost “build the missing tool” recovery mission.
3. Provider routing could select a configured but unavailable provider. Historical runtime metadata
   explicitly identifies an Ollama-down era with no shared availability gate.
4. A process exit, plan-card status, or autonomy terminal state could become `done` without a trusted
   acceptance or verification receipt.
5. Dashboard text collapsed terminal/process success into “complete” or “committed,” overstating the
   evidence.
6. Heal-attempt accounting read only the newest 32 task jobs. Old attempts could age out, reset the
   apparent count, and reopen the loop.
7. Heal evaluation/count/start and ordinary task start were not atomic across concurrent dashboard
   requests, allowing duplicate attempts around reattachment and launch boundaries.
8. The runtime had no safe GPT-only reviewer grade. With other providers unavailable, self-tool
   promotion either stopped or was tempted to mislabel the same model as independent.

This is the “killed itself” path: not a dramatic process death, but loss of trustworthy state. The
machine kept producing terminal records while its evidence, retry memory, and UI semantics diverged.

## Repairs made or under final verification

- Provider admission is explicit and fail-closed. The live Kist/cortex policy admits only
  `codex-cli:gpt-5.6-sol`; auto-routing is disabled. A configured non-GPT profile cannot bypass that
  allowlist.
- Provider health/availability participates in routing and fallback instead of treating installation
  as readiness.
- Calling a known skill as a tool now returns interface guidance, so the next action is to read the
  skill and the failure classifier does not manufacture a capability gap from a bare unknown-tool
  error.
- Dashboard task APIs separate `terminal`, `succeeded`, and `verified`. Legacy `done` remains only a
  terminal compatibility alias. Without a trusted objective receipt, `verified` is false.
- The worker and UI now say “process exited 0 — result not verified”; they do not claim a file was
  committed or an objective completed.
- Heal lineage uses uncapped durable history for governance. Evaluate/count/start is serialized and
  capped at three attempts. Exact-job reattachment, eight-way concurrent start, and stop/launch
  handoff regressions now pass without duplicate workers or a missed stop.
- Empty dashboard tool allowlists are described honestly as deny-all, matching runtime behavior.
- The GPT-only review lane enforces an exact canonical provider/model in a separate fresh invocation
  and emits `independent=false`. High-risk work still requires an identity-distinct reviewer.
- A host-owned 64-lowercase-hex mission identifier now survives the installed Perslis→Jeeves legacy
  gate. Its Kist PlanExecute/reasoning/episode/lesson/ledger/receipt graph is now structurally verified;
  fresh cross-process Perslis/Jeeves/GhostBridge provenance and physical actuation remain outside the
  evidence boundary.

## What remains deliberately off

`~/.kist/runtime/config.json` remains the authority and currently requires:

```json
{
  "autonomy": {
    "enabled": false,
    "canonical_execution": false,
    "allow_shell_execution": false,
    "allow_self_tool_creation": false
  }
}
```

No dashboard label, plan status, process exit, model prose, or same-model critique may override those
switches. VM launch, display/input control, browser automation, physical-device control, and live
GhostBridge handoff remain outside this recovery run.

## Wake-up gate

Kist is not ready for standing autonomy until all of these are evidenced from fresh fixtures:

1. One host-owned mission ID joins Captain/PlanExecute, tool spans, audit entries, outbound MCP
   metadata, Perslis/Jeeves echo, run ledger, and dashboard aggregation.
2. A seeded failure is detected, minimally repaired, deterministically verified after the final edit,
   and continued without replaying a mutation.
3. Retry limits survive history growth, concurrent requests, process restart, and reattachment races.
4. Self-authored tools are confined, reloaded, positively and negatively tested, and accompanied by an
   honest review receipt.
5. Dashboard `verified=true` can arise only from an accepted same-mission host receipt.
6. Frozen GhostBridge/Perslis/Tinky provenance drift is reconciled from authoritative artifacts; it is
   never silently rebaselined.
7. A second clean run reproduces the result and all spawned children are gone afterward.
8. High-risk autonomous promotion remains blocked until an identity-distinct reviewer is available.
9. The checkpointed Python temporal-memory slice remains tied to the durable `08be5e4` lineage and
   external bundle; the obsolete standalone sidecar is never mistaken for its authority.
10. All six source-declared evolution readiness gates—fitness, rollback witness, hard containment,
    identity-distinct review, sealed activation, and witnessed budget reservation—are backed by
    fresh production receipts, not test-only constructors or model prose.

Until that bar is met, Frankenstein stays on the table: he may be inspected and exercised in bounded
fixtures, but he does not wake himself or operate live systems.
