import XCTest
import Foundation
@testable import Kist
@testable import AgentCore

// PROTOTYPE — host_snapshot CLI contract. Asserts ATOMICITY on BOTH the single-frame AND the stream paths
// INDIVIDUALLY (two named assertions — a complete {png,sha256,signature} object OR an error, never a
// {status:pending}), and that the operator surface advertises the capability marker.
final class HostSnapshotContractTests: XCTestCase {

    private let token = "contract-token-abc"

    override func setUp() {
        super.setUp()
        setenv(HostSnapshotAuth.tokenEnvVar, token, 1)          // configure the host secret for the run
        ForgeSeal.forceEphemeralKeyForTesting()                // deterministic HMAC key
        HostSnapshotSigner.forceEphemeralKeyForTesting()       // deterministic Ed25519 key
    }
    override func tearDown() {
        unsetenv(HostSnapshotAuth.tokenEnvVar)
        ForgeSeal.resetCacheForTesting()
        HostSnapshotSigner.resetCacheForTesting()
        super.tearDown()
    }

    // A minimal valid PNG (real IHDR) — enough for pngDimensions() to read w/h and for the frame to sign.
    private static func tinyPNG(width: Int, height: Int) -> Data {
        var b: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        b += [0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
        func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        b += be32(width) + be32(height) + [0x08, 0x02, 0x00, 0x00, 0x00] + [0, 0, 0, 0]
        return Data(b)
    }

    // A thread-safe line sink so the in-process runner's emitted objects can be inspected.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _lines: [String] = []
        func emit(_ s: String) { lock.lock(); _lines.append(s); lock.unlock() }
        var lines: [String] { lock.lock(); defer { lock.unlock() }; return _lines }
    }

    private func fixtureSource(fresh: Bool, png: Data) -> HostSnapshotSource {
        let now = Date()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        return HostSnapshotSource(
            latestJpgPath: "/dev/null",
            now: { now },
            isInteractiveSession: { false },
            // Single-fd seam: mtime + bytes together (fresh vs stale off the mtime), TOCTOU-safe by shape.
            openLatestJPEG: { _ in HostSnapshotSource.LatestJPEG(mtime: fresh ? now : now.addingTimeInterval(-100), bytes: jpeg) },
            jpegToPNG: { _, _ in png },
            screencapturePNG: { _, _ in png })
    }

    private func opts(stream: Bool) -> KistOptions {
        var o = KistOptions(project: FileManager.default.currentDirectoryPath)
        o.hostSnapshot = true
        o.hostSnapshotStream = stream
        o.authToken = token
        o.maxFrames = 3
        o.fps = 5
        return o
    }

    private func assertAtomicObject(_ line: String, site: String) {
        let obj = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertNil(obj["status"], "\(site): must NEVER emit a {status:pending} object")
        let hasFrame = obj["png_base64"] != nil && obj["sha256"] != nil && obj["signature"] != nil
        let isError = obj["error"] != nil
        XCTAssertTrue(hasFrame != isError, "\(site): each line must be EITHER a complete frame OR an error, never both/neither")
        if hasFrame {
            XCTAssertNil(obj["error"], "\(site): a frame object must carry no error")
            XCTAssertFalse((obj["png_base64"] as! String).isEmpty, "\(site): frame must carry non-empty png")
        }
    }

    // SITE 1: single-frame path is atomic.
    func testSingleFramePathIsAtomic() async {
        let png = Self.tinyPNG(width: 10, height: 7)
        let sink = Sink()
        let code = await KistRunner.runHostSnapshot(opts(stream: false),
                                                    source: fixtureSource(fresh: true, png: png),
                                                    emit: sink.emit)
        XCTAssertEqual(code, 0, "a fresh fixture frame must succeed")
        XCTAssertEqual(sink.lines.count, 1, "single frame emits exactly one object")
        assertAtomicObject(sink.lines[0], site: "single-frame")
    }

    // SITE 2: stream path is atomic (each of the N lines independently).
    func testStreamPathIsAtomic() async {
        let png = Self.tinyPNG(width: 10, height: 7)
        let sink = Sink()
        let code = await KistRunner.runHostSnapshotStream(opts(stream: true),
                                                          source: fixtureSource(fresh: true, png: png),
                                                          emit: sink.emit,
                                                          sleep: { _ in })
        XCTAssertEqual(code, 0, "a fresh fixture stream must succeed")
        XCTAssertEqual(sink.lines.count, 3, "max-frames=3 emits exactly three objects")
        for (i, line) in sink.lines.enumerated() { assertAtomicObject(line, site: "stream-line-\(i)") }
    }

    // Fail-closed: no token supplied ⇒ atomic auth error + exit 2 on BOTH paths, zero frame fields.
    func testMissingTokenIsAtomicAuthErrorBothPaths() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        var noAuth = opts(stream: false); noAuth.authToken = nil
        unsetenv(HostSnapshotAuth.tokenEnvVar)   // remove the configured secret too ⇒ definitely rejected

        let sink1 = Sink()
        let code1 = await KistRunner.runHostSnapshot(noAuth, source: fixtureSource(fresh: true, png: png), emit: sink1.emit)
        XCTAssertEqual(code1, 2, "single-frame missing token ⇒ exit 2")
        assertAtomicObject(sink1.lines[0], site: "single-frame-auth")
        XCTAssertNotNil((try! JSONSerialization.jsonObject(with: Data(sink1.lines[0].utf8)) as! [String: Any])["error"])

        var noAuthStream = opts(stream: true); noAuthStream.authToken = nil
        let sink2 = Sink()
        let code2 = await KistRunner.runHostSnapshotStream(noAuthStream, source: fixtureSource(fresh: true, png: png),
                                                           emit: sink2.emit, sleep: { _ in })
        XCTAssertEqual(code2, 2, "stream missing token ⇒ exit 2")
        assertAtomicObject(sink2.lines[0], site: "stream-auth")
    }

    // Per-frame error in a stream ⇒ ONE atomic error line then STOP (no partial "more coming" stream).
    func testStreamStopsAtomicallyOnStaleSource() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        let sink = Sink()
        let code = await KistRunner.runHostSnapshotStream(opts(stream: true),
                                                          source: fixtureSource(fresh: false, png: png),  // stale
                                                          emit: sink.emit, sleep: { _ in })
        XCTAssertNotEqual(code, 0, "stale source ⇒ non-zero exit")
        XCTAssertEqual(sink.lines.count, 1, "must emit exactly one atomic error line then stop")
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertNotNil(obj["error"]); XCTAssertNil(obj["png_base64"])
    }

    // `--pubkey`: prints a valid Ed25519 public key + key_id, captures NO frame, needs NO token.
    func testPubkeyPrintsKeyCapturesNoFrameNeedsNoToken() async {
        unsetenv(HostSnapshotAuth.tokenEnvVar)   // NO token configured — --pubkey must still work
        var o = opts(stream: false)
        o.authToken = nil                        // NO supplied token either
        o.hostSnapshotPubkey = true
        let sink = Sink()
        // A source that would FAIL if touched — proves --pubkey never captures.
        let neverCaptures = HostSnapshotSource(
            latestJpgPath: "/dev/null", now: { Date() },
            isInteractiveSession: { false },
            openLatestJPEG: { _ in nil },   // file absent — but --pubkey never even touches this
            jpegToPNG: { _, _ in XCTFail("--pubkey must not capture"); return Data() },
            screencapturePNG: { _, _ in XCTFail("--pubkey must not capture"); return Data() })
        let code = await KistRunner.runHostSnapshot(o, source: neverCaptures, emit: sink.emit)
        XCTAssertEqual(code, 0, "--pubkey exits 0 without a token")
        XCTAssertEqual(sink.lines.count, 1)
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(obj["kind"] as? String, "host-snapshot-pubkey")
        XCTAssertEqual(obj["alg"] as? String, "ed25519")
        XCTAssertNil(obj["png_base64"], "--pubkey must carry NO frame")
        let pubB64 = obj["public_key"] as! String
        let pubRaw = Data(base64Encoded: pubB64)!
        XCTAssertTrue(MythosCrypto.ed25519ValidPublicKey(pubRaw), "printed public key must be a valid Ed25519 key")
        XCTAssertEqual(obj["key_id"] as? String, HostSnapshotSigner.keyID(forPublicKeyRaw: pubRaw), "key_id must be the printed key's fingerprint")
    }

    // NONCE + THE GUEST'S PATH: a frame echoes the planted nonce, and its ed25519 sig INDEPENDENTLY verifies
    // against the exported public key (no host secret). Proves the guest could verify + detect replay.
    func testNonceEchoAndIndependentEd25519Verify() async {
        let png = Self.tinyPNG(width: 9, height: 5)
        var o = opts(stream: false)
        o.hostSnapshotNonce = "cafebabe"
        let sink = Sink()
        let code = await KistRunner.runHostSnapshot(o, source: fixtureSource(fresh: true, png: png), emit: sink.emit)
        XCTAssertEqual(code, 0)
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(obj["nonce"] as? String, "cafebabe", "the frame must echo the planted nonce")
        // Reconstruct the frame and verify ed25519 with ONLY the exported public key (the guest's position).
        let frame = HostSnapshotFrame(
            capturedAt: obj["captured_at"] as! String, source: obj["source"] as! String,
            displayIndex: obj["display_index"] as! Int, displayCount: obj["display_count"] as! Int,
            width: obj["width"] as! Int, height: obj["height"] as! Int, nonce: obj["nonce"] as! String,
            pngBase64: obj["png_base64"] as! String, sha256Hex: obj["sha256"] as! String,
            signature: obj["signature"] as! String, ed25519: obj["ed25519"] as! String, keyID: obj["key_id"] as! String)
        let pubRaw = try! HostSnapshotSigner.publicKeyRaw()
        XCTAssertTrue(frame.ed25519IsValid(publicKeyRaw: pubRaw), "the guest must verify the frame's ed25519 with only the public key")
        // A frame carrying a DIFFERENT echoed nonce is detectable by echo-mismatch (guest's replay check).
        XCTAssertNotEqual(obj["nonce"] as? String, "not-what-I-planted")
    }

    // NEGATIVE --display (Codex MEDIUM #1): a negative index must NOT be clamped to 0 — it fails closed with
    // an atomic error + nonzero exit + ZERO png, on BOTH the single-frame AND the stream path (named each).
    func testNegativeDisplayFailsClosedSingleFrame() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        var o = opts(stream: false); o.displayIndex = -1
        let sink = Sink()
        let code = await KistRunner.runHostSnapshot(o, source: fixtureSource(fresh: true, png: png), emit: sink.emit)
        XCTAssertNotEqual(code, 0, "single-frame: negative --display must not succeed (no clamp to 0)")
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertNotNil(obj["error"], "single-frame: negative --display must be an atomic error")
        XCTAssertNil(obj["png_base64"], "single-frame: negative --display must capture zero png")
    }

    func testNegativeDisplayFailsClosedStream() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        var o = opts(stream: true); o.displayIndex = -1
        let sink = Sink()
        let code = await KistRunner.runHostSnapshotStream(o, source: fixtureSource(fresh: true, png: png),
                                                          emit: sink.emit, sleep: { _ in })
        XCTAssertNotEqual(code, 0, "stream: negative --display must not succeed (no clamp to 0)")
        XCTAssertEqual(sink.lines.count, 1, "stream: negative --display emits one atomic error then stops")
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertNotNil(obj["error"], "stream: negative --display must be an atomic error")
        XCTAssertNil(obj["png_base64"], "stream: negative --display must capture zero png")
    }

    // NON-INTEGER --display (Codex MEDIUM #2): a present-but-non-integer value (parse error) must be rejected
    // with an atomic "invalid --display index" error BEFORE auth/capture, on BOTH paths (named each).
    func testNonIntegerDisplayIsAtomicInvalidErrorSingleFrame() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        var o = opts(stream: false); o.hostSnapshotDisplayParseError = true   // as set by `--display abc`
        let sink = Sink()
        let code = await KistRunner.runHostSnapshot(o, source: fixtureSource(fresh: true, png: png), emit: sink.emit)
        XCTAssertNotEqual(code, 0, "single-frame: non-integer --display must not succeed")
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(obj["error"] as? String, "invalid --display index", "single-frame: must be the atomic invalid-display error")
        XCTAssertNil(obj["png_base64"], "single-frame: non-integer --display captures zero png")
    }

    func testNonIntegerDisplayIsAtomicInvalidErrorStream() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        var o = opts(stream: true); o.hostSnapshotDisplayParseError = true
        let sink = Sink()
        let code = await KistRunner.runHostSnapshotStream(o, source: fixtureSource(fresh: true, png: png),
                                                          emit: sink.emit, sleep: { _ in })
        XCTAssertNotEqual(code, 0, "stream: non-integer --display must not succeed")
        XCTAssertEqual(sink.lines.count, 1, "stream: non-integer --display emits one atomic error then stops")
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertEqual(obj["error"] as? String, "invalid --display index", "stream: must be the atomic invalid-display error")
    }

    // The parse-error signal is set for a NON-integer --display and NOT for a valid one (KistOptions plumbing).
    func testDisplayParseErrorSignalIsSetOnlyForNonInteger() {
        let good = KistOptions.parse(["host-snapshot", "--display", "2"])
        XCTAssertFalse(good.hostSnapshotDisplayParseError, "a valid integer --display must not set the parse-error signal")
        XCTAssertEqual(good.displayIndex, 2)
        let bad = KistOptions.parse(["host-snapshot", "--display", "abc"])
        XCTAssertTrue(bad.hostSnapshotDisplayParseError, "a non-integer --display must set the parse-error signal")
        XCTAssertNil(bad.displayIndex, "a non-integer --display must not silently set displayIndex to 0")
        let neg = KistOptions.parse(["host-snapshot", "--display", "-1"])
        XCTAssertFalse(neg.hostSnapshotDisplayParseError, "a negative integer is a valid Int (parsed, not a parse error)")
        XCTAssertEqual(neg.displayIndex, -1, "the negative index is passed through for acquire() to reject")
    }

    // DISPLAY HONESTY at the CLI: tinkystream + --display 3 ⇒ fail-closed atomic error, no mislabeled frame.
    func testCliTinkystreamNonZeroDisplayFailsClosed() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        var o = opts(stream: false)
        o.displayIndex = 3
        let sink = Sink()
        let code = await KistRunner.runHostSnapshot(o, source: fixtureSource(fresh: true, png: png), emit: sink.emit)
        XCTAssertNotEqual(code, 0, "tinkystream + --display 3 must not succeed")
        let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
        XCTAssertNotNil(obj["error"], "must be an atomic error, not a frame")
        XCTAssertNil(obj["png_base64"], "no mislabeled frame bytes")
    }

    // AUTH ORACLE at the CLI: the guest-facing error string is BYTE-IDENTICAL across ALL THREE reachable
    // failure states, on BOTH runHostSnapshot AND runHostSnapshotStream (per-path, named). The three states
    // reachable through the CLI's env-fallback credential model are:
    //   - not-configured, no credential presented  (no env, no flag)
    //   - not-configured, a credential presented    (no env, wrong flag) — host isn't armed at all
    //   - mismatch                                  (env armed, wrong flag)
    // The pure "missing supplied token vs configured secret" split is asserted at the authorize() unit level
    // (HostSnapshotAuthTests) — it can't be reached at the CLI because env IS both the expected AND the
    // fallback supplied source. What matters here: the guest can't tell ANY of them apart.
    func testGuestFacingAuthErrorIsIdenticalAcrossStatesBothPaths() async {
        let png = Self.tinyPNG(width: 4, height: 4)
        func guestError(stream: Bool, armHost: Bool, flag: String?) async -> String {
            if armHost { setenv(HostSnapshotAuth.tokenEnvVar, token, 1) } else { unsetenv(HostSnapshotAuth.tokenEnvVar) }
            var o = opts(stream: stream); o.authToken = flag
            let sink = Sink()
            if stream {
                _ = await KistRunner.runHostSnapshotStream(o, source: fixtureSource(fresh: true, png: png), emit: sink.emit, sleep: { _ in })
            } else {
                _ = await KistRunner.runHostSnapshot(o, source: fixtureSource(fresh: true, png: png), emit: sink.emit)
            }
            let obj = try! JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as! [String: Any]
            return (obj["error"] as? String) ?? "<NO ERROR — UNEXPECTED FRAME>"
        }
        for stream in [false, true] {
            let site = stream ? "stream" : "single-frame"
            let notArmedNoCred = await guestError(stream: stream, armHost: false, flag: nil)
            let notArmedWrong  = await guestError(stream: stream, armHost: false, flag: "some-flag")
            let mismatch       = await guestError(stream: stream, armHost: true,  flag: "wrong-token")
            XCTAssertEqual(notArmedNoCred, notArmedWrong, "\(site): not-armed states must be byte-identical to the guest")
            XCTAssertEqual(notArmedWrong, mismatch, "\(site): not-armed vs mismatch must be byte-identical to the guest")
            XCTAssertEqual(mismatch, HostSnapshotAuth.guestFacingRejection, "\(site): guest sees the one opaque reason")
        }
    }

    // Operator surface advertises the fixed capability.
    func testProtocolsSurfaceAdvertisesHostSnapshot() {
        let text = KistRunner.protocolStatusText(projectRoot: FileManager.default.currentDirectoryPath)
        XCTAssertTrue(text.contains("host_snapshot · kist-cli-json-v1"),
                      "`kist --protocols` must advertise the host_snapshot capability marker")
    }
}
