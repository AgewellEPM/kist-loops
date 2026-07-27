import Foundation

/// Durable storage for `AgentCheckpoint`s — one JSON file per run.
///
/// Default location: `~/Library/Application Support/FloatingChatApp/checkpoints/`.
/// The directory is injectable so tests can point at a temp dir.
///
/// Durability/atomicity lives in `JSONDirectoryStore`; this type adds the
/// checkpoint-specific querying (newest-first ordering, resumable filter).
final class CheckpointStore {
    static let shared = CheckpointStore()

    private let store: JSONDirectoryStore<AgentCheckpoint>

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let dir = directory ?? JSONDirectoryStore<AgentCheckpoint>.defaultDirectory(
            subfolder: "checkpoints",
            fileManager: fileManager
        )
        self.store = JSONDirectoryStore<AgentCheckpoint>(directory: dir, fileManager: fileManager)
    }

    func url(for id: String) -> URL { store.url(for: id) }
    var storageDirectory: URL { store.storageDirectory }

    func save(_ checkpoint: AgentCheckpoint) throws { try store.save(checkpoint) }
    func load(id: String) throws -> AgentCheckpoint { try store.load(id: id) }

    /// All checkpoints, newest first.
    func list() -> [AgentCheckpoint] {
        store.list().sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Only runs that can be resumed (running / paused / failed), newest first.
    func resumable() -> [AgentCheckpoint] {
        list().filter { $0.isResumable }
    }

    func delete(id: String) throws { try store.delete(id: id) }
}
