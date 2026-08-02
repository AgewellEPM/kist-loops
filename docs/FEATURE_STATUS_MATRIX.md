# Kist Feature Status — 2026-08-02

This is the current, conservative status sheet. Executable tests and the installed binary's
provenance manifest outrank prose when they disagree.

## Trustworthy core

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
| Context compaction | Built | One preparation path for text/native histories; native call/result groups remain atomic and the current raw objective is reasserted. Its conservative character allowance bounds message history, not the separate system prompt/tool schemas/provider output budget. |
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
