# Bug-Bounty Assistant — Two-Edition Architecture (Pass 1, 2026-06-30)

## The split (Luke's call)
Two **separate distributions**, not a runtime toggle:

- **PUBLIC edition** — this repo. Fail-closed gate; ships to everyone. The bypass capability is **physically
  absent from the source**, so nothing (config, prompt, AI) can produce full access here.
- **FULL-ACCESS edition** — a **separate private repo Luke controls** and hands to vetted security teams.
  It imports the same shared core and supplies its own policy with broad, *attested* authority.

Why two repos beats a flag: a public binary with a flippable "scope off" switch is unauthorized-access
tooling one mistake away from CFAA exposure. If the capability isn't in the code, there's nothing to flip.

## The seam (one boundary, zero duplication)
```
SHARED CORE (this repo, Sources/AgentCore/Bounty/)
  BountyProgram.swift            rules model: AutomationPolicy, TestMethod, BountyProgramRules,
                                 BountyAction, BountyDecision
  BountyAuthorizationPolicy.swift  protocol BountyAuthorizationPolicy  ← the seam
                                   PublicEditionPolicy  ← the ONLY conformer in this repo (fail-closed)
                                   BountyGate           ← facade; defaults to PublicEditionPolicy

PRIVATE FULL REPO (Luke's, separate)
  imports the core, adds  FullAccessEditionPolicy : BountyAuthorizationPolicy
  flips its ONE wiring line:  BountyGate(policy: FullAccessEditionPolicy())
```
The rest of the app is edition-agnostic — it only ever calls `BountyGate.evaluate(...)`.

## What scope means in each edition
- Both editions still evaluate inside an **attested** `SecurityEngagement` (the hardened, fail-closed
  host/repo membership gate). "Full access" = a BROADER attested authority (warrant / ROE / owned-CIDR)
  with relaxed *program-courtesy* rules (rate caps, AI-tooling bans, auto-submit), authored only in the
  private repo. The public edition keeps every courtesy rule on and a human on the submit button.

## Pass 1 — BUILT (this commit) · status: PROTOTYPE
The per-program **rules engine** (plan checklist item #1's second half), on top of the existing
`SecurityEngagement` scope gate. Public edition enforces, fail-closed, in order:
1. **scope** — action must name a target, and every target must be in the attested engagement
2. **categorical bans** — DoS / social-eng / exfil / lateral-movement / physical refused for every program
3. **automation policy** — honors `banned` / `restricted` (passive-only) / `allowed`
4. **vuln class** — active findings must be in the program's accepted classes (empty set ⇒ refuse)
5. **traffic budget** — rate limit honored; unknown limit forbids automated traffic
6. **submission** — never auto-submits; a human stays on the button

17 fail-closed tests, one per rule (a regression names the exact rail). `BountyRulesEngineTests`.

## Pass 2 — BUILT (2026-06-30) · status: PROTOTYPE — the moat
The verify spine: a finding is `.reportReady` ONLY if it clears THREE fail-closed gates, all required:
1. **authorized to reproduce** — `BountyGate` evaluates `poc.reproAction` (scope + program rules) before
   any traffic; out-of-scope / banned-automation / wrong-class / over-rate ⇒ never even attempted
2. **survives the adversarial panel** — reuses the existing hardened `FindingVerifier` (skeptic refute
   panel, scope-bound, strict-minority-to-confirm)
3. **reproduces** — `PoCReproducer` re-runs the PoC; if the expected signal doesn't show, the finding is
   DROPPED as a false positive **even if the panel confirmed** (reproduction is ground truth)

Files: `ProofOfConcept.swift` (PoC + `PoCReproducer` + `ReproResult`), `BountyFindingVerifier.swift`
(`VerifiedBountyFinding`, `BountyFindingVerdict`, batch `reportReady`). 8 tests, one per killed gate +
the moat case (confirmed-but-not-reproduced ⇒ dropped). Nothing an LLM says can promote a finding.

## Pass 3 — BUILT (2026-06-30) · status: PROTOTYPE — recon intake
The scope+rules-gated recon that FEEDS the verify spine:
- `ReconPipeline` runs the existing deterministic scanners (`SecurityAuditor`: secrets/SAST/dependency)
  over an ATTESTED repo, but only after `BountyGate` authorizes recon (out-of-scope / automation-banned ⇒
  refusal, not a scan). Surfaces only findings whose vuln class the program ACCEPTS (source findings skip
  the gate's active-only class check, so recon is where that program-interest filter lives).
- `SourceRescanReproducer` — a REAL (not stub) `PoCReproducer`: reproduction = re-read the file + re-run
  the deterministic scanner; reproduces iff the SAME finding id fires again. Deterministic ground truth,
  no live-target traffic.
- End-to-end proven: recon → verify spine → report-ready, using the real reproducer against a planted
  vuln; "fix the vuln" → PoC can't reproduce → dropped. Live-host DAST intentionally deferred.

Files: `ReconPipeline.swift`, `SourceRescanReproducer.swift`. 8 tests incl. the full pipeline compose.

## Pass 4 — BUILT (2026-06-30) · status: PROTOTYPE — the last mile
- `ReportDrafter` — turns a REPORT-READY finding into a grounded `DisclosureReport` (summary / repro /
  PoC / impact / remediation / est. payout), rendered as Markdown a human reviews. **Refuses (throws) for
  any finding that isn't report-ready** — you cannot draft the slop that gets a hunter banned.
- `SubmissionTracker` — durable, human-only submission + outcome tracking. `recordSubmission` demands a
  non-empty HUMAN submitter and re-runs the submit action through `BountyGate` (refuses automated submit
  and out-of-scope asset at submit time). Records outcome (accepted/dup/rejected/paid) and computes a
  per-program `ReputationSummary` (signal ratio, paid $) — the asset that compounds. No auto-submit path
  exists structurally.

Files: `DisclosureReport.swift`, `ReportDrafter.swift`, `SubmissionTracker.swift`. 8 tests. 44 bounty
tests total green.

## Pass 5 — BUILT (2026-06-30) · status: PROTOTYPE — dedup-risk + prioritization
- `DedupRiskScorer` — estimates duplicate risk in [0,1] with reasons. Hard signal = your OWN prior
  submissions (`SubmissionTracker.list`): exact finding filed ⇒ ~0.95, same rule+file ⇒ ~0.8. Heuristic
  baseline from severity + rule commonness. Honest — never claims certainty.
- `FindingPrioritizer` — ranks report-ready findings by `novelty*0.45 + severity*0.35 + payout*0.20`, so
  novel/severe/well-paying float up and likely-duplicates sink. Triage, not a gate — nothing is dropped.
  Every score carries an explainable rationale.

Files: `DedupRiskScorer.swift`, `FindingPrioritizer.swift`. 8 tests. 52 bounty tests total green.

## Wizard — BUILT (2026-06-30) · status: PROTOTYPE — beginner-mode guided flow
`BountyWizard` — the headless orchestrator that sequences passes 1–5 into a narrated, beginner-safe run:
welcome → program → recon (gated) → verify (the moat) → prioritize → draft top finding → **you submit** →
coach. Every stage carries plain-language teaching (learn-by-doing). It NEVER submits — the submit step
`needsHuman == true` and hands back the drafted report for the human to file. If recon is refused (out of
scope) it stops there and explains the guardrail; if nothing reproduces it says so ("nothing to report, and
that's the point"). 5 tests incl. full run, stage order, refusal, all-refuted, teach intro.

**57 bounty tests total, green. Full AgentCore suite green.**

## Program intake — BUILT (2026-06-30) · status: PROTOTYPE
- `ProgramSpec` — the operator-authored intake DTO (Codable). Deliberately a STRUCTURED spec the human
  fills/reviews, not free text an LLM parses — authorization scope is never model-invented. Lenient decode
  toward the strictest reading (unknown automation ⇒ banned, missing rate ⇒ nil, no classes ⇒ none).
- `ProgramIntake.parse` — validates + builds `(SecurityEngagement, BountyProgramRules)` fail-closed: no
  program name / no attestation / no valid target ⇒ REFUSED. `parse(json:)` for a `.kist/bounty/<id>.json`;
  `ingest` persists engagement (`EngagementStore`) + rules (`BountyRulesStore`), same id.
- `BountyRulesStore` — durable rules companion to `EngagementStore` (atomic, path-safe, fail-closed on corrupt).

Files: `ProgramSpec.swift`, `ProgramIntake.swift`, `BountyRulesStore.swift`. 7 tests. 64 bounty tests total.

## REPL wiring — BUILT (2026-06-30) · status: PROTOTYPE — it's a live terminal command
`/bug-bounty` (aliases `/bounty`, `/bb`) in Kist:
- `ingest <spec.json>` → `ProgramIntake.ingest` (attest scope + rules, fail-closed)
- `run <program-id> [dir]` → drives `BountyWizard` over an in-scope repo, prints the narrated steps + any
  drafted report, flags human-action steps `[you]`, and submits NOTHING
- `list` → ingested programs
Adversarial panel: 3 model skeptics via the current provider (`registry.complete`), or a deterministic
severity-floor panel offline. `LLMFindingRefuter` fails CLOSED (empty/ambiguous ⇒ refuted).

Files: `LLMFindingRefuter.swift` (+ `SeverityThresholdRefuter`), `BountyConsole.swift`; wired into
`KistREPL`/`KistRunner`. Console smoke-tested end-to-end (ingest→list→run→report-ready) on isolated stores.
**77 bounty tests; full suite 1380 AgentCore + 172 Kist, 0 failures.**

## Still to do
- Live-host DAST recon (bigger/riskier surface) — source recon only for now.
- Live-host DAST recon (bigger/riskier surface) — source recon only for now.
- The private **full-access repo** itself (authored separately by Luke; this public repo only ships
  `PublicEditionPolicy`).
- Pass 5 — dedup-risk + prioritization
- The guided **wizard** UX (beginner mode) that drives all of the above
- Program **intake/parsing** (program page → `BountyProgramRules` + `SecurityEngagement`); for now both are
  constructed directly / loaded from disk.
- The private **full-access repo** itself (authored separately by Luke).
