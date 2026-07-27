# kist vs the field — brutal cross-comparison + the conversational gap (2026-06-28)

Research across the open agent-CLI landscape (5 parallel read-only agents, current to mid-2026)
cross-compared with kist/Mythos. Brutal on purpose. Bottom line up front:

> **kist is roughly C-tier on conversational FEEL and best-in-class on OUTPUT VERIFICATION.**
> Every competitor gates the tool *call*; NONE verify the agent's *result*. That's our moat —
> and the exact reason the "conversational" layer never got built. To make conversational
> modeling *appear*, the work is ~6 model-agnostic prompt/harness mechanisms, not model magic.

---

## 1. The field (conversational-feel grade + the one thing each does best)

| Tool | Lang / open | BYOK / local | Feel | Best idea (steal-worthy) |
|---|---|---|---|---|
| **Claude Code** | TS, closed | ❌ Anthropic-only | **A+** | Act-vs-ask *reversibility gate*; plan mode; todo surfacing; restraint persona |
| **Cline / Roo** | TS, open | ✅ | **A** | **Plan/Act toggle** — best conversational UX in the category |
| **OpenCode** | TS, open | ✅ (75+) | **A−** | In-prompt `@file` search; Tab Plan/Build; `description`-routed subagents + per-agent permissions |
| **Goose** | Rust, open | ✅ +local | **B+** | Stacked pre-tool inspector pipeline; subrecipe = role-as-YAML w/ per-role model |
| **Crush** | Go, open | ✅ +local | **B+** | **Mid-session model switch with preserved context graph**; sessions as JSON |
| **Codex CLI** | Rust, open | ✅ +local | **B+** | Real OS sandbox (Seatbelt/Landlock); sandbox × approval as orthogonal dials |
| **Aider** | Py, open | ✅ +local | **B−** | Edit-format-per-model portability; **git-commit-per-edit** |
| **Gemini CLI** | TS, open | ❌ Gemini | **B** | Shadow-git checkpoint/`/restore`; live `/memory add` |
| **OpenHands** | Py, open | ✅ (LiteLLM) | **C+** | **Docker-per-task sandbox**; event-sourced immutable log; per-action LLM risk tier |
| **Continue** | TS, ☠️ dead | ✅ | **C−** | `@`-context-provider model (acqui-hired by Cursor 2026 — mine, don't benchmark) |
| **kist** | Swift, open | ✅ +local | **~C** (honest) | **Output verification: committed-diff measurement + HMAC signoff + council/captain gate** |

---

## 2. Where kist genuinely WINS (don't lose this)

**The entire field gates the tool CALL and never verifies the RESULT.**
- Permissions/approvals (OpenCode patterns, Crush whitelists, Cline approval menu) = "did the user OK this call."
- LLM-judged risk (Goose `AdversaryInspector`/`PermissionJudge`, OpenHands LOW/MED/HIGH) = a *second model* guesses if a call is dangerous — **reward-hackable, and ships with no default rules**.
- **Nobody** measures what the agent actually committed and refuses to merge off-lease/forged/contradicted work.

kist's `committed-diff measurement + ForgeSeal HMAC signoff ledger + lease enforcement + ClaimReconciler + (new this session) council→captain promotion gate` is the **unoccupied position**. It is *structurally* stronger than every LLM-judge safety model out there. This is the moat. Keep widening it.

**The unoccupied market slot (from the official-CLI teardown):** Claude's conversational refinement
+ true any-provider BYOK + real verification. Codex proves the *open* half (BYOK + local + sandbox).
**Nobody combines Claude's feel on any model WITH output verification.** That's kist's lane.

---

## 3. Where kist LOSES — and WHY conversational modeling never "appeared"

kist was built loop-out / trust-in: the energy (correctly) went to the agent loop, fleet, and
trust spine. The conversational layer is a **thin deterministic veneer** — `ConversationRouter`
(sees ONE message, no history) + `ControlIntentParser` (conservative regex) + a **neutral,
personality-free system prompt** ("You are Mythos, an autonomous coding/agent shell"). It is
**purely reactive and serial**: no clarifying questions, no act-vs-ask nuance, no plan/act bounce,
no live todo surfacing, no conversation-history awareness, no persona/restraint.

The key insight (official-CLI agent): **what makes Claude Code feel like a collaborator is NOT
UI — it's ~9 specific prompt/harness mechanisms, every one model-agnostic and replicable on a
BYOK router.** kist has almost none of them. That's the whole gap.

---

## 4. THE BUILD LIST — what makes conversational modeling appear (ranked by feel-per-effort)

Each maps to existing kist seams; none needs a frontier model — they're harness/prompt engineering.

1. **Act-vs-ask reversibility gate** (THE #1 lever). Today kist only prompts for a fixed
   `sensitiveTools` set. Replace with a per-action classifier: *local + reversible → just do it;
   irreversible / high-blast-radius (delete, force-push, network, out-of-workspace, money, mass
   edit) → stop and ask.* This single asymmetry is the biggest driver of the "peer not vending
   machine" feel. Seam: `HeadlessAgentLoop.approve()` + a `ReversibilityClassifier` over the
   proposed tool call. (Distinct from `--auto`, which is a crude global on/off.)

2. **Clarifying questions as a structured tool.** `RuntimeInteractor.requestInput` EXISTS and is
   **never called**. Add an `AskUserQuestion`-style tool: when intent is ambiguous or a tool is
   denied, emit multiple-choice options instead of guessing or dumping prose. Single most-noticed
   missing thing vs Claude Code. Seam: a new tool + wire `requestInput`.

3. **Restraint/collaborator persona in the system prompt** (cheap, big). Add Claude-style rules:
   lead with the answer, be concise, **"don't add features/refactor/'improve' beyond what was
   asked,"** comment only when WHY is non-obvious, collaborator identity. Make it injectable from
   project context. Seam: `HeadlessAgentLoop.systemPrompt`/`nativeSystemPrompt` — currently neutral.

4. **Plan/Act bounce (not all-or-nothing).** kist has the PIECES (plan mode, `AgentPlanner`,
   `/plan-execute`) but not the *cycle*: research read-only → propose plan → user approves →
   execute → re-plan. Steal Cline's Plan/Act toggle as the conversational spine; bind to a key.
   Seam: plan mode + router + a gated `ExitPlanMode`-style approval.

5. **Live todo/task surfacing.** kist HAS `/tasks` (`PlanStore`) but the agent doesn't proactively
   surface + update a visible checklist mid-turn (Claude's `TodoWrite`). Wire the loop to emit and
   tick a task list as it works — makes the plan shared and visible. Seam: `ManageTasksTool` +
   event sink rendering.

6. **Conversation-history-aware routing + brief.** `ConversationRouter` classifies ONE message;
   the brief is static per-message; compound asks ("add tests" → "deploy if they pass") route
   independently. Feed recent turns into the router + `PromptCompiler`. Seam: `ConversationRouter`,
   `PromptCompiler.compile`.

**Lower priority / polish:** graceful Esc-to-cancel mid-action (kist kills on Ctrl-C, checkpoint
survives — but no clean re-sync); mid-session model switch with *preserved* context (verify kist
keeps transcript on `/model`); LLM fallback for control-intent when the deterministic parser misses
(with confirmation — keep the conservative default we just hardened).

---

## 5. Other steals (beyond conversational feel)

- **Goose's stacked pre-tool inspector pipeline** (Security→Egress→Adversary→Permission→Repetition)
  as a *soft, fast* pre-call gauntlet BENEATH kist's hard structural gates — but ship **sensible
  default rules** (Goose's fatal flaw is blank defaults). + **doom_loop/repetition** runaway detector.
- **Aider's git-commit-per-increment** baked into the runtime (matches Luke's standing rule) +
  per-model edit-format adaptation (proves the text-protocol P1 decision; helps weak local models).
- **OpenHands' Docker-per-task sandbox + event-sourced log.** kist has worktree isolation but not
  process/network/FS sandboxing — the missing ENTERPRISE-READY box. The immutable event log is a
  natural superset of the signoff ledger.
- **OpenCode's `description`-routed subagents + per-agent permission overrides.** kist's AgentForge
  (this session) is ~80% there; add description-based auto-routing + attach leases to the per-agent
  permission block.
- **Crush's mid-session model swap w/ preserved context graph** — directly serves the BYOK thesis.

---

## 6. The one-paragraph verdict

kist is **behind on conversational feel (C-ish) and uniquely ahead on verification (A+)**. The feel
gap is not talent or model — it's that the conversational mechanisms were never built, because the
moat (trust/verification) correctly ate the effort. The fix is ~6 model-agnostic harness mechanisms
(reversibility gate, clarifying-question tool, restraint persona, plan/act bounce, todo surfacing,
history-aware routing). Build the top three and kist jumps from C to B+ feel **while keeping the one
thing no competitor has**: it verifies what the agent actually did before trusting it. That
intersection — Claude's feel, on any model, with real verification — is empty. It's ours to take.
