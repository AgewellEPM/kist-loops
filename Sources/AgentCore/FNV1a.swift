import Foundation

/// FNV-1a 64-bit — the one canonical deterministic string hash for kist.
///
/// Swift's built-in `Hasher` is per-process seeded, so it is UNSAFE for anything persisted or compared
/// across runs (config fingerprints, replayable seeds, corpus keys). Three call sites had each inlined the
/// same FNV-1a constants (`OrgFingerprint`, `EvolutionParentSelector`, `SuiteMutator`) — a value that must
/// stay stable FOREVER, copy-pasted three times. This is the single source. The two forms match the two
/// existing behaviors exactly (pinned byte-for-byte by FNV1aTests against a reference loop):
///   • `hash64` — FNV-1a over the raw UTF-8 bytes (OrgFingerprint / SuiteMutator).
///   • `seed`   — FNV-1a over LENGTH-PREFIXED tokens so a separator inside a token can't alias a boundary
///                (EvolutionParentSelector's replayable seed).
public enum FNV1a {
    public static let offsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    public static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// FNV-1a over the raw UTF-8 bytes of `s`. `hash64("")` == `offsetBasis` by definition.
    public static func hash64(_ s: String) -> UInt64 {
        var h = offsetBasis
        for b in s.utf8 { h = (h ^ UInt64(b)) &* prime }
        return h
    }

    /// FNV-1a over length-prefixed tokens (8 little-endian length bytes, then the token's bytes) so token
    /// boundaries stay unambiguous even when a token contains a separator-like character.
    public static func seed(_ tokens: String...) -> UInt64 { seed(tokens) }
    public static func seed(_ tokens: [String]) -> UInt64 {
        var h = offsetBasis
        for token in tokens {
            let length = UInt64(token.utf8.count)
            for shift in stride(from: 0, to: 64, by: 8) {
                h = (h ^ UInt64(UInt8(truncatingIfNeeded: length >> UInt64(shift)))) &* prime
            }
            for byte in token.utf8 { h = (h ^ UInt64(byte)) &* prime }
        }
        return h
    }
}
