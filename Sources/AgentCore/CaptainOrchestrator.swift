import Foundation

/// THE LAUNCHER — takes a goal + a set of proposed subtasks → validates them into DISJOINT leases →
/// prepares one worktree+branch PER subtask (isolated by construction) → seeds the blackboard → spawns
/// workers only after that durable substrate exists + mints one baton per launched agent. It does NOT supervise or merge: handing the launched fleet
/// to a `FleetSupervisor` is a SEPARATE, explicit step (the arming step — never auto-fired). The
/// decomposition (goal → subtasks) is UPSTREAM: the caller's planner proposes; this validates + isolates.
///
/// SPAWN-AGNOSTIC: the worker runs via an injected `AgentSpawner` — in Mythos that's the IN-PROCESS
/// cross-vendor `PlanExecuteLoop` (planner/coder/critic = different vendors), the upgrade over Claude-only
/// `cu` subprocesses. The orchestrator never assumes HOW a worker runs.
///
/// SAFETY: each agent is confined to its worktree (can't touch another's files); fleet size is HARD-capped
/// (`maxAgents` — never a runaway swarm); every brief says "commit on your branch; do NOT merge to main";
/// the worktree + dir-tree + spawn are injectable seams so the logic is unit-tested with NO real git/spawn.
///
/// Ported from TinkySDR's Captain (Stage 2). Adaptations: ModelRouter/AgentPlanner decomposition lifted
/// UPSTREAM (caller passes `subtasks`); AgentEffort→`maxAgents: Int`; the `cu`/OSAScript spawn→`AgentSpawner`;
/// FleetLessonStore (Phase C) + FleetIntegrationVerifier (Phase B) deferred to Stage 3; supervision is a
/// separate call. LABEL: PROTOTYPE.

/// One proposed unit of fleet work (the planner's output, pre-validation).
public struct FleetSubtask: Sendable, Equatable {
    public let title: String
    public let intent: String
    public let scopeGlobs: [String]           // PROPOSED lease (validated into a disjoint one)
    public let acceptanceCriterion: String
    public init(title: String, intent: String, scopeGlobs: [String] = [], acceptanceCriterion: String = "") {
        self.title = title; self.intent = intent; self.scopeGlobs = scopeGlobs
        self.acceptanceCriterion = acceptanceCriterion
    }
}

/// One spawned fleet member (the launch outcome — `launched` is the SPAWN success, not the work verdict).
public struct LaunchedAgent: Sendable, Equatable {
    public let agentID: UUID
    public let title: String
    public let branch: String
    public let worktreePath: String
    public let scopeGlobs: [String]           // the VALIDATED lease the foreman enforces
    public let launched: Bool
    public let assignment: ModelAssignmentDecision?
    public init(agentID: UUID, title: String, branch: String, worktreePath: String,
                scopeGlobs: [String], launched: Bool, assignment: ModelAssignmentDecision? = nil) {
        self.agentID = agentID; self.title = title; self.branch = branch
        self.worktreePath = worktreePath; self.scopeGlobs = scopeGlobs; self.launched = launched
        self.assignment = assignment
    }
}

/// The result of a launch — enough for the caller to (a) report, and (b) re-open the substrate (by
/// `fleetID`/`fleetDir`) and hand it to a `FleetSupervisor`.
public struct FleetLaunch: Sendable {
    public let fleetID: UUID
    public let fleetDir: URL                  // where the per-fleet board/baton/ledger live
    public let agents: [LaunchedAgent]
    public let board: FleetBlackboard
    public let scopeIssues: [String]          // validator notes (dropped hallucinated/overlapping globs)
    public let assignments: [ModelAssignmentDecision]
    public let summary: String
    /// True only when every launched worker has enough durable substrate for the caller to arm supervision.
    /// A launch can have `launchedCount > 0` but still be unsafe if a required board/baton write failed.
    public let supervisionReady: Bool
    public var launchedCount: Int { agents.filter(\.launched).count }
}

protocol FleetBlackboardPersisting: Sendable {
    @discardableResult
    func seed(_ initial: FleetBlackboard) -> Bool
    func lastSaveError() -> String?
}

extension FleetBlackboardStore: FleetBlackboardPersisting {}

public final class CaptainOrchestrator: @unchecked Sendable {

    private let spawner: AgentSpawner
    private let makeWorktree: (_ repo: String, _ label: String) -> GitWorktree?
    private let dirTree: (_ repo: String) -> (snapshot: String, knownDirs: Set<String>)
    private let makeBlackboardStore: @Sendable (_ fleetID: UUID, _ baseDir: URL) -> any FleetBlackboardPersisting

    public convenience init(spawner: AgentSpawner,
                            makeWorktree: ((String, String) -> GitWorktree?)? = nil,
                            dirTree: ((String) -> (snapshot: String, knownDirs: Set<String>))? = nil) {
        self.init(spawner: spawner,
                  makeWorktree: makeWorktree,
                  dirTree: dirTree,
                  makeBlackboardStore: { FleetBlackboardStore(fleetID: $0, baseDir: $1) })
    }

    init(spawner: AgentSpawner,
         makeWorktree: ((String, String) -> GitWorktree?)? = nil,
         dirTree: ((String) -> (snapshot: String, knownDirs: Set<String>))? = nil,
         makeBlackboardStore: @escaping @Sendable (_ fleetID: UUID, _ baseDir: URL) -> any FleetBlackboardPersisting) {
        self.spawner = spawner
        self.makeWorktree = makeWorktree ?? { repo, label in
            GitIsolation.makeWorktree(repo: repo, label: label, nowEpoch: Date().timeIntervalSince1970)
        }
        self.dirTree = dirTree ?? { repo in
            CaptainOrchestrator.deriveScopeContext(fromFiles: GitIsolation.trackedFiles(repo: repo))
        }
        self.makeBlackboardStore = makeBlackboardStore
    }

    /// Validate the proposed subtasks into disjoint leases, isolate worktrees, seed the board, then spawn
    /// workers + mint batons.
    /// Returns the launch (does NOT supervise — that's the caller's explicit arming step).
    @discardableResult
    public func launchFleet(goal: String, repo: String, subtasks: [FleetSubtask],
                            maxAgents: Int = 5, baseDir: URL, nowEpoch: Double) async -> FleetLaunch {
        let legacyRoles = RoleBindings(default: ProviderBinding(providerId: "default"))
        let assigned = subtasks.map { subtask in
            AssignedFleetTask(subtask: subtask, roles: legacyRoles,
                              assignment: .legacy(taskTitle: subtask.title, roles: legacyRoles))
        }
        return await launchFleet(goal: goal, repo: repo, assignedTasks: assigned,
                                 maxAgents: maxAgents, baseDir: baseDir, nowEpoch: nowEpoch)
    }

    /// Validate assigned subtasks into disjoint leases, isolate worktrees, seed the board, then spawn each
    /// worker with its assigned model team + mint batons. Returns the launch (does NOT supervise).
    @discardableResult
    public func launchFleet(goal: String, repo: String, assignedTasks: [AssignedFleetTask],
                            maxAgents: Int = 5, baseDir: URL, nowEpoch: Double) async -> FleetLaunch {
        let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let fleetID = UUID()
        let fleetDir = baseDir.appendingPathComponent(fleetID.uuidString, isDirectory: true)
        // UNIQUE per-fleet integration branch (Codex HIGH): a hard-coded "integration" collides with a
        // stale branch of that name → mergeIntoIntegration returns .alreadyIntegrated and the fresh
        // fleet's signed branches never join while the CLI reports "integrated". A fleetID-scoped name
        // can never pre-exist, so each fleet always gets its own real integration branch.
        let integrationBranch = "mythos/integration-" + fleetID.uuidString.prefix(8)

        func empty(_ why: String) -> FleetLaunch {
            FleetLaunch(fleetID: fleetID, fleetDir: fleetDir, agents: [],
                        board: FleetBlackboard(id: fleetID, goal: goal, plan: [], integrationBranch: integrationBranch,
                                               repo: trimmedRepo, startedAt: Date(timeIntervalSince1970: nowEpoch)),
                        scopeIssues: [], assignments: assignedTasks.map(\.assignment), summary: why,
                        supervisionReady: false)
        }

        func blocked(_ issues: [String], _ why: String) -> FleetLaunch {
            FleetLaunch(fleetID: fleetID, fleetDir: fleetDir, agents: [],
                        board: FleetBlackboard(id: fleetID, goal: goal, plan: [], integrationBranch: integrationBranch,
                                               repo: trimmedRepo, startedAt: Date(timeIntervalSince1970: nowEpoch)),
                        scopeIssues: issues, assignments: assignedTasks.map(\.assignment), summary: why,
                        supervisionReady: false)
        }

        guard GitIsolation.isGitRepo(trimmedRepo) else {
            return empty("\"\(trimmedRepo)\" isn't a git repo — a fleet needs one for isolated branches. Nothing launched.")
        }
        let chosen = Self.chooseAssignedTasks(assignedTasks, maxAgents: maxAgents)
        guard !chosen.isEmpty else { return empty("No subtasks to launch.") }

        // Validate proposed scopes into a TRUSTWORTHY, DISJOINT lease per step (hallucinated globs dropped;
        // overlapping pairs cleared to [] by the validator). The planner is ASKED, never trusted.
        let (_, knownDirs) = dirTree(trimmedRepo)
        let validation = FleetScopeValidator.validate(scopesPerStep: chosen.map { $0.subtask.scopeGlobs },
                                                      knownDirs: knownDirs)
        let leases = validation.scopesPerStep
        // C10: single-agent lease enforcement is handled by Foreman GATE 3 at SIGNOFF (an agent that
        // commits outside its declared lease is refused) using the VALIDATED/cleaned lease below — so a
        // launch-time hard-block for single agents is unnecessary and harmful (it would refuse a lone
        // agent for one dropped hallucinated glob with no replan path). The multi-agent launch block
        // stays: a fleet needs a non-empty, disjoint lease per agent AND a clean validation before it
        // spins up worktrees.
        if chosen.count > 1 {
            let emptyLeaseSteps = leases.enumerated().filter { $0.element.isEmpty }.map { $0.offset }
            if !validation.clean || !emptyLeaseSteps.isEmpty {
                var issues = validation.issues
                if !emptyLeaseSteps.isEmpty {
                    issues.append("multi-agent fleet requires a non-empty, disjoint lease for every agent; empty lease step(s): \(emptyLeaseSteps.map(String.init).joined(separator: ", "))")
                }
                return blocked(issues, "Scope repair required before launch — no agents started. Replan with real, non-overlapping file leases.")
            }
        }

        let agentIDs = chosen.map { _ in UUID() }
        let manifest: [PlanStepRef] = zip(zip(chosen, agentIDs), leases).map { pair, lease in
            let (assigned, aid) = pair
            return PlanStepRef(title: assigned.subtask.title, intent: assigned.subtask.intent,
                               scope: lease.isEmpty ? nil : lease.joined(separator: ", "), assignedAgentID: aid)
        }

        struct PreparedAgent: Sendable {
            let assigned: AssignedFleetTask
            let agentID: UUID
            let lease: [String]
            let worktree: GitWorktree
        }

        struct SpawnResult: Sendable {
            let preparedIndex: Int
            let agentID: UUID
            let launched: Bool
        }

        var agents: [LaunchedAgent] = []
        var cells: [AgentCell] = []
        var prepared: [PreparedAgent] = []
        for (seq, assigned) in chosen.enumerated() {
            let sub = assigned.subtask
            let agentID = agentIDs[seq]
            let lease = leases[seq]
            guard let wt = makeWorktree(trimmedRepo, sub.title) else {
                agents.append(LaunchedAgent(agentID: agentID, title: sub.title, branch: "(worktree failed)",
                                            worktreePath: "", scopeGlobs: lease, launched: false,
                                            assignment: assigned.assignment))
                continue
            }
            prepared.append(PreparedAgent(assigned: assigned, agentID: agentID, lease: lease, worktree: wt))
            agents.append(LaunchedAgent(agentID: agentID, title: sub.title, branch: wt.branch,
                                        worktreePath: wt.path, scopeGlobs: lease, launched: false,
                                        assignment: assigned.assignment))
            cells.append(AgentCell(id: agentID, title: sub.title, branch: wt.branch, worktreePath: wt.path,
                                   baseSHA: wt.base, scopeGlobs: lease, acceptanceCriterion: sub.acceptanceCriterion,
                                   status: .pending))
        }

        var board = FleetBlackboard(id: fleetID, goal: goal, plan: manifest, integrationBranch: integrationBranch,
                                    repo: trimmedRepo, startedAt: Date(timeIntervalSince1970: nowEpoch),
                                    cells: cells, revision: 0)

        // Seed the per-fleet substrate BEFORE any worker starts. If this fails, no agent is spawned; a
        // live worker without a durable board cannot be supervised or resumed honestly.
        let boardStore = makeBlackboardStore(fleetID, baseDir)
        guard boardStore.seed(board) else {
            let reason = boardStore.lastSaveError() ?? "unknown blackboard persistence error"
            let cleanupIssues = prepared.compactMap { item -> String? in
                GitIsolation.discard(item.worktree) ? nil : "worktree cleanup failed for \(item.worktree.path)"
            }
            return FleetLaunch(fleetID: fleetID, fleetDir: fleetDir, agents: agents, board: board,
                               scopeIssues: validation.issues + ["blackboard seed failed: \(reason)"] + cleanupIssues,
                               assignments: chosen.map(\.assignment),
                               summary: "Fleet substrate failed to persist before spawn — no agents started. \(reason)",
                               supervisionReady: false)
        }

        let batonStore = FleetBatonStore(baseDir: fleetDir)
        var launchIssues: [String] = []
        var heldBatons: [UUID: Baton] = [:]
        let spawnDriver = spawner
        var spawnResults: [SpawnResult] = []
        await withTaskGroup(of: SpawnResult.self) { group in
            // `chosen` is already hard-capped by maxAgents, so this group cannot exceed the
            // caller's fleet bound. Arming stays ordered; only spawn calls overlap.
            for (preparedIndex, item) in prepared.enumerated() {
                let sub = item.assigned.subtask
                let cellIndex = board.cells.firstIndex(where: { $0.id == item.agentID })
                guard let cellIndex else { continue }
                var workingBoard = board
                workingBoard.cells[cellIndex].status = .working
                workingBoard.revision += 1
                guard boardStore.seed(workingBoard) else {
                    let reason = boardStore.lastSaveError() ?? "unknown blackboard persistence error"
                    launchIssues.append("launch status persistence failed for \(item.agentID.uuidString): \(reason)")
                    var failedBoard = board
                    Self.markLaunchesFailed(
                        &failedBoard, agentIDs: prepared[preparedIndex...].map(\.agentID))
                    failedBoard.revision += 1
                    board = failedBoard
                    if !boardStore.seed(failedBoard) {
                        let failedReason = boardStore.lastSaveError()
                            ?? "unknown blackboard persistence error"
                        launchIssues.append(
                            "failed to persist launch-abort statuses after status persistence failure: \(failedReason)")
                    }
                    break
                }
                board = workingBoard

                let heldBaton = Baton(
                    fleetID: fleetID, missionGoal: goal, repo: trimmedRepo,
                    holder: item.agentID.uuidString, currentWorktree: item.worktree.path,
                    currentBranch: item.worktree.branch, scopeGlobs: item.lease, state: .held,
                    lineage: [BatonHop(
                        from: "captain", to: item.agentID.uuidString,
                        atEpoch: nowEpoch, state: .held)])
                guard batonStore.save(heldBaton) else {
                    let reason = batonStore.lastSaveError() ?? "unknown baton persistence error"
                    launchIssues.append("baton persistence failed for \(item.agentID.uuidString): \(reason)")
                    var failedBoard = board
                    failedBoard.cells[cellIndex].status = .failed
                    failedBoard.revision += 1
                    board = failedBoard
                    if !boardStore.seed(failedBoard) {
                        let boardReason = boardStore.lastSaveError()
                            ?? "unknown blackboard persistence error"
                        launchIssues.append(
                            "failed to persist baton-failure status for \(item.agentID.uuidString): \(boardReason)")
                        break
                    }
                    continue
                }
                heldBatons[item.agentID] = heldBaton

                let brief = Self.batonBrief(
                    subtask: sub, goal: goal, agentID: item.agentID, manifest: manifest,
                    fleetID: fleetID, worktreePath: item.worktree.path,
                    scopeGlobs: item.lease, assignment: item.assigned.assignment)
                group.addTask {
                    let ok: Bool
                    if let assignedSpawner = spawnDriver as? any AssignedAgentSpawner {
                        ok = await assignedSpawner.spawn(
                            task: brief, worktree: item.worktree,
                            assignment: item.assigned.assignment)
                    } else {
                        ok = await spawnDriver.spawn(task: brief, worktree: item.worktree)
                    }
                    return SpawnResult(
                        preparedIndex: preparedIndex, agentID: item.agentID, launched: ok)
                }
            }
            for await result in group { spawnResults.append(result) }
        }

        // Completion order is nondeterministic; all durable/public state transitions are not.
        for result in spawnResults.sorted(by: { $0.preparedIndex < $1.preparedIndex }) {
            let item = prepared[result.preparedIndex]
            let sub = item.assigned.subtask
            if let idx = agents.firstIndex(where: { $0.agentID == result.agentID }) {
                agents[idx] = LaunchedAgent(
                    agentID: item.agentID, title: sub.title,
                    branch: item.worktree.branch, worktreePath: item.worktree.path,
                    scopeGlobs: item.lease, launched: result.launched,
                    assignment: item.assigned.assignment)
            }
            guard !result.launched,
                  let cellIndex = board.cells.firstIndex(where: { $0.id == item.agentID }) else {
                continue
            }
            var failedBoard = board
            failedBoard.cells[cellIndex].status = .failed
            failedBoard.revision += 1
            board = failedBoard
            if !boardStore.seed(failedBoard) {
                let reason = boardStore.lastSaveError() ?? "unknown blackboard persistence error"
                launchIssues.append(
                    "failed to persist spawn-failure status for \(item.agentID.uuidString): \(reason)")
            }
            if let heldBaton = heldBatons[item.agentID],
               let timedOut = heldBaton.advanced(
                    to: .timedOut, from: item.agentID.uuidString,
                    to: "captain", atEpoch: nowEpoch),
               let failed = timedOut.advanced(
                    to: .failed, from: "captain",
                    to: item.agentID.uuidString, atEpoch: nowEpoch) {
                _ = batonStore.save(failed)
            }
        }

        let okCount = agents.filter(\.launched).count
        let incompleteLaunches = agents.filter { !$0.launched }.map {
            "agent not running \($0.title) (\($0.branch))"
        }
        let readinessIssues = launchIssues + incompleteLaunches
        let ready = okCount > 0 && readinessIssues.isEmpty
        let issueSummary = readinessIssues.isEmpty ? "" : " Launch issue(s): \(readinessIssues.joined(separator: "; "))"
        let summary = "Launched \(okCount)/\(agents.count) agent(s) on isolated branches — each launched worker "
            + "has a durable board cell and held baton before work starts. Nothing touches main." + issueSummary
        return FleetLaunch(fleetID: fleetID, fleetDir: fleetDir, agents: agents, board: board,
                           scopeIssues: validation.issues + readinessIssues, assignments: chosen.map(\.assignment),
                           summary: summary, supervisionReady: ready)
    }

    private static func markLaunchesFailed(_ board: inout FleetBlackboard, agentIDs: [UUID]) {
        let failedIDs = Set(agentIDs)
        for cellIndex in board.cells.indices where failedIDs.contains(board.cells[cellIndex].id) {
            board.cells[cellIndex].status = .failed
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Fleet size = min(available subtasks, the cap), floored at 1. Never a runaway swarm.
    public static func chooseSubtasks(_ subtasks: [FleetSubtask], maxAgents: Int) -> [FleetSubtask] {
        let cap = max(1, maxAgents)
        return Array(subtasks.prefix(min(subtasks.count, cap)))
    }

    public static func chooseAssignedTasks(_ tasks: [AssignedFleetTask], maxAgents: Int) -> [AssignedFleetTask] {
        let cap = max(1, maxAgents)
        return Array(tasks.prefix(min(tasks.count, cap)))
    }

    /// The subtask + a HARD scope/no-merge contract so agents stay disjoint and never merge to main.
    public static func fleetTask(subtask: FleetSubtask, goal: String, scopeGlobs: [String] = []) -> String {
        let scope = scopeGlobs.isEmpty ? "" : "Stay within your file scope: \(scopeGlobs.joined(separator: ", ")). "
        return """
        \(subtask.intent)

        (Part of the larger goal: \(goal).) \(scope)Work ONLY on this subtask in THIS worktree. Commit your \
        changes on this branch when done. Do NOT merge, do NOT push to main, do NOT touch files outside your \
        subtask — other agents are working in parallel on their own branches.
        """
    }

    /// The RICH brief: the subtask contract + the crew (no-touch set) + the acceptance criterion + the
    /// DONE PROTOCOL the supervisor's foreman depends on (commit + .fleet-claims.json; the runtime wrapper
    /// drops .fleet-done only after the worker exits). The done protocol is load-bearing — a claim alone is
    /// ignored; only a green ./test.sh over a committed, claim-reconciled diff signs off.
    public static func batonBrief(subtask: FleetSubtask, goal: String, agentID: UUID,
                                  manifest: [PlanStepRef], fleetID: UUID,
                                  worktreePath: String, scopeGlobs: [String] = [],
                                  assignment: ModelAssignmentDecision? = nil) -> String {
        let base = fleetTask(subtask: subtask, goal: goal, scopeGlobs: scopeGlobs)
        let crew = manifest.filter { $0.assignedAgentID != agentID }
            .map { "- \($0.title) owns \($0.scope ?? "(its module)") — do NOT touch it" }
            .joined(separator: "\n")
        let crewBlock = crew.isEmpty ? "" : "\nYOUR CREW (work in parallel — stay off their files):\n\(crew)\n"
        let assignmentBlock = assignment.map { "\nMODEL ASSIGNMENT: \($0.summary)\n" } ?? ""
        let crit = subtask.acceptanceCriterion.trimmingCharacters(in: .whitespacesAndNewlines)
        let acceptanceBlock = crit.isEmpty ? "" : """

        ACCEPTANCE CRITERION (your definition of done): \(crit)
        You MUST add a TEST that proves this criterion (a new `func test…`) AND it must pass. A signoff with
        no added test for the criterion is REJECTED — define-then-prove. Do NOT delete tests, add skips,
        disable assertions, or edit test.sh to make the suite easier; the captain treats that as tampering.
        """
        return """
        \(base)
        \(crewBlock)\(assignmentBlock)\(acceptanceBlock)
        SHARED CONTEXT: a fresh slice of what your crew has PROVEN done (only signed-off work) is kept at
        \(worktreePath)/.mythos-fleet-slice.md between steps.

        PROGRESS PROTOCOL (so the captain can SEE you working): append one JSON object per line to
        \(worktreePath)/.fleet-progress.jsonl, e.g.
        {"step":1,"action":"edit","file":"Core/Foo.swift","at":<unix-seconds>,"note":"adding X"}
        action ∈ read|edit|run|note|done. ADVISORY (never counts as done) — but go silent and you're flagged STALE.

        DONE PROTOCOL (required — the foreman verifies this; a claim alone is ignored):
        1. Commit your changes on THIS branch (an uncommitted "done" is not done).
        2. Write \(worktreePath)/.fleet-claims.json declaring what you ACTUALLY did:
        {"files":["Core/Foo.swift"],"symbols":["funcOrTypeYouAdded"],"testsPass":true,"actions":["…"]}
        The captain reconciles these against the REAL committed diff + test result; a claim it can't find
        (a file you didn't touch, a symbol not in the diff, "testsPass":true when they failed) is a
        HALLUCINATION and REJECTS the signoff. Under-claiming is safe; lying is blocked.
        3. Stop after the commit + claims file are in place. Do NOT write \(worktreePath)/.fleet-done yourself;
        the Mythos runtime wrapper writes that sentinel after your worker exits, so the captain never verifies
        a half-finished in-process run. The captain then runs ./test.sh in your worktree and, ONLY on a green
        run with claims that match reality, signs off.
        """
    }

    /// Derive the lease vocabulary from a repo's tracked files: a bounded, sorted dir-tree SNAPSHOT for the
    /// planner to choose scopes from, and the FULL set of real directory prefixes (+ root "") the validator
    /// checks proposals against. Pure + deterministic. maxDepth 4 (real repos nest sources under a root).
    public static func deriveScopeContext(fromFiles files: [String], maxDepth: Int = 4, maxLines: Int = 200)
        -> (snapshot: String, knownDirs: Set<String>) {
        var knownDirs: Set<String> = [""]
        var snapshotDirs = Set<String>()
        for file in files {
            let comps = file.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard comps.count > 1 else { continue }
            for i in 1..<comps.count {
                let dir = comps[0..<i].joined(separator: "/")
                knownDirs.insert(dir)
                if i <= maxDepth { snapshotDirs.insert(dir) }
            }
        }
        let sorted = snapshotDirs.sorted()
        var lines = Array(sorted.prefix(maxLines))
        if sorted.count > maxLines {
            lines.append("… (\(sorted.count - maxLines) more directories omitted — scope to a listed parent dir)")
        }
        return (lines.joined(separator: "\n"), knownDirs)
    }
}
