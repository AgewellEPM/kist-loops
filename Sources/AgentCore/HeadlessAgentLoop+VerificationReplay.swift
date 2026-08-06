import Foundation

/// Deterministic re-verification for verify-before-done (dogfood find 2026-08-06).
///
/// The failure this closes: the agent compiled + ran its build, made ONE more source edit,
/// then answered "done". verify-before-done correctly demanded a fresh build/test, but the
/// model (post-compaction) kept insisting it was done — burning the whole nudge budget and
/// failing a turn whose final edit was actually CORRECT. Symbolic-first: the loop itself now
/// re-runs the LAST passing build/test command of THIS run before spending nudges on the
/// model. The harness replays; the verdict is real; the LLM doesn't get a vote.
extension HeadlessAgentLoop {
    /// The most recent PASSING build/test action of this run — the replay candidate. Carries
    /// the exact execution context it was approved with, so the replay exercises no authority
    /// beyond what the original, already-approved invocation had.
    struct VerificationReplay {
        let tool: String
        let args: [String: Any]
        let context: ToolContext
    }

    /// If this successful step was a real build/test (as classified by its recorded effect),
    /// it becomes the replay candidate; anything else returns nil.
    static func replayCandidate(tool: String, args: [String: Any], context: ToolContext,
                                succeeded: Bool, observed: ToolEffectObservation) -> VerificationReplay? {
        guard succeeded, observed.verification == .buildOrTest else { return nil }
        return VerificationReplay(tool: tool, args: args, context: context)
    }

    /// Re-run the remembered build/test EXACTLY as previously approved and executed (identical
    /// tool + args + context — same run, no new authority). The result is recorded into the
    /// trajectory and the transcript, so the verifier re-judges on real evidence and the model
    /// sees the output either way. Returns true when the replayed verification PASSED.
    func replayVerification(_ replay: VerificationReplay, cp: inout LoopCheckpoint,
                            iteration: Int) async -> Bool {
        sink.emit(.actionStarted(index: iteration, tool: replay.tool,
                                 description: "re-verify · replaying the last passing build/test"))
        let result = await tools.execute(name: replay.tool, arguments: replay.args, context: replay.context)
        sink.emit(.actionFinished(index: iteration, success: result.success,
                                  output: result.output, error: result.error))
        recorder.record(tool: replay.tool,
                        argsFingerprint: TrajectoryAnalyzer.fingerprint(replay.args),
                        success: result.success,
                        failureDetail: result.success ? nil : String(Self.failureAwareRaw(result).prefix(1500)),
                        effectObservation: tools.effectObservation(name: replay.tool, arguments: replay.args,
                                                                   result: result))
        let raw = Self.failureAwareRaw(result)
        let body = Self.toolObservationBody(raw: raw, metadata: result.metadata, maxBytes: maxObservationBytes)
        cp.messages.append(ChatMessage(role: .user, content:
            "[re-verify] the loop re-ran the last passing build/test after your final edit:\n"
            + Self.toolOutputEnvelope(tool: replay.tool, success: result.success, body: body)))
        persist(&cp)
        return result.success
    }
}
