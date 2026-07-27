# kist — new capabilities (2026-07-01)

Operator guide for the tools/primitives added this cycle. All landed on `main` except where
noted. Each was adversarially reviewed (Codex + DeepSeek/Gemini/Grok on the primitives).

## Code intelligence (read-only, no setup)

| Tool | What it does |
|------|--------------|
| `ast_grep` | Structural (AST) search + rewrite **preview**. Finds every site of a pattern by structure, not text. Needs the `ast-grep` binary (`brew install ast-grep`); degrades with an install hint if absent. |
| `ast_grep_apply` | Applies a structural rewrite in place across every match. **Mutating → approval-gated + shell-gated.** |
| `git` | Read-only `status`/`diff`/`log`/`show`/`blame`. Works shell-off. Hardened against git's code-exec surfaces (no pager/fsmonitor/external-diff/textconv/hooks). Mutating git stays behind `run_command`. |
| `symbols` | `outline` a file's declarations, or `find` where a symbol is defined repo-wide. 9 languages. Complements `search_code`/`ast_grep`/`context_brain`. |

## Edit safety (automatic)

`EditGuards` runs on every `edit_file`/`write_file`/`apply_patch`: refuses leaked merge/patch
markers, catastrophic (>60%) truncation of a localized edit, and mass (3+) dropped imports.
Stricter-never-looser — it can only block, never loosen.

`toolOutputEnvelope` scans every tool's output for prompt-injection signatures and prepends an
untrusted-data banner when found (advisory only — never blocks or changes control flow).

## Local embeddings (opt-in)

Semantic memory (`remember`/`recall`) can run fully local instead of the Gemini API:

```sh
export KIST_EMBEDDER=ollama            # requires a running Ollama
export KIST_EMBED_MODEL=nomic-embed-text   # optional; this is the default
```

Without the opt-in it uses Gemini when its key is present, else semantic memory is off.

## Type-aware navigation via LSP (`kist-lsp` helper)

kist auto-discovers MCP servers from `~/.mcp.json`. `Tools/kist-lsp` registers an
LSP-over-MCP bridge (`isaacphi/mcp-language-server`) so the model gets `definition`,
`references`, `hover`, `diagnostics`, `rename_symbol`.

```sh
# one-time bridge install (needs Go)
brew install go && go install github.com/isaacphi/mcp-language-server@latest
# symlink onto PATH if ~/go/bin isn't there:
ln -sf ~/go/bin/mcp-language-server /opt/homebrew/bin/mcp-language-server

Tools/kist-lsp doctor                       # check prerequisites + LSP servers
Tools/kist-lsp add swift --workspace .      # register for the current project
Tools/kist-lsp status                       # list configured LSP servers
```

Notes:
- One workspace per entry — re-run `add` when you switch projects.
- sourcekit-lsp/rust-analyzer resolve symbols only after their index loads (~30–50s on connect
  for a large repo); the first query right after connect may say "not found" until it warms up.
- The bridge exposes MUTATING tools (`*__edit_file`, `*__rename_symbol`). kist gates these:
  see below.

## MCP tool safety (automatic)

External MCP tools bypass kist's `ConfinedRoot`, so they aren't covered by FILE-TREE-TRUST.
`ReversibilityClassifier` is **default-deny** for any `server__leaf` tool: it's treated as
`.dangerous` (always prompts, even past "allow all") **unless** its leaf is provably read-only
(`get`/`list`/`read`/`definition`/`references`/`hover`/`diagnostics`/…). Handles snake/camel/kebab
naming; compound read+write (`getAndReplace`) is gated. The plan-execute DAG enforces the same
gate — it is not an approval bypass.

## Authorized security testing (`pentest`, REPL-only)

For testing **your own** infrastructure. Refuses everything until you create the allowlist —
the agent can only READ it, never edit it. Fail-closed: no file ⇒ nothing runs.

```sh
# ~/.kist/authorized-targets.conf  (one entry per line; the agent CANNOT add to this)
app.tinky.com
*.tinky.com          # apex + subdomains
10.0.0.0/24          # CIDR (subset targets only)
```

- Approval-gated + shell-gated + every run appended to `~/.kist/pentest-audit.log` (fail-closed:
  no scan without a durable audit record).
- Subcommands shell out to standard tools (non-destructive flags), install what you need:
  `ports`(nmap) `tls`(testssl/sslscan) `headers`(httpx) `vuln`(nuclei) `web`(nikto)
  `dirs`(ffuf/gobuster + wordlist) `subs`(subfinder).
- `KIST_AUTHORIZED_TARGETS` overrides the allowlist path.
