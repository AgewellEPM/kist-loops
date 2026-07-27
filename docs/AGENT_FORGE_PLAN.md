# AgentForge — describe a role → forge a specialist → spawn it

**Status: RESEARCH + PLAN (2026-06-28). Nothing built yet. Do not auto-arm forged
agents into a live fleet without Luke's explicit say-so.**

Goal: replicate Claude Code's subagent system — *especially* the "describe what you
want in plain English and it generates the agent's identity before you use it" flow —
so kist's runtime agents can forge **purpose-built specialists** on demand instead of
dispatching faceless generic workers.

Rule this implements: `~/.claude/projects/-Users-lukekist/memory/specialist_subagents_rule.md`
— **no generic workers; every spawned subagent is a dedicated specialist with a real
identity** (name, purpose, system prompt, scoped tools).

---

## 1. How Claude Code's system works (the model we're copying)

**A subagent = a file** (`.claude/agents/<name>.md`): YAML frontmatter (identity) +
markdown body (system prompt).

- **Required**: `name` (unique id), `description` (the *auto-delegation trigger* —
  "Use proactively when…"). The description is the contract: it's how the main agent
  decides *when* to delegate.
- **Optional**: `tools` (allowlist — omit = inherit all), `disallowedTools` (denylist,
  applied first), `model` (`haiku`/`sonnet`/`opus`/`inherit`), `permissionMode`,
  `maxTurns`, `skills`, `mcpServers`, `memory` scope, `isolation: worktree`, `color`.
- **Body** = the specialist's system prompt (focused instructions, not the full CC prompt).
- **Scope/precedence**: project `.claude/agents/` > user `~/.claude/agents/` > plugin.

**The "Generate with Claude" flow** (`/agents` → Create → Generate): you type a role
description; Claude generates `name`, a delegation-driving `description`, the system
prompt, a **recommended tool allowlist** (read-only reviewer → `Read,Grep,Glob,Bash`;
debugger → adds `Edit,Bash`; analyst → `Bash,Read,Write`), and a model suggestion. You
can edit, then it saves and is immediately usable.

**Delegation**: automatic (task matches a `description`) or explicit (`@agent-<name>` /
`--agent <name>` / Task tool `subagent_type`). Each subagent runs in an **isolated
context** (fresh window; doesn't see parent history) and returns a result string.

**Anti-patterns Anthropic names** (these become our guardrails): generic descriptions
(no auto-delegation), kitchen-sink agents (split by concern), over-permissive tools
(restriction is a security + focus mechanism), nested-spawn abuse (cap depth).

---

## 2. What kist already has (the seams — file:line)

kist is ~90% wired for spawning; it's missing *identity + generation + tool scoping*.

| Need | Exists today | File |
|---|---|---|
| Spawn mechanism | `AgentSpawner` protocol (injectable), `InProcessAgentSpawner` | `FleetSpawn.swift:74` |
| Spawn orchestration | `launchFleet()`, `batonBrief()` (pure brief builder) | `CaptainOrchestrator.swift:82,185` |
| Role→provider binding | `AgentRole{planner,worker,coder,critic}`, `ProviderBinding`, `RoleBindings` | `RoleBindings.swift:8` |
| Named team presets | `RoleProfileStore` (JSON, XDG) | `RoleProfileStore.swift` |
| Closest file analog | `.kist/commands/<name>.md` loader (`$ARGUMENTS`, **no frontmatter**) | `KistCommands.swift:1` |
| Tool registry | `ToolRegistry` (immutable map), `AgentTool` protocol | `ToolRegistry.swift:9` |
| LLM seam | `ProviderRegistry.complete/stream`, `ModelSettings.systemPrompt` | `ProviderCatalog.swift:104` |
| Persistence pattern | `PlanStore`/`LessonStore` (JSON/JSONL + advisory lock) | `PlanStore.swift:12` |
| Brief/memory injection | `PromptCompiler`/`TaskBrief`, `LessonStore.primer()` | `PromptCompiler.swift:99` |

**The three real gaps:**
1. **No per-agent system prompt** — prompts are generated per-loop; there's no stored
   identity that says "you ARE the migration specialist."
2. **No per-agent tool allowlist enforcement** — every agent gets the same registry;
   scoping today is *file* scope (`scopeGlobs`/Foreman), not *tool* access.
3. **No generation** — nothing turns a NL role description into a validated identity.

---

## 3. Design

### 3.1 Data model — `SpecialistDefinition` (new, Codable, in AgentCore)
```
name            String   // unique id, lowercase-hyphen
description     String   // WHEN to use it — drives selection/delegation
systemPrompt    String   // the specialist's instructions (markdown body)
toolAllowlist   [String]?// nil = inherit the spawner's ceiling; else ⊆ ceiling
model           ProviderBinding?  // nil = inherit role default
role            AgentRole?        // optional archetype hint for routing
source          String   // "forged" | "authored" | path — provenance, never trust-bearing
```
Stored as `.kist/agents/<name>.md` (frontmatter + body) to mirror CC exactly, OR
`.kist/agents/<name>.json` — **pick markdown+frontmatter** so files are human-editable
and diff-friendly like CC. Project scope wins over user scope (`~/.config/kist/agents/`).

### 3.2 `SpecialistRegistry` (new, in Kist) — mirrors `KistCommands` loader
- `load()` scans user dir then project `.kist/agents/`, parses frontmatter+body.
- `all()`, `named(_)`, `matching(goal:)` (keyword rank, like `LessonStore.retrieve`).
- `save(_)` writes a definition (advisory lock, like `PlanStore`).

### 3.3 `AgentForge` (new, in AgentCore) — the generator (THE feature)
`forge(roleDescription:, ceiling:) async -> SpecialistDefinition`
1. Ask the PLANNER-role model (via `ProviderRegistry.complete`) to emit **JSON**:
   `{name, description, systemPrompt, toolAllowlist, model?}` — same recommend-tools
   heuristic CC uses (read-only reviewer vs editor vs analyst).
2. Parse tolerantly (strip ``` fences, retry-on-malformed — like `FleetPlanner` parser).
3. **VALIDATE (trust spine, see §4)** then register via `SpecialistRegistry.save`.

### 3.4 Selection / spawn wiring
- Planner/Foreman: before spawning a step, `registry.matching(goal:)` → reuse if a
  specialist fits; else `AgentForge.forge(...)` a new one (reuse-before-mint).
- `batonBrief()` gains an optional `specialist:` → its `systemPrompt` becomes the lead
  section + `ModelSettings.systemPrompt`; `toolAllowlist` scopes the registry.

### 3.5 Per-agent tool scoping (new enforcement)
Add an allowlist gate in `ToolRegistry.execute()` (or a `scoped(to:)` view): if a
definition has `toolAllowlist`, calls to tools outside it return a hard `ToolResult`
error — **fail-closed**, like plan-mode's read-only gate.

---

## 4. Trust spine (non-negotiable — an LLM is writing another agent's permissions)

This is the dangerous part and the reason to build it carefully:

1. **No privilege escalation.** A forged `toolAllowlist` can only **narrow** the
   spawner's ceiling, never grant a tool the creator lacks. Enforce set-intersection
   with the ceiling at validation AND at execution (belt + suspenders).
2. **Tool names must resolve.** Reject/drop any tool name not in the live registry
   (a hallucinated tool must never silently widen or crash).
3. **`source` is provenance, never authority.** "forged" is a label; it confers no
   trust. Same rule as `LessonStore` (`proven` w/o source → coerced) and the signoff
   ledger (seal-or-drop).
4. **No self-spawn loop.** A forged specialist cannot forge/spawn (or cap depth ≤ N),
   mirroring CC's nested-spawn cap. Default: specialists get **no** Agent/forge tool.
5. **systemPrompt is data, not commands to the runtime.** Injected as advisory brief
   text ("untrusted content" discipline already exists — `UntrustedContentScanner`).
6. **Validation is pure + unit-pinned.** Every invariant above gets a per-invariant
   test (escalation attempt, hallucinated tool, sourceless trust, depth) — multi-site
   discipline: assert on each, not just "it works."

---

## 5. Phases (each: build → test → adversarial Codex → ff-merge; nothing auto-armed)

- **P1 — Identity + registry (no generation).** `SpecialistDefinition`, frontmatter
  parser (extend `KistCommands` pattern), `SpecialistRegistry` load/save, `/agents`
  REPL command (list/show/new-from-file). Authored agents only. *Lowest risk; unlocks
  the file format + selection.*
- **P2 — Tool scoping.** Per-agent allowlist enforcement in `ToolRegistry` (fail-closed
  intersection with ceiling) + tests for escalation/hallucinated-tool. *Security gate
  before any generation exists.*
- **P3 — AgentForge generation.** NL description → validated `SpecialistDefinition`
  (the trust spine §4). `/agents new "<description>"` forges + registers. *The headline
  feature, gated behind P2's enforcement.*
- **P4 — Runtime selection.** Planner/Foreman reuse-or-forge per step; `batonBrief`
  injects the specialist prompt + scopes tools. Behind a flag (off), like `leaseRequired`.
- **P5 — Polish.** Embedding/keyword match quality, `description`-driven auto-delegation
  in the conversational router, memory scope per specialist.

**Recommended start: P1** (file format + registry is the foundation everything else
needs, zero trust risk) — then P2 *before* P3 so generation can never outrun enforcement.
