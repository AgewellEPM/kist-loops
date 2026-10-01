# Kist Feature Status — 2026-08-02

This is the current, conservative status sheet. Executable tests and the installed binary's
provenance manifest outrank prose when they disagree.

## Lightweight on-demand host runtime — 2026-10-01

`Tools/kist_local_runtime/` preserves the installed host controller and its live
verification receipts. `kist-local-ai auto` enables a small loopback gateway;
`off` (also `kill` or `freeze`) stops local Ollama workers and disables startup;
`status` reports managed activity and separately started Ollama processes.
The controller loads one installed model for a native Ollama request, forces
immediate unload, and terminates its private process group after completion,
disconnect, timeout, or a memory-pressure warning. Observing inventory does not
load a model. The next inference incurs a new cold start.

Luke's 16 GB M4 profile permits at most 2 GiB of model weights, 4096 context
tokens and 1024 output tokens. Large models, local vision, downloads, concurrent
inference and OpenAI-compatible API routes are refused. Cloud fallback belongs
to the caller; the gateway does not send prompts to a cloud service. The previous
9B local-first rollout is superseded on this host, and Kist's cloud configuration
remains unchanged. This utility does not promote the pending Swift candidate.

The installed layout is `~/.kist/local-runtime/runtime.py` with `config.json`,
`~/bin/kist-local-ai`, and the manual LaunchAgent
`~/Library/LaunchAgents/com.kist.local-ai-runtime.plist`. The source directory
includes the host's configuration and plist examples plus the guarded legacy
launcher. Model weights remain on PRO-G40 and are not versioned. The explicit
control command refreshes a metadata-only catalog; the private Ollama backend
independently checks its digest and size before inference. No macOS permission
or Kist autonomy setting was widened. Separately launched Ollama processes are
reported and stopped by `off`; the gateway cannot prevent another application
from launching its own server on another port.

Live checks covered Qwen2.5 0.5B and Llama3.2 1B GPU inference and cleanup, 9B
refusal without loading, concurrent-request refusal, killing an active request,
and client-disconnect cleanup in 0.42 seconds. No worker remained at final
inspection. The complete Swift candidate is not fully verified: its last full
run had 22 assertion failures across three test cases. The deployment fixture
passed after its provenance-output fix; details remain in the runtime's
`verification/validation-status.json` rather than being treated as a green suite.

## Goal map candidate — 2026-09-30

`/goalmap` (also `/goal-map` or `/goals map`) reads the current workspace's board
locally, with no model call. It shows the next selected task, blocked work and reasons,
tasks left active by an earlier session, and missing acceptance, verification, or evidence
references. `/goalmap <id>` inspects a task without starting it. The agent can request the
same bounded view through `tasks(action="map", id=<optional task id>)` in read-only modes.

The overview and `next` share task selection: current-session work, then queued work
other than research, then queued research. Stale tasks require explicit selection.
Explicit invalid task IDs fail without starting a different task. An invalid `/tasks clear`
argument leaves the board unchanged. Spaces, tabs, and newlines separate slash-command
arguments consistently. Inspection aliases preserve the previous turn's logs and usage.

The map reads at most 4 MiB, refuses malformed or linked boards, bounds rendered details,
and never treats a board label or evidence reference as an accepted completion receipt.
It does not execute verification or test whether an attached path still exists. There is
no dependency graph in the board schema; the map does not invent dependencies.

This is a local source candidate, pending sanctioned production promotion. The prototype
`--tui` command subset does not expose the goal map; use the standard REPL.

## Trustworthy core

### Ollama adapter — 2026-09-30

The Ollama adapter carries native tool schemas, assistant calls with object arguments,
and matching tool results. It also carries inline user images for supported vision
models, JSON/schema output requests, and Qwen3.5's disable-thinking control. Invalid
tool history, error frames, and streams without `done:true` fail explicitly.

Automatic native routing currently covers `qwen3-vl` and `qwen3.5`; unknown templates
retain the text protocol. The installed `qwen2.5-coder:7b` advertised tool support but
returned a call as ordinary text in the Ollama 0.32.3 canary, so it remains on the text
path. `qwen3-vl:4b-instruct` passed a real native call/result canary on the M4 Mac mini.
This canary is not proof of coding quality, long-running autonomy, or Claude/GPT parity.
`qwen3.5:9b-q4_K_M` also passed the installed native round trip. Task qualification
is recorded separately; a successful tool canary does not qualify a replacement model.

### Local-first routing candidate — 2026-09-30

With `provider: ollama`, an explicit local model, `autoRouting: true`, and
`localFirst: true`, routine turns return to the local model. Difficult reasoning
requests and oversized requests can select a configured, available cloud provider.
CLI model/provider pins and per-role pins remain authoritative. The launcher does
not inject its saved team when an explicit model/provider flag is present.

Ordinary REPL builds use the typed Builder route selected from the existing effort
assessment, instead of forcing a second plan for every request. Explicit `/plan-execute`,
resume and CLI route pins remain authoritative. Direct execution respects both the
CLI iteration cap and the effort cap. Build routes share local-first model selection
before sealing a plan. A known local planning-shape
failure can move the producer team to cloud once, under the same budget, scope and
validator. Authorization, protected paths, budget and cancellation failures do not
qualify. Duplicate file operations cannot be repaired without changing authority,
so their schema-repair call is skipped. The initial planner prompt includes the complete
output schema and supported structured command forms. Bare interpreters and inline
interpreter evaluation are rejected before work, under the execution tool's existing policy.
Execution contracts retain exact model IDs, including `Q4_K_M`; independence comparison
keys and execution identities serve different purposes. The chosen outer reviewer
is preserved when the advisory inner critic follows the producer.

Known Qwen3.5 and Qwen3-VL templates allocate 16,384 runtime tokens by default.
The history allowance reserves instructions, serialized schemas and output, with
tokenization headroom. Context estimates are approximate; an obviously oversized
request is rejected before contacting Ollama. Capsules retain objective/provenance
and complete native tool exchanges. Intent classification caps output at 384 tokens
with thinking disabled. Batch file reads accept both encoded strings and decoded
arrays through the same size, range and confinement checks. The 512-token advisory
goal verdict disables hidden thinking. Local council lenses run sequentially against
Ollama, with the existing four fresh conversations, per-call deadline, quorum and veto.
A literal structured `python3 -m json.tool <file.json>` is a data-validation receipt,
not a source build/test: it can bind a final artifact replay only when the trajectory
contains no source or unknown-target mutations. Concurrent or stale checks do not qualify.

Chat, native-tool and embedding requests send `keep_alive: 0`: Ollama loads weights
on demand and releases them after inference when its other clients are finished.
The daemon remains available; Kist never kills another client's runner. Local-first
can acquire a missing, qualified Qwen artifact on demand through Ollama. Admission
checks host RAM and current macOS memory pressure; acquisition checks official Hugging
Face metadata, license, destination disk space, bounded download size and the exact
qualified manifest digest. Stored matching weights work offline. Unknown or changed
artifacts require vet/onboard; discovery does not automatically promote arbitrary Hub models.
Scout includes the current Qwen3.5 9B and 4B candidates; 4B remains unqualified for coding.

The candidate completed a real Qwen coding fix with unchanged tests and independent
cloud review, and a card workflow using cloud planning fallback plus local review.
Those bounded receipts do not establish general model parity. Shared-server latency
and incomplete vision qualification remain limitations.

This candidate requires sanctioned promotion and installed workflow evidence before
default migration is credited. Local-only card and coding qualification has exposed
failures; no general Claude/GPT parity or unattended-autonomy claim is made.

| Capability | Status | Current contract |
|---|---:|---|
| Conversational REPL | Built | One existing REPL and control plane; this reliability pass adds no replacement/v2 mode. |
| Bottom response bar | Built | Behavior unchanged: native terminal scrollback; pinned while idle. During-turn sticky capture is opt-in with `--sticky-turns` and remains off by default. |
| Turn intent/outcome | Built | One resolved intent is reused by routing, prompt compilation, progress monitoring, checkpoints, and replay. |
| Native + text tool loops | Built | Both paths share tools, approvals, resume reconciliation, progress policy, verification, and context preparation. |
| Tool-effect accounting | Built | Argument-aware effects are recorded once and consumed by trajectory analysis and completion verification. A successful `ls` is not build progress or proof. |
| Verify-before-done | Built | Source mutations require an executed build/test after the final source change. Unavailable execution is reported as unverified, never promoted to success. |
| Plan attempt evidence | Built | Every invocation attempt is retained, including a failed call later replaced by a repaired retry. Dependency-wave calls share a causal phase, so a verifier concurrent with a possible source mutation is not accepted as later proof; verification history also carries across replans. |
| Resume proof boundary | Built | Stale pre-resume build/test proof cannot authorize mutation completion. Where proof could be stale or workspace binding is absent, resume adds a conservative unbound-workspace marker and requires fresh verification against the current workspace state; it never masks a latest failed mutation. |
| Build/oracle inputs | Built | Recognized build, dependency, test, and CI manifests, configuration files, workflows, and lockfiles count as verification-requiring source inputs when changed. |
| Context compaction | Built | One preparation path for text/native histories; native call/result groups remain atomic and the current raw objective is reasserted. Its conservative history allowance reserves system instructions, serialized tool schemas and provider output; estimates retain tokenization headroom. |
| ESC + type-ahead | Built | Direct, plan, council, research, and fleet turns use the same interrupt/queue semantics. |
| Task-board freshness | Built | In-progress tasks carry a start time; stale prior-session work cannot become the implicit current topic. |
| Replay/proof stream | Built | Local replay distinguishes route, review, verification, and the single finalized turn result. |

## Review policy

| Behavior | Status |
|---|---:|
| Ordinary Q&A returns one answer | Default |
| Build/change review | Automatically attempted after a confirmed workspace mutation when a turn-scoped textual Git delta exists; a missing/non-textual subject is reported as incomplete, never clean. Also explicit via `/copilot`, a named team, or `/ultra`. |
| Automatic repair | Requires `autoFix` authority; enabled for the default build-review policy and disabled by `/copilot off` |
| Repair owner and bound | Original author; at most three rounds |
| Missing reviewer response | Incomplete, never a clean vote |
| Review wording | Advisory assessment only; it never claims executed verification |

## Built orchestration and foundations

- Checkpoint/resume with interrupted-action reconciliation.
- Sandboxed file, command, search, web, browser, media, MCP, and specialist-tool plumbing.
- Plan/execute, council, research, supervised fleet, Captain gates, learning/retrieval, and task board.
- Native provider tool calling with structured-text fallback for compatible/local models.
- Local proof/replay, usage spans, failure analysis, and deterministic completion gates.

These are capabilities, not a claim that every model/provider combination behaves equally well.
Provider reachability, credentials, terminal behavior, and OS sandbox strength still vary at runtime.

## Known gaps and deliberate limits

- Kist remains pilot software, not 1.0.
- macOS has the production OS-sandbox path; Linux parity and per-domain network allowlists remain incomplete.
- The native-scrollback bar cannot remain fixed while the user scrolls terminal history. Kist deliberately does not switch the normal REPL to an alternate-screen UI.
- `--sticky-turns` is experimental and off by default while resize/terminal coverage matures.
- Model review is advisory. Only executed deterministic checks establish verification.
- Long-running orchestration still needs broader provider-fault and real-terminal soak coverage.

## Historical documents

Roadmaps and dated audits under `docs/` describe intent or the state at their timestamp. They are not
deployment truth. In particular, `CAPTAIN_UX_OVERHAUL_PLAN_2026_07_28.md` is a historical plan.
