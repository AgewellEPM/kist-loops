import Foundation

/// Spawn tools expose their registry so ToolRegistry can install the matching lifecycle controls
/// atomically. A control tool can therefore never be wired to a different handle namespace.
public protocol AsyncDelegationRegistryProviding: Sendable {
    var delegationRegistry: AsyncDelegationRegistry { get }
}

public struct DelegationCapabilityCeiling: Codable, Sendable, Equatable {
    public let allowedToolNames: Set<String>
    public let allowedMCPServers: Set<String>
    public let allowedProjectPaths: [String]
    public let maxIterations: Int
    public let maxTokens: Int?
    public let maxDelegationDepth: Int
    public let requiresMutationApproval: Bool

    public init(allowedToolNames: Set<String>, allowedMCPServers: Set<String> = [],
                allowedProjectPaths: [String], maxIterations: Int, maxTokens: Int? = nil,
                maxDelegationDepth: Int = 0, requiresMutationApproval: Bool = true) {
        self.allowedToolNames = allowedToolNames
        self.allowedMCPServers = allowedMCPServers
        self.allowedProjectPaths = allowedProjectPaths
        self.maxIterations = max(1, maxIterations)
        self.maxTokens = maxTokens.map { max(1, $0) }
        self.maxDelegationDepth = max(0, maxDelegationDepth)
        self.requiresMutationApproval = requiresMutationApproval
    }

    public func permits(_ child: DelegationCapabilityCeiling) -> Bool {
        func subset(_ child: Set<String>, of parent: Set<String>) -> Bool {
            parent.contains("*") || child.isSubset(of: parent)
        }
        func pathAllowed(_ child: String) -> Bool {
            allowedProjectPaths.contains("*") || allowedProjectPaths.contains { parent in
                child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
            }
        }
        let tokenBounded: Bool = {
            guard let parent = maxTokens else { return true }
            guard let child = child.maxTokens else { return false }
            return child <= parent
        }()
        return subset(child.allowedToolNames, of: allowedToolNames)
            && subset(child.allowedMCPServers, of: allowedMCPServers)
            && child.allowedProjectPaths.allSatisfy(pathAllowed)
            && child.maxIterations <= maxIterations
            && tokenBounded
            && child.maxDelegationDepth <= maxDelegationDepth
            && (!requiresMutationApproval || child.requiresMutationApproval)
    }
}

public struct DelegationRequest: Codable, Sendable, Equatable {
    public let nodeID: String?
    public let role: String
    public let task: String
    public let depth: Int
    public let capabilityCeiling: DelegationCapabilityCeiling

    public init(nodeID: String? = nil, role: String, task: String, depth: Int = 0,
                capabilityCeiling: DelegationCapabilityCeiling) {
        self.nodeID = nodeID
        self.role = String(role.prefix(120))
        self.task = String(task.prefix(16_000))
        self.depth = max(0, depth)
        self.capabilityCeiling = capabilityCeiling
    }
}

public struct DelegationHandle: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let nodeID: String?
    public let role: String
    public let createdAt: Double
}

public struct DelegationResult: Codable, Sendable, Equatable {
    public let handleID: String
    public let summary: String
    public let artifacts: [ReasoningArtifactReference]
    public let checks: [ReasoningCheckReceipt]
    public let evidence: [ReasoningEvidenceReference]
    public let risks: [ReasoningRiskReceipt]
    public let progress: [ReasoningProgressReceipt]
    public let childCheckpointID: String?
    public let tokensSpent: Int

    public init(handleID: String, summary: String,
                artifacts: [ReasoningArtifactReference] = [],
                checks: [ReasoningCheckReceipt] = [],
                evidence: [ReasoningEvidenceReference] = [],
                risks: [ReasoningRiskReceipt] = [],
                progress: [ReasoningProgressReceipt] = [],
                childCheckpointID: String? = nil, tokensSpent: Int = 0) {
        self.handleID = handleID
        self.summary = String(summary.prefix(8_000))
        self.artifacts = artifacts
        self.checks = checks
        self.evidence = evidence
        self.risks = risks
        self.progress = progress
        self.childCheckpointID = childCheckpointID
        self.tokensSpent = max(0, tokensSpent)
    }
}

public enum DelegationStatus: Codable, Sendable, Equatable {
    case running
    case cancelling
    case completed
    case cancelled
    case failed(String)
}

public struct DelegationSnapshot: Codable, Sendable, Equatable {
    public let handle: DelegationHandle
    public let status: DelegationStatus
}

public enum DelegationRegistryError: Error, Sendable, Equatable {
    case unknownHandle(String)
    case capabilityEscalation(String)
    case depthExceeded(Int)
    case cancelled(String)
    case failed(String)
}

public actor DelegationSteeringMailbox {
    private var messages: [String] = []
    public init() {}

    public func enqueue(_ message: String) {
        let bounded = String(message.prefix(4_000))
        guard !bounded.isEmpty else { return }
        messages.append(bounded)
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
    }

    public func next() -> String? {
        guard !messages.isEmpty else { return nil }
        return messages.removeFirst()
    }

    public func drain() -> [String] {
        defer { messages.removeAll(keepingCapacity: true) }
        return messages
    }
}

public struct DelegationExecutionContext: Sendable {
    public let handle: DelegationHandle
    public let capabilityCeiling: DelegationCapabilityCeiling
    public let steering: DelegationSteeringMailbox
}

public typealias DelegationOperation = @Sendable (DelegationExecutionContext) async throws -> DelegationResult

/// In-memory task ownership plus durable structured result projection. Tasks can be spawned,
/// joined, cancelled, and steered without weakening the parent's capability ceiling.
public actor AsyncDelegationRegistry {
    /// Backward-compatible live registry for callers that have not yet injected a run-scoped one.
    /// Hosts should prefer a dedicated instance per top-level run.
    public static let shared = AsyncDelegationRegistry()
    private enum TaskOutcome: Sendable {
        case completed(DelegationResult)
        case cancelled
        case failed(String)
    }

    private struct Entry {
        let handle: DelegationHandle
        let request: DelegationRequest
        let mailbox: DelegationSteeringMailbox
        var status: DelegationStatus
        var task: Task<TaskOutcome, Never>?
    }

    private var entries: [String: Entry] = [:]
    private let controlStore: (any ReasoningControlStateStoring)?
    private let runID: String?
    private let clock: @Sendable () -> Double

    public init(controlStore: (any ReasoningControlStateStoring)? = nil,
                runID: String? = nil,
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.controlStore = controlStore
        self.runID = runID
        self.clock = clock
    }

    public nonisolated func controlTools() -> [AgentTool] {
        [JoinDelegationTool(registry: self), CancelDelegationTool(registry: self),
         SteerDelegationTool(registry: self)]
    }

    @discardableResult
    public func spawn(_ request: DelegationRequest,
                      parentCeiling: DelegationCapabilityCeiling? = nil,
                      operation: @escaping DelegationOperation) throws -> DelegationHandle {
        guard request.depth <= request.capabilityCeiling.maxDelegationDepth else {
            throw DelegationRegistryError.depthExceeded(request.depth)
        }
        if let parentCeiling, !parentCeiling.permits(request.capabilityCeiling) {
            throw DelegationRegistryError.capabilityEscalation("child capability ceiling exceeds parent")
        }
        let handle = DelegationHandle(id: UUID().uuidString, nodeID: request.nodeID,
                                      role: request.role, createdAt: clock())
        let mailbox = DelegationSteeringMailbox()
        entries[handle.id] = Entry(handle: handle, request: request, mailbox: mailbox,
                                   status: .running, task: nil)
        let task = Task { [weak self] () -> TaskOutcome in
            do {
                let context = DelegationExecutionContext(handle: handle,
                                                         capabilityCeiling: request.capabilityCeiling,
                                                         steering: mailbox)
                let result = try await operation(context)
                guard !Task.isCancelled else {
                    await self?.finish(handleID: handle.id, outcome: .cancelled)
                    return .cancelled
                }
                guard result.handleID == handle.id else {
                    let message = "delegation result handle does not match the spawned handle"
                    await self?.finish(handleID: handle.id, outcome: .failed(message))
                    return .failed(message)
                }
                await self?.finish(handleID: handle.id, outcome: .completed(result))
                return .completed(result)
            } catch is CancellationError {
                await self?.finish(handleID: handle.id, outcome: .cancelled)
                return .cancelled
            } catch {
                let message = String(String(describing: error).prefix(2_000))
                await self?.finish(handleID: handle.id, outcome: .failed(message))
                return .failed(message)
            }
        }
        entries[handle.id]?.task = task
        return handle
    }

    public func join(_ handle: DelegationHandle) async throws -> DelegationResult {
        try await join(handleID: handle.id)
    }

    public func join(handleID: String) async throws -> DelegationResult {
        guard let task = entries[handleID]?.task else {
            throw DelegationRegistryError.unknownHandle(handleID)
        }
        switch await task.value {
        case .completed(let result):
            if let status = entries[handleID]?.status, case .failed(let message) = status {
                throw DelegationRegistryError.failed(message)
            }
            return result
        case .cancelled: throw DelegationRegistryError.cancelled(handleID)
        case .failed(let message): throw DelegationRegistryError.failed(message)
        }
    }

    public func cancel(_ handle: DelegationHandle) throws {
        try cancel(handleID: handle.id)
    }

    public func cancel(handleID: String) throws {
        guard var entry = entries[handleID] else {
            throw DelegationRegistryError.unknownHandle(handleID)
        }
        entry.status = .cancelling
        entry.task?.cancel()
        entries[handleID] = entry
    }

    public func steer(_ handle: DelegationHandle, message: String) async throws {
        try await steer(handleID: handle.id, message: message)
    }

    public func steer(handleID: String, message: String) async throws {
        guard let entry = entries[handleID] else {
            throw DelegationRegistryError.unknownHandle(handleID)
        }
        guard entry.status == .running else {
            throw DelegationRegistryError.failed("delegation is not running")
        }
        await entry.mailbox.enqueue(message)
    }

    public func snapshot(_ handle: DelegationHandle) throws -> DelegationSnapshot {
        try snapshot(handleID: handle.id)
    }

    public func snapshot(handleID: String) throws -> DelegationSnapshot {
        guard let entry = entries[handleID] else {
            throw DelegationRegistryError.unknownHandle(handleID)
        }
        return DelegationSnapshot(handle: entry.handle, status: entry.status)
    }

    public func snapshots() -> [DelegationSnapshot] {
        entries.values.map { DelegationSnapshot(handle: $0.handle, status: $0.status) }
            .sorted { $0.handle.createdAt < $1.handle.createdAt }
    }

    private func finish(handleID: String, outcome: TaskOutcome) async {
        guard var entry = entries[handleID] else { return }
        switch outcome {
        case .completed: entry.status = .completed
        case .cancelled: entry.status = .cancelled
        case .failed(let message): entry.status = .failed(message)
        }
        entries[handleID] = entry

        guard case .completed(let result) = outcome,
              let controlStore, let runID else { return }
        let checkpointNodeID = entry.request.nodeID ?? handleID
        do {
            _ = try await controlStore.update(runID: runID, create: nil) { state in
                try state.recordTokenSpend(result.tokensSpent)
                state.addEvidence(result.evidence)
                for receipt in result.progress {
                    _ = MonotonicProgressReducer.apply(receipt, to: &state.progress)
                }
                if let checkpointID = result.childCheckpointID {
                    state.childCheckpointIDs[checkpointNodeID] = checkpointID
                }
            }
        } catch {
            guard var failedEntry = entries[handleID] else { return }
            failedEntry.status = .failed("delegation result persistence failed: \(error)")
            entries[handleID] = failedEntry
        }
    }
}

public enum DelegationProjection {
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(data: try encoder.encode(value), encoding: .utf8) ?? "{}"
    }
}

/// Read-only mailbox injected only into a background child. Steering is cooperative but live: the
/// parent queues messages with steer_agent and the child polls this tool at phase boundaries.
public struct DelegationInboxTool: AgentTool {
    public let name = "delegation_updates"
    public let description = "Read and consume steering messages sent by the parent of this background delegation."
    public let parameters: [ToolParameter] = []
    private let mailbox: DelegationSteeringMailbox

    public init(mailbox: DelegationSteeringMailbox) { self.mailbox = mailbox }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let messages = await mailbox.drain()
        let data = try JSONSerialization.data(withJSONObject: ["messages": messages], options: [.sortedKeys])
        return ToolResult(success: true, output: String(data: data, encoding: .utf8) ?? "{\"messages\":[]}")
    }
}

public struct JoinDelegationTool: AgentTool {
    public let name = "join_agent"
    public let description = "Wait for a background delegation and return its typed result projection."
    public let parameters = [ToolParameter(name: "handle", type: "string", description: "Handle returned by a background spawn.")]
    private let registry: AsyncDelegationRegistry
    public init(registry: AsyncDelegationRegistry) { self.registry = registry }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let id = try requireString("handle", from: arguments)
        let result = try await registry.join(handleID: id)
        return ToolResult(success: true, output: try DelegationProjection.encode(result),
                          metadata: ["delegation_handle": id, "delegation_status": "completed"])
    }
}

public struct CancelDelegationTool: AgentTool {
    public let name = "cancel_agent"
    public let description = "Cancel a background delegation owned by this run."
    public let parameters = [ToolParameter(name: "handle", type: "string", description: "Handle returned by a background spawn.")]
    private let registry: AsyncDelegationRegistry
    public init(registry: AsyncDelegationRegistry) { self.registry = registry }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let id = try requireString("handle", from: arguments)
        try await registry.cancel(handleID: id)
        let snapshot = try await registry.snapshot(handleID: id)
        return ToolResult(success: true, output: try DelegationProjection.encode(snapshot),
                          metadata: ["delegation_handle": id, "delegation_status": "cancelling"])
    }
}

public struct SteerDelegationTool: AgentTool {
    public let name = "steer_agent"
    public let description = "Send bounded steering to a running background delegation."
    public let parameters = [
        ToolParameter(name: "handle", type: "string", description: "Handle returned by a background spawn."),
        ToolParameter(name: "message", type: "string", description: "Updated constraint or direction for the child."),
    ]
    private let registry: AsyncDelegationRegistry
    public init(registry: AsyncDelegationRegistry) { self.registry = registry }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let id = try requireString("handle", from: arguments)
        let message = try requireString("message", from: arguments)
        try await registry.steer(handleID: id, message: message)
        let snapshot = try await registry.snapshot(handleID: id)
        return ToolResult(success: true, output: try DelegationProjection.encode(snapshot),
                          metadata: ["delegation_handle": id, "delegation_status": "running"])
    }
}
