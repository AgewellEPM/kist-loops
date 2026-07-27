# Bug-Bounty Trust Core — Hardening Roadmap (from MiMo / DeepSeek / Grok review, 2026-06-30)

The trust core (SecurityEngagement + VerifiedFinding + EngagementStore) was reviewed by Codex (5 spine
bugs fixed) and then by **three independent models — MiMo, DeepSeek, Grok**. Two real bugs were fixed
immediately (CIDR `/0` footgun; dead `*.` wildcard). This is the triaged backlog of everything else they
raised: what's worth doing, what it reuses, and what was rejected.

## ✅ Already fixed
- 5 Codex spine bugs (newline-attestation, empty-target, control-char host, octal IPv4, Codable canon).
- CIDR `/8` floor — `/0`/over-broad ranges refused (DeepSeek+Grok CRITICAL).
- Wildcard `*.example.com` normalized to parent (Grok).

## 🔴 High-value enhancements — UNANIMOUS across all three reviewers
Each reuses a primitive that ALREADY EXISTS in this codebase, so they're integration, not green-field.

1. **Signed / cryptographic attestation** (MiMo, DeepSeek, Grok).
   Today `attestedBy` is a plain string — anyone with FS access can forge an engagement. Sign the
   canonical engagement blob with **Ed25519**, bound to operator identity + `attestedAtISO` + a nonce.
   REUSE: `AttestationVerifier` / `VerifiedOutcome` / Curve25519 already powering `FleetPromotionGate`.
   → `EngagementStore.load` verifies the signature; an unsigned/forged engagement is `.outOfScope`.

2. **Expiry + revocation** (MiMo, DeepSeek, Grok).
   Authorizations are time-bound in the real world; today they're eternal. Add `expiresAtISO: String?`
   + `isActive(asOf: Date)` (keep `inScope` pure — check expiry at the call site / a wrapper). Add a
   revocation marker so a compromised engagement can be killed without deleting the evidence.

3. **Append-only audit log** (MiMo, DeepSeek, Grok).
   No forensic trail of scope decisions / verify events today. Every `inScope` decision + every
   `FindingVerifier.verify` outcome → a **hash-chained ledger** (who, when, target, verdict).
   REUSE: `FleetSignoffLedger` (ForgeSeal HMAC + chain-hash) is exactly this shape.

## 🟡 Medium — worth doing, not urgent
4. **Scanner provenance** (Grok). `verify()` trusts whatever `[SecurityFinding]` it's handed — the
   "deterministic scanner only" guarantee is by CONVENTION, not enforced. Bind findings to the scanner
   (hash/sign the audit output) so a caller can't feed fabricated findings into the confirm path.
5. **IPv6 / IPv4-mapped coverage** (DeepSeek, Grok). Today IPv6 + `::ffff:1.2.3.4` are *rejected*
   (fail-closed, SAFE — they just can't be expressed). Add real IPv6 target kinds when a program needs them.
6. **Schema version field** (DeepSeek, Grok). Add `schemaVersion: Int` (custom decode default = 1) so
   future format changes don't break every stored engagement.

## 🟢 Low / noted
7. Empty-`id` validation in `EngagementStore.save` (DeepSeek) — empty id currently collides on `untitled`.
8. Surface (log) corrupt files skipped in `list()` instead of silent skip (DeepSeek M3).
9. DNS-rebinding awareness DURING active testing (DeepSeek M1) — a static gate can't solve this; belongs
   in the active-probe layer, not the scope model.

## ❌ Rejected (wrong or already-handled)
- DeepSeek C3 (panel collusion math) — boolean inverted; a tie ALREADY goes to `.refuted`. No bug.
- DeepSeek C5 (repo not canonicalized) / H1 (wildcard matches apex) — both already handled.
- "Malicious panel confirms fabricated findings" — a panel can only down-rank; findings come from the
  deterministic scanner, so a bad panel drops real findings (a DoS), it cannot MINT one.

## Recommended next build order
**#1 signed attestation → #3 audit log → #2 expiry/revocation** — all three reuse existing Ed25519 +
ledger primitives and together close the "forge / replay / no-trail" class the reviewers cared most about.
