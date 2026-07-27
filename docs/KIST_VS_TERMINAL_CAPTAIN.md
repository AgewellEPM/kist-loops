# Cross-Compare — kist/Mythos vs TinkySDR "Terminal Captain"

## 0. The headline: same DNA, two bodies
TinkySDR's **Terminal Captain** is the **SOURCE**; kist/Mythos's fleet is a **PORTED FORK** of it
(`ForgeSeal.swift` literally says *"Ported from TinkySDR's Captain (Stage 1.3)"*). They share the
exact trust architecture — ForgeSeal HMAC, hash-chained signoff ledger, GroundedVerdict (private-init,
code-provenance-only), SymbolicCaptain referee, claim reconciliation, Ed25519 promotion gate — but
there is **NO import relationship**. They're two independent copies that have **diverged**. That's the
core fact: one trust engine, maintained twice.

---

## 1. What each one actually IS

**Terminal Captain (TinkySDRMac)** — a **GUI cockpit on macOS** for supervising autonomous *Claude-Code*
fleets. `TerminalCaptainView`: left = live sessions, center = full transcript, right = work kanban,
bottom = propose→approve drive bar (human approval before any keystroke; auto-send OFF by default).
Decomposes a goal → spawns one Claude-Code agent per disjoint subtask in an isolated worktree →
supervises to a forge-proof signoff → a read-only `FleetCockpitView` shows the honest merge fate.
Xcode, `com.tinkytown.sdr.mac`, macOS-only, Keychain/CryptoKit. **PILOT-READY (Luke-only).**

**kist/Mythos** — a **cross-platform, multi-vendor agent RUNTIME** (terminal CLI + REPL, plus a GUI
sibling). Same fleet core, but the spawner is `PlanExecuteLoop` (planner/coder/critic can be *different
vendors*), plus a whole agent runtime around it: `HeadlessAgentLoop`, MCP, 30+ tools (browser,
security_audit, media, spreadsheet, eval, memory, tasks), multimodal, conversational control. SwiftPM,
macOS **+ Linux**, file-based crypto (swift-crypto), thread-safe (`Sendable`). 784 tests.

---

## 2. The shared trust core (identical in both)
ForgeSeal (HMAC-SHA256 per-install key) · FleetSignoffLedger (hash-chain, seal-or-drop) ·
SymbolicCaptain + GroundedVerdict (deterministic, private-init `.green`) · Foreman (verify-and-sign
gate) · FleetPromotionGate (Ed25519 external attestation + replay protection, fail-closed) ·
CaptainOrchestrator (decompose + spawn in isolated worktrees) · FleetSupervisor (bounded poll→verify→
sign loop) · Baton (custody chain) · ClaimReconciler · GitIsolation.

**Trust tier verdict: EQUAL.** Both have the two-tier (internal HMAC + external Ed25519), replay
protection, fail-closed gates.

---

## 3. Where each LEADS (the divergence)

### Terminal Captain is DEEPER on fleet supervision + safety
Guards/maturity kist's fleet does NOT yet have (all real files in TinkySDRMac):
- **Conscience / drift fully wired** — `GroundedObserver` + `WorldModel` reconcile agent self-reports
  vs measured evidence (kist has `ClaimReconciler` but defers the full conscience).
- **RewardHackingGuard** — blocks signoff if an agent games tests (mutates the suite, skips CI).
- **CIIntegrityGuard** — refuses if the test harness changed (deleted tests / new skips).
- **UntrustedContentScanner** — scans agent diffs for secrets/malware before signoff.
- **FleetLessonStore + FleetRetrospective** — cross-fleet durable memory + post-mortem (kist just
  added a general LessonStore, but not the fleet-signoff-sourced one).
- **FleetBudgetGuard / ArmingThrottle / ReliabilityCalibration** — runaway-swarm caps, arming
  cool-down, per-agent success-rate learning.
- **FleetRecoveryPlanner** — re-specs a failed subtask and retries.
- **GUI cockpit + human visibility** — `FleetCockpitView` shows per-agent lease/verdict/merge-fate;
  a propose→approve drive bar; arming requires a minted authorization token.
- **Per-agent Seatbelt sandbox profile**, **ProactiveInitiative + FleetCouncil** (Phase D), **28
  dedicated fleet tests.**

### kist/Mythos is BROADER as a runtime
What kist has that Terminal Captain does NOT:
- **Cross-platform** (macOS + Linux) — Terminal Captain is macOS-only.
- **Multi-vendor agent teams** — planner/coder/critic on *different* vendors (proven live: MiMo+DeepSeek
  +Gemini). Terminal Captain spawns *Claude-Code only*.
- **MCP** client (external tool servers) — Terminal Captain has none.
- **30+ tools**: browser (SSRF-guarded), security_audit, governance_report, analyze_media (video/
  audio), query_data (DuckDB), spreadsheet, eval/trajectory, `/tasks` runbook.
- **Conversational control** — rebind roles/models/settings by talking.
- **Headless CLI runtime + plan-execute + council** as first-class, scriptable.
- **Thread-safe** (`Sendable`, lock-guarded ledger) for concurrent supervision.

---

## 4. The two strategic facts that fall out

**Fact 1 — divergence is a liability.** Same trust core, two copies, drifting (exactly the
FloatingChatApp problem again). Bug fixes and hardening done in one don't reach the other. Over time
they'll disagree about what "verified" means — the worst possible drift for a *trust* layer.

**Fact 2 — each has what the other needs.** Terminal Captain has the **deep fleet-safety guards**;
kist has the **cross-platform multi-vendor runtime + tools**. Neither is strictly better — they
optimized different axes from the same root.

---

## 5. Recommendation — converge them, don't run two

**Make AgentCore the single shared trust+fleet engine; Terminal Captain becomes a GUI cockpit over it.**
This is the U1 pattern again, applied to the fleet:

- **C1 · Port the guards INTO AgentCore** (they share the lineage, so it's mechanical): RewardHackingGuard,
  CIIntegrityGuard, UntrustedContentScanner, the full conscience (GroundedObserver/WorldModel),
  FleetLessonStore (signoff-sourced), FleetBudgetGuard, FleetRecoveryPlanner. This closes kist's
  fleet-depth gap and brings cross-platform + multi-vendor to those guards.
- **C2 · TinkySDR imports AgentCore** as a SwiftPM dependency and deletes its parallel `Core/Captain/`
  copy; `TerminalCaptainView`/`FleetCockpitView` become a thin macOS GUI over the shared engine. Kills
  the drift; one definition of "verified" everywhere.
- **C3 · The cockpit becomes cross-cutting** — the same fleet that runs headless via `kist --fleet`
  on Linux is the one the Mac cockpit visualizes. One engine, two surfaces (CLI + cockpit), like the
  portfolio strategy's "one trustworthy engine, many surfaces."

**Sequencing:** C1 first (port the guards — pure value, makes kist's fleet best-in-class on safety),
then C2 (reunify — kills the maintenance drift). C2 is bigger (touches the Mac app), so it can follow.

---

## 6. One-line answer to "are the two there / how do they compare"
**They're the same trust engine forked in two directions:** Terminal Captain is the *deeper, GUI-
supervised, macOS fleet cockpit*; kist is the *broader, cross-platform, multi-vendor runtime*. On the
**trust tier they're equal**; on **fleet-safety depth Terminal Captain leads**; on **runtime breadth +
portability kist leads**. The win is to **merge them** — port Captain's guards into AgentCore, then let
TinkySDR ride AgentCore — so there's one engine that's both deep AND broad, instead of two that drift.
