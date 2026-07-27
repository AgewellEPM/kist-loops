# App Reconstruction & Hardening Pipeline — Plan (2026-06-28)

Luke's vision: mirror an app/website you own → rebuild it EXACTLY in an isolated sandbox (code and all)
→ run pentester-grade analysis to find vulnerabilities → harden / redesign / upgrade the code paths.
Easy as 1-2-3. A defensive security-engineering loop on your own assets.

---

## ⚠️ GUARDRAIL FIRST (non-negotiable — build before anything else)

This capability is DUAL-USE. Mirroring + scanning a target you don't own/aren't authorized to test is a
CFAA violation and a copyright problem — it would put you and the company at real legal risk. So the tool
is **defensive-by-construction**:

- **Authorization scope** (`.kist/security-scope.json`): an explicit, signed list of domains / repos / app
  bundle-ids the user OWNS or has WRITTEN authorization to test, with a note/evidence per entry. Every
  acquire/scan tool checks the target against this scope and **HARD-REFUSES anything out of scope** ("not in
  your authorized scope — add it with proof of ownership"). No scope entry ⇒ no mirror, no scan.
- **Isolation always**: all reconstruction + testing happens in a throwaway worktree + Seatbelt/(Linux)
  sandbox. The rebuilt app NEVER touches production or the network unless an authorized-live-target flag is
  explicitly set.
- **Passive vs active tiers**: static analysis of a mirror you already hold = low gate. ACTIVE/intrusive
  scanning (DAST against a live host) = high gate — requires an in-scope target AND explicit per-run
  confirmation. Default to the sandboxed rebuild, never the live target.
- **Purpose is hardening, not exploitation.** Findings produce fixes. The system refuses to weaponize
  (e.g. it won't generate working exploit payloads aimed at a third party); it reports the weakness + the
  remediation.
- **Honest reconstruction limit**: client-side (HTML/CSS/JS/bundles) is fully recoverable from a mirror;
  SERVER-side logic is only INFERRED from behavior — you can't recover a black-box server's source. Full
  source-level rebuild only exists for YOUR OWN repos. The tool states this, never pretends otherwise.

---

## The pipeline — 5 stages

### Stage 1 — ACQUIRE (mirror/clone the target)  [scope-gated]
- **Repo path**: `git clone` your own source (the complete, honest case).
- **`mirror_site` tool**: recursive fetch of HTML/CSS/JS/assets (in-process URLSession or rate-limited
  shell), robots-aware, depth/size-capped, SSRF-guarded, **scope-checked**. Captures the client-side app.
- **Rendered capture**: `BrowserTool`/Playwright (already built) loads the running app → DOM + bundled JS
  for SPAs that assemble client-side.
- Output: a local, sandboxed mirror of the target's observable code + assets.

### Stage 2 — RECONSTRUCT (regenerate the exact app, editable)
- Turn the mirror into a BUILDABLE local project: beautify/de-minify JS, map routes + asset graph, infer
  the framework, scaffold a runnable local copy. `reconstruct_app` capability.
- Result: an editable, buildable copy in the sandbox you can re-run, diff, and harden.
- (Server-side: scaffold a behavior-faithful stub from observed responses; flagged as inferred, not real.)

### Stage 3 — ISOLATE (sandbox the rebuild)
- The reconstructed app runs in the isolated worktree + sandbox (no egress, confined writes) — reuse kist's
  `--sandbox` + worktree isolation. Testing it cannot harm anything.

### Stage 4 — ANALYZE (pentester-grade)  [SAST low-gate, DAST high-gate]
- **Static (SAST)** — extend the existing `SecurityAuditTool`: secrets, injection sinks (SQLi/cmd/template),
  XSS, insecure deserialization, dependency CVEs, auth/authz gaps, CSP/security headers, CORS, exposed
  endpoints/keys in bundles.
- **Pentester checklist** — map to **OWASP Web Top 10** (broken access control, crypto failures, injection,
  insecure design, security misconfig, vulnerable components, auth failures, integrity failures, logging
  gaps, SSRF) + a core pentest playbook. (Complements the existing `GovernanceReportTool` → OWASP Agentic.)
- **Dynamic (DAST)** — probe the checklist against the SANDBOXED rebuild (safe) or an authorized live target
  (high gate). Reports the weakness + repro evidence + fix — not a weaponized exploit.
- Output: a structured vulnerability report (severity · location · evidence · remediation).

### Stage 5 — HARDEN (rebuild / redesign / upgrade the code paths)
- For each finding, the agent proposes a hardening patch via **`apply_patch`** (just built) on the
  reconstructed/own code, then **re-scans to confirm the fix** (regression: the vuln is gone).
- "Redesign and upgrade the code paths we see" — rewrite vulnerable paths; the council/captain gate verifies
  the hardening before it's accepted (no fabricated "fixed" claims — re-scan is the proof).

---

## Reuses what we already have
- `SecurityAuditTool` + `GovernanceReportTool` (security analysis) — extend with OWASP Web Top 10.
- `BrowserTool`/Playwright (capture the rendered app), `fetch_url`/`web_search` (in-process, sandbox-safe).
- Worktree + Seatbelt sandbox (isolation), Linux sandbox (Wave-3 gap) for full Linux parity.
- `apply_patch` (Wave 1.2) — the hardening edits; `search_code` (ripgrep) — find the sinks.
- Council/captain + `GroundedReviewValidator` — verify hardening, no fabricated findings.
- NEW: authorization scope, `mirror_site`, `reconstruct_app`, OWASP-web checklist, the pipeline orchestrator.

## Phases (each: build → test → adversarial Codex → ff-merge)
1. **Authorization scope + guardrail** — the safety foundation (FIRST).
2. **Acquire** — `git clone` + `mirror_site` (scope-checked, capped, SSRF-guarded).
3. **SAST expansion** — OWASP Web Top 10 in `SecurityAuditTool`.
4. **Reconstruct** — mirror → buildable project.
5. **Harden loop** — finding → `apply_patch` → re-scan-to-confirm.
6. **DAST** — gated, against the sandboxed rebuild first; authorized-live-target last & loudest.

## One-paragraph framing
Most of the machinery exists: sandboxed isolation, a security auditor, a browser capture tool, ripgrep
search, atomic apply_patch, and a verify-before-trust spine. This pipeline wires them into a 1-2-3 loop —
**acquire → reconstruct → analyze → harden** — for apps you OWN. The single thing that makes it safe to
ship (and the first thing to build) is the authorization scope: it keeps a genuinely powerful capability
pointed at hardening YOUR products, never at attacking someone else's. Built that way, it's a defensible,
high-value security-engineering tool; built the other way, it's a liability. We build it the first way.
