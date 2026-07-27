import Foundation

/// Single-writer persistence of fleet batons. Every baton transition is persisted IMMEDIATELY (atomic,
/// not debounced) so a dropped write is observable, never silent — a baton is the load-bearing handoff
/// record, and a crash between judge and persist must leave the agent treated as not-done on resume
/// (the state-machine fail-safe). One file (`batons.json`) under `baseDir`.
///
/// Ported from TinkySDR's Captain (Stage 2). De-coupled from SwiftUI: was `@MainActor ObservableObject`;
/// now a plain class serialized by an `NSLock` (the captain is the sole writer). `@unchecked Sendable`
/// justified BY the lock. LABEL: PROTOTYPE.
public final class FleetBatonStore: @unchecked Sendable {

    private let lock = NSLock()
    private var _batons: [Baton] = []
    private var _lastSaveError: String?
    private let fileURL: URL

    /// `baseDir` is the test seam. Production default is `~/.mythos/fleet` (cross-platform).
    public init(baseDir: URL? = nil) {
        let base = baseDir ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".mythos/fleet", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("batons.json")
        // Additive-tolerant per Baton's init(from:); a row this build can't decode (e.g. an unknown
        // BatonState) fails the WHOLE decode → batons empty rather than partially-trusted (fail-safe).
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Baton].self, from: data) {
            _batons = decoded
        }
    }

    /// All batons (a value-type snapshot).
    public func all() -> [Baton] { lock.lock(); defer { lock.unlock() }; return _batons }

    /// Last persistence failure, or nil if the last save succeeded.
    public func lastSaveError() -> String? { lock.lock(); defer { lock.unlock() }; return _lastSaveError }

    /// Insert-or-update a baton by id and persist immediately (atomic). Safe to call repeatedly as a baton
    /// advances through its state machine. Returns false without publishing the in-memory mutation when the
    /// durable write fails.
    @discardableResult
    public func save(_ baton: Baton) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var next = _batons
        if let idx = next.firstIndex(where: { $0.id == baton.id }) {
            next[idx] = baton
        } else {
            next.append(baton)
        }
        guard persistLocked(next) else { return false }
        _batons = next
        return true
    }

    /// The baton with a given id.
    public func baton(id: UUID) -> Baton? {
        lock.lock(); defer { lock.unlock() }
        return _batons.first { $0.id == id }
    }

    /// Every baton belonging to a fleet (parallel fan-out mints several).
    public func batons(forFleet fleetID: UUID) -> [Baton] {
        lock.lock(); defer { lock.unlock() }
        return _batons.filter { $0.fleetID == fleetID }
    }

    /// The most-recent live (non-terminal) baton for a fleet — the resume candidate. A baton mid-flight is
    /// picked back up; a `.passed`/`.failed` one is done.
    public func latestUnfinished(forFleet fleetID: UUID) -> Baton? {
        lock.lock(); defer { lock.unlock() }
        return _batons.filter { $0.fleetID == fleetID }.first { !$0.state.isTerminal }
    }

    // MARK: - Persistence (lock held by caller)

    private func persistLocked(_ batons: [Baton]) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try enc.encode(batons)
            try data.write(to: fileURL, options: [.atomic])
            _lastSaveError = nil
            return true
        } catch {
            _lastSaveError = "Couldn't persist fleet batons: \(error.localizedDescription)"
            return false
        }
    }
}
