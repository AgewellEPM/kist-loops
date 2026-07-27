# Mythos vs the World — Competitive Synthesis (2026-06-27)

Four parallel live-web research passes (HN / GitHub / Google / arXiv), each a distinct lens:
fleet orchestration · agent-work verification · multi-vendor teams · adversarial debate. Cross-compared
against what we've actually built (Stage 0–1 of the Captain port: worktree isolation + disjoint leases +
deterministic referee + forge-proof signoff + Foreman verify-and-sign + planned Council).

## VERDICT
The moat is **real but narrow**, and it points at the exact failure the field just admitted out loud.
- **Anthropic + AWS now say our thesis aloud:** agents lie about "done"; gate on measured evidence, not
  their word (Anthropic supervisor session + success-classifier on verifiable evidence; AWS: "insert a
  deterministic check between Executor and Validator"). We built that as the *spine*, not a patch.
- **AgenticFlict (arXiv 2604.03551):** 142K agentic PRs, **27.67% merge-conflict rate**, ~11 conflict
  regions/PR — the field has worktree *isolation* (detect) but not *prevention*. Our disjoint leases
  prevent at the source.
- The work I did THIS session (TOCTOU "test rewrote the committed code" check) is **the live exploit**
  the literature flags (EvilGenie test-file-edit; SWE-bench-Pro 100% via in-container parser overwrite).
  Most harnesses are vulnerable to exactly what we just closed. We're aimed right.

## WHERE WE GENUINELY LEAD (don't bury these)
1. **Disjoint file LEASES = prevention, not detection.** Everyone (Claude Code native worktrees, ccswarm,
   uzi, claude-squad, container-use, Factory, Devin Desktop) isolates with worktrees and *detects*
   collisions at merge. `FleetScopeValidator` clears any overlapping pair to empty so two agents can
   *never* hold an overlapping non-empty lease. Almost nobody ships structural prevention.
2. **By-construction-no-fake-green + deterministic referee FUSED with a cryptographic seal.** Every
   surveyed verifier is a *detector* (EvilGenie, TDFlow audit, Anthropic classifier) — catches hacking
   after the fact. Ours makes a passing verdict *unconstructible* except by passing the deterministic
   judge over real artifacts, then HMAC-seals + hash-chains it. The intersection of the test-gating
   literature and the tamper-evident-provenance literature is **empty except us**.
3. **Claim↔committed-diff reconciliation + TOCTOU test-tamper check.** Granular anti-hallucination
   (per file/symbol/test vs committed-only git) + the parser-overwrite defense the SWE-bench post-mortems
   say is the active exploit. Rare.
4. **In-process heterogeneous team sharing a typed plan.** Closest competitor — Thomson Reuters
   **"Claude Forge"** — is subprocessed CLIs + LiteLLM proxy + file handoffs (exactly what we
   differentiate against). CrewAI/AutoGen do per-role models but as a Python framework, no shared typed
   plan, not a shell.
5. **Council design is on the right side of the debate evidence.** Gavel-bounded + diverse-vendor +
   distinct-lens + skeptic-but-falsifiable + cost-gated are *precisely* the mitigations the negative-
   results papers (2311.17371, 2509.05396, 2511.07784) recommend. We engineered around the snake-oil.

## WHERE WE'RE COMMODITY (never market as moat)
- Worktree isolation (Claude Code v2.1.49 native, ccswarm, uzi, squad, container-use).
- BYOK / provider switching (RouteLLM, OpenRouter, LiteLLM, Portkey, Goose, CrewAI).
- Model routing/proxying. Hash-chain + signing *mechanics* (many OSS audit-log impls).
- Test-gated "make the failing test pass" loop (TDFlow 94.3% SWE-Verified, Claude Code TDD).
- Live per-agent observability panes (claude-squad, Conductor).
- **Positioning rule (Agent C, emphatic): lead with "trust spine + disjoint leases + in-process typed-plan
  team." NEVER lead with "BYOK / multi-model / worktrees" — all commodity.**

## WHERE WE'RE BEHIND / MISSING (honest)
1. **Symmetric HMAC seal → should trend asymmetric + external log.** HMAC = verifier holds the secret, so
   whoever can mint can forge. Fine for same-user/same-machine (documented residual, covered by the
   Ed25519 deploy tier) — but for external verifiability the *signoff itself* should move toward Ed25519
   (we already built the primitive) + an in-toto/SLSA envelope + ideally a Rekor-style append-only log.
   Counter-view exists ("Tool Receipts, Not ZKPs", 2603.10060 — crypto is overkill); but for a
   self-forging-agent threat model, asymmetric is defensible.
2. **No held-out / mutation oracle.** ~31% of "passing" SWE patches pass *weak* tests (green but wrong).
   We trust the repo's own suite. A held-out/mutation dimension closes "green on a weak suite."
3. **Behavioral/UI validation gap.** Our gate = test exit + diff + size. Factory's validator agents
   *launch the app and click flows*. **We OWN tinky-verify (Gemini visual verifier) and it is NOT wired
   into the fleet gate.** Cheapest big win on the board.
4. **Lease partitioning uses a raw dir-tree.** Aider's **repo-map (PageRank over the call graph)**
   partitions along dependency seams → fewer forced cross-lease edits, tighter disjoint scopes.
5. **No rebase-on-latest-before-merge** for the non-disjoint residual (shared interfaces, generated files)
   — where AgenticFlict says the real conflicts live.
6. **Scale.** Local single-digit agents vs Factory "thousands of droids" / OpenHands "thousands of runs"
   in cloud sandboxes. Hard ceiling, not our near-term game.
7. **Council synthesizer is the weak link** (LLM-judge bias: self-preference, position, verbosity). Keep
   it non-authoritative (gavel decides); make the synthesizer a *different* vendor than the debaters.
8. **No public evals.** A demo, not a measured win. Competitors cite Terminal-Bench / SWE-bench.

## TOP STEALS (ranked by leverage/cost)
1. **Wire tinky-verify into `FleetIntegrationVerifier`.** We own it; closes green-but-broken-UI;
   near-free. #1.
2. **Promote a critic's falsifiable repro into the PERMANENT gavel test suite.** When a Council critic
   constructs a reproducing input, auto-add it as a regression test. Turns the adversary's value into
   permanent coverage and makes "bounded by the gavel" strictly tighter over time. (Agent D's best idea;
   mirrors our own multi-site per-assertion discipline — synthesis can only ADD constraints, never drop a
   real objection.)
3. **Held-out / mutation-test oracle dimension** (TDFlow reproduction-first + EvilGenie held-out). Run the
   patch against tests it never saw; mutation-test the suite. Real teeth against weak-oracle certification.
4. **Move signoff toward Ed25519 + in-toto/SLSA envelope.** External verifiability + free interop with
   Sigstore/policy engines + the format regulators (EU AI Act Art. 12) are coalescing on. We have the
   primitive.
5. **Aider repo-map for lease partitioning.** Replace the raw dir-tree in `AgentPlanner.plan(scopeContext:)`.
6. **Rebase-on-latest-before-merge + re-run the gate** for residual overlap (AgenticFlict's fix).
7. **Self-consistency MIDDLE tier in the cost gate.** trivial → fast; medium → self-consistency (N-sample
   vote, cheaper, equal quality to debate on most problems); risky concurrency/IO/security → full Council.
   Don't pay Council cost where SC wins.
8. **Race mode** (K agents take the SAME lease; the objective gate score picks the winner, discard rest).
   Factory races solution approaches; our deterministic gate is uniquely suited to make it trustworthy.
9. **ACP (Agent Client Protocol)** so foreign agents (Codex/OpenCode) can join a Mythos-supervised fleet
   under our lease+gate discipline — turns the gate into a *governance layer over any agent*, not just ours.

## TWO HONEST CAVEATS (label discipline)
- **The text-protocol loop is a TRADE, not a pure win:** provider-agnostic by construction, at the cost of
  native tool-use reliability + provider prompt-cache cost savings (LiteLLM/Vercel-AI-SDK exploit those).
  A sharp enterprise eval will probe exactly there. Don't sell it as free.
- **"A flaw is real only if a test fails it" is a SAFETY guarantee (no regression ships), NOT a correctness
  one (untested failure modes are invisible).** The gavel must never breed false completeness. PILOT-READY
  framing, not "verified correct."

### Key sources
Anthropic multi-agent (anthropic.com/engineering/multi-agent-research-system) · AWS deterministic-check
(dev.to/aws/how-to-stop-ai-agents-from-hallucinating-silently) · AgenticFlict (arXiv 2604.03551) ·
ccswarm (github.com/nwiizo/ccswarm) · Factory Missions (factory.ai/news/missions-architecture) · Claude
Forge (medium.com/tr-labs-ml-engineering-blog) · TDFlow (arXiv 2510.23761) · EvilGenie (arXiv 2511.21654)
· Berkeley RDI trustworthy-benchmarks · SLSA/in-toto (slsa.dev) · MoA (arXiv 2406.04692) · RouteLLM
(github.com/lm-sys/RouteLLM) · OpenCode-Anthropic-block (nxcode.io) · Du multiagent debate (2305.14325) ·
LLMs-Cannot-Self-Correct-Yet (2310.01798) · Should-we-go-MAD (2311.17371) · Talk-Isn't-Cheap (2509.05396)
· Can-LLM-Agents-Really-Debate (2511.07784) · Diversity-of-Thought (2410.12853) · CRITIC (2305.11738).
