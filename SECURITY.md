# Security Policy

Mythos is a **developer tool** — a terminal coding/agent shell that plans, edits files, and (when you
opt in) runs commands in *your* project, on *your* machine, with *your* API keys. It is built to be a
better dev assistant, **not** an attack tool. This document states the posture, the responsible-use
expectation, the privacy stance, and how to report a vulnerability.

## TL;DR

- **No telemetry. No phone-home.** Mythos sends your prompts and code only to the AI provider *you*
  configured (via *your* key), and nowhere else. Nothing goes to us. There is no analytics, no usage
  beacon, no crash reporter. (Grep the source: the only outbound network calls are to the provider
  endpoint you chose and the `fetch_url` tool, which is SSRF-guarded — see below.)
- **Safe by default.** The dangerous capabilities are **off** until you explicitly turn them on.
- **No offensive capability shipped.** Mythos has no scanners, no exploits, no attack tooling. It is a
  general dev agent (read / write / edit / search / generate / run). What you point it at is on you.

## Responsible use

Mythos can read, write, and run code. Use it **only on systems you own or are explicitly authorized to
work on.** Do **not** use it to access, test, or attack systems you do not have written permission for —
that's not what it's for, and in most jurisdictions it's a crime (e.g. the U.S. Computer Fraud and Abuse
Act). Using a general dev tool to do unauthorized security testing is misuse, the same way it would be
with `bash`, `python`, or `curl`. The maintainers do not condone it and the license disclaims liability
for it (see LICENSE).

If you want to do **authorized** security work, that's a different, scoped product concern — it is not in
this open-source core, and it should never be run without signed authorization for the target.

## Safe defaults (what's off until you opt in)

| Capability | Default | Opt-in |
|---|---|---|
| Shell / `run_command` | **OFF** | `--allow-shell` |
| Approval prompts on write/edit/run | **ON** (interactive) | `--yolo` disables them |
| Filesystem reach | **Confined to the project root** (symlink-safe `openat`/`O_NOFOLLOW`) | — |
| `fetch_url` network reach | **SSRF-guarded** (blocks loopback, RFC-1918 private ranges, link-local, cloud-metadata IPs, and redirects) | — |
| OS sandbox for shell | available | `--sandbox` (macOS Seatbelt: egress-deny + write-confine) |
| Spend | bounded by `--budget <tokens>` (honest-fail at the cap) | — |
| Autonomous fleet / "Captain" (if/when enabled) | **OFF; never arms without an explicit token** + one-way kill switch | explicit arm |

Turning off a guardrail (`--yolo`, `--allow-shell`) is loud and intentional. Leave them on unless you
know why you're disabling them.

## Threat model (summary)

- **The model is untrusted.** Tool arguments are treated as attacker-influenced (prompt injection from a
  malicious file, a poisoned web page, a shared board). Every tool validates its inputs; tool output is
  wrapped in an untrusted-data envelope and the agent is instructed never to obey instructions found
  inside it.
- **The project root + host user are trusted.** Mythos confines actions *to* a root you own; it is not a
  sandbox *against you* — if you `--yolo --allow-shell` and tell it to do something destructive in your
  own repo, it can.
- **Provider keys are yours.** They're read from your environment/keychain, sent only to the provider
  endpoint, never logged in full, never transmitted to the maintainers.

The full engine-level threat model lives in [`Sources/AgentCore/SECURITY.md`](Sources/AgentCore/SECURITY.md).

## Reporting a vulnerability

If you find a security issue (a confinement escape, an SSRF-guard bypass, a prompt-injection that defeats
the untrusted-data envelope, a key-leak path, etc.):

- **Do not** open a public issue with exploit details.
- Email the maintainer (see the repository profile / `Cargo`-style contact in the README) with a
  description, repro steps, and impact. Please allow reasonable time for a fix before public disclosure.
- Good-faith research on **your own** instance is welcome and appreciated.

## Supported versions

Mythos is pre-1.0 (PILOT). Security fixes target the latest `main`. Pin a commit if you need stability.
