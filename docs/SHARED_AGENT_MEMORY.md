# Agent creation, search and shared history

Kist exposes `create_agent`, `list_agents`, `spawn_agent`, `spawn_specialist` and `shared_memory` to authorized task-driven loops. A newly created definition is immediately discoverable and reusable in later sessions. No restart is needed to update the registry.

Plain requests such as “Create a reusable agent named historian” or “Use create_agent to register my specialist” run through a metadata action surface in the REPL and one-shot CLI. That turn can register definitions and read context; it cannot write source files, execute shell commands or delegate arbitrary work. After registration, a delegation request can use the agent immediately in the same session. Explicit Builder flags still select the governed Builder.

Ask Kist to create a focused specialist, name the tools it needs, then delegate a bounded task to it. Definitions are validated and published under the original project's `.kist/agents/<name>.md`, including when the creator executes in a worktree. Creation does not overwrite a different existing definition. The returned path and SHA-256 identify what was actually stored.

Creation is a metadata write. A delegation request containing a broad “do not change” or “no edits” clause clamps the child to reads, including when another clause asks it to create a definition. Give a metadata-creating specialist an explicit tool list without source-write or shell tools, and state its permitted creation task directly. Registration feedback uses the validated metadata result; source mutations retain the build/test checklist.

Tools, admitted providers, turn limits, approval requirements and remaining delegation depth come from the host and creator. Each descendant can only narrow these capabilities. An empty tools array creates a tool-free specialist; it still receives authorized memory context. The `memory` field accepts `user`, `project` or `local` and cannot widen the creator's memory scope. `--delegation-depth` controls nested delegation, and `--budget` shares one token ledger through the delegated team.

Generic and named background agents run in isolated Git worktrees. `spawn_agent` or `spawn_specialist` with `background=true` returns a handle for `join_agent`, `steer_agent` or `cancel_agent`. Join the work before ending the turn. A loop cancels and drains its own unfinished children before releasing its checkpoint; incomplete delegated work makes that turn unsuccessful. Empty worktrees are removed; changed branches remain available for review under the existing isolation policy.

Root, resumed, generic, named, nested and background headless loops receive shared recall before their first model call. Plan-execute planner/coder calls, fleet planners/workers and council participants use the same host memory access. Every recorded agent has run, parent, root and session identifiers plus its original memory project and separate execution directory. Fleet controller history uses the fleet board ID. The explicit `--no-memory` option disables this shared recall and history layer. Library hosts opt in with `ToolContext.agentMemory`; an unconfigured host does not gain implicit filesystem access.

`shared_memory` supports three modes:

| Mode | Result |
| --- | --- |
| `search` | Ranked context, temporally eligible episodes, content-bound fetched research and dated observations across known authorized projects. Supplemental organizational lessons remain scoped to the original host project. Requires `query`. |
| `history` | A chronological page of one project's raw events, including failed and cancelled work. Defaults to the original project; optional `run_id` filters one agent. |
| `history_search` | Ranked matches in raw history, including prior summaries, without presenting them as current knowledge. Requires `query`. |

Search understands identifiers such as `orchidLaunchCode`, snake_case, C++, C# and Go. Results include original source locators. `context_brain` and agent discovery use the same lexical ranking. The `before` argument continues from a returned `next_cursor`; each page also reports scanned, indexed and rejected records, searched projects and known authorized project count. Treat cursors as opaque and restart a search if its query, run filter or authorized project set changes.

Default search includes the original project, explicit `--allow-read` roots and cataloged projects under those roots. Kist registers projects when it configures shared memory, storing private discovery records beside its active config in `agent-memory-projects/v1`. The catalog survives sessions; entries grant no access. Each query reapplies this session's grants and checks physical directory identities. There is no recursive crawl of a broad read root. An older project not yet registered can be selected with an explicit authorized `project` argument, or registered by opening a Kist session there. Catalog discovery reads at most 1,024 entries and reports invalid or omitted entries.

An explicit `project` narrows the search to that project. `project` memory scope restricts all recall to the original project; `local` restricts event recall to the current root run. Execution in a temporary worktree does not change these host scopes. Reading never refreshes an event's age. Unknown-age generic data, read observations and repeated final summaries remain raw history instead of becoming fresh evidence. Cross-project curated files, episodes and research use confined reads; legacy supplemental organizational readers remain in the original host project.

The derived history index covers a bounded window of up to 30,000 records per project and revalidates matching original bytes, timestamps and project identity before returning them. Caches live only under the original host project's `.kist/cache/agent-history-index/v1`. One search handles at most eight projects and shares allowances of 10,000 index-building record reads, 1,000 candidate reads and five seconds for building index shards. Partial builds retry their source window; additional project groups and candidate windows return continuation. Directory enumeration and metadata checks still grow with archive size; these allowances are not hard whole-run resource limits. An unavailable index falls back to bounded raw reads with explicit degradation.

Raw chronological pages return at most 100 rows through the tool. Research recall scans at most 128 run directories and 8 MiB of evidence per selected project and reports limits or malformed evidence. Confined episode recall accepts a stable snapshot up to 8 MiB, preserving original event clocks; an unsafe or oversized source is reported. A result from a bounded page is not an exhaustive archive search. Check `history_search_complete`, `retrieval_issues` and continuation rather than inferring completeness from a matching answer.

Tool responses also fit a 6,000-byte JSON window, below the CLI's default observation limit. A raw history page may return fewer rows than requested; its cursor preserves every omitted older event for the next page. Search keeps the best-ranked visible rows and reports `result_window_limited` and `results_omitted_from_page`; refine the query or filter by run for more specific evidence. Search cursors continue chronological scan windows, not individual ranked results. Excerpts disclose clipping, and source locators identify the full immutable records. Raw search includes run, parent and root IDs as well as event text.

History lives in `.kist/runs/agent-history/v1` as immutable owner-private files. Appends use confined, no-replace publication and fsync. Concurrent processes write distinct records; restart and worktree removal leave original-project history intact. Events sort by original time and a stable ID tie-break, not an invented causal order between simultaneous processes. The archive excludes hidden reasoning and token fragments. It masks common secrets and clips oversized event details with their original byte count and digest recorded. Directory enumeration currently scales with archive size; page file reads are bounded.

## Typed memory schema

Every recall candidate instantiates one of four record types with distinct policies. **Facts**
(curated project context) persist until superseded — edited or deleted, never decayed.
**Episodes** (history events, episodic records, fetched research) decay by age and are
append-only; a later episode never overwrites an earlier one. **Procedures** (the ProcedureStore
plus advisory lessons) are reinforced how-tos: persistence grows with verified reuse, decays by
disuse (slow half-life anchored on the last verified confirmation), retrieval is by task
applicability, and updates are reinforcement or supersession — deposits require a proven source,
reinforcement requires verified evidence, and every version is an immutable audit record under
`.kist/memory/procedures/v1`. **Working state** is task-scoped scratch; the gate denies it
unconditionally (`working_state_leak`) so finished-task residue can never poison durable recall.
A dormant procedure whose failure situation recurs is re-presented to the gate by signature
applicability, so "this bit me before" works for how-tos, not just episodes.

## Admission gate and reactivation

Every `search`-mode candidate — history events, curated project context, episodes, research
evidence, and supplemental lessons — passes one fail-closed admission gate before it can reach a
model. The gate applies per-provenance temporal policy (curated facts are supersession-governed;
research evidence decays fast; events, episodes and lessons decay medium), denies unknown-age,
out-of-scope, lifecycle-ineligible (retired/superseded/expired/future) and below-floor candidates,
and treats its own evaluation failures as denials. Retrieval is not authorization: retrievability
never implies influence. Raw `history`/`history_search` pages remain the ungated forensic surface,
labeled "raw event; not current knowledge". Each recall writes one bounded audit record under
`.kist/memory/admission/v1` (counts, denial reasons, bounded denial samples); tool responses report
`admission_denied_rows` and `admission_denial_reasons`, and the pre-model brief discloses gate
counts.

A memory that decayed below the floor can return only on context recurrence: signatures derived
from recent FAILURE details (never from the query) are matched against dormant candidates, and a
match at or above the threshold readmits the memory at the floor. Reactivation lifts decay only —
it never resurrects retired, superseded, expired, or unknown-age records. Each fresh reactivation
appends one bounded overlay record under `.kist/memory/reactivation/v1` (reconsolidation: current
context merged, original bytes untouched, event ages never refreshed); the overlay boost itself
halves every seven days, so an unrecurred memory sinks back. Reactivated entries are surfaced
after ranked results because they are query-dissimilar by construction.

## Forgetting

Forgetting is a designed feature with two regimes, both receipted under
`.kist/memory/forgetting/v1`. **Retention sweeps** (`MemoryForgetting.retentionSweep`) remove
admission-audit and reactivation-overlay records past their retention window (default 90 days)
so the bounded governance stores stay live. **Governance forgetting**
(`MemoryForgetting.forget(term:)`) is right-to-delete: it purges matching episode rows (raw-byte
match, deliberately over-inclusive), entire procedure version chains, and the reactivation
overlays bound to the forgotten memories, then runs a residual scan and records whether removal
is PROVEN in the receipt. Receipts store only the SHA-256 of the request term — never the
content. Deletion is never blocked on receipt capacity; a missing receipt is reported loudly
instead. Deliberately out of scope: the agent-history archive (append-only forensic surface;
purging it is a separate operator-owned decision) and admission audit records (digests and
reasons, no memory content).

Recalled text and model summaries are advisory data. They grant no permissions and establish no accepted completion, independent review or evolution authority. Training or analysis consumers should retain original timestamps, provenance, failure status and usage labels. Operational model fallback remains available; refusals and access denials are not execution-routing shortcuts.
