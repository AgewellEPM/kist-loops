# AI Bug-Bounty Assistant — Plan + honest assessment (2026-06-29)

Luke's idea: point the AI at bug-bounty programs (HackerOne, Bugcrowd, company programs, comps), find bugs,
claim the rewards. "Seems like a sweet spot." It is — but for a specific reason, and with hard rules.

---

## Is it a sweet spot? Yes — but the edge is QUALITY, not quantity.

- **Bug bounty = AUTHORIZED testing.** A program's published scope + rules ARE your legal permission to test
  the listed assets. So this is the legitimate, in-scope endpoint of the security pipeline we already
  planned — the authorization-scope guardrail maps onto it 1:1. This is NOT random hacking; it's invited.
- **The honest reality**: it's competitive and hard. Most submissions are duplicates or rejected; median
  hunter earnings are low; top earners are highly skilled. AI is leverage, not a money printer. Anyone
  selling "AI finds bugs while you sleep" is selling a fantasy.
- **THE actual opportunity right now**: the platforms are DROWNING in AI-slop — floods of unverified,
  hallucinated, false-positive reports — and they're cracking down (rejections, reputation hits, bans).
  So the winning move is the *opposite* of spam: a system that only surfaces **VERIFIED, reproducible,
  high-quality** findings and REFUSES to report anything it can't prove. That is precisely kist's
  no-fabrication / verify-before-trust spine. **The sweet spot isn't "more reports" — it's "trustworthy
  reports in a market full of noise."** That's a real, defensible edge, and almost nobody has it.

---

## Hard rules (break these and you get banned or sued — non-negotiable)
1. **Strictly IN SCOPE.** Only the exact assets + vuln classes a program authorizes. Out-of-scope testing
   is unauthorized access — ban + potential legal exposure. The scope file enforces this; it refuses
   anything not explicitly listed.
2. **Follow each program's rules.** Rate limits, NO DoS, no social engineering, no data exfiltration, no
   pivoting. **Many programs restrict or BAN automated/AI tooling** — read every program's policy; the
   rules engine encodes it per-program and the tools obey it.
3. **Responsible disclosure.** Report only through the platform; never disclose publicly; never retain or
   exfiltrate real user data found incidentally.
4. **VERIFIED findings ONLY.** Never submit an unverified or AI-guessed bug — that's the slop that gets you
   banned. A finding with no reproducible PoC is DROPPED, not reported.
5. **Human-in-the-loop for SUBMISSION.** The AI recons, finds, verifies, and drafts; the human reviews and
   submits. NO auto-submit — ever. (Protects you from a single bad finding torching your reputation.)

---

## The system (reuses the security pipeline + the verify spine)
1. **Program intake**: parse a program's scope + rules → a structured authorization (the `.kist/security-
   scope.json` from the harden plan) + a per-program **rules object** (rate limit, automation policy,
   allowed vuln classes, payout table). Out-of-scope/forbidden-method requests are hard-refused.
2. **Recon + analyze (in-scope only)**: the app-reconstruct/harden pipeline pointed at in-scope assets —
   mirror/clone, SAST + DAST + OWASP Web Top 10 + a pentest checklist, all scope- and rate-gated.
3. **VERIFY — the moat**: every candidate finding must produce a **reproducible PoC** and pass an
   **adversarial re-check** (council/captain + `GroundedReviewValidator`). Can't reproduce it → it's a
   false positive → DROPPED. This is what keeps you off the slop list and is the whole reason kist wins
   here.
4. **Dedup + prioritize**: estimate likelihood a finding is already reported (common-pattern check) →
   prioritize novel / higher-severity / better-paying.
5. **Report drafting**: a high-quality disclosure in the program's required format — summary, CVSS/severity,
   exact steps to reproduce, impact, remediation, PoC artifact.
6. **Human review + submit + track**: Luke reviews the verified report, submits through the platform; a
   tracker records submissions, outcomes, payouts, and per-program reputation.

---

## What's NEEDED (concrete checklist)
- ✅ Already have: the trust/verify spine (no-fab, council/captain, grounding), `apply_patch`, ripgrep
  search, browser capture, sandbox isolation, security_audit + governance_report.
- ⬜ Build: the **authorization scope + per-program rules engine** (rate limits, automation policy) — FIRST.
- ⬜ Build: the **verify-finding spine** — reproducible-PoC generation + adversarial re-check wired to
  security findings (the differentiator).
- ⬜ Build: the **recon/analyze pipeline** (the harden plan's stages, scope-gated).
- ⬜ Build: the **report drafter** (program-format templates) + **submission/outcome tracker**.
- ⬜ Build: the **dedup-risk + prioritization** scorer.

## Honest expectations (so you go in clear-eyed)
- This is a force-multiplier for skilled security work, not passive income. Expect a long tail of
  duplicates/rejections; the wins come from verified, novel, well-written reports.
- **Start narrow**: one or two programs whose rules ALLOW tooling, web vuln classes the SAST/DAST covers
  well, verified findings only, human submits. Prove the verify-spine kills false positives before scaling.
- The reputation asset compounds: a hunter who only files reproducible, well-written reports gets triaged
  faster and trusted more. The verify spine builds that reputation by construction.

## GUIDED WIZARD / BEGINNER MODE (Luke has no security background — this is the default UX)

The system should onboard a complete beginner like a wizard, teaching the industry AS it goes — and the
verify spine makes this SAFE for a beginner in a way it normally isn't (it blocks the exact mistakes that
get newcomers banned). The wizard:

1. **Teaches the game, plainly.** What a bounty program is, what "scope" means, what's allowed vs forbidden,
   how triage/dedup/payout works, what a good report looks like. Short, plain-language, just-in-time — not a
   textbook. You learn by doing, with the AI explaining WHY at each step.
2. **Picks a safe starting program WITH you.** Filters to programs that (a) allow tooling, (b) are
   beginner-friendly, (c) have an in-scope surface our SAST/DAST covers well. Reads the rules aloud and
   loads them into the rules engine so the tools can't break them.
3. **Drives recon for you, in-scope only.** You don't need to know the commands; the AI runs the pipeline,
   narrates what it's checking, and shows findings in plain English.
4. **Refuses to let you submit junk.** A candidate finding can't even be drafted until it has a reproducible
   PoC that passed the adversarial re-check. This is the guardrail that protects a beginner's reputation —
   you literally can't fire off the AI-slop that gets people banned.
5. **Writes the report; you approve.** It drafts the disclosure in the program's exact format (severity,
   repro steps, impact, fix, PoC), explains each part, and walks you through submitting on the platform.
   You stay on the submit button; it never submits for you.
6. **Tracks + coaches.** Records outcomes, explains rejections/dups so you learn, and gets you triaged
   faster over time as your reputation (built on verified-only reports) compounds.

**The honest promise**: the wizard makes you *competent and safe at the process* on day one, and maximizes
your odds — it does NOT guarantee a payout. Rewards come from actually finding valid, novel bugs; the
system finds + verifies + writes them up and keeps you out of trouble, but the bug has to be real and not a
duplicate. Think tutor + co-pilot + safety rail, not a slot machine. For someone who "has no idea how this
works," that's exactly the right tool — it's the difference between learning the game safely and getting
banned in week one.

## Order
1. Authorization scope + per-program rules engine.
2. Verify-finding spine (reproducible PoC + adversarial check) — the edge.
3. Recon/analyze pipeline (harden-plan stages, scope+rate gated).
4. Report drafter + submission tracker (human submits).
5. Dedup risk + prioritization.

## One-paragraph framing
Bug bounty is the COMMERCIAL endpoint of the security pipeline — and the one place kist's biggest weakness-
turned-strength pays off directly: in a market flooded with AI-slop false positives, a system that only
reports what it can PROVE is exactly what's scarce and valuable. The plan is therefore not "find more bugs"
— it's "build the verify spine that makes every report reproducible and trustworthy, stay rigidly in
program scope, keep a human on the submit button, and let reputation compound." Built that way it's a
defensible, repeatable edge. Built as a report-cannon it gets you banned in a week.
