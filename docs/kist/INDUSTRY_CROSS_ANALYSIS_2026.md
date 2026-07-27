# kist vs the AI-coding-agent industry — cross-analysis (DeepSeek + Grok + MiMo panel, 2026-07-04)

Panel: DeepSeek-reasoner, Grok-4, MiMo-v2.5-pro (the last run THROUGH kist itself — it fired kist's own
HostControlPreflight warning + MCP host-control drop mid-analysis, a live dogfood of this session's security).

**CALIBRATION (honest):** the panel was given *our* description of kist, so "AHEAD" verdicts partly reflect
framing. Trust the CONVERGENT signals: (a) the gaps all three name independently (cost, distribution, interop)
are real regardless of framing; (b) the "genuinely novel, not replicated" claims are broadly checkable and
consistent across all three. Treat exact "12–18 months ahead" as directional, not gospel.

## 1. Cross-comparison — consensus (all 3 agree unless noted)
| Dimension | Verdict | vs. whom |
|---|---|---|
| Provider-agnosticism (uniform TEXT protocol, BYOK, per-turn auto-route) | **AHEAD (leads)** | Claude Code (Anthropic-only), Codex CLI (OpenAI-only), Cursor (IDE-locked); Aider does multi-backend but via adapters, no uniform protocol/auto-route |
| Security model (split-identity TCC broker, sandbox tiers, default-deny) | **AHEAD (field-leading)** | > all OSS (Aider/OpenHands/SWE-agent); ≥ Claude Code (basic prompts); > Cursor/Devin (containers, not privilege-separated) |
| Multi-agent orchestration (lease enforcement + HMAC-sealed signoff + Ed25519 gates) | **AHEAD** | > CrewAI/AutoGen/LangGraph (frameworks, no crypto enforcement); more auditable than Devin's opaque teams |
| Verification discipline (multi-model council + mandatory Codex gate) | **AHEAD (unique)** | No competitor runs cross-model ADVERSARIAL review as a hard "done" gate. Closest: academic LLM-debate (not productionized) |
| Legacy modernization (equivalence cathedral: golden corpus + mutation meter + boundary catalog) | **AHEAD (unique)** | Nothing comparable in Aider/SWE-agent; formal-verification-meets-AI-coding |
| Architecture / durable resume | **AHEAD** of Aider/OpenHands; ~parity Devin; **BEHIND** Cursor's IDE embedding | — |
| Computer-use CAPABILITY | **BEHIND** (safer, less complete) | < Anthropic computer-use / Devin browser automation / Cursor. Grok: "still early"; DeepSeek/MiMo: "at parity but less mature UX" |

## 2. Standards alignment (MiMo mapped the most detail)
- **MCP** ✅ embodied (client + hooks + trust-gating).
- **A2A (Google) / ACP (IBM)** ❌ MISSING — kist's fleet is self-contained (blackboard/baton/ledger), speaks no standard agent-to-agent protocol. All 3 flag this as the key interop gap.
- **OWASP Top-10 for LLM Apps (2025)** ✅ strong — LLM01 prompt-injection (runtime injection-scan), LLM02 sensitive-info (sandbox secret-read denial), LLM04 model-DoS (cost caps), LLM06 excessive-agency (lease + permission modes), LLM08 (default-deny computer-use).
- **OWASP Agentic (2026 draft)** ✅ partial — lease/ledger/gates cover tool-misuse + privilege-escalation; missing explicit A2A trust boundaries.
- **NIST AI RMF** ⚠️ partial — RunLedger + verification + honest labeling map to Govern/Map/Measure/Manage; no formal risk-taxonomy docs, no SBOM/attestation compliance surface for regulated buyers.

## 3. Future 2025–2027
WELL-POSITIONED: provider-agnostic routing (model commoditization), verification>velocity (production/enterprise),
security-first computer-use (privilege separation becoming mandatory — macOS TCC / Linux Landlock), legacy
modernization (huge untargeted enterprise market), cost governance (fleet token burn).
MISSING/LATE (all 3 converge): A2A/ACP interop; IDE surface (Cursor/Copilot own the workflow); cloud-native
execution (Codex/Devin run in cloud sandboxes — kist is local-first, security-superior but limits CI/CD);
visual/multimodal screenshot→code loops.

## 4. Genuinely novel (all 3 concur "not replicated anywhere")
council+Codex-gate verification · split-identity TCC broker · lease-enforced fleet with HMAC signoff ·
equivalence-cathedral legacy modernization. (Provider-agnostic text protocol = "partially novel" — Aider
does multi-backend, but not a uniform protocol + auto-route.)

## 5. THE STRATEGIC ROADMAP — 3 complementary bets (one per model, addressing the 3 real gaps)
- **DeepSeek → COST/LATENCY: Adaptive Verification Fidelity.** Risk-classify each change: trivial (rename/format)
  → single fast model, no council; high-risk (security/refactor) → full council + gate. A "speed mode" keeps only
  the essential safety scans. Makes the verification differentiator usable DAILY instead of a research toll.
- **Grok → DISTRIBUTION: thin VS Code / JetBrains extension** over the headless Swift core, surfacing the
  council verdicts + signoff ledger IN-EDITOR. Keeps the Swift core as the verification authority; removes the
  terminal-only adoption tax (vs Cursor's 500k+ users).
- **MiMo → INTEROP + PLATFORM: an A2A/ACP bridge** exposing kist's fleet as standard agents, so external systems
  ROUTE THROUGH kist's council+gate before shipping code. Turns verification from a walled garden into a
  platform advantage ("the verified backbone of a heterogeneous agent ecosystem").

**Synthesis:** the three are NOT competing — they patch the three gaps every model named. Sequence by leverage:
Adaptive Verification (makes the daily-driver case) → IDE extension (distribution) → A2A bridge (platform).
Consensus bottom line: kist's RISK IS ADOPTION, NOT CAPABILITY — it's ahead on security/verification/multi-agent
rigor and behind on surface + interop.
