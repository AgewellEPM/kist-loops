# Verification Receipt — security warranty

This is the honest contract for the receipt gate: what it **guarantees**, what it **explicitly does not**, and how
to verify both yourself. A compliance primitive is only worth the precision of its claims — so this document errs
toward under-claiming. Everything here is backed by tests (`swift test`) and a runnable adversarial gauntlet
(`scripts/receipt-gauntlet.sh`). Run the gauntlet against your own build before you rely on any of it.

## What the gate GUARANTEES (with the `--ci-guard` required check, KIST_RECEIPT_KEY provisioned)

1. **No unreviewed content merges.** Every content-bearing commit in the gated range must carry a Verification
   Receipt bound to its exact diff. No receipt ⇒ blocked. (Gauntlet: *unreceipted change is BLOCKED*.)
2. **Exact-change binding.** A receipt is valid only for the exact diff it verified (SHA-256 over stable,
   machine-independent diff bytes incl. full blob ids). A receipt can't be reused for a different change, and the
   same textual change on different base content yields a different digest.
3. **Tamper-evidence.** The receipt is HMAC-sealed over the receipt AND its keyID; the verdict is re-derived from
   the checks at admission (never a trusted stored field); the whole receipt FILE is authenticated byte-for-byte.
   Editing any part invalidates it. (Gauntlet: *wrapped receipt* and *keyID tamper* are BLOCKED.)
4. **No smuggling through the proof store.** `.kist/receipts` is excluded from the gated diff (to break the
   circular digest), but every file there must authenticate as a seal-valid receipt or a pinned-issuer-verified
   attestation — arbitrary content, gitlinks, symlinks, and trees are blocked. (Gauntlet: *arbitrary file* and
   *gitlink under .kist/receipts* are BLOCKED.)
5. **Full-history coverage.** Every real (non-merge) commit is gated, and evil-merge content is caught — content
   added on a side branch and removed before an empty-net merge is still blocked. (Gauntlet: *add-then-delete*.)
6. **Fail-closed.** An unresolvable range, an unreadable diff, a git error, a non-pass verdict, a missing required
   issuer signature — all block. The gate never admits a change it cannot fully see. (Gauntlet: *unresolvable base
   fails closed*.)
7. **Unbypassability of the required check.** As a GitHub required status check, `git commit --no-verify` and
   removing the local hook are irrelevant — the gate runs server-side on the PR.
8. **(Issuer tier) key-theft resistance.** With an issuer pinned, an attacker who steals `KIST_RECEIPT_KEY` still
   cannot pass a malicious change — they lack the issuer's Ed25519 private key. Revocation burns the key
   *material* (fingerprint), not just the alias.

## What the gate DOES NOT guarantee (documented limits — not bugs)

- **The HMAC tier is same-trust-domain.** Whoever holds `KIST_RECEIPT_KEY` can mint any receipt. That is inherent
  to a symmetric secret. → Use the **issuer-signature tier** (Ed25519) when you need resistance to key theft or
  cross-org trust. Keep `KIST_RECEIPT_KEY` a protected CI/org secret.
- **The local `--guard` hook is bypassable** (`--no-verify`, hook removal, `core.hooksPath`). It is
  defense-in-depth only. **The required CI check is the authority.**
- **The checks are as good as what you put in them.** The built-in secret/host-control scans are cheap
  BACKSTOPS — split/obfuscated secrets and `.gitattributes`-hidden content can evade pattern-matching. The real
  gate is the verification PROOF (`--verify-cmd` build/tests, council/human review, and for higher assurance an
  issuer signature). The receipt attests *that checks ran and passed*; it does not make weak checks strong.
- **A receipt is not a proof of correctness.** It's an attestation that a defined set of deterministic + judged
  checks passed for an exact change. Correctness is only as strong as those checks.
- **Cross-git-version determinism.** The digest is pinned against local git config, but exotic git/zlib version
  differences could cause a *false reject* (never a false admit) — you re-verify. Verify with the same kist/git
  you gate with.
- **Trust roots/issuer stores are local files.** They must be provisioned securely (owner-only, out of the repo);
  kist enforces owner-only/symlink-reject on read, but the operator must protect the secrets and pins.
- **Trust-bundle rollback is now blocked at the CI gate.** A PR that reverts `.kist/trust-bundle.json` to an
  OLDER (still validly root-signed) bundle — re-trusting a revoked issuer — is refused: the gate compares the
  bundle's `issuedAtEpoch` at base vs head and blocks a decrease, and blocks removing a bundle that was root-valid
  at base (Codex gate9 MED, closed). Stateless + CI-native (no persistent high-water needed). Belt-and-suspenders:
  a local `kist --revoke-issuer <id>` is STICKY — a bundle can never re-trust locally-burned material (by keyID or
  fingerprint). Any bundle CONTENT change must STRICTLY advance `issuedAtEpoch` — a same-or-lower-epoch bundle with
  different contents (e.g. re-adding a revoked issuer) is refused ("same epoch ⇒ identical payload"). TRUST MODEL:
  the root, as the anchor, CAN un-revoke a bundle-only revocation by issuing a HIGHER-epoch bundle — that is its
  prerogative, not a bypass. For revocation of COMPROMISED material that must survive even a root re-issue, also run
  local `kist --revoke-issuer` (sticky; a bundle can never re-trust locally-burned material). The signing root may
  not change across a transition (a cross-root swap between two pinned roots is blocked; deliberate root rotation is
  a separate explicit operation). Residual limits (stateless gate): (a) FIRST bundle adoption in a repo with no
  prior bundle trusts whatever root-signed bundle is committed — there's no earlier epoch to compare, so a
  historical permissive bundle could be adopted; mitigate with local sticky `--revoke-issuer` for compromised
  issuers and by reviewing the adoption commit (it's gated content). (b) Two verifiers gating DIFFERENT base points
  is out of scope; the gate protects the base→head transition it actually sees.

## How to verify these claims yourself

```sh
swift test --filter 'Receipt'          # the invariants, as unit + real-git integration tests
scripts/receipt-gauntlet.sh            # the adversarial corpus — every attack class, must all block
```

If any gauntlet scenario fails on your build, do not rely on the gate until it's fixed. See
`RECEIPT_THREAT_MODEL.md` for the full model and the review history behind each guarantee.
