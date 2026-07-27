# AgentCore — Security Model & Threat Model

AgentCore is the headless tool + provider + MCP core for an autonomous agent runtime. It
executes model-directed actions (file I/O, shell commands, MCP tool calls) on a host. This
document states what it **guarantees**, what it **deliberately does not** (yet), and the
threat model those choices assume. Labels follow the project bar; see the bottom.

## Trust model & assumptions

- **The LLM is untrusted.** Tool arguments are attacker-influenced (prompt injection, a
  malicious shared board, a poisoned web page). Every tool gates its inputs; nothing trusts
  that the model "meant well."
- **The project root and the host user are trusted.** AgentCore confines actions *to* a
  project root the user owns; it is not a sandbox against the user themselves.
- **MCP servers and their config are a separate trust boundary** — validated before spawn,
  output sanitized after. Project-local `.mcp.json` is **opt-in only** (untrusted-workspace
  RCE guard).
- **Out of scope:** a hostile *local* process that can already write inside or adjacent to
  the project root and race the filesystem at high frequency. We close the cheap races
  (see below) but do not claim to defeat an attacker with concurrent write access to the
  root's ancestors. A kernel-enforced sandbox (roadmap P3) is the answer there.

## Guarantees (enforced + tested)

### 1. Filesystem confinement — `ConfinedRoot` (openat / O_NOFOLLOW)
- The root is opened **once** to a trusted directory fd with `O_NOFOLLOW | O_CLOEXEC` and
  **held**; every descendant access is an `openat` relative to a `dup` of that fd with
  `O_NOFOLLOW`. There is no per-operation re-resolution of the root pathname by name.
- A symlink swapped in at the **leaf or any intermediate component** yields `ELOOP` and is
  refused — closing the check-then-open TOCTOU window for descendants.
- `..` traversal, absolute paths outside the root, and sibling-prefix paths (`/rootEVIL`)
  are rejected. Writes are atomic (`temp + renameat` inside the confined parent); a
  symlinked leaf has the **link** replaced, never its target.
- **Deliberate trade-off:** symlinks *inside* the root are **not followed** (read/list/walk
  through an in-repo symlink is refused). Security-first; documented contract.
- All headless file/dir/search tools route through this layer. Tested:
  `ConfinedRootTests`, `ToolConfinementTests` (per-tool, through the live registry, incl. a
  held-fd root-pathname-swap test proven to fail on the old open-by-name path).
- **Residual:** an **ancestor of the root** swapped to a symlink *before* the one-time init
  open is resolved by name once (same exposure as `realpath`). Out of scope per the threat
  model; a kernel sandbox closes it.

### 2. Process lifecycle — `ProcessGroupRunner` (posix_spawn + process-group kill)
- Children are spawned via `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (pgroup 0) → the child
  leads its **own** process group, set atomically pre-exec.
- On **timeout, output-cap, and normal return**, the **whole group** is torn down
  (`killpg` SIGTERM → grace → SIGKILL) so a forked grandchild cannot orphan past the call.
- PGID-reuse safe: the group is only signalled while an un-reaped zombie reserves the PGID
  (exit detected via `waitid(WNOWAIT)`, swept before reap); every `killpg` is gated by a
  "still ours" flag and disarmed after reap. If a host `SIGCHLD=SIG_IGN`/`SA_NOCLDWAIT`
  auto-reaps the child (no zombie), the post-exit sweep is skipped rather than risk a
  recycled PGID.
- Output is drained on two concurrent threads (no full-pipe deadlock), multiplexed with a
  shutdown self-pipe via `poll()` (portable wakeup on Darwin **and** Linux), into a hard
  per-stream byte cap (bounded memory).
- Tested: `ProcessGroupRunnerTests` — grandchild-killed-on-timeout over multiple shell
  shapes, normal-return and output-cap orphan sweeps; the timeout test is proven to fail
  under a PID-only kill.
- **Residual:** a descendant that calls `setsid()`/`daemon()` leaves the group and survives
  `killpg` (standard for a shell-exec tool). cgroup-v2 `cgroup.kill` / PID-namespace is the
  future hardening tier (roadmap).

### 3. Command gating — `ShellPolicy` (structured-first, deny > allow > approval)
- **Structured exec** (`executable` + `args`) is the default and is spawned with **no
  shell**, so the deny/allow gate is enforced on the **resolved absolute binary path + full
  argv** the OS execs — `rm${IFS}-rf` / `/tmp/git` token tricks don't apply.
- **Raw shell** (`command` + `shell:true`) is opt-in and can **never be auto-approved** —
  it requires an approval handler (refused outright when none exists, e.g. non-interactive).
- Deny-list matches the full argv line (so `curl https://…`, `dd if=…` fire); allow-list
  matches the resolved basename. Deny wins.

### 4. Environment & output hygiene
- Child env is **scrubbed to an allow-list** (`PATH, HOME, USER, LANG, LC_*, TERM, TMPDIR,
  SHELL, PWD`) — no host secrets reach spawned tools or MCP servers.
- Per-stream output byte caps (shell), 64 KB cap + control/format-char stripping (MCP).

### 5. MCP boundaries
- **Config validation (pre-spawn):** absolute command paths only, no `..`, no shell
  metacharacters, executable check, NUL-free env, secret-key hints; project-local config
  opt-in. **Output sanitization (post-call):** size cap + control/bidi/zero-width stripping.
- Zombie-proof shutdown (SIGTERM→SIGKILL + await-exit), actor-isolated, 1 MB line cap.

### 6. OS-level sandbox tier — `SandboxPolicy` / `SeatbeltSandbox` (opt-in, macOS)
- When `ToolContext.sandbox` is enabled, `run_command` wraps the resolved command in macOS
  **Seatbelt** (`sandbox-exec`) so the **kernel** enforces, on top of the in-process gates:
  **network egress default-deny** and **filesystem-write confinement** to the project root
  (+ `/private/tmp`, the process `$TMPDIR`, `/dev`). Reads are allowed.
- The sandbox launcher is just another member of the spawned process group, so it composes
  with `ProcessGroupRunner` teardown. A malicious root path cannot inject the profile
  (TinyScheme string-escaped). Tested: `SeatbeltSandboxTests` (live write-deny outside root,
  write-allow inside, a disabled-sandbox control proving the sandbox is the gate).
- Live Seatbelt kernel checks are opt-in so normal harness runs do not emit nested
  `sandbox-exec` false positives. Run them explicitly outside the harness with
  `KIST_LIVE_SEATBELT=1 swift test --disable-sandbox --filter "SeatbeltSandboxTests|CustomToolTests"`.
- **Fails closed:** on a platform without Seatbelt (Linux), a *requested* sandbox returns
  unavailable and the command is **refused** — it never silently runs unsandboxed.

## NOT yet provided (roadmap — do not assume these)

| Gap | Status |
|---|---|
| **Network egress control** | **macOS: available** (opt-in Seatbelt `denyNetwork`). **Linux: not yet** (bubblewrap tier — fails closed). `fetch_url` supports configured exact/wildcard host allowlists via Kist `--fetch-host` / config, plus per-call narrowing. |
| **OS-level sandbox** | **macOS: available** (opt-in Seatbelt write-confinement + egress-deny). **Linux: not yet** (fails closed; bubblewrap+seccomp planned). |
| **Resource limits** (`setrlimit` CPU/AS/FSIZE) | **Absent.** Timeout + output cap only. (Roadmap P4) |
| **Secret output masking** | **Present, best-effort.** Tool outputs/errors/metadata are redacted at the `ToolRegistry` boundary for common API key/token/password shapes before they reach transcripts, terminal output, hooks, or later model context. This is not a full DLP system. |
| **Audit log** | **Absent.** (Roadmap P4) |
| **Linux CI** | Configured (GitHub Actions, `swift:5.10` container); not yet run against a remote. |

## Reporting

Security issues in AgentCore: handle privately with the maintainer before disclosure. Do
not file exploit details in a public tracker.

## Label

**PILOT-READY** (security infrastructure). A kernel-enforced sandbox tier now exists on
**macOS** (opt-in egress-deny + write-confinement). Enterprise-blocked by: no Linux sandbox
parity (fails closed there), no resource limits, no Linux CI *run* (configured, unrun), no
path-parser fuzzing, no per-domain egress allowlist. On macOS with the sandbox enabled it is
suitable for more autonomous use; on Linux it remains trusted-local until the bubblewrap tier
lands.
