# kist LEAPFROG ROADMAP — ahead by miles (council-hardened 2026-07-04)

Panel: DeepSeek + Grok + GPT-5 (built on the DeepSeek/Grok/MiMo industry analysis). The draft "adaptive
verification + IDE sidecar + capability parity" was unanimously judged CATCH-UP. This is the reframe.

## THE REFRAME (what the panel forced)
1. The moat must be **technical + unblockable**, not relational. Riding Cursor/Copilot as a "sidecar" fails —
   they'll block a nagging verifier the moment it threatens their numbers.
2. Stop optimizing "better than competitors" → make kist's output a **COMPLIANCE PRIMITIVE** that regulators,
   insurers, and SOC2/FedRAMP/HIPAA controls REQUIRE. When the artifact is mandatory, every agent must emit it.
3. Decouple verification COST from LLM cost: LLMs GENERATE proofs; kist deterministically CHECKS them in ms.
4. Own regulated/vulnerable-user deployment (where Devin/Anthropic are BANNED) via policy-as-boundary + audit +
   liability indemnity — an ECONOMIC moat no capability-only player can match.

## WS1 — COST/LATENCY → PROOF-CARRYING PATCHES (GPT-5 killer move)
LEAP (not adaptive routing — that's catch-up): every change ships a MACHINE-CHECKABLE artifact — contracts +
property tests + ABI/schema/security invariants. The LLM/council GENERATES the proof; kist only CHECKS it with
DETERMINISTIC checkers (static analysis, type/DB-migration guards, snapshot tests) in milliseconds, locally,
model-independent. Verification cost decouples from token cost → "always-on verification cheaper than skipping."
- T1.1 Verification Receipt schema: (diff hash, invariants asserted, checks run, results, signer). The primitive.
- T1.2 Deterministic checker suite: type/compile, tests, static-analysis, migration/ABI/secret-policy guards.
- T1.3 Proof/spec generation: council emits the contracts + property tests a change must satisfy.
- T1.4 Invariant MINING: learn repo/org-specific contracts from history (proprietary; compounding moat).
- T1.5 Distilled fast verifier (3B) for the residual LLM-judgment checks — 10ms, always on (DeepSeek/Grok).
- T1.6 Adaptive fidelity + risk routing, trained on REAL gauntlet data (WS4), NOT dogfood anecdotes.

## WS2 — DISTRIBUTION → UNBLOCKABLE GIT/FS GUARD + open receipt standard (GPT-5 + Grok)
LEAP (not sidecar plugins): a signed LOCAL GUARD that wraps git (pre-commit/merge) + a lightweight VFS that
intercepts writes from ANY agent/editor/CLI. A merge REQUIRES a valid kist Verification Receipt. IDE-politics-
free, works everywhere, unblockable.
- T2.1 GitHub App + required PR check gated on the Verification Receipt (primary distribution).
- T2.2 Local git-guard (pre-commit/pre-merge) + org policy packs (per repo/language).
- T2.3 OPEN the Verification Receipt format + reference checker as a neutral PUBLIC GOOD; keep the high-assurance
  council PROPRIETARY. Every IDE/agent must emit kist-compatible receipts to sell into regulated buyers.
- T2.4 Enterprise: MDM deployment, GH/GitLab co-sell, Jira/ServiceNow change-mgmt hooks.
- T2.5 Editor plugins (VS Code/JetBrains) — LAST, as UX sugar over the guard.

## WS3 — COMPUTER-USE → POLICY-ENGINE + ATTESTED REPLAY VM + INDEMNITY (Grok + GPT-5)
LEAP (not capability parity — a sucking-cost trap): the verification gate becomes the POLICY ENGINE that decides
which actions are even ATTEMPTED, in an ephemeral INSTRUMENTED desktop VM with full event capture, time-travel
replay, deterministic intent→effect diff, and a signed action ledger. Own the environments where Anthropic/Devin
are BANNED. Wrap their computer-use APIs for raw capability; kist owns the TRUST layer.
- T3.1 Finish the split-identity broker (signed 2-binary + hardware TCC test — already spec'd).
- T3.2 SecureAction DSL (policy-as-code: SOX/HIPAA/PCI mappings) — the gate decides attemptability.
- T3.3 Ephemeral attested VM: event capture + time-travel replay + signed action ledger.
- T3.4 Formal intent-vs-action spec for GUI ops (else the gate is "just another heuristic" — DeepSeek).
- T3.5 LIABILITY INDEMNITY: contractual warranty when the ledger proves an action was verified (economic moat).

## WS4 — BENCHMARKS → PUBLIC CONTINUOUS GAUNTLET + owned benchmark (GPT-5 + DeepSeek)
LEAP (not internal scoreboard theater): an always-on auto-fix gauntlet across 1k opt-in OSS repos with NOTARIZED
receipts, THIRD-PARTY audit, weekly transparency, and a PAID WARRANTY for a bad merge. Trust becomes measurable.
- T4.1 SWE-bench-Verified harness + the verified-vs-unverified A/B (prove council+gate raises resolve / cuts
  wrong patches) — AND the verified arm must also be the FASTEST (WS1 makes that true).
- T4.2 Public gauntlet (1k OSS repos, notarized receipts, warranty). Launch as soon as the git-guard exists.
- T4.3 CREATE the "Adversarial Code-Editing Challenge" (inject subtle security flaws, measure detection) → make
  it the de-facto standard kist owns.
- T4.4 Metrics others don't run: revert rate, PR cycle time, leakage incidents, SBOM/supply-chain attestation.
- T4.5 Robustness suite (noisy inputs: API failures, model drift) + score-regression release gate.

## MISSING FROM THE DRAFT (panel-flagged) — now first-class
- BUSINESS MODEL: open-core (receipt standard + checker open; council + warranty + enterprise proprietary).
- The open **Verification Receipt + Attestation Token** = the compliance primitive everything else hangs on.
- Actuarial bug WARRANTY / indemnity = the uncatchable economic moat.
- A2A/ACP bridge is DEFERRED (premature without distribution).

## SEQUENCE (GPT-5's, panel-endorsed)
1) Git-guard + GitHub App w/ PROOF-CARRYING PATCHES + the Receipt standard (unblockable dist + cheap verify).
2) Public GAUNTLET + warranty (prove it; build the trust asset).
3) Train risk routing from REAL gauntlet data.
4) Enterprise policy packs + MDM.
5) Editor UX (sugar).
6) Deterministic VM computer-use for a few high-value regulated workflows.
7) Broader computer-use parity + A2A bridge.

BOTTOM LINE: don't build a better agent — build the **verification primitive the industry is forced to route
through**, distributed unblockably via git, monetized via warranty. That's ahead-by-miles and uncatchable.
