import Foundation

/// A receipt + its HMAC seal. The seal makes the sealed receipt tamper-evident: any edit to the receipt OR the
/// keyID (flipping the verdict, swapping the diffDigest, rewriting keyID) invalidates the tag unless the attacker
/// holds the key. `sealTag` itself is not covered (it IS the tag).
public struct SealedReceipt: Codable, Equatable, Sendable {
    public var receipt: VerificationReceipt
    public var sealTag: String   // hex HMAC-SHA256 over signableBytes(receipt, keyID) — the {keyID, receipt} envelope
    public var keyID: String     // identifies the sealing key (supports rotation); AUTHENTICATED by the seal

    public init(receipt: VerificationReceipt, sealTag: String, keyID: String) {
        self.receipt = receipt; self.sealTag = sealTag; self.keyID = keyID
    }

    /// Canonical on-disk bytes for a stored receipt: sorted-key JSON, no pretty whitespace. Deterministic, so a
    /// committed receipt file can be authenticated byte-for-byte (nothing extra may hide around the sealed object).
    public func canonicalBytes() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }
}

/// Seal + the ADMISSION GATE. `admit` is the single decision the git-guard / PR-check calls: it returns
/// `.admit` ONLY when all three fail-closed conditions hold, else `.reject(reason)`.
public enum ReceiptSeal {

    /// Bytes the HMAC seal covers: the receipt AND the keyID (every field the file carries except the tag itself).
    /// Sealing keyID too closes the smuggle where keyID is attacker-controlled unauthenticated free text that still
    /// passes byte-equality (Codex CRITICAL). Encoded as a canonical envelope so the boundary is unambiguous.
    private struct SealPayload: Encodable { let keyID: String; let receipt: VerificationReceipt }
    static func signableBytes(receipt: VerificationReceipt, keyID: String) -> Data {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(SealPayload(keyID: keyID, receipt: receipt))) ?? Data()
    }

    public static func seal(_ receipt: VerificationReceipt, key: Data, keyID: String) -> SealedReceipt {
        let tag = MythosCrypto.hmacSHA256(key: key, message: signableBytes(receipt: receipt, keyID: keyID))
        return SealedReceipt(receipt: receipt, sealTag: ReceiptHex.encode(tag), keyID: keyID)
    }

    /// True iff the seal is intact under `key` (HMAC only — no diff/verdict check). Authenticates BOTH the receipt
    /// and the keyID (the `{keyID, receipt}` envelope). One half of whole-file auth (`authenticateReceiptFile`),
    /// which additionally requires the file bytes to equal the canonical serialization (no wrapper/trailing bytes).
    public static func sealValid(_ sealed: SealedReceipt, key: Data) -> Bool {
        guard let tag = ReceiptHex.decode(sealed.sealTag) else { return false }
        return MythosCrypto.hmacSHA256Valid(
            key: key, message: signableBytes(receipt: sealed.receipt, keyID: sealed.keyID), tag: tag)
    }

    /// Authenticate a committed receipt FILE END-TO-END. The seal only covers the `receipt` sub-object, so
    /// `decode + sealValid` alone would let an attacker WRAP a valid sealed receipt with extra unauthenticated
    /// content (extra JSON keys, trailing bytes) and smuggle it into the diff-excluded `.kist/receipts/` dir
    /// (Codex stop-gate). Requiring the file bytes to EQUAL the canonical re-serialization of the decoded receipt
    /// leaves no room for anything but a canonical, seal-valid receipt. `JSONDecoder` drops unknown keys, so any
    /// wrapper content is discarded on decode → the re-encode won't match the original bytes → rejected.
    public static func authenticateReceiptFile(_ data: Data, key: Data) -> Bool {
        guard let sealed = try? JSONDecoder().decode(SealedReceipt.self, from: data) else { return false }
        // Canonical sealTag hex too (not just canonical JSON) so casing can't smuggle bytes past byte-equality.
        return ReceiptHex.isCanonical(sealed.sealTag) && sealValid(sealed, key: key) && sealed.canonicalBytes() == data
    }

    public enum Admission: Equatable, Sendable {
        case admit
        case reject(String)
        public var isAdmitted: Bool { if case .admit = self { return true }; return false }
    }

    /// Admit a change for merge ONLY IF:
    ///   1. the seal is intact (not forged / correct key), AND
    ///   2. the receipt is bound to THIS EXACT diff (diffDigest == SHA-256 of the presented diff), AND
    ///   3. the verdict DERIVED FROM THE CHECKS is `pass` AND the stored verdict agrees.
    /// Any failure ⇒ reject with a reason. Fail-closed throughout — a malformed tag, a stale/other-change
    /// receipt, an inconsistent/non-pass verdict all block the merge.
    public static func admit(_ sealed: SealedReceipt, forDiff diff: String, key: Data) -> Admission {
        guard ReceiptHex.decode(sealed.sealTag) != nil else {
            return .reject("receipt seal is malformed")
        }
        guard sealValid(sealed, key: key) else {   // covers receipt + keyID (Codex CRITICAL: keyID was unauthenticated)
            return .reject("receipt seal invalid — forged, edited, or wrong key")
        }
        let expected = ReceiptSubject.digest(ofDiff: diff)
        guard sealed.receipt.subject.diffDigest == expected else {
            return .reject("receipt does not cover this change (diff digest mismatch — a receipt is only valid "
                         + "for the exact diff it verified)")
        }
        // RE-DERIVE the verdict from the checks — never trust the stored `verdict` field. `verdict` is mutable +
        // Codable-decoded, so a key holder could hand-flip it to `.pass` on failing checks and re-seal. Deriving
        // here makes admission a pure function of the CHECKS; the stored field must also agree (else it's been
        // tampered into an inconsistent state) — both are required, fail-closed. (Codex gate finding.)
        let derived = VerificationReceipt.derive(checks: sealed.receipt.checks)
        guard sealed.receipt.verdict == derived else {
            return .reject("receipt verdict '\(sealed.receipt.verdict.rawValue)' is inconsistent with its checks "
                         + "(they derive '\(derived.rawValue)') — receipt was edited")
        }
        guard derived == .pass else {
            return .reject("receipt checks do not derive a pass (derived '\(derived.rawValue)')")
        }
        return .admit
    }
}

/// Minimal hex codec (kept local so the receipt module has no external hex dependency).
enum ReceiptHex {
    static func encode(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    /// True iff `hex` is the CANONICAL encoding of its bytes (lowercase, even length) — so hex casing can't be a
    /// covert byte channel in a byte-canonical receipt (Codex gate7 LOW).
    static func isCanonical(_ hex: String) -> Bool { decode(hex).map { encode($0) == hex } ?? false }
    static func decode(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            out.append(byte); i += 2
        }
        return out
    }
}
