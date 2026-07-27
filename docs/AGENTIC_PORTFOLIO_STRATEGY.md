# Agentic Portfolio — Where We Stand, The Landscape, The Future, The Plan

**Cross-references the whole agentic stack** (kist/Mythos, AgentCore, FloatingChatApp, the
CLI/wrapper layer, tinky-verify, IsolatedTester, the Codex gate, MCP) to ensure we deliver a
top-notch, coherent experience across every shell, wrapper, and surface.

---

## 0. Thesis (read this first)
The runtime/orchestration/protocol layers are **commoditizing fast** — in 2026 the default is
"Agents SDK inside a LangGraph state machine, MCP servers attached, A2A exposed." **Defensible value
is migrating UP the stack to applications and observability/governance.** That is *exactly* where our
moat already sits: **verified-not-claimed** work (signoff ledger, claim reconciliation, grounded
verdicts), plus the eval/security-audit/governance layers we just built. So the strategy is:
**stop polishing the commoditizing engine for its own sake, and (a) UNIFY the fragmented surfaces onto
the hardened core, (b) turn our three verification systems into one trust layer, and (c) ride the
MCP/A2A standards instead of reinventing them.**

---

## 1. Where we stand — the agentic portfolio (grounded audit)

| System | What it is | State | Verdict |
|---|---|---|---|
| **AgentCore** (SPM, macOS+Linux) | The hardened headless engine: HeadlessAgentLoop, checkpoint/resume, replan, ConfinedRoot, ProcessGroupRunner, structured-safe shell, fleet+signoff, MCP client, **+ this session's** multimodal/media/data/security-audit/eval/memory/browser tools | **Strong, current** | The crown jewel. Keep investing. |
| **kist** (CLI on AgentCore) | Terminal REPL + TUI, `/model` `/fleet` `/plan-execute` `/council`, multimodal, self-monitoring + lesson memory wired this session | **Strong** | The reference surface. |
| **FloatingChatApp** (Xcode, macOS GUI) | Floating-window chat agent (hotkey, screen capture, settings UI, 10 providers, 28 tools) | **DIVERGED** | ⚠️ Re-implements everything; **does NOT use AgentCore** (README claims it does — false); **weaker security** (pattern-match shell denial vs structural); **lacks** fleet/MCP/hooks/checkpoint/budget. Liability. |
| **CLI/wrapper layer** (`~/bin`, `~/.zshrc`, `~/.claude`) | `cu`/`cu-wt`/`cx`/`ai` router, claude-edit-lock (PreToolUse), Codex review gate (SessionStart verify + Stop enforce), tinky-smoke (PostToolUse), git-ghosts/ghost-triage, CLAUDE.md constitution | **Coherent** ✓ | The one genuinely unified, defense-in-depth layer. The model for the rest. |
| **tinky-verify** (Gemini visual, web) | Drives a web page + judges it (goal/steps); MCP + CLI | **Solid** | Verification organ #1 (web). Siloed. |
| **IsolatedTester** (vision, native app) | Drives a `.app` on an invisible display; 19 MCP tools; **wired into kist this session** | **Newly integrated** | Verification organ #2 (app). Siloed. |
| **GroundedVerdict / ClaimReconciler / security_audit** (in AgentCore) | Verifies code work vs committed diff + tests; deterministic security findings | **Strong** | Verification organ #3 (code). Siloed from the other two. |
| **Codex gate** | Independent review after Claude "done" (Stop hook) | **Working** | Good adversarial check; complements our verdicts. |

**Two structural problems jump out:**
1. **Surface fragmentation:** kist (hardened engine) and FloatingChatApp (separate, weaker re-impl)
   are drifting apart — duplicated tools/providers/loop, a real **security regression in the GUI**.
2. **Verification fragmentation:** three verification systems (web / app / code) with **no shared
   interface** and no common feed into the trust/signoff pipeline.

---

## 2. The landscape + the future (researched, 2026→2027)

- **Protocols are the backbone, and they're standardizing:** **MCP** (tools/context — 10K+ enterprise
  servers, 97M SDK downloads, adopted by Anthropic/OpenAI/Google/Microsoft/AWS) + **A2A**
  (agent-to-agent coordination, Linux-Foundation governed) + **ACP** (runtime-neutral messaging).
  **ANP** (DID-based agent naming/identity) is the ~2027 horizon.
- **The 2026 default stack:** Agents SDK + LangGraph-style state machine + MCP servers + A2A endpoints.
  The runtime/orchestration layer is becoming a commodity.
- **Where value accrues:** the **application** and **observability/governance** layers — "the runtime,
  protocol, and orchestration layers are standardizing fast." (This is the whole strategic pivot.)
- **DX has shifted from prompting → orchestration + sustained execution + observability/governance +
  multi-surface deployment.** Enterprises want unified SDKs, governance, and debuggability.
- **Our position vs all this:** we have MCP (client + we just made several MCP-ready tools); we do
  **not** have A2A; our verification/trust moat is *ahead* of the market on the layer that's becoming
  most valuable. We're well-placed — IF we unify and lean up-stack instead of re-hardening the engine.

---

## 3. Cross-system coherence — the three gaps

**Gap A · Surface fragmentation (kist ↔ FloatingChatApp).** Two agent loops, two tool sets, two
provider stacks; the GUI is bigger but less safe and lacks every advanced capability. Maintenance is
doubled and the GUI ships a weaker security model. **The README's "shares AgentCore" is aspirational,
not true.**

**Gap B · Verification is three silos.** tinky-verify (web), IsolatedTester (app), GroundedVerdict
(code) each prove a different surface, but nothing unifies them or feeds their results into the
signoff/claim-reconciliation pipeline. Our moat is "verified," yet verification itself is fragmented.

**Gap C · No A2A / ecosystem interop.** Our fleet/spawn is *internal* orchestration. We can't yet
interoperate with the broader agent ecosystem (consume or expose A2A), which is becoming table stakes.

(Non-gaps to protect: the **wrapper layer** is coherent — keep it as the template; the **trust moat**
is ahead — keep extending it; **MCP-as-connective-tissue** is the right bet — lean in.)

---

## 4. The plan (unify + go up-stack; prioritized)

### Tier 1 — fix the fragmentation, extend the moat
**U1 · Reunify FloatingChatApp onto AgentCore.** The GUI keeps its shell (floating window, hotkey,
screen capture, settings UI) but its loop/tools/providers/security become a **thin SwiftUI skin over
AgentCore** (add AgentCore as a Swift package dependency; delete the re-implemented loop/tools).
Kills the security regression, ends the drift, halves maintenance, instantly gives the GUI
fleet/MCP/hooks/checkpoint/budget + this session's tools. **Highest-leverage coherence win.**

**U2 · Unified Verification layer (the trust unifier).** Define one `Verifier` protocol with a
`VerificationResult` (claim → evidence → verdict). Make the three organs *providers* behind it:
- web → tinky-verify (MCP), app → IsolatedTester (MCP), code → GroundedVerdict/security_audit.
Then **wire verification into the signoff/claim-reconciliation pipeline**: a plan-execute/fleet run
that builds web/app/code work is *not signed* until the matching verifier confirms behavior. A
behaviorally-verified UI becomes a far stronger "proven" than "tests passed" — and feeds the
proven-lesson memory. This is the moat-extending unification, and it sits on the layer where value
accrues.

### Tier 2 — ride the standards, surface the governance
**U3 · A2A endpoint (expose + consume).** Wrap kist's agent as an A2A endpoint and let it *call* other
A2A agents — so our fleet can interoperate with the ecosystem, not just our own spawns. MCP we already
have; A2A is the missing half of the interop backbone.

**U4 · Observability/governance as a first-class surface.** Since value accrues here: wire the eval
runner into a `--eval` CLI gate + CI, add OpenTelemetry export of `AgentTrace`, and surface the
`governance_report` + trajectory self-checks in a small dashboard. Make "prove this agent is reliable
and compliant" a product, not a side effect.

**U5 · One identity/memory/config across surfaces.** Shared providers + shared `LessonStore` + shared
settings across kist, the GUI, and the wrappers — so the agent is the same agent everywhere
(continuity of memory + trust posture), not three personalities.

### Tier 3 — horizon
ANP/DID agent identity (the 2027 bet) · MCP gateway + egress inspection · Linux sandbox tier ·
deeper specialist verification (Deepgram/TwelveLabs behind the Verifier protocol).

---

## 5. Sequencing recommendation
1. **U1 (reunify the GUI onto AgentCore)** — stops an active security regression + the drift; biggest
   coherence ROI; makes "one engine, many surfaces" real.
2. **U2 (unified Verifier + wire into signoff)** — turns three siloed verifiers into the trust layer;
   directly extends the moat on the layer the market is paying for.
3. **U3/U4 (A2A + observability surface)** — ride the standardizing protocols and productize the
   governance/observability value.
4. **U5 + Tier 3** — continuity + horizon bets.

**What we are, stated cleanly:** not a coding tool and not three drifting apps — **one trustworthy
agent engine (AgentCore) delivered through many coherent surfaces** (terminal/kist, GUI/Floating,
web-verify/tinky, app-verify/Isolated), where every surface inherits the same hardened security and
the same verified-not-claimed guarantee, and where verification across web + app + code is one layer,
not three. The engine commoditizes; the **trust** is the product.

_Sources:_ MCP/A2A/ACP interop (prompt20, augmentcode, zylos), value-migration up-stack
(fifthrow, buildmvpfast), agent-framework/DX landscape (langchain, vellum, kore.ai), Gartner
enterprise-agent projection. Codebase audit: this session's Explore passes over the wrapper layer +
FloatingChatApp + AgentCore. Links in chat.
