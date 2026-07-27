# Documented vs Built — Honest Cross-Comparison (2026-06-29)

28 plan docs · 158 Swift files · ~976 tests. Luke's read is correct: **the PRODUCTS are documentation
only; the FOUNDATIONS those products need are heavily built.** The gap is the *middle* — nobody has
assembled the built foundations into the documented products. Verified by grep, not vibes.

> Engine: built. Cars: not assembled yet.

---

## ✅ FOUNDATIONS — real code + tests (the engine)
| Capability | Built | Where |
|---|---|---|
| Agent loop (write→exec→observe→replan, checkpoint/resume) | ✅ | HeadlessAgentLoop.swift |
| Tool family (read/write/edit/move/make_dir/list/glob, **ripgrep search**, **apply_patch**, run_command) | ✅ | Tools/ |
| Multimodal (analyze_media video/audio, media_clip) | ✅ | AnalyzeMediaTool, MediaClipTool |
| Web (fetch_url SSRF-guarded, web_search) | ✅ | WebFetchTool, WebSearchTool |
| AgentForge P1–P3 (specialist definition/registry/forge, `/agents`) | ✅ | Specialist/ |
| Tool scoping (no-privilege-escalation) | ✅ | ToolRegistry.scoped |
| Promotion gate (council judge → CaptainGate → pipeline) | ✅ | CouncilPromotionJudge, CaptainGate |
| Reversibility gate + **exfil gate** + capability-denial steer | ✅ | ReversibilityClassifier |
| `--auto` autopilot + forced sandbox (Seatbelt) | ✅ | KistOptions, SeatbeltSandbox |
| Conversational (collaborator persona, ask_user) | ✅ | HeadlessAgentLoop, AskUserTool |
| UX (status line, plain-language team, error humanizer, council card, operator panel, proof drawer) | ✅ | Kist/UX/ |
| Tool contract (capability manifest) | ✅ | ToolContract |
| **Review-without-paths** (resolver + Prompts module + batcher) | ✅ | Review/, Prompts/ |
| **Cortex memory** (preferences/projects/journal as .md) | ✅ | Memory/CortexMemory.swift |
| MCP client (stdio) | ✅ | MCP/, RemoteMCPTool |
| Security primitives (audit, governance, SecretScanner, CIIntegrityGuard, ForgeSeal, signoff ledger) | ✅ | Security/, Fleet |
| Fleet/Captain (orchestrator, supervisor, blackboard, scope validator) | ✅ | Fleet*/ |
| Eval harness (EvalRunner, TrajectoryAnalyzer) | ✅ | Eval/ |

## 🟡 PARTIAL / on the other branch (the system is SPLIT across 2 worktrees)
| Capability | Status |
|---|---|
| `view_image` (vision) | ✅ **on GPT's branch** (`feat/kist-multimodal`), ❌ on wave1 — needs merge |
| `AuthorizationScope` (the scope guardrail) | ✅ **on GPT's branch**, ❌ on wave1 — needs merge |
| `TaskPersonaMatcher` (persona auto-select, AgentForge P4) | 🟡 **GPT building on its branch**, ❌ on wave1 |
| Prompts centralization | 🟡 started (Prompts.swift); ~25 files still scattered |
| Live model-driven todo | 🟡 `tasks` exists; not surfaced as a live ≤1-in_progress checklist |
| Auto-learn cortex | 🟡 manual `/cortex remember` built; end-of-session extraction not |

## ❌ PRODUCTS — DOCUMENTED, ZERO CODE (the whole nine yards)
Grep found **no implementation** for any of these — the "hits" were false-positive substrings
(`diagnos`→GroundedVerdict, `Wizard`→KeyStore). Each is a full doc, not a line of product code:
| Product | Doc | Built |
|---|---|---|
| **Bug-bounty assistant** (+ guided wizard) | BUG_BOUNTY_ASSISTANT_PLAN.md | ❌ none |
| **Security-awareness platform** (micro-tests, phishing sim) | SECURITY_AWARENESS_PLATFORM_PLAN.md | ❌ none |
| **App reconstruct & harden** (mirror, reconstruct, SAST/DAST) | APP_RECONSTRUCT_HARDEN_PLAN.md | ❌ none |
| **Vision flow reconstruction** (screenshot→app, visual-diff loop) | VISION_FLOW_RECONSTRUCT_PLAN.md | ❌ none |
| **Server/network diagnostics** (SRE co-pilot, SSH) | SERVER_NETWORK_DIAGNOSTICS_PLAN.md | ❌ none |
| **Persona research collective** | PERSONA_RESEARCH_COLLECTIVE_PLAN.md | ❌ none (forge exists; collective doesn't) |
| **Prompt-injection defense suite** (scanner, MCP hash-pin, trifecta taint) | PROMPT_INJECTION_DEFENSE.md | 🟡 ONLY the exfil gate built |
| **Red-team / blue-team harness** | (in injection-defense doc) | ❌ none |
| **The guided "wizard"** (beginner mode) | (bug-bounty doc) | ❌ none |

## ❌ Tool-family gaps still doc-only
LSP / code-intelligence · repo-map (tree-sitter) · MCP HTTP transport + remote OAuth + resources/lazy-load ·
Linux sandbox (Landlock/seccomp) · background/PTY exec · web POST/auth · cross-platform image (libvips) ·
file-watch. (All in TOOL_FAMILY_GAP_ANALYSIS.md; none built.)

---

## The honest takeaways
1. **You're right: every documented PRODUCT is unbuilt.** Bug bounty, security awareness, app/vision
   reconstruction, server diagnostics, red/blue team, the wizard — 0 lines each. We wrote the brochures,
   not the products.
2. **But it is NOT "nothing built."** The foundation layer is large and real — ~158 files, ~976 tests:
   the loop, the tools, the trust spine, forge, MCP, the security primitives, review, memory. The products
   are *assemblies* of these — most are weeks of integration, not green-field.
3. **The system is SPLIT across two diverged branches** — wave1 (cortex, review, exfil) and
   feat/kist-multimodal (view_image, AuthorizationScope, TaskPersonaMatcher). **Merge them first** or the
   "current system" keeps being two half-pictures.
4. **The highest-leverage next move is NOT another product doc** — it's: merge the branches, then pick ONE
   product and build it end-to-end on the real foundations (the bug-bounty/security path is most reuse —
   it sits on the scope gate + security tools + verify spine that already exist).
