import Foundation
import Crypto   // apple/swift-crypto — cross-platform CryptoKit API (BoringSSL-backed on Linux)

/// The crypto primitives the fleet TRUST layer builds on, wrapped so the rest of AgentCore deals only
/// in `Data` (no swift-crypto types leak into the trust types). Stage 1's ForgeSeal + signoff ledger
/// use HMAC-SHA256 (the seal) + SHA256 (the chain hash); Stage 3's deploy gate uses Ed25519.
///
/// swift-crypto guarantees identical results to Apple CryptoKit via a shared test suite — so this is
/// the same crypto on macOS and Linux. This file's existence also verifies the dependency resolves,
/// links, and exposes exactly the operations the trust layer requires.
public enum MythosCrypto {

    // MARK: - HMAC-SHA256 (the forge seal)

    /// HMAC-SHA256 tag for (key, message). Deterministic — same inputs → same tag.
    public static func hmacSHA256(key: Data, message: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Constant-time verification of an HMAC-SHA256 tag.
    public static func hmacSHA256Valid(key: Data, message: Data, tag: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: message, using: SymmetricKey(data: key))
    }

    // MARK: - SHA256 (the chain hash)

    /// SHA256 digest (32 bytes).
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Streaming SHA256 digest for files. Keeps large model artifacts out of memory.
    public static func sha256File(path: String, chunkSize: Int = 1_048_576) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: chunkSize)
            guard !data.isEmpty else { return false }
            hasher.update(data: data)
            return true
        }) {}
        return Data(hasher.finalize())
    }

    // MARK: - Random symmetric key (the per-install forge-seal key)

    /// Fresh cryptographically-random key bytes (default 256-bit) — the per-install HMAC seal key.
    public static func randomKey(byteCount: Int = 32) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: byteCount * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: - Ed25519 (the deploy gate)

    /// A freshly generated Ed25519 key pair as raw bytes (so callers never touch swift-crypto types).
    public struct Ed25519KeyPair: Sendable, Equatable {
        public let privateRaw: Data
        public let publicRaw: Data
    }

    public static func ed25519GenerateKeyPair() -> Ed25519KeyPair {
        let priv = Curve25519.Signing.PrivateKey()
        return Ed25519KeyPair(privateRaw: priv.rawRepresentation, publicRaw: priv.publicKey.rawRepresentation)
    }

    /// Sign `message` with a raw Ed25519 private key. Throws if the key bytes are malformed.
    public static func ed25519Sign(message: Data, privateKeyRaw: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        return try key.signature(for: message)
    }

    /// Verify an Ed25519 signature against a raw public key. False on any malformed input (fail-closed).
    public static func ed25519Verify(signature: Data, message: Data, publicKeyRaw: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    /// True iff `publicKeyRaw` is a well-formed Ed25519 public key (constructs without throwing). Used to
    /// validate a pinned trust key at setup so a malformed pin is dropped, not trusted at verify time.
    public static func ed25519ValidPublicKey(_ publicKeyRaw: Data) -> Bool {
        (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw)) != nil
    }
}
