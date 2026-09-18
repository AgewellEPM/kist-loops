import Foundation
import Crypto

/// Q7: forgetting as a designed feature, in two regimes.
///
/// **Hygienic retention** — the governance stores (admission audit, reactivation overlay) are
/// bounded and would otherwise only refuse writes at capacity; the retention sweep removes
/// records past their retention window so the stores stay live.
///
/// **Governance forgetting** — right-to-delete. A forget request purges matching content from
/// episodes, procedures (all versions), and the reactivation overlay, then scans those stores.
/// These local audit records describe bounded, point-in-time observations, not sealed completion
/// receipts or system-wide erasure. Read failures and limits are explicit incomplete results.
/// Request terms and removed payloads are represented by digests, never copied into the audit.
///
/// Deliberately NOT purged here: the agent-history archive (append-only forensic surface with
/// its own confinement; purging it is a separate, explicitly-operator-owned decision) and
/// admission audit records (they carry digests and reasons, not memory content).
public enum MemoryForgetting {
    public static let receiptDirectory = ".kist/memory/forgetting/v1"
    public static let maximumReceipts = 2_048
    public static let minimumTermUTF8Bytes = 4
    public static let maximumScanRecords = 4_096

    public struct RetentionPolicy: Sendable {
        public let admissionRetentionDays: Double
        public let overlayRetentionDays: Double
        public init(admissionRetentionDays: Double = 90, overlayRetentionDays: Double = 90) {
            self.admissionRetentionDays = admissionRetentionDays.isFinite ? max(1, admissionRetentionDays) : 90
            self.overlayRetentionDays = overlayRetentionDays.isFinite ? max(1, overlayRetentionDays) : 90
        }
    }

    public struct RemovedItem: Codable, Sendable, Equatable {
        public let store: String
        public let reference: String
        public let contentSHA256: String
    }

    public struct Receipt: Codable, Sendable {
        public let at: Date
        public let regime: String
        /// SHA-256 of the lowercased request term for governance forgets; nil for retention.
        public let requestSHA256: String?
        public let removed: [RemovedItem]
        /// Governance only: true for a complete scan with no matching content, false for known
        /// residue, nil for incomplete coverage. Retention sweeps also carry nil.
        public let residualClean: Bool?
        public let notes: [String]
    }

    // MARK: - Hygienic retention

    public static func retentionSweep(hostRoot: String, policy: RetentionPolicy = RetentionPolicy(),
                                      at now: Date) -> (receipt: Receipt, issues: [String]) {
        var removed: [RemovedItem] = []
        var issues: [String] = []
        let lease: WorkspaceExecutionLease
        do {
            guard ProjectMemory.isWireDate(now) else { throw ToolError.execution("invalid timestamp") }
            lease = try WorkspaceExecutionCoordinator().acquire(projectRoot: hostRoot,
                missionInstanceID: "memory-retention-" + UUID().uuidString, blocking: false)
        } catch {
            let notes = ["retention refused: invalid timestamp or exclusive workspace lease unavailable"]
            return (Receipt(at: now, regime: "retention", requestSHA256: nil,
                            removed: [], residualClean: nil, notes: notes), notes)
        }
        defer { lease.release() }
        sweepDirectory(MemoryAdmissionAuditLog.directory, store: "admission", hostRoot: hostRoot,
                       olderThanDays: policy.admissionRetentionDays, at: now, lease: lease,
                       removed: &removed, issues: &issues)
        sweepDirectory(MemoryReactivationStore.directory, store: "reactivation", hostRoot: hostRoot,
                       olderThanDays: policy.overlayRetentionDays, at: now, lease: lease,
                       removed: &removed, issues: &issues)
        let receipt = Receipt(at: now, regime: "retention", requestSHA256: nil,
                              removed: removed, residualClean: nil, notes: issues)
        if !removed.isEmpty, let issue = persist(receipt, hostRoot: hostRoot, at: now) {
            issues.append(issue)
        }
        return (receipt, issues)
    }

    // MARK: - Governance forgetting (right-to-delete)

    public static func forget(term: String, hostRoot: String,
                              at now: Date) -> (receipt: Receipt?, issues: [String]) {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.utf8.count >= minimumTermUTF8Bytes else {
            return (nil, ["forget refused: the term is too short to identify content safely"])
        }
        guard needle.utf8.count <= 1_024, ProjectMemory.isWireDate(now) else {
            return (nil, ["forget refused: invalid term size or timestamp"])
        }
        let lease: WorkspaceExecutionLease
        do {
            lease = try WorkspaceExecutionCoordinator().acquire(projectRoot: hostRoot,
                missionInstanceID: "memory-forgetting-" + UUID().uuidString, blocking: false)
        } catch {
            return (nil, ["forget refused: exclusive workspace lease unavailable"])
        }
        defer { lease.release() }
        var removed: [RemovedItem] = []
        var issues: [String] = []
        var overlayTargets: Set<String> = []

        // Episodes: purge matching rows under the store's own lock, then derive each removed
        // row's recall-entry target so its reactivation overlays are purged with it.
        let episodeLocator = hostRoot + "/.mythos/memory/episodes.jsonl"
        if let dropped = ProjectMemory(root: hostRoot).forgetEpisodes(containing: needle, lease: lease) {
            for (ordinal, row) in dropped.enumerated() {
                removed.append(RemovedItem(store: "episodes",
                                           reference: "removed-row-\(ordinal)",
                                           contentSHA256: digest(row)))
                if let decoded = try? JSONDecoder().decode(Episode.self, from: row),
                   let episode = ProjectMemory.episodeWithTemporalMetadata(
                       ProjectMemory.sanitizedEpisode(decoded)) {
                    overlayTargets.insert(MemoryFailureEvidence.target(AgentMemoryEntry(
                        id: "forgotten", title: "", text: episode.goal + "\n" + episode.summary,
                        locator: episodeLocator, observedAt: episode.at, temporal: episode.temporal)))
                }
            }
        } else {
            issues.append("episode purge unreadable, over limit, locked or write failed; incomplete")
        }

        // Procedures: a matching procedure loses its ENTIRE version chain — right-to-delete
        // trumps the reinforcement audit trail.
        if let confined = try? ConfinedRoot(root: hostRoot) {
            let observed = snapshot(ProcedureStore.directory, store: "procedure", confined: confined)
            issues.append(contentsOf: observed.issues)
            var versions: [String: Procedure] = [:]
            var forgottenIDs: Set<String> = []
            var valid = observed.complete
            if valid {
                for (name, data) in observed.files {
                    guard let procedure = try? JSONDecoder().decode(Procedure.self, from: data),
                          name == ProcedureStore.fileName(id: procedure.id, version: procedure.version) else {
                        issues.append("procedure record invalid; whole-chain purge skipped")
                        valid = false
                        break
                    }
                    versions[name] = procedure
                    if contentContains(data, term: needle) { forgottenIDs.insert(procedure.id) }
                }
            }
            if valid {
                for (name, procedure) in versions.sorted(by: { $0.key < $1.key })
                    where forgottenIDs.contains(procedure.id) {
                    guard let data = observed.files[name] else { continue }
                    do {
                        _ = try confined.conditionalRemove(ProcedureStore.directory + "/" + name,
                            expectedSHA256: Data(SHA256.hash(data: data)), lease: lease)
                        removed.append(RemovedItem(store: "procedures", reference: digest(Data(name.utf8)),
                                                   contentSHA256: digest(data)))
                    } catch {
                        issues.append("procedure changed or removal failed; purge incomplete")
                        continue
                    }
                    // Every removed version has its own content/clock/path identity. Include
                    // the historical unversioned locator only to remove old advisory overlays.
                    for locator in [hostRoot + "/" + procedure.relativePath,
                                    hostRoot + "/" + ProcedureStore.directory + "/" + procedure.id] {
                        overlayTargets.insert(MemoryFailureEvidence.target(AgentMemoryEntry(
                            id: "forgotten", title: "",
                            text: "Applies to: \(procedure.task)\n" + procedure.steps,
                            locator: locator,
                            observedAt: procedure.temporal.createdAt, temporal: procedure.temporal)))
                    }
                }
            }

            // Reactivation overlays: schema-2 records bound to a forgotten memory's target, and
            // legacy records whose recorded signatures carry the term.
            let overlays = snapshot(MemoryReactivationStore.directory, store: "reactivation", confined: confined)
            issues.append(contentsOf: overlays.issues)
            for (name, data) in overlays.files.sorted(by: { $0.key < $1.key }) where overlays.complete {
                let path = MemoryReactivationStore.directory + "/" + name
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    issues.append("reactivation record malformed; purge incomplete")
                    continue
                }
                let boundTarget = object["targetSHA256"] as? String
                let matches = (boundTarget.map { overlayTargets.contains($0) } ?? false)
                    || contentContains(data, term: needle)
                guard matches else { continue }
                do {
                    _ = try confined.conditionalRemove(path,
                        expectedSHA256: Data(SHA256.hash(data: data)), lease: lease)
                    removed.append(RemovedItem(store: "reactivation", reference: digest(Data(name.utf8)),
                                               contentSHA256: digest(data)))
                } catch { issues.append("overlay changed or removal failed; purge incomplete") }
            }
        } else {
            issues.append("host root unavailable; procedure and overlay purge skipped")
        }

        let scan = residualScan(term: needle, hostRoot: hostRoot)
        issues.append(contentsOf: scan.issues)
        if scan.contains { issues.append("residual content remains; deletion incomplete") }
        let clean = issues.isEmpty ? scan.clean : (scan.contains ? false : nil)
        let receipt = Receipt(at: now, regime: "governance",
                              requestSHA256: BuilderEvidenceDigest.sha256(needle),
                              removed: removed, residualClean: clean,
                              notes: issues.filter { !$0.lowercased().contains(needle) })
        if let issue = persist(receipt, hostRoot: hostRoot, at: now) {
            issues.append(issue)
        }
        return (receipt, issues)
    }

    // MARK: - Internals

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sweepDirectory(_ directory: String, store: String, hostRoot: String,
                                       olderThanDays: Double, at now: Date, lease: WorkspaceExecutionLease,
                                       removed: inout [RemovedItem], issues: inout [String]) {
        guard let confined = try? ConfinedRoot(root: hostRoot) else {
            issues.append("\(store) retention sweep unavailable: host root unreadable")
            return
        }
        let selected = retentionSelection(directory, store: store, confined: confined,
                                          olderThanDays: olderThanDays, at: now)
        issues.append(contentsOf: selected.issues)
        for (name, data) in selected.files.sorted(by: { $0.key < $1.key }) {
            let path = directory + "/" + name
            do {
                _ = try confined.conditionalRemove(path,
                    expectedSHA256: Data(SHA256.hash(data: data)), lease: lease)
                removed.append(RemovedItem(store: store, reference: digest(Data(name.utf8)),
                                           contentSHA256: digest(data)))
            } catch { issues.append("\(store) retention record changed or removal failed; incomplete") }
        }
    }

    private static func persist(_ receipt: Receipt, hostRoot: String, at now: Date) -> String? {
        guard ProjectMemory.isWireDate(now) else { return "forgetting receipt NOT written: invalid timestamp" }
        do {
            let confined = try ConfinedRoot(root: hostRoot)
            let existing: Int
            do { existing = try confined.entries(receiptDirectory).count }
            catch ToolError.notFound { existing = 0 }
            // Deletion is never blocked on receipt capacity — refusing a right-to-delete
            // because the audit is full would retain data the request removed. The missing
            // receipt is reported loudly instead.
            guard existing < maximumReceipts else {
                return "forgetting receipt NOT written: receipt store at capacity (\(maximumReceipts))"
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let name = "\(Int(now.timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased().prefix(8)).json"
            _ = try confined.createDataIfMissing(receiptDirectory + "/" + name,
                                                 try encoder.encode(receipt), createParents: true)
            return nil
        } catch {
            return "forgetting receipt NOT written: \(error)"
        }
    }
}
