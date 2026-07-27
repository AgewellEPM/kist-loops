# Deploying the receipt gate as a required check (GitHub)

The receipt gate becomes an **unbypassable** control the moment it's a **required status check** on a protected
branch. `git commit --no-verify` and removing the local hook are irrelevant — the gate runs server-side on every
PR. This is the authoritative enforcement layer (the local `kist --guard` hook is only defense-in-depth).

> Why an Action, not a hosted GitHub App? kist is a static binary that runs in your CI. A reusable Action + a
> required check gives you the unbypassable gate with **no server to host, no webhook, no third party holding your
> keys**. Your HMAC secret and trust roots stay in your CI. (A hosted App only adds value for cross-repo policy UX,
> which is future work.)

## 1. Provision the sealing secret

Create a repo or org **secret** `KIST_RECEIPT_KEY` — a strong (≥16 byte) shared secret. Receipts are sealed and
verified against it. Keep it out of the repo; rotate via your secret manager. (This is the same-trust-domain HMAC
tier; for cross-org trust add the issuer-signature tier below.)

## 2. Add the workflow

Copy `docs/kist/templates/receipt-gate.yml` to `.github/workflows/receipt-gate.yml`. Pin the action to a SHA. It:
- checks out full history (`fetch-depth: 0`),
- obtains a `kist` binary (build from source, or a pinned `kist-path`),
- runs `kist --ci-guard "origin/<base_ref>" "<pr_head_sha>"` with `KIST_RECEIPT_KEY` from the secret.

## 3. Make it required

Settings → Branches → Branch protection rule for your default branch → **Require status checks to pass** → select
**receipt-gate**. Also enable "Require branches to be up to date". Now no PR merges unless the gate is green.

## 4. Developer flow

```sh
git add -A
kist --verify --verify-cmd "swift build && swift test"   # or your build/test
git add .kist/receipts
git commit -m "feat: …"
```

## 5. (Optional) issuer-signature tier — cross-org / higher assurance

When you want more than "someone in our trust domain vouched" — e.g. a security team must sign off — pin issuer
keys and require signatures:

```sh
kist --gen-issuer-key security-team           # issuer keeps the private key
kist --trust-issuer security-team <public>    # pin on every verifier (or distribute via a trust bundle, below)
# developer, after --verify:
kist --sign-receipt latest --issuer-key <security-team-private>
git add .kist && git commit -m "…"
```

With any issuer pinned, the gate requires a valid pinned-issuer Ed25519 signature per change **in addition** to the
HMAC receipt — an attacker who steals `KIST_RECEIPT_KEY` still can't pass a change (they lack the issuer private
key). Revoke a compromised issuer with `kist --revoke-issuer <id>` (burns the key material, not just the alias).

### Distribute/rotate issuers at scale with a trust bundle

Instead of pinning every issuer on every verifier, pin ONE **root** and distribute a signed bundle:

```sh
kist --gen-issuer-key org-root                        # long-lived root, kept offline
# each verifier / CI:
kist --trust-root org-root <root-public>              # pin ONCE
# org publishes (and commits) a signed issuer-set:
kist --make-bundle --root-key <org-root-private>      # → .kist/trust-bundle.json
```

The CI gate loads `.kist/trust-bundle.json`, verifies it against the pinned root, and trusts the issuers it lists.
Rotating an issuer = re-issue the bundle; no CI reconfiguration. A tampered bundle breaks the root signature and is
ignored (fail-closed).

## What the gate fails closed on

Unresolvable range (exit 2); unreadable diff; any content-bearing commit with a missing/forged/mismatched/non-pass
receipt; a smuggled non-receipt file under `.kist/receipts`; a required-but-missing issuer signature; a
non-blob/gitlink under the receipts dir; a `KIST_RECEIPT_KEY` that doesn't match the sealed receipts. See
`RECEIPT_THREAT_MODEL.md` for the full model and the documented trust boundaries.
