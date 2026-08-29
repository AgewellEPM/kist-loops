# Kist memory governance status

Date: 2026-08-28
Last verified: 2026-08-29
Posture: advisory recall is temporal; authority remains receipt-bound

## One temporal kernel

Swift `MemoryTemporalEnvelope` and the live Python Cortex runtime at
`~/.kist/cortex/memory/` separate:

- event/evidence time: `created_at` and optional `last_confirmed_at`;
- transaction time: `updated_at`;
- application time: `valid_from` and `valid_until`;
- access time, lifecycle, decay, and explicit recurrence.

Eligibility is evaluated before ranking or pinning. Invalid, retired, superseded,
future-poisoned, not-yet-valid, and expired records have zero salience. The bounded future-clock
allowance is five minutes.

For an unpinned eligible record:

`salience = base_salience × 0.5^(elapsed_days / half_life_days) × season_multiplier`

The decay anchor is `last_confirmed_at` only after verified reinforcement; otherwise it is
`created_at`. Reading, access counts, and ordinary transaction updates do not move that anchor.

| Class | Half-life |
|---|---:|
| `session` | 1 day |
| `very_fast` | 7 days |
| `fast` | 30 days |
| `medium` | 90 days |
| `slow` | 180 days |
| `very_slow` | 365 days |
| `none` | 36,500 days |

`none` is a compatibility class, not authority. Unsigned generic memory cannot request it.

## Explicit seasonal recall

A season may select months, Monday-zero weekdays, and a local half-open hour window under an IANA
timezone, including overnight windows. No season is inferred from prose, tags, filenames, file
timestamps, or one historical observation.

The default multiplier is `1.15` in season and `0.35` off season. An explicitly configured
off-season factor of `0` suppresses recall; the same unchanged record can reactivate when its season
returns. Seasonality changes relevance, never receipt authenticity.

## Shelf policy

| Shelf | Temporal policy | Authority |
|---|---|---|
| Project episodes and learning capsules | `medium` | advisory |
| Proven lessons, knowledge debt, and evidence-ledger projection | `slow` | advisory |
| Obstacle lessons and organizational rules | `very_slow` | advisory |
| Generic knowledge index | `fast` or `medium` only | unsigned advisory |
| Industry intelligence and benchmarks | `fast` only | unsigned advisory |
| Evolution proposals | `medium` only | unsigned advisory |
| CaptainLearning scorecard | separate 30-day policy | unsigned route bias only |
| Semantic/vector memory V2 | `medium` manual observations; `slow` content-bound checked lessons; cosine × temporal salience | unsigned advisory |
| Accepted receipts and sealed evolution archive | no salience decay; separate freshness and authority rules | authority-bearing only when validation succeeds |

Generic unsigned rows additionally reject pins, `none` decay, confirmation, reinforcement, access
history, contradictory scalar/nested clocks, and base salience above `0.8`. Stable-ID updates advance
transaction time only and preserve the original evidence/decay anchor and season.

## Legacy and raw-audit boundary

Legacy episodes, lessons, capsules, debt, and rules may derive an in-memory envelope only from their
own stable event timestamp. Reads never persist that projection. Generic rows with no explicit
event/transaction clocks cannot be safely aged and remain raw audit-only. File modification time is
never evidence time. Unindexed files in `research-archive/` are also excluded from operational
recall.

Checkpoint inventory:

- 26 generic rows are unknown-age audit-only: 10 industry observations, 6 evolution proposals, and
  10 benchmarks;
- zero generic rows are clocked;
- one research artifact is unindexed and raw audit-only.
- 18 V1 semantic rows (15 `auto-lesson`, 2 `win`, 1 `obstacle`) in the inspected live file
  `/Users/lukekist/.kist/memory/vectors.json` have no temporal envelope and remain audit-only;
  `metadata.at` is not accepted as evidence time.
- The live Cortex record directory contains 1,625 physical JSON rows. Under the repaired decoder,
  940 are undecodable audit rows because they have no trustworthy event time. Of the 685 decodable
  rows, 684 are `unverified-source-event-time`; only one row is currently retrieval-eligible. These
  counts describe migration debt, not 1,625 learned operational memories. The inventory was read
  with mutation and access-touch disabled.

A later genuine observation may append a newly clocked revision. Do not bulk-stamp or silently
migrate this history.

## Persistence and authority boundary

Writers publish the underlying report or artifact before publishing its memory index. JSONL
mutation refuses malformed, partial, oversized, unsafe, or capped input and uses an owner-only,
no-follow sidecar lock across read-modify-write. This is cooperative local persistence, not a
cryptographic authority seal.

The Python per-record `MemoryStore` now pins an owner-only real directory, safely tightens an owned
non-writable legacy directory to mode `0700`, and uses a pinned mode-`0600` cross-process lock.
Record reads and writes are no-follow, regular-file, owner, mode, link-count, identity, stability,
size, aggregate-capacity, JSON-depth/node/string, embedding-dimension, and finite-number checked.
Lifecycle read-modify-write operations are serialized, fork-inherited descriptors are invalidated,
and every lock wait is bounded. Per-file publication remains atomic and directory-synced.

Learning-index publication uses a distinct pinned mode-`0600` publication lock held from bounded
source snapshot through the final manifest check, store transaction, and PEEL evidence write. This
prevents cooperative indexers from publishing out of order without blocking ordinary store readers
during source traversal. Source directories and files are owner/non-writable/no-follow checked and
bounded by entries, directories, files, bytes, rows, and row size. An uncoordinated source writer can
still mutate after the last manifest check, and a multi-record process death can still leave a
partial generation. Absolute freshness needs writer participation or a trusted source epoch;
crash-atomic generations need a WAL/generation pointer or transactional database. The store remains
advisory and is not authority-grade. Operational reads fail closed, while `audit_inventory()` keeps
rejected physical rows visible as audit debt.

Semantic V2 uses the separate project-scoped `<projectRoot>/.kist/memory/vectors-v2.json` path. This
is a rolling-version barrier: the old timeless reader never sees V2 temporal/lifecycle revisions and
therefore cannot strip their fields or resurrect them after rollback. V2 refuses unsafe links,
special files, oversized/truncated/malformed stores, unknown or duplicate JSON keys (including
escaped-equivalent keys), duplicate physical identities, invalid vectors, unconstrained temporal
envelopes, and embedding-space/model mismatches. It enforces canonical logical/content identity,
one store-wide embedding signature, append-order transaction-time monotonicity, and terminal
lifecycle invariants. Partial-query salvage is explicitly reported as degraded health and makes the
recall ablation fail closed. Mutations reload under a cross-process, owner-owned sidecar lock,
revalidate owner/mode/type/link invariants, and atomically publish mode `0600`. Under the hardened
source policy, the owner-owned V1 file remains byte-preserved at mode `0644` for audit and is never
silently migrated or operationally recalled. The currently installed older binary still contains
the timeless V1 reader, so that sentence is not a claim about deployed behavior.

Manual semantic rows are unpinned, capped at `0.8`, and cannot claim confirmation, reinforcement,
access history, or `none` decay. Checked lessons require a bounded source locator and a SHA-256
binding to the exact stored text, but remain unsigned advisory data. Recall captures one clock,
applies lifecycle/validity/future-clock/season/decay eligibility before similarity, and ranks by
`max(0, cosine) × salience`. Reads do not touch clocks or counters. Recalled prose is bounded and
JSON-escaped inside an explicit untrusted-data boundary; embedded instructions are never promoted to
system policy or receipt authority.

ForgeSeal/AcceptedRun receipts and locally sealed evolution-archive rows do not enter relevance
ranking and do not decay. Accepted-run freshness may expire under its own policy and become a
`historical-seal`; authenticity is not erased.

EffortMemory, CaptainLearning, and several specialist/evaluation ledgers still use separate
policies. Checked semantic reinforcement is an internal typed-call boundary, not yet a
ForgeSeal/AcceptedRun evidence binding.

## Verification and provenance warning

The full Python temporal repair is durably preserved in local commit
`08be5e4af15c7c93821378c66f27e0150bc5d22b` (`fix(memory): fail closed on temporal
projections`) on `agent/runtime-hardening-research-intelligence`. Its exact staged snapshot passed
160 affected tests. On 2026-08-28, the integrated live checkout passed 468/468 Cortex-memory tests.
The complete temporal bundle is
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-runtime-temporal-08be5e4.bundle`, SHA-256
`3f46824757b88c08402e796fd61fc8a34b6d0f69fdfc062859772ffacd10091e`, mode `0600`, and verifies as
a complete Git history. Commit `99ea435` and its older bundle remain a historical predecessor, not
the final repair authority.

A separate fail-closed reviewer-identity correction is preserved in local commit
`e19019c100b411c3b6a44bce2233ab603877fa3e`; it canonicalizes provider/model identities before
uniqueness and high-risk independence checks. The complete recovery bundle through that commit is
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-runtime-recovery-e19019c.bundle`, SHA-256
`639eed705b59318235dacab7fd68504410af3aba32141161444fd918fb0f9d28`, mode `0600`.

The persistence and source-publication repair is preserved in local commit
`773112d12dd4e85b7051ab2ccb1bb0d9d36cacaa` (`fix(memory): contain persistence and
publication`). Its exact detached snapshot passed all 435 tracked Cortex-memory tests; the focused
store/indexer suite passed 93/93, and the integrated live checkout passed 513/513. Independent
adversarial review reproduced the pending-flock fork leak and publication self-deadlock before the
fix, then found no remaining blocker after both regressions passed. The complete Git bundle is
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-runtime-memory-773112d.bundle`, SHA-256
`84b62ea7453b06cae292802f96756231fc21b05c19e9d7cb8edab01b34f56f64`, mode `0600`, and verifies as
a complete history through that commit.

No push was performed. Locally, Python `HEAD` is four commits ahead of the recorded origin-tracking
commit; no remote query was used for this reconciliation. The broader runtime checkout remains
dirty with unrelated autonomy/runtime/security/provider/budget work. Seven tracked supporting
memory-test files and seven untracked supporting memory-test files remain outside the temporal
lineage. The five temporal production files and five direct temporal tests are clean and
byte-identical to the repaired lineage. The older
`/Volumes/PRO-G40/mythos-cortex-memory` sidecar is a different July 2026 lineage and is not authority
for the live memory organ.

The working Swift semantic/temporal/evolution slice remains uncommitted in the separate Kist
checkout. The Python bundles do not preserve it. A 217-file source overlay against base `5f6158c`
contains the temporal consumers, semantic integration, evolution authority contracts, direct tests,
their dirty compile/test dependency closure, campaign assets, and corrected governance documents.
It is stored at
`/Volumes/PRO-G40/kist-runtime-checkpoints/kist-recovery-source-5f6158c-20260829-final3.tar.gz`, mode
`0600`; every archive member was validated byte-for-byte against the live checkout. That archive is
preservation, not a Git commit, installation, or promotion. The prior 142-file `final2` and older
69-file semantic overlays are historical predecessors.

Swift semantic V2 remains source-only and deliberately unpromoted. The final combined
memory/evolution/security gate passed 392/392, the capability-campaign unit suite passed 39/39, and
a fresh full Swift package run executed 4,914 tests with six intentional skips and zero failures.
Final `git diff --check` passed. The installed `~/bin/kist-current` is a different, older binary: it
contains the timeless V1 path and does not contain the V2 path or the new evolution-refusal strings.
The live V1 vector file retained SHA-256
`5c8dcf15739921ce9fc5878d09f0dbe8bc0fcad78be485c85e812afd22d26200`, and no live V2 store was
created during verification.

The resident Python daemon also predates the repaired commits: at the checkpoint, PID 8579 had run
`kist_runtime.py daemon --interval 300` since 2026-08-27. Autonomy is disabled, but the daemon still
runs non-autonomy indexing cycles, and process-resident imports cannot be assumed to match current
files. No drain or restart was authorized. Python source policy is therefore preserved and tested,
not yet production-live in that daemon. The live record directory also remains mode `0755` and has
no new lock sidecars; the safe `0700` migration has not been invoked against production data.

Promotion requires an explicit old-process drain and a rollback policy that keeps semantic memory
disabled for a reverted timeless binary. Frankenstein remains on the table; none of these memory
changes arms autonomy.
