# Mythos / kist · Strategic Roadmap — Where the Frontier Is & What We Build Next

**Thesis in one line:** the frontier's #1 unsolved problem across *every* category — coding, security,
business — is **trust** (hallucinated code, hallucinated exploits, unreliable agents). We already have
the deepest trust/verification layer of any open runtime. **Lean into that moat and extend it into
the categories the market is paying for.**

---

## 1. The frontier in 2026 (researched)

### Coding agents — a $9.8–11B market, shifting from autocomplete → real autonomy
Claude Code, Cursor, Devin/Cognition, OpenAI **Frontier/Codex** (enterprise platform, Feb 2026),
Gemini CLI. The bar moved: CLI agents now "run autonomously for hours, coordinate changes across
dozens of files, run shell to verify, and commit." Frontier model labs now compete directly with the
app layer. **We already do this** (fleet, plan-execute, git-isolated verified work).

### Observability & Eval — the maturity layer everyone now needs
LangSmith, Braintrust, Langfuse. The pattern: **trajectory tracing** (every step/tool-call/reasoning),
**LLM-as-judge regression suites**, **eval-on-every-PR that fails the build on a score drop**, and
**production trace sampling → failures become eval cases**. Crucial finding: *"most agent incidents
stem from tool-call failures, context truncation, and runaway loops — not model errors; standard APM
can't see these."* **This is our biggest capability gap** (we have spans, not evals).

### Security auditing — agentic red-teaming went mainstream
XBOW (hit **#1 on HackerOne**), Horizon3 NodeZero, Pentera, Astra, open-source **PentAGI**. Full
lifecycle: recon → threat-model → exploit → chain → validate-with-PoC → report → retest. **Stated #1
risk: "AI hallucinations producing fake exploits"** + scope-control failures + audit-grade
attestation. OWASP shipped the **Top-10 for Agentic Applications (2026)**. **This is our biggest
opportunity** — our claim-reconciliation/no-fabrication layer is the exact antidote to fake findings.

### Business / enterprise — the money
Gartner: **40% of enterprise apps embed task-specific agents by end-2026** (from <5%). Top use cases:
customer service (43%), **data analysis/reporting (38%)**, code gen/review (35%). **25% of AI budgets
already go to agents.** Platforms: Sana, ServiceNow, UiPath, Glean, Sierra, Hebbia, CrewAI. Value is
verticalized knowledge-work workflows — and we just shipped the data primitives (spreadsheet, DuckDB,
media analysis) those workflows need.

### Memory — vector + temporal knowledge graphs
Mem0, **Zep/Graphiti** (temporal KG, +15 on LongMemEval), Letta, LangGraph. Cross-session,
learned-workflow, time-aware memory. **We're at facts+episodes MVP** — a real gap.

### Runtime, MCP, governance
OpenAI Agents SDK + agent-infra **AIO Sandbox** (browser+shell+file+MCP in one container); **WebMCP**
(W3C — sites expose tools to agents); MCP collapses N×M→N+M. **OWASP Top-10 Agentic**, **NIST AI Agent
Standards**, Microsoft **Agent Governance Toolkit**, MCP gateways + egress inspection + DID identity.
Bessemer: *"securing AI agents is the defining cybersecurity challenge of 2026."*

---

## 2. Where we stand — honest audit (from the codebase ledger)

**Standout strengths (our moat):**
- **Trust/verification — best-in-class.** TOCTOU-safe confinement, layered shell policy, Seatbelt
  sandbox, git-isolated worktrees, **ForgeSeal HMAC signoff ledger** (hash-chained, fail-closed),
  **claim reconciliation** (claims checked vs committed diff + test exit — hallucinations blocked),
  **Foreman 6-gate judge** + **GroundedVerdict**. *Almost nobody else has forge-proof, no-fabrication
  verification.*
- **Provider-agnostic by construction.** 16 providers / 80+ models, **native tool-calling AND a
  universal text-protocol** that works on every model incl. local. "Use every AI" is real.
- **Orchestration breadth.** Single-loop, plan-execute DAG, supervised fleet (disjoint leases), AI
  council, recursive spawn — with durable checkpoint/resume + replan.
- **Multimodal + data.** Image/video/audio/pdf, Gemini Files API, media index, spreadsheet + DuckDB.
- **Cost + evolution lab + AgentTrace telemetry.**

**Gaps (vs the frontier above):**
1. **Eval/observability layer** — we have trace *spans* but no eval harness, no LLM-judge regression,
   no eval-on-PR gate, no trace dashboard/OTel export, no prod-trace→eval-case loop. **Biggest gap.**
2. **Memory** — facts+episodes only; no vector retrieval, no temporal KG, no learned-workflow recall.
   (Note: this worktree lacks the OutcomeMemory/FleetLessonStore that MEMORY.md references — verify/port.)
3. **Security auditing as a product** — strong *defensive* posture, but no *offensive/audit* mode:
   no SAST / dependency-audit / secret-scan / threat-model / structured vuln report. **Biggest opportunity.**
4. **Browser / web / computer use** — only macOS `computer_control` (open app/URL); no browser agent,
   no WebMCP, no real web automation.
5. **Business/vertical workflows** — we're a horizontal engine; no packaged analyst/report/research
   workflows on top of the new data tools.
6. **Governance/standards** — strong primitives, but no explicit OWASP-Top-10-Agentic mapping or
   audit-trail export for buyers.
7. **Native tool-calling completeness** (minor) + MCP gateway/egress inspection (minor).

---

## 3. The roadmap (prioritized — moat first, then the categories paying)

### Tier 1 — extend the trust moat into the two biggest gap/opportunity pairs

**P1 · Eval + Observability layer** *(closes the #1 gap; reliability + sellable)*
Turn `AgentTrace` into a real harness: trajectory traces (step/tool/reasoning), **LLM-as-judge
regression suites**, an **eval runner that gates a build on score drop**, OpenTelemetry export + a
local trace viewer, and a **prod-trace → eval-case** loop. Target the proven incident causes
(tool-call failures, context truncation, runaway loops) with specific detectors. *Natural extension of
our no-fabrication DNA: we already verify outcomes — now we measure trajectories.*

**P2 · Security Audit mode** *(closes the #1 opportunity; differentiator = trustworthy findings)*
A first-class `audit` workflow: secret-scan + dependency/CVE audit + SAST + threat-model + a structured
report mapped to **OWASP Top-10 (app & agentic) / SOC2 controls**. **Run every finding through claim
reconciliation + PoC verification** so we ship *zero hallucinated exploits* — the exact thing the
frontier (XBOW/PentAGI) struggles with. "Audit-grade, verified-by-construction security."

**P3 · Real memory** *(closes a core gap)*
Vector retrieval + a temporal knowledge graph (build, or integrate **Mem0/Zep via MCP**) for
cross-session learned workflows; wire `OutcomeMemory` + `FleetLessonStore` so the runtime *learns from
past runs*. Memory stays advisory/retrieval — never a verdict authority (keeps the trust invariant).

### Tier 2 — reach + business value

**P4 · Browser / web agent + WebMCP** — real web automation (a sandboxed browser tool + WebMCP client),
so "do this on the web" works, not just "open a URL."

**P5 · Business workflow templates** — packaged analyst/report/research/customer-ops flows on top of
the data tools (spreadsheet, DuckDB, media): "analyze this dataset → build the report," "compare these
two graphs → memo." Targets the 38%-data-analysis / 43%-service ROI lanes.

**P6 · Governance & standards reporting** — map our primitives to OWASP-Top-10-Agentic + NIST, export
an audit trail (signoff ledger + traces) buyers can attest against.

### Tier 3 — polish
Native tool-calling completeness across providers · MCP gateway + egress inspection · agent identity
(DID/behavioral trust) · Linux sandbox tier (bubblewrap).

---

## 4. Positioning — what we tell the user we are
Not "a coding tool." **A trustworthy agent runtime** — *use it to build, to audit security, to analyze
a business's data, to automate knowledge work* — where the difference is that **the work is verified,
not claimed.** Every other category leader has a hallucination problem; our moat is that we don't ship
unverified work. The roadmap turns that moat into products in the three lanes the market funds:
**engineering (P1), security (P2), business (P5).**

---

## 5. Recommended first build
**P1 (Eval/Observability)** and **P2 (Security Audit mode)** in parallel — both extend the verification
moat, both are top-of-market gaps, and both reuse what exists (`AgentTrace`, `ClaimReconciler`,
`GroundedVerdict`, the tool layer). Memory (P3) follows. Start with P2's secret/dependency scan + a
verified report (fast, high-signal, demoable) and P1's LLM-judge eval runner on our own trajectories.

_Sources:_ Gartner (enterprise agent market & projections), CIO/StartupHub/Morph (coding-agent
landscape), Braintrust/LangSmith/Latitude (observability & eval), Astra/XBOW/PentAGI/escape.tech
(agentic pentest), Mem0/Zep/Graphlit (agent memory), OWASP Top-10 Agentic, NIST AI Agent Standards,
Microsoft Agent Governance Toolkit, Bessemer (agent security). Links in chat.
