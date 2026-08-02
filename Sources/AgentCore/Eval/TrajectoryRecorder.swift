import Foundation

/// A thread-safe sink the agent loop writes each tool call into, so the host can analyze the run's
/// trajectory afterward (runaway loops, failure spikes — the incident causes APM can't see). The loop
/// is a Sendable struct and may execute across tasks, so this is a lock-guarded reference type.
public final class TrajectoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ActionRecord] = []

    public init() {}

    public func record(tool: String, argsFingerprint: String, success: Bool, failureDetail: String? = nil,
                       effectObservation: ToolEffectObservation? = nil) {
        lock.lock(); defer { lock.unlock() }
        steps.append(ActionRecord(tool: tool, argsFingerprint: argsFingerprint, success: success,
                                  failureDetail: failureDetail, effectObservation: effectObservation))
    }

    /// Current steps (a copy).
    public func snapshot() -> [ActionRecord] {
        lock.lock(); defer { lock.unlock() }
        return steps
    }

    /// Replace the in-memory ledger with the exact durable checkpoint ledger. Resume must restore,
    /// not append: appending to a host recorder that already observed the pre-pause actions would
    /// duplicate evidence, while starting empty would let pause/resume bypass completion verification.
    public func restore(_ records: [ActionRecord]) {
        lock.lock(); defer { lock.unlock() }
        steps = records
    }

    /// Clear between turns so each run is analyzed on its own.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        steps.removeAll(keepingCapacity: true)
    }
}
