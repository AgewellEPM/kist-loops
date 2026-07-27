# kist Tool Family — Gap Analysis + Plan (2026-06-28)

Research across Claude Code, OpenAI Codex CLI (codex-rs), Gemini CLI, the MCP ecosystem, the OSS
agents (OpenCode/Crush/Cline/Goose/Aider), and the Mac/Linux cross-platform reality — cross-referenced
with kist's actual 24-tool inventory. Bottom line:

> **kist's tool family is solid on file/shell/web/media with best-in-class confinement, but it's behind
> on the 2026 table-stakes in four concrete places: (1) ripgrep-grade search, (2) a real patch/multi-edit
> tool, (3) vision (see images/PDFs), and (4) modern MCP (HTTP transport + remote servers). The deeper
> differentiators the field has and we lack: LSP code-intelligence, a repo-map, and the Linux half of the
> sandbox.** None are exotic — they're known integrations. We keep our unique moat (trust spine, no-fab,
> security/governance tools) and bolt on parity.

---

## 1. The 2026 table-stakes tool set (what every serious agent has)

| Capability | Claude Code | Codex CLI | Gemini CLI | kist today |
|---|---|---|---|---|
| Read (text **+ images/PDF**) | Read | shell+`view_image` | `read_file` (img/audio/pdf) | text only ❌ |
| Write | Write | `apply_patch` | `write_file` | write_file ✅ |
| Edit (single) | Edit | `apply_patch` | `replace` (`allow_multiple`) | edit_file ✅ |
| **Multi-file / patch** | **MultiEdit** | **`apply_patch` (V4A grammar)** | (via replace) | ❌ **none** |
| **Grep (ripgrep, output modes)** | **Grep (rg)** | shell `rg` | **`grep_search` (rg variant)** | hand-rolled NSRegex ❌ |
| Glob | Glob | shell | `glob` | glob_files ✅ |
| Shell (sandboxed) | Bash | `shell`/`exec_command` (PTY) | `run_shell_command` (bg) | run_command ✅ |
| **Background / PTY exec** | Bash bg | **`exec_command`+`write_stdin`** | `is_background` | one-shot ❌ |
| Web fetch / search | WebFetch/WebSearch | hosted `web_search` | `web_fetch`/`google_web_search` | fetch_url/web_search ✅ |
| **Vision (view image)** | Read images | **`view_image`** | read_file images | ❌ media is A/V only |
| **Structured todo (≤1 in_progress)** | TodoWrite/TaskCreate | **`update_plan`** | `write_todos` | `tasks` (close, not model-live) 🟡 |
| Subagents | Task | spawn_agent | `@agent` subagents | spawn_agent ✅ |
| Ask user | AskUserQuestion | `request_user_input` | `ask_user` | ask_user ✅ |
| **MCP transports** | stdio+HTTP | stdio+HTTP | stdio+SSE+**HTTP** | **stdio only** ❌ |
| MCP resources/prompts | yes | yes | yes (`list/read_mcp_resource`) | ❌ tools only |
| **Sandbox Mac + Linux** | (perms) | **Seatbelt + Landlock/seccomp** | Seatbelt + Docker/gVisor | **Mac only** ❌ |
| LSP code-intel | (via MCP) | — | — | ❌ |
| Repo-map (tree-sitter) | — | — | — | ❌ |

**What kist has that they mostly don't (keep these):** the trust spine (no-fabrication, committed-diff
measurement, ForgeSeal signoff, council/captain promotion gate), `security_audit` + `governance_report`
(OWASP Agentic), DuckDB `query_data`, deep A/V `analyze_media`. That's the moat — don't dilute it.

---

## 2. The gaps, ranked by "must-fix to keep up"

### 🔴 HIGH — table-stakes we're visibly behind on
1. **Ripgrep grep.** `search_code` is a hand-rolled `NSRegularExpression` line-by-line walk — no multiline,
   no output modes (files/content/count), no context lines (-A/-B/-C), no type filters. Everyone else
   bundles `rg`. This is the single most-used tool and ours is the weakest link. (Watch the ENOEXEC trap:
   Mach-O vs ELF `rg` are not interchangeable — pick the arch-correct binary or use PATH `rg`.)
2. **`apply_patch` / multi-edit.** We only have single-substring `edit_file` + whole-file `write_file`.
   Codex's *entire* edit model is `apply_patch` (V4A `*** Begin Patch` grammar, multi-file, rename, fuzzy
   no-line-number matching); it's the de-facto standard models are trained on. No atomic multi-file edit,
   **no diff preview before write**. Aider's whole reliability edge is edit-format quality.
3. **Vision — `view_image` + image/PDF read.** Agents increasingly must *see* screenshots, mockups, PDFs.
   Our media tools are A/V-only (Gemini-backed); `read_file` is text-only. Codex `view_image`, Gemini/Claude
   read images+PDF natively.
4. **Modern MCP: Streamable HTTP + remote servers.** Our client is **stdio-only**. The ecosystem moved to
   Streamable HTTP (current transport) and 25+ **remote OAuth** servers (Linear, Atlassian, Sentry, Stripe,
   Vercel, Neon…). Stdio-only locks us out of the fastest-growing MCP segment entirely.

### 🟡 MEDIUM — real gaps, slightly less urgent
5. **Structured live todo.** `tasks` exists but isn't surfaced as the model-driven live checklist with the
   ≤1-in_progress invariant (TodoWrite / `update_plan` / `write_todos`). Small lift to match.
6. **MCP resources + prompts.** We do tools only; the spec's resources (context-by-URI) and prompts
   (slash-commands) are unused.
7. **Lazy tool-loading / tool-search.** Our new ToolContract injects ALL tool defs. With many MCP servers
   that's the documented 55K–134K-token context bomb. Anthropic's Tool Search + Codex `tool_search` defer
   loading (~85% reduction). We'll need a deferred/hot-set model once servers multiply.
8. **Linux sandbox.** Seatbelt (Mac) only; Linux returns `.unavailable` (so `--auto` shell fails-closed on
   Linux). Codex ships Landlock + seccomp (+ bwrap fallback). This is the Linux half of our own sandbox.
9. **Background / PTY exec.** `run_command` is one-shot — can't run a dev server / REPL / watcher and
   interact (Codex `exec_command`+`write_stdin`).

### 🟢 DEPTH — the differentiators the field's leaders have and we lack
10. **LSP code-intelligence.** Research's #1 "biggest gap a green-field runtime ships without." OpenCode +
    Crush wire real language servers (go-to-def, find-refs, diagnostics, symbols) → structural refactors
    instead of grep-and-pray. Protocol is easy; per-language server lifecycle + file-sync is the work.
11. **Repo-map (tree-sitter).** Aider's ranked symbol skeleton injected up front — lets a model reason about
    a repo bigger than its window. Distinct from LSP (static vs live).

### Lower: web_fetch POST/auth; cross-platform image (libvips, don't lean on macOS `sips`); file-watch
(FSEvents/inotify); git tool family (shell covers it today).

---

## 3. The plan — 4 waves

Each item: own file(s), built→tested→Codex→ff-merge, like everything else. Wave 1 is the highest
impact-per-effort and closes the visible parity gap.

### WAVE 1 — table-stakes parity (do first; ~biggest bang)
- **W1.1 Ripgrep `search_code`.** Shell out to `rg` (PATH first, optional bundled per-arch), `.gitignore`-aware,
  output modes (`files`/`content`/`count`), `-A/-B/-C`, multiline, `type`/glob filters. Keep the pure-Swift
  walk as the no-`rg` fallback (so it never hard-fails). Update the tool contract.
- **W1.2 `apply_patch` tool.** Adopt the Codex V4A envelope (`*** Begin/End Patch`, Add/Update/Delete/Move,
  fuzzy hunk match) — models already know it. Multi-file, atomic, confined via ConfinedRoot. Add a
  **diff-preview** the approval prompt shows before applying (ties into the reversibility gate).
- **W1.3 Vision.** `view_image` (load a disk image into the turn) + extend `read_file` to return image/PDF
  content for vision-capable models. Routes through the existing media/vision plumbing.
- **W1.4 Live todo.** Surface `tasks` as the model-facing checklist with the ≤1-in_progress contract; render
  it in the calm UX (ties into the OperatorPanel / "current/next task" lifecycle the DeepSeek audit flagged).

### WAVE 2 — MCP modernization (keep-up urgency: high)
- **W2.1 Streamable HTTP transport** for the MCP client (+ backward-compat SSE probe). Unlocks remote servers.
- **W2.2 Remote OAuth servers** (OAuth 2.1, RFC 8707 resource indicators, audience validation) — Linear/
  Atlassian/Sentry/etc. Keychain secrets, never plaintext.
- **W2.3 MCP resources + prompts** (`resources/list|read`, `prompts/list|get`).
- **W2.4 Lazy tool-loading** — a deferred/hot-set + tool-search primitive so N servers don't blow context.
  Security: hash-pin tool defs at approval, re-verify on connect (tool-poisoning / rug-pull defense).

### WAVE 3 — depth differentiators (high effort, high payoff)
- **W3.1 LSP integration.** Spawn language servers (sourcekit-lsp, gopls, rust-analyzer, pyright, tsserver)
  over stdio JSON-RPC; tools for go-to-def/find-refs/hover/diagnostics/symbols; manage didOpen/didChange.
- **W3.2 Linux sandbox.** Landlock + seccomp-BPF (network deny) + bubblewrap fallback — the missing half of
  `--auto`'s "everything sandboxed" promise on Linux.
- **W3.3 Repo-map** (tree-sitter): parse → extract symbol defs → PageRank-rank → token-budgeted skeleton.

### WAVE 4 — polish
- Background/PTY exec (`exec_command`/`write_stdin`); web_fetch POST/auth headers; libvips image inspect
  (cross-platform, not `sips`); FSEvents/inotify file-watch; structured git tool.

---

## 4. The one-paragraph strategy
We are **not** behind on architecture or safety — we're ahead on the trust spine nobody else has. We're
behind on **four boring-but-essential tools** (ripgrep, apply_patch, vision, HTTP-MCP) that every serious
2026 agent ships, and on **two depth integrations** (LSP, Linux sandbox) that separate the leaders. Wave 1
buys table-stakes parity in days, not months — it's shell-out + thin shims plus one grammar parser. Do
Wave 1 now; it directly fixes the "agent feels underpowered on a real codebase" gap while we keep building
the verification moat that's actually our reason to exist.
