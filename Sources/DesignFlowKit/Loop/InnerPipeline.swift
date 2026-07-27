import Foundation
import AgentCore

/// The inner loop — the assembly line. For each agent: produce → GATE → commit →
/// RECONCILE. The gate is fail-closed: if a stage produces no real artifact, the
/// pipeline STOPS. No stage can advance on a claim. Each accepted artifact is
/// committed immediately (via the fleet's GitIsolation), then the fleet's
/// ClaimReconciler proves the artifact is actually in the committed merge-set —
/// not merely on disk. History is the audit trail.
public struct InnerPipeline: Sendable {
    private let gate: ArtifactGate
    private let log: Log

    public init(gate: ArtifactGate = ArtifactGate(), log: Log = Log("pipeline")) {
        self.gate = gate
        self.log = log
    }

    public struct Result: Sendable {
        public let seedBrief: String
        public let workspace: URL
        public let artifacts: [Artifact]
        public let completed: Bool
        public let blockedStage: AgentKind?
        public let blockReason: String?
        /// ForgeSeal-sealed signoff, one per accepted stage. Tamper-evident.
        public let signoffs: [StageSignoff]
        /// True iff the on-disk signoff chain verifies (seal + hash chain intact).
        public let signoffChainIntact: Bool

        public init(seedBrief: String, workspace: URL, artifacts: [Artifact], completed: Bool,
                    blockedStage: AgentKind?, blockReason: String?,
                    signoffs: [StageSignoff] = [], signoffChainIntact: Bool = true) {
            self.seedBrief = seedBrief
            self.workspace = workspace
            self.artifacts = artifacts
            self.completed = completed
            self.blockedStage = blockedStage
            self.blockReason = blockReason
            self.signoffs = signoffs
            self.signoffChainIntact = signoffChainIntact
        }
    }

    /// Run `agents` against a fresh workspace seeded with `brief`.
    /// Returns partial results if the gate blocks midway — the truth of what was
    /// actually produced, never a rounded-up "success".
    public func run(brief: String, agents: [Agent], workspace: GitWorkspace) async -> Result {
        do { try workspace.initialize() } catch {
            return Result(seedBrief: brief, workspace: workspace.root, artifacts: [],
                          completed: false, blockedStage: nil,
                          blockReason: "workspace init failed: \(error)")
        }

        var context = PipelineContext(seedBrief: brief)
        try? workspace.write(brief, to: "SEED.md")
        _ = try? workspace.commit("designflow: seed brief")

        // The sealed, tamper-evident signoff chain for this run (sidecar to the repo).
        let signoffLedger = StageSignoffLedger(
            fileURL: workspace.root.appendingPathComponent(".designflow-signoff.jsonl"))
        var signoffs: [StageSignoff] = []

        for agent in agents {
            // Honor cancellation between stages so a SIGINT'd daemon stops promptly
            // instead of burning budget on the rest of the pipeline.
            if Task.isCancelled {
                log.warn("cancelled before \(agent.kind.displayName)")
                return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                              completed: false, blockedStage: agent.kind,
                              blockReason: "cancelled", signoffs: signoffs)
            }
            log.info("stage \(agent.kind.displayName) starting")

            // Snapshot the artifact's mtime BEFORE producing. In a reused workspace a
            // stale artifact may already exist; the gate uses this to require freshness.
            let artifactURL = workspace.root.appendingPathComponent(agent.kind.artifactPath)
            let priorMTime = ArtifactGate.modificationTime(artifactURL)

            // 1. Produce.
            let text: String
            do {
                text = try await agent.produce(context: context, workspace: workspace)
            } catch {
                log.error("stage \(agent.kind.displayName) failed to produce: \(error)")
                return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                              completed: false, blockedStage: agent.kind,
                              blockReason: "produce error: \(error)", signoffs: signoffs)
            }

            // 2. GATE — the trust spine. Verify the artifact exists, is non-empty,
            //    and is FRESH (not a stale file left by a prior run).
            do {
                let bytes = try gate.verify(stage: agent.kind, in: workspace.root, priorModification: priorMTime)
                log.debug("gate ok: \(agent.kind.artifactPath) (\(bytes) bytes)")
            } catch {
                log.error("\(error)")
                return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                              completed: false, blockedStage: agent.kind,
                              blockReason: String(describing: error), signoffs: signoffs)
            }

            // 3. Commit — accepted work lands in history right away. Capture HEAD
            //    BEFORE the commit so reconciliation measures THIS stage's diff only
            //    (preHead...HEAD), never the cumulative root...HEAD — a no-op stage
            //    must not pass on a prior stage's committed paths (Codex HIGH-4).
            let preStageHead = workspace.headSHA() ?? ""
            var artifact = Artifact(stage: agent.kind, relativePath: agent.kind.artifactPath,
                                    summary: String(text.prefix(160)))
            do {
                artifact.commitSHA = try workspace.commit("designflow: \(agent.kind.displayName) → \(agent.kind.artifactPath)")
                log.success("stage \(agent.kind.displayName) committed \(artifact.commitSHA ?? "?")")
            } catch {
                log.error("commit failed for \(agent.kind.displayName): \(error)")
                return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                              completed: false, blockedStage: agent.kind,
                              blockReason: "commit error: \(error)", signoffs: signoffs)
            }
            // A stage that produced NO new commit did no committed work — block it,
            // even though the file exists and is fresh (Codex HIGH-4, fail-closed).
            guard let stageSHA = artifact.commitSHA, !stageSHA.isEmpty else {
                log.error("\(agent.kind.displayName) made no committed change — blocking")
                return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                              completed: false, blockedStage: agent.kind,
                              blockReason: "no committed change (nothing new to seal)", signoffs: signoffs)
            }

            // 4. RECONCILE — the fleet's anti-hallucination gate, scoped to THIS stage's
            //    committed diff (preStageHead...HEAD). Proves the artifact actually landed
            //    in the commit this stage made — not merely on disk, not a prior stage's
            //    path. Catches gitignored/untracked/no-op artifacts. Stricter-only.
            let claims = AgentClaims(files: [agent.kind.artifactPath], symbols: [], testsPass: nil, actions: [])
            let findings = ClaimReconciler.reconcile(
                claims: claims,
                committedFiles: workspace.committedPaths(since: preStageHead),
                diffText: workspace.committedDiff(since: preStageHead),
                testExitCode: 0)
            if !findings.isEmpty {
                let reason = findings.map { "\($0.kind): \($0.detail)" }.joined(separator: "; ")
                log.error("claim reconciliation blocked \(agent.kind.displayName): \(reason)")
                return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                              completed: false, blockedStage: agent.kind,
                              blockReason: "claim reconciliation: \(reason)", signoffs: signoffs)
            }

            // 5. SEAL — append a ForgeSeal-sealed, hash-chained signoff for the accepted
            //    stage. Tamper-evident receipt of measured facts (artifact, commit, merged
            //    paths). Not a code verdict — the fleet's code-signoff currency stays locked.
            //    append() throws if the seal is empty (no ForgeSeal key) or the chain
            //    fails to extend — so an UNSEALED signoff can never let a stage advance
            //    (Codex BLOCKER-2, fail-closed).
            do {
                let signoff = try signoffLedger.append(
                    projectID: brief, stage: agent.kind, artifactPath: agent.kind.artifactPath,
                    commitSHA: stageSHA,
                    artifactHash: workspace.contentHash(of: agent.kind.artifactPath) ?? "",
                    committedPaths: workspace.committedPaths(since: preStageHead),
                    atEpoch: Date().timeIntervalSince1970)
                signoffs.append(signoff)
                log.success("sealed signoff seq \(signoff.seq) [\(signoff.seal?.prefix(8) ?? "unsealed")…]")
            } catch {
                log.error("signoff seal failed for \(agent.kind.displayName): \(error)")
                return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                              completed: false, blockedStage: agent.kind,
                              blockReason: "signoff error: \(error)", signoffs: signoffs)
            }

            context.record(artifact, text: text)
        }

        // Final fail-closed guard: a run is only COMPLETE if the whole sealed chain
        // verifies on disk. A broken/unsealed chain can never report completed (BLOCKER-2).
        let chainIntact = signoffLedger.verifyChain() == nil
        guard chainIntact else {
            log.error("signoff chain not intact at completion — refusing COMPLETE")
            return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                          completed: false, blockedStage: agents.last?.kind,
                          blockReason: "signoff chain broken", signoffs: signoffs, signoffChainIntact: false)
        }
        return Result(seedBrief: brief, workspace: workspace.root, artifacts: context.artifacts,
                      completed: true, blockedStage: nil, blockReason: nil,
                      signoffs: signoffs, signoffChainIntact: true)
    }
}
