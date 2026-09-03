import Foundation

/// Single-flight capability dispatcher for a long-lived SML host.
///
/// After every mutating command (and on a slow periodic tick), the host asks the pump to drain:
/// it scans the snapshot for tasks parked at `waitingCapability` WITHOUT an existing claim and
/// executes them one at a time through the approval-gated coordinator. Sequential on purpose —
/// one dispatch in flight keeps graceful shutdown a bounded drain and makes receipts totally
/// ordered per host.
///
/// Two things the pump deliberately never does:
/// - Auto-retry a task that already carries a `capabilityClaim`: a claimed-but-incomplete dispatch
///   means a prior driver run may have had real side effects; re-executing would break
///   exactly-once. Those surface as stuck claims in the pending view for a HUMAN to resolve.
/// - Treat a failed dispatch as fatal: the failure is recorded per task and the pump moves on.
///   `SMLApprovalGatedCoordinator.ApprovalGateError` results are EXPECTED (the task's gate has
///   not been approved yet) and simply leave the task parked.
public actor SMLRuntimeCapabilityPump {
    public struct DrainReport: Sendable, Equatable {
        public var dispatched: [String] = []
        public var skippedUnapproved: [String] = []
        public var failed: [String: String] = [:]
        public var hostFailure: String?

        public init() {}
    }

    private let store: SMLRuntimeStore
    private let coordinator: SMLApprovalGatedCoordinator
    private var draining = false
    private var drainRequested = false
    private var waiters: [CheckedContinuation<DrainReport, Never>] = []

    public init(store: SMLRuntimeStore, coordinator: SMLApprovalGatedCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    /// Drains every dispatchable task once. Concurrent callers coalesce behind the active drain
    /// and are resumed only after it has observed a fresh snapshot. This closes the edge where a
    /// periodic drain could otherwise finish just as an approval POST requests another drain.
    @discardableResult
    public func drain() async -> DrainReport {
        if draining {
            drainRequested = true
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        draining = true

        var report = DrainReport()
        var visited: Set<String> = []
        while true {
            let snapshot: SMLRuntimeSnapshot
            do {
                snapshot = try await store.load()
            } catch {
                report.hostFailure = String(describing: error)
                break
            }
            let candidates = snapshot.tasks.values
                .filter { $0.status == .waitingCapability && $0.capabilityClaim == nil }
                .map(\.taskID)
                .sorted()
                .filter { !visited.contains($0) }
            guard let next = candidates.first else {
                if drainRequested {
                    drainRequested = false
                    visited.removeAll(keepingCapacity: true)
                    continue
                }
                break
            }
            visited.insert(next)
            do {
                _ = try await coordinator.executeNext(taskID: next)
                report.dispatched.append(next)
            } catch let error as SMLApprovalGatedCoordinator.ApprovalGateError {
                // Not approved / not gated: expected park, human action required. Never fatal.
                report.skippedUnapproved.append(next)
                _ = error
            } catch {
                report.failed[next] = String(describing: error)
            }
        }
        draining = false
        drainRequested = false
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in pendingWaiters { waiter.resume(returning: report) }
        return report
    }
}
