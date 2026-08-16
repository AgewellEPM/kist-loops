import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Cross-process memory of LIVE provider failures (rate limits, transient 5xx).
///
/// `--health` reports keys and capabilities, not live state, and the REPL's
/// in-session "benched" substitution dies with its process — so every one-shot
/// run re-picked a provider that was actively rate-limiting (observed 4× on
/// 2026-08-13: two ask-mode director turns and two vm-agent runs all died on
/// openai rateLimited while 12 ready providers sat idle).
///
/// File-backed (`~/.kist/runtime/provider-cooldowns.json`), tiny, and fail-open:
/// any read/parse error means "no cooldowns" — this store may only ever REDUCE
/// eagerness to pick a failing provider, never block the last resort.
public struct ProviderCooldownStore: Sendable {
    /// Rate limits usually clear within minutes; long enough to skip the wall,
    /// short enough that a recovered provider comes back on its own.
    public static let defaultTTL: TimeInterval = 300

    private let fileURL: URL
    private let now: @Sendable () -> Date

    /// Stable sidecar lock guarding the load->modify->save transaction across processes.
    private var lockURL: URL { fileURL.appendingPathExtension("lock") }

    public init(directory: URL? = nil, now: @Sendable @escaping () -> Date = { Date() }) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kist/runtime", isDirectory: true)
        self.fileURL = dir.appendingPathComponent("provider-cooldowns.json")
        self.now = now
    }

    /// Mark a provider as live-failing until now + ttl.
    ///
    /// The read-modify-write is serialized across processes by a stable sidecar
    /// advisory lock (`provider-cooldowns.json.lock`). Without it, two concurrent
    /// kist processes each `load()` the same table, add their own provider, and
    /// atomically replace the file — last-writer-wins silently drops the other
    /// provider's cooldown, routing traffic straight back to a failing provider.
    /// The lock closes that window: the whole load->modify->save runs while the
    /// lock is held, so a second writer waits and observes the first writer's row.
    public func record(_ providerId: String, ttl: TimeInterval = ProviderCooldownStore.defaultTTL) {
        withLock {
            var table = load()
            table[providerId.lowercased()] = now().timeIntervalSince1970 + ttl
            save(table)
        }
    }

    /// Run `body` while holding an exclusive advisory lock on the sidecar file so
    /// the enclosed load->modify->save is atomic across processes.
    ///
    /// Fail-safe: if the lock can't be opened (fd < 0), we still run `body` rather
    /// than crash or block — this store may only ever REDUCE eagerness to pick a
    /// failing provider, never wedge the one path that records the failure.
    private func withLock<T>(_ body: () -> T) -> T {
        #if canImport(Darwin) || canImport(Glibc)
        // Ensure the directory exists so open() can create the lock file.
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return body() }   // fail-open, never crash
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)                     // blocks until the other writer releases
        return body()
        #else
        return body()
        #endif
    }

    /// True while the provider's cooldown window is open.
    public func coolingDown(_ providerId: String) -> Bool {
        guard let until = load()[providerId.lowercased()] else { return false }
        return until > now().timeIntervalSince1970
    }

    /// Provider ids currently cooling down (for operator-facing notes).
    public func activeCooldowns() -> [String] {
        let t = now().timeIntervalSince1970
        return load().filter { $0.value > t }.map(\.key).sorted()
    }

    private func load() -> [String: Double] {
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return table
    }

    private func save(_ table: [String: Double]) {
        let t = now().timeIntervalSince1970
        let live = table.filter { $0.value > t }   // expired entries never accumulate
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(live) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
