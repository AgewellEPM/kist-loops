# Hard Reality — Where kist Stands vs The Field, and How We Win

No flattery. This compares what we ACTUALLY built (kist/Mythos, 784 tests, on `main`) against what's
actually shipping in 2026, and says plainly where we lose, where we win, and what to do.

---

## 1. The field, June 2026 (who's real, with numbers)

| Tool | What it is | Reality |
|---|---|---|
| **Claude Code** (Anthropic) | The reference. CLI + VS Code + JetBrains + Desktop + Web + **Agent SDK** (Py/TS) + GitHub Action/App | **#2 Terminal-Bench 2.1 (Opus 4.8, 78.9%)**. Subagents, **Skills** (unified w/ slash cmds), Hooks (tool/session/stop/subagent), **Plugins** (versioned bundles). Everywhere. |
| **Codex CLI** (OpenAI) | Terminal agent, multi-agent | **#1 Terminal-Bench 2.1 (GPT-5.5, 83.4%)** |
| **OpenCode** | Open-source breakout | **165k stars — most-starred coding agent.** TUI, build/plan agents, **LSP 20+ langs**, **75+ providers** (Models.dev), MCP, ships daily |
| **OpenHands** (ex-OpenDevin) | Fully autonomous | **74k stars, $18.8M Series A**, contributors from Apple/Google/NVIDIA/Netflix |
| **Gemini CLI** | Google terminal agent | **105k stars** — but **being retired June 2026** → closed-source "Antigravity CLI" |
| **Crush** (Charmbracelet) | Best-looking TUI | **Best TUI in the category**, mid-session model switch, LSP, MCP, granular permissions, many providers |
| **Pi** (Armin Ronacher) | Minimal harness | **54k stars** on a <1000-token system prompt |
| **aider** | Git-native edits | Still wins for disciplined git-native diffs |

**2026 verdict from the field:** "the year autonomous agents stopped being demos and became
infrastructure." Multi-agent teams (one writes / one reviews / one tests) are now table stakes
(Claude agent teams, Codex multi-agent, Copilot fleet mode).

---

## 2. Hard head-to-head — where we LOSE, where we WIN

### ❌ Where we genuinely LOSE (don't kid ourselves)
1. **TUI** — ours is **PROTOTYPE** (opt-in `--tui`, not live-verified). Crush/OpenCode have polished,
   beloved TUIs. This is the most visible gap.
2. **LSP integration** — we have **none**. OpenCode (20+ langs) and Crush feed the agent
   language-server signals (defs, diagnostics, refs). We're guessing where they're grounded. Real
   code-quality gap.
3. **No benchmark number** — Codex 83.4%, Claude 78.9% on Terminal-Bench 2.1. We are **unmeasured**.
   We cannot claim parity without a number, and "trust me" isn't a number.
4. **Distribution / surfaces** — terminal-only. Claude Code is CLI + IDE + desktop + web + SDK +
   GitHub. We have one surface (and a second, *diverged*, GUI — U1).
5. **Ecosystem / adoption** — no skills marketplace, no plugins, **no stars, no community**. OpenCode
   165k, OpenHands 74k. We're pre-release and private.
6. **Proving depth** — 1 clean cross-provider run. OpenHands has battle-tested autonomy at scale.

### ✅ Where we genuinely WIN (the real moat — nobody else has this depth)
1. **Verified, not claimed.** Forge-proof signoff (HMAC chain), claim reconciliation (claims checked
   vs committed diff + tests), grounded verdicts, the Foreman 6-gate. **No other open agent has a
   trust layer remotely this deep.** The whole field has a hallucination problem; we structurally don't.
2. **Heterogeneous teams WITH verification.** Just proven live: MiMo plans · **DeepSeek codes** ·
   **Gemini critiques** → file written, per-vendor token trace. Crush/OpenCode *switch* models;
   they don't run *verified multi-vendor teams with forge-proof signoff*.
3. **Deterministic security + governance.** `security_audit` (grounded, secret-redacted, zero
   hallucinated findings — proven live), `governance_report` (OWASP-Agentic posture w/ evidence).
   The pentest frontier (XBOW) struggles with fake findings; we don't produce them.
4. **Conversational control.** Just shipped: *talk* to rebind roles/models/settings — "use DeepSeek
   as builder and Gemini as critic" mutates the runtime. Crush switches models via UI; we do it by
   talking, and run the team automatically.
5. **Security posture.** TOCTOU-safe confinement, structured spawn, Seatbelt, **SSRF-guarded browser
   with per-request in-driver guard** (proven live), secret redaction. Better than most (independently
   confirmed by MiMo's audit + the research).
6. **Breadth of tools.** analyze_media (video timeline/transcript), spreadsheet+DuckDB, browser,
   `/tasks` runbook, self-monitoring + lesson memory. Wider than a pure coding agent.
7. **Universal text protocol** — works on ANY model incl. local. "Use every AI" is literally true.

---

## 3. The strategic read (the only honest way to win)

The stack splits in two:
- **Commodity layer** (loop, providers, TUI, LSP, IDE plugins): the field is ahead on TUI/LSP/surfaces,
  at-par on providers, and these are **standardizing fast**. We will NOT win by out-TUI-ing Crush or
  out-starring OpenCode. Chasing that is a losing race.
- **Value layer** (trust / verification / governance / multi-agent correctness): **we are ahead of the
  entire open field here**, and this is exactly where 2026's value is migrating (apps + observability/
  governance, per the research). This is the moat.

**So the winning move is barbell, not catch-up:**
- **Don't lose on basics** — close just enough of the table-stakes gap (a usable TUI, LSP, a benchmark
  number) that nobody dismisses us on UX/correctness.
- **Win on the unmatched thing** — be **"the agent runtime you can trust for high-stakes work"**:
  verified, heterogeneous, governed. That's a category the others can't easily copy (it's architecture,
  not a feature), and it's the one that matters for Luke's domain (vulnerable users, real products).

---

## 4. The plan — be better than what's out

### Track A · Close table-stakes (so we don't lose on basics)
- **A1 · Ship the TUI for real.** Finish P4 (raw-mode persistent-input, type-while-running, single-key
  approvals) → production, not PROTOTYPE. Match Crush's bar enough to not embarrass us.
- **A2 · LSP integration.** Wire a language-server client (defs/diagnostics/refs) so the coder/critic
  are grounded like OpenCode. Biggest code-quality lever we're missing.
- **A3 · Get a Terminal-Bench number.** Run Terminal-Bench 2.1 (and SWE-bench-lite) on our loop with a
  strong model. **A measured score is the price of being taken seriously.** Use our eval harness.

### Track B · Extend the moat (win on what's unique)
- **B1 · Unified Verifier → signoff** (the U2 already in the roadmap): web (tinky-verify) + app
  (IsolatedTester) + code (GroundedVerdict) behind one interface, feeding claim-reconciliation. Make
  "verified across web/app/code" a single guarantee no one else has.
- **B2 · Make the heterogeneous-verified-team the headline.** Polish the DeepSeek-codes /
  Gemini-critiques / signoff flow, add the 20–50 proving runs, and lead with it — it's the demo nobody
  else can run.
- **B3 · Finish conversational control + governance as product.** Escalation/approvals/budget by
  talking; surface `governance_report` + trajectory self-checks as a "prove this agent is safe" output.
- **B4 · Trust benchmark.** Invent the number the field lacks: a **hallucination/verification score**
  (claims-made vs claims-verified, fake-finding rate). We'd top a leaderboard that plays to our moat.

### Tier 3 (later): IDE/SDK surfaces, skills/plugins ecosystem, MCP gateway, A2A.

---

## 5. The one-line positioning
Everyone else is racing to be the **fastest** coding agent. Be the **most trustworthy** one — the only
runtime that runs a real multi-vendor team and **proves** the work (code, web, AND app) instead of
claiming it. Close enough of the TUI/LSP/benchmark gap to sit at the table; win on the trust nobody
else has.

_Sources:_ Claude Code docs + 2026 feature roundups (code.claude.com, marktechpost, alexop.dev),
CLI-agent comparisons (tembo, pinggy, sanj.dev, morphllm Terminal-Bench), OpenCode/OpenHands/Pi
star+funding data (dev.to, ossinsight, byteiota). Links in chat.
