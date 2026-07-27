import XCTest
@testable import AgentCore

/// The Verification Receipt is the compliance primitive the whole leapfrog strategy hangs on, so its security
/// invariants are pinned hard: a receipt binds to the EXACT diff, verdict is derived (un-fakeable), and the
/// admission gate is fail-closed against tamper / wrong-change / wrong-key / non-pass.
final class VerificationReceiptTests: XCTestCase {
    private let key = Data("test-sealing-key-0123456789".utf8)
    private let diff = "diff --git a/x.swift b/x.swift\n+let a = 1\n"

    private func receipt(checks: [ReceiptCheck], diff: String) -> VerificationReceipt {
        VerificationReceipt(
            subject: ReceiptSubject(baseSHA: "base123", changedFiles: ["x.swift"],
                                    diffDigest: ReceiptSubject.digest(ofDiff: diff)),
            checks: checks, issuedAtEpoch: 1_700_000_000, issuer: "kist/test")
    }
    private var passingChecks: [ReceiptCheck] {
        [ReceiptCheck(name: "compile", kind: .deterministic, passed: true),
         ReceiptCheck(name: "tests", kind: .deterministic, passed: true)]
    }

    func testDiffDigestIsDeterministicAndBinds() {
        XCTAssertEqual(ReceiptSubject.digest(ofDiff: diff), ReceiptSubject.digest(ofDiff: diff))
        XCTAssertNotEqual(ReceiptSubject.digest(ofDiff: diff), ReceiptSubject.digest(ofDiff: diff + " "))
    }

    func testVerdictDerivedNotHandSet() {
        XCTAssertEqual(receipt(checks: passingChecks, diff: diff).verdict, .pass)
        XCTAssertEqual(receipt(checks: [ReceiptCheck(name: "tests", kind: .deterministic, passed: false)], diff: diff).verdict, .fail)
        XCTAssertEqual(receipt(checks: [], diff: diff).verdict, .incomplete, "no checks ⇒ never silently pass")
        // A failed OPTIONAL check does not fail the receipt; a missing REQUIRED backbone does gate it.
        let optionalFail = [ReceiptCheck(name: "council", kind: .modelJudged, passed: false, required: false),
                            ReceiptCheck(name: "compile", kind: .deterministic, passed: true)]
        XCTAssertEqual(receipt(checks: optionalFail, diff: diff).verdict, .pass)
    }

    func testSealRoundTripAdmitsTheExactChange() {
        let sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "k1")
        XCTAssertEqual(ReceiptSeal.admit(sealed, forDiff: diff, key: key), .admit)
    }

    func testTamperedVerdictIsRejected() {
        var sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "k1")
        sealed.receipt.verdict = .pass   // already pass; now try to smuggle a pass onto a FAILED receipt:
        var failed = ReceiptSeal.seal(receipt(checks: [ReceiptCheck(name: "tests", kind: .deterministic, passed: false)], diff: diff), key: key, keyID: "k1")
        failed.receipt.verdict = .pass   // hand-flip the sealed receipt's verdict
        if case .reject = ReceiptSeal.admit(failed, forDiff: diff, key: key) {} else {
            XCTFail("a hand-edited verdict must break the seal and be rejected")
        }
        _ = sealed
    }

    func testReceiptForADifferentChangeIsRejected() {
        let sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "k1")
        let otherDiff = "diff --git a/y.swift b/y.swift\n+let evil = true\n"
        if case .reject(let why) = ReceiptSeal.admit(sealed, forDiff: otherDiff, key: key) {
            XCTAssertTrue(why.contains("diff digest mismatch"))
        } else { XCTFail("a receipt must not admit a change it didn't verify") }
    }

    func testNonPassVerdictIsRejected() {
        let sealed = ReceiptSeal.seal(receipt(checks: [ReceiptCheck(name: "tests", kind: .deterministic, passed: false)], diff: diff), key: key, keyID: "k1")
        if case .reject(let why) = ReceiptSeal.admit(sealed, forDiff: diff, key: key) {
            XCTAssertTrue(why.contains("do not derive a pass"), "got: \(why)")
        } else { XCTFail("a failed receipt must be rejected") }
    }

    func testWrongKeyIsRejected() {
        let sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "k1")
        if case .reject = ReceiptSeal.admit(sealed, forDiff: diff, key: Data("attacker-key".utf8)) {} else {
            XCTFail("a receipt sealed with a different key must be rejected")
        }
    }

    func testMalformedTagIsRejected() {
        var sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "k1")
        sealed.sealTag = "zzzz"   // not valid hex
        if case .reject = ReceiptSeal.admit(sealed, forDiff: diff, key: key) {} else {
            XCTFail("a malformed seal tag must be rejected")
        }
    }

    /// Codex gate: a KEY HOLDER hand-flips the verdict to `.pass` on FAILING checks, then RE-SEALS (so the seal
    /// is valid over the tampered receipt). Admission must still reject because it RE-DERIVES the verdict from the
    /// checks and requires the stored field to agree — the verdict is not a trusted stored value.
    func testResealedInconsistentVerdictIsRejected() {
        var r = receipt(checks: [ReceiptCheck(name: "tests", kind: .deterministic, passed: false)], diff: diff)
        XCTAssertEqual(r.verdict, .fail)         // derived at init
        r.verdict = .pass                        // smuggle a pass onto failing checks
        let sealed = ReceiptSeal.seal(r, key: key, keyID: "k1")   // re-seal → HMAC is VALID over the tampered receipt
        if case .reject(let why) = ReceiptSeal.admit(sealed, forDiff: diff, key: key) {
            XCTAssertTrue(why.contains("inconsistent"), "must reject on verdict/checks inconsistency, got: \(why)")
        } else { XCTFail("a re-sealed receipt whose verdict disagrees with its checks must be rejected") }
    }

    /// And the honest inverse: an all-passing set with the verdict flipped to `.fail` and re-sealed is also
    /// rejected (still inconsistent) — the derive() function is the single source of truth, both directions.
    func testResealedPassFlippedToFailIsRejected() {
        var r = receipt(checks: passingChecks, diff: diff)
        r.verdict = .fail
        let sealed = ReceiptSeal.seal(r, key: key, keyID: "k1")
        XCTAssertFalse(ReceiptSeal.admit(sealed, forDiff: diff, key: key).isAdmitted)
    }

    /// Dogfood HOLE B: `sealValid` certifies a file under the excluded receipts dir is a genuine sealed receipt.
    /// True for a real receipt; false the moment any byte of it is edited (tamper) or the key is wrong.
    func testSealValidTrueForRealReceiptFalseForTampered() {
        let sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "k1")
        XCTAssertTrue(ReceiptSeal.sealValid(sealed, key: key))
        var tampered = sealed; tampered.receipt.issuer = "HACKED"      // edit inside the sealed canonical region
        XCTAssertFalse(ReceiptSeal.sealValid(tampered, key: key), "an edited receipt must not seal-validate")
        XCTAssertFalse(ReceiptSeal.sealValid(sealed, key: Data("other".utf8)), "wrong key must not validate")
    }

    /// Codex stop-gate: whole-FILE authentication. The seal only covers the receipt sub-object, so a valid receipt
    /// WRAPPED with extra content (an injected JSON key carrying a payload) would pass a decode+sealValid check but
    /// smuggle bytes into the excluded dir. `authenticateReceiptFile` requires the file to equal the canonical
    /// serialization exactly → any wrapper/trailing/reformat is rejected.
    func testAuthenticateReceiptFileRejectsWrappedContent() {
        let sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "k1")
        let canonical = sealed.canonicalBytes()
        XCTAssertTrue(ReceiptSeal.authenticateReceiptFile(canonical, key: key), "canonical file authenticates")
        // Inject an extra top-level key while keeping receipt/sealTag/keyID intact (JSONDecoder would drop it).
        var obj = try! JSONSerialization.jsonObject(with: canonical) as! [String: Any]
        obj["EVIL"] = "backdoor AKIAIOSFODNN7EXAMPLE"
        let wrapped = try! JSONSerialization.data(withJSONObject: obj)
        XCTAssertFalse(ReceiptSeal.authenticateReceiptFile(wrapped, key: key),
                       "a valid receipt WRAPPED with extra content must NOT authenticate")
        // Trailing bytes after valid JSON also rejected.
        XCTAssertFalse(ReceiptSeal.authenticateReceiptFile(canonical + Data("  \n".utf8), key: key))
        XCTAssertFalse(ReceiptSeal.authenticateReceiptFile(canonical, key: Data("wrong-key".utf8)))
    }

    /// Codex gate5 CRITICAL: `keyID` must be AUTHENTICATED by the seal. Byte-equality alone let an attacker put a
    /// payload in a canonical file's keyID string. Changing keyID must now break the seal.
    func testKeyIDIsAuthenticated() {
        let sealed = ReceiptSeal.seal(receipt(checks: passingChecks, diff: diff), key: key, keyID: "install")
        XCTAssertTrue(ReceiptSeal.sealValid(sealed, key: key))
        var forged = sealed
        forged.keyID = "SMUGGLED-PAYLOAD-AKIAIOSFODNN7EXAMPLE"      // rewrite only keyID, keep receipt + tag
        XCTAssertFalse(ReceiptSeal.sealValid(forged, key: key), "a rewritten keyID must break the seal")
        XCTAssertFalse(ReceiptSeal.authenticateReceiptFile(forged.canonicalBytes(), key: key),
                       "a canonical file with a tampered keyID must not authenticate")
        XCTAssertFalse(ReceiptSeal.admit(forged, forDiff: diff, key: key).isAdmitted)
    }
}
