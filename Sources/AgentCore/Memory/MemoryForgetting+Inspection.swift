import Foundation
import Crypto

extension MemoryForgetting {
    public struct ForgetInspection: Codable, Sendable {
        public let requestSHA256: String?
        /// These three stores only, at the time of inspection. Nil means incomplete coverage.
        public let residualClean: Bool?
        public let issues: [String]
    }

    public struct RetentionInspection: Codable, Sendable {
        public let eligible: [RemovedItem]
        public let issues: [String]
    }

    /// Read-only residual inspection; not an exact purge plan. A matching procedure's other
    /// versions and overlays bound to removed memories can also be deleted by `forget`.
    /// No leases, directories or audit records are created by either inspection method.
    public static func inspectForget(term: String, hostRoot: String) -> ForgetInspection {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (minimumTermUTF8Bytes...1_024).contains(needle.utf8.count) else {
            return ForgetInspection(requestSHA256: nil, residualClean: nil,
                                    issues: ["forget inspection refused: term must contain 4–1024 UTF-8 bytes"])
        }
        let scan = residualScan(term: needle, hostRoot: hostRoot)
        return ForgetInspection(requestSHA256: BuilderEvidenceDigest.sha256(needle),
                                residualClean: scan.clean, issues: scan.issues)
    }

    public static func inspectRetention(hostRoot: String, policy: RetentionPolicy = RetentionPolicy(),
                                        at now: Date) -> RetentionInspection {
        guard ProjectMemory.isWireDate(now),
              let confined = try? ConfinedRoot(root: hostRoot, readOnly: true) else {
            return RetentionInspection(eligible: [],
                issues: ["retention inspection unavailable: invalid timestamp or unreadable root"])
        }
        var eligible: [RemovedItem] = []
        var issues: [String] = []
        for (directory, store, days) in [
            (MemoryAdmissionAuditLog.directory, "admission", policy.admissionRetentionDays),
            (MemoryReactivationStore.directory, "reactivation", policy.overlayRetentionDays)
        ] {
            let selected = retentionSelection(directory, store: store, confined: confined,
                                              olderThanDays: days, at: now)
            issues.append(contentsOf: selected.issues)
            for (name, data) in selected.files.sorted(by: { $0.key < $1.key }) {
                eligible.append(RemovedItem(store: store,
                    reference: BuilderEvidenceDigest.sha256(name),
                    contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
            }
        }
        return RetentionInspection(eligible: eligible, issues: issues)
    }

    /// Shared by preview and sweep so both use the same source clocks and strict expiry boundary.
    /// An unreadable/incomplete inventory selects nothing; invalid individual ages are skipped.
    static func retentionSelection(_ directory: String, store: String, confined: ConfinedRoot,
                                   olderThanDays: Double, at now: Date) -> DirectorySnapshot {
        let observed = snapshot(directory, store: store, confined: confined)
        guard observed.complete else { return DirectorySnapshot(files: [:], issues: observed.issues) }
        var selected = DirectorySnapshot()
        for (name, data) in observed.files.sorted(by: { $0.key < $1.key }) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let age = retentionAge(object, store: store, at: now), age.isFinite else {
                selected.issues.append("\(store) retention record has no valid age; skipped")
                continue
            }
            if age > olderThanDays * 86_400 { selected.files[name] = data }
        }
        return selected
    }

    private static func retentionAge(_ object: [String: Any], store: String, at now: Date) -> TimeInterval? {
        if store == "reactivation", let failureAt = object["failureAt"] as? Double, failureAt.isFinite {
            return now.timeIntervalSince1970 - failureAt
        }
        guard let raw = object["at"] as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: raw) ?? plain.date(from: raw) else { return nil }
        return now.timeIntervalSince(date)
    }
}
