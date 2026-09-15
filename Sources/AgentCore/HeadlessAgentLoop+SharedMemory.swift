import Foundation

extension HeadlessAgentLoop {
    /// One boundary for fresh, conversational, resumed, generic and specialist loops. Parent context
    /// is inherited by structured/background Tasks; checkpoint identity survives a process restart.
    func drive(_ initial: LoopCheckpoint, heldRunLease: LoopCheckpointRunLease? = nil) async -> (Outcome, LoopCheckpoint) {
        let lease: LoopCheckpointRunLease?
        do { lease = try heldRunLease ?? checkpoints?.acquireRunLease(id: initial.id) }
        catch {
            let reason = "checkpoint run refused: \(error)"
            sink.emit(.stateChanged(.failed)); sink.emit(.failed(reason))
            return (Outcome(success: false, summary: reason, iterations: initial.iteration,
                            checkpointId: initial.id), initial)
        }
        // Own the checkpoint through child cleanup and the final durable history/status update.
        defer { lease?.release() }
        guard let access = context.agentMemory else {
            return await finishOwnedDelegations(await driveCore(initial))
        }
        let parent = AgentExecutionScope.current
        let identity = initial.agentIdentity ?? AgentRunIdentity(
            runID: initial.id, parentRunID: parent?.runID,
            rootRunID: parent?.rootRunID ?? context.correlationID ?? initial.id,
            sessionID: parent?.sessionID ?? access.sessionID,
            role: traceRole ?? (parent == nil ? "assistant" : "worker"),
            project: access.project, executionRoot: context.projectRoot)
        guard identity.project == access.project, identity.runID == initial.id else {
            let reason = "shared agent identity does not match the host-authorized project/checkpoint"
            return (Outcome(success: false, summary: reason, iterations: initial.iteration,
                            checkpointId: initial.id), initial)
        }
        return await AgentExecutionScope.$current.withValue(identity) {
            var prepared = initial
            prepared.agentIdentity = identity
            do {
                try access.history.append(agent: identity,
                    kind: initial.agentIdentity == nil ? "run_started" : "run_resumed",
                    detail: initial.rawRequest ?? initial.goal)
                let memory = try access.bootstrap(query: initial.rawRequest ?? initial.goal, agent: identity)
                // Replace only host-generated recall messages; preserve the current user objective last.
                prepared.messages.removeAll { $0.content.hasPrefix("[KIST_SHARED_AGENT_MEMORY_V1]\n") }
                prepared.messages.insert(ChatMessage(role: .user, content: memory),
                                         at: max(0, prepared.messages.count - 1))
            } catch {
                let reason = "shared agent memory initialization failed: \(error)"
                sink.emit(.checkpointFailed(reason))
                prepared.status = .failed; prepared.summary = reason; persist(&prepared)
                return (Outcome(success: false, summary: reason, iterations: initial.iteration,
                                checkpointId: initial.id), prepared)
            }
            var result = await finishOwnedDelegations(await driveCore(prepared))
            do {
                try access.history.append(agent: identity, kind: "run_finished",
                    detail: "success=\(result.0.success); status=\(result.1.status.rawValue); provider_fault=\(result.0.providerFault)\n\(result.0.summary)")
            } catch { _ = agentHistoryHealth.recordFailure(String(describing: error)) }
            if let error = agentHistoryHealth.error {
                let reason = result.0.summary + "\nAgent history durability failed: \(error)"
                result.1.status = .failed; result.1.summary = reason; persist(&result.1)
                sink.emit(.stateChanged(.failed)); sink.emit(.failed(reason))
                return (Outcome(success: false, summary: reason,
                                iterations: result.0.iterations, checkpointId: result.0.checkpointId,
                                providerFault: result.0.providerFault), result.1)
            }
            return result
        }
    }

    private func finishOwnedDelegations(_ result: (Outcome, LoopCheckpoint)) async -> (Outcome, LoopCheckpoint) {
        let owned = Set(result.1.delegationHandles ?? [])
        guard !owned.isEmpty else { return result }
        var registries = Set<ObjectIdentifier>()
        var stopped = [DelegationSnapshot]()
        for tool in tools.all() {
            guard let source = tool as? any AsyncDelegationRegistryProviding,
                  registries.insert(ObjectIdentifier(source.delegationRegistry)).inserted else { continue }
            stopped += await source.delegationRegistry.cancelAndDrain(handleIDs: owned)
        }
        guard !stopped.isEmpty else { return result }
        var cp = result.1
        let reason = result.0.summary + "\nStopped and drained \(stopped.count) unfinished background agent(s). Join delegated work before ending the turn."
        if cp.status != .paused { cp.status = .failed }
        cp.summary = reason; persist(&cp)
        sink.emit(.failed(reason))
        return (Outcome(success: false, summary: reason, iterations: result.0.iterations,
                        checkpointId: result.0.checkpointId, providerFault: result.0.providerFault), cp)
    }

}
