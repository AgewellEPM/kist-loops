# Persona-Shifting Research Collective — Plan (2026-06-28)

Luke's vision: agents that (a) **research the internet seamlessly even in autopilot**, (b) **auto-attach
the RIGHT specialist persona to each task** — "I need help with a mortgage clause" → a real-estate-law
agent; persona *shifts* as the task shifts, so every agent is a focused specialist all the time — and
(c) **research as a collective** toward your goals until they're actuated.

## What's already true (so we build, not start over)
1. **Research is already sandbox-independent.** `web_search` + `fetch_url` are in-process URLSession;
   `SeatbeltSandbox.wrap` only wraps `run_command`'s child process, never the kist process. So internet
   research works under `--auto`/`--sandbox` (only shell `curl`-style egress is denied — correct). The
   tools "work in union unsandboxed for research" *today* — we just need to make it seamless + advertise it.
2. **The specialist engine exists** (AgentForge P1–P3): forge a specialist (persona system-prompt + scoped
   tools), validated (no privilege escalation), registered, listed. `SpecialistRegistry.matching(goal:)`
   exists.
3. **Multi-agent exists**: AICouncil, fleet/CaptainOrchestrator, spawn_agent.
4. **THE GAP**: `matching(goal:)` is called nowhere (P4 auto-selection unwired); there's no persona
   library; there's no standing research collective.

---

## The build — 3 tracks

### TRACK A — Seamless research (network + tools in union)
- **A1. Advertise + confirm** the research-always-on fact. The persona/contract tells the agent:
  "Internet research (web_search, fetch_url) is ALWAYS available — even in autopilot; the sandbox only
  limits shell, not research." So it never hesitates to go look something up. (+ a one-line capability
  note on the web tools.)
- **A2. A `research` loop** (extend the existing WorkflowTool research playbook): chain
  web_search → fetch the top hits → synthesize **with citations**, staying in research mode for N rounds
  or until the question is answered. No-fabrication: every claim cites a fetched source (routes through
  `GroundedReviewValidator` so cited files/URLs are real).
- **A3. Richer fetch** (gap-analysis W4): `fetch_url` POST + auth headers + multi-URL fetch, for API/doc
  research behind logins.

### TRACK B — Persona auto-matching (THE HEADLINE — AgentForge P4 + a persona library)
- **B1. Persona library.** Ship a curated set of `SpecialistDefinition`s (+ user-extensible in
  `~/.config/kist/agents/` and `.kist/agents/`): real-estate / contract / IP **lawyer**, **realtor**,
  **CPA/accountant**, **financial advisor**, **medical-research** aide, **security auditor**, **researcher**,
  etc. Each = a persona system prompt + a scoped tool allowlist + a "use when…" description that drives
  matching. (Reuses the P1 format + registry exactly.)
- **B2. `TaskPersonaMatcher`.** Per user message: `SpecialistRegistry.matching(goal:)` ranks the library
  (keyword prefilter, optional LLM tiebreak). Strong match → adopt it. Weak/no match → **AgentForge.forge**
  a persona on the fly ("a real-estate-law specialist for mortgage clauses") and register it for reuse.
  Reuse-before-mint (the P4 contract in `docs/AGENT_FORGE_PLAN.md:148`).
- **B3. Per-turn persona adoption.** The matched specialist's `systemPrompt` becomes the active persona for
  that task; its `toolAllowlist` scopes the tools (the no-escalation gate from P3 still applies). When the
  task's intent shifts, **re-match** → the agent shifts persona. Surface it: `↳ acting as: Real-Estate Law
  specialist` in the status line, so you always see which persona is on.
- **B4. Wire into the loop (the actual P4).** `ConversationRouter`/`PromptCompiler` call the matcher; the
  loop is rebuilt with the persona prompt + scoped tools per task. **Behind a flag** (off = today's
  behavior) until it's proven, then default-on.

### TRACK C — Research collective (a group toward the goals)
- **C1. Standing research collective.** For a research goal, the matcher assigns 2–4 personas to the
  distinct angles (e.g. mortgage clause → **legal** + **financial** + **market**); each researches its
  angle in parallel (Track A loop), then synthesizes toward the goal board (`.kist/plan.json`). Built on
  `AICouncil` + the goal board.
- **C2. Goal-driven persistence.** The collective stays in research mode across rounds — findings →
  open questions → re-assign the right persona to each open question — until the goals are actuated (the
  board's tasks all resolved). The human sees the live board + each persona's gist (the `CouncilCard` shape).
- **C3. Trust.** Collective findings route through `GroundedReviewValidator` (no hallucinated sources) and
  the council/captain gate before anything is *acted on*. **Research = retrieval, never auto-action.**

---

## Trust + safety invariants (non-negotiable, kept)
- **Personas are scoped.** A "lawyer" persona gets read/search/research tools, NOT destructive ones —
  `toolAllowlist` enforced by the P2 no-escalation gate.
- **Forged personas can't escalate** (P3 ceiling-intersection) and can't self-spawn.
- **Research is retrieval-only.** Acting on a finding (a write, a send, a purchase) still needs the
  reversibility gate / captain OK. A persona advising on a mortgage never *signs* anything.
- **No fabrication.** Every research claim cites a real fetched source; grounding-validated.
- **Persona shift is visible** (status line) so you always know who's "in the room."

---

## Phased order (each: build → test → adversarial Codex → ff-merge; persona-adoption flag-gated)
1. **B1 + B2 + B3** — persona library + matcher + per-turn adoption (the headline; builds on P1–P3).
2. **A1 + A2** — research-always-on advertised + the cited research loop.
3. **B4** — wire the matcher into the router (flag off → on once proven).
4. **C** — the research collective toward the goal board.
5. **A3** — richer fetch (POST/auth) as needed.

## One-paragraph framing
The architecture is already most of the way there: research is sandbox-independent, the specialist
engine (forge + scoped tools + no-escalation) is built, and multi-agent exists. The missing magic is
**wiring it together** — a persona library, a matcher that attaches the right specialist to each task
(forging one when none fits), per-turn persona adoption that's visible, and a goal-driven collective
that keeps researching toward what you actually want. Every piece reuses what we have; nothing here
re-architects. The result: you say "help me with this mortgage clause" and a real-estate-law specialist
takes the room, pulls live sources, and — when the question is bigger — pulls in a financial and a market
specialist to finish the job, all toward your goal board, all cited, all scoped.
