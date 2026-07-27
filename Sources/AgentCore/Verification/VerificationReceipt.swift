import Foundation

/// THE VERIFICATION RECEIPT — the compliance primitive kist's leapfrog strategy hangs on
/// (docs/kist/LEAPFROG_ROADMAP_2026.md). A receipt is a machine-checkable attestation that a SPECIFIC change
/// (bound to its exact diff bytes) passed a set of deterministic + model-judged checks. Merges require a valid,
/// seal-intact receipt whose diffDigest matches the change being merged — so a receipt can NEVER be reused for a
/// different change, and can't be edited without the sealing key (tamper-evident).
///
/// Design goals: (1) deterministic canonical form (sorted-key JSON) so the digest/seal are reproducible;
/// (2) the receipt BINDS to the diff via a SHA-256 digest of the canonical diff; (3) transport-agnostic +
/// open (this schema is the public-good format other agents emit; the high-assurance council stays proprietary).
public struct VerificationReceipt: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var subject: ReceiptSubject
    public var checks: [ReceiptCheck]
    public var verdict: ReceiptVerdict
    public var issuedAtEpoch: Double
    public var issuer: String            // e.g. "kist/<version>" or a signer id

    public init(subject: ReceiptSubject, checks: [ReceiptCheck], issuedAtEpoch: Double,
                issuer: String, schema: Int = VerificationReceipt.currentSchema) {
        self.schema = schema
        self.subject = subject
        self.checks = checks
        self.issuedAtEpoch = issuedAtEpoch
        self.issuer = issuer
        // The verdict is DERIVED, never hand-set: PASS iff every REQUIRED check passed. A missing required
        // check ⇒ incomplete (not pass). This makes "pass" un-fakeable at construction.
        self.verdict = VerificationReceipt.derive(checks: checks)
    }

    /// PASS iff there is ≥1 check and every REQUIRED check passed; FAIL if any required failed; INCOMPLETE
    /// if there are no checks at all (nothing was actually verified — never silently "pass").
    static func derive(checks: [ReceiptCheck]) -> ReceiptVerdict {
        let required = checks.filter { $0.required }
        if checks.isEmpty || required.isEmpty { return .incomplete }
        if required.contains(where: { !$0.passed }) { return .fail }
        return .pass
    }

    /// Canonical bytes for digest + seal: sorted-key JSON, no whitespace. Deterministic across runs/platforms.
    public func canonicalBytes() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }
}

/// WHAT was verified — bound to the exact change by `diffDigest`.
public struct ReceiptSubject: Codable, Equatable, Sendable {
    public var baseSHA: String           // the base commit the diff is measured against
    public var changedFiles: [String]    // sorted, for human/audit readability
    public var diffDigest: String        // hex SHA-256 of the CANONICAL diff — binds the receipt to exact bytes

    public init(baseSHA: String, changedFiles: [String], diffDigest: String) {
        self.baseSHA = baseSHA
        self.changedFiles = changedFiles.sorted()
        self.diffDigest = diffDigest
    }

    /// The canonical diff digest: hex SHA-256 over the diff's UTF-8 bytes. The single source of binding.
    public static func digest(ofDiff diff: String) -> String {
        MythosCrypto.sha256(Data(diff.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One check that ran. `deterministic` checks (compile/tests/static-analysis) are the cheap, model-independent
/// backbone; `modelJudged` checks (council verdicts) are recorded but are advisory unless marked required.
public struct ReceiptCheck: Codable, Equatable, Sendable {
    public var name: String
    public var kind: CheckKind
    public var passed: Bool
    public var required: Bool
    public var detail: String

    public init(name: String, kind: CheckKind, passed: Bool, required: Bool = true, detail: String = "") {
        self.name = name; self.kind = kind; self.passed = passed; self.required = required; self.detail = detail
    }
}

public enum CheckKind: String, Codable, Sendable { case deterministic, modelJudged }
public enum ReceiptVerdict: String, Codable, Sendable { case pass, fail, incomplete }
