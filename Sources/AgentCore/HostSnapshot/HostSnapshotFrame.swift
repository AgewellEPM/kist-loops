import Foundation

// PROTOTYPE — host_snapshot capability (SECURITY BOUNDARY: exposes the macOS screen to a guest VM).
// This file is PURE: response model + canonical signing string + signing. No I/O, so the crypto contract
// is unit-tested without any real display, process, or clock.

/// The `kist-cli-json-v1` host-snapshot response. One COMPLETE object per emitted line — a caller either
/// sees a fully-formed frame (png + sha256 + signature + ed25519 + key_id) or an error object, never a
/// "pending"/partial SHAPE. NDJSON READ CONTRACT (honest about the pipe): "atomic" is at the LINE level, not
/// the pipe-read level. A large base64 frame can be delivered to a reader in multiple chunks, so a single
/// read may return a PARTIAL line. The consumer MUST buffer stdout until it observes a '\n', then parse the
/// bytes up to that newline as one object; a newline-less partial line is NEVER a valid object.
///
/// TWO signatures, DIFFERENT trust models — be precise about what each proves:
///   - `signature` = HMAC-SHA256 (ForgeSeal). SYMMETRIC → HOST-SIDE integrity/provenance ONLY. A guest
///     CANNOT verify it (it would need the host's secret key). Do not advertise it as guest-verifiable.
///   - `ed25519` (+ `key_id`) = detached Ed25519 signature. ASYMMETRIC → THIS is the guest-verifiable
///     authenticity signature. The guest pins the host_snapshot Ed25519 PUBLIC key OUT-OF-BAND (via
///     `kist host-snapshot --pubkey`) and verifies each frame against it, holding NO host secret.
///
/// BOTH signatures cover the SAME canonical string, which binds `sha256` (of the RAW PNG bytes),
/// `captured_at`, and (when supplied) a client `nonce`, plus schema/target/source/display/dimensions. So a
/// swapped frame fails verify (a signature can't be lifted onto different bytes).
///
/// FRESHNESS / REPLAY — the honest bound: `captured_at` is the host's self-reported wall-clock; the
/// signature attests bytes + host-CLAIMED time (+ nonce when provided). It is NOT an independent temporal
/// assurance. A verbatim signed frame can be replayed UNLESS the guest plants a fresh random `--nonce` per
/// request and rejects any frame whose echoed `nonce` != the one it planted. Nonce is the ONLY replay
/// defense here; without it a single-operator caller trusts the host's clock.
public struct HostSnapshotFrame: Sendable, Equatable {
    public static let schema = "kist-cli-json-v1"
    public static let version = 1
    public static let target = "macos-host"

    public let capturedAt: String      // ISO8601 UTC, trailing Z (host self-reported wall-clock)
    public let source: String          // "tinkystream" | "screencapture"
    public let displayIndex: Int       // the CAPTURED display index (never the merely-requested one)
    public let displayCount: Int
    public let width: Int
    public let height: Int
    public let nonce: String           // client-planted opaque nonce echoed back ("" when none supplied)
    public let pngBase64: String       // base64 of the COMPLETE PNG
    public let sha256Hex: String       // hex SHA256 of the RAW PNG bytes (NOT the base64)
    public let signature: String       // hex HMAC-SHA256 (ForgeSeal) — HOST-SIDE integrity tag, NOT guest-verifiable
    public let ed25519: String         // hex detached Ed25519 sig — the GUEST-VERIFIABLE authenticity signature
    public let keyID: String           // short hex fingerprint of the host_snapshot Ed25519 public key

    /// Direct memberwise init (used by tamper tests to construct arbitrary frames). Prefer `signed()` on the
    /// real path — it refuses to build a frame with an empty HMAC seal (see below).
    public init(capturedAt: String, source: String, displayIndex: Int, displayCount: Int,
                width: Int, height: Int, nonce: String = "", pngBase64: String, sha256Hex: String,
                signature: String, ed25519: String = "", keyID: String = "") {
        self.capturedAt = capturedAt
        self.source = source
        self.displayIndex = displayIndex
        self.displayCount = displayCount
        self.width = width
        self.height = height
        self.nonce = nonce
        self.pngBase64 = pngBase64
        self.sha256Hex = sha256Hex
        self.signature = signature
        self.ed25519 = ed25519
        self.keyID = keyID
    }

    // MARK: - Canonical signing string

    /// The INJECTIVE canonical string BOTH signatures cover. Every value is ForgeSeal.field()-encoded
    /// (percent-encode all non-alphanumerics) so the `|` / `=` join delimiters can NEVER appear inside a
    /// value — two logically different frames can never collapse to the same canonical string. The
    /// signature does NOT cover `png_base64` directly; it covers `sha256` (a collision-resistant digest of
    /// those exact bytes), which is equivalent and far cheaper to sign/verify.
    ///
    /// UNAMBIGUOUS nonce: `nonce=` is ALWAYS present (empty value when the caller planted none). So
    /// "no nonce" and "empty nonce" are the same string and cannot be confused with a distinct nonce value
    /// — a signature made without a nonce can never be re-labeled as carrying one, and vice versa.
    public static func canonicalString(capturedAt: String, source: String, displayIndex: Int,
                                       width: Int, height: Int, sha256Hex: String, nonce: String = "") -> String {
        let parts = [
            "schema=\(ForgeSeal.field(schema))",
            "version=\(ForgeSeal.field(String(version)))",
            "target=\(ForgeSeal.field(target))",
            "captured_at=\(ForgeSeal.field(capturedAt))",
            "source=\(ForgeSeal.field(source))",
            "display_index=\(ForgeSeal.field(String(displayIndex)))",
            "width=\(ForgeSeal.field(String(width)))",
            "height=\(ForgeSeal.field(String(height)))",
            "nonce=\(ForgeSeal.field(nonce))",
            "sha256=\(ForgeSeal.field(sha256Hex))",
        ]
        return parts.joined(separator: "|")
    }

    /// This frame's canonical string.
    public var canonicalString: String {
        Self.canonicalString(capturedAt: capturedAt, source: source, displayIndex: displayIndex,
                             width: width, height: height, sha256Hex: sha256Hex, nonce: nonce)
    }

    /// Build a signed frame from the raw PNG bytes. Computes sha256 over the RAW bytes, then produces BOTH:
    ///   - the HMAC-SHA256 ForgeSeal (host-side integrity tag), and
    ///   - the detached Ed25519 authenticity signature (+ its key_id) via `HostSnapshotSigner`.
    ///
    /// TYPE-LEVEL FAIL-CLOSED: returns nil if EITHER the HMAC seal is empty (no ForgeSeal key material) OR
    /// the Ed25519 signature can't be produced. There is no path that constructs a `signed()` frame with an
    /// empty seal — the "refuse to emit an unsigned frame" invariant is enforced HERE, not only at the CLI
    /// emit site. The memberwise `init` remains available for tests that need to build tampered frames.
    public static func signed(pngBytes: Data, capturedAt: String, source: String, displayIndex: Int,
                              displayCount: Int, width: Int, height: Int, nonce: String = "") -> HostSnapshotFrame? {
        let sha = MythosCrypto.sha256(pngBytes).map { String(format: "%02x", $0) }.joined()
        let canonical = canonicalString(capturedAt: capturedAt, source: source, displayIndex: displayIndex,
                                        width: width, height: height, sha256Hex: sha, nonce: nonce)
        let hmac = ForgeSeal.sign(canonical)
        guard !hmac.isEmpty else { return nil }          // no ForgeSeal key ⇒ refuse to build the frame
        guard let ed = try? HostSnapshotSigner.sign(canonical),
              let keyID = try? HostSnapshotSigner.keyID() else { return nil }  // no Ed25519 key ⇒ refuse
        return HostSnapshotFrame(capturedAt: capturedAt, source: source, displayIndex: displayIndex,
                                 displayCount: displayCount, width: width, height: height, nonce: nonce,
                                 pngBase64: pngBytes.base64EncodedString(), sha256Hex: sha,
                                 signature: hmac, ed25519: ed, keyID: keyID)
    }

    /// Verify the HMAC-SHA256 ForgeSeal over this frame's canonical string. HOST-SIDE only (the host holds
    /// the symmetric key). A tampered covered field changes the canonical string and makes this false.
    public var signatureIsValid: Bool {
        ForgeSeal.verify(canonicalString, seal: signature)
    }

    /// The GUEST verification path: check the detached Ed25519 signature against a pinned PUBLIC key. This
    /// is the check a guest VM actually runs — it holds NO host secret, only the pinned public key. Fails
    /// closed on a malformed hex signature or any tampered covered field.
    public func ed25519IsValid(publicKeyRaw: Data) -> Bool {
        guard let sig = Self.hexToData(ed25519) else { return false }
        return MythosCrypto.ed25519Verify(signature: sig, message: Data(canonicalString.utf8),
                                          publicKeyRaw: publicKeyRaw)
    }

    /// Decode a lowercase/upper hex string to bytes; nil on odd length or a non-hex nibble (fail-closed).
    static func hexToData(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    // MARK: - Atomic JSON emission

    /// The complete success object as a single-line JSON string (stable key order, no pretty-printing so
    /// each NDJSON line is one object). Hand-built to guarantee the exact schema and key order the guest
    /// contract pins — never a dictionary whose order Foundation could reorder.
    ///
    /// This returns the object WITHOUT a trailing newline; the emit sink appends the '\n' that terminates the
    /// NDJSON record. The consumer's obligation (see the type doc) is to buffer until that newline before
    /// parsing — a large `png_base64` means a single pipe read can return only part of this string.
    public func jsonLine() -> String {
        var s = "{"
        s += "\"schema\":\(Self.jsonString(Self.schema)),"
        s += "\"version\":\(Self.version),"
        s += "\"target\":\(Self.jsonString(Self.target)),"
        s += "\"captured_at\":\(Self.jsonString(capturedAt)),"
        s += "\"source\":\(Self.jsonString(source)),"
        s += "\"display_index\":\(displayIndex),"
        s += "\"display_count\":\(displayCount),"
        s += "\"width\":\(width),"
        s += "\"height\":\(height),"
        s += "\"nonce\":\(Self.jsonString(nonce)),"
        s += "\"png_base64\":\(Self.jsonString(pngBase64)),"
        s += "\"sha256\":\(Self.jsonString(sha256Hex)),"
        s += "\"signature\":\(Self.jsonString(signature)),"
        s += "\"ed25519\":\(Self.jsonString(ed25519)),"
        s += "\"key_id\":\(Self.jsonString(keyID))"
        s += "}"
        return s
    }

    /// The atomic error object as a single-line JSON string. Same schema/version envelope as success so a
    /// parser reads one shape; carries only `error`. Never partial, never retry-implying.
    public static func errorLine(_ reason: String) -> String {
        "{\"schema\":\(jsonString(schema)),\"version\":\(version),\"error\":\(jsonString(reason))}"
    }

    /// The atomic `--pubkey` object as a single-line JSON string: the host_snapshot Ed25519 PUBLIC key
    /// (base64) + its key_id. Same schema/version envelope; NO frame, NO secret. This is what the operator
    /// captures out-of-band and pins into the guest. The escaper lives here so the CLI (a different module)
    /// never needs the internal `jsonString`.
    public static func pubkeyLine(publicKeyB64: String, keyID: String) -> String {
        var s = "{"
        s += "\"schema\":\(jsonString(schema)),"
        s += "\"version\":\(version),"
        s += "\"target\":\(jsonString(target)),"
        s += "\"kind\":\"host-snapshot-pubkey\","
        s += "\"alg\":\"ed25519\","
        s += "\"public_key\":\(jsonString(publicKeyB64)),"
        s += "\"key_id\":\(jsonString(keyID))"
        s += "}"
        return s
    }

    /// Minimal, correct JSON string escaper for the values this schema emits (base64/hex/ASCII labels +
    /// arbitrary error reasons). Escapes the JSON control set so a reason with a quote can't break the line.
    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
