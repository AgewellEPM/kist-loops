import Foundation

/// A KeyStore that answers from an in-memory overlay first, then a base store.
/// Used during onboarding so live probes can authenticate with a JUST-ENTERED key
/// (not yet persisted) while still resolving keys for existing providers (e.g. the
/// advisory judge model) from the real Keychain/file store. Also handy in tests.
public struct OverlayKeyStore: KeyStore {
    private let overlay: [String: String]
    private let base: any KeyStore

    public init(overlay: [String: String], base: any KeyStore) {
        self.overlay = overlay
        self.base = base
    }

    public func key(forAccount account: String) -> String? {
        if let v = overlay[account], !v.isEmpty { return v }
        return base.key(forAccount: account)
    }
}
