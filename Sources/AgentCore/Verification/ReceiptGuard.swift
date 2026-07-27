import Foundation

/// THE GUARD DECISION — the single call the git-guard hook and the GitHub App both make: may the change
/// described by `currentDiff` merge? Core policy: a change with NO valid, seal-intact, diff-bound, passing
/// receipt NEVER merges. This is what makes the receipt a HARD gate, not advisory.
public enum ReceiptGuard {
    public static func decide(currentDiff: String, key: Data,
                              lookup: (_ diffDigest: String) -> SealedReceipt?) -> ReceiptSeal.Admission {
        let digest = ReceiptSubject.digest(ofDiff: currentDiff)
        guard let sealed = lookup(digest) else {
            return .reject("no verification receipt covers this change (digest \(digest.prefix(12))…) — "
                         + "run `kist verify` to produce one, then retry the merge.")
        }
        return ReceiptSeal.admit(sealed, forDiff: currentDiff, key: key)
    }
}

/// File-backed receipt store, keyed by the change's diffDigest, under `<root>/.kist/receipts/`. A receipt is a
/// discrete file so it can be committed, shared, or attached to a PR. Fail-soft on read (a corrupt file just
/// means "no receipt" ⇒ the guard rejects — fail-closed).
public struct ReceiptStore {
    public let dir: String
    public init(projectRoot: String) {
        self.dir = (projectRoot as NSString).appendingPathComponent(".kist/receipts")
    }

    private func path(for digest: String) -> String {
        (dir as NSString).appendingPathComponent("\(digest).json")
    }

    @discardableResult
    public func save(_ sealed: SealedReceipt) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Write the CANONICAL bytes (sorted-key, no pretty whitespace) so a committed receipt file can be
        // authenticated byte-for-byte — the guard requires the file to equal exactly this (no smuggled wrapper).
        let data = sealed.canonicalBytes()
        guard !data.isEmpty else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path(for: sealed.receipt.subject.diffDigest)))) != nil
    }

    public func load(diffDigest: String) -> SealedReceipt? {
        guard let data = FileManager.default.contents(atPath: path(for: diffDigest)) else { return nil }
        return try? JSONDecoder().decode(SealedReceipt.self, from: data)
    }

    // MARK: Issuer-signature sidecars (`.kist/receipts/<digest>.sig.json`)

    private func sigPath(for digest: String) -> String {
        (dir as NSString).appendingPathComponent("\(digest).sig.json")
    }

    /// Save an issuer attestation sidecar (canonical bytes, so it whole-file-authenticates like the sealed receipt).
    @discardableResult
    public func saveAttestation(_ attested: AttestedReceipt) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = attested.canonicalBytes()
        guard !data.isEmpty else { return false }
        return (try? data.write(to: URL(fileURLWithPath: sigPath(for: attested.approval.diffDigest)))) != nil
    }

    public func loadAttestation(diffDigest: String) -> AttestedReceipt? {
        guard let data = FileManager.default.contents(atPath: sigPath(for: diffDigest)) else { return nil }
        return try? JSONDecoder().decode(AttestedReceipt.self, from: data)
    }
}
