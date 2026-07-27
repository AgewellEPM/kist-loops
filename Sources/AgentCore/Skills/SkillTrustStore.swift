import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Trust tier of a skill (Sprint 2 — the security spine).
public enum SkillTrust: String, Sendable, Equatable, Codable {
    /// Shipped builtin, OR a project skill whose content hash is pinned in the trust store (or, later,
    /// carries a valid publisher signature). Honors its own `allowed-tools`.
    case trusted
    /// An unpinned project / third-party skill. Loadable, but forced to a READ-ONLY scope — its
    /// self-declared `allowed-tools` is ignored. The user pins it (after review) to grant trust.
    case untrusted
}

/// The per-project skill trust store: `.kist/skills-trust.json`, mapping a skill name → the SHA-256
/// of the exact SKILL.md bytes the user reviewed and approved. A project skill is `.trusted` only
/// when its CURRENT content hash matches the pinned hash — so editing a trusted skill drops it back
/// to `.untrusted` until re-reviewed (defeats "approve benign, then swap malicious").
///
/// This is the hash-pin tier. A publisher-signature tier (Ed25519, cloning PromotionAttestation) is
/// the natural next step for distributed/marketplace skills; the hash pin already makes local project
/// skills a real boundary.
public struct SkillTrustStore: Sendable, Equatable {
    /// Human-facing location of the (user-level) trust store, for messages.
    public static let displayPath = "~/.config/kist/skills-trust.json"

    private var pinned: [String: String]   // skill name → pinned content hash (hex)

    public init(pinned: [String: String] = [:]) { self.pinned = pinned }

    /// SHA-256 hex of arbitrary content — the canonical content-hash function for skills.
    public static func hash(_ content: String) -> String {
        MythosCrypto.sha256(Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A skill is trusted by this store iff its current content hash matches the pinned hash for its
    /// name. Constant-ish comparison (hashes are public, so plain equality is fine).
    public func isPinned(name: String, hash: String) -> Bool {
        guard let p = pinned[name], !p.isEmpty else { return false }
        return p == hash
    }

    public func pinnedHash(for name: String) -> String? { pinned[name] }

    /// Pin a skill's content hash (trust it). Returns a new store; persistence is the caller's job.
    public func pinning(name: String, hash: String) -> SkillTrustStore {
        var copy = pinned; copy[name] = hash; return SkillTrustStore(pinned: copy)
    }

    public func unpinning(name: String) -> SkillTrustStore {
        var copy = pinned; copy[name] = nil; return SkillTrustStore(pinned: copy)
    }

    public var allPinned: [String: String] { pinned }

    // MARK: Persistence (USER-LEVEL, never inside the repo)

    /// The trust store lives at `~/.config/kist/skills-trust.json` — NOT in the project. A repo-local
    /// `.kist/skills-trust.json` is the council's HIGH finding: cloning a malicious repo that ships a
    /// pre-pinned trust file would auto-trust its own skills. Storing trust in the user's home, keyed
    /// by canonical project path, means a checked-out repo can NEVER ship trust for itself.
    public static func userStorePath() -> String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
        return home + "/.config/kist/skills-trust.json"
    }

    /// Whole-file document: trust pins keyed by canonical project root, then by skill name.
    private struct Doc: Codable { var version: Int; var projects: [String: [String: String]] }

    /// The pins for one project (`root`), read from the user-level store. Missing/unreadable/insecure
    /// ⇒ empty (fail-safe: no skill trusted). The file is owner-only, symlink-rejected, size-capped.
    /// `storePath` overrides the location (tests inject a temp path; nil = the real user store).
    public static func load(root: String, storePath: String? = nil) -> SkillTrustStore {
        guard let doc = loadDoc(storePath ?? userStorePath()) else { return SkillTrustStore() }
        let key = canonical(root)
        return SkillTrustStore(pinned: doc.projects[key] ?? [:])
    }

    /// Merge THIS project's pins into the user-level store under `root` and persist owner-only (0600).
    public func save(root: String, storePath: String? = nil) throws {
        guard let path = storePath ?? Self.userStorePath() else {
            throw NSError(domain: "SkillTrustStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HOME is not set; cannot locate the user trust store"])
        }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        var doc = Self.loadDoc(path) ?? Doc(version: 1, projects: [:])
        doc.projects[Self.canonical(root)] = pinned
        let data = try JSONEncoder().encode(doc)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Read + security-vet the whole user-level doc. nil on any failure. A MISSING file is silent
    /// (the normal first-run state); a file that EXISTS but is insecure/corrupt is fail-CLOSED (returns
    /// nil → every project skill untrusted/read-only) AND warns once — otherwise a corrupted store would
    /// silently strip trust from skills the user pinned, with no explanation (DeepSeek LOW).
    private static func loadDoc(_ pathOpt: String?) -> Doc? {
        guard let path = pathOpt else { return nil }
        // Shared security vetting (symlink-reject / owner-only / size-cap) via SecureUserJSON — the SAME
        // path SkillPublisherKeyStore uses, so the checks can't drift apart.
        switch SecureUserJSON.read(path) {
        case .absent:
            return nil                                     // silent (the normal first-run state)
        case .insecure:
            warnTrustStoreOnce("the trust store at \(displayPath) is not a private regular file (symlink / wrong "
                + "owner / group- or world-accessible / oversized) — ignoring it; all project skills are untrusted")
            return nil
        case .unreadable:
            warnTrustStoreOnce("the trust store at \(displayPath) exists but is unreadable / corrupt — ignoring it; "
                + "all project skills are untrusted until you re-pin them")
            return nil
        case .ok(let data):
            guard let doc = try? JSONDecoder().decode(Doc.self, from: data) else {
                warnTrustStoreOnce("the trust store at \(displayPath) exists but is unreadable / corrupt — ignoring it; "
                    + "all project skills are untrusted until you re-pin them")
                return nil
            }
            return doc
        }
    }

    private static let trustWarnLock = NSLock()
    nonisolated(unsafe) private static var warnedTrustStore = false
    private static func warnTrustStoreOnce(_ message: String) {
        trustWarnLock.lock(); defer { trustWarnLock.unlock() }
        guard !warnedTrustStore else { return }
        warnedTrustStore = true
        FileHandle.standardError.write(Data("kist: \(message)\n".utf8))
    }

    /// Canonical (realpath) project root so the key is stable regardless of symlinks/relative paths.
    private static func canonical(_ root: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return root.withCString { realpath($0, &buf) != nil ? String(cString: buf) : root }
    }
}
