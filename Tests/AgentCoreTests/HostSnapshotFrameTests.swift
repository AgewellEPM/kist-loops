import XCTest
@testable import AgentCore

// PROTOTYPE — host_snapshot frame crypto contract. Pure tests: canonical-string injectivity, sign/verify
// round-trip, and tamper-detection on the two security-critical bound fields (sha256, captured_at).
final class HostSnapshotFrameTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()          // deterministic HMAC key; never touches ~/.mythos
        HostSnapshotSigner.forceEphemeralKeyForTesting() // deterministic Ed25519 key; never touches ~/.mythos
    }
    override func tearDown() {
        ForgeSeal.resetCacheForTesting()
        HostSnapshotSigner.resetCacheForTesting()
        super.tearDown()
    }

    // Canonical injectivity: a `|` or `=` embedded in ANY value cannot collide with a different logical
    // record, because ForgeSeal.field() percent-encodes every non-alphanumeric.
    func testCanonicalStringIsInjectiveAcrossDelimiterInjection() {
        // Two logically DIFFERENT records that a naive join would collide.
        let a = HostSnapshotFrame.canonicalString(capturedAt: "2026-01-01T00:00:00Z", source: "tinkystream|width=9",
                                                  displayIndex: 0, width: 100, height: 50, sha256Hex: "aa")
        let b = HostSnapshotFrame.canonicalString(capturedAt: "2026-01-01T00:00:00Z", source: "tinkystream",
                                                  displayIndex: 0, width: 9, height: 50, sha256Hex: "aa")
        XCTAssertNotEqual(a, b, "delimiter injection in `source` must not collide with a different width field")
        // And an `=` injection can't fabricate a new key/value pair.
        let c = HostSnapshotFrame.canonicalString(capturedAt: "x=y", source: "s", displayIndex: 0,
                                                  width: 1, height: 1, sha256Hex: "z")
        XCTAssertFalse(c.contains("captured_at=x=y"), "raw `=` must be percent-encoded, never a literal delimiter")
    }

    func testSignVerifyRoundTrip() {
        let png = Self.tinyPNG(width: 4, height: 3)
        let frame = HostSnapshotFrame.signed(pngBytes: png, capturedAt: "2026-09-01T12:00:00Z",
                                             source: "tinkystream", displayIndex: 0, displayCount: 1,
                                             width: 4, height: 3)!
        XCTAssertFalse(frame.signature.isEmpty, "an install with a key must produce a non-empty signature")
        XCTAssertTrue(frame.signatureIsValid, "a freshly-signed frame must verify (HMAC, host-side)")
        // sha256 field must be the digest of the RAW png bytes (not the base64).
        let expected = MythosCrypto.sha256(png).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(frame.sha256Hex, expected)
    }

    // Ed25519 — the GUEST verification path: a frame's ed25519 sig verifies against the EXPORTED public key
    // WITHOUT any host secret (proves a real guest could verify it). Named the "guest's path".
    func testEd25519VerifiesWithExportedPublicKeyTheGuestsPath() throws {
        let png = Self.tinyPNG(width: 4, height: 3)
        let frame = HostSnapshotFrame.signed(pngBytes: png, capturedAt: "2026-09-01T12:00:00Z",
                                             source: "tinkystream", displayIndex: 0, displayCount: 1,
                                             width: 4, height: 3)!
        XCTAssertFalse(frame.ed25519.isEmpty, "a signed frame must carry a non-empty ed25519 signature")
        XCTAssertFalse(frame.keyID.isEmpty, "a signed frame must carry a key_id")
        // The guest holds ONLY the exported public key (base64) — NO host secret.
        let pubRaw = try HostSnapshotSigner.publicKeyRaw()
        XCTAssertTrue(frame.ed25519IsValid(publicKeyRaw: pubRaw), "the guest must verify ed25519 with only the public key")
        // key_id is the exported key's fingerprint.
        XCTAssertEqual(frame.keyID, HostSnapshotSigner.keyID(forPublicKeyRaw: pubRaw))
        // A DIFFERENT public key must NOT verify (fail-closed).
        let other = MythosCrypto.ed25519GenerateKeyPair()
        XCTAssertFalse(frame.ed25519IsValid(publicKeyRaw: other.publicRaw), "a wrong pinned key must not verify")
    }

    // Tampering ANY signed field breaks BOTH signatures. Per multi-site discipline, assert every covered
    // field individually against the guest-verifiable ed25519 path.
    func testTamperingAnySignedFieldBreaksEd25519() throws {
        let png = Self.tinyPNG(width: 4, height: 3)
        let f = HostSnapshotFrame.signed(pngBytes: png, capturedAt: "2026-09-01T12:00:00Z",
                                         source: "tinkystream", displayIndex: 0, displayCount: 1,
                                         width: 4, height: 3, nonce: "aa11")!
        let pubRaw = try HostSnapshotSigner.publicKeyRaw()
        func tampered(_ mutate: (inout Fields) -> Void) -> HostSnapshotFrame {
            var x = Fields(f)
            mutate(&x)
            return HostSnapshotFrame(capturedAt: x.capturedAt, source: x.source, displayIndex: x.displayIndex,
                                     displayCount: f.displayCount, width: x.width, height: x.height,
                                     nonce: x.nonce, pngBase64: f.pngBase64, sha256Hex: x.sha256,
                                     signature: f.signature, ed25519: f.ed25519, keyID: f.keyID)
        }
        // Each covered field, named — a swap on ANY of them must fail the guest's ed25519 check AND the HMAC.
        XCTAssertFalse(tampered { $0.sha256 = String(repeating: "0", count: 64) }.ed25519IsValid(publicKeyRaw: pubRaw), "sha256")
        XCTAssertFalse(tampered { $0.sha256 = String(repeating: "0", count: 64) }.signatureIsValid, "sha256 (hmac)")
        XCTAssertFalse(tampered { $0.capturedAt = "1999-01-01T00:00:00Z" }.ed25519IsValid(publicKeyRaw: pubRaw), "captured_at")
        XCTAssertFalse(tampered { $0.source = "screencapture" }.ed25519IsValid(publicKeyRaw: pubRaw), "source")
        XCTAssertFalse(tampered { $0.displayIndex = 7 }.ed25519IsValid(publicKeyRaw: pubRaw), "display_index")
        XCTAssertFalse(tampered { $0.width = 999 }.ed25519IsValid(publicKeyRaw: pubRaw), "width")
        XCTAssertFalse(tampered { $0.height = 999 }.ed25519IsValid(publicKeyRaw: pubRaw), "height")
        XCTAssertFalse(tampered { $0.nonce = "bb22" }.ed25519IsValid(publicKeyRaw: pubRaw), "nonce")
        // Sanity: the untampered frame still verifies.
        XCTAssertTrue(f.ed25519IsValid(publicKeyRaw: pubRaw))
    }

    // A mutable bag of the signed fields, for the tamper matrix above.
    private struct Fields {
        var capturedAt: String, source: String, displayIndex: Int, width: Int, height: Int, nonce: String, sha256: String
        init(_ f: HostSnapshotFrame) {
            capturedAt = f.capturedAt; source = f.source; displayIndex = f.displayIndex
            width = f.width; height = f.height; nonce = f.nonce; sha256 = f.sha256Hex
        }
    }

    func testTamperedSha256FailsVerify() {
        let png = Self.tinyPNG(width: 4, height: 3)
        let frame = HostSnapshotFrame.signed(pngBytes: png, capturedAt: "2026-09-01T12:00:00Z",
                                             source: "tinkystream", displayIndex: 0, displayCount: 1,
                                             width: 4, height: 3)!
        // Swap in a DIFFERENT sha256 but keep the original signature (a replay-onto-other-bytes attempt).
        let tampered = HostSnapshotFrame(capturedAt: frame.capturedAt, source: frame.source,
                                         displayIndex: frame.displayIndex, displayCount: frame.displayCount,
                                         width: frame.width, height: frame.height, nonce: frame.nonce,
                                         pngBase64: frame.pngBase64, sha256Hex: String(repeating: "0", count: 64),
                                         signature: frame.signature)
        XCTAssertFalse(tampered.signatureIsValid, "a swapped sha256 (different frame bytes) must fail verify")
    }

    func testTamperedCapturedAtFailsVerify() {
        let png = Self.tinyPNG(width: 4, height: 3)
        let frame = HostSnapshotFrame.signed(pngBytes: png, capturedAt: "2026-09-01T12:00:00Z",
                                             source: "tinkystream", displayIndex: 0, displayCount: 1,
                                             width: 4, height: 3)!
        // Replay the SAME signed bytes under a NEW timestamp — must fail (signature binds captured_at).
        let replayed = HostSnapshotFrame(capturedAt: "1999-01-01T00:00:00Z", source: frame.source,
                                         displayIndex: frame.displayIndex, displayCount: frame.displayCount,
                                         width: frame.width, height: frame.height, nonce: frame.nonce,
                                         pngBase64: frame.pngBase64, sha256Hex: frame.sha256Hex,
                                         signature: frame.signature)
        XCTAssertFalse(replayed.signatureIsValid, "a replayed frame under a new captured_at must fail verify")
    }

    // TYPE-LEVEL refusal: signed() is failable and NEVER yields a frame with an empty HMAC seal. The
    // "unsigned frame" refusal lives in the type (nil return), not only at the CLI emit site. In the XCTest
    // bundle both keys auto-arm ephemeral, so the positive assertion is that a produced frame always has a
    // non-empty seal AND a non-empty ed25519; the nil path is exercised by construction of the guard.
    func testSignedNeverYieldsEmptySignatures() {
        let png = Self.tinyPNG(width: 4, height: 3)
        guard let frame = HostSnapshotFrame.signed(pngBytes: png, capturedAt: "2026-09-01T12:00:00Z",
                                                   source: "tinkystream", displayIndex: 0, displayCount: 1,
                                                   width: 4, height: 3) else {
            return XCTFail("with both keys armed, signed() must produce a frame")
        }
        XCTAssertFalse(frame.signature.isEmpty, "signed() must never yield an empty HMAC seal")
        XCTAssertFalse(frame.ed25519.isEmpty, "signed() must never yield an empty ed25519 signature")
        XCTAssertFalse(frame.keyID.isEmpty, "signed() must never yield an empty key_id")
    }

    func testJsonLineIsSingleCompleteObject() {
        let png = Self.tinyPNG(width: 2, height: 2)
        let frame = HostSnapshotFrame.signed(pngBytes: png, capturedAt: "2026-09-01T12:00:00Z",
                                             source: "screencapture", displayIndex: 1, displayCount: 2,
                                             width: 2, height: 2, nonce: "deadbeef")!
        let line = frame.jsonLine()
        XCTAssertFalse(line.contains("\n"), "a stream line must be exactly one line")
        let obj = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(obj["schema"] as? String, "kist-cli-json-v1")
        XCTAssertEqual(obj["target"] as? String, "macos-host")
        XCTAssertNotNil(obj["png_base64"]); XCTAssertNotNil(obj["sha256"]); XCTAssertNotNil(obj["signature"])
        XCTAssertNotNil(obj["ed25519"]); XCTAssertNotNil(obj["key_id"])
        XCTAssertEqual(obj["nonce"] as? String, "deadbeef", "the planted nonce must be echoed in the frame")
        XCTAssertNil(obj["error"], "a success object must never carry an error")
        XCTAssertNil(obj["status"], "must never emit a {status:pending} object")
    }

    // Nonce is unambiguous: "no nonce" and "empty nonce" produce the SAME canonical string, and a distinct
    // nonce value produces a DIFFERENT one — so presence/absence can never collide with a real value.
    func testNonceCanonicalStringIsUnambiguous() {
        let base = HostSnapshotFrame.canonicalString(capturedAt: "t", source: "s", displayIndex: 0,
                                                     width: 1, height: 1, sha256Hex: "aa")            // no nonce arg
        let empty = HostSnapshotFrame.canonicalString(capturedAt: "t", source: "s", displayIndex: 0,
                                                      width: 1, height: 1, sha256Hex: "aa", nonce: "") // explicit empty
        let planted = HostSnapshotFrame.canonicalString(capturedAt: "t", source: "s", displayIndex: 0,
                                                        width: 1, height: 1, sha256Hex: "aa", nonce: "n1")
        XCTAssertEqual(base, empty, "absent nonce and empty nonce must be the same canonical string")
        XCTAssertNotEqual(base, planted, "a planted nonce must change the canonical string")
        XCTAssertTrue(planted.contains("nonce=n1"), "a planted nonce must be a covered field")
        XCTAssertTrue(base.contains("|nonce=|"), "nonce= is ALWAYS present (empty here), never omitted")
    }

    func testErrorLineIsAtomicAndCarriesNoFrameFields() {
        let line = HostSnapshotFrame.errorLine("stale frame source")
        let obj = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(obj["error"] as? String, "stale frame source")
        XCTAssertNil(obj["png_base64"]); XCTAssertNil(obj["signature"]); XCTAssertNil(obj["status"])
    }

    // KEY CREATION IS EXCLUSIVE (Codex LOW #4): an EXISTING key file is NOT overwritten — the loader takes
    // over and the derived public key is stable across calls. Exercises the FILE path against a temp dir via
    // keyDirectoryOverrideForTesting (never touches the user's real ~/.mythos).
    func testExistingKeyIsNotOverwrittenAndSurvives() throws {
        HostSnapshotSigner.resetCacheForTesting()
        defer { HostSnapshotSigner.resetCacheForTesting() }
        let dir = NSTemporaryDirectory() + "kist-hs-keytest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        HostSnapshotSigner.keyDirectoryOverrideForTesting = dir

        // First use CREATES the key; capture the public half.
        let pub1 = try HostSnapshotSigner.publicKeyRaw()
        let keyFile = dir + "/host-snapshot-ed25519-v1.key"
        XCTAssertTrue(FileManager.default.fileExists(atPath: keyFile), "first use must create the key file")
        // The created key file is 0600 (owner-only, no group/other bits).
        let mode = (try FileManager.default.attributesOfItem(atPath: keyFile)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode.map { $0 & 0o777 }, 0o600, "the key file must be created 0600")

        // Clear the in-process cache so the NEXT call must re-load from disk (not the memoized pair). The
        // existing file must be LOADED (exclusive-create must NOT overwrite it), yielding the SAME public key.
        HostSnapshotSigner.resetCacheForTesting()
        HostSnapshotSigner.keyDirectoryOverrideForTesting = dir
        let pub2 = try HostSnapshotSigner.publicKeyRaw()
        XCTAssertEqual(pub1, pub2, "an existing key must be loaded, never overwritten by a fresh one")
    }

    // KEY DIRECTORY PERMS (Codex LOW #4): a group/world-writable key directory is refused (fail-closed) when
    // creating a new key — a writable dir is a plant/swap vector. Skipped if the FS can't hold 0777 (rare).
    func testInsecureKeyDirectoryFailsClosedOnCreate() throws {
        HostSnapshotSigner.resetCacheForTesting()
        defer { HostSnapshotSigner.resetCacheForTesting() }
        let dir = NSTemporaryDirectory() + "kist-hs-badperms-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o777])   // group/world writable
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Confirm the FS actually kept the loose mode; if umask/FS forced it tighter, the test is moot.
        let mode = (try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try XCTSkipUnless(mode & 0o022 != 0, "filesystem did not preserve a group/world-writable dir; can't assert the gate")
        HostSnapshotSigner.keyDirectoryOverrideForTesting = dir
        XCTAssertThrowsError(try HostSnapshotSigner.publicKeyRaw(),
                             "a group/world-writable key directory must fail closed on key creation")
    }

    // A minimal, valid PNG with a real IHDR so pngDimensions() reads back w/h (bytes need not be a full image).
    static func tinyPNG(width: Int, height: Int) -> Data {
        var b: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] // signature
        b += [0x00, 0x00, 0x00, 0x0D]                                     // IHDR length = 13
        b += [0x49, 0x48, 0x44, 0x52]                                     // "IHDR"
        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        b += be32(width) + be32(height)
        b += [0x08, 0x02, 0x00, 0x00, 0x00]                              // bit depth/colour/compression/filter/interlace
        b += [0x00, 0x00, 0x00, 0x00]                                    // (fake) CRC — dimensions parsing ignores it
        return Data(b)
    }
}
