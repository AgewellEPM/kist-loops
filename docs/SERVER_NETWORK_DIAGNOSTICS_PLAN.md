# Server & Network Diagnostics Agent — Plan (SRE co-pilot + business tool) — 2026-06-29

Luke's idea: point kist at a server/network issue you're having → it determines how well things are
running, diagnoses the root cause, and guides you to a fix. Then package it as a tool businesses can use.
This is the OPS sibling of the security pipeline — same shape (collect → diagnose → VERIFY → gated-fix),
and the same edge: a grounded, no-fabrication diagnosis in a world of "have you tried restarting it."

---

## What we already have / what's missing
- ✅ `run_command` (diagnostic commands), sandbox, the **verify spine** (grounded, no-fab), the
  **reversibility gate** (fix-gating: restart/kill/config-wipe → ask), `apply_patch` (config fixes),
  **wizard mode** (guide non-experts), ripgrep (log search).
- ⬜ **No remote/SSH execution** (gap-analysis #12) — needed to reach a remote server. Build it scoped.
- ⬜ **No diagnostic tool family** yet (metrics/logs/network/services) — build it cross-platform.

---

## Two modes — be honest about risk
- **DIAGNOSE (read-only, safe, the high-value default).** Collect health signals + analyze → root cause +
  ranked recommendations. Touching nothing, this is genuinely useful and low-risk.
- **REMEDIATE (gated).** Apply a fix (restart a service, edit a config, free disk). Each runs through the
  reversibility gate + human approval, then a RE-CHECK that the issue actually cleared. **Never auto-fixes
  production.** Read-only by default; remediation is opt-in per action.

---

## The diagnostic tool family (cross-platform Mac/Linux)
- **System health**: CPU / memory / load (top, vmstat), disk usage + inodes (df, du), processes (ps), uptime,
  OOM-kill detection, swap pressure.
- **Logs**: journalctl / syslog / app logs — collect + ripgrep for error patterns, spikes, stack traces,
  correlate timestamps with the incident window.
- **Network**: reachability (ping, traceroute/mtr), DNS (dig/nslookup), open ports + listeners (ss/lsof),
  latency / packet loss, TLS + cert validity (openssl s_client), HTTP health (fetch_url — in-process,
  sandbox-safe), firewall state.
- **Services**: systemd status + restart loops, container/orchestrator health (docker/k8s), web server, DB
  connectivity + slow queries.
- **Resource exhaustion**: ulimits, file-descriptor leaks, connection-pool saturation, disk-full cascades.
Implement as typed diagnostic tools where structure matters, plus a **diagnostics cookbook** of vetted,
read-only `run_command` recipes (the bash-cookbook idea, ops edition) the agent picks from.

## Remote access (the missing piece)
- A **scoped remote-exec / SSH** capability — read-only diagnostic commands FIRST. Targets the user's OWN
  authorized servers (the security-scope/authorization model again). Credentials from the keychain, never
  plaintext; every command on a remote host is audit-logged.

## Diagnosis engine (the value)
- Collect signals → **correlate** (high CPU + OOM lines in logs + a flapping service = a memory leak; 100%
  disk + write errors = disk-full cascade) → root-cause hypothesis → ranked recommendations.
- **VERIFY (the moat)**: the diagnosis must cite the REAL collected evidence (the log line, the metric, the
  failed check) — no "it's probably DNS" without proof. Grounded by `GroundedReviewValidator`; an
  unsupported root cause is downgraded to "unconfirmed — here's what to check next," never asserted.

## Remediation (gated, verified)
- Each recommended fix is classified by the reversibility gate (restart = mutating→ask; `rm -rf`/config
  wipe / DB drop = dangerous→hard-ask), human approves, the agent applies it (via `apply_patch` for config,
  gated `run_command` for service control), then **re-runs the diagnostic to confirm the issue cleared** —
  no fabricated "fixed."

---

## ⚠️ Productization (offering to businesses) — this is a PRODUCT, not a feature

This is where I have to be straight with you: a tool that touches OTHER businesses' PRODUCTION servers,
credentials, and logs is one of the highest-trust, highest-liability things you can build. Your own
ENTERPRISE-READY bar applies in FULL, and it must be met before it ever touches a paying customer's box:
- **Tenant isolation** — provably no cross-customer leakage of access, logs, or findings.
- **Least-privilege + credential vaulting** — scoped, rotatable creds; never plaintext; read-only by default.
- **Full audit** — every command run on a customer host is logged, attributable, reviewable by them.
- **Customer approval for ANY remediation** — you never change their infra without explicit, per-action sign-off.
- **Data governance** — their logs/metrics may contain PII/secrets: classify, redact, retention/deletion
  policy, encryption in transit + at rest. Compliance posture stated (SOC2-style) since the domain demands it.
- **Reliability/ops** — runbooks, rollback, on-call: you're now part of THEIR incident path.

**Sequence honestly**: use it on your OWN infra first (PILOT — real value, contained blast radius). Only
after the verify-spine + gating are proven, and the enterprise checklist above is genuinely met (not
aspirationally), does it become a tool you offer others. Selling infra access before that bar is a
liability, not a product.

---

## Phases (each: build → test → adversarial Codex → ff-merge)
1. **Diagnostic tool family** (read-only, local) — system / logs / network / services + the diagnostics cookbook.
2. **Diagnosis engine** — collect → correlate → root-cause → VERIFY-grounded (no slop diagnosis).
3. **Remote access** — scoped SSH, read-only first, keychain creds, audit-logged.
4. **Remediation** — gated by reversibility + approval, re-check-to-confirm.
5. **Wizard mode** — guide a non-expert through diagnose → understand → approve → fix → confirm.
6. **Productization** — the enterprise-ready bar (tenant isolation, audit, vault, compliance) — LAST + heaviest.

## One-paragraph framing
The diagnosis core is high-value, low-risk, and reuses almost everything we have — it's the same
collect→verify→gated-act pattern as the security pipeline, pointed at "why is my server unhealthy." The
no-fabrication spine is again the differentiator: a diagnosis you can TRUST because it cites the actual log
line and metric, not a confident guess. Build the read-only diagnostics + remote access + the grounded
engine and you have a real SRE co-pilot for your own infra fast. Turning it into a tool other businesses
run against their production is a separate, serious, enterprise-grade product — worth doing, but only after
the bar is met, because the moment you hold a customer's server credentials you've taken on their risk too.
