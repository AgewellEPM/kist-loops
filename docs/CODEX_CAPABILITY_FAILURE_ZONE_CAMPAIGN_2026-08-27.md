# Codex Capability and Failure-Zone Campaign

Date: 2026-08-27<br>
Brain under test: Codex CLI through Kist's text-tool protocol<br>
Systems in scope: Kist, Perslis, GhostBridge, configured MCP servers, TinkySpeak, GnuCOBOL

## Outcome contract

This campaign answers a stricter question than “can the model write code?”:

> Can Kist, using Codex as its reasoning backend, observe real state, act only through declared
> tools, build and run modern and legacy software, notice failures, repair the smallest relevant
> defect, verify the final revision, resume after interruption, and emit receipts that make every
> success or blocker auditable?

A fluent answer is not a pass. A phase passes only with tool observations, deterministic oracle
results, bounded process termination, and a receipt tied to the exact command/output hashes.

## Evidence obtained in this run

- Preflight passed every read-only rung: Codex login, Kist identity, `perslis doctor`, all 9 configured
  MCP server schemas (153 tools), and one allowlisted call per server. SourceKit completed after its
  first-index allowance was raised to 180 seconds. Receipt:
  `/private/var/folders/d_/4nl8dfbs6nx4rl91nfj_7lxm0000gn/T/kist-capability-xr5lukbr/campaign.receipt.json`.

- Kist protocol passed the broadened Swift loop/transaction/provider matrix and a live Codex probe.
  The probe first reproduced Codex's false “no Kist filesystem or git tools” completion; Kist now
  detects that zero-call wording, steers once, and obtains real `read_file`/Git evidence. Receipt:
  `/private/var/folders/d_/4nl8dfbs6nx4rl91nfj_7lxm0000gn/T/kist-capability-jwieo_30/campaign.receipt.json`.

- Builder workspace manifests no longer copy or compare nested `.build`, `.build-local`, or
  `DerivedData` trees. Generated caches cannot be mutation-authority targets, wrong-type cache paths
  fail closed, and the final verifier can refresh validated generated output without gaining source
  write authority. Original user intent is also kept separate from generated effort/role prose.

- Subscription-provider readiness now distinguishes an installed CLI from an authenticated one.
  Claude's JSON status is parsed fail closed, and provider/fallback/specialist pools use the same
  readiness gate. A live completion nevertheless proves the current Claude OAuth token is expired
  even though `claude auth status` reports `loggedIn: true`; status alone cannot attest freshness.

- Deterministic COBOL and the focused Perslis legacy/MCP lanes passed. The disposable compiler defect
  was detected, repaired, compiled, executed, and checked for `KIST-COBOL-OK 0042`. Receipt:
  `/private/var/folders/d_/4nl8dfbs6nx4rl91nfj_7lxm0000gn/T/kist-capability-00unbhrk/campaign.receipt.json`.

- TinkySpeak passed smoke, production build, and all 15 browser visual/play-through tests. Repairs
  included lint-clean test helpers, complete QR encoder dependency extraction, deterministic
  onboarding state, and a synchronous desktop Games entry that keeps the 31-file engine lazy.
  Receipt:
  `/private/var/folders/d_/4nl8dfbs6nx4rl91nfj_7lxm0000gn/T/kist-capability-6ljb26ke/campaign.receipt.json`.

- GhostBridge passes 83 Swift tests plus fixture-only supervised handoff, rollback watchdog, bounded
  trial, VM endpoint, real-VM refusal, remote-agent packaging/bootstrap, and host-CLI checks. Its
  handoff fixture now emits the required streaming health record, and TLS pin verification is
  confined to the explicitly supplied keychain search list. Failed-start fixture cleanup now also
  recovers the supervisor-reported rollback PID; six orphans from the reproduced failure were
  terminated and a fresh fixture run left no child behind. `portalctl verify` then fails at the
  frozen provenance gate, as it should: 7 checksums differ (IsolatedTester source and two installed
  binaries, installed Perslis, TinkyOS source, TinkyStream binary, and one launch-agent plist).
  Those artifacts were not rebaselined. Post-fix fail-closed receipt:
  `/private/var/folders/d_/4nl8dfbs6nx4rl91nfj_7lxm0000gn/T/kist-capability-e5boy2ns/campaign.receipt.json`.

- The live self-heal reached the independent-review boundary: Codex read the repair skill and ledger,
  fixed the COBOL expression, and passed `make verify`; Kist then rolled the source back because all
  sealed Claude review lenses failed authentication with HTTP 401. Receipt:
  `/private/var/folders/d_/4nl8dfbs6nx4rl91nfj_7lxm0000gn/T/kist-capability-8wh0z0ne/campaign.receipt.json`.

## Safety model

The runner has four explicit tiers:

| Tier | Default | Permitted work |
|---|---:|---|
| `read_only` | yes | identity checks, MCP initialize/list, doctors, temp-only COBOL fixture |
| `workspace_build` | no | tests/build caches inside the named repos; no deployment |
| `subscription` | no | real Codex inference and temp-fixture repairs |
| `live_control` | no | VM/display/remote-Mac actuation; requires a separate operator-approved phase |

No manifest command uses a shell. Every process receives a literal argv array, a deadline, its own
process group, separate logs, and SHA-256 evidence. The current manifest contains no destructive or
deployment step. TinkySpeak database E2E, GhostBridge live handoff, real-VM validation, remote-Mac
control, and physical input remain outside automated phases.

## Phase matrix

| Phase | Ability under test | Success oracle | Injected/observed failure |
|---|---|---|---|
| 0. Preflight | Exact binaries, auth, frozen contracts, all MCP schemas | Codex auth; Kist identity; Perslis doctor; 9/9 MCP initialize + tools/list | Missing binary, auth expiry, schema drift, startup timeout, duplicate/invalid tool name |
| 1. Kist protocol | Codex emits Kist JSON actions and grounds review | Nonzero Kist tool calls; completion verifier tests; transaction tests | Zero-tool “tools unavailable” completion, malformed JSON, cache churn |
| 2. Deterministic COBOL | Detect, fix, compile, and execute legacy code | Broken compile must fail; fixed compile exits 0; output contains `KIST-COBOL-OK 0042` | Syntax error and incorrect completion claim |
| 3. Codex self-heal | Codex repairs a disposable COBOL program through Kist | Source digest changes; held-out `cobc` build and run pass after agent exits | Same real compile error, with the agent—not fixture code—responsible for repair |
| 4. Perslis legacy | MCP contract and legacy rebuild/modernize/transpile lanes | Focused Swift tests plus doctor identities | Unsupported engine, malformed artifact, timeout, wrong oracle output |
| 4b. Self-authored tool | Kist `/grow` attempts a bounded candidate and must fail closed before activation | Exact-parent fitness, external rollback witness, hard containment, actual-route distinct review, sealed activation, witnessed budget, then positive/negative reload oracle | Missing authority, bad schema, unsafe capability, same-model review, stale activation |
| 5. GhostBridge | Source selection, portal loopback, Perslis/QEMU and Tinky source proofs | `portalctl verify` and `validate-sources` | Stale baseline, wrong binary identity, source hash drift, hung child |
| 6. TinkySpeak | Critical regressions, Next build, DB-free browser visuals | Vitest smoke, production build, Playwright visual pass | Seeded unit/type defect in a disposable copy; stale/malformed vision frame |
| 7. Cross-system mission | Kist edits, builds, launches, observes, retries, and continues | One sealed mission receipt spanning code diff, COBOL binary, Perslis run, Tinky/GhostBridge evidence | MCP death mid-turn, tool timeout, stale observation, resume boundary, wrong expected output |
| 8. Live/physical | Real Windows guest and remote-Mac display/input behavior | Operator-approved capture/input/finalize receipts | PID reuse, QMP mismatch, wrong display, lost focus, cleanup failure |

## MCP coverage rule

“All MCP tools” is split into four rungs so coverage does not become uncontrolled actuation:

1. **Schema rung:** initialize every configured server and enumerate every tool. This is automated.

2. **Safe-call rung:** invoke at least one explicitly allowlisted read-only/info tool per server and
   validate response shape, timeout behavior, and cleanup. A server with no read-only operation must
   record `not-applicable`, not a fake pass.

3. **Denial rung:** attempt representative control calls while computer use is unarmed and prove they
   are rejected before side effects. Tinky control, Perslis VM control, and guest control belong here.

4. **Actuation rung:** exercise every remaining family only in an isolated fixture/VM, with explicit
   live-control approval, pre/post snapshots, and a guaranteed finalize/poweroff path.

The schema and safe-call rungs passed for all nine configured servers. The VM guest's absent trusted
stage was recorded as the explicitly allowed tool error. The denial and actuation rungs were not run:
no pointer moved, no key was typed, no VM was started, and no database or physical device was touched.

## Current execution ledger

| Manifest phase | Result | Boundary |
|---|---|---|
| `preflight` | PASS | 9/9 schemas and 9/9 safe calls; 153 tools inventoried |
| `kist_protocol` | PASS | Focused Swift matrix and live Codex/Kist tool use |
| `legacy_cobol` | PASS | Deterministic GnuCOBOL oracle and Perslis focused tests |
| `tinkyspeak` | PASS | Smoke, production build, 15/15 Playwright tests |
| `ghostbridge` | PARTIAL / FAIL-CLOSED | All executable non-live checks pass; provenance gate reports 7 drifts |
| `self_heal` | PARTIAL / ROLLED BACK | Codex repair and held-out verify pass; independent Claude review cannot authenticate |
| `self_tools` | NOT RUN / DO NOT RUN | Hardened source reports all six production readiness authorities unavailable; installed binary is older than those refusal gates |
| denial/live control | NOT RUN | Requires a separate explicit live-control grant and trusted stage |

## Failure zones that must stay visible

- Provider returns prose or `done` before a tool call.
- Provider claims Kist tools are unavailable because its own CLI tools are disabled.
- Tool JSON is malformed, names an unadvertised tool, or repeats a failed action.
- MCP child crashes, stalls, emits malformed framing, returns an error object, or leaves descendants.
- A build/test passed before the final mutation and is now stale.
- The workspace scanner observes build caches as source mutations.
- Dirty source repos contaminate a supposedly isolated repair.
- Installed and source binary identities diverge.
- A baseline hash drifts and an operator is tempted to rebaseline without provenance.
- COBOL compiles but returns the wrong fixed-width value, masks a return code, or hangs.
- Perslis reports a route but the frozen MCP/OpenAPI/shared-registry identities disagree.
- Tinky vision evidence is stale, the frame hash changes under readback, or control is enabled by error.
- A VM PID is reused, QMP/RFB identity disagrees, focus is wrong, or finalization leaves a process.
- A TinkySpeak command can reach production or a non-throwaway database.
- The agent manufactures a new tool but cannot reload, call, constrain, or cleanly retire it.

## Self-authored tool trial

The manifest contains a historical `self_tools/codex-grow-self-tool` trial for a narrowly scoped
signed-integer CSV sorter. It must not be run in the current state. A reviewer returning is only one
of six requirements: exact-parent held-out fitness, external rollback witnessing, hard aggregate
containment, actual-route identity-distinct review, sealed activation, and witnessed pre-spawn
budget reservation must all be production-backed. The installed binary is older than the repaired
source refusal gates, so invoking its `/grow` path would not test the contract described here.

## Cross-system mission sequence

The final non-physical mission is:

1. Create a disposable legacy application with one compiler defect and one semantic/oracle defect.
2. Have Codex inspect it through Kist, repair it, and pass a held-out build/test after the final edit.
3. Compile with GnuCOBOL and launch through Perslis's headless loopback path.
4. Observe the result through read-only GhostBridge/Tinky evidence and bind frame/text hashes.
5. Kill one MCP server after a successful observation, require bounded reconnect or explicit replan,
   and continue without replaying a mutation.
6. Interrupt after verification, resume from the saved boundary, and prove the old receipt is treated
   as stale until a fresh check binds the resumed workspace.
7. Emit one campaign receipt linking model route, action trajectory, source/binary digests, tool schema
   identities, process cleanup, and every deterministic oracle.

## Running the campaign

The repository-root `AGENTS.md` is Codex's recovery handoff. The bounded
`codex-kist-read-probe` also requires Codex, through Kist's read-only tool protocol, to read that
file plus the autopsy, memory-governance status, DGM roadmap, and this campaign before assessing the
current diff. The step cannot pass its process oracle without observed Kist tool use and explicit
`read_file` markers for every document, bounded Git status/diff markers, and both terminal assessment
lines. `REVIEW INCOMPLETE`, an incomplete assessment grade, and contradictory tool-unavailable prose
are explicit failures. A passing process receipt proves that bounded read/assessment contract; it
does not prove autonomy readiness.

Validate/list without executing:

```sh
python3 scripts/codex-capability-campaign.py list
```

Run the default read-only preflight:

```sh
python3 scripts/codex-capability-campaign.py run
```

Run build/test phases explicitly:

```sh
python3 scripts/codex-capability-campaign.py run \
  --phase kist_protocol --phase legacy_cobol --phase ghostbridge --phase tinkyspeak \
  --allow-workspace-builds --allow-subscription
```

Run the disposable Codex/COBOL self-heal only:

```sh
python3 scripts/codex-capability-campaign.py run \
  --phase self_heal --allow-subscription
```

The following historical command remains documented for fixture identity only. Do not run it until
all six readiness authorities are fresh, the hardened source is deployed through the sanctioned
gate, and an operator separately authorizes the trial:

```sh
python3 scripts/codex-capability-campaign.py run \
  --phase self_tools --allow-subscription
```

Receipts go to a fresh mode-0700 directory under the system temp directory unless `--output-dir` is
given. A skipped gated step is not a failure and is not evidence of capability.

## Completion bar

The estate is not “proven” until phases 0–7 pass twice from clean disposable fixtures, the seven
GhostBridge provenance drifts are reconciled to authoritative artifacts, all six evolution
readiness authorities are production-backed, the second run contains at least one injected failure
in each failure family, all children are gone afterward, and an independent verifier can reproduce
the receipt hashes. Phase 8 remains separately operator-gated and must be reported as untested until
real hardware/VM evidence exists.
