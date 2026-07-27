# Mythos Heterogeneous Edge — the "outpace Anthropic" feature lot

The thesis, the proof, and the ranked backlog for the one thing Anthropic structurally cannot follow us
into: **using every model on earth — including broken-API and Chinese frontier models — as cheap,
trustworthy teammates in one loop.** This doc is a LIVING backlog; per-model recommendations from live
tests get appended at the bottom as we pull them.

## The thesis (why this beats single-vendor)

1. **The text-protocol is the moat — MiMo proved it.** Claude Code is welded to Claude's native tool
   format. A provider whose tools API is *broken* (MiMo: round 1 works, round 2 returns `400 Param
   Incorrect`, XiaomiMiMo/MiMo#44) is simply unusable to it. Mythos made a 1-trillion-param model fully
   agentic *despite* its broken API — by construction (capability degradation → universal text protocol
   exposing the SAME tools). **We can field models the entire Anthropic stack can't touch.** Not a
   feature — a different category.

2. **Cost arbitrage Anthropic can't match (single-vendor by design).** MiMo ≈ 1T MoE, ~1M context, tuned
   for "1,000+ tool calls/session", at Chinese pricing (10–50× cheaper than Claude). The killer config:
   `kist --fleet "<big build>" --coder mimo --worker deepseek --critic gemini` — a swarm of cheap Chinese
   workers doing the labor, a frontier critic gating quality, all behind the forge-proof signoff.
   **Frontier-quality output at a fraction of Claude-only cost.** Anthropic only has Claude.

3. **The trust spine makes cheap models SAFE.** A cheap/uneven worker is fine when nothing it claims is
   trusted without a deterministic, forge-proof signoff (the Foreman + sealed ledger). So "use the cheap
   model" stops being a quality risk — the gate catches a bad green. Heterogeneity without the trust spine
   is reckless; with it, it's an edge.

## The proof (live, this session)

- **MiMo (Xiaomi) live, multi-round, via text protocol:** asked to find a file then read it then answer,
  MiMo ran `glob_files` (missed) → **self-recovered** → `list_files` → `read_file` → correct answer. Three
  tool rounds + a recovery — exactly the flow that `400`s natively. Reliable, agentic, no break.

## Ranked feature backlog (ship order)

| # | Feature | Why | Size |
|---|---|---|---|
| 1 | **`thinking`/reasoning OFF in tool-mode** for reasoning models (MiMo, DeepSeek-Reasoner, GLM, …) | Reasoning tokens are pure cost/latency tax during agentic tool loops; disable when the turn is a tool call. Per-provider body flag (`"thinking":{"type":"disabled"}` for MiMo; `reasoning_effort` low for others). | S |
| 2 | **1M-context "whole-repo worker" role** | MiMo/Qwen-Long as the worker where Claude's window forces chunking — feed the whole repo, no RAG. A real edge on large codebases. | M |
| 3 | **Endurance validation — the "1,000+ tool calls" claim** | Our text protocol removes MiMo's round-2 ceiling, so MiMo can finally *use* that capacity. A long agentic run proving it = a headline. | S |
| 4 | **Cost-per-verified-success benchmark** (MiMo/DeepSeek team vs Claude) | Same task, measured in **dollars per signed-off result** (sealed-ledger verdicts, not a public bench). THE Reddit-launch weapon — proves "outpace Anthropic" with a number. | M |
| 5 | **Per-model capability registry from live tests** | Don't assume; MEASURE each provider's native-tools / parallel-calls / streaming behaviour with a real probe, and pin the result (like the MiMo `nativeToolsSupported:false` fix). Self-healing "uses all AIs". | M |
| 6 | **Auto cost-routing inside roles** | RouteLLM-style: a trivial subtask downshifts the coder to the cheapest capable Chinese model, escalates to frontier only when hard. Turns the static role→vendor map into a cost-optimized one. | M |

## Honest caveats (label discipline)

- Text protocol trades native-tool efficiency for universality — slightly more tokens/round. Worth it for
  breadth; measure it (feature #4).
- "Cheap model" ≠ "as smart as Claude on hard reasoning." The win is **breadth + cost + trust**, not
  head-to-head IQ. The benchmark settles per-task quality honestly.

---

## Per-model live findings (appended as we pull them)

### MiMo (Xiaomi) — `nativeToolsSupported: false` → text protocol
- **Native tools BROKEN for multi-turn** (round-2 `400`, MiMo#44). Routed to text → live-proven 3-round
  agentic loop + self-recovery. **Rec:** disable `thinking` in tool-mode (#1); use as the cheap 1M-context
  worker (#2); validate endurance (#3). Tool sequence: glob (miss) → list_files → read → correct answer.

### DeepSeek — native tool-calling, works multi-turn
- Same task, **native** path (no `400` — DeepSeek's tools API is solid multi-turn). Reached the correct
  answer. Slightly MORE redundant calls than MiMo (glob → search → glob again → list → read) — a touch of
  thrash before falling back. **Rec:** native is good; the redundant glob/search is downstream of the glob
  bug below, not the model. Good cheap WORKER/coder candidate alongside MiMo.

### 🐞 CROSS-MODEL TOOL BUG (found by BOTH MiMo + DeepSeek) — HIGH, ship soon
- `glob_files` with pattern `**/test.sh` returns NOTHING for a **root-level** `test.sh`. Both models tried
  the idiomatic `**/<file>` and got an empty result, forcing a `list_files` fallback (extra round, extra
  cost). Standard glob semantics: `**/` must match **zero or more** directories, so `**/test.sh` SHOULD
  match `./test.sh`. **Fix `glob_files` so `**` matches zero path segments** (and add a regression test:
  `**/x` matches a root `x`). This makes EVERY model's first tool call land — a real agentic-efficiency win
  across the whole fleet, not just one model.
  → Added to the ranked backlog as **#0 (do first — cheap, helps all models).**
