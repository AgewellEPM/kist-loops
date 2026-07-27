import Foundation

/// The PRODUCER BOUNDARY for fleet progress reports — where worker progress ENTERS while the captain
/// stays the sole writer of the board.
///
/// WHY A FILESYSTEM INBOX: the blackboard has ONE writer (the captain). But N agents run in detached
/// worktrees with no live IPC into the captain. So agents do NOT write the board — they DROP a tiny
/// `CellUpdate` JSON file into a per-fleet inbox dir the captain OWNS; the captain DRAINs the inbox and
/// FOLDs each update as the sole writer. N producers → 1 reducer → 1 atomic file: no two writers ever
/// race on blackboard.json.
///
/// There is intentionally NO enqueue/write method on this type — the only mutation it performs is REMOVAL
/// of files it has durably folded. An agent writes a drop with its OWN code (a different process). That
/// is the "separate custody" guarantee. `readPending()` parses without removing valid files; the captain
/// calls `acknowledge` only after the blackboard fold persists. The legacy `drain()` still parses +
/// removes for simple exactly-once callers. A malformed file is removed (fail-fast — don't retry garbage
/// forever, don't wedge the queue). Transport only, never trust: a CellUpdate is a self-REPORTED note,
/// not proof. Real "done" is the foreman's signoff.
///
/// Ported from TinkySDR's Captain (Stage 2). LABEL: PROTOTYPE.
public final class FleetUpdateInbox {

    /// The directory agents drop CellUpdate JSON files into — a per-fleet subtree so two fleets never
    /// cross-contaminate each other's intake. Public so a producer (a different process, or a test) can
    /// drop a file; this type itself never writes here.
    public let inboxURL: URL

    public struct PendingUpdate: Sendable, Equatable {
        public let update: CellUpdate
        public let sourcePath: String
        init(update: CellUpdate, sourcePath: String) {
            self.update = update
            self.sourcePath = sourcePath
        }
    }

    /// `baseDir` is the test seam. Production default is `~/.mythos/fleet/<fleetID>/updates`.
    public init(fleetID: UUID, baseDir: URL? = nil) {
        let base = baseDir ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".mythos/fleet", isDirectory: true)
        let inbox = base
            .appendingPathComponent(fleetID.uuidString, isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        self.inboxURL = inbox
    }

    /// Read valid inbox drops in stable filename order without removing them. Malformed files are removed
    /// immediately because they cannot become valid by retrying. Valid files must be acknowledged only
    /// after their blackboard fold persists.
    public func readPending() -> [PendingUpdate] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else {
            return []
        }
        let files = names
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var out: [PendingUpdate] = []
        let decoder = JSONDecoder()
        for url in files {
            if let data = try? Data(contentsOf: url),
               let update = try? decoder.decode(CellUpdate.self, from: data) {
                out.append(PendingUpdate(update: update, sourcePath: url.path))
            } else {
                // Malformed drops are garbage we refuse to re-process endlessly.
                try? fm.removeItem(at: url)
            }
        }
        return out
    }

    /// Acknowledge a parsed update after its blackboard fold is durably persisted. Returns false if the
    /// source path is not one of this inbox's files, or if removal fails, so the supervisor can fail closed.
    @discardableResult
    public func acknowledge(_ pending: PendingUpdate) -> Bool {
        let source = URL(fileURLWithPath: pending.sourcePath).standardizedFileURL.path
        let root = inboxURL.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard source.hasPrefix(prefix) else { return false }
        do {
            try FileManager.default.removeItem(atPath: source)
            return true
        } catch {
            return false
        }
    }

    /// Legacy exactly-once intake: parse each *.json into a CellUpdate, then REMOVE it.
    public func drain() -> [CellUpdate] {
        let pending = readPending()
        pending.forEach { _ = acknowledge($0) }
        return pending.map(\.update)
    }
}
