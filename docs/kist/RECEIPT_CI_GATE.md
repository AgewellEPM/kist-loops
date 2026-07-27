# Verification Receipts as an unbypassable CI gate

The local `kist --guard` pre-commit hook is defense-in-depth — it's bypassable (`git commit --no-verify`, or
removing the hook). The **authoritative** enforcement is a **CI required check** that a developer cannot skip:
`kist --ci-guard`. It gates a commit range: every content-bearing commit in `base..head` must carry a valid,
seal-intact, passing Verification Receipt bound to that commit's exact diff.

## Developer flow (local)

```sh
# make your change, stage it
git add -A
# run checks, seal a receipt (optionally gate on build/tests)
kist --verify --verify-cmd "swift build && swift test"
# commit BOTH the change and the receipt
git add .kist/receipts
git commit -m "feat: …"
```

The receipt (`.kist/receipts/<digest>.json`) is committed alongside the change. It is excluded from the gated
diff, so it never perturbs its own digest.

## GitHub Actions (the required check)

```yaml
name: receipt-gate
on: pull_request
jobs:
  verify-receipts:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0            # need full history to diff base..head
      - name: Build kist
        run: swift build -c release --product kist
      - name: Enforce Verification Receipts
        env:
          # The org shared sealing secret (>= 16 bytes). Sealed receipts verify against THIS key.
          KIST_RECEIPT_KEY: ${{ secrets.KIST_RECEIPT_KEY }}
        run: |
          .build/release/kist --ci-guard \
            "origin/${{ github.base_ref }}" "${{ github.sha }}"
```

Mark **receipt-gate** a required status check in branch protection. Now a PR cannot merge unless every commit
carries a valid receipt — `--no-verify` at commit time is irrelevant, because the gate runs server-side on the PR.

## What it fails closed on

- Unresolvable base/head range (exit 2) — never passes blind on a misconfigured range.
- Any commit whose diff can't be read (exit 1).
- Any content-bearing commit with a missing / forged / mismatched / non-pass receipt (exit 1).
- No `KIST_RECEIPT_KEY` set → a per-install key that won't match org-sealed receipts → every commit fails closed
  (with a loud warning to set the secret).

## Trust boundary

The seal is a symmetric HMAC: whoever holds `KIST_RECEIPT_KEY` can mint any passing receipt. Keep it a protected
CI/org secret. Cross-org, untrusted-issuer receipts require the Ed25519 signature tier (roadmap WS3) — the CI
required check is the boundary until then. See `RECEIPT_THREAT_MODEL.md`.
