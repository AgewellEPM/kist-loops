import Foundation

// Checkpoint persistence, interrupted-action reconciliation, resume-boundary invalidation,
// argument parsing, and model-profile stop injection. Extracted verbatim from
// HeadlessAgentLoop.swift — behavior unchanged.
extension HeadlessAgentLoop {
    /// Reconcile an interrupted action — steer the model to verify, not blindly replay (both loops).
    func reconcile(_ cp: inout LoopCheckpoint) {
        guard let pending = cp.pendingAction else { return }
        let predicted = pending.predictedEffects
            ?? Self.legacyPendingEffects(tool: pending.tool, argsSummary: pending.argsSummary)
        if predicted.mutation != .none {
            let uncertain = ToolEffectObservation(
                mutation: predicted.mutation, mutationEvidence: .mayMutate)
            recorder.record(
                tool: pending.tool,
                argsFingerprint: "interrupted:\(pending.argsSummary)",
                success: false,
                failureDetail: "interrupted action may have mutated the workspace; reconcile it with a later real mutation and verification",
                effectObservation: uncertain)
        }
        cp.messages.append(ChatMessage(role: .user, content:
            "NOTE: the previous action \(pending.tool)(\(pending.argsSummary)) was INTERRUPTED and may or may not have completed. Before retrying, VERIFY the current state (re-read or re-list) — do NOT blindly repeat a write or command."))
        cp.pendingAction = nil
        // Atomically replace the pending bracket with its durable uncertainty evidence. If this save
        // fails, the old on-disk checkpoint still retains the pending marker and will fail closed again.
        persist(&cp)
        sink.emit(.replanStarted(reason: "reconciling interrupted action: \(pending.tool)"))
    }

    /// A pre-resume build/test says nothing about workspace changes made while kist was not running.
    /// Insert an unconfirmed mutation boundary when prior source proof must be invalidated, or when a
    /// mutation-promising turn has no source/unknown record at all (offline source drift would otherwise be
    /// invisible behind a docs-only ledger). An already-unverified source record needs no duplicate boundary.
    static func resumeBoundaryRecord(
        for trajectory: [ActionRecord], expectedOutcome: TaskBrief.ExpectedOutcome?
    ) -> ActionRecord? {
        // Never let a synthetic *successful* boundary supersede a real failed mutation. CompletionVerifier
        // deliberately rejects a failed latest mutation until a later real mutation repairs it; appending
        // the boundary after that failure would make a fresh test look like recovery even though no repair
        // occurred.
        guard trajectory.last(where: { $0.observedEffects.mutation != .none })?.success != false else {
            return nil
        }
        let hasBuildRelevantMutation = trajectory.contains {
            $0.observedEffects.requiresBuildVerification
        }
        let mutationTurnNeedsWorkspaceBinding = expectedOutcome == .mutation
            && !hasBuildRelevantMutation
        let staleProofNeedsInvalidation: Bool
        if let mutationIndex = trajectory.lastIndex(where: {
            $0.success && $0.observedEffects.requiresBuildVerification
        }), mutationIndex + 1 < trajectory.count {
            staleProofNeedsInvalidation = trajectory[(mutationIndex + 1)...].contains {
                $0.success && $0.observedEffects.verification == .buildOrTest
            }
        } else {
            staleProofNeedsInvalidation = false
        }
        guard mutationTurnNeedsWorkspaceBinding || staleProofNeedsInvalidation else { return nil }
        return ActionRecord(
            tool: "resume_boundary",
            argsFingerprint: "workspace-state-unbound",
            success: true,
            effectObservation: ToolEffectObservation(
                mutation: .unknownTarget, mutationEvidence: .mayMutate))
    }

    /// Pending actions written before `predictedEffects` used the human-facing `compactArgs` shape
    /// (`command: ls`), not the stable trajectory fingerprint (`command=ls`). Recover the unambiguous,
    /// untruncated command-only form so an interrupted read does not become a permanent failed mutation.
    /// Ambiguous/multi-field/truncated summaries deliberately fall back to the conservative legacy parser.
    private static func legacyPendingEffects(tool: String, argsSummary: String) -> ToolEffectObservation {
        guard tool == "run_command", argsSummary.hasPrefix("command: ") else {
            return ToolEffectCatalog.inferLegacy(tool: tool, argsFingerprint: argsSummary)
        }
        let command = String(argsSummary.dropFirst("command: ".count))
        let laterFieldMarkers = [
            ", cpu_limit: ", ", cwd: ", ", executable: ", ", file_size_limit_mb: ",
            ", memory_limit_mb: ", ", shell: ", ", timeout: ",
        ]
        guard !command.hasSuffix("..."),
              !laterFieldMarkers.contains(where: command.contains) else {
            return ToolEffectCatalog.inferLegacy(tool: tool, argsFingerprint: argsSummary)
        }
        return CommandClassifier.observe(arguments: ["command": command])
    }

    static func parseArgs(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return obj
    }

    // MARK: - Internals

    /// Persist the checkpoint after an iteration. Fail-closed surfacing: a write failure becomes
    /// a `.checkpointFailed` event (lost durability) but does not abort the run.
    func persist(_ cp: inout LoopCheckpoint) {
        // Keep evidence and transcript under the same atomic checkpoint write. Do this even when no
        // store is configured so the final in-memory checkpoint returned by drive remains complete.
        cp.trajectory = recorder.snapshot()
        guard let store = checkpoints else { return }
        cp.updatedAt = Date()
        do {
            try store.save(cp)
            sink.emit(.checkpointSaved(id: cp.id, iteration: cp.iteration))
        } catch {
            sink.emit(.checkpointFailed("\(error)"))
        }
    }

    /// Inject a verified local model's stop sequences (from Drop-a-Key/Drop-a-Doc onboarding) into the
    /// generation settings, so the model halts at its real turn boundary. No-op when no profile matches.
    @discardableResult
    func applyModelProfileStops(_ settings: inout ModelSettings) -> Bool {
        if let stops = modelProfiles?.stops(providerId: providerId, model: model), !stops.isEmpty {
            settings.stopSequences = stops
            return true
        }
        return false
    }
}
