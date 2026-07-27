# Cockpit ideas mined from ModularCode → the Captain cockpit

**Date:** 2026-06-26 · Source: `/Users/lukekist/Downloads/ModularCode-main` (the March GUI-IDE
precursor — same dream, 149K-line monolith). These are the genuinely-reusable *concepts* extracted
for the Mythos/Captain cockpit. **We port the data model + idea, NOT the code** — ModularCode's
versions are `@MainActor ObservableObject` GUI singletons; we rebuild each as Foundation-only pure
data + a trustworthy-by-construction reducer, the way the rest of Mythos is built.

## The one invariant that makes them safe
Every idea below renders **MEASURED** facts, never claimed ones. Replay shows what *measurably*
happened (AgentTrace spans, committed diffs, test exit codes, signoff ledger). Analytics rank on
*measured* tokens/outcomes, not self-report. Same rule as the trace + Fleet Cockpit: **measured
drives display; claimed stays advisory until the critic verifies.** ModularCode had none of this
discipline — that's exactly what we're adding.

---

## 1. AgentReplay — scrub the fleet's run back (highest-value, lowest-risk)
**ModularCode had:** `AgentMapReplayEngine` — records a run as `ReplayFrame`s (each a point-in-time
`AgentSnapshot` + `TaskFlowSnapshot` + `StatsSnapshot`), with `KeyframeMarker`s and a
`ReplayTimelineEvent` stream. You can rewind a multi-agent run frame-by-frame.

**Mythos has the data already** — `AgentTrace` records measured spans (per-LLM-call, per-tool, with
tokens/duration/vendor/role/finish). We just don't *replay* it; we print a summary.

**Fold-in:** a `FleetReplay` (pure) that folds the span log (+ the `.fleet-progress.jsonl` heartbeat +
signoff events) into an ordered, scrubbable timeline with keyframes ("plan frozen", "agent E2
signed off", "drift flagged", "merge"). Cockpit gets a **rewind** view; the CLI gets a `kist replay
<traceId>` post-hoc tree. Read-only over data we already have → near-zero risk, high "wow".
**Priority: FIRST.** It's the cockpit feature nobody else ships and it's almost free.

## 2. Capability scores — learned routing, not static role-binding
**ModularCode had:** `AgentCapabilityScore` per crew member — a learned skill rating used to route a
`DevTicket` to the agent best at it.

**Mythos has:** static role→vendor binding (`--planner openai --critic gemini`) + EMA fitness already
in `CaptainMemory` (the same idea, half-built).

**Fold-in:** a `CapabilityLedger` (pure) keyed by `(role, vendor)` that accrues a **measured** success
rate (verified signoffs / attempts) + cost-per-success from the trace. The planner/router can then
*suggest* the best-scoring vendor per role — upgrading `--coder deepseek` (you pick) to "the router
learned DeepSeek wins coder tickets at 1/8 the cost" (it suggests). Gate it on **verified** outcomes
only (no self-rated skill). **Priority: SECOND** — it's the moat's "gets smarter over time" story and
feeds the benchmark.

## 3. Longitudinal analytics — per-vendor cost trends + rankings (the proof dashboard)
**ModularCode had:** `AgentMetrics`, `DailyAgentStats`, `WeeklyTrend`, `AgentCostBreakdown`,
`AgentRanking`, `AggregateStats`, `AnalyticsExport`.

**Mythos has:** per-run, per-vendor token spans + budget — but no *across-run* dashboard.

**Fold-in:** roll the per-run `TraceSummary`s into a durable `analytics.jsonl` → per-vendor / per-role
**cost-per-verified-success** over time, rankings, weekly trend, CSV export. This is the missing half
of the proof story: "over 200 runs, Gemini-as-critic caught N real issues at $X — here's the data."
Renders to TTY now, to the cockpit later. **Priority: THIRD** — it's also the honest benchmark
substrate (quality-per-dollar, per the research).

## 4. The agent MAP — a live node-graph view (alternative to the Kanban board)
**ModularCode had:** `AgentMapEngine` — `MappedAgent` nodes + `AgentConnection` edges + `TaskFlow` /
`TaskFlowStage`, a live graph of who's doing what and how work flows.

**Mythos/Captain has:** the Kanban board (TO DO / DOING / DONE) from the cockpit screenshot.

**Fold-in:** an optional **graph view** of the fleet (agents = nodes, dependency/handoff = edges,
lease scope on each node) fed by the same `FleetCockpitModel` data. Better than a Kanban for *seeing
collisions and dependencies* at a glance. **Priority: LATER** (GUI-surface dependent; the board is
fine for v1).

## 5. Tickets + sprints — the work-unit model (mostly already there)
**ModularCode had:** `DevTicket` (work unit), `CrewSprint` (batch), `CrewPerformanceMetrics`,
`CrewChatMessage`.

**Mythos/Captain has:** the sprint board + per-turn metrics already in the cockpit; the plan-DAG step
is effectively the ticket; the baton carries handoff.

**Fold-in:** mostly a naming/UX alignment — treat a plan-DAG step as a "ticket", a fleet run as a
"sprint", surface `CrewPerformanceMetrics` (verified/claimed ratio — already on the board). Low new
work; mainly makes the cockpit legible. **Priority: incidental** (rides along with #1/#3).

---

## Recommended order (folds into the Captain cockpit roadmap)
1. **FleetReplay** — scrub the run; the standout, near-free over existing spans.
2. **CapabilityLedger** — learned per-(role,vendor) routing on *verified* outcomes.
3. **Longitudinal analytics** — cost-per-verified-success dashboard + export (also the proof harness).
4. Agent-map graph view + ticket/sprint UX polish — when/if the GUI cockpit surface is built.

## What we deliberately leave behind
The `@MainActor ObservableObject` singletons, the SwiftUI/Combine coupling, the 149K-line IDE weight,
the Claude-centric `ClaudeAgentAnalytics` (we're per-vendor). We take the *ideas*, not the monolith —
which is the whole lesson ModularCode taught.
