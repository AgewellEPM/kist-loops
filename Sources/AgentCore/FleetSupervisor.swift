import Foundation

/// The MISSING LOOP that closes the baton. A bare launcher is fire-and-forget — it reports "launched" and
/// returns, blind to whether any agent finished. This supervisor WAITS, VERIFIES, SIGNS, and PROPAGATES —
/// turning "launched" into "verified done, signed, on the board."
///
/// THE LOOP (bounded — never infinite): poll until every agent is terminal OR the sweep cap is hit; each
/// sweep: (1) read pending inbox updates → fold+ack self-reported progress (advisory) only after the
/// blackboard write persists. (2) For each live agent: fold its live progress signal (advisory);
/// if its `.fleet-done` sentinel is present → Foreman.inspect →
/// on GREEN seal+fold-signedOff+append a proven BatonContribution+refresh peer slices+advance the baton
/// verified→passed; on NON-GREEN reject (bump rejectCount, surface blockers, bounce held/failed). If the
/// deadline elapsed with no sentinel → timeout (mark failed, record partial, NEVER auto-merge).
///
/// SAFETY: "done" is ONLY a green judge over MEASURED evidence → a sealed ledger entry. The supervisor
/// never touches main (the merge gate joins onto a fresh integration branch, guarded in GitIsolation).
/// Every loop is bounded (maxSweeps). All real effects (sentinel probe, clock, slice writer, inter-sweep
/// wait, progress reader, merge) are injectable seams so unit tests drive the whole loop with ZERO real
/// git/sleep.
///
/// Ported from TinkySDR's Captain (Stage 2). Adaptations: @MainActor dropped; Foreman.inspect takes the
/// cell's derived `foremanSubject`; the `FleetLessonStore` (Phase C) is deferred to Stage 3; the
/// done-sentinel + live progress use Mythos's `FleetSentinel`. LABEL: PROTOTYPE.

/// A live, advisory progress summary derived from an agent's `.fleet-progress.jsonl` (folded for cockpit
/// visibility — never gates a signoff).
public struct FleetProgress: Equatable, Sendable {
    public let latestStep: Int
    public let lastAction: String
    public let lastActionEpoch: Double
    public let lastFile: String?
    public init(latestStep: Int, lastAction: String, lastActionEpoch: Double, lastFile: String? = nil) {
        self.latestStep = latestStep
        self.lastAction = lastAction
        self.lastActionEpoch = lastActionEpoch
        self.lastFile = lastFile
    }
}

/// Continuous supervision policy: how quickly Captain intervenes while workers are still running. This
/// is not the terminal Foreman gate; it is the live oversight layer that notices drift before the end.
public struct FleetSupervisorPolicy: Equatable, Sendable {
    public let staleAfterSeconds: Double
    public let maxInterventionsPerAgent: Int
    public let escalateAfterSeconds: Double
    public let maxEscalationsPerAgent: Int

    public init(staleAfterSeconds: Double = 180,
                maxInterventionsPerAgent: Int = 2,
                escalateAfterSeconds: Double = 300,
                maxEscalationsPerAgent: Int = 1) {
        self.staleAfterSeconds = max(1, staleAfterSeconds)
        self.maxInterventionsPerAgent = max(0, maxInterventionsPerAgent)
        self.escalateAfterSeconds = max(1, escalateAfterSeconds)
        self.maxEscalationsPerAgent = max(0, maxEscalationsPerAgent)
    }
}

/// A repair directive issued while a fleet worker is still live. Advisory progress never signs work off,
/// but a supervisor intervention is durable proof that Captain did not leave autonomous work unattended.
public struct FleetSupervisorIntervention: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case stale, blocked, drift }
    public let kind: Kind
    public let agentID: UUID
    public let title: String
    public let summary: String
    public let directive: String
    public let evidence: [String]

    public init(kind: Kind, agentID: UUID, title: String, summary: String,
                directive: String, evidence: [String]) {
        self.kind = kind
        self.agentID = agentID
        self.title = title
        self.summary = summary
        self.directive = directive
        self.evidence = evidence
    }
}

/// A durable rescue assignment issued only after a delivered supervisor directive has not cleared the
/// worker's blocked/stale/drift risk. This does not trust or merge anything; it creates auditable work for
/// a repair/rescue pass so Captain can keep supervising instead of silently waiting.
public struct FleetSupervisorEscalation: Equatable, Sendable {
    public let kind: FleetSupervisorIntervention.Kind
    public let agentID: UUID
    public let title: String
    public let summary: String
    public let assignment: String
    public let evidence: [String]

    public init(kind: FleetSupervisorIntervention.Kind, agentID: UUID, title: String, summary: String,
                assignment: String, evidence: [String]) {
        self.kind = kind
        self.agentID = agentID
        self.title = title
        self.summary = summary
        self.assignment = assignment
        self.evidence = evidence
    }
}

/// The honest, machine-readable result of supervising a fleet to its conclusion. A `signed` count comes
/// ONLY from sealed signoffs — a claimed-done string never counts. Never claims "done" when partial.
public struct FleetSupervisionResult: Equatable, Sendable {
    public let total: Int
    public let signed: Int          // SEALED signoffs — the only "really done" tally
    public let rejected: Int        // exhausted retry budget → .failed
    public let timedOut: Int        // deadline elapsed in .held
    public let stillRunning: Int    // never reached terminal within maxSweeps
    public let interventions: Int   // live Captain repair directives issued before terminal failure
    public let escalations: Int      // rescue assignments issued after unresolved interventions
    public let persistenceFailures: Int
    public let summary: String
    public var allSigned: Bool { persistenceFailures == 0 && signed == total && total > 0 }
    public init(total: Int, signed: Int, rejected: Int, timedOut: Int, stillRunning: Int,
                interventions: Int = 0, escalations: Int = 0,
                persistenceFailures: Int = 0, summary: String) {
        self.total = total; self.signed = signed; self.rejected = rejected
        self.timedOut = timedOut; self.stillRunning = stillRunning
        self.interventions = interventions; self.escalations = escalations; self.summary = summary
        self.persistenceFailures = persistenceFailures
    }
}

public final class FleetSupervisor: @unchecked Sendable {

    private let board: FleetBlackboardStore
    private let inbox: FleetUpdateInbox
    private let ledger: FleetSignoffLedger
    private let batons: FleetBatonStore
    private let foreman: Foreman

    private let doneSentinelPresent: (_ worktreePath: String) -> Bool
    private let nowEpoch: () -> Double
    private let writeSlice: (_ worktreePath: String, _ digest: String) -> Bool
    private let waitBetweenSweeps: () async -> Void
    private let readProgress: (_ worktreePath: String) -> FleetProgress?
    private let headSHA: (_ worktreePath: String) -> String
    private let writeIntervention: (_ worktreePath: String, _ intervention: FleetSupervisorIntervention) -> Bool
    private let writeEscalation: (_ worktreePath: String, _ escalation: FleetSupervisorEscalation) -> Bool
    private let archiveRejectedDone: (_ worktreePath: String, _ atEpoch: Double) -> Bool
    private var rejectedSurrenders: Set<String> = []
    private var boardPersistenceFailures: [String] = []
    private var inboxPersistenceFailures: [String] = []

    private let maxSweeps: Int
    private let maxRejects: Int
    private let policy: FleetSupervisorPolicy

    /// Phase-4 merge seam. Default = GitIsolation.mergeIntoIntegration (NEVER touches main). Tests inject
    /// a recorder so no real git runs.
    private let merge: (_ repo: String, _ base: String, _ branches: [String],
                        _ integrationBranch: String, _ nowEpoch: Double) -> GitIsolation.MergeResult

    public init(board: FleetBlackboardStore,
                inbox: FleetUpdateInbox,
                ledger: FleetSignoffLedger,
                batons: FleetBatonStore,
                foreman: Foreman,
                maxSweeps: Int = 600,
                maxRejects: Int = 2,
                doneSentinelPresent: ((String) -> Bool)? = nil,
                nowEpoch: (() -> Double)? = nil,
                writeSlice: ((String, String) -> Bool)? = nil,
                waitBetweenSweeps: (() async -> Void)? = nil,
                readProgress: ((String) -> FleetProgress?)? = nil,
                headSHA: ((String) -> String)? = nil,
                policy: FleetSupervisorPolicy = FleetSupervisorPolicy(),
                writeIntervention: ((String, FleetSupervisorIntervention) -> Bool)? = nil,
                writeEscalation: ((String, FleetSupervisorEscalation) -> Bool)? = nil,
                archiveRejectedDone: ((String, Double) -> Bool)? = nil,
                merge: ((String, String, [String], String, Double) -> GitIsolation.MergeResult)? = nil) {
        self.board = board
        self.inbox = inbox
        self.ledger = ledger
        self.batons = batons
        self.foreman = foreman
        self.maxSweeps = max(1, maxSweeps)
        self.maxRejects = max(0, maxRejects)
        self.policy = policy
        self.merge = merge ?? { repo, base, branches, intBranch, epoch in
            GitIsolation.mergeIntoIntegration(repo: repo, base: base, branches: branches,
                                              integrationBranch: intBranch, nowEpoch: epoch)
        }
        self.doneSentinelPresent = doneSentinelPresent ?? { path in FleetSentinel.isDone(inWorktree: path) }
        self.nowEpoch = nowEpoch ?? { Date().timeIntervalSince1970 }
        self.writeSlice = writeSlice ?? { path, digest in
            let url = URL(fileURLWithPath: (path as NSString).appendingPathComponent(".mythos-fleet-slice.md"))
            do {
                try digest.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        self.waitBetweenSweeps = waitBetweenSweeps ?? { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        self.readProgress = readProgress ?? { path in
            let events = FleetSentinel.readProgress(inWorktree: path)
            guard let last = events.last else { return nil }
            let latestStep = events.map(\.step).max() ?? last.step
            return FleetProgress(latestStep: latestStep, lastAction: last.action,
                                 lastActionEpoch: last.at, lastFile: last.file)
        }
        self.headSHA = headSHA ?? Self.readHeadSHA
        self.writeIntervention = writeIntervention ?? { path, intervention in
            let url = URL(fileURLWithPath: (path as NSString).appendingPathComponent(".mythos-fleet-supervisor.md"))
            do {
                try (intervention.directive + "\n").write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        self.writeEscalation = writeEscalation ?? { path, escalation in
            let url = URL(fileURLWithPath: (path as NSString).appendingPathComponent(".mythos-fleet-rescue.md"))
            do {
                try (escalation.assignment + "\n").write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
        self.archiveRejectedDone = archiveRejectedDone
            ?? { path, epoch in FleetSentinel.archiveRejectedDone(inWorktree: path, atEpoch: epoch) }
    }

    // MARK: - The supervision loop

    /// Supervise a launched fleet to conclusion. The board must already be seeded (cells .pending/.working)
    /// and one baton minted per agent. Returns an HONEST result.
    @discardableResult
    public func supervise(goalID: String) async -> FleetSupervisionResult {
        var sweeps = 0
        while sweeps < maxSweeps {
            sweeps += 1

            for pending in inbox.readPending() {
                if board.foldUpdate(pending.update, receivedAtEpoch: nowEpoch()) {
                    if !inbox.acknowledge(pending) {
                        recordInboxPersistenceFailure("failed to acknowledge inbox update for \(pending.update.agentID.uuidString)")
                    }
                } else {
                    recordBoardPersistenceFailure("failed to persist inbox update for \(pending.update.agentID.uuidString)")
                }
            }
            reconcilePendingDeliveries()
            if hasPersistenceFailures { break }

            let snapshot = board.currentBoard()
            let cells = snapshot?.cells ?? []
            var anyLive = false
            for cell in cells where !Self.isTerminal(cell.status) {
                if hasPersistenceFailures { break }
                anyLive = true
                let now = nowEpoch()

                var observed = cell
                let progress = readProgress(cell.worktreePath)
                if let p = progress {
                    let progressIsFutureDated = p.lastActionEpoch > now + 5
                    let progressIsNew = p.latestStep != cell.liveStep
                        || p.lastAction != cell.lastAction
                        || p.lastActionEpoch > cell.lastHeartbeatEpoch
                        || !(p.lastFile?.isEmpty ?? true)
                    if !board.foldProgress(agentID: cell.id, liveStep: p.latestStep,
                                           lastAction: p.lastAction, atEpoch: p.lastActionEpoch,
                                           receivedAtEpoch: now,
                                           advanceHeartbeat: progressIsNew && !progressIsFutureDated) {
                        recordBoardPersistenceFailure("failed to persist progress for \(cell.id.uuidString)")
                    }
                    observed.liveStep = p.latestStep
                    observed.lastAction = p.lastAction
                    if progressIsNew && !progressIsFutureDated {
                        observed.lastHeartbeatEpoch = max(observed.lastHeartbeatEpoch,
                                                          min(p.lastActionEpoch, now))
                    }
                }

                guard let baton = batons.all().first(where: { $0.holder == cell.id.uuidString })
                        ?? batons.all().first(where: { $0.currentBranch == cell.branch }) else { continue }

                if doneSentinelPresent(cell.worktreePath) {
                    if alreadyRejectedCurrentSurrender(cell) {
                        if let intervention = continuousIntervention(for: observed,
                                                                     boardStartedAt: snapshot?.startedAt.timeIntervalSince1970,
                                                                     progress: progress,
                                                                     atEpoch: now) {
                            _ = applyIntervention(intervention, to: observed)
                        } else if let escalation = continuousEscalation(for: observed,
                                                                        boardStartedAt: snapshot?.startedAt.timeIntervalSince1970,
                                                                        progress: progress,
                                                                        atEpoch: now) {
                            _ = applyEscalation(escalation, to: observed)
                        }
                    } else {
                        await handleSurrender(cell: cell, baton: baton, goalID: goalID)
                    }
                } else if baton.isPastDeadline(nowEpoch: now) {
                    handleTimeout(cell: cell, baton: baton)
                } else if let intervention = continuousIntervention(for: observed,
                                                                     boardStartedAt: snapshot?.startedAt.timeIntervalSince1970,
                                                                     progress: progress,
                                                                     atEpoch: now) {
                    _ = applyIntervention(intervention, to: observed)
                } else if let escalation = continuousEscalation(for: observed,
                                                                boardStartedAt: snapshot?.startedAt.timeIntervalSince1970,
                                                                progress: progress,
                                                                atEpoch: now) {
                    _ = applyEscalation(escalation, to: observed)
                }
            }

            if hasPersistenceFailures { break }
            if !anyLive { break }
            await waitBetweenSweeps()
        }
        return summarize(goalID: goalID, sweptOut: sweeps >= maxSweeps)
    }

    // MARK: - Continuous supervisor

    private typealias SupervisorRisk = (kind: FleetSupervisorIntervention.Kind, summary: String, evidence: [String])

    private func reconcilePendingDeliveries() {
        guard var b = board.currentBoard() else {
            if board.lastLoadError() != nil {
                recordBoardPersistenceFailure("failed to load board before supervisor delivery reconciliation")
            }
            return
        }
        var changed = false

        for idx in b.cells.indices where !Self.isTerminal(b.cells[idx].status) {
            var cell = b.cells[idx]
            var cellChanged = false

            for recordIndex in cell.supervisorInterventions.indices
                where !cell.supervisorInterventions[recordIndex].delivered {
                let record = cell.supervisorInterventions[recordIndex]
                let kind = FleetSupervisorIntervention.Kind(rawValue: record.kind) ?? .blocked
                let intervention = makeIntervention(kind: kind, cell: cell,
                                                    summary: record.summary, evidence: record.evidence,
                                                    atEpoch: record.atEpoch)
                let digest = board.digest(forAgent: cell.id)
                let slice = digest.isEmpty ? intervention.directive : digest + "\n\n" + intervention.directive
                let directiveDelivered = writeIntervention(cell.worktreePath, intervention)
                let sliceDelivered = writeSlice(cell.worktreePath, slice)
                var deliveryFailures: [String] = []
                if !directiveDelivered { deliveryFailures.append(".mythos-fleet-supervisor.md write failed") }
                if !sliceDelivered { deliveryFailures.append(".mythos-fleet-slice.md write failed") }
                let delivered = directiveDelivered && sliceDelivered

                cell.supervisorInterventions[recordIndex] = SupervisorInterventionRecord(
                    kind: record.kind,
                    atEpoch: record.atEpoch,
                    summary: record.summary,
                    evidence: record.evidence,
                    delivered: delivered,
                    deliveryFailures: deliveryFailures)
                let deliveryText = delivered
                    ? "pending repair directive delivery recovered"
                    : "pending repair directive delivery still failed: \(deliveryFailures.joined(separator: "; "))"
                cell.keyDecisions.append(Note(atEpoch: record.atEpoch,
                    text: "SUPERVISOR INTERVENTION RECOVERY — \(kind.rawValue): \(deliveryText)"))
                cellChanged = true
            }

            for recordIndex in cell.supervisorEscalations.indices
                where !cell.supervisorEscalations[recordIndex].delivered {
                let record = cell.supervisorEscalations[recordIndex]
                let kind = FleetSupervisorIntervention.Kind(rawValue: record.kind) ?? .blocked
                let escalation = FleetSupervisorEscalation(kind: kind,
                                                           agentID: cell.id,
                                                           title: cell.title,
                                                           summary: record.summary,
                                                           assignment: record.assignment,
                                                           evidence: record.evidence)
                let delivered = writeEscalation(cell.worktreePath, escalation)
                let deliveryFailures = delivered ? [] : [".mythos-fleet-rescue.md write failed"]

                cell.supervisorEscalations[recordIndex] = SupervisorEscalationRecord(
                    kind: record.kind,
                    atEpoch: record.atEpoch,
                    summary: record.summary,
                    evidence: record.evidence,
                    assignment: record.assignment,
                    delivered: delivered,
                    deliveryFailures: deliveryFailures)
                let deliveryText = delivered
                    ? "pending rescue assignment delivery recovered"
                    : "pending rescue assignment delivery still failed: \(deliveryFailures.joined(separator: "; "))"
                cell.keyDecisions.append(Note(atEpoch: record.atEpoch,
                    text: "SUPERVISOR ESCALATION RECOVERY — \(kind.rawValue): \(deliveryText)"))
                cellChanged = true
            }

            if cellChanged {
                b.cells[idx] = cell
                changed = true
            }
        }

        guard changed else { return }
        b.revision += 1
        if !board.seed(b) {
            recordBoardPersistenceFailure("failed to persist supervisor delivery reconciliation")
        }
    }

    private func continuousIntervention(for cell: AgentCell,
                                        boardStartedAt: Double?,
                                        progress: FleetProgress?,
                                        atEpoch: Double) -> FleetSupervisorIntervention? {
        guard policy.maxInterventionsPerAgent > 0 else { return nil }
        guard interventionCount(cell) < policy.maxInterventionsPerAgent else { return nil }
        guard let risk = currentRisk(for: cell,
                                     boardStartedAt: boardStartedAt,
                                     progress: progress,
                                     atEpoch: atEpoch,
                                     requireNewWorkerBlockerAfterSupervisor: true) else {
            return nil
        }
        return makeIntervention(kind: risk.kind, cell: cell,
                                summary: risk.summary, evidence: risk.evidence,
                                atEpoch: atEpoch)
    }

    private func continuousEscalation(for cell: AgentCell,
                                      boardStartedAt: Double?,
                                      progress: FleetProgress?,
                                      atEpoch: Double) -> FleetSupervisorEscalation? {
        guard policy.maxEscalationsPerAgent > 0 else { return nil }
        guard escalationCount(cell) < policy.maxEscalationsPerAgent else { return nil }
        guard deliveredInterventionCount(cell) > 0,
              let deliveredAt = latestDeliveredSupervisorInterventionEpoch(cell) else {
            return nil
        }
        guard atEpoch - deliveredAt >= policy.escalateAfterSeconds else { return nil }
        guard let risk = currentRisk(for: cell,
                                     boardStartedAt: boardStartedAt,
                                     progress: progress,
                                     atEpoch: atEpoch,
                                     requireNewWorkerBlockerAfterSupervisor: false) else {
            return nil
        }
        let evidence = risk.evidence + [
            "delivered supervisor interventions: \(deliveredInterventionCount(cell))",
            "last delivered intervention epoch: \(deliveredAt)",
            "unresolved for: \(Int(atEpoch - deliveredAt))s"
        ]
        return makeEscalation(kind: risk.kind, cell: cell,
                              summary: "unresolved \(risk.kind.rawValue) after supervisor intervention: \(risk.summary)",
                              evidence: evidence,
                              atEpoch: atEpoch)
    }

    private func currentRisk(for cell: AgentCell,
                             boardStartedAt: Double?,
                             progress: FleetProgress?,
                             atEpoch: Double,
                             requireNewWorkerBlockerAfterSupervisor: Bool) -> SupervisorRisk? {
        if let rawFile = progress?.lastFile {
            guard let file = Self.normalizeProgressPath(rawFile) else {
                let trimmed = rawFile.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return (.drift,
                            "worker reported non-canonical progress path \(trimmed)",
                            ["reported progress file: \(trimmed)",
                             "lease: \(cell.scopeGlobs.joined(separator: ", "))"])
                }
                return nil
            }
            if !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !Foreman.outOfScopePaths(changed: [file], scopeGlobs: cell.scopeGlobs).isEmpty {
                return (.drift,
                        "worker reported out-of-lease file \(file)",
                        ["reported progress file: \(file)",
                         "lease: \(cell.scopeGlobs.joined(separator: ", "))"])
            }
        }

        if cell.status == .blocked {
            let lastSupervisor = latestSupervisorInterventionEpoch(cell)
            let workerBlockers = cell.blockers
                .filter { !$0.text.hasPrefix("SUPERVISOR ") && $0.atEpoch > lastSupervisor }
            if requireNewWorkerBlockerAfterSupervisor && lastSupervisor != 0 && workerBlockers.isEmpty {
                return nil
            }
            let blockers = workerBlockers.suffix(3).map(\.text)
            let summary = blockers.isEmpty ? "worker reported blocked with no diagnostic"
                                           : "worker reported blocked: \(blockers.joined(separator: "; "))"
            return (.blocked, summary, blockers.isEmpty ? ["status: blocked"] : blockers)
        }

        let reference = cell.lastHeartbeatEpoch > 0 ? cell.lastHeartbeatEpoch : (boardStartedAt ?? atEpoch)
        if atEpoch - reference >= policy.staleAfterSeconds {
            return (.stale,
                    "no worker heartbeat for \(Int(atEpoch - reference))s",
                    ["last heartbeat: \(reference)", "now: \(atEpoch)"])
        }

        return nil
    }

    private func makeIntervention(kind: FleetSupervisorIntervention.Kind, cell: AgentCell,
                                  summary: String, evidence: [String], atEpoch: Double) -> FleetSupervisorIntervention {
        let directive = """
        # Captain Continuous Supervisor

        Agent: \(cell.title)
        Status: \(cell.status.rawValue)
        Intervention: \(kind.rawValue.uppercased())
        Reason: \(summary)
        Evidence: \(evidence.joined(separator: "; "))

        Repair Directive
        1. Stop expanding scope.
        2. Re-read `.mythos-fleet-slice.md` and your lease.
        3. Address the blocker or drift directly.
        4. Append a new `.fleet-progress.jsonl` line explaining the repair step.
        5. Do not write `.fleet-done` until the acceptance criterion is proven by tests.
        """
        return FleetSupervisorIntervention(kind: kind, agentID: cell.id, title: cell.title,
                                           summary: summary, directive: directive, evidence: evidence)
    }

    private func makeEscalation(kind: FleetSupervisorIntervention.Kind, cell: AgentCell,
                                summary: String, evidence: [String], atEpoch: Double) -> FleetSupervisorEscalation {
        let assignment = """
        # Captain Rescue Assignment

        Agent: \(cell.title)
        Status: \(cell.status.rawValue)
        Escalation: \(kind.rawValue.uppercased())
        Reason: \(summary)
        Evidence: \(evidence.joined(separator: "; "))

        Rescue Task
        1. Treat the previous supervisor directive as failed to clear the risk.
        2. Inspect the worker branch \(cell.branch) inside \(cell.worktreePath).
        3. Preserve the original lease: \(cell.scopeGlobs.joined(separator: ", ")).
        4. Produce the smallest repair needed to unblock or fail the worker honestly.
        5. Run acceptance evidence before any new `.fleet-done` marker is trusted.
        6. If repair is unsafe, leave a blocker and do not merge.
        """
        return FleetSupervisorEscalation(kind: kind, agentID: cell.id, title: cell.title,
                                         summary: summary, assignment: assignment,
                                         evidence: evidence)
    }

    @discardableResult
    private func applyIntervention(_ intervention: FleetSupervisorIntervention, to cell: AgentCell) -> Bool {
        let now = nowEpoch()
        guard var b = board.currentBoard(), let idx = b.cells.firstIndex(where: { $0.id == cell.id }) else {
            recordBoardPersistenceFailure("missing board while persisting supervisor intervention for \(cell.id.uuidString)")
            return false
        }
        var c = b.cells[idx]
        let digest = board.digest(forAgent: c.id)
        let slice = digest.isEmpty ? intervention.directive : digest + "\n\n" + intervention.directive
        let recordIndex = c.supervisorInterventions.count
        c.status = .blocked
        c.supervisorInterventions.append(SupervisorInterventionRecord(kind: intervention.kind.rawValue,
                                                                      atEpoch: now,
                                                                      summary: intervention.summary,
                                                                      evidence: intervention.evidence,
                                                                      delivered: false,
                                                                      deliveryFailures: ["delivery pending until board persistence succeeds"]))
        c.blockers.append(Note(atEpoch: now, text: "SUPERVISOR \(intervention.kind.rawValue.uppercased()) — \(intervention.summary)"))
        c.keyDecisions.append(Note(atEpoch: now,
                                   text: "SUPERVISOR INTERVENTION QUEUED — \(intervention.kind.rawValue): board record persisted before worker files are touched"))
        c.lastHeartbeatEpoch = max(c.lastHeartbeatEpoch, now)
        b.cells[idx] = c
        b.revision += 1
        if !board.seed(b) {
            recordBoardPersistenceFailure("failed to persist supervisor intervention for \(cell.id.uuidString)")
            return false
        }

        let directiveDelivered = writeIntervention(c.worktreePath, intervention)
        let sliceDelivered = writeSlice(c.worktreePath, slice)
        var deliveryFailures: [String] = []
        if !directiveDelivered { deliveryFailures.append(".mythos-fleet-supervisor.md write failed") }
        if !sliceDelivered { deliveryFailures.append(".mythos-fleet-slice.md write failed") }
        let delivered = directiveDelivered && sliceDelivered

        guard var afterDelivery = board.currentBoard(),
              let deliveryCellIndex = afterDelivery.cells.firstIndex(where: { $0.id == cell.id }) else {
            recordBoardPersistenceFailure("missing board while persisting supervisor delivery result for \(cell.id.uuidString)")
            return false
        }
        var deliveredCell = afterDelivery.cells[deliveryCellIndex]
        let finalRecord = SupervisorInterventionRecord(kind: intervention.kind.rawValue,
                                                       atEpoch: now,
                                                       summary: intervention.summary,
                                                       evidence: intervention.evidence,
                                                       delivered: delivered,
                                                       deliveryFailures: deliveryFailures)
        if recordIndex < deliveredCell.supervisorInterventions.count {
            deliveredCell.supervisorInterventions[recordIndex] = finalRecord
        } else {
            deliveredCell.supervisorInterventions.append(finalRecord)
        }
        let deliveryText = delivered
            ? "repair directive delivered to .mythos-fleet-supervisor.md and refreshed slice"
            : "repair directive delivery FAILED: \(deliveryFailures.joined(separator: "; "))"
        deliveredCell.keyDecisions.append(Note(atEpoch: now,
                                               text: "SUPERVISOR INTERVENTION — \(intervention.kind.rawValue): \(deliveryText)"))
        afterDelivery.cells[deliveryCellIndex] = deliveredCell
        afterDelivery.revision += 1
        if !board.seed(afterDelivery) {
            recordBoardPersistenceFailure("failed to persist supervisor delivery result for \(cell.id.uuidString)")
            return false
        }
        return true
    }

    @discardableResult
    private func applyEscalation(_ escalation: FleetSupervisorEscalation, to cell: AgentCell) -> Bool {
        let now = nowEpoch()
        guard var b = board.currentBoard(), let idx = b.cells.firstIndex(where: { $0.id == cell.id }) else {
            recordBoardPersistenceFailure("missing board while persisting supervisor escalation for \(cell.id.uuidString)")
            return false
        }
        var c = b.cells[idx]
        let recordIndex = c.supervisorEscalations.count
        c.status = .blocked
        c.supervisorEscalations.append(SupervisorEscalationRecord(kind: escalation.kind.rawValue,
                                                                  atEpoch: now,
                                                                  summary: escalation.summary,
                                                                  evidence: escalation.evidence,
                                                                  assignment: escalation.assignment,
                                                                  delivered: false,
                                                                  deliveryFailures: ["delivery pending until board persistence succeeds"]))
        c.blockers.append(Note(atEpoch: now, text: "SUPERVISOR ESCALATION \(escalation.kind.rawValue.uppercased()) — \(escalation.summary)"))
        c.keyDecisions.append(Note(atEpoch: now,
                                   text: "SUPERVISOR ESCALATION QUEUED — \(escalation.kind.rawValue): board record persisted before rescue files are touched"))
        c.lastHeartbeatEpoch = max(c.lastHeartbeatEpoch, now)
        b.cells[idx] = c
        b.revision += 1
        if !board.seed(b) {
            recordBoardPersistenceFailure("failed to persist supervisor escalation for \(cell.id.uuidString)")
            return false
        }

        let delivered = writeEscalation(c.worktreePath, escalation)
        let deliveryFailures = delivered ? [] : [".mythos-fleet-rescue.md write failed"]

        guard var afterDelivery = board.currentBoard(),
              let deliveryCellIndex = afterDelivery.cells.firstIndex(where: { $0.id == cell.id }) else {
            recordBoardPersistenceFailure("missing board while persisting supervisor escalation delivery result for \(cell.id.uuidString)")
            return false
        }
        var deliveredCell = afterDelivery.cells[deliveryCellIndex]
        let finalRecord = SupervisorEscalationRecord(kind: escalation.kind.rawValue,
                                                     atEpoch: now,
                                                     summary: escalation.summary,
                                                     evidence: escalation.evidence,
                                                     assignment: escalation.assignment,
                                                     delivered: delivered,
                                                     deliveryFailures: deliveryFailures)
        if recordIndex < deliveredCell.supervisorEscalations.count {
            deliveredCell.supervisorEscalations[recordIndex] = finalRecord
        } else {
            deliveredCell.supervisorEscalations.append(finalRecord)
        }
        let deliveryText = delivered
            ? "rescue assignment delivered to .mythos-fleet-rescue.md"
            : "rescue assignment delivery FAILED: \(deliveryFailures.joined(separator: "; "))"
        deliveredCell.keyDecisions.append(Note(atEpoch: now,
                                               text: "SUPERVISOR ESCALATION — \(escalation.kind.rawValue): \(deliveryText)"))
        afterDelivery.cells[deliveryCellIndex] = deliveredCell
        afterDelivery.revision += 1
        if !board.seed(afterDelivery) {
            recordBoardPersistenceFailure("failed to persist supervisor escalation delivery result for \(cell.id.uuidString)")
            return false
        }
        return true
    }

    private func interventionCount(_ cell: AgentCell) -> Int {
        cell.supervisorInterventions.count
    }

    private func escalationCount(_ cell: AgentCell) -> Int {
        cell.supervisorEscalations.count
    }

    private func deliveredInterventionCount(_ cell: AgentCell) -> Int {
        cell.supervisorInterventions.filter(\.delivered).count
    }

    private func deliveredEscalationCount(_ cell: AgentCell) -> Int {
        cell.supervisorEscalations.filter(\.delivered).count
    }

    private func latestSupervisorInterventionEpoch(_ cell: AgentCell) -> Double {
        cell.supervisorInterventions.map(\.atEpoch).max() ?? 0
    }

    private func latestDeliveredSupervisorInterventionEpoch(_ cell: AgentCell) -> Double? {
        cell.supervisorInterventions.filter(\.delivered).map(\.atEpoch).max()
    }

    private static func normalizeProgressPath(_ path: String) -> String? {
        let rawParts = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
            .drop(while: { $0.isEmpty || $0 == "." })
        if rawParts.contains(".") || rawParts.contains("..") { return nil }
        let normalized = FleetScopeValidator.normalize(path)
        return normalized.isEmpty ? nil : normalized
    }

    // MARK: - Surrender → verify → sign → propagate

    private func handleSurrender(cell: AgentCell, baton: Baton, goalID: String) async {
        let now = nowEpoch()

        // held → submitted (persist immediately so a crash mid-verify leaves it honestly unverified).
        var baton = baton
        if baton.state == .held,
           let submitted = baton.advanced(to: .submitted, from: cell.id.uuidString, to: "captain", atEpoch: now) {
            baton = submitted
            batons.save(baton)
        }

        let report = await foreman.inspect(subject: cell.foremanSubject, goalID: goalID, nowEpoch: now)

        if let signoff = report.signoff, report.verdict == .green {
            guard foldSignedOff(cell: cell, signoff: signoff, report: report, atEpoch: now) else { return }

            let contribution = BatonContribution(
                subtaskTitle: cell.title, branch: cell.branch, commitSHA: headSHA(cell.worktreePath), summary: cell.title,
                scopeGlobs: cell.scopeGlobs, signoffSeq: signoff.ledgerSeq,
                evidence: report.evidence, signedAtEpoch: now)

            if let verified = baton.advanced(to: .verified, from: cell.id.uuidString, to: "captain", atEpoch: now) {
                let withProof = verified.appendingContribution(contribution)
                batons.save(withProof)
                if let passed = withProof.advanced(to: .passed, from: "captain", to: "captain", atEpoch: now) {
                    batons.save(passed)
                }
            }
            refreshAllSlices()
        } else {
            _ = rejectAgent(cell: cell, baton: baton, report: report, atEpoch: now)
        }
    }

    /// Fold a verified cell into the board: status .signedOff + the sealed Signoff + a verdict note. The
    /// ONLY path that sets `.signedOff` (the store refuses an agent-claimed one).
    private func foldSignedOff(cell: AgentCell, signoff: Signoff, report: ForemanReport, atEpoch: Double) -> Bool {
        guard var b = board.currentBoard(), let idx = b.cells.firstIndex(where: { $0.id == cell.id }) else {
            recordBoardPersistenceFailure("missing board while persisting signoff for \(cell.id.uuidString)")
            return false
        }
        var c = b.cells[idx]
        c.status = .signedOff
        c.signoff = signoff
        c.filesTouched = Array(Set(c.filesTouched)).sorted()
        c.keyDecisions.append(Note(atEpoch: atEpoch, text: "SIGNED OFF (seq \(signoff.ledgerSeq)) — \(report.evidence)"))
        c.lastHeartbeatEpoch = max(c.lastHeartbeatEpoch, atEpoch)
        b.cells[idx] = c
        b.revision += 1
        if !board.seed(b) {
            recordBoardPersistenceFailure("failed to persist signoff for \(cell.id.uuidString)")
            return false
        }
        return true
    }

    /// Record a rejection on the board + bounce the baton. Within budget → .rejected (re-held for retry);
    /// over budget → .failed (to human, with a recovery recommendation).
    @discardableResult
    private func rejectAgent(cell: AgentCell, baton: Baton, report: ForemanReport, atEpoch: Double) -> Bool {
        let nextRejects = baton.rejectCount + 1
        let blockerNote = report.failedBlockers.isEmpty
            ? report.evidence
            : "rejected — failed: \(report.failedBlockers.joined(separator: ", "))"
        let rejectedHead = headSHA(cell.worktreePath)
        let rejectedKey = rejectedHead.isEmpty ? nil : surrenderKey(cell, head: rejectedHead)

        guard var b = board.currentBoard(), let idx = b.cells.firstIndex(where: { $0.id == cell.id }) else {
            recordBoardPersistenceFailure("missing board while persisting rejection for \(cell.id.uuidString)")
            return false
        }
        var c = b.cells[idx]
        c.status = (nextRejects > maxRejects) ? .failed : .blocked
        c.blockers.append(Note(atEpoch: atEpoch, text: blockerNote))
        if !rejectedHead.isEmpty && !c.rejectedDoneHeadSHAs.contains(rejectedHead) {
            c.rejectedDoneHeadSHAs.append(rejectedHead)
        }
        if nextRejects > maxRejects {
            let rec = FleetRecoveryPlanner.decide(rejectCount: nextRejects, maxRejects: maxRejects,
                                                  timedOut: false, blockers: report.failedBlockers)
            c.keyDecisions.append(Note(atEpoch: atEpoch, text: "RECOVERY — \(rec.summary)"))
        }
        c.lastHeartbeatEpoch = max(c.lastHeartbeatEpoch, atEpoch)
        b.cells[idx] = c
        b.revision += 1
        if !board.seed(b) {
            recordBoardPersistenceFailure("failed to persist rejection for \(cell.id.uuidString)")
            return false
        }
        if let rejectedKey {
            rejectedSurrenders.insert(rejectedKey)
        }

        if !archiveRejectedDone(cell.worktreePath, atEpoch) {
            let headDescription = rejectedHead.isEmpty ? "unknown commit" : rejectedHead
            let consequence = rejectedHead.isEmpty
                ? "commit could not be identified; the marker may be inspected again after restart."
                : "same commit will not be re-inspected after restart."
            guard var archivedBoard = board.currentBoard(),
                  let archiveIdx = archivedBoard.cells.firstIndex(where: { $0.id == cell.id }) else {
                recordBoardPersistenceFailure("missing board while persisting rejected done-marker archive failure for \(cell.id.uuidString)")
                return false
            }
            archivedBoard.cells[archiveIdx].blockers.append(Note(atEpoch: atEpoch,
                text: "SUPERVISOR REJECTION CONSUME FAILED — rejected .fleet-done for \(headDescription) could not be archived; \(consequence)"))
            archivedBoard.revision += 1
            if !board.seed(archivedBoard) {
                recordBoardPersistenceFailure("failed to persist rejected done-marker archive failure for \(cell.id.uuidString)")
                return false
            }
        }

        var current = baton
        current.rejectCount = nextRejects
        if let rejected = current.advanced(to: .rejected, from: cell.id.uuidString, to: "captain", atEpoch: atEpoch) {
            current = rejected
            batons.save(current)
            let nextState: BatonState = (nextRejects > maxRejects) ? .failed : .held
            if let advanced = current.advanced(to: nextState, from: "captain",
                                               to: nextState == .held ? cell.id.uuidString : "human", atEpoch: atEpoch) {
                batons.save(advanced)
            }
        }
        return true
    }

    // MARK: - Timeout

    /// A stuck agent: deadline elapsed in `.held` with no `.fleet-done`. Mark the cell `.failed`, time out
    /// the baton, record the partial honestly — NEVER merge.
    private func handleTimeout(cell: AgentCell, baton: Baton) {
        let now = nowEpoch()
        guard var b = board.currentBoard(), let idx = b.cells.firstIndex(where: { $0.id == cell.id }) else {
            recordBoardPersistenceFailure("missing board while persisting timeout for \(cell.id.uuidString)")
            return
        }
        var c = b.cells[idx]
        c.status = .failed
        c.blockers.append(Note(atEpoch: now,
            text: "TIMED OUT — deadline elapsed in .held with no .fleet-done; partial work left on \(c.branch), not merged"))
        let priorBlockers = c.blockers.map(\.text).filter { !$0.hasPrefix("TIMED OUT") }
        let rec = FleetRecoveryPlanner.decide(rejectCount: baton.rejectCount, maxRejects: maxRejects,
                                              timedOut: true, blockers: priorBlockers)
        c.keyDecisions.append(Note(atEpoch: now, text: "RECOVERY — \(rec.summary)"))
        b.cells[idx] = c
        b.revision += 1
        if !board.seed(b) {
            recordBoardPersistenceFailure("failed to persist timeout for \(cell.id.uuidString)")
            return
        }
        if let timedOut = baton.advanced(to: .timedOut, from: cell.id.uuidString, to: "captain", atEpoch: now) {
            batons.save(timedOut)
            if let failed = timedOut.advanced(to: .failed, from: "captain", to: "human", atEpoch: now) {
                batons.save(failed)
            }
        }
    }

    // MARK: - Digest propagation

    /// Rewrite every LIVE agent's slice from the freshly-folded board, so a downstream agent re-reads
    /// proven peer context before its next step. Only non-terminal agents get a fresh slice.
    private func refreshAllSlices() {
        guard let b = board.currentBoard() else { return }
        for cell in b.cells where !Self.isTerminal(cell.status) {
            _ = writeSlice(cell.worktreePath, board.digest(forAgent: cell.id))
        }
    }

    // MARK: - Honest summary

    /// Tally the fleet's MEASURED outcome from the SEALED ledger + the board. A signed count comes ONLY
    /// from `ledger.signedOff` (a claimed-done string never counts).
    private func summarize(goalID: String, sweptOut: Bool) -> FleetSupervisionResult {
        let cells = board.currentBoard()?.cells ?? []
        let total = cells.count
        let signed = cells.filter { ledger.signedOff(goalID: goalID, agentID: $0.id) }.count
        func isTimedOut(_ cell: AgentCell) -> Bool {
            cell.status == .failed && cell.blockers.contains { $0.text.hasPrefix("TIMED OUT") }
        }
        let timedOut = cells.filter(isTimedOut).count
        let rejected = cells.filter { $0.status == .failed && !isTimedOut($0) }.count
        let stillRunning = cells.filter { !Self.isTerminal($0.status) }.count
        let interventions = cells.reduce(0) { $0 + deliveredInterventionCount($1) }
        let escalations = cells.reduce(0) { $0 + deliveredEscalationCount($1) }
        let persistenceFailures = boardPersistenceFailures.count + inboxPersistenceFailures.count

        var summary = "Fleet: signed \(signed)/\(total) agent(s)"
        if timedOut > 0 { summary += "; \(timedOut) timed out" }
        if rejected > 0 { summary += "; \(rejected) failed verification" }
        if stillRunning > 0 {
            summary += sweptOut ? "; \(stillRunning) still running (sweep cap hit)"
                                : "; \(stillRunning) still running"
        }
        if interventions > 0 { summary += "; \(interventions) supervisor intervention(s)" }
        if escalations > 0 { summary += "; \(escalations) rescue escalation(s)" }
        if !boardPersistenceFailures.isEmpty {
            summary += "; \(boardPersistenceFailures.count) board persistence failure(s)"
        }
        if !inboxPersistenceFailures.isEmpty {
            summary += "; \(inboxPersistenceFailures.count) inbox persistence failure(s)"
        }
        summary += signed == total && total > 0
            ? (persistenceFailures == 0
                ? " — all verified. Merge joins onto a fresh integration branch (nothing touched main)."
                : " — PARTIAL. Proof exists, but blackboard persistence failed; nothing should auto-merge.")
            : " — PARTIAL. Only the signed subset is mergeable; nothing touched main."
        if sweptOut { summary += " [poll bound reached]" }

        return FleetSupervisionResult(total: total, signed: signed, rejected: rejected,
                                      timedOut: timedOut, stillRunning: stillRunning,
                                      interventions: interventions,
                                      escalations: escalations,
                                      persistenceFailures: persistenceFailures,
                                      summary: summary)
    }

    // MARK: - The merge gate: join the signed branches

    /// Merge ONLY the valid, sealed-signed, IN-LEASE branches (one per agent, in signoff order) onto a
    /// FRESH integration branch off `base`. Reads `ledger.entries` (chain-intact + seal-valid; a tampered
    /// chain collapses it to empty → nothing merges). A signed entry whose sealed `outOfScopeCount > 0`
    /// (committed outside its lease) is REFUSED — the signoff still STANDS, but the out-of-lease branch is
    /// not auto-joined; a human reviews it. NEVER touches main (guarded in GitIsolation). Refusals are
    /// surfaced on the board, never silent.
    public func joinSignedBranches(goalID: String, base: String) -> GitIsolation.MergeResult {
        guard let b = board.currentBoard() else {
            if let loadError = board.lastLoadError() {
                return .failed(reason: "no board to merge; blackboard load error: \(loadError)")
            }
            return .failed(reason: "no board to merge")
        }
        if hasPersistenceFailures {
            return .failed(reason: "blackboard/inbox persistence failure recorded; refusing merge")
        }
        if let error = board.lastSaveError() {
            return .failed(reason: "blackboard persistence error recorded; refusing merge: \(error)")
        }
        var seenAgents = Set<UUID>()
        var refused: [(branch: String, oos: Int)] = []
        var boardRefused: [String] = []
        let signedBranches = ledger.entries
            .filter { $0.goalID == goalID }
            .sorted { $0.seq < $1.seq }
            .compactMap { entry -> String? in
                guard seenAgents.insert(entry.agentID).inserted else { return nil }   // one per agent
                guard let cell = b.cells.first(where: { $0.id == entry.agentID }),
                      cell.status == .signedOff,
                      cell.signoff != nil else {
                    boardRefused.append(entry.branch)
                    return nil
                }
                guard entry.outOfScopeCount == 0 else {
                    refused.append((entry.branch, entry.outOfScopeCount))
                    return nil
                }
                return entry.branch
            }
        if !boardRefused.isEmpty {
            let branches = boardRefused.joined(separator: ", ")
            return .failed(reason: "blackboard-refused signed branch(es): \(branches); durable board signoff missing")
        }
        if !refused.isEmpty {
            recordLeaseRefusals(refused)
            let branches = refused.map(\.branch).joined(separator: ", ")
            return .failed(reason: "lease-refused signed branch(es): \(branches); no subset merge performed")
        }
        guard !signedBranches.isEmpty else { return .nothingToMerge }
        return merge(b.repo, base, signedBranches, b.integrationBranch, nowEpoch())
    }

    /// Surface lease refusals on the board (append-only) so a human sees which verified branches were held
    /// back from the auto-join, and why. Never silent.
    private func recordLeaseRefusals(_ refused: [(branch: String, oos: Int)]) {
        guard var b = board.currentBoard() else { return }
        let now = nowEpoch()
        for (branch, oos) in refused {
            if let idx = b.cells.firstIndex(where: { $0.branch == branch }) {
                b.cells[idx].keyDecisions.append(Note(atEpoch: now,
                    text: "LEASE REFUSED at merge — \(oos) file(s) committed OUTSIDE the declared scope; "
                        + "branch \(branch) is verified-green but NOT auto-joined. Human review required."))
            }
        }
        b.revision += 1
        if !board.seed(b) {
            recordBoardPersistenceFailure("failed to persist merge lease refusal")
        }
    }

    // MARK: - Pure helper

    private func recordBoardPersistenceFailure(_ context: String) {
        let error = board.lastSaveError() ?? board.lastLoadError() ?? "unknown blackboard persistence error"
        boardPersistenceFailures.append("\(context): \(error)")
    }

    private func recordInboxPersistenceFailure(_ context: String) {
        inboxPersistenceFailures.append(context)
    }

    private var hasPersistenceFailures: Bool {
        !boardPersistenceFailures.isEmpty || !inboxPersistenceFailures.isEmpty
    }

    private func alreadyRejectedCurrentSurrender(_ cell: AgentCell) -> Bool {
        let head = headSHA(cell.worktreePath)
        guard !head.isEmpty else { return false }
        return rejectedSurrenders.contains(surrenderKey(cell, head: head))
            || cell.rejectedDoneHeadSHAs.contains(head)
    }

    private func surrenderKey(_ cell: AgentCell, head: String? = nil) -> String {
        "\(cell.id.uuidString):\(head ?? headSHA(cell.worktreePath))"
    }

    private static func readHeadSHA(worktreePath: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", worktreePath, "rev-parse", "HEAD"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return "" }
            return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    /// A cell is terminal when it can take no further part: signed off, or failed.
    public static func isTerminal(_ status: AgentCell.CellStatus) -> Bool {
        status == .signedOff || status == .failed
    }
}
