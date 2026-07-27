# kist ↔ Claude Code — Feature & Settings Parity Map + Forward Plan

**Status: PLANNING DOC (not code).** Snapshot date 2026‑07‑01. Sources: Claude Code live
docs (`code.claude.com/docs` — commands, settings), kist repo `main` @ `815525a`.

kist is a **BYOK, provider‑agnostic, open‑source terminal agent**. Claude Code is Anthropic's
first‑party CLI wired to Anthropic accounts + cloud. So parity is **not** "clone every command."
A large slice of Claude Code's surface is account/plan/cloud‑tied and *irrelevant by design* for
kist. This doc separates **(A) local dev‑loop primitives kist should match**, **(B) what kist
already has**, **(C) cloud/account features to deliberately skip**, and **(D) where kist already
beats Claude Code** — then a prioritized build plan.

---

## 0. TL;DR

- kist is **strong on orchestration** (fleet, council, roles/team, plan‑execute, DGM/evolve,
  agentforge, bench/eval, pentest) — several of these Claude Code has **no equivalent** for.
- kist's **gaps are all in the "session ergonomics" layer**: context management (`/compact`,
  `/context`), time‑travel (`/rewind` checkpoints), a real **settings/config panel** (`/config`),
  and the **inspector commands** for the config it *already stores on disk* (`/hooks`,
  `/permissions`, `/skills`, `/mcp`, `/memory`, `/theme`, `/output-style`).
- The single highest‑leverage insight: **kist already persists most of this config in `.kist/`
  (hooks.json, providers.json, model‑profiles.json, agents/, skills/, commands/, memory) but has
  almost no `/` commands to VIEW or EDIT it in‑session.** The panel is the missing 20%.

---

## A. Local dev‑loop primitives — PARITY TARGETS (build these)

| Claude Code | What it does | kist today | Gap / action |
|---|---|---|---|
| `/compact [focus]` | Summarize convo to free context, keep working | `ContextBrain` exists; **no user command** | **BUILD** `/compact` — surface the summarizer as a command + auto‑compact near limit |
| `/context [all]` | Visualize context‑window usage (grid, what's eating tokens) | `/usage` shows tokens/cost, not window breakdown | **BUILD** `/context` — per‑source token map (system, memory, transcript, tools) |
| `/rewind` (`/undo`,`/checkpoint`) | Roll conversation **and/or code** back to a prior point | `AgentCheckpoint`/checkpoint store exists; **no rewind UX** | **BUILD** `/rewind` — file + convo checkpoints; you already snapshot, expose restore |
| `/config [k=v]` (`/settings`) | Settings UI + direct `key=value` set | Scattered flags; `.kist/*.json` on disk; **no panel** | **BUILD** `/config` — one panel over the config kist already writes |
| `/permissions` (`/allowed-tools`) | View/edit allow/ask/deny rules by scope | Shift+Tab permission **bar** (mode cycle); no **rule editor** | **BUILD** `/permissions` — list + edit persisted allow/deny tool rules |
| `/hooks` | View hook configs for tool events | `.kist/hooks.json` is read; **no viewer** | **BUILD** `/hooks` — list configured hooks + fire status |
| `/memory` | Edit CLAUDE.md / auto‑memory in‑session | `/cortex remember`, `.kist/memory`; no editor | **BUILD** `/memory` — open + edit project/user memory |
| `/skills` | List skills, token cost, hide/show | `.kist/skills` loaded; no list command | **BUILD** `/skills` — list + per‑skill token cost + enable/disable |
| `/reload-skills` / `/reload-plugins` | Re‑scan skill/command dirs live | none | **BUILD** `/reload` — re‑scan `.kist/{skills,commands,agents}` |
| `/mcp` | Manage MCP servers (list/reconnect/enable) | MCP client exists (`MCP/`); no mgmt command | **BUILD** `/mcp` — list servers, reconnect, enable/disable |
| `/diff` | Interactive uncommitted + per‑turn diff viewer | `/logs` proof drawer; copilot reads diff | **BUILD** `/diff` — per‑turn diff browser (you already capture turn diffs) |
| `/export` / `/copy` | Export convo / copy last response | `/save-chat` (markdown export) ✓; no `/copy` | **PARTIAL** — add `/copy [N]` (clipboard last response / code block) |
| `/theme` | Color theme incl. accessible/daltonized, ANSI | none (hardcoded ANSI) | **BUILD** `/theme` — **matters for Luke's a11y bar** (colorblind themes) |
| `/output-style` | Adjust system‑prompt output style | none | **BUILD** `/output-style` — concise/explanatory/custom personas already exist via `/persona`; unify |
| `/effort [level]` | low→ultracode reasoning effort | `/think on/off` (binary) | **UPGRADE** `/think` → graded effort levels per provider |
| `/branch` / `/fork` | Branch or fork the conversation to try a direction | none (fleet forks agents, not convo) | **BUILD** `/branch` — cheap convo checkpoint fork |
| `/background` (`/bg`) | Detach session as background agent | fleet is bg; whole‑session detach absent | **CONSIDER** — lower priority (fleet covers the parallel case) |
| `/rename` | Name the session (shown on prompt bar) | none | **BUILD** (trivial) — session names for `/replay` picker |
| `/keybindings` / `editorMode: vim` | Vim editing in the prompt | LineEditor (emacs‑ish); no vim mode | **CONSIDER** `/config editor=vim` |

---

## B. Already at (near‑)parity — kist HAS these

| Claude Code | kist equivalent |
|---|---|
| `/help` | `/help` ✓ |
| `/model` (picker + arrows) | `/model` arrow‑key picker ✓ (just shipped) |
| `/clear` (`/reset`,`/new`) | `/clear` ✓ |
| `/plan` (plan mode) | `/plan [on\|off]` ✓ |
| `/init` | `--onboard` / `--onboard-doc` ✓ (make it a `/init` too) |
| `/doctor` | `/doctor` + `/health` + `/probe` ✓ (kist arguably deeper) |
| `/usage` (`/cost`,`/stats`) | `/usage` rich session+week panel ✓ |
| `/resume` (`/continue`) | `--resume` / `--resume-last` / `/replay` ✓ |
| `/review`, `/security-review`, `/code-review` | `/review` board step + `/copilot` co‑review + `bug-bounty` + **pentest tool** ✓ |
| `/agents` (subagent mgr) | `/agents` + `/agent new` (AgentForge NL→specialist) ✓ |
| `/tasks` (`/bashes`) | `/tasks` shared board + `/fleet-status` cockpit ✓ |
| `/loop` (scheduled/self‑paced) | evolve autopilot / `--arm-hours` ✓ (different shape) |
| `/deep-research` (workflow) | `/research` evidence dossier + council ✓ |
| `/batch` (parallel worktrees) | `/fleet` supervised disjoint‑lease fleet ✓ (kist deeper: signoff/merge‑gate) |
| custom commands `.claude/commands/` | `.kist/commands` + `/commands` ✓ |
| skills (`SKILL.md`, progressive disclosure) | `.kist/skills` (agentskills.io standard) ✓ |
| hooks (lifecycle events) | `.kist/hooks.json` ✓ (needs `/hooks` viewer — see A) |
| MCP servers | MCP client (`MCP/`), `/protocols` ✓ (needs `/mcp` mgr — see A) |
| CLAUDE.md memory | `.kist/memory` + ProjectMemory + cortex ✓ |
| permission modes (ask/auto/all) | Shift+Tab bar: normal→accept‑edits→plan→bypass ✓ |
| sandboxing (`/sandbox`) | `--sandbox` + Seatbelt `.confined` tiers ✓ |

---

## C. Cloud / account / Anthropic‑tied — DELIBERATELY SKIP

Not relevant to a BYOK OSS tool. Listed so the gap map is honest, not aspirational.

`/login` `/logout` `/upgrade` `/usage-credits` `/passes` `/stickers` `/radio` `/mobile`
`/desktop` `/teleport` `/remote-control` `/remote-env` `/web-setup` `/autofix-pr`
`/install-github-app` `/install-slack-app` `/setup-bedrock` `/setup-vertex` `/design-sync`
`/design-login` `/chrome` `/voice` `/schedule` (cloud routines) `/ultraplan` `/ultrareview`
`/advisor` (server tool) `/privacy-settings` `/feedback` `/insights` `/team-onboarding`
`/powerup` `/heapdump` `/passes`.

Plus most enterprise settings keys: `forceLoginMethod`, `awsCredentialExport`, `gcpAuthRefresh`,
`policyHelper`, `companyAnnouncements`, `strictKnownMarketplaces`, `minimumVersion`, Bedrock/Vertex
model overrides, telemetry/OTEL — **skip unless kist ever targets orgs.**

*Note:* a few of these have a **BYOK re‑interpretation worth stealing the shape of** — e.g.
`/schedule` → local cron for `--evolve`/`--fleet`; `apiKeyHelper` → dynamic key command instead of
static paste. Filed under P2.

---

## D. Where kist ALREADY BEATS Claude Code (protect + market these)

- **Provider‑agnostic team routing** — `/roles` assign planner/coder/critic to *different
  providers/models* (Claude Code is single‑model per turn). Save/load named AI teams.
- **`/council`** — multi‑mind (researcher/architect/coder/critic/UX/memory) deliberation → kanban.
  No Claude Code equivalent.
- **`/fleet` merge gate** — disjoint‑lease agents with **forge‑proof signoff + committed‑diff
  measurement + integration‑branch join that refuses off‑lease work.** Claude Code `/batch` opens
  PRs; kist enforces scope + provenance. Deeper safety story.
- **`--evolve` (DGM / Darwin‑Gödel)** — self‑improvement loop over an archive with sandboxed
  candidates. Nothing like it in Claude Code.
- **`/bench` + `/eval`** — provider bake‑off + deterministic agent‑behavior eval. Claude Code has
  no built‑in provider comparison (it's single‑vendor).
- **AgentForge** — NL role description → validated spawnable specialist, in‑session.
- **Pentest tool** (gated, authorized‑targets) + **A2A** agent cards — niche but unique.
- **Fleet observability** — live `.fleet-progress.jsonl`, claim reconciliation vs committed
  artifacts, cross‑fleet lesson memory. Anti‑hallucination spine.

**Positioning:** kist = "**multi‑model agent orchestration** with a safety‑gated fleet," not "a
Claude Code clone." Parity work is about *ergonomics*, not *capability*.

---

## E. FORWARD PLAN — prioritized

Guiding rule: **surface the config kist already persists** before inventing new subsystems. Most of
P0 is UI over existing `.kist/` state, so it's cheap and high‑impact.

### P0 — the Settings/Inspector Panel (the "our / entries panel" Luke asked for)
One coherent `/config` surface + the read‑only inspectors over on‑disk state. Low risk, mostly
rendering. Each is its own small file (respect modularity).
1. **`/config`** — interactive settings panel + `/config key=value` direct‑set (mirror Claude Code).
   Backed by a new `.kist/settings.json` with a typed schema. Migrate scattered flags into it.
2. **`/context`** — context‑window breakdown (system / memory / transcript / tool output / skills).
3. **`/compact [focus]`** — expose `ContextBrain` summarizer as a command + auto‑compact threshold.
4. **`/permissions`** — view/edit persisted allow/ask/deny tool rules (complements the Shift+Tab bar).
5. **`/hooks`, `/mcp`, `/skills`, `/memory`** — inspector/editor commands over existing `.kist/`
   config (hooks.json, MCP servers, skills dir, memory).

### P1 — session time‑travel & ergonomics
6. **`/rewind`** — restore conversation and/or files to a checkpoint (checkpoint store exists).
7. **`/diff`** — per‑turn + working‑tree diff browser (turn diffs already captured).
8. **`/theme`** — themes incl. **colorblind/daltonized + high‑contrast** (Luke's a11y bar makes this
   more than cosmetic) + `/config theme=`.
9. **`/effort`** — graded reasoning effort per provider (upgrade binary `/think`).
10. **`/copy [N]`, `/rename`, `/reload`** — small quality‑of‑life wins.

### P2 — deeper / optional
11. **`/output-style`** — unify with `/persona` into a named output‑style system.
12. **`/branch` / `/fork`** convo — cheap divergent exploration (distinct from fleet agent forks).
13. **BYOK re‑interpretations** — local `/schedule` (cron for evolve/fleet), `apiKeyHelper`‑style
    dynamic key command, vim editor mode via `/config`.
14. **`/init` alias** for `--onboard`; **`/doctor` fix‑it** action (press‑to‑fix like Claude Code).

### Explicitly NOT doing (unless scope changes)
All of section C. Don't build cloud/account/enterprise‑tied surfaces for a BYOK tool.

---

## F. Suggested `/config` schema (starting point)

Mirror the *useful* subset of Claude Code's `settings.json`, BYOK‑adapted, stored at
`.kist/settings.json` (project) + `~/.kist/settings.json` (user), project‑over‑user precedence:

```jsonc
{
  "model": "gemini:gemini-3.1-pro",        // default binding (⟶ /model)
  "roles": { "coder": "deepseek", "critic": "gemini" }, // ⟶ /roles
  "effort": "high",                         // ⟶ /think / /effort
  "reasoning": false,                        // show provider reasoning
  "permissions": { "allow": [], "ask": [], "deny": [] }, // ⟶ /permissions
  "sandbox": "confined",                     // off | confined | strict
  "copilot": { "enabled": false, "co": null },
  "autoCompact": true,
  "theme": "auto",                           // auto | dark | light | daltonized | high-contrast
  "editor": "emacs",                          // emacs | vim
  "hooks": {},                                 // ⟶ .kist/hooks.json (or inline)
  "includeCoAuthored": true
}
```

---

## G. Open questions for Luke
1. **Config precedence** — mirror Claude Code's managed→CLI→local→project→user chain, or keep it
   simpler (project→user) for now?
2. **`/theme` priority** — given the a11y mandate, promote colorblind/high‑contrast themes to P0?
3. **Scope of P0** — ship the whole panel as one feature, or land `/config` + `/context` +
   `/compact` first (the three highest‑value) and fan the inspectors out after?
