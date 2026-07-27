# MASTER PLAN — Mythos / kist Agentic Stack

**Single source of truth.** Point me here and say *"run T0.1"* (or *"run the next task"*) and I'll
execute it. Every task has: a status, who owns it (🤖 me / 🧑 you / 👥 both), and a link to the
detail doc. Update the `[ ]`/`[x]` as we go.

**Detail docs this links:**
[Multimodal+TUI](MULTIMODAL_TUI_PLAN.md) · [Deep Media+Data](DEEP_MEDIA_DATA_PLAN.md) ·
[Strategic Roadmap](STRATEGIC_ROADMAP.md) · [Portfolio Strategy](AGENTIC_PORTFOLIO_STRATEGY.md)

**Where the work lives:** branch `feat/kist-multimodal` (worktree `~/Downloads/mythos-stage2-mm`),
130 commits ahead of `main`, installed to `~/bin/kist`. Nothing merged yet.

---

## ✅ DONE this session (already shipped on the branch)
- Phases 1–5 multimodal (drag image/video/audio, Gemini Files API, multi-provider vision, `/paste`)
- `--tui` raw-mode persistent-input shell (PROTOTYPE, opt-in)
- Deep media: `analyze_media` (timeline/transcript/scenes), `extract_clip` (ffmpeg)
- Data: `read_spreadsheet` (CoreXLSX/CSV), `query_data` (DuckDB)
- **P2 security:** `security_audit` (secrets/SAST/deps, grounded) + `governance_report` (OWASP Agentic)
- **P1 eval:** TrajectoryAnalyzer + EvalRunner + LLM judge, **wired live** (self-check every run)
- **P3 memory:** LessonStore — learns obstacles + verified wins, primes briefs, **wired live**
- **P5:** `business_workflow` playbooks · **P4:** `browse` (Playwright/Chrome) + SSRF guard
- IsolatedTester wired as an MCP server (kist sees its 19 app-verification tools)
- 742 tests green

---

## PHASE 0 — CLOSEOUT (finish what's in flight, then land it)
> Goal: get the 130-commit stack reviewed, verified, and merged to `main`. Do this BEFORE new builds.

- [x] **T0.1 — Codex review pass over the whole stack.** 🤖 ✅ Codex found 1 CRITICAL + 3 HIGH + 3
      MEDIUM + 1 LOW; all fixed + regression-pinned (commit `2307d97`). 762 tests green.
- [x] **T0.2 — Verify-live the headless parts.** 🤖 ✅ security_audit found 4 grounded findings w/ the
      secret REDACTED; browse rendered example.com AND refused 169.254.169.254 (SSRF). Fixed a real
      global-Playwright resolution bug found in the process (commit `5787e1c`). 763 tests.
- [x] **T0.3 — Verify-live the gated parts.** ✅ (mostly auto-verified) `analyze_media` on a real test
      video → accurate timestamped timeline via Gemini; IsolatedTester `setup_status` → `allGranted:true`,
      virtual display ready (perms already granted). REMAINING (🧑, non-blocking): drive `--tui`
      interactively in a real terminal — a raw-mode TUI can't be auto-driven.
- [ ] **T0.4 — Install missing deps (optional).** 🧑 `brew install duckdb` (for `query_data`);
      `npm i -g playwright && npx playwright install chromium` (for interactive `browse`).
- [x] **T0.5 — Merge `feat/kist-multimodal` → `main`.** ✅ Clean fast-forward (old main `b32ac34` → new
      `e27ff72`, strict ancestor, reversible). Release rebuilt + reinstalled to `~/bin/kist`. **Phase 0 done.**

---

## PHASE 1 — STRATEGIC TIER 1 (fix fragmentation + extend the moat)
> From [Portfolio Strategy](AGENTIC_PORTFOLIO_STRATEGY.md). Highest leverage.

- [ ] **T1.1 — U1: Reunify FloatingChatApp onto AgentCore.** 🤖 Add AgentCore as a Swift package dep to
      the GUI; delete its re-implemented loop/tools/providers; keep the SwiftUI shell (window, hotkey,
      screen capture, settings). **Kills the GUI's security regression + the drift.** Biggest ROI.
- [ ] **T1.2 — U2: Unified `Verifier` layer.** 🤖 One protocol + `VerificationResult`; make the 3 organs
      providers (web→tinky-verify, app→IsolatedTester, code→GroundedVerdict/security_audit).
- [ ] **T1.3 — U2 wiring: verification → signoff.** 🤖 A plan-execute/fleet run building web/app/code is
      NOT signed until the matching verifier confirms behavior; feed results into claim-reconciliation
      + proven-lesson memory. *(This is the deep IsolatedTester integration too.)*

---

## PHASE 2 — STRATEGIC TIER 2 (ride the standards, surface governance)
- [ ] **T2.1 — U3: A2A endpoint.** 🤖 Expose kist's agent over A2A + let it call other A2A agents
      (MCP we have; A2A is the missing interop half).
- [ ] **T2.2 — U4: Observability/governance as a product.** 🤖 `--eval` CLI + CI gate, OpenTelemetry
      export of AgentTrace, surface `governance_report` + trajectory self-checks in a small view.
- [ ] **T2.3 — U5: One identity/memory/config across surfaces.** 🤖 Shared providers + `LessonStore` +
      settings across kist, the GUI, and the wrappers — same agent everywhere.

---

## PHASE 3 — HORIZON (bets, not commitments)
- [ ] **T3.1** ANP / DID agent identity (the ~2027 standard).
- [ ] **T3.2** MCP gateway + egress inspection (agent-security control plane).
- [ ] **T3.3** Linux sandbox tier (bubblewrap) to match the macOS Seatbelt tier.
- [ ] **T3.4** Specialist verifiers behind the Verifier protocol (Deepgram diarized transcripts,
      TwelveLabs cross-library video search, live CVE lookup for `security_audit`).

---

## Conventions
- **Status:** `[ ]` todo · `[x]` done · `[~]` in progress · `[!]` blocked (note why inline).
- **"run the next task"** = the lowest-numbered `[ ]` task I own (🤖). I'll mark it `[~]`, do it, commit,
  then `[x]` and report.
- **Don't skip Phase 0.** New builds (Phase 1+) wait until the stack is reviewed + merged, so we're not
  piling more onto an unmerged, unreviewed 130-commit branch.
