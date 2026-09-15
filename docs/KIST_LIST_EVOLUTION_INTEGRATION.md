# LIST observations and Kist evolution

LIST can feed Kist's dated advisory memory and propose bounded investigations. This
does not arm unattended code execution or promote an evolution candidate.

## Operator commands

```sh
kist --list-learning-status --project /Volumes/PRO-G40/kist-loops
kist --list-learning-sync --project /Volumes/PRO-G40/kist-loops
```

Status reads the local learning shelves. Sync connects only to the user-configured
`list` MCP server, requests a bounded project-specific page, validates provenance
and timestamps, and deduplicates it into the existing learning shelves. These
commands do not need a model or generate inference charges. Unavailable or invalid
observations cannot establish successful learning.

Ordinary Kist sessions also refresh LIST context, at most once per minute during
active turns. `--no-memory` disables that ingestion and recall. Review the dated
observations in `.kist/learning/list-observations-v1.jsonl` and the investigation
proposals in `.kist/learning/list-proposals-v1.jsonl` under the project root.
Proposals are advisory data, not executable goals or approval grants. These versioned
paths reuse Kist's existing temporal record and transaction machinery while keeping
LIST prose invisible to older processes that only read generic learning shelves.
There is no automatic migration from generic shelves; existing records remain
byte-preserved unless the operator performs a separately scoped repair.

## Background attachment

The optional user LaunchAgent `com.kist.list-learning` runs one observation sync
every five minutes through `scripts/kist-list-learning-sync.py`. It uses the
installed Kist executable, takes the existing deployment lease in shared mode, and
defers when promotion holds that lease. Each invocation has a 90-second deadline,
a 64-KiB output ceiling, and process-group cleanup. No model session is kept alive.

Inspect or stop an installed attachment with:

```sh
launchctl print gui/$(id -u)/com.kist.list-learning
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.kist.list-learning.plist
```

Starting the attachment requires a deployed Kist that supports the sync command.
Use the sanctioned `kist-rebuild --force` promotion path; do not copy a binary into
the installation. A Kist chat already running before deployment keeps its old
code and MCP registry until it is restarted.

## Observation boundary

The local adapter is `~/file_memory/list_kist_mcp.py`, registered as `list` in
`~/.mcp.json`. It exposes only `recent_observations` and `status`, reads the existing
LIST catalog and bounded collector log, and never creates a catalog, starts capture, analyzes a
video, calls a model, or executes a workflow. Stored collector heartbeats report
their original dates; they are not proof that a collector is currently running.

Ingestion accepts direct observations with an exact project path, original event
time, source locator and content digest. It excludes protected/generated paths and
rejects cross-project, future, stale or malformed pages. Actor attribution remains
unknown: file activity may come from Luke, Kist or another application. It does
not turn observed activity into a claimed personal preference. Reading an old
observation does not rejuvenate its memory age.

Video workflows linked only by inferred project names do not cross this exact-path
boundary. LIST's existing capture settings and archive collection remain separate;
this attachment does not fill capture gaps or infer what happened during them.

## Held-out referee

The evolution referee compares host-captured output and exit status from the exact
parent and child against the same frozen private expectations. Improvement requires
newly solved cases, a positive solved-count delta, no regressions, and successful
infrastructure in both arms. Candidate-reported pass/fail fields are not its oracle.

Fitness travels with the benchmark batch and is bound into evaluation and archive
authority. Copied results, a mismatched parent, or missing fitness cannot authorize
a passing candidate. Test-only authority remains visibly separate from production.

The current macOS runtime still lacks qualifying hard process containment and a
trusted private-suite execution backend. It therefore refuses candidate execution
before launch. The external rollback witness, actual-route distinct reviewer,
sealed activation, and externally witnessed budget reservation also remain required.
None of the four runtime autonomy switches is enabled by LIST learning or by this
referee integration. A separate wake-up operation requires fresh evidence for all
documented gates.
