# Roadmap evidence harness

These local commands measure coding, history recall and retained training evidence.
They do not enable production autonomy, train a model, upload data or confer
evolution acceptance. Live inference uses the admitted Codex route, with same-model
review explicitly marked `independent=false`.

Freeze a corpus before inference. Preserve its manifest, protected inputs, private
cases, producer deployment manifest and every attempt directory. Do not edit a
running harness or replace an original failed result with a later assessment.
`corpus.py`, `interrupted.py` and `training.py` generate the distinct coding,
interrupted-refactor and verifier-diagnostics fixtures; each command exposes its
arguments with `--help`. Interrupted refactors model an invocation boundary, not a
process-crash recovery claim.

`coding.py --corpus CORPUS --output NEW_OUTPUT --binary INSTALLED_KIST --repetitions 2`
runs the installed CLI and checks copied final source with host-controlled cases.
`--baseline-source` checks the original fixtures without inference. `release.py`
first verifies the executable and adjacent required skill resources, then checks
that those inputs stay fixed across invocations. A missing bundle is recorded
before any model call. This check is limited to required release inputs, not a
whole deployment attestation.

`memory.py --corpus FROZEN_MEMORY --output NEW_OUTPUT --binary INSTALLED_KIST --repetitions 2`
seeds one physical archive and reopens it in separate CLI processes. Each result
checks the exact original value, timestamp and locator, unchanged seed bytes and
the current invocation's reported usage. `--freeze NEW_CORPUS --mission MISSION_ID`
creates a new synthetic 3,006-event fixture. Reuse the same frozen corpus for both
releases. Keep historical binaries labeled as historical copies, including how
their required resource files were retained.

`shared_projects.py --corpus FROZEN_MEMORY --output NEW_OUTPUT --binary INSTALLED_KIST`
registers two disposable projects through real CLI starts with no model calls,
then verifies default recall from an authorized project across separate processes.
A matching event in a registered but unauthorized project must stay excluded.
A final broad query must expose incomplete search and continuation. Every phase
retains source bindings, observations, reported usage and process cleanup. It
stops on a failed phase before running dependent inference.

`numeric.py --parent FROZEN_CODING --output NEW_CORPUS` preserves prior cases and
adds the large finite-integer/float mean regressions found during review. That
derived corpus explicitly records the later inspection; it is not unseen DGM
evaluation and must not be relabeled as training data.

`compare.py` accepts repeated `--baseline` and `--candidate` campaign directories
and explicit `--baseline-reassessment` bindings. It rejects different paired task
coverage and corpus identities. It counts failed attempts in token and latency
metrics; a smaller number of calls caused by early failure is not a capability gain.
The proposed half-token goal additionally requires unchanged recall evidence.

`export.py --corpus CORPUS --campaign CAMPAIGN --output NEW_OUTPUT --binary INSPECTOR
--binary-sha256 SHA --producer-build-manifest PRODUCER_MANIFEST` creates versioned
JSONL without model calls. The installed inspector authenticates historical sealed
Builder snapshots; the exporter joins those records to original requests, exact
source mutations, host verification, failures, reported usage and producer identity.
An exit code or model's completion statement cannot establish a success label.
USD cost stays null when unavailable.

Use `--reassessment BINDING` for an explicit correction that retains the original
result. Use `--adverse-observation RECORDS` to withdraw success eligibility after
additional checks fail on the same source. Such observations can only downgrade a
label and preserve the earlier scoped outcome. Always carry known later failures
when exporting; the exporter cannot discover omitted external evidence.

Corpus split controls training eligibility. Reserved evaluation corpora cannot be
relabeled for training. Supply previous JSONL with `--prior-export` to detect exact
task/source overlap across splits. This detects only supplied exact overlap;
semantic contamination and unprovided history remain unassessed. Failed and
partially exportable attempts remain represented. No private evaluation case
payloads are included in the JSONL.

Run `python3 -m unittest discover -s benchmarks/roadmap/tests -v` from the repository
root for local process, sandbox and evidence checks. Sandbox/process-group cleanup
is observational and is not aggregate CPU/RAM/PID containment for DGM experiments.
