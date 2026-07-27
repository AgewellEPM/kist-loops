import Foundation

/// The WHOLE-PICTURE read model for a fleet — ported from TinkySDR Terminal Captain (C1). kist runs a
/// fleet's lease/signoff/baton machinery, but nothing surfaced "who did what, was it verified, will it
/// merge, was it held back for a lease escape." This pure aggregation fuses the blackboard cells +
/// the trustworthy signoff ledger into one honest picture you can read in the terminal — the Captain's
/// cockpit, for a CLI.
///
/// TRUSTWORTHY BY CONSTRUCTION: `willMerge` is derived from the SAME inputs + rule as
/// `FleetSupervisor.joinSignedBranches` — a chain-intact, seal-valid green signoff for the agent
/// (deduped one-per-agent), with `outOfScopeCount == 0`. Pass the ledger's `entries` (EMPTY on a
/// broken chain) so the cockpit can NEVER show "will merge" for a branch the merge gate would refuse.
public struct FleetAgentRow: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let branch: String
    public let status: AgentCell.CellStatus
    public let scopeGlobs: [String]            // the validated LEASE (empty = permissive)
    public let signoffSeq: Int?                // sealed signoff seq; nil = not (trustworthily) signed
    public let outOfScopeCount: Int?           // sealed escape count; nil = not signed
    public let willMerge: Bool                 // signed + in-lease → joinSignedBranches would auto-join
    public let refusedForLease: Bool           // signed but committed OUTSIDE its lease → held back
    public let blockerReason: String?
    /// A HELD-OUT ADVISORY was recorded for this agent — the base-tests-vs-code check flagged a possible
    /// weakened test OR a legitimate API change. NEVER blocks (the agent still signs); surfaced so the
    /// operator reviews before promoting. Full text lives in the board keyDecisions.
    public let heldOutAdvisory: Bool
    public let liveStep: Int?
    public let lastAction: String?
    public let lastHeartbeatEpoch: Double
}

public struct FleetPicture: Equatable, Sendable {
    public let goal: String
    public let rows: [FleetAgentRow]
    public let total: Int
    public let signed: Int
    public let mergeable: Int
    public let refusedForLease: Int
    public let chainIntact: Bool               // false ⇒ ZERO trust (tampered ledger)
    public var allMergeable: Bool { mergeable == total && total > 0 }

    public func render() -> String {
        if !chainIntact { return "Fleet cockpit · ⚠ SIGNOFF LEDGER CHAIN BROKEN — zero trustworthy signoffs. Nothing will merge." }
        var s = "Fleet cockpit · \(goal)\n"
        s += "\(total) agents · \(signed) signed · \(mergeable) mergeable"
        if refusedForLease > 0 { s += " · \(refusedForLease) held (lease escape)" }
        s += "\n"
        for r in rows.sorted(by: { $0.title < $1.title }) {
            let mark: String
            switch r.status {
            case .signedOff: mark = r.willMerge ? "☑" : (r.refusedForLease ? "⊘" : "☑")
            case .failed: mark = "✗"; case .blocked: mark = "⊘"; case .working: mark = "◐"
            case .readyForSignoff: mark = "◑"; case .pending: mark = "☐"
            }
            s += "  \(mark) \(r.title)  \u{001B}[2m[\(r.branch)]\u{001B}[0m"
            if let seq = r.signoffSeq { s += "  signed#\(seq)" }
            s += r.willMerge ? "  → merges" : (r.refusedForLease ? "  → HELD (off-lease)" : "")
            if let step = r.liveStep, let act = r.lastAction, r.status == .working {
                s += "  \u{001B}[2m· doing: \(act) (step \(step))\u{001B}[0m"
            }
            if let why = r.blockerReason, r.status == .blocked || r.status == .failed { s += "  \u{001B}[2m· \(why)\u{001B}[0m" }
            if r.heldOutAdvisory { s += "  \u{001B}[33m⚠ held-out advisory — review before promoting\u{001B}[0m" }
            s += "\n"
        }
        return s
    }
}

public enum FleetCockpitModel {

    /// Fold the cells + trustworthy ledger entries into the whole picture. `trustworthyEntries` MUST be
    /// `ledger.entries` (chain-intact + seal-valid only). `chainIntact` is surfaced for honest display.
    public static func picture(goal: String, cells: [AgentCell], trustworthyEntries: [FleetSignoffEntry],
                               chainIntact: Bool) -> FleetPicture {
        // One trustworthy signoff per agent — latest seq wins (mirrors the gate's dedup).
        var signoffByAgent: [UUID: FleetSignoffEntry] = [:]
        for e in trustworthyEntries where e.verdict == .green {
            if let prev = signoffByAgent[e.agentID], prev.seq >= e.seq { continue }
            signoffByAgent[e.agentID] = e
        }
        var rows: [FleetAgentRow] = []
        for cell in cells {
            let entry = signoffByAgent[cell.id]
            let willMerge = (entry?.outOfScopeCount == 0) && entry != nil
            let refused = (entry.map { $0.outOfScopeCount > 0 }) ?? false
            rows.append(FleetAgentRow(
                id: cell.id, title: cell.title, branch: cell.branch, status: cell.status,
                scopeGlobs: cell.scopeGlobs, signoffSeq: entry?.seq, outOfScopeCount: entry?.outOfScopeCount,
                willMerge: willMerge, refusedForLease: refused,
                blockerReason: cell.blockers.last?.text,
                heldOutAdvisory: cell.keyDecisions.contains { $0.text.contains("HELD-OUT ADVISORY") },
                liveStep: cell.liveStep,
                lastAction: cell.lastAction, lastHeartbeatEpoch: cell.lastHeartbeatEpoch))
        }
        return FleetPicture(
            goal: goal, rows: rows, total: rows.count,
            signed: rows.filter { $0.signoffSeq != nil }.count,
            mergeable: rows.filter { $0.willMerge }.count,
            refusedForLease: rows.filter { $0.refusedForLease }.count,
            chainIntact: chainIntact)
    }

    /// A NON-terminal agent is STALE when its last heartbeat is older than `thresholdSeconds`. A zero
    /// heartbeat (no signal yet) is NOT stale (it just started). Pure.
    public static func isStale(lastHeartbeatEpoch: Double, now: Double, thresholdSeconds: Double = 300) -> Bool {
        guard lastHeartbeatEpoch > 0 else { return false }
        return (now - lastHeartbeatEpoch) > thresholdSeconds
    }
}
