import Foundation

/// The sealing key for verification receipts. Precedence: KIST_RECEIPT_KEY env (CI / org-shared) → a
/// per-install key file (`~/.kist/receipt-key`, 0600, generated once). The keyID lets a verifier know which
/// key a receipt was sealed with (rotation-ready). NOTE: HMAC is a per-install/org SHARED-secret seal (integrity
/// + tamper-evidence within a trust domain); the roadmap's cross-org "public-good receipt" tier upgrades this to
/// Ed25519 signatures (kist already has that primitive in the fleet deploy gate) — tracked, not yet wired.
public enum ReceiptKey {
    /// Minimum bytes for an env-supplied shared secret. Hygiene only: it rejects a trivially-weak key (e.g. a lazy
    /// `KIST_RECEIPT_KEY=x` injection), NOT an attacker who supplies their own STRONG key to seal+validate their
    /// own receipt — that is the same-trust-domain HMAC limit (docs/kist/RECEIPT_THREAT_MODEL.md), fixed only by
    /// the cross-org Ed25519 / keyID-pinning tier, not by a length check.
    public static let minEnvKeyBytes = 16

    public static func load(home: String = NSHomeDirectory()) -> (key: Data, keyID: String) {
        if let env = ProcessInfo.processInfo.environment["KIST_RECEIPT_KEY"], env.utf8.count >= minEnvKeyBytes {
            return (Data(env.utf8), "env")
        }
        let path = (home as NSString).appendingPathComponent(".kist/receipt-key")

        // Read an EXISTING key only if it's trustworthy: a regular file (not a symlink — no follow to an
        // attacker-planted target), owned by us, mode exactly 0600 (Codex round 2). A file that exists but is
        // untrusted is NOT used and NOT overwritten (fail-closed: an ephemeral key ⇒ everything rejects until the
        // user fixes it, rather than silently trusting a compromised key or clobbering it).
        switch inspectKeyFile(path) {
        case .trusted(let data): return (data, "install")
        case .untrusted(let why):
            let msg = "⚠ kist: ignoring untrusted receipt key at \(path) (\(why)); "
                    + "receipts will fail closed until you remove/repair it.\n"
            FileHandle.standardError.write(Data(msg.utf8))
            return (MythosCrypto.randomKey(), "ephemeral")
        case .absent: break
        }

        // No key yet — create it with O_EXCL so a racing process can't be overwritten, and 0600 at creation (no
        // write-then-chmod window). If we lost the race (EEXIST), re-read the winner (validated).
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let key = MythosCrypto.randomKey()
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            key.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
            close(fd)
            return (key, "install")
        }
        // Lost the race (or can't create) — trust the existing file only if it validates.
        if case .trusted(let data) = inspectKeyFile(path) { return (data, "install") }
        return (MythosCrypto.randomKey(), "ephemeral")
    }

    private enum KeyFileState { case trusted(Data), untrusted(String), absent }

    /// Validate the key file with lstat (no symlink follow) before trusting its bytes.
    private static func inspectKeyFile(_ path: String) -> KeyFileState {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .absent }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .untrusted("is a symlink") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .untrusted("not a regular file") }
        guard st.st_uid == geteuid() else { return .untrusted("not owned by current user") }
        guard (st.st_mode & 0o777) == 0o600 else { return .untrusted("mode is not 0600") }
        guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            return .untrusted("empty")
        }
        return .trusted(data)
    }
}

/// The verify + guard orchestration (injectable inputs → unit-testable without git/process). The thin CLI layer
/// in KistRunner supplies the real git diff + command runner.
public enum ReceiptCLI {

    /// Produce, seal, and STORE a receipt for a change. Runs the built-in deterministic scans plus any
    /// `commandChecks` (compile/tests) the caller evaluated. Returns the sealed receipt + whether it stored.
    public static func verify(projectRoot: String, baseSHA: String, changedFiles: [String], diff: String,
                              commandChecks: [ReceiptCheck], key: (Data, String), now: Double,
                              issuer: String) -> (sealed: SealedReceipt, saved: Bool) {
        let subject = ReceiptSubject(baseSHA: baseSHA, changedFiles: changedFiles,
                                     diffDigest: ReceiptSubject.digest(ofDiff: diff))
        let checks = ReceiptChecks.runBuiltins(diff: diff) + commandChecks
        let receipt = VerificationReceipt(subject: subject, checks: checks, issuedAtEpoch: now, issuer: issuer)
        let sealed = ReceiptSeal.seal(receipt, key: key.0, keyID: key.1)
        let saved = ReceiptStore(projectRoot: projectRoot).save(sealed)
        return (sealed, saved)
    }

    /// The guard decision for a change (looks the receipt up in the store by digest).
    public static func guardDecision(projectRoot: String, diff: String, key: Data) -> ReceiptSeal.Admission {
        let store = ReceiptStore(projectRoot: projectRoot)
        return ReceiptGuard.decide(currentDiff: diff, key: key, lookup: { store.load(diffDigest: $0) })
    }

    /// Human summary of a receipt for the terminal.
    public static func summary(_ sealed: SealedReceipt) -> String {
        let r = sealed.receipt
        let lines = r.checks.map { "  \($0.passed ? "✓" : "✗") \($0.name)\($0.required ? "" : " (advisory)") — \($0.detail)" }
        return "receipt · verdict \(r.verdict.rawValue.uppercased()) · \(r.subject.changedFiles.count) file(s) · "
             + "digest \(r.subject.diffDigest.prefix(12))…\n" + lines.joined(separator: "\n")
    }
}
