# Provider Resilience — Why these break, and how to make kist's AI layer flawless (2026-06-30)

Two failures keep recurring when kist calls models (and they just bit the bug-bounty review via the FCA
tool too):

1. **Reasoning model returns empty content** — "no visible content (reasoning model may have spent the
   budget — increase max_tokens)". MiMo-V2.5-Pro, twice.
2. **Dead model id → 404** — Grok's `grok-2-latest` returned "Model not found".

Different symptoms, **same meta-cause**: the provider layer bakes model ids and token budgets in as STATIC
ASSUMPTIONS and never reconciles them against live provider reality — then its failure handler *masks* the
specific failure (cross-provider fallback) instead of *healing* it.

---

## Root cause 1 — flat token budget, not reasoning-aware
**Evidence:**
- `OpenAICompatibleProvider.swift:81` — `body[tokenBudgetKey(...)] = settings.maxTokens`. A FLAT budget.
- `OpenAICompatibleProvider.swift:42` — `capabilities(forModel:)` already KNOWS `reasoning: Bool`
  (`ModelCapabilities.reasoning`). **It is never consulted at line 81 to size the budget.**
- Call sites pass small budgets: `HeadlessAgentLoop` 4096, `AICouncil` 1400–2200, `CouncilPromotionJudge`
  600.

**Mechanism:** a reasoning model spends its budget on hidden `reasoning_content` FIRST. With a 600–4096
ceiling it never reaches visible `content`. `collectText()` ignores reasoning → returns "" →
`ProviderRegistry.completeWithUsage:199` throws `transport("empty completion")` → classified retryable/
fallback → kist **abandons the model and falls back to a different provider**. The user asked for MiMo and
silently got someone else (or a hard failure).

## Root cause 2 — hardcoded model-id catalog drifts from reality
**Evidence:**
- `ProviderCatalog.swift:98` still ships `grok-2-latest` in Grok's `availableModels` — **dead** (xAI retired
  it). Defaults (`grok-4.3`, `gpt-5.5`, `deepseek-v4-pro`) are hand-edited snapshots.
- No `GET /v1/models` reconciliation anywhere — grep for live model listing finds only the STATIC
  `availableModels` arrays. The catalog can only drift; nothing pulls it back to truth.

**Mechanism:** provider renames/retires an id → kist still sends the stale id → 404 →
`shouldFallback:333` treats 404 as a cross-provider fallback → "ask Grok" silently becomes "answered by
OpenAI", or a hard 404 if no fallback configured.

## The masking problem (makes both worse)
`completeWithUsage` / `retryingStream` fall back to a DIFFERENT PROVIDER on empty-completion AND on 404.
That's wrong for both cases: the real fix for #1 is "give the SAME model more room"; for #2 it's "resolve a
VALID id on the SAME provider". Cross-provider fallback hides the defect and produces answers from a model
the caller didn't choose — silent substitution, the exact anti-pattern the MiMo memory warns about.

---

## The fix — 3 layers (defense in depth) + a preflight doctor

### Layer A — reasoning-aware budget + targeted self-heal (fixes #1)  ★ highest value, pure kist
1. At request build (`OpenAICompatibleProvider` body), when `capabilities(forModel:).reasoning == true`,
   floor the budget: `max_tokens = max(settings.maxTokens, reasoningFloor)` (e.g. ≥ 16k) so reasoning +
   answer both fit. Keep a separate "answer budget" notion so callers asking for 600 answer-tokens still
   get enough thinking room.
2. Classify empty completions: if the response had reasoning and/or `finish_reason == "length"`, it was
   **truncated mid-reasoning** → RETRY THE SAME MODEL with a doubled budget (bounded, ≤ context window),
   NOT a provider fallback. Only a genuinely empty answer (no reasoning, natural stop) surfaces/falls back.

### Layer B — live model-id reconciliation (fixes #2)  ★ high value
1. `ModelResolver` with a TTL-cached `GET /v1/models` per provider. `resolvedModel()` maps a requested or
   catalog id → the nearest VALID live id before the first call; prunes dead ids (grok-2-latest) on sight.
2. On a 404 "model not found", fetch the live list, pick the best valid match, and **retry the SAME
   provider** — only cross-provider fallback if the provider itself is unreachable.
3. Keep `ProviderCatalog` as the offline SEED/fallback; live data overrides it.

### Layer C — honest failure semantics (fixes the masking)
- A model-not-found is NOT a cross-provider event by default (Layer B resolves on the same provider first).
- Empty-due-to-truncation is a same-model retry (Layer A), not a fallback.
- Cross-provider fallback stays ONLY for true provider outages (DNS/timeout/5xx/auth) and is always logged.

### Layer D — `kist providers doctor` (prevention)  ★ catches drift before a task hits it
A preflight that pings each keyed provider's `/models`, diffs it against `ProviderCatalog`, and reports:
stale/dead ids (grok-2-latest), the provider's real default, which models advertise reasoning (+ a sane
budget), and any provider whose key is set but endpoint/model is wrong. Run it in CI + on demand so the
catalog can never silently rot.

---

## Recommended build order
1. **Layer A** — pure kist, no network dependency, directly fixes the MiMo failure. Smallest, highest value.
2. **Layer D doctor** — cheap, turns "we discover drift when a task fails" into "we detect it on demand/CI".
3. **Layer B** — the durable fix for id drift (needs the live `/models` fetch + cache).
4. **Layer C** — falls out of A+B (tighten the fallback classifier so it stops masking).

## Note: the FCA MCP tool has the SAME two bugs
The bug-bounty review hit this through `mcp__fca__ask` (FloatingChatApp — a separate codebase): its Grok
default is the dead `grok-2-latest` and it has no reasoning budget. Same root cause, same fix shape. Worth
porting Layer A+B there, or routing FCA's provider calls through kist's resilient layer once it's built.
