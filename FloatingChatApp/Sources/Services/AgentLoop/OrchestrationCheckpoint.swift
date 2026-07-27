import Foundation

/// A serializable snapshot of a multi-agent ORCHESTRATION run (AgentLoopEngine),
/// so a team run can be resumed after a crash/quit.
///
/// Unlike the single-agent `AgentCheckpoint` (per-action cursor), orchestration
/// resume is PHASE-granular: it records which phase the team had reached
/// (sequential agent index, completed debate rounds, etc.) and re-enters there.
/// The heavy payloads (`agents`, `conversationHistory`) are already Codable.
struct OrchestrationCheckpoint: Codable, Identifiable {
    enum Mode: String, Codable {
        case single        // single lead agent (processMessage)
        case sequential
        case parallel
        case collaborative
        case debate
    }

    enum Status: String, Codable {
        case running, paused, completed, failed, cancelled
    }

    /// Where the orchestration had progressed to. Coarser than the single-agent
    /// cursor by design — orchestration modes have phase boundaries, not
    /// per-action ones.
    enum Phase: String, Codable {
        case started            // nothing run yet
        case sequential         // mid sequential pass (see sequentialIndex)
        case parallelDone       // parallel fan-out finished; synthesis pending
        case debateRounds       // mid debate (see debateRound)
        case synthesis          // final synthesis pending
        case done
    }

    let id: String
    var title: String
    let projectPath: String
    let userMessage: String
    var mode: Mode
    var status: Status

    var agents: [AgentConfig]
    var conversationHistory: [AgentMessage]

    // Phase cursor.
    var phase: Phase
    var sequentialIndex: Int?    // next agent index to run (sequential)
    var debateRound: Int?        // completed debate rounds
    var consensusReached: Bool?
    /// Tool that was about to run / running when we stopped. Bracketing the
    /// side effect (set before, cleared after) gives sub-phase crash-safety
    /// matching the single-agent loop.
    var pendingTool: String?

    let createdAt: Date
    var updatedAt: Date

    init(
        mode: Mode,
        userMessage: String,
        projectPath: String,
        agents: [AgentConfig],
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.title = String(userMessage.prefix(60))
        self.projectPath = projectPath
        self.userMessage = userMessage
        self.mode = mode
        self.status = .running
        self.agents = agents
        self.conversationHistory = []
        self.phase = .started
        self.sequentialIndex = nil
        self.debateRound = nil
        self.consensusReached = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var isResumable: Bool {
        (status == .running || status == .paused || status == .failed) && phase != .done
    }
}

/// Durable storage for orchestration runs. Thin wrapper over the shared generic
/// store (same atomicity / corrupt-skip guarantees as `CheckpointStore`).
final class OrchestrationCheckpointStore {
    static let shared = OrchestrationCheckpointStore()

    private let store: JSONDirectoryStore<OrchestrationCheckpoint>

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let dir = directory ?? JSONDirectoryStore<OrchestrationCheckpoint>.defaultDirectory(
            subfolder: "orchestrations",
            fileManager: fileManager
        )
        self.store = JSONDirectoryStore<OrchestrationCheckpoint>(directory: dir, fileManager: fileManager)
    }

    func save(_ checkpoint: OrchestrationCheckpoint) throws { try store.save(checkpoint) }
    func load(id: String) throws -> OrchestrationCheckpoint { try store.load(id: id) }
    func list() -> [OrchestrationCheckpoint] { store.list().sorted { $0.updatedAt > $1.updatedAt } }
    func resumable() -> [OrchestrationCheckpoint] { list().filter { $0.isResumable } }
    func delete(id: String) throws { try store.delete(id: id) }
}
