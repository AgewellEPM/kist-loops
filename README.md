# Mythos

**An open-source agent shell that runs on *any* model you bring a key for.**

Mythos is a terminal-first autonomous coding/agent runtime in the spirit of Claude Code — plan →
act → observe → repeat, over real tools, in your project — but **provider-agnostic**: point it at
OpenAI, Anthropic, Gemini, Grok, DeepSeek, Kimi, GLM, MiMo, or a local model (Ollama / MLX) with
your own key. One agent loop, every AI.

```
$ kist "find the slowest test and tell me why"
$ kist                       # interactive REPL
$ kist --resume <id>         # pick a run back up where it stopped
```

> **Status: PILOT.** The engine is built, covered by thousands of automated checks, and security-reviewed. It runs real
> agentic loops against real providers today. It is not yet 1.0 — see [Status](#status).

## Why

Claude Code is excellent and Anthropic-only. Mythos asks: what if the same kind of agent shell were
**open source** and ran on **whatever model you want** — including local, offline ones? You own the
keys, the data path, and the code.

## Quick start

The [terminal setup candidate](Tools/kist_local_runtime/DISTRIBUTION.md) reuses Kist's
existing model picker on first launch: choose a model, complete setup, and enter the
REPL in your current repository. The packaged launcher can prepare a small local
model automatically and unload it after requests. macOS packaging is under local
verification; Linux/WSL require their own build and execution checks. This is not
yet a published cross-platform release.

```bash
# Build the CLI (Swift 5.9+, macOS or Linux)
swift build -c release            # produces .build/release/kist

# Bring a key (any one of these works; Mythos auto-picks a configured provider)
export OPENAI_API_KEY=…           # or ANTHROPIC_API_KEY / GEMINI_API_KEY / …
kist --list-providers             # see what's configured

# Run
kist "summarize what this project does and list its entry points"
kist                              # REPL: chat, it acts, you continue (/help, /clear, /exit)
```

Local, no key needed: run an [Ollama](https://ollama.com) model and `kist --provider ollama "…"`.

## What it does

| | |
|---|---|
| **BYOK, 10 providers** | OpenAI, Anthropic, Gemini, Grok, DeepSeek, Kimi, GLM, MiMo (cloud) + Ollama, MLX (local). Keys from Keychain (macOS) or env. |
| **Real tools, sandboxed** | read / write / edit / list / glob / search, and (opt-in) shell — every path confined to the project root. |
| **Resume** | every step is checkpointed; `kist --resume <id>` / `--resume-last` / `--list`. |
| **Self-correction** | live re-plan when actions keep failing. |
| **Human-in-the-loop** | in the REPL, shell + file-write tools ask before they run (`--yolo` to skip). |
| **MCP** | use any [Model Context Protocol](https://modelcontextprotocol.io) server's tools — configure in `~/.mcp.json`. |
| **Multi-agent** | the agent can `spawn_agent` to delegate a focused subtask to a fresh sub-agent. |

The approval-gated SML harness can also turn reviewed OpenAPI 3 JSON operations into pinned HTTP
capabilities and single-operation workflows. See the [SML runtime operator guide](docs/SML_RUNTIME_OPERATOR_GUIDE.md)
for the import, human-admission, credential, and durable-run procedure.

## Safety & privacy

**No telemetry. No phone-home.** Mythos sends your prompts and code only to the AI provider *you*
configured, using *your* key — and nowhere else. There's no analytics, no usage beacon, no crash
reporter; nothing is sent to the maintainers. Provider calls go to your selected
endpoint; `fetch_url` uses its SSRF guard. Packaged local setup also downloads the
selected weights from Ollama and, when needed, the private runtime from GitHub.

**A dev tool, not an exploit tool.** Mythos ships no scanners and no attack tooling — it's a general
coding agent (read / write / edit / search / generate / run). Use it only on systems you own or are
authorized to work on. Full policy + responsible-use + vuln disclosure: [`SECURITY.md`](SECURITY.md).

Because it executes tools, confinement is first-class (engine threat model:
[`Sources/AgentCore/SECURITY.md`](Sources/AgentCore/SECURITY.md)):

- **Filesystem confinement** — file tools are restricted to the project root via an `openat`/
  `O_NOFOLLOW` layer (`ConfinedRoot`) that defeats `..`/symlink escapes.
- **SSRF-guarded network** — `fetch_url` resolves the host and **refuses** loopback, private
  (RFC-1918), link-local, and cloud-metadata IPs, and follows no redirects.
- **Process-group teardown** — spawned commands run in their own process group and are killed as a
  group on timeout/return; no orphaned grandchildren.
- **Shell off by default** — `run_command` is disabled unless you pass `--allow-shell`; a deny-list
  still blocks the worst shapes; raw shell needs approval.
- **Opt-in OS sandbox** — `--sandbox` wraps commands in macOS Seatbelt or Linux bubblewrap
  (kernel-enforced network-deny + write-confinement). If the platform sandbox is unavailable,
  execution fails closed instead of running unsandboxed.
- **Tool approval** — the REPL prompts y/n before sensitive tools; sub-agents inherit the policy.
- **Spend ceiling** — `--budget <tokens>` hard-stops a run at the cap (honest-fail, no surprise bill).

## Architecture

Two pieces, one Foundation-only Swift package (`AgentCore`) + a CLI (`Kist`):

- **`AgentCore`** — the headless, cross-platform engine: pluggable providers (`ChatProvider`),
  sandboxed `ToolRegistry`, an MCP client, and `HeadlessAgentLoop` (the agent loop). No UI deps.
- **`Kist`** — the terminal shell wired on top.

The loop supports both **native provider tool calls** and a provider-agnostic structured-text
protocol. Capable providers use their native tool format; local or compatibility models use the
same JSON-action loop through the text path. Both paths share tools, approvals, checkpointing,
progress monitoring, verification, and resume reconciliation.

The reliability rules live inside those existing paths; this work did not add another REPL or
control plane. Plan execution retains every invocation attempt, including failures later replaced by
a repair, and carries deterministic verification evidence across replans. Concurrent dependency-wave
steps do not establish a false mutation-before-verification order. A resumed mutation turn cannot
reuse stale pre-resume build/test proof to authorize completion: it needs fresh verification against
the current workspace state. Recognized build, dependency, test, and CI manifests, configuration
files, and lockfiles are treated as verification-requiring inputs when changed.

A macOS SwiftUI app shares the same `AgentCore` engine.

## Status

PILOT-quality and honestly labeled — built and reviewed, not yet 1.0. Known gaps:

- Linux and macOS builds/tests are covered by the CI matrix. Linux bubblewrap enforcement is
  additionally exercised by a real-kernel integration check in CI; the first remote run is still
  required before calling the gate green.
- OS sandbox parity is available for the common deny-network/write-confinement policy. Exact
  loopback proxy allowlists remain unsupported by bubblewrap and fail closed; per-domain egress
  policy is still a future hardening tier.
- The native-scrollback REPL's response-bar behavior is unchanged: pinned while idle, with
  during-turn sticky capture remaining explicit opt-in (`--sticky-turns`) while terminal/resize
  coverage continues to mature.
- Model review is advisory evidence; only executed deterministic checks establish verification.

## License

TBD before public release.
