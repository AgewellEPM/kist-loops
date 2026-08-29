import Foundation

/// Read-side of the daemon's provider health snapshot (`~/.kist/runtime/provider-health.json`).
///
/// The health daemon has been WRITING this file all along, but nothing on the request path ever
/// read it — so a provider known-down at startup (ollama unloaded, observed 2026-08-25) was still
/// selected turn after turn, and every turn died with the same transport error. This store closes
/// that loop: routing composes `down(_:)` with `ProviderCooldownStore.coolingDown(_:)` as the
/// avoid gate, so a known-down provider is skipped BEFORE the first failure, not after it.
///
/// Same doctrine as the cooldown store: file-backed, tiny, and fail-open. A missing, unreadable,
/// or malformed file means "nothing is down" — this store may only ever REDUCE eagerness to pick
/// a dead provider, never block the last resort. Only `status == "down"` counts; "degraded"
/// (missing key) is already handled by the registry's key checks, and "unknown" is not evidence.
///
/// Freshness: a "down" verdict older than `maxAge` is ignored — the daemon refreshes on an
/// interval, so a stale row must not bench a provider the user has since restarted.
public struct ProviderHealthFileStore: Sendable {
    /// The daemon's refresh interval is 300s; 30 minutes tolerates several missed cycles while
    /// still expiring verdicts from a daemon that has stopped running.
    public static let defaultMaxAge: TimeInterval = 1_800

    private let fileURL: URL
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date

    public init(directory: URL? = nil, maxAge: TimeInterval = ProviderHealthFileStore.defaultMaxAge,
                now: @Sendable @escaping () -> Date = { Date() }) {
        // The producing daemon resolves its root as $KIST_HOME (defaulting to ~/.kist) — the reader
        // must resolve the SAME override or a relocated home silently fails open and known-down
        // providers stay selectable (Codex P2, 2026-08-25).
        let kistHome = ProcessInfo.processInfo.environment["KIST_HOME"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kist", isDirectory: true)
        let dir = directory ?? kistHome.appendingPathComponent("runtime", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("provider-health.json")
        self.maxAge = maxAge
        self.now = now
    }

    /// True while the daemon's snapshot records a FRESH `status == "down"` for the provider.
    public func down(_ providerId: String) -> Bool {
        downProviders().contains(providerId.lowercased())
    }

    /// Provider ids with a fresh "down" verdict (for operator-facing notes).
    public func downProviders() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(HealthFile.self, from: data) else { return [] }
        let cutoff = now().timeIntervalSince1970 - maxAge
        return Set(file.providers.compactMap { id, row in
            guard row.status == "down", (row.checkedAt ?? 0) > cutoff else { return nil }
            guard Self.verdictAppliesToThisProcess(providerId: id) else { return nil }
            return id.lowercased()
        })
    }

    /// A daemon verdict is bound to the ENDPOINT it probed, and the snapshot records only the
    /// provider id. Both the daemon and this process honor `OLLAMA_HOST`, but they run in different
    /// environments (launchd vs shell), so when this process carries an explicit override the two
    /// endpoints cannot be assumed equal — a localhost "down" verdict must not bench a healthy
    /// remote Ollama for up to maxAge (Codex P2, 2026-08-25). Unverifiable identity ⇒ fail open;
    /// the cooldown ledger still benches the real endpoint after its first observed failure.
    static func verdictAppliesToThisProcess(
        providerId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard providerId.lowercased() == "ollama" else { return true }
        let host = environment["OLLAMA_HOST"] ?? ""
        return host.isEmpty   // default endpoint on both sides ⇒ the verdict applies
    }

    private struct HealthFile: Decodable {
        var providers: [String: Row]
        struct Row: Decodable {
            // A row without a status never benches anybody (nil != "down").
            var status: String?
            var checkedAt: Double?
        }
    }
}
