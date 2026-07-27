import Foundation
import AgentCore

/// SERVER-AUTHORITATIVE receipt gate (docs/kist/LEAPFROG_ROADMAP_2026.md WS2 T2.1) — the fix for the #1 documented
/// FUNDAMENTAL limit of the local hook: `git commit --no-verify` (or deleting the hook) bypasses a client-side
/// guard. This mode is meant to run as a CI REQUIRED CHECK on a pull request: a required check cannot be skipped
/// with `--no-verify`, so THIS is the enforcement boundary. It gates a COMMIT RANGE (base..head): every
/// content-bearing commit must carry a valid, seal-intact, passing receipt bound to that commit's exact diff.
///
/// Fail-closed everywhere: an unresolvable range, an unreadable diff, a missing/forged/mismatched receipt, or a
/// non-pass verdict all FAIL the check. The only exit-0 paths are "range resolved and every gated commit admitted"
/// and "range resolved but genuinely empty" (explicitly logged, never silent).
extension KistRunner {

    /// Resolve base/head refs to concrete SHAs. Precedence: explicit args → CI env → origin default branch.
    /// Returns nil (fail-closed) if either ref can't be resolved to a commit.
    private static func resolveRange(opts: KistOptions, root: String) -> (base: String, head: String)? {
        let env = ProcessInfo.processInfo.environment
        // HEAD: explicit → CI head sha → HEAD
        let headRef = opts.ciGuardHead ?? env["GITHUB_SHA"] ?? "HEAD"
        // BASE: explicit → GitHub PR base ref → GitLab target → remote default branch. If NONE resolve, we do NOT
        // guess — resolveRange returns nil and the caller fails closed (never gate a silently-narrowed range).
        guard let baseRef = opts.ciGuardBase
            ?? env["GITHUB_BASE_REF"].map({ "origin/\($0)" })
            ?? env["CI_MERGE_REQUEST_TARGET_BRANCH_NAME"].map({ "origin/\($0)" })
            ?? inferDefaultBase(root: root)
        else { return nil }
        let base = gitOut(["rev-parse", "--verify", "--quiet", "\(baseRef)^{commit}"], cwd: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let head = gitOut(["rev-parse", "--verify", "--quiet", "\(headRef)^{commit}"], cwd: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !head.isEmpty else { return nil }
        return (base, head)
    }

    /// Default base when nothing explicit is given: the remote's default branch (origin/HEAD → main → master).
    /// Returns nil if NONE resolve — the caller then FAILS CLOSED. Never guesses `HEAD~1`: guessing a base
    /// narrows the range to the tip commit and lets earlier unreceipted commits slip past ungated (dogfood HOLE A).
    private static func inferDefaultBase(root: String) -> String? {
        for candidate in ["origin/HEAD", "origin/main", "origin/master"] {
            let sha = gitOut(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], cwd: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sha.isEmpty { return candidate }
        }
        return nil
    }

    /// The tree a commit is diffed AGAINST: its FIRST parent, or the well-known empty-tree id for a root commit
    /// (so a root commit still produces a real, bindable diff).
    private static func against(_ commit: String, root: String) -> String {
        let parent = gitOut(["rev-parse", "--verify", "--quiet", "\(commit)^"], cwd: root)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parent.isEmpty ? "4b825dc642cb6eb9a060e54bf8d69288fbee4904" : parent
    }

    /// The exact-diff of ONE commit vs `base`, with the SAME stable flags + receipt exclusion `--verify` used, so
    /// the digest reproduces the one sealed at commit time (`git diff --cached` compares the same two trees).
    private static func commitDiff(_ commit: String, against base: String, root: String) -> (status: Int32, diff: String) {
        var args = stableDiffRangeFlags
        args.append(base); args.append(commit)
        args.append(contentsOf: receiptPathExclusion)   // same exclusion as verify → digest reproduces (live-test C1)
        let r = gitRun(args, cwd: root)
        return (r.status, losslessString(r.data))
    }

    /// Every `.kist/receipts/**` path CHANGED by this commit must be a REGULAR BLOB that authenticates as a
    /// seal-valid receipt file — else arbitrary content (code/secrets/submodules) rides into the repo hidden in
    /// the diff-EXCLUDED receipts dir. Uses `--raw -z` to read the NEW MODE so a gitlink (160000), symlink
    /// (120000), or tree is rejected — `git show` fails on a gitlink and used to be mis-treated as "deleted"
    /// (Codex HIGH). Deletions are fine. Returns a failure reason, or nil if clean.
    private static func receiptDirIntegrity(commit: String, against base: String, root: String,
                                            key: Data, verifier: ReceiptAttestationVerifier) -> String? {
        // --no-renames: keep entries as clean (meta,path) PAIRS. With rename detection on (a common git default) an
        // R entry carries TWO path fields (src,dst) and would misalign the pair-parser below.
        let raw = gitOut(["diff", "--raw", "-z", "--no-renames", base, commit, "--", ":(top).kist/receipts"], cwd: root)
        return checkReceiptRaw(raw, showRef: { "\(commit):\($0)" }, root: root, key: key, verifier: verifier)
    }

    /// Shared parser for `git diff --raw -z` over the receipts dir (works for both range and staged forms via the
    /// `showRef` closure that builds the `git show` argument for a path). Meta token `:<old> <new> <o> <n> <status>`,
    /// then the path token.
    static func checkReceiptRaw(_ raw: String, showRef: (String) -> String, root: String,
                               key: Data, verifier: ReceiptAttestationVerifier) -> String? {
        let toks = raw.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i + 1 < toks.count {
            let meta = toks[i], path = toks[i + 1]; i += 2
            let f = meta.split(separator: " ").map(String.init)
            guard f.count >= 5 else { continue }
            let newMode = f[1], status = f[4]
            if status.hasPrefix("D") { continue }   // deleted → nothing under receipts remains
            guard newMode == "100644" || newMode == "100755" else {
                return "non-blob entry under .kist/receipts (mode \(newMode)): \(path)"   // gitlink/symlink/tree
            }
            let r = gitRun(["show", showRef(path)], cwd: root)
            guard r.status == 0, authenticateReceiptDirFile(path: path, data: r.data, key: key, verifier: verifier) else {
                return "non-receipt content smuggled under .kist/receipts: \(path)"
            }
        }
        return nil
    }

    /// A file under `.kist/receipts/` is legitimate iff it is EITHER a whole-file-authenticated sealed receipt
    /// (`<digest>.json`, HMAC) OR a canonical, digest-bound, PINNED-ISSUER-verified attestation sidecar
    /// (`<digest>.sig.json`, Ed25519). A `.sig.json` whose signature doesn't verify against a pinned key — or any
    /// sidecar when no issuer is pinned — is treated as smuggled content (fail-closed): the free-text approval
    /// fields are covered by the signature, so an attacker can't hide a payload there without a pinned key.
    static func authenticateReceiptDirFile(path: String, data: Data, key: Data,
                                           verifier: ReceiptAttestationVerifier) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".sig.json") {
            let digest = String(name.dropLast(".sig.json".count))
            guard let att = try? JSONDecoder().decode(AttestedReceipt.self, from: data),
                  att.canonicalBytes() == data,                 // no wrapper/trailing bytes
                  att.approval.diffDigest == digest else { return false }   // filename binds the change
            if case .valid = verifier.verify(att, diffDigest: digest) { return true }
            return false
        }
        return ReceiptSeal.authenticateReceiptFile(data, key: key)
    }

    /// `git diff-tree --cc` over a merge surfaces content the merge introduced that is in NO parent (conflict
    /// resolution / evil merge). Any such content is un-receipted and must block. Returns the offending paths.
    private static func evilMergePaths(_ merge: String, root: String) -> [String] {
        // --no-commit-id: without it diff-tree prints the commit SHA as its first line, which we'd mis-read as a
        // changed path and FALSE-BLOCK every clean merge.
        gitOut(["diff-tree", "--cc", "--no-commit-id", "-r", "--name-only", "-z", merge], cwd: root)
            .split(separator: "\u{0}").map(String.init).filter { !$0.isEmpty }
    }

    /// The EFFECTIVE issuer verifier for a repo: locally-pinned issuers PLUS the issuers from a repo trust bundle
    /// (`.kist/trust-bundle.json`) IF it's signed by a PINNED trust root. Local pins/revocations win; a bundle can
    /// only ADD trust an org's root vouches for. No pinned root or no valid bundle ⇒ just the local pins.
    static func effectiveIssuerVerifier(projectRoot root: String) -> ReceiptAttestationVerifier {
        var store = ReceiptIssuerKeyStore.load()
        let rootVerifier = TrustBundleVerifier(trustedRoots: ReceiptRootKeyStore.load().trustedKeys())
        if !rootVerifier.isEmpty, let signed = loadRepoTrustBundle(root: root),
           case .valid(let vb) = rootVerifier.verify(signed) {
            store = store.addingBundle(issuers: vb.bundle.issuers, revoked: vb.bundle.revoked)
        }
        return ReceiptAttestationVerifier(trusted: store.trustedKeys())
    }

    private static func loadRepoTrustBundle(root: String) -> SignedTrustBundle? {
        let path = (root as NSString).appendingPathComponent(".kist/trust-bundle.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(SignedTrustBundle.self, from: data)
    }

    private static func bundleAtRef(_ ref: String, root: String) -> SignedTrustBundle? {
        let r = gitRun(["show", "\(ref):.kist/trust-bundle.json"], cwd: root)
        guard r.status == 0 else { return nil }
        return try? JSONDecoder().decode(SignedTrustBundle.self, from: r.data)
    }

    /// ANTI-ROLLBACK for trust bundles (Codex gate9 MED): a stale but still-root-valid bundle could re-trust a
    /// revoked issuer. Stateless + CI-native — compare the bundle at BASE vs HEAD: a PR that LOWERS the bundle's
    /// `issuedAtEpoch`, or REMOVES a bundle that was root-valid at base, is a trust DOWNGRADE and is refused. Only
    /// meaningful when a root is pinned and base actually had a valid bundle (new adoption / no-bundle → nothing to
    /// roll back). Returns a failure reason or nil.
    static func bundleRollbackReason(base: String, head: String, root: String) -> String? {
        let rootVerifier = TrustBundleVerifier(trustedRoots: ReceiptRootKeyStore.load().trustedKeys())
        return bundleTransitionReason(baseSigned: bundleAtRef(base, root: root),
                                      headSigned: bundleAtRef(head, root: root), rootVerifier: rootVerifier)
    }

    /// PURE transition policy for trust bundles (unit-testable, no git). Given the root-signed bundles at base and
    /// head (either may be nil = absent) and the pinned-root verifier, return a block reason or nil:
    ///  - no pinned root, or base has no root-valid bundle ⇒ nothing to roll back (nil).
    ///  - base had a valid bundle, head has none/invalid ⇒ block (downgrade).
    ///  - unchanged bundle ⇒ ok. Any CONTENT change must STRICTLY advance issuedAtEpoch, else block — enforces
    ///    "same epoch ⇒ identical payload" so a same/older-epoch bundle can't re-trust a revoked issuer (Codex).
    /// The root CAN un-revoke by issuing a HIGHER-epoch bundle (its prerogative); for irreversible revocation of
    /// COMPROMISED material also use local `--revoke-issuer`, which a bundle can never override.
    static func bundleTransitionReason(baseSigned: SignedTrustBundle?, headSigned: SignedTrustBundle?,
                                       rootVerifier: TrustBundleVerifier) -> String? {
        guard !rootVerifier.isEmpty else { return nil }
        guard let baseSigned, case .valid(let baseVB) = rootVerifier.verify(baseSigned) else { return nil }
        guard let headSigned, case .valid(let headVB) = rootVerifier.verify(headSigned) else {
            return "trust bundle removed or no longer root-valid vs base — refusing a trust downgrade"
        }
        // The signing ROOT must not change across a transition. With multiple pinned roots, swapping base's
        // restrictive root A for a permissive root B (both pinned) would otherwise be a cross-root downgrade
        // (Codex bg-gate). A deliberate root rotation is a separate, explicit operation.
        if headVB.bundle.rootKeyID != baseVB.bundle.rootKeyID {
            return "trust bundle switched signing root ('\(baseVB.bundle.rootKeyID)' → '\(headVB.bundle.rootKeyID)') "
                 + "— refusing a cross-root change that could downgrade trust"
        }
        if headSigned.canonicalBytes() == baseSigned.canonicalBytes() { return nil }
        if headVB.bundle.issuedAtEpoch <= baseVB.bundle.issuedAtEpoch {
            return "trust bundle changed without advancing issuedAtEpoch (head \(Int(headVB.bundle.issuedAtEpoch)) "
                 + "≤ base \(Int(baseVB.bundle.issuedAtEpoch))) — refusing a same/older-epoch content change that "
                 + "could re-trust a revoked issuer"
        }
        return nil
    }

    static func runReceiptCIGuard(_ opts: KistOptions) -> Int32 {
        let root = opts.project
        guard let (base, head) = resolveRange(opts: opts, root: root) else {
            rcptStderr("✗ kist CI-guard: could not resolve the commit range (base/head) — refusing to pass blind. "
                     + "Pass `--ci-guard <base> <head>` or run in a CI with GITHUB_BASE_REF/GITHUB_SHA set."); return 2
        }
        // Gate EVERY real (non-merge) commit's introduced content — NOT just the first-parent chain — so content
        // added on a side branch (even if later removed before an empty-net merge) is still gated (Codex HIGH:
        // --first-parent left an add-then-delete-then-merge history gap).
        let revList = gitOut(["rev-list", "--reverse", "--no-merges", "\(base)..\(head)"], cwd: root)
            .split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        let merges = gitOut(["rev-list", "--merges", "\(base)..\(head)"], cwd: root)
            .split(separator: "\n").map { String($0) }.filter { !$0.isEmpty }
        if revList.isEmpty && merges.isEmpty {
            rcptStderr("✓ kist CI-guard: no commits in \(base.prefix(8))..\(head.prefix(8)) — nothing to gate."); return 0
        }
        let (key, keyID) = ReceiptKey.load()
        if keyID != "env" {
            rcptStderr("⚠ kist CI-guard: KIST_RECEIPT_KEY not set (key '\(keyID)') — a local/ephemeral key WON'T "
                     + "match receipts sealed elsewhere. Set the org shared secret in CI or every commit fails closed.")
        }
        // ISSUER-SIGNATURE tier: when the verifier has PINNED issuer public keys, every gated change must ALSO
        // carry a valid Ed25519 attestation from a pinned issuer — closing the symmetric-key limit (an attacker
        // with KIST_RECEIPT_KEY still can't forge an issuer signature). Empty store ⇒ HMAC-only (same-trust-domain).
        let verifier = effectiveIssuerVerifier(projectRoot: root)
        if !verifier.isEmpty {
            rcptStderr("kist CI-guard: issuer-signature tier ACTIVE — every change must carry a pinned-issuer "
                     + "Ed25519 attestation in addition to its receipt.")
        }
        let store = ReceiptStore(projectRoot: root)
        var failures: [String] = []
        var gated = 0
        // Anti-rollback: refuse a PR that downgrades the root-signed trust bundle (re-trusting a revoked issuer).
        if let why = bundleRollbackReason(base: base, head: head, root: root) { failures.append("trust-bundle: \(why)") }
        for commit in revList {
            let short = String(commit.prefix(8))
            let base0 = against(commit, root: root)
            // Integrity FIRST: block a commit that hides content under the excluded receipts dir, even if the rest
            // of its diff is empty or receipted.
            if let why = receiptDirIntegrity(commit: commit, against: base0, root: root, key: key, verifier: verifier) {
                failures.append("\(short): \(why)"); continue
            }
            let (status, diff) = commitDiff(commit, against: base0, root: root)
            guard status == 0 else { failures.append("\(short): could not read diff (git exit \(status))"); continue }
            if diff.isEmpty { continue }   // no content (empty commit) → nothing to gate
            gated += 1
            let digest = ReceiptSubject.digest(ofDiff: diff)
            let decision = ReceiptGuard.decide(currentDiff: diff, key: key,
                                               lookup: { store.load(diffDigest: $0) })
            if case .reject(let why) = decision { failures.append("\(short): \(why)"); continue }
            // Issuer requirement (only when keys are pinned).
            if !verifier.isEmpty {
                guard let att = store.loadAttestation(diffDigest: digest),
                      case .valid = verifier.verify(att, diffDigest: digest) else {
                    failures.append("\(short): no valid pinned-issuer signature for this change "
                                  + "(sign it with `kist --sign-receipt`)"); continue
                }
            }
        }
        // A clean merge introduces nothing new; an EVIL merge (conflict resolution / crafted content) adds content
        // present in no parent → un-receipted → block it (Codex: merges must not be a coverage gap).
        for merge in merges {
            let bad = evilMergePaths(merge, root: root)
            if !bad.isEmpty {
                failures.append("\(merge.prefix(8)): merge introduces un-receipted content (resolve it in a normal "
                              + "receipted commit, or squash/rebase): \(bad.prefix(8).joined(separator: ", "))")
            }
        }
        if failures.isEmpty {
            rcptStderr("✓ kist CI-guard: all \(gated) content-bearing commit(s) in \(base.prefix(8))..\(head.prefix(8)) "
                     + "carry a valid verification receipt."); return 0
        }
        rcptStderr("✗ kist CI-guard BLOCKED — \(failures.count) commit(s) lack a valid receipt:")
        for f in failures { rcptStderr("   • \(f)") }
        rcptStderr("Produce receipts locally with `kist --verify` before committing, and commit .kist/receipts/.")
        return 1
    }
}
