# Real Kist / COBOL MCP benchmark

This suite sends native SML workflows through a real Kist CLI and the existing local
`cobol-build` MCP server, then independently compiles and executes returned COBOL.
It measures construction, intent handling, refusal, schema validation, approval,
restart behavior, and local latency. It does not accept the builder's `verified`
flag as behavioral proof.

The first measured baseline is [baseline-2026-09-08.md](baseline-2026-09-08.md).
The [repair results](repair-2026-09-08.md) resolve all 24 failing runs and add a
separate 42-case regression suite in `repair-regression.v1.json`.

The [100 new-case and rephrasing experiment](unseen-100-2026-09-09.md) compares
model-assisted Kist with the standalone builder, including fresh-context memory
controls. All 600 requests were scored as construction tasks: refusals earn no
capability credit. Its [frozen paired corpus](unseen-paired-100.v1.json),
[audited scores](unseen-100-2026-09-09.json), and
[per-case comparison](unseen-100-2026-09-09.csv) are archived alongside the report.
The model-assisted experiment uses its separately archived runner; the default
`run.py` command below remains the deterministic repair/regression suite.

## Run

Requires Python 3, an installed `cobc`, a Kist binary supporting the durable SML
REPL, and the existing absolute-command `cobol-build` entry in `~/.mcp.json`.
There are no downloads or additional Python packages.

```sh
cd /Volumes/PRO-G40/kist-loops
python3 -B -m unittest discover -s benchmarks/cobol -p test_benchmark.py -v
python3 -B benchmarks/cobol/run.py \
  --binary /Volumes/PRO-G40/kist-loops/.build/debug/kist \
  --output "$HOME/kist-cobol-benchmark-run-01"
```

Output must be a new directory. The default is the full 101-case manifest, repeated
twice: 202 case runs. Use `--case reduce-max-7 --case vowel-count-40 --repetitions 1`
for a clearly labeled subset. Explicit `--binary` selection prevents accidentally
benchmarking a different installed build. The installed CLI can be supplied once
it supports the same REPL; do not interpret a CLI incompatibility as COBOL refusal.
If another task may rebuild `.build`, benchmark a private fixed copy of the selected
executable. The suite rejects a campaign when a pinned input changes during its run.

Exit **0** means all measured contracts passed; **1** means a completed campaign
found product failures; **2** means incomplete or infrastructure evidence. Known
defects are scored as failures, never hidden with expected-failure annotations.

## Fixed settings and contracts

`suite.v1.json` defines the prompts, contracts, seed `9082026`, four random inputs
per numeric program, and two repetitions. Change the suite version when changing
the task distribution or oracle contract.

| Set | Cases | Purpose |
|---|---:|---|
| Construction | 72 | All 13 families, three ABI shapes, and boundary sizes |
| Intent | 10 | Paraphrases, casing, and size/threshold ambiguity |
| Unsupported intent | 2 | Correct implementation or explicit refusal; wrong substitution fails |
| Refusal | 10 | Unsupported operations, composites, invalid sizes, empty prompts |
| Schema | 7 | Missing/wrong-typed prompt and unknown fields rejected before MCP dispatch |

Numeric sizes are 1, 2, 7, 31, 100, and 999; inputs stay inside signed five-digit
storage. Each returned numeric program receives 15 independent checks: fixed
sign/boundary/threshold examples, four varied seeded arrays, and a permutation.
Integer averages truncate toward zero. String sizes are 1, 7, 40, and 999 with nine
ASCII examples each; vowels are case-insensitive and digits are ASCII 0–9. Indexed
file sizes are 1, 3, 31, and 100, with exact ascending keys checked twice in fresh
directories. This indexed benchmark checks the builder's fixed record-writing
routine; it does not establish arbitrary database CRUD, durability, or concurrency.

Every case performs four separate CLI sessions: start, stale approval, exact
approval, and restart/repeated approval. The recorder verifies zero tool calls
before approval, no stale-approval changes, one actual call for a valid schema,
terminal claim release, and no replay after restart. Schema cases require zero
actual MCP calls. These checks cover Kist's schema gate, not malformed requests
sent directly to the remote server.

Before grading, eight calibration controls require the independent evaluator to
accept correct maximum code and reject a zero-seeded maximum, constant range,
off-by-one sum, invalid COBOL, nonzero exit with correct text, timeout, and output
overflow. The Python references never import the builder or its own validator.

## Evidence and interpretation

Read `report.md` for results and `benchmark.json` for machine-readable metrics.
Each case retains its workflow, durable state, exact MCP request/reply trace,
builder response, returned source, independent caller, executable, and all
inputs/expected/observed outputs. Process records include status, deadlines,
elapsed time, and stream hashes. The source, binary, compiler, interpreter, suite,
and harness hashes are checked before and after the run.

The recording relay forwards the actual stdio bytes to the configured local
`cobol_build_mcp.py`; it supplies no mocked answers. Its overhead is part of the
reported local timing. Only the selected server's secret-free command/arguments
and PATH settings are copied, not the user's whole MCP configuration.

Category and family scores are separate: a refusal can satisfy a refusal contract
but never counts as a constructed program. Protocol/transport errors are not
honest refusals. Successful-build MCP and approval p50/p95/p99 timings are separate
from independent compilation and program execution. Two repetitions establish a
small deterministic repeatability check, not a statistical reliability claim.

The run uses one case at a time, a 60-second CLI deadline, 30-second independent
compile deadline, 5-second executable deadline, and 1 MiB per process output stream.
Child process groups are stopped and reaped; MCP start/stop identities are retained.
Fresh directories contain ordinary fixture writes. This is cooperative local test
cleanup, not a sandbox for hostile generated programs. No autonomous promotion,
model route, UI, VM, network dependency, or production configuration is activated.

These artifacts are benchmark evidence, not a sealed Kist mission receipt. Passing
this finite corpus does not establish universal correctness or autonomous evolution.

## Next benchmark sets

1. **Repair regression:** rerun this exact corpus and seed against a changed builder,
   then evaluate new, separately authored held-out prompts and examples. Require
   positive capability gains without losing refusal or lifecycle behavior.
2. **Business programs:** define explicit file layouts and golden outputs for a
   transaction ledger, reconciliation, fixed-point invoice totals, and payroll
   arithmetic before adding those capabilities. Current templates do not establish
   these end-to-end abilities; keep their scores separate from numeric reductions.
3. **Evolution acceptance:** retain exact parent/candidate hashes, independent
   review provenance, held-out results, and host-owned acceptance. This benchmark
   alone must not authorize candidate promotion or wake unattended evolution.
