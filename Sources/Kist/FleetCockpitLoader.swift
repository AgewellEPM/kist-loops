import Foundation
import AgentCore

/// Reads the most-recent fleet's persisted stores off disk and folds them into a cockpit picture —
/// so `/fleet-status` can pull up the whole-picture view anytime, not just right after a run. Reads
/// only (blackboard + trustworthy signoff ledger); the merge-fate it shows mirrors the merge gate.
enum FleetCockpitLoader {
    static func latestPicture(fleetRoot: String = NSHomeDirectory() + "/.mythos/fleet") -> FleetPicture? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: fleetRoot) else { return nil }
        let fleets: [(id: UUID, at: Date)] = names.compactMap { name in
            guard let id = UUID(uuidString: name) else { return nil }
            let mod = (try? fm.attributesOfItem(atPath: fleetRoot + "/" + name)[.modificationDate]) as? Date
            return (id, mod ?? .distantPast)
        }
        guard let newest = fleets.max(by: { $0.at < $1.at }) else { return nil }

        let baseURL = URL(fileURLWithPath: fleetRoot)
        let board = FleetBlackboardStore(fleetID: newest.id, baseDir: baseURL)
        let ledger = FleetSignoffLedger(baseDir: baseURL.appendingPathComponent(newest.id.uuidString)
                                                        .appendingPathComponent("signoff"))
        guard let snapshot = board.currentBoard() else { return nil }
        let chainIntact = ledger.all().isEmpty || !ledger.entries.isEmpty
        return FleetCockpitModel.picture(goal: snapshot.goal, cells: snapshot.cells,
                                         trustworthyEntries: ledger.entries, chainIntact: chainIntact)
    }
}
