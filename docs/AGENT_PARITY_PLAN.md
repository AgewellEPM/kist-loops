# kist Subagent System — Exact Claude-Code Parity: 4-Model Panel + Plan

**Status: PLANNING DOC (not code).** 2026-07-01. Goal: make kist's custom-agent creation work
**exactly like Claude Code's subagent system.** Analysis by a 4-model panel — **Claude (me),
DeepSeek-reasoner, Gemini-2.5-pro, GPT-5** — cross-referenced against Claude Code's live docs
(`code.claude.com/docs/en/sub-agents`) and kist's `SpecialistDefinition`. *(MiMo was on the panel
list but its API key is unset this session — 4 of 5 voices.)*

---

## 0. The key insight (why this is cheaper than it looks)

kist is **not missing the capabilities** Claude's subagents expose — it's missing the **frontmatter
schema that wires an agent file to them.** kist already ships:

| Claude subagent feature | kist already has |
|---|---|
| tool scoping (`tools`) | `SpecialistDefinition.toolAllowlist` (nil=inherit, []=fail-closed) |
| per-agent model | `model: ProviderBinding` |
| NL → agent ("Generate with Claude") | **AgentForge** (`/agent new <desc>`) |
| auto-delegation by `description` | **TaskPersonaMatcher** |
| `isolation: worktree` | **fleet** GitWorktree / GitIsolation |
| `color` | **Theme** (just shipped) |
| `mcpServers` | **MCP client** (`Sources/AgentCore/MCP/`) |
| `skills` (preload) | `.kist/skills` |
| `memory` | `.kist/memory` + `ProjectMemory` |
| `permissionMode` | Shift+Tab permission bar (normal/accept-edits/plan/bypass) |
| `maxTurns` | loop `--max-iterations` cap |
| `hooks` | `.kist/hooks.json` |

So parity ≈ **(a) extend the frontmatter schema, (b) read `.claude/agents/`, (c) wire each field to
the subsystem that already exists.** Not a new engine — a schema + adapters.

---

## 1. Panel consensus (unanimous unless noted)

**Q1 — Read `.claude/agents/*.md` directly?** **YES, unanimous.** Drop-in compatibility with
existing Claude agents/dotfiles is the biggest ecosystem win; a converter creates a permanent
schism. Keep `.kist/agents/` as the native/override format. **Precedence (merged from GPT + Gemini):**
`managed > --agents CLI > .kist project > .claude project > .kist user > .claude user > plugin`.
Add an optional `import-claude` to normalize into `.kist` for users who want it.

**Q2 — Which of the 12 missing fields?** Merged priority:
- **P0 (all agree):** `tools`, `disallowedTools`, `model`(+`inherit`), `permissionMode`, `maxTurns`.
- **P1:** `memory` (Gemini P0), `isolation` (cheap — fleet already does it), `initialPrompt`,
  `color` (cheap — Theme exists), `skills` (DeepSeek P0), `mcpServers` (GPT P1 — kist HAS an MCP client).
- **Skip / defer:** `background` (cloud-UX; low value in a terminal), `effort` (largely subsumed by
  BYOK model choice; kist has `/think`), `hooks` per-agent (kist has global hooks.json — defer the
  per-agent scope).

**Q3 — `model` for BYOK?** **Support all three, unanimous.** Resolution order:
`explicit provider:model  >  alias table (sonnet/opus/haiku → provider:model, user-configurable)  >
inherit (session/role model)  >  kist default`. Validate availability at load; warn + deterministic
fallback. kist's `ProviderBinding` stays authoritative; aliases are a compat convenience.

**Q4 — Unify `/roles` and subagents?** **KEEP SEPARATE, unanimous.** `/roles` = *process* (which
provider fills planner/coder/critic pipeline slots); subagents = *capability* (a named prompt + tools
+ perms + optional model). Conflating them muddles two orthogonal axes. **Bridge, don't merge:**
allow `model: inherit` to resolve to the active role's model, and let a role delegate to a specialist.

**Q5 — Single highest-leverage move?** Split 2–2, and they're the two halves of one thing:
- DeepSeek + GPT: **description-driven auto-delegation** with isolated per-agent context (the matcher
  routes tasks by `description`; explicit `use <agent>` too). *Without this, agents are just named prompts.*
- Gemini: **the `/agents` TUI** with AgentForge ("Generate with Claude") built in.
- **My call (Claude):** ship **both**, auto-delegation FIRST — it's the behavior that makes the
  system feel alive; the TUI is discoverability on top.

---

## 2. Field-by-field parity map

| Claude field | Required | kist status | Plan |
|---|---|---|---|
| `name` | ✅ | HAVE | — |
| `description` | ✅ | HAVE (drives matcher) | strengthen auto-delegation (Phase 2) |
| system prompt (body) | — | HAVE | — |
| `tools` | — | HAVE (`toolAllowlist`) | — |
| `disallowedTools` | — | **MISSING** | **P0** add denylist; subtract from ceiling, fail-closed |
| `model` | — | HAVE (provider:model) | **P0** add alias table + `inherit` |
| `permissionMode` | — | MISSING (bar exists) | **P0** map to the permission-bar tiers |
| `maxTurns` | — | MISSING (loop caps exist) | **P0** wire to loop iteration cap |
| `skills` | — | subsystem exists | **P1** preload named skills into context |
| `mcpServers` | — | client exists | **P1** scope MCP servers per agent |
| `memory` | — | subsystem exists | **P1** map user/project/local to kist stores |
| `isolation` | — | fleet does it | **P1** `worktree` → GitWorktree (cheap) |
| `color` | — | Theme exists | **P1** map to Theme roles (cheap) |
| `initialPrompt` | — | MISSING | **P1** seed first user turn |
| `hooks` | — | global hooks.json | **P2** per-agent hook scope |
| `background` | — | fleet is bg | **SKIP** (low value in terminal) |
| `effort` | — | `/think` | **SKIP/defer** (subsumed by model choice) |

---

## 3. Recommended phased plan

### Phase 0 — schema + `.claude/agents/` drop-in compat  ← START HERE
- Extend `SpecialistDefinition` with the P0 fields: `disallowedTools`, `permissionMode`, `maxTurns`,
  and `model` alias/`inherit` resolution. Keep the hardened parse (injection guards, ASCII name).
- Add a **tolerant YAML-frontmatter reader** (the 5–6 scalar/list fields we care about — not a full
  YAML lib; a small line lexer + list handling). Reject unknown-but-dangerous, ignore unknown-benign.
- **Load `.claude/agents/*.md` and `~/.claude/agents/`** alongside `.kist/agents/`, with the merged
  precedence chain. Add `~/.kist/agents/` (user scope) too.
- Tests: round-trip both formats; a real Claude agent file loads and runs; precedence resolves.

### Phase 1 — wire P0 fields to existing subsystems
- `tools`/`disallowedTools` → tool ceiling intersection (enforcement in the tool layer, fail-closed).
- `permissionMode` → the Shift+Tab permission-bar tiers (map default/acceptEdits/plan/bypass…).
- `maxTurns` → the loop iteration cap for that agent's run.
- `model` alias table (`sonnet/opus/haiku → provider:model`) + `inherit` (→ active role model).

### Phase 2 — description-driven auto-delegation (the "feels like Claude" behavior)
- Upgrade `TaskPersonaMatcher` to route by `description` with a confidence gate; explicit
  `use <agent> …` / `@agent` path; each delegated agent runs in its own context and returns a summary.

### Phase 3 — the `/agents` TUI (discoverability)
- Library/Running tabs; list (built-in + project + user), inspect, edit, delete, and **create via
  AgentForge** ("Generate with kist" = NL → validated agent), mirroring Claude's `/agents` flow.

### Phase 4 (P1 tail) — `isolation: worktree` (fleet), `color` (Theme), `memory`, `skills`,
`mcpServers` per-agent, `initialPrompt`. Each maps to an existing subsystem; land opportunistically.

### Keep separate: `/roles` (team) stays; bridge via `model: inherit` → active role model.

---

## 4. The model-resolution spec (concrete)

```
resolve(model field, activeRole) →
  1. "provider:model"           → ProviderBinding.parse(...)          (authoritative, BYOK)
  2. alias in {sonnet,opus,haiku,fable}
                                → aliasTable[alias]  (user-configurable in .kist/settings.json)
  3. "inherit" or absent        → activeRole's binding (roleSelection.fallback)
  4. unresolved                 → kist default + a visible warning (fail-soft, deterministic)
```
Aliases default to the user's Anthropic binding if present, else their configured equivalent — never
silently swap providers without disclosure (kist's standing no-silent-substitution rule).

---

## 5. Open questions for Luke
1. **`.claude/agents/` read** — read-only compat (recommended) or also *write* kist agents back into
   `.claude/agents/` so they're shared with a real Claude Code install?
2. **Auto-delegation aggressiveness** — proactive (Claude-style: delegates whenever `description`
   matches) or conservative (only on explicit `use <agent>`)? Claude-exact = proactive.
3. **Phase 0 scope** — ship `.claude/agents/` compat + the 3 P0 schema fields first (recommended), or
   the whole schema + wiring in one push?
