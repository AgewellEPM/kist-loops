# Verification Receipt — threat model + pen-test results (2026-07-04)

Pen-tested the git-guard adversarially. Recorded honestly: what HELD, what was FIXED, what is FUNDAMENTAL.

## HELD (core security sound)
- **Forged receipt (invalid HMAC seal) → REJECTED.** The seal is the crypto root; can't forge without the key.
  HMAC verify is constant-time (`HMAC.isValidAuthenticationCode`).
- **Receipt reuse across changes → REJECTED.** diffDigest binds a receipt to the exact diff (content-digest,
  not filename). A receipt for change A can't admit change B.
- **Hand-flipped verdict → REJECTED.** Editing the stored verdict breaks the seal; AND admission RE-DERIVES the
  verdict from the checks and requires the stored field to agree (a key holder can't smuggle a `.pass` onto
  failing checks — the verdict is a pure function of the checks at admission time).

## FIXED — Codex adversarial gate round (2026-07-04)
- **CRITICAL fail-open on git error.** `git diff --cached` failing (launch error, nonzero exit) or a diff with
  invalid UTF-8 used to decode to `""`, which the guard treated as "nothing staged" → admit with no receipt.
  FIX: git runs now return EXIT STATUS; the guard fail-CLOSES on any nonzero status and on "files staged but
  empty diff"; diff/blob bytes decode LOSSLESSLY (ISO-Latin-1, a total injective map) so invalid UTF-8 never
  empties the digest or skips the scan.
- **HIGH binary-diff binding was weaker than "exact diff".** Default diff bound only abbreviated blob IDs +
  "Binary files differ". FIX: `--full-index --binary --no-textconv` — full 40-char blob SHAs + the actual binary
  patch are bound; `core.abbrev` can no longer shift the digest.
- **HIGH hook shell injection.** `exePath`/`root` embedded in double quotes let a path with `$()`/backticks/`"`
  execute at commit time. FIX: both are single-quote-escaped (`'` → `'\''`) → every metacharacter is literal.
- **MED content-scan skipped binary blobs** with invalid UTF-8 (same lossy-decode root) — FIX: lossless decode.
- **MED secret/host-control scans widened.** Secret shapes: GitHub (`ghp_`…), Slack (`xox…`), OpenAI (`sk-`),
  Google (`AIza…`), more AWS prefixes, and the JSON `"api_key": "…"` form (quote before the separator).
  Host-control: `NSAppleScript`, `CGEvent*`, ScreenCaptureKit/`SCStream`, `CGWindowListCreateImage`, `IOHID*`.
  Still a BACKSTOP, not complete DLP (see FUNDAMENTAL).
- **Env-key hygiene.** `KIST_RECEIPT_KEY` must be ≥16 bytes (rejects a lazy weak-key injection). This is hygiene,
  NOT a fix for the attacker-supplies-their-own-strong-key case — that is the same-trust-domain limit below.

## FIXED — Codex adversarial gate ROUND 2 (2026-07-04) — on the round-1-hardened code
Round 2 re-confirmed the round-1 CRITICAL/HIGH fixes are sound (no seal break, no binding break, no fail-open),
and found lower-severity edges, now closed:
- **`core.hooksPath` bypassed the installed hook** (git ignores `$GIT_DIR/hooks` when set). FIX: the hooks dir is
  resolved via `git rev-parse --git-path hooks` (honors `core.hooksPath`). Still a LOCAL hook — CI is authority.
- **Filename quoting + fail-open on blob read.** `--name-only` C-quoted odd names → `git show :<file>` failed →
  the content scan silently skipped that file. FIX: `--name-status -z` (NUL-delimited, no quoting); an unreadable
  ADDED/MODIFIED blob now FAILS THE CHECK (closed), not skipped. Deleted entries are skipped (no blob).
- **`.gitattributes -diff` blinded the host-control scan** (a source file forced to render as a binary patch has
  no `+` lines). FIX: host-control is now scanned over the full CONTENT of ADDED files (whole content == the
  change ⇒ no false positives). Modified-file `-diff` host-control remains a documented heuristic limit.
- **Digest still render-dependent (`diff.interHunkContext`).** FIX: pinned `interHunkContext=0`. This was a
  false-REJECT (fail-closed) risk only, never a false-admit.
- **Key-file trust incomplete.** FIX: an existing key is used only if it's a regular file, owned by us, mode 0600,
  and not a symlink (else ignored → ephemeral key → fail-closed). Creation uses `O_EXCL` (race-safe, no clobber).
- **Hook-ownership marker** now matched as a full line, not a substring (won't clobber a hook that merely mentions
  the marker in prose).

## SERVER-AUTHORITATIVE GATE — the fix for the #1 fundamental (WS2 T2.1, shipped 2026-07-04)
`kist --ci-guard [base] [head]` gates a COMMIT RANGE as a CI REQUIRED CHECK: every content-bearing commit in
base..head must carry a valid receipt bound to that commit's exact diff. A required check cannot be skipped with
`git commit --no-verify` or by removing a local hook — so THIS is the enforcement boundary the local hook never
was. Fail-closed on unresolvable range / unreadable diff / missing-forged-mismatched receipt / non-pass verdict.
The receipt store (`.kist/receipts`) is EXCLUDED from the gated diff on both ends so the sealed digest reproduces
(the proof artifact is not part of the reviewed change). Live-verified end-to-end (verify→commit→ci-guard admits;
unreceipted commit blocked; empty range clean; bad ref fails closed).

## FIXED — brutal dogfood round (2026-07-04) — two REAL holes found by attacking `--ci-guard`
- **HOLE A (fail-open range narrowing).** When no base could be resolved (no `--ci-guard` args, no CI env, no
  `origin/*` default branch), the base fell back to `HEAD~1` → only the tip commit was gated → earlier
  unreceipted commits slipped past. FIX: the `HEAD~1` guess is GONE — an unresolvable base now returns nil and
  the guard exits 2 (fail-closed). Pinned by `testUnresolvableBaseFailsClosed`.
- **HOLE B (smuggling under the excluded dir).** Because `.kist/receipts` is excluded from the gated diff (to
  break the circular digest), an attacker could commit ARBITRARY content there (`.kist/receipts/backdoor.swift`)
  completely ungated — including alongside an otherwise-valid receipted code change. FIX: every `.kist/receipts/**`
  path a change touches must decode to a SEAL-VALID `SealedReceipt` (`ReceiptSeal.sealValid`), else the change is
  blocked — in the CI guard (per commit), the local `--guard`, AND `--verify` (as a required check). Reduces
  smuggling to "attacker holds the sealing key" = the documented same-trust-domain limit. A tampered receipt also
  fails `sealValid` → blocked. Pinned by `testSmuggledFileUnderReceiptsIsBlocked` + `testMixed…` + `testSealValid…`.
  (Sibling paths like `.kist/receipts-evil` are NOT excluded — the pathspec is component-precise; verified.)
  Residual heuristic note: a real sealed receipt has string fields (`issuer`, `changedFiles`) that are part of its
  sealed bytes — putting a secret there requires the key (same-trust-domain limit), so it's not a new avenue.
- **HOLE B′ (Codex stop-gate): whole-FILE authentication.** The first HOLE-B fix authenticated the receipt
  OBJECT (`decode + sealValid`), but the HMAC only covers the `receipt` sub-object and `JSONDecoder` DROPS unknown
  keys — so a valid sealed receipt WRAPPED with an extra key (`{"receipt":…,"sealTag":…,"keyID":…,"EVIL":"payload"}`)
  decoded clean, seal-validated, and smuggled its wrapper bytes into the excluded dir. FIX: `authenticateReceiptFile`
  requires the committed file to EQUAL the canonical serialization of the decoded receipt byte-for-byte (the store
  now writes canonical bytes) — no wrapper, trailing bytes, or reformatting survives. Pinned by
  `testAuthenticateReceiptFileRejectsWrappedContent` + `testWrappedReceiptFileIsBlocked`.

## FIXED — Codex gate5 (2026-07-04) — three more found by attacking the whole-file auth + range walk
- **CRITICAL: `keyID` was not authenticated.** The seal covered only `receipt.canonicalBytes()`; byte-equality
  made the file canonical but a canonical file with an attacker-chosen `keyID` string still passed → keyID was a
  smuggle channel. FIX: the seal now covers a canonical envelope of `{keyID, receipt}` (`signableBytes`) — any
  keyID edit breaks the HMAC. `sealValid`/`admit` verify over the same payload. Pinned by `testKeyIDIsAuthenticated`.
- **HIGH: non-blob entries under `.kist/receipts` failed open.** `git show <commit>:<path>` fails on a gitlink
  (submodule, mode 160000) → it was mis-treated as "deleted" and skipped, while the main diff excluded it → a
  submodule pointer (arbitrary external code) rode in ungated. FIX: read the NEW MODE via `git diff --raw -z` and
  require a regular blob (100644/100755) — gitlinks/symlinks/trees are blocked. Pinned by `testGitlink…`.
- **HIGH: `--first-parent` left a history gap.** Content added on a side branch then deleted before an empty-net
  merge was never gated but stayed reachable in history. FIX: the guard now walks `--no-merges` (gates EVERY real
  commit vs its first parent), and separately flags EVIL MERGES (`git diff-tree --cc --no-commit-id` content that
  is in no parent). Clean merges of receipted branches pass; evil merges + side-branch history are blocked. Pinned
  by `testAddThenDeleteInSideBranchIsGated`. NOTE: a merge that resolves conflicts by adding content must do so in
  a normal receipted commit (or squash/rebase) — bare conflict-resolution content in a merge is fail-closed.

## FIXED (found by pen-test, now closed + re-verified)
- **Binary-file secret** (git diff shows no content) — added a FULL-CONTENT scan of every staged blob.
- **install-guard clobbering an existing pre-commit hook** — now REFUSES with chain instructions (idempotent
  for our own hook).
- **Cross-machine diff non-determinism** (git config-dependent) — diff computed with PINNED stable flags
  (algorithm/renames/quotePath/prefix) so the digest is reproducible everywhere.
- **Key-file world-readable window** — key now created 0600 ATOMICALLY (no write-then-chmod).

## FUNDAMENTAL (not code-fixable at the local tier — documented, mitigated by design elsewhere)
- **`git commit --no-verify` / removing the hook BYPASSES the local guard.** Client-side hooks are inherently
  bypassable. → The AUTHORITATIVE gate is the SERVER-SIDE required check (GitHub App, roadmap WS2 T2.1). The
  local hook is convenience/defense-in-depth ONLY; never the security boundary. The hook + install output now
  say this explicitly.
- **A deliberately split/obfuscated secret** (e.g. across two source lines) EVADES the pattern scan. Regex DLP
  is a cheap BACKSTOP, not a guarantee. → The real gate is the verification PROOF (council/human review the
  change); the scan just catches the obvious. Entropy-based DLP is a future check.
- **Local HMAC key extraction OR attacker-supplied env key → forge (CLOSABLE via the issuer tier below).** The
  HMAC seal is a SYMMETRIC shared secret: an attacker who reads `~/.kist/receipt-key` OR injects `KIST_RECEIPT_KEY`
  can seal a receipt AND make the guard validate it with the same key. This is unavoidable for HMAC within one
  trust domain. → **NOW FIXED for cross-org by the Ed25519 ISSUER-SIGNATURE tier (shipped 2026-07-04).**

## ISSUER-SIGNATURE TIER — the cross-org trust upgrade (Ed25519, shipped 2026-07-04)
`ReceiptAttestation.swift` + `ReceiptIssuerKeyStore.swift` (mirrors the proven skill-publisher / fleet-deploy
attestation pattern: fileprivate-init unforgeability, fail-closed, verifier holds ONLY public keys):
- An ISSUER holds an Ed25519 private key (`kist --gen-issuer-key <id>`). It SIGNS a change's `(diffDigest, pass)`
  → `.kist/receipts/<digest>.sig.json` (`kist --sign-receipt`). Verifiers PIN the issuer's PUBLIC key
  (`kist --trust-issuer <id> <pub>`, stored owner-only in `~/.config/kist/receipt-issuers.json`, never in-repo).
- When ANY issuer key is pinned, `--guard`/`--ci-guard` require, per gated change: a valid HMAC receipt AND a
  valid Ed25519 signature from a PINNED issuer bound to that exact diffDigest + a `pass` verdict. **An attacker who
  holds the symmetric HMAC key STILL cannot forge the issuer signature** (no private key) → the symmetric-key limit
  is closed. Proven: `testIssuerSignatureTierRequiresAndAcceptsSignature` + live (HMAC-key holder blocked).
- The `.sig.json` sidecar is itself authenticated (canonical byte-eq + filename-digest binding + pinned-key
  signature) so it's not a new smuggle channel; an unpinned issuer's signature is rejected.
- Empty issuer store ⇒ tier inactive ⇒ HMAC-only (the same-trust-domain tier, unchanged for local/solo use).
- Verdict/label: this lifts the receipt toward the cross-org public-good primitive. Remaining hardening: a signed
  issuer-set (today trust = the pinned public keys) and GitHub App packaging. Still PILOT-READY until those + the
  tier's security review land.

### Rotation & revocation (shipped 2026-07-04)
`kist --revoke-issuer <id>` burns the compromised KEY MATERIAL, not just the keyID string (v3 store
`{version:3, issuers, revoked: {keyID → pubkey SHA-256 fingerprint}}`). The revoked key is dropped from the
verifier's trusted set — by keyID AND by fingerprint — so its signatures are rejected (`testRevokedIssuerSignatureIsRejected`)
and the same key bytes **cannot be re-pinned under a NEW alias** (Codex gate8 MED: `--trust-issuer` refuses burned
material; `init` filters it under any alias — `testRevocationBurnsKeyMaterialAcrossAliases`). Un-revoke lifts the
burn. `--unpin-issuer` removes a pin without a compromise record. Fail-closed against re-trusting a compromised key.
ROTATION WORKFLOW (compromised key): `--revoke-issuer old` → `--gen-issuer-key new` + `--trust-issuer new` →
for each affected change, REMOVE the old sidecar (`git rm .kist/receipts/<digest>.sig.json`), re-`--verify`,
re-`--sign-receipt` with the new key. (A stale revoked-issuer sidecar left staged correctly fails `--verify`.)
- **Codex gate7 (2026-07-04): NO CRITICAL/HIGH/MED bypass** — the tier is sound for its goal (a KIST_RECEIPT_KEY
  holder cannot pass a malicious change once an issuer is pinned): `VerifiedAttestation` init is fileprivate (only
  the verifier mints it), verify order is strict + fail-closed, the `.sig.json` sidecar is whole-file authenticated
  + digest-bound + pinned-key-verified, and the signed digest reproduces the gated digest. One LOW closed:
  `signatureB64` / `sealTag` now require CANONICAL encoding (64-byte sig + canonical base64; lowercase even-length
  hex) so encoding variants can't be a covert byte channel. DOCUMENTED CONTRACT: a repo that uses signatures must
  pin the issuer on EVERY verifier (incl. CI) — an unpinned verifier fails closed on any `.sig.json`.
- **Deleting `~/.kist/receipt-key` silently mints a new key**, invalidating all prior receipts (fail-closed but
  operationally surprising). → Key backup/rotation runbook + an org-shared key (KIST_RECEIPT_KEY) mitigate.

### Signed trust bundles — distributable issuer-set (shipped 2026-07-04)
`ReceiptTrustBundle.swift` + `ReceiptRootKeyStore.swift`. An org has ONE long-lived ROOT Ed25519 key; each verifier
pins only the ROOT public key (`--trust-root`). The org SIGNS a `TrustBundle` (issuer set + revocations) with the
root private key (`--make-bundle --root-key <priv>` → `.kist/trust-bundle.json`, committed). At gate time
`effectiveIssuerVerifier` loads the repo bundle, verifies it against pinned roots (`TrustBundleVerifier`,
fileprivate-init `VerifiedBundle`, fail-closed), and MERGES its issuers into the local set — LOCAL pins/revocations
win, and a bundle-revoked issuer is dropped by keyID AND fingerprint. Orgs rotate issuers by re-issuing the bundle
with NO per-verifier reconfig; a tampered bundle breaks the root signature and is ignored (fail-closed). The bundle
file is NOT excluded from the gated diff — changing trusted issuers is reviewable and needs its own receipt.
Canonical signature encoding enforced. Tests: `ReceiptTrustBundleTests` (7) + live root-only-verifier e2e.

## Net: the crypto core is sound; the local hook is honest defense-in-depth; enforcement authority belongs to
## the server check + (for cross-org) Ed25519 signatures + (for scale) root-signed trust bundles. No overclaim.
