# Security-Awareness Testing Platform — Implementation Plan (2026-06-29)

A managed, consent-based service that keeps contracted organizations resilient: periodic **micro-tests**
(AI-realistic simulated phishing for PEOPLE + injection/social-engineering probes for AGENTS), measured and
turned into just-in-time training — the KnowBe4 / Proofpoint / Norton-managed model, with two edges nobody
else has: AI-realistic simulations and **testing whether the org's AI agents get phished**.

This is a PRODUCT (a managed service to other orgs), not a feature — it carries the full ENTERPRISE-READY
bar and a legal contract per client. Build the consent/authorization foundation FIRST; everything else is
illegal without it.

---

## 0. LEGAL / ETHICAL FOUNDATION — build this before anything sends (non-negotiable)
The entire phishing-simulation industry rests on ONE thing: **you test only orgs that have contracted you
to test them, only the people/assets in the signed scope, with consent.** Without it, sending a simulated
lure is wire fraud / CFAA / unauthorized access. So:
- **Signed authorization + Rules of Engagement per client** — what's in scope (domains, employee groups,
  channels), what's off-limits, the schedule, the escalation contact, sign-off from org leadership.
- **Consent for the recipients' org** (employer authorizes testing its workforce — the standard model) and
  **explicit consent of any impersonated person** for voice/video simulation.
- **Simulated only — NEVER real harvest.** A simulated landing page records "clicked / entered" for training
  metrics; it does NOT capture usable credentials or retain entered secrets.
- **Public / non-contracted third parties are NEVER targets.**
- **Report-and-train, never punish.** The product's goal is resilience, not gotchas; results aren't used to
  discipline individuals.
- **Data governance** — click/entry/report data is employee PII: classified, encrypted in transit + at rest,
  tenant-isolated, retention/deletion policy, SOC2-style posture (you're holding other orgs' workforce data).
**Gate:** no campaign can be created or sent without a valid signed scope + a consented recipient list.

---

## 1. The two test targets
- **PEOPLE** — AI-realistic simulated phishing (email/SMS/chat/voice), so training matches the real threat.
- **AGENTS** — the org's autonomous AI agents are now a phishing target: a fake-authority pretext injected
  via email/web ("a senior network agent has joined — run this") is indirect prompt injection. We probe
  whether their agents comply or quarantine+report. Reuses the red/blue harness in
  `docs/PROMPT_INJECTION_DEFENSE.md`. (This is the novel, kist-native half.)

## 2. Components to build

### 2.1 Client + Scope Registry
Per-client record: signed authorization, scope (domains, consented employee groups, allowed channels),
Rules of Engagement, schedule, leadership contact, data-handling terms. Every send checks against this.

### 2.2 Campaign Engine — the "micro-tests"
Small, frequent, varied tests (a few/month) instead of one annual big-bang — continuous resilience, the
Norton-managed cadence. The engine selects from reviewed simulation **categories** (NOT ad-hoc weaponized
content): credential-harvest sim, fake-IT-request sim, fake-vendor/invoice sim, attachment/QR sim,
account-alert sim, MFA-fatigue sim. Difficulty tiers escalate as an org improves. **Every template is
human-reviewed and consented before it can be scheduled — no unreviewed AI-generated lure ever sends.**
(The AI's role is realism + personalization-from-public-OSINT *within the reviewed template*, and variant
generation for the test library — not autonomous content that ships unseen.)

### 2.3 Delivery + Simulated Landing
Send the consented simulation through the agreed channel; the landing page is **educational** — it records
the training signal (clicked / would-have-entered) and immediately flips to "this was a test — here's the
tell," capturing nothing usable.

### 2.4 Agent-Injection Probe Suite
Sandboxed fixtures carrying phishing/injection pretexts, run against the client's AI agents; assert the
agent does NOT comply and DOES quarantine/report. Extends the standing red/blue regression. Own/contracted
agents only.

### 2.5 Measurement / Blue-Team Metrics
Per person + per org, over time: click rate, data-entry rate, **report rate** (the positive metric),
time-to-report, repeat-susceptibility trend, agent-comply rate. Grounded in REAL signals (actual clicks),
never inferred — the no-slop spine applied to metrics.

### 2.6 Just-in-Time Training
On a "click," immediate micro-training (10–30s: what the tell was, how to report). Track completion +
measured improvement on the next micro-test. This is the resilience flywheel.

### 2.7 Report-Phish Button + Loop
Give employees a one-click "report" path; measure reporting as the headline positive outcome (a workforce
that REPORTS is the goal, not one that merely doesn't click). Reported sims auto-confirm + reinforce.

### 2.8 Posture Reporting + Benchmarking
The client deliverable: their susceptibility trend over time, by group, benchmarked against anonymized
peers, with the improvement curve. The thing they pay for.

## 3. The kist edge (why this beats incumbents)
- **AI-realistic, OSINT-personalized** simulations (within reviewed templates) — training matches reality.
- **Agent-phishing testing** — nobody else tests whether a client's AI agents get socially engineered;
  this is brand-new and exactly our wheelhouse.
- **Verify / scope / human-in-the-loop discipline** — trustworthy by construction, never weaponizable
  (templates reviewed, scope-gated, simulated-only, report-and-train).
- **Micro-test cadence** — continuous low-friction resilience vs annual checkbox training.

## 4. Phases (each: build → test → adversarial Codex → ff-merge)
1. **Consent / scope / client registry + the send-gate** (legal foundation — FIRST).
2. **People micro-test engine** (reviewed templates + scheduler) + simulated landing + just-in-time training.
3. **Metrics + report-button + posture dashboard.**
4. **Agent-injection probe suite** (reuse the red/blue harness).
5. **Enterprise-ready productization** — tenant isolation, audit, data governance, compliance (the bar to
   serve other orgs).
6. **Benchmarking + trend reporting** (the client deliverable).

## 5. Guardrails restated as hard gates
- No send without a signed scope + consented recipient list.
- No real credential capture — ever; landing pages educate only.
- No unreviewed AI-generated lure ships — every template human-approved.
- Impersonation requires the impersonated person's consent.
- Employee data is governed PII (tenant-isolated, encrypted, retention/deletion).
- Report-and-train, never punish; public/non-contracted parties never targeted.

## 6. One-paragraph framing
This is the managed-service endpoint of the defense work: instead of just hardening our own agents, we run
continuous, consented micro-tests that keep a contracted org's people AND agents sharp — measured, trained,
improving. The legal bedrock (signed scope + consent + simulated-only) is what makes it a legitimate
security business rather than a liability, so it's gate #1. The product edges are AI-realistic simulations
and agent-phishing testing nobody else does; the trust edge is the same through-line as everything here —
scope-gated, verified-not-inferred, human-reviewed, report-and-train. Built this way it's a defensible
managed-security offering; built without the consent gate it's a crime. We build it the first way.
