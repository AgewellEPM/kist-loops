import Foundation

/// Q7: forgetting as a designed feature, in two regimes.
///
/// **Hygienic retention** — the governance stores (admission audit, reactivation overlay) are
/// bounded and would otherwise only refuse writes at capacity; the retention sweep removes
/// records past their retention window so the stores stay live.
///
/// **Governance forgetting** — right-to-delete. A forget request purges matching content from
/// episodes, procedures (all versions), and the reactivation overlay, then runs a residual scan
/// proving the content actually left. Every deletion writes a receipt; the receipt stores only
/// the SHA-256 of the request term — a receipt that re-persisted the forgotten content would
/// defeat the deletion it documents.
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
            self.admissionRetentionDays = max(1, admissionRetentionDays)
            self.overlayRetentionDays = max(1, overlayRetentionDays)
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
        /// Governance only: true when the post-deletion residual scan found no trace of the
        /// term in the purgeable stores. Retention sweeps carry nil.
        public let residualClean: Bool?
        public let notes: [String]
    }

    // MARK: - Hygienic retention

    public static func retentionSweep(hostRoot: String, policy: RetentionPolicy = RetentionPolicy(),
                                      at now: Date) -> (receipt: Receipt, issues: [String]) {
        var removed: [RemovedItem] = []
        var issues: [String] = []
        sweepDirectory(MemoryAdmissionAuditLog.directory, store: "admission", hostRoot: hostRoot,
                       olderThanDays: policy.admissionRetentionDays, at: now,
                       recordAge: { object, _ in isoAge(object["at"], at: now) },
                       removed: &removed, issues: &issues)
        sweepDirectory(MemoryReactivationStore.directory, store: "reactivation", hostRoot: hostRoot,
                       olderThanDays: policy.overlayRetentionDays, at: now,
                       recordAge: { object, _ in
                           if let failureAt = object["failureAt"] as? Double, failureAt.isFinite {
                               return now.timeIntervalSince1970 - failureAt
                           }
                           return isoAge(object["at"], at: now)
                       },
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
        var removed: [RemovedItem] = []
        var issues: [String] = []
        var overlayTargets: Set<String> = []

        // Episodes: purge matching rows under the store's own lock, then derive each removed
        // row's recall-entry target so its reactivation overlays are purged with it.
        let episodeLocator = hostRoot + "/.mythos/memory/episodes.jsonl"
        if let dropped = ProjectMemory(root: hostRoot).forgetEpisodes(containing: needle) {
            for (ordinal, row) in dropped.enumerated() {
                removed.append(RemovedItem(store: "episodes",
                                           reference: "removed-row-\(ordinal)",
                                           contentSHA256: BuilderEvidenceDigest.sha256(
                                               String(decoding: row, as: UTF8.self))))
                if let decoded = try? JSONDecoder().decode(Episode.self, from: row),
                   let episode = ProjectMemory.episodeWithTemporalMetadata(
                       ProjectMemory.sanitizedEpisode(decoded)) {
                    overlayTargets.insert(MemoryFailureEvidence.target(AgentMemoryEntry(
                        id: "forgotten", title: "", text: episode.goal + "\n" + episode.summary,
                        locator: episodeLocator, observedAt: episode.at, temporal: episode.temporal)))
                }
            }
        } else {
            issues.append("episodes archive unreadable; episode purge skipped")
        }

        // Procedures: a matching procedure loses its ENTIRE version chain — right-to-delete
        // trumps the reinforcement audit trail.
        if let confined = try? ConfinedRoot(root: hostRoot) {
            let names = (try? confined.entries(ProcedureStore.directory).filter { !$0.isDir }
                .map(\.name).sorted().prefix(maximumScanRecords)) ?? []
            var forgottenIDs: Set<String> = []
            for name in names {
                guard let data = try? confined.readStableData(
                        ProcedureStore.directory + "/" + name, maxBytes: Procedure.maximumRecordBytes),
                      let procedure = try? JSONDecoder().decode(Procedure.self, from: data) else { continue }
                let haystack = (procedure.title + "\n" + procedure.task + "\n" + procedure.steps).lowercased()
                if haystack.contains(needle) {
                    forgottenIDs.insert(procedure.id)
                    overlayTargets.insert(MemoryFailureEvidence.target(AgentMemoryEntry(
                        id: "forgotten", title: "",
                        text: "Applies to: \(procedure.task)\n" + procedure.steps,
                        locator: hostRoot + "/" + ProcedureStore.directory + "/\(procedure.id)",
                        observedAt: procedure.temporal.createdAt, temporal: procedure.temporal)))
                }
            }
            for name in names {
                guard forgottenIDs.contains(where: { name.hasPrefix($0 + "-v") }) else { continue }
                let path = ProcedureStore.directory + "/" + name
                let digest = (try? confined.readStableData(path, maxBytes: Procedure.maximumRecordBytes))
                    .map { BuilderEvidenceDigest.sha256(String(decoding: $0, as: UTF8.self)) } ?? "unreadable"
                do {
                    try confined.removeFile(path)
                    removed.append(RemovedItem(store: "procedures", reference: name,
                                               contentSHA256: digest))
                } catch { issues.append("procedure purge incomplete for \(name): \(error)") }
            }

            // Reactivation overlays: schema-2 records bound to a forgotten memory's target, and
            // legacy records whose recorded signatures carry the term.
            let overlayNames = (try? confined.entries(MemoryReactivationStore.directory)
                .filter { !$0.isDir }.map(\.name).sorted().prefix(maximumScanRecords)) ?? []
            for name in overlayNames {
                let path = MemoryReactivationStore.directory + "/" + name
                guard let data = try? confined.readStableData(path, maxBytes: 8_192),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let boundTarget = object["targetSHA256"] as? String
                let signatures = (object["signatures"] as? [String]) ?? []
                let matches = (boundTarget.map { overlayTargets.contains($0) } ?? false)
                    || signatures.contains { $0.lowercased().contains(needle) }
                guard matches else { continue }
                do {
                    try confined.removeFile(path)
                    removed.append(RemovedItem(store: "reactivation", reference: name,
                                               contentSHA256: BuilderEvidenceDigest.sha256(
                                                   String(decoding: data, as: UTF8.self))))
                } catch { issues.append("overlay purge incomplete for \(name): \(error)") }
            }
        } else {
            issues.append("host root unavailable; procedure and overlay purge skipped")
        }

        let clean = !residualContains(term: needle, hostRoot: hostRoot)
        if !clean { issues.append("residual scan still finds the term; deletion is NOT proven complete") }
        let receipt = Receipt(at: now, regime: "governance",
                              requestSHA256: BuilderEvidenceDigest.sha256(needle),
                              removed: removed, residualClean: clean,
                              notes: issues.filter { !$0.lowercased().contains(needle) })
        if let issue = persist(receipt, hostRoot: hostRoot, at: now) {
            issues.append(issue)
        }
        return (receipt, issues)
    }

    /// Post-deletion proof scan over the purgeable stores. Case-insensitive; bounded.
    static func residualContains(term: String, hostRoot: String) -> Bool {
        let needle = term.lowercased()
        guard let confined = try? ConfinedRoot(root: hostRoot, readOnly: true) else { return true }
        if let data = try? confined.readStableData(".mythos/memory/episodes.jsonl",
                                                   maxBytes: ProjectMemory.defaultMaxEpisodeBytes),
           String(decoding: data, as: UTF8.self).lowercased().contains(needle) {
            return true
        }
        for directory in [ProcedureStore.directory, MemoryReactivationStore.directory] {
            let names = (try? confined.entries(directory).filter { !$0.isDir }
                .map(\.name).prefix(maximumScanRecords)) ?? []
            for name in names {
                if let data = try? confined.readStableData(directory + "/" + name,
                                                           maxBytes: Procedure.maximumRecordBytes),
                   String(decoding: data, as: UTF8.self).lowercased().contains(needle) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Internals

    private static func sweepDirectory(_ directory: String, store: String, hostRoot: String,
                                       olderThanDays: Double, at now: Date,
                                       recordAge: ([String: Any], String) -> TimeInterval?,
                                       removed: inout [RemovedItem], issues: inout [String]) {
        guard let confined = try? ConfinedRoot(root: hostRoot) else {
            issues.append("\(store) retention sweep unavailable: host root unreadable")
            return
        }
        let names: [String]
        do { names = try confined.entries(directory).filter { !$0.isDir }.map(\.name) }
        catch { return }
        for name in names.sorted().prefix(maximumScanRecords) {
            let path = directory + "/" + name
            guard let data = try? confined.readStableData(path, maxBytes: 64_000),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let age = recordAge(object, name) else { continue }
            guard age > olderThanDays * 86_400 else { continue }
            do {
                try confined.removeFile(path)
                removed.append(RemovedItem(store: store, reference: name,
                                           contentSHA256: BuilderEvidenceDigest.sha256(
                                               String(decoding: data, as: UTF8.self))))
            } catch { issues.append("\(store) retention removal incomplete for \(name): \(error)") }
        }
    }

    private static func isoAge(_ value: Any?, at now: Date) -> TimeInterval? {
        guard let raw = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else { return nil }
        return now.timeIntervalSince(date)
    }

    private static func persist(_ receipt: Receipt, hostRoot: String, at now: Date) -> String? {
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
