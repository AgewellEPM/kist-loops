# AI Council Result

## Goal
Critically review the "A+ hardening" work just shipped to kist (a provider-agnostic terminal AI coding agent in Swift) and identify weaknesses, bugs, security holes, and what is MISSING. The work spans 3 sprints, all Codex-gated and merged:

SPRINT 1 (safety floor): (S1) agentskills.io `allowed-tools` capability scoping — a loaded skill scopes the session to its declared tools + an always-safe read-only set, enforced at ToolRegistry.execute. (S3) static skill scan — HARD-reject invisible Unicode injection (Tag/bidi/zero-width chars) at validate, SOFT-warn injection heuristics (secret exfil, override phrases) at load. (C3) capped the previously-uncapped AICouncil/research token budget.

SPRINT 2 (trust spine): project skills are UNTRUSTED until their SHA-256 content hash is pinned in .kist/skills-trust.json; an untrusted loaded skill is forced READ-ONLY (its self-declared allowed-tools is IGNORED) so a malicious skill cannot grant itself run_command. Trust is re-derived at LOAD from the exact bytes (TOCTOU-safe); untrusted dominates (no trusted skill lifts it). CLI: --trust-skill, --skills.

SPRINT 3 (cost governance): (C1) --max-cost dollar ceiling priced live per provider; either token or $ cap halts. (C2) atomic reserve-before-spend on BudgetLedger (reserve/commit) wired into the agent loop + fleet + generate tool — closes the parallel-overspend TOCTOU.

Be BRUTALLY honest and concrete. For each finding give severity and a fix. Then rank the top 5 things still missing or weak across this work, and what we should build next. Do NOT be diplomatic — find the holes.

## Researcher
_role: worker · model: mimo_

**Critical Findings:**

- **Severity: High** – `allowed-tools` enforcement at `ToolRegistry.execute` is runtime-only; a malicious skill could still *attempt* to call a disallowed tool, triggering an error but potentially leaking side effects (e.g., network call before check). **Fix:** Enforce at the tool-call *dispatch* layer, not just execution.

- **Severity: High** – Trust pinning via `.kist/skills-trust.json` is file-based and local; a compromised repo could modify this file to trust a malicious skill. **Fix:** Pin trust to a signed manifest or use a separate, immutable trust store (e.g., user-level config outside repo).

- **Severity: Medium** – Static scan for Unicode injection is good, but only at *load* time. A skill could dynamically generate malicious strings at runtime. **Fix:** Add runtime sanitization for all tool inputs/outputs.

- **Severity: Medium** – `--max-cost` halts on dollar ceiling, but no *alerting* or *graceful degradation*; abrupt halt may leave agent in inconsistent state. **Fix:** Implement cost-warning thresholds and checkpointing before halt.

- **Severity: Low** – `BudgetLedger` atomic reserve-before-spend closes TOCTOU, but assumes provider pricing is static and known; dynamic pricing (e.g., spot instances) could still cause overspend. **Fix:** Add pricing volatility buffer or real-time price fetch.

**Top 5 Missing/Weak Areas:**

1. **No runtime tool-call sandboxing** – Even with allowed-tools, tools like `run_command` need OS-level sandboxing (e.g., seccomp, containers) to prevent system compromise.
2. **No skill dependency scanning** – Skills could import malicious packages at runtime; need static analysis of dependencies.
3. **No audit trail for tool calls** – Critical for debugging and security forensics; log all tool invocations with context.
4. **No user consent for high-risk actions** – Even trusted skills should prompt for confirmation on destructive operations (e.g., file deletion).
5. **No provider-side cost validation** – Relying on local cost tracking; providers could bill differently; need reconciliation with provider billing APIs.

**Next Build Priority:** Implement runtime sandboxing for high-risk tools (especially `run_command`) and add an audit log for all tool calls.

## Architect
_role: planner · model: grok_

- **Next primitive**: ToolDispatch + AuditLog (enforce allowed-tools + trust at call site before any execution; emit immutable per-call record with skill hash, args hash, cost reserve)
- **System boundary**: kist core agent loop + ToolRegistry only; OS-level sandbox (seccomp/container) and signed trust manifest live outside this boundary
- **Do not build yet**: dependency scanning, runtime string sanitization, provider billing reconciliation, cost-warning checkpoints, or dynamic pricing buffers
- **Direction**: harden dispatch + audit first; everything else remains research until dispatch is the single choke point

## Coder
_role: coder · model: deepseek_

**Likely modules**
- `ToolDispatch` – new entry point that every tool call goes through before `ToolRegistry.execute`; enforces allowed-tools + trust read-only override; emits an immutable record to `AuditLog`.
- `AuditLog` – structured logger writing to a file (e.g., JSONL) with call metadata: skill hash, tool name, arg digest, cost reserve, timestamp, trust status.
- `ToolRegistry` – altered to route calls exclusively through `ToolDispatch` (internal `execute` becomes private).
- `BudgetLedger` – no change needed, but its reserve/commit flow must be called from `ToolDispatch` before tool execution.
- `SkillsManager` – trust pin look-up is already TOCTOU-safe; must feed the skill hash and trust status to `ToolDispatch`.

**Tests**
- Unit: `ToolDispatch` with mocked `ToolRegistry` – verify disallowed tool throws before execution; verify untrusted skill yields read-only override even if skill declares a broader set; verify reserve-before-spend is called exactly once per dispatch; verify an `AuditLog` entry is written on every attempt (success/fail).
- Integration: wire a real `ToolDispatch`+`AuditLog` into the agent loop; run a small session with trusted and untrusted skills; assert that `run_command` is never invoked for untrusted ones and that the audit log contains correct entries.
- Edge-case tests: nested tool calls (generate tool invoking another tool) – ensure `ToolDispatch` re-enters safely and budget reserve is still atomic; concurrent dispatches from fleet – verify log file writes are thread-safe (use OS-level append locking).
- Migration test: run existing skill+tools tests to confirm no regressions in behavior for already-trusted skills with the new dispatch path.

**Migration risks**
- **Breaking change in call flow** – any code currently calling `ToolRegistry.execute` directly must switch to `ToolDispatch`. This includes the agent loop, `generate` tool, and potential future extensions. Risk of missing a call site, causing bypass of enforcement. Mitigation: make `ToolRegistry.execute` private/internal and provide a linter rule or grep for direct calls.
- **Performance overhead** – adding audit logging per tool call (especially high-frequency calls) could slow down loops. Mitigation: use an async, buffered log writer with a queue; ensure writes don’t block the agent loop.
- **Cost accounting sync** – since `BudgetLedger.reserve` moves before execution, any failure after reserve but before completion must correctly commit or rollback; the dispatch layer must integrate with the existing `BudgetLedger` API without double-counting. Need to ensure `commit` is called on success, `rollback` on caught error.
- **Trust pin revalidation** – if trust status is re-derived at load and cached, but the dispatch layer reads the cached value, TOCTOU is still safe; just ensure no stale skill hash is used for audit entries.
- **File-based audit log** – risk of growing unbounded; need a rotation/retention policy, at minimum truncation after session end or a configurable max size. Log format must be strict to avoid injection (use structured JSON, escape any user-supplied data).

**Smallest first implementation**
1. Create `AuditLog` as a simple struct that appends a line to a file (JSONL) with `skillHash`, `toolName`, `argsDigest`, `trusted`, `reserveAmount`, `timestamp`. Use `FileHandle` with `seekToEnd` + write; protect with a serial DispatchQueue to avoid interleaved writes.
2. Create `ToolDispatch` with a single public method `dispatch(skillHash: String, trusted: Bool, toolName: String, args: [String: Any], budgetLedger: BudgetLedger) async throws -> ToolResult`. Inside:
   - Look up `allowedTools` from skill meta (if untrusted, force read-only set).
   - Assert `toolName` is in allowedTools.
   - Call `budgetLedger.reserve` for estimated cost of this tool (needs a cost estimator or use a default token cost).
   - On success, proceed to `ToolRegistry.executeInternal`; catch error, rollback, and log.
   - Log the attempt regardless of outcome.
3. Modify `ToolRegistry` to rename existing `execute` to an internal method, making it only callable by `ToolDispatch`. The agent loop’s tool call path now calls `toolDispatch.dispatch(...)`.
4. Add one integration test: a small agent session that tries to use `run_command` from an untrusted skill, confirms the dispatch rejects it and logs the attempt.

This is the smallest shippable increment that closes the critical gap: enforces allowed-tools + trust BEFORE any side effect, and adds an audit trail for every tool invocation.

## Critic
_role: critic · model: deepseek_

- **Finding: Cost estimation for reserve is undefined, risking ineffective budget capping.**  
  Severity: High. The dispatch layer calls `budgetLedger.reserve(estimatedCost)` but provides no estimator beyond a “default token cost.” Without per-tool, per-provider cost maps, the reserve may be too low (overspend) or too high (deadlocks budget, blocks progress).  
  **Fix:** Ship a cost estimator that queries provider pricing for each tool or uses statically configured cost tables, with a configurable safety multiplier; integration-test reserve accuracy under varied tool usage.

- **Finding: Budget ledger rollback gaps after tool execution failures.**  
  Severity: Medium. The dispatch path reserves, then executes, then commits/rolls back. If the tool partially performs side effects and then throws, the reserve is rolled back but the executed side effects may be permanent, leaving ledger state inconsistent with actual spend. Also, if the process crashes after reserve but before commit/rollback, the reserved amount could leak forever.  
  **Fix:** Use an atomic `reserve` with a timeout or session-scoped lease; ensure the agent loop can recover stale reserves on restart. Log all lifecycle transitions (reserve, commit, rollback, expire) in AuditLog.

- **Finding: Audit log resilience and performance not addressed.**  
  Severity: Medium. Writing directly to a file with `FileHandle.seekToEnd` on a serial queue under concurrent tool calls risks blocking the agent loop during disk I/O spikes. A crash mid-write can produce a corrupt JSON line.  
  **Fix:** Use a lock-free, ring-buffer logger with asynchronous flush; append complete newline-delimited records atomically (write to temp and rename, or use `os_log`). Set a max file size with rotation after session end.

- **Finding: Trust status passed as a cached `Bool` may be safe, but audit traceability weakens without re-derivation context.**  
  Severity: Low. The dispatch receives `trusted: Bool` derived at load time. If the trust manifest is tampered with after load but before dispatch, the cached value remains correct for the in-memory skill, so enforcement is safe. However, the audit log records only the boolean; it cannot prove the trust derivation was valid.  
  **Fix:** Include the skill hash and the trust manifest version/hash in each audit entry, enabling post-hoc verification that the trust status matched the pinned set at load time.

- **Finding: No argument-level validation for sensitive tools after allowed-tools check.**  
  Severity: Medium. The dispatch blocks forbidden tool names but does not inspect arguments. A trusted `run_command` could pass `rm -rf /` or exfiltrate secrets. The static scan only catches known patterns in skill definitions, not runtime argument injection.  
  **Fix:** (Future) Extend the dispatch to accept per-tool argument sanitizers; initially, for `run_command`, block known-dangerous patterns or require a pre‑execution sandbox; this is outside the current proposal but remains a critical gap.

- **Finding: Breaking change may leave hidden direct-call paths to `ToolRegistry.execute`.**  
  Severity: Medium. The proposal makes `execute` internal, but any existing extension, plugin, or future developer calling it directly would bypass all dispatch checks. There’s no guarantee all call sites are updated in a codebase that may have external consumers.  
  **Fix:** Add a compile-time guard (e.g., a linter rule or a `@unknown default` trap) to prevent direct calls; add a smoke test that tool invocations outside dispatch fail.

---

**Top 5 missing or weak areas across all the A+ hardening work (post‑dispatch):**

1. **OS‑level sandboxing for `run_command` and other side‑effecting tools**  
   *Severe; no isolation prevents a trusted skill from compromising the host.*  
   Build next: integrate `sandbox‑exec` with seccomp or a minimal container; make untrusted skills’ `run_command` always run in a write‑disabled, network‑restricted sandbox.

2. **Accurate cost estimation integrated with reserve‑before‑spend**  
   *High; the current proposal’s placeholder default cost undermines the entire budget governance sprint.*  
   Ship a cost estimator module that uses live provider pricing data and tool‑specific models; tie into BudgetLedger’s reserve calls.

3. **User consent gateway for high‑risk actions**  
   *High; file deletion, network exposure, and sensitive command execution should require explicit approval, even from pinned trusted skills.*  
   Add a consent layer in the dispatch (or a pre‑dispatch hook) that prompts the user with a clear summary and waits for confirmation before proceeding.

4. **Dependency/import scanning for skills**  
   *Medium; a skill can silently import malicious packages that bypass all code‑scanning.*  
   Create a static analyser that inspects declared dependencies (e.g., Swift Package Manager manifests) against known‑malicious signatures, blocking loads when high‑confidence threats are found.

5. **Runtime tool‑input sanitization**  
   *Medium; argument‑level attacks remain possible even with allowed‑tools enforcement.*  
   Extend the dispatch to apply per‑tool input validators; at minimum, block shell metacharacter patterns for `run_command` and enforce allow‑lists for file paths.

## UX
_role: worker · model: mimo_

- **Magic moment**: Instant, clear feedback when a skill is blocked or trust-pinned — e.g., "🔒 Skill 'X' loaded (untrusted, read-only)" or "🚫 Tool 'run_command' blocked for untrusted skill."
- **Confusing commands**: `--trust-skill` and `--skills` flags are opaque; no inline help or examples. Users won't know how to pin trust or list skills without docs.
- **Missing feedback**: No real-time cost tracking or warnings before hitting `--max-cost`; abrupt halt feels like a crash. No audit log visibility — users can't see what tools were called or why they were blocked.
- **Smallest natural interface**: A `kist status` command showing: active skills (trusted/untrusted), current cost vs. budget, and last few tool calls with outcomes. Add `kist trust --list` and `kist trust --pin <skill>` for clarity.
- **Top 5 missing/weak (UX focus)**:
  1. **No user consent for high-risk actions** — even trusted skills should prompt before destructive ops (e.g., "Allow 'run_command' to delete files? [y/N]").
  2. **No cost visibility** — users can't see spend until halt; add a live cost ticker or `kist cost` command.
  3. **No audit log access** — users can't review tool calls; add `kist log --last 10` or a session summary.
  4. **No skill management UI** — `--trust-skill` is CLI-only; add interactive prompts or a `kist skills` dashboard.
  5. **No error recovery guidance** — when halted by cost or blocked tool, suggest next steps (e.g., "Increase budget with --max-cost $X" or "Pin skill with --trust-skill Y").

## Memory
_role: memory · model: deterministic_

No project memory found. Treat this as a fresh council decision and save the outcome.

## Decision, Task Analysis, And Kanban
Decision:
- Build the minimal ToolDispatch + AuditLog choke point (enforce allowed-tools + trust read-only override + reserve-before-spend + immutable JSONL audit) with ToolRegistry.execute made private; nothing else.

Task Analysis:
- Why this is the next move: It is the single point that closes the runtime bypass and missing audit gaps identified across Researcher/Critic findings before any further hardening.
- Dependencies and risks: Depends on existing skill meta, BudgetLedger.reserve, and SkillsManager hash; risks are missed direct-call sites and placeholder cost estimation (both must be tested in the first increment).
- What to avoid: OS sandboxing, consent prompts, dependency scanning, runtime sanitization, cost estimator, or any UX commands.

Kanban Board:
| Status | Task | Owner | Acceptance |
| --- | --- | --- | --- |
| Ready | Implement ToolDispatch + AuditLog + private execute | builder | Unit test rejects disallowed/untrusted tool before any execute; integration test shows audit entry + reserve call for valid path; no direct execute bypass possible |
| Backlog | Verify cost-estimation accuracy for reserve | researcher | Documented per-tool cost table or provider query with safety multiplier; integration test shows reserve prevents overspend on sample tools |

Next Builder Brief:
- Create AuditLog (JSONL append via serial queue) and ToolDispatch.dispatch(skillHash, trusted, toolName, args, budgetLedger) that performs the allowed-tools/trust check, calls reserve, then ToolRegistry.executeInternal, logs every attempt, and make ToolRegistry.execute private; add the one specified integration test.