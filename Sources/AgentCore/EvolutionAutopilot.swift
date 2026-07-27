import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// CROSS-SESSION AUTOPILOT SCAFFOLD — lets the DGM evolve over DAYS via repeated (e.g. cron) invocations,
/// building on the accumulated archive. It is DISARMED by default and FAIL-CLOSED: an autonomous session
/// refuses to spawn anything unless a human has EXPLICITLY armed it with a BOUNDED cumulative token budget,
/// a maximum number of sessions, and a hard time-expiry. So it can never run away — it stops itself when
/// the budget is spent, the session count is hit, the arming expires, or the search globally stagnates.
/// The never-merge / never-auto-promote invariant is unchanged; this only decides WHETHER to run a round.

/// The human-set authorization to run autonomously. Absent ⇒ disarmed.
public struct EvolutionArming: Codable, Sendable, Equatable {
    public var objective: String             // what to improve — fixed at arm time (cron reuses it)
    public var cumulativeBudgetTokens: Int   // total tokens across ALL sessions (hard ceiling)
    public var maxSessions: Int              // total autonomous sessions allowed
    public var expiresAtEpoch: Double        // hard wall-clock expiry — re-arm to continue
    public var armedAtEpoch: Double
    public var generationsPerSession: Int    // how many DGM generations one session runs
    public var stagnationPatience: Int       // stop after N consecutive sessions with no improvement (0 = off)

    public init(objective: String, cumulativeBudgetTokens: Int, maxSessions: Int, expiresAtEpoch: Double,
                armedAtEpoch: Double, generationsPerSession: Int, stagnationPatience: Int) {
        self.objective = objective
        self.cumulativeBudgetTokens = cumulativeBudgetTokens
        self.maxSessions = maxSessions
        self.expiresAtEpoch = expiresAtEpoch
        self.armedAtEpoch = armedAtEpoch
        self.generationsPerSession = generationsPerSession
        self.stagnationPatience = stagnationPatience
    }
}

/// Cumulative progress across all autonomous sessions (persisted).
public struct EvolutionRunState: Codable, Sendable, Equatable {
    public var sessionsRun: Int
    public var tokensSpent: Int
    public var bestEverScore: Int?
    public var consecutiveStagnantSessions: Int
    public var firstSessionAtEpoch: Double?
    public var lastSessionAtEpoch: Double?

    public init(sessionsRun: Int = 0, tokensSpent: Int = 0, bestEverScore: Int? = nil,
                consecutiveStagnantSessions: Int = 0, firstSessionAtEpoch: Double? = nil,
                lastSessionAtEpoch: Double? = nil) {
        self.sessionsRun = sessionsRun; self.tokensSpent = tokensSpent; self.bestEverScore = bestEverScore
        self.consecutiveStagnantSessions = consecutiveStagnantSessions
        self.firstSessionAtEpoch = firstSessionAtEpoch; self.lastSessionAtEpoch = lastSessionAtEpoch
    }

    /// Fold one finished session into the cumulative state.
    public func recording(tokensSpentThisSession: Int, newBestScore: Int?, nowEpoch: Double) -> EvolutionRunState {
        let improved = EvolutionRunProgress.improved(from: bestEverScore, to: newBestScore)
        let best: Int? = {
            switch (bestEverScore, newBestScore) {
            case let (b?, n?): return max(b, n)
            case (let b?, nil): return b
            case (nil, let n): return n
            }
        }()
        return EvolutionRunState(
            sessionsRun: sessionsRun + 1,
            tokensSpent: tokensSpent + max(0, tokensSpentThisSession),
            bestEverScore: best,
            consecutiveStagnantSessions: improved ? 0 : consecutiveStagnantSessions + 1,
            firstSessionAtEpoch: firstSessionAtEpoch ?? nowEpoch,
            lastSessionAtEpoch: nowEpoch)
    }
}

/// The FAIL-CLOSED decision brain (pure): should this autonomous session run, and with what budget?
public enum EvolutionRunController {

    public struct Decision: Sendable, Equatable {
        public var shouldRun: Bool
        public var reason: String
        public var sessionBudgetTokens: Int   // 0 when shouldRun is false
    }

    static func refuse(_ reason: String) -> Decision { Decision(shouldRun: false, reason: reason, sessionBudgetTokens: 0) }

    /// Every gate must pass to run. Any missing/expired/exhausted/stagnant condition ⇒ refuse (no spawn).
    public static func decide(arming: EvolutionArming?, state: EvolutionRunState, nowEpoch: Double,
                              perSessionBudgetCap: Int) -> Decision {
        guard let arming else {
            return refuse("DISARMED — autonomous evolution is off. Arm it explicitly: kist --evolve-arm --budget <tokens> --max-sessions <N>")
        }
        // Validate state invariants BEFORE trusting any arithmetic — a tampered/corrupt state with
        // negative counters could make `remaining` huge and bypass the ceiling. Refuse, don't guess.
        guard state.tokensSpent >= 0, state.sessionsRun >= 0, state.consecutiveStagnantSessions >= 0 else {
            return refuse("run-state INVALID (negative counters) — refusing autonomous run; investigate .mythos/evolution/run-state.json")
        }
        guard nowEpoch < arming.expiresAtEpoch else {
            return refuse("arming EXPIRED — re-arm to continue autonomous evolution")
        }
        guard state.sessionsRun < arming.maxSessions else {
            return refuse("session ceiling reached (\(state.sessionsRun)/\(arming.maxSessions)) — re-arm to run more")
        }
        let remaining = arming.cumulativeBudgetTokens - state.tokensSpent
        guard remaining > 0 else {
            return refuse("cumulative token budget exhausted (\(state.tokensSpent)/\(arming.cumulativeBudgetTokens)) — re-arm to add budget")
        }
        if arming.stagnationPatience > 0, state.consecutiveStagnantSessions >= arming.stagnationPatience {
            return refuse("global stagnation: \(state.consecutiveStagnantSessions) session(s) without improvement ≥ patience \(arming.stagnationPatience) — search has plateaued")
        }
        let sessionBudget = min(max(0, perSessionBudgetCap), remaining)
        guard sessionBudget > 0 else { return refuse("no per-session budget available (cap \(perSessionBudgetCap), remaining \(remaining))") }
        return Decision(shouldRun: true,
                        reason: "ARMED · session \(state.sessionsRun + 1)/\(arming.maxSessions) · budget \(sessionBudget) of \(remaining) remaining",
                        sessionBudgetTokens: sessionBudget)
    }
}

/// Persistence for arming + run-state under `<root>/.mythos/evolution/`. Fail-soft on any I/O error.
public struct EvolutionAutopilotStore: Sendable {
    public let root: String
    public init(root: String) { self.root = root }

    private var dir: String { (root as NSString).appendingPathComponent(".mythos/evolution") }
    var armingPath: String { (dir as NSString).appendingPathComponent("arming.json") }
    var statePath: String { (dir as NSString).appendingPathComponent("run-state.json") }

    var sessionLockPath: String { (dir as NSString).appendingPathComponent("session.lock") }

    public func arming() -> EvolutionArming? { decode(armingPath) }
    public func state() -> EvolutionRunState { decode(statePath) ?? EvolutionRunState() }

    /// FAIL-CLOSED state load for the autonomous path: distinguishes MISSING (first run ⇒ fresh state, fine)
    /// from PRESENT-BUT-UNDECODABLE (corrupt/truncated ⇒ nil ⇒ the caller must refuse). Defaulting a
    /// corrupt state to zero would silently reset the cumulative budget and let the whole ceiling be spent
    /// again (fail-open) — the panel's HIGH/BLOCKER finding.
    public func stateOrNil() -> EvolutionRunState? {
        guard FileManager.default.fileExists(atPath: statePath) else { return EvolutionRunState() }
        return decode(statePath)   // present but undecodable ⇒ nil
    }

    /// Acquire an EXCLUSIVE, non-blocking interprocess lock for the whole session. Returns a handle to hold
    /// for the session's duration, or nil if another session already holds it (⇒ decline). Serializes
    /// concurrent `--evolve-session` invocations (overlapping cron) so the budget/session ceilings can't be
    /// bypassed by a read-decide-run-write race.
    public func acquireSessionLock() -> Int32? {
        #if canImport(Darwin) || canImport(Glibc)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fd = open(sessionLockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return nil }   // held by another process ⇒ decline
        return fd
        #else
        return -1   // no locking available ⇒ best-effort (single-process platforms)
        #endif
    }
    public func releaseSessionLock(_ fd: Int32) {
        #if canImport(Darwin) || canImport(Glibc)
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd)
        #endif
    }

    @discardableResult public func arm(_ arming: EvolutionArming) -> Bool { encode(arming, to: armingPath) }
    @discardableResult public func disarm() -> Bool {
        // Removing the arming file returns to the DISARMED (fail-closed) default. Missing = already disarmed.
        if !FileManager.default.fileExists(atPath: armingPath) { return true }
        return (try? FileManager.default.removeItem(atPath: armingPath)) != nil
    }
    @discardableResult public func save(state: EvolutionRunState) -> Bool { encode(state, to: statePath) }

    private func decode<T: Decodable>(_ path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func encode<T: Encodable>(_ value: T, to path: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(value) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
