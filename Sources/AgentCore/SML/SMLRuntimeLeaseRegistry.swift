import Foundation

/// Session-scoped worker leases for durable SML runtime hosts.
///
/// A lease is minted once per host session and never persisted: restarting the host mints a new
/// lease, and the store's durable dispatch-claim records — not the lease — keep capability
/// execution exactly-once across restarts. What the lease owns is TASK authority: a task created
/// through this lease (a `workflow.run` / `workflow.run_matching` command) becomes operable by
/// this lease; tasks created by other leases stay invisible to it, so two hosts sharing one store
/// cannot approve or roll back each other's work by accident.
///
/// Task binding is optimistic at resolution time: a creating command's task is bound before the
/// gateway admits it. A bound-but-never-created task grants nothing exploitable — every later
/// command still crosses the full admission gates, and a task ID that was never created fails in
/// the runtime, not in authority.
public enum SMLRuntimeLeaseRegistry {
    /// Operations whose command names a NEW task the lease should adopt.
    public static let taskCreatingOperations: Set<String> = [
        SMLRuntimeCommandOperation.workflowRun,
        SMLRuntimeCommandOperation.workflowRunMatching,
    ]

    /// The synthetic task identifier generated metadata surfaces use (`workflow.inspect`,
    /// `runtime.status`, `roles.list`, `workflows.list`).
    public static let runtimeMetadataTask = "runtime"

    public actor Session {
        public nonisolated let leaseID: String
        private var boundTasks: Set<String> = []

        public init(leaseID: String? = nil) {
            let minted = leaseID ?? "sml-host-lease-\(UUID().uuidString.lowercased())"
            precondition(
                SMLValidationSupport.identifierIsValid(minted),
                "minted lease ID must be a valid SML identifier"
            )
            self.leaseID = minted
        }

        /// The task set this lease may present as authority for one command. Creating operations
        /// adopt the command's own task; everything else is confined to already-bound tasks plus
        /// the synthetic runtime-metadata task.
        public func authorizedTasks(for command: SMLCommandEnvelope) -> Set<String> {
            if SMLRuntimeLeaseRegistry.taskCreatingOperations.contains(command.op) {
                boundTasks.insert(command.task)
            }
            var tasks = boundTasks
            tasks.insert(SMLRuntimeLeaseRegistry.runtimeMetadataTask)
            return tasks
        }

        /// Adopts a task created outside the command path (e.g. recovered from a prior session's
        /// snapshot when the operator explicitly resumes it). Explicit, never automatic.
        public func adopt(taskID: String) {
            boundTasks.insert(taskID)
        }

        public func ownsTask(_ taskID: String) -> Bool {
            boundTasks.contains(taskID)
        }

        public func ownedTasks() -> Set<String> {
            boundTasks
        }
    }
}
