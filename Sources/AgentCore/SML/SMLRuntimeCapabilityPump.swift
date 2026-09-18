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
///   the at-most-one-dispatch contract. Those surface as stuck claims for an operator to resolve.
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
    private var worker: Task<Void, Never>?
    private var stopping = false
    private let reportDrain: @Sendable (DrainReport) -> Void

    public init(store: SMLRuntimeStore, coordinator: SMLApprovalGatedCoordinator,
                reportDrain: @escaping @Sendable (DrainReport) -> Void = { _ in }) {
        self.store = store
        self.coordinator = coordinator
        self.reportDrain = reportDrain
    }

    /// Schedule work without holding the operator's HTTP request open during a tool call.
    public func requestDrain() {
        guard !stopping else { return }
        if worker != nil {
            drainRequested = true
            return
        }
        worker = Task {
            repeat {
                self.drainRequested = false
                let report = await self.drain()
                self.reportDrain(report)
            } while self.drainRequested && !self.stopping && !Task.isCancelled
            self.worker = nil
        }
    }

    /// Stop taking new work. A dispatched operation gets a bounded grace period; if it cannot
    /// finish, cancellation preserves its durable claim for inspection on the next launch.
    public func shutdown(graceMilliseconds: Int = 30_000) async -> Bool {
        stopping = true
        let grace = max(0, min(graceMilliseconds, 60_000))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(grace) * 1_000_000
        while draining, !Task.isCancelled, DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        worker?.cancel()
        // Give cancellation-aware drivers time to reap subprocesses before the host releases its
        // lease. Do not spin if the caller itself was canceled.
        let cleanupDeadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while draining, !Task.isCancelled, DispatchTime.now().uptimeNanoseconds < cleanupDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return !draining
    }

    /// Drains every dispatchable task once. Concurrent callers coalesce behind the active drain
    /// and are resumed only after it has observed a fresh snapshot. This closes the edge where a
    /// periodic drain could otherwise finish just as an approval POST requests another drain.
    @discardableResult
    public func drain() async -> DrainReport {
        guard !stopping, !Task.isCancelled else { return DrainReport() }
        if draining {
            drainRequested = true
            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
        draining = true

        var report = DrainReport()
        var visited: Set<String> = []
        while !stopping && !Task.isCancelled {
            let snapshot: SMLRuntimeSnapshot
            do {
                snapshot = try await store.load()
            } catch {
                report.hostFailure = String(describing: error)
                break
            }
            guard !stopping, !Task.isCancelled else { break }
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
