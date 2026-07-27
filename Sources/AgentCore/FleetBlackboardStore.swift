import Foundation

/// The SOLE WRITER of one fleet's blackboard. Persists an atomic JSON file under
/// `<baseDir>/<fleetID>/blackboard.json`. Agents NEVER write here — they drop `CellUpdate`s (via the
/// inbox) the captain drains and FOLDS. Persistence is ATOMIC-on-save (not debounced): a fleet write is
/// an infrequent, load-bearing event we never lose; a dropped write surfaces via `lastSaveError()`,
/// never silently swallowed (the board is the resume backbone).
///
/// `digest(forAgent:)` is the read-only injection seam — a CHAR-CAPPED shared-context block describing
/// what the OTHER agents own + have proven, for inlining into an agent brief so no agent is blind to its
/// crew. Hard-clamped so the manifest + N peer summaries can never blow the context window.
///
/// Ported from TinkySDR's Captain (Stage 2). De-coupled from SwiftUI: was `@MainActor ObservableObject`
/// with `@Published`; now a plain class serialized by an internal `NSLock` (the captain is the sole
/// writer; the lock makes that safe across actors). `@unchecked Sendable` justified BY the lock.
/// LABEL: PROTOTYPE.
public final class FleetBlackboardStore: @unchecked Sendable {

    private let lock = NSLock()
    private var _board: FleetBlackboard?
    private var _lastSaveError: String?
    private var _lastLoadError: String?
    private let fileURL: URL

    /// Hard cap on the injected digest (~1.5 KB ≈ a few hundred tokens — one line per signed sibling).
    public static let digestMaxChars = 1500
    private static let maxNotesPerCell = 200
    private static let maxSupervisorRecordsPerCell = 50

    /// `baseDir` is the test seam. Production default is `~/.mythos/fleet/<fleetID>` (cross-platform). The
    /// fleetID scopes the dir so concurrent fleets never share a board file.
    public init(fleetID: UUID, baseDir: URL? = nil) {
        let base = baseDir ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".mythos/fleet", isDirectory: true)
        let dir = base.appendingPathComponent(fleetID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("blackboard.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                _board = Self.normalizeForPersistence(try JSONDecoder().decode(FleetBlackboard.self, from: data))
            } catch {
                _lastLoadError = "Couldn't load fleet blackboard: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Reads

    /// The current board (a value-type snapshot). nil until seeded / loaded.
    public func currentBoard() -> FleetBlackboard? { lock.lock(); defer { lock.unlock() }; return _board }

    /// Last persistence failure, or nil if the last save succeeded.
    public func lastSaveError() -> String? { lock.lock(); defer { lock.unlock() }; return _lastSaveError }

    /// Last load failure, or nil when the on-disk board decoded cleanly or did not exist.
    public func lastLoadError() -> String? { lock.lock(); defer { lock.unlock() }; return _lastLoadError }

    // MARK: - Writes (captain only)

    /// Seed the board with the initial manifest + pending cells, persist, publish. Overwrites any
    /// in-memory board (a fresh fleet starts clean). The caller supplies the fully-built board so this
    /// stays a pure I/O seam.
    @discardableResult
    public func seed(_ initial: FleetBlackboard) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let normalized = Self.normalizeForPersistence(initial)
        guard persistLocked(normalized) else { return false }
        _board = normalized
        return true
    }

    /// Fold one agent's self-reported `CellUpdate` into its cell and persist. Status is advisory — an
    /// agent may NOT report itself `.signedOff` (only the foreman can); clamped here. Decisions/questions/
    /// blockers are APPEND-ONLY. `filesTouched` is unioned (the agent CLAIMS; the captain harvests the
    /// authoritative set from git). `revision` bumps on every committed fold (the stale-read guard). An
    /// update for an unknown agentID is dropped (it cannot fabricate a cell). Live supervisors must pass
    /// `receivedAtEpoch` so worker-controlled future timestamps are clamped to Captain receive time.
    @discardableResult
    public func foldUpdate(_ update: CellUpdate, receivedAtEpoch: Double? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var current = _board else {
            _lastSaveError = "No fleet blackboard loaded; couldn't fold update for \(update.agentID.uuidString)."
            return false
        }
        guard let idx = current.cells.firstIndex(where: { $0.id == update.agentID }) else { return true }
        var cell = current.cells[idx]
        let eventEpoch = Self.captainObservedEpoch(reported: update.atEpoch, received: receivedAtEpoch)
        let reportedFuture = receivedAtEpoch.map { update.atEpoch > $0 + 5 } ?? false

        // STALE-READ GUARD: an update whose baseRevision predates the board's current revision was
        // composed against an older snapshot. Append-only facts still merge (additive), but a STALE
        // status must NOT regress a newer one; the staleness is surfaced as an open question. baseRevision
        // 0 = "not provided" (the Codable default) → don't flag; only an EXPLICIT older revision is stale.
        let isStale = update.baseRevision > 0 && update.baseRevision < current.revision
        if let status = update.status, status != .signedOff, !isStale {
            let supervisorBlocked = cell.status == .blocked && !cell.supervisorInterventions.isEmpty
            if supervisorBlocked && status == .working {
                cell.openQuestions.append(Note(atEpoch: eventEpoch,
                    text: "Supervisor block remains active; worker .working status ignored until the supervisor verifies repaired evidence."))
            } else {
                cell.status = status
            }
        }
        if isStale {
            cell.openQuestions.append(Note(atEpoch: eventEpoch,
                text: "Stale update (based on rev \(update.baseRevision), board at rev \(current.revision)) — facts merged, status change skipped."))
        }
        if reportedFuture {
            cell.openQuestions.append(Note(atEpoch: eventEpoch,
                text: "Worker update timestamp was in the future (\(update.atEpoch)); Captain clamped it to receive time \(eventEpoch)."))
        }
        for text in update.keyDecisions { cell.keyDecisions.append(Note(atEpoch: eventEpoch, text: text)) }
        for text in update.openQuestions { cell.openQuestions.append(Note(atEpoch: eventEpoch, text: text)) }
        for text in update.blockers { cell.blockers.append(Note(atEpoch: eventEpoch, text: text)) }
        for f in update.filesTouched where !cell.filesTouched.contains(f) { cell.filesTouched.append(f) }
        cell.lastHeartbeatEpoch = max(cell.lastHeartbeatEpoch, eventEpoch)

        current.cells[idx] = cell
        current.revision += 1
        let normalized = Self.normalizeForPersistence(current)
        guard persistLocked(normalized) else { return false }
        _board = normalized
        return true
    }

    /// Fold a LIVE progress signal into a cell: current step + last action + freshness clock. ADVISORY —
    /// never touches status/signoff (only the foreman may), so it can't fake "done." Does NOT bump
    /// `revision` (revision is the TRUSTED-mutation counter the stale-read guard keys on; an advisory
    /// heartbeat every sweep would inflate it and drop a legit status push as "stale"). No-op if the
    /// agent isn't on the board. Live supervisors must pass `receivedAtEpoch` so worker-controlled future
    /// timestamps are clamped to Captain receive time.
    @discardableResult
    public func foldProgress(agentID: UUID, liveStep: Int, lastAction: String, atEpoch: Double,
                             receivedAtEpoch: Double? = nil, advanceHeartbeat: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var current = _board else {
            _lastSaveError = "No fleet blackboard loaded; couldn't fold progress for \(agentID.uuidString)."
            return false
        }
        guard let idx = current.cells.firstIndex(where: { $0.id == agentID }) else { return true }
        var cell = current.cells[idx]
        let eventEpoch = Self.captainObservedEpoch(reported: atEpoch, received: receivedAtEpoch)
        cell.liveStep = liveStep
        cell.lastAction = lastAction
        if advanceHeartbeat {
            cell.lastHeartbeatEpoch = max(cell.lastHeartbeatEpoch, eventEpoch)
        }
        current.cells[idx] = cell
        let normalized = Self.normalizeForPersistence(current)
        guard persistLocked(normalized) else { return false }
        _board = normalized
        return true
    }

    // MARK: - Read-only injection seam

    /// A CHAR-CAPPED shared-context block for an agent's brief: one line per PEER (every cell except
    /// `agentID`) describing what it owns and has proven. Hard-clamped to `digestMaxChars`. Returns "" when
    /// there is no board or no peers.
    public func digest(forAgent agentID: UUID) -> String {
        lock.lock(); defer { lock.unlock() }
        guard let board = _board else { return "" }
        let peers = board.cells.filter { $0.id != agentID }
        guard !peers.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("FLEET SHARED CONTEXT (read-only) — goal: \(board.goal)")
        lines.append("rev \(board.revision). Your crew (do NOT edit their scopes):")
        for cell in peers {
            let scope = cell.scopeGlobs.isEmpty ? "—" : cell.scopeGlobs.joined(separator: ",")
            let latest = cell.keyDecisions.last.map { " · \($0.text)" } ?? ""
            let proven = cell.status == .signedOff ? " [SIGNED OFF]" : ""
            lines.append("- \(cell.title) [\(cell.status.rawValue)]\(proven) · branch \(cell.branch) · scope \(scope)\(latest)")
        }
        return Self.clamp(lines.joined(separator: "\n"), to: Self.digestMaxChars)
    }

    /// Hard char clamp with an explicit truncation marker so a reader can tell the digest was cut. Pure.
    public static func clamp(_ s: String, to maxChars: Int) -> String {
        guard maxChars > 0, s.count > maxChars else { return s }
        let marker = "\n…(truncated — cat blackboard.json for the full board)"
        let keep = max(0, maxChars - marker.count)
        return String(s.prefix(keep)) + marker
    }

    // MARK: - Persistence (lock held by caller)

    private func persistLocked(_ board: FleetBlackboard) -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try enc.encode(board)
            try data.write(to: fileURL, options: [.atomic])
            _lastSaveError = nil
            return true
        } catch {
            _lastSaveError = "Couldn't persist fleet blackboard: \(error.localizedDescription)"
            return false
        }
    }

    private static func captainObservedEpoch(reported: Double, received: Double?) -> Double {
        guard let received else { return reported }
        return reported > received ? received : reported
    }

    private static func normalizeForPersistence(_ board: FleetBlackboard) -> FleetBlackboard {
        var normalized = board
        normalized.schemaVersion = FleetBlackboard.currentSchemaVersion
        for idx in normalized.cells.indices {
            normalized.cells[idx].keyDecisions = suffix(normalized.cells[idx].keyDecisions, limit: maxNotesPerCell)
            normalized.cells[idx].openQuestions = suffix(normalized.cells[idx].openQuestions, limit: maxNotesPerCell)
            normalized.cells[idx].blockers = suffix(normalized.cells[idx].blockers, limit: maxNotesPerCell)
            normalized.cells[idx].supervisorInterventions = suffix(normalized.cells[idx].supervisorInterventions,
                                                                    limit: maxSupervisorRecordsPerCell)
            normalized.cells[idx].supervisorEscalations = suffix(normalized.cells[idx].supervisorEscalations,
                                                                 limit: maxSupervisorRecordsPerCell)
        }
        return normalized
    }

    private static func suffix<T>(_ values: [T], limit: Int) -> [T] {
        guard values.count > limit else { return values }
        return Array(values.suffix(limit))
    }
}
