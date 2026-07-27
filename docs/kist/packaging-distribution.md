# Kist — Packaging, Distribution, Config & Shell-Safety Spec

**Status: SPEC ONLY (no code written).** Target deliverable tier: **PRODUCTION-READY**, with
the shell-safety model designed to ENTERPRISE-bar thinking because shell runs ON BY DEFAULT.

Kist is a Swift terminal executable that runs the FloatingChatApp agent system in the
terminal on **macOS** and **Linux headless**. It is the third consumer of `AgentCore`
(alongside the GUI app and `mcp-server`). It reuses `AgentCore`'s `KeyStore`,
`ProviderRegistry`, and the 10-provider `ProviderCatalog` verbatim — no key logic is
re-implemented.

Scope of this doc: SwiftPM layout, config & keys, the shell-on-by-default safety model,
cross-platform gotchas, distribution, and a v0 install/run story.

---

## 0. Ground truth (what already exists in this repo)

- **`AgentCore`** is a Foundation-only SwiftPM **library** (`Package.swift` at repo root,
  `platforms: [.macOS(.v13)]`, products: `.library("AgentCore")`). It compiles on Linux
  (Foundation-only, no AppKit/Security hard dependency — `Security` is `#if canImport`-gated).
- **`KeyStore`** (`Sources/AgentCore/KeyStore.swift`) already provides:
  - `KeychainKeyStore` (macOS, `#if canImport(Security)`) — login Keychain, service
    `com.floatingchatapp.apikeys`, **with env fallback**.
  - `FileKeyStore` (Linux/portable) — env vars first, then JSON at
    `$HOME/.config/agentcore/keys.json` (`{account: key}`).
  - `DefaultKeyStore.make()` — picks Keychain on macOS, File on Linux automatically.
  - Account→env mapping: account `mimo_api_key` → env `MIMO_API_KEY` (uppercased account name).
- **`ProviderCatalog.all`** = **10 providers**: `mimo`, `zhipu`, `moonshot`, `deepseek`,
  `openai`, `grok`, `mlx` (local, no key), `anthropic`, `gemini`, `ollama` (local).
  `ProviderRegistry(providers:keyStore:)` resolves keys via the `KeyStore`. Kist constructs
  exactly one `ProviderRegistry` and uses `hasKey(for:)` / `stream(...)` / `complete(...)`.
- **`mcp-server`** is the reference SwiftPM **executable** (`mcp-server/Package.swift`,
  `.executableTarget(name:"fca-mcp", path:"Sources/fca-mcp")`). Its `AgentTools.swift` +
  `Shell` enum are the reference safe-execution model (root-confined, symlink-safe paths;
  shell via `zsh -f -c` with a scrubbed env). **Kist inherits and HARDENS this model.**
- The **GUI app is an Xcode project** (`FloatingChatApp.xcodeproj`, NO SPM). AgentCore + Kist
  + mcp-server are SPM. See coexistence note in §1.

---

## 1. SwiftPM layout

### 1.1 The `kist` executable target (add to root `Package.swift`)

Add an executable target + product to the existing root package (do **not** create a second
package — keeping Kist in the root package means it links `AgentCore` by in-repo path with
zero version drift):

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentCore",
    platforms: [.macOS(.v13)],          // Linux ignores `platforms:` (uses host)
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .executable(name: "kist", targets: ["kist"]),     // NEW
    ],
    targets: [
        .target(name: "AgentCore"),
        .executableTarget(                                 // NEW
            name: "kist",
            dependencies: ["AgentCore"],
            path: "Sources/kist"
            // No external SwiftPM deps: hand-rolled arg parsing keeps the binary
            // hermetic and the supply-chain surface zero (ENTERPRISE: pinned/audited
            // deps — easiest audit is "none"). If a parser is later wanted, pin
            // swift-argument-parser to an exact tag and vendor a checksum.
        ),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "KistTests", dependencies: ["kist"]),   // NEW
    ]
)
```

Source layout:

```
Sources/
  AgentCore/            (existing library)
  kist/
    main.swift          entrypoint: parse argv → dispatch subcommand
    KistConfig.swift    config discovery + precedence (see §2)
    ShellPolicy.swift   path confinement + allow/deny + approval (see §3)
    KistTools.swift     file/grep tools (reuse mcp-server AgentTools shape, hardened)
    Repl.swift          interactive loop (TTY)
    AuditLog.swift      structured JSONL audit log (see §3.6)
Tests/
  KistTests/
```

### 1.2 Build invocations

**macOS:**
```bash
# debug
swift build --product kist
# release (what ships)
swift build -c release --product kist
# binary at: .build/release/kist     (or .build/arm64-apple-macosx/release/kist)
```

Universal binary (Apple Silicon + Intel) for distribution:
```bash
swift build -c release --product kist --arch arm64 --arch x86_64
# → .build/apple/Products/Release/kist  (universal)
```

**Linux (headless):**
```bash
# On a Linux box (or the official `swift:5.9` Docker image):
swift build -c release --product kist
# binary at: .build/release/kist
```
Linux compiles `FileKeyStore` (Security framework is absent → `#if canImport(Security)` is
false → `KeychainKeyStore` is not built). No code change required; this is already how
`KeyStore.swift` is written.

### 1.3 Where the binary lands & installing to `~/bin`

`swift build` always emits to `.build/<config>/kist`. Kist is installed by **copying** that
artifact to `~/bin/kist` (a real binary, not a shell launcher — but a `.command` launcher is
also provided for macOS Finder per Luke's conventions, see §5).

```bash
install -m 0755 "$(swift build -c release --show-bin-path)/kist" "$HOME/bin/kist"
```

### 1.4 Coexistence: Xcode GUI app (no SPM) ↔ SPM AgentCore/Kist/mcp-server

This is intentional and already the established pattern in the repo:

- The **GUI app** is built by **Xcode** (`xcodebuild -project FloatingChatApp.xcodeproj -scheme
  FloatingChatApp`). It does **not** consume the SwiftPM package; it includes AgentCore sources
  via classic Xcode groups / its own target membership (the `add_*.rb` xcodeproj scripts).
- **AgentCore is the single source of truth** for the shared brain (providers, key store,
  models). The GUI target and the SPM package both compile the **same `Sources/AgentCore/*.swift`
  files** — Xcode by file reference, SPM by `.target(name:"AgentCore")`. There is one copy of the
  code on disk; two build systems point at it.
- **Kist and mcp-server never touch the Xcode project.** They are pure SPM, built with
  `swift build`. They share Keychain state with the GUI app only through the **service name**
  (`com.floatingchatapp.apikeys`) — a runtime contract, not a build dependency.
- Practical rule (already in project CLAUDE.md): a new `.swift` file added for the GUI must be
  registered in `project.pbxproj`; a new file for Kist/mcp-server only needs to live under the
  SPM target's `path`. Keep Kist-only files **out** of `Sources/AgentCore/` so they don't leak
  into the GUI target.

---

## 2. Config & keys

### 2.1 Key discovery (reuse `KeyStore`, do NOT re-implement)

Kist obtains all provider keys via `DefaultKeyStore.make()` → injected into
`ProviderRegistry(keyStore:)`. Resolution order is whatever `KeyStore` already does:

| Platform | Resolution order (per account, e.g. `openai_api_key`) |
|----------|--------------------------------------------------------|
| macOS    | login Keychain (`com.floatingchatapp.apikeys`) → env `OPENAI_API_KEY` |
| Linux    | env `OPENAI_API_KEY` → JSON `$HOME/.config/agentcore/keys.json` |

Local providers (`mlx`, `ollama`) have `requiresAPIKey == false` → no key needed;
`registry.hasKey(for:)` returns true regardless.

`kist keys` subcommand surface (thin wrappers, no new storage):
- `kist keys list` — for each of the 10 providers, print `id`, `hasKey` (✓/✗), and the
  **source** (keychain / env / file / not-required). Never prints key values.
- `kist keys set <provider>` — macOS: write to Keychain via Security (same service as the GUI
  wizard). Linux: print the exact `export NAME=…` line **or** offer to append to
  `keys.json` with `chmod 600`. Reads the key from a TTY prompt with echo OFF (never argv,
  never logged).
- `kist keys path` — print the resolved keys.json path + which store is active.

### 2.2 Kist config file (separate from keys)

Config is **non-secret behavior**, kept apart from keys.

- **Location (XDG-first, both platforms):** `$XDG_CONFIG_HOME/kist/config.json`, default
  `$HOME/.config/kist/config.json`. (Matches AgentCore's existing `~/.config/agentcore/`
  convention; keeps mac+Linux identical — see §4.)
- **Format:** JSON (Foundation-only, no TOML dep).

Configurable fields (all optional; built-in defaults shown):

```jsonc
{
  "defaultProvider": "anthropic",      // any of the 10 provider ids
  "defaultModel": null,                // null → provider.defaultModel
  "projectRoot": null,                 // null → CWD at launch; the shell/file confinement root
  "shell": {
    "enabled": true,                   // ON BY DEFAULT (Luke's explicit choice)
    "mode": "interactive-approve",     // interactive-approve | auto | off
    "allow": [],                       // optional allowlist of command name prefixes
    "deny":  ["rm -rf /", "curl", "wget", "ssh", "sudo", "nc",
              ":(){:|:&};:", "dd if=", "mkfs", "chmod -R"],   // see §3.3
    "timeoutSeconds": 120,
    "maxOutputBytes": 40000
  },
  "audit": { "enabled": true, "path": null },  // null → ~/.local/state/kist/audit.jsonl
  "maxIterations": 25
}
```

### 2.3 Precedence (highest wins)

1. **Command-line flags** (`--provider`, `--model`, `--root`, `--yolo`, `--no-shell`, `--allow`,
   `--deny`, `--max-iter`).
2. **Environment variables** (`KIST_PROVIDER`, `KIST_MODEL`, `KIST_ROOT`, `KIST_SHELL=off|auto`).
   *Note:* API **keys** follow `KeyStore`'s own order (§2.1) and are not part of this chain.
3. **Config file** (`~/.config/kist/config.json`).
4. **Built-in defaults** (table above).

Security carve-out — precedence does **not** allow widening past safety: a `deny` entry can
never be removed by a lower-precedence layer, and `projectRoot` from any layer is still subject
to the confinement check (§3.1). Flags can only **add** denies / **narrow** allows, plus opt
into `--yolo` (which is loud — see §3.4).

---

## 3. SHELL-ON-BY-DEFAULT safety model (the part that matters most)

The `mcp-server` reference keeps shell **off** unless explicitly enabled. **Kist flips that
default to ON.** That single change moves the entire blast radius from "opt-in dangerous" to
"on-by-default dangerous," so the guardrails below are the price of that choice.

### 3.1 Threat model

The model (LLM) is **untrusted input**, and the strings it emits are **untrusted code**.
Threats, in priority order:

1. **Exfiltration of secrets.** A command reads API keys / SSH keys / `.env` / Keychain and
   pipes them to the network (`curl`, `nc`, DNS tricks). *Highest severity* — Luke ships to
   vulnerable users; a leaked key can be abused at their cost or expose their data.
2. **Destruction outside the project.** `rm -rf ~`, `dd`, `mkfs`, fork bombs, `chmod -R` on
   `$HOME`. The file tools are root-confined; **a raw shell is not** — `cd ..` / absolute paths
   escape (this is exactly the caveat the mcp-server `Shell` comment calls out).
3. **Privilege escalation / persistence.** `sudo`, editing `~/.zshrc`/`~/.bashrc`/cron/launchd
   to run attacker code on next login.
4. **Lateral movement.** `ssh`, reading `~/.ssh`, hitting cloud metadata endpoints
   (`169.254.169.254`).
5. **Prompt-injection chain.** A file the agent reads (`README`, web content) contains
   instructions that steer the model into 1–4. The defense is that the *human* still gates
   execution (§3.4), not that the model "knows better."

### 3.2 Path confinement to a project root

- Reuse the `AgentTools.resolve(...)` pattern verbatim for **file tools**: expand `~`,
  `standardizedFileURL`, `resolvingSymlinksInPath()`, then require
  `url.path == root.path || url.path.hasPrefix(root.path + "/")`. Symlinks inside root that
  point outside are rejected (the Codex-CRITICAL fix that's already in the reference).
- `root` = `projectRoot` from config/flags, default = CWD at launch.
- **Shell `cwd` is `root`**, but a shell command can still `cd` out. So confinement for shell is
  enforced by the **command filter + approval**, not by `cwd` alone. Treat shell as "can reach
  anywhere the user can" and gate accordingly.

### 3.3 Command allow/deny lists

Two-stage filter applied to the **raw command string** before any process spawns:

- **Deny list (hard block, always on, cannot be disabled even by `--yolo`):** patterns that are
  never legitimate for a confined coding agent. Default set: `sudo`, `rm -rf /` and `rm -rf ~`,
  `dd if=`, `mkfs`, `:(){:|:&};:` (fork bomb), `chmod -R`/`chown -R` on `$HOME` or `/`,
  `> /dev/sd*`, writes to `~/.ssh`, `~/.zshrc`, `~/.bashrc`, `~/.profile`, crontab, `launchctl`,
  and **network exfil tools** by default (`curl`, `wget`, `nc`, `ssh`, `scp`, `telnet`).
  Network tools are denied by default because exfiltration is the top threat (§3.1#1); a user who
  needs them adds them to `allow` consciously.
- **Allow list (optional whitelist):** if non-empty, the command's first token must match a
  prefix in `allow` or it's rejected. This is the **enterprise posture** — flip from
  "deny-known-bad" to "permit-known-good" (e.g. `["git ", "swift ", "npm ", "ls", "cat ",
  "grep ", "make "]`).
- Matching is on the **normalized** command (collapse whitespace; reject if it contains
  `&&`/`;`/`|`/backticks/`$(` when an allowlist is active, so a permitted prefix can't smuggle a
  denied tail). Deny always beats allow.
- **This is mitigation, not a sandbox.** A string filter cannot be exhaustive (base64-decoded
  payloads, `eval`, env-var indirection all exist). The real backstop is §3.4 + §3.7. The filter
  removes the obvious foot-guns and forces creativity to be visible to the human.

### 3.4 Approval: interactive prompt vs `--yolo`/`--auto`

Three modes (config `shell.mode`, overridable by flag):

- **`interactive-approve` (DEFAULT when stdin is a TTY):** every shell command is shown to the
  user *before* it runs — full command, resolved cwd, and which deny/allow rules it passed —
  and waits for `y / n / a(lways this exact command) / e(dit) / q(uit)`. File **writes/edits**
  outside a quiet allowlist also prompt. Reads and the pure-Foundation grep do not prompt.
- **`auto` (a.k.a. `--yolo` / `--auto`):** no per-command prompt. Deny list is **still enforced**
  (it cannot be disabled). Entering this mode prints a loud, un-suppressible banner
  (`⚠️ KIST AUTO MODE: shell commands run WITHOUT approval. Deny-list still active.`) and is
  recorded in the audit log. Refuses to enable `auto` **and** an empty deny list at once.
- **`off` (`--no-shell` / `shell.enabled=false`):** shell tool is not registered at all; the
  agent gets only the confined file/grep tools (the mcp-server default posture).

**Non-interactive default (no TTY — CI, Linux headless pipe):** if stdin is **not** a TTY and the
user did not explicitly pass `--yolo`, Kist defaults shell `mode` to **`off`**, not `auto`. A
headless run must opt into autonomy explicitly; it must never silently auto-execute model
commands because nobody is watching. (This is the single most important default in the whole
spec — see closing summary.)

### 3.5 Environment scrubbing

Reuse and tighten the `Shell.scrubbedEnv` model from `AgentTools.swift`:

- Child process gets a **minimal env**: `PATH` (sanitized to a fixed safe list, not inherited
  verbatim), plus `HOME`, `LANG`, `LC_ALL`, `TMPDIR`, `USER`. **Nothing else.**
- **No `*_API_KEY` / `*_TOKEN` / `*_SECRET` / `AWS_*` / `GH_*` ever pass through** — they are
  resolved by the parent only when calling provider HTTP and never exported to the child. (On
  macOS the keys live in Keychain, not env, so they're naturally absent; on Linux they may be in
  the parent env, which is exactly why the scrub allowlist is strict.)
- Spawn with `zsh -f -c` on macOS (skip `~/.zshenv`/rc) and `sh -c` on Linux (no profile). The
  `-f` / bare `sh` matters: it stops the child from re-sourcing a user rc that could re-inject
  secrets or aliases.
- Async pipe drain + hard timeout + SIGKILL exactly as the reference (prevents a child holding
  the pipe open from hanging Kist).

### 3.6 What gets logged (structured audit)

Append-only **JSONL** at `~/.local/state/kist/audit.jsonl` (XDG state dir; config-overridable).
One line per security-relevant event:

```jsonc
{"ts":"2026-06-25T12:00:00Z","kind":"shell","mode":"interactive-approve",
 "root":"/home/luke/proj","cmd":"git status","decision":"approved",
 "denyHit":null,"allowHit":"git ","exit":0,"durMs":42}
```

- Logged: every shell **attempt** (approved, denied, auto-run), every file **write/edit**, mode
  changes, `--yolo` activation, every deny-list hit (even if the user would have approved).
- **Redaction:** the audit log records the *command string the model proposed* — which the model
  controls — so the log itself must be treated as potentially containing injected secrets. It is
  written `chmod 600`. Key **values** are never logged (the `keys` subcommand and provider calls
  never emit them). Provider request/response bodies are **not** logged by default.
- Logging is on by default; `audit.enabled=false` is allowed but prints a warning, because for
  vulnerable-user shipping an un-audited autonomous shell is a disqualifier.

### 3.7 Defense-in-depth summary (belt + suspenders)

No single layer is trusted: (1) string deny-list, (2) optional allow-list, (3) human approval in
the default mode, (4) scrubbed env so even a successful command finds no secrets to steal,
(5) confined file tools so the *non-shell* path can never escape, (6) audit trail so anything that
does happen is attributable. The model is assumed hostile at every layer.

**Honest label:** the shell layer is **PILOT-READY today, PRODUCTION-bar by design.** It is *not*
a true sandbox (no seccomp/Landlock on Linux, no `sandbox-exec` profile on macOS). The
**enterprise hardening follow-up** (named explicitly so it isn't forgotten) is: wrap shell
execution in OS-level sandboxing — `sandbox-exec`/App Sandbox profile (macOS) and
seccomp-bpf + Landlock or a `bubblewrap` jail (Linux) — confining the *child* to `root` at the
kernel level. Until that lands, do not call the shell layer ENTERPRISE-READY.

---

## 4. Cross-platform gotchas

- **Keychain absent on Linux.** `KeychainKeyStore` is `#if canImport(Security)`-gated and simply
  isn't compiled on Linux; `DefaultKeyStore.make()` returns `FileKeyStore`. **No code change
  needed.** Implication: on Linux, keys live in env or `~/.config/agentcore/keys.json`
  (`chmod 600` — Kist should warn if the file is group/world-readable).
- **Shell binary differs.** macOS ships `zsh`; minimal Linux images may lack it. Use `zsh -f` on
  macOS, fall back to `/bin/sh -c` on Linux. Probe at startup; if no usable shell exists, force
  `shell.mode=off` and say so.
- **File paths.** Keep everything XDG-based (`$HOME/.config`, `$HOME/.local/state`) so the same
  defaults work on both OSes. macOS *also* has `~/Library/Application Support`, but Kist
  deliberately uses XDG on mac too for one config story (AgentCore already uses
  `~/.config/agentcore`). Always `expandingTildeInPath` + `standardizedFileURL`; never assume `/`.
- **Process spawning.** `Process` works on both, but: signal handling and the
  `terminationHandler`/pipe-drain dance must be tested on Linux (Foundation's Process on Linux
  has had quirks with `readabilityHandler`). The reference's async-drain + SIGKILL pattern is the
  safe baseline; verify on Linux in CI.
- **TTY detection.** `isatty(STDIN_FILENO)` is portable C and the basis for the
  interactive-vs-headless default (§3.4). Test it under Docker (`-it` vs piped) — getting this
  wrong is how headless `auto` accidentally happens.
- **Universal binary** is macOS-only (`--arch arm64 --arch x86_64`); on Linux build per-arch
  (x86_64 and aarch64 separately).

---

## 5. Distribution — how Luke gets `kist` on PATH

### 5.1 Build + install script (`Scripts/install-kist.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."                       # repo root
echo "Building kist (release)…"
if [[ "$(uname)" == "Darwin" ]]; then
  swift build -c release --product kist --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/kist"
else
  swift build -c release --product kist
  BIN="$(swift build -c release --show-bin-path)/kist"
fi
mkdir -p "$HOME/bin"
install -m 0755 "$BIN" "$HOME/bin/kist"
echo "Installed → $HOME/bin/kist"
case ":$PATH:" in *":$HOME/bin:"*) ;; *) echo "⚠️  add ~/bin to PATH (e.g. in ~/.zshrc)";; esac
```

### 5.2 macOS Finder launcher (`Kist.command`, per Luke's conventions)

Double-clickable, opens Terminal, starts an interactive Kist session in the chosen folder:

```bash
#!/bin/bash
# Kist.command — double-click to launch Kist in interactive mode.
cd "$(dirname "$0")"
exec "$HOME/bin/kist" repl
```
`chmod +x Kist.command`. (This is the GUI on-ramp; PATH users just type `kist`.)

### 5.3 Versioning & provenance

- `kist --version` prints the build's git SHA + tag (injected at build time via a generated
  `Version.swift` or `-Xswiftc -DKIST_VERSION=…`). ENTERPRISE: every binary is traceable to a
  commit.
- Releases are tagged; the universal mac binary and per-arch Linux binaries are the release
  artifacts. (No Homebrew/apt in v0 — that's a follow-up.)

---

## 6. v0 install/run story (end to end)

```bash
# 1. Clone & build (macOS or Linux)
git clone <repo> && cd FloatingChatApp-save-complex-agent-state
./Scripts/install-kist.sh          # builds release, copies to ~/bin/kist

# 2. Add a key (once). macOS → Keychain; Linux → env or keys.json
kist keys set anthropic            # prompts, echo off; stored in Keychain (mac) / advised (linux)
kist keys list                     # ✓ anthropic (keychain), ✗ openai, …, mlx (not-required)

# 3. (optional) configure defaults
mkdir -p ~/.config/kist
cat > ~/.config/kist/config.json <<'JSON'
{ "defaultProvider": "anthropic", "shell": { "enabled": true, "mode": "interactive-approve" } }
JSON

# 4a. Interactive run (TTY) — shell ON, every command prompts y/n
cd ~/my-project
kist repl                          # root = CWD; agent plans→acts; shell cmds gated by approval

# 4b. One-shot
kist run "add a --help flag and a unit test for it"

# 4c. Headless / CI (no TTY) — shell defaults OFF unless you opt in
kist run "fmt the repo" --provider openai            # shell auto-OFF (no TTY): file tools only
kist run "fmt the repo" --yolo --allow "swift ,git " # explicit autonomy, narrowed allowlist
```

What happens on a shell command in the default interactive flow:
1. Model proposes `git commit -am "x"`.
2. Kist normalizes it, checks deny (pass) / allow (n/a), shows it + cwd + rule result.
3. User answers `y` → spawn `zsh -f -c` in `root` with scrubbed env, 120s timeout.
4. Output (≤40 KB) returned to the loop; the attempt + decision + exit code appended to
   `audit.jsonl`.

---

## 7. Labeling

- **SwiftPM packaging / config / key reuse:** PRODUCTION-READY by design (reuses proven
  AgentCore seams; needs Linux CI + the install script committed to earn the label in practice).
- **Shell-safety layer:** **PILOT-READY, PRODUCTION-bar in design** — enterprise-blocked on:
  (1) no OS-level sandbox (seccomp/Landlock/sandbox-exec) confining the child, (2) string-filter
  is necessarily incomplete, (3) no cross-tenant story because Kist is single-user (acceptable
  for the tool's scope, but state that explicitly). Hardening follow-up is named in §3.7.
- **Distribution:** PILOT-READY (script + .command launcher; no signed/notarized mac binary, no
  package-manager channel yet).
```
