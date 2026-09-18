import Foundation
import AgentCore

extension KistRunner {
    /// Offline maintenance dispatches before provider, MCP, and tool construction.
    static func runSMLRuntimeMaintenance(_ opts: KistOptions) async -> Int32 {
        do {
            let report = try await Self.performSMLRuntimeMaintenance(opts)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return 0
        } catch {
            FileHandle.standardError.write(Data("SML store maintenance failed: \(error)\n".utf8))
            return 2
        }
    }

    static func performSMLRuntimeMaintenance(_ opts: KistOptions) async throws -> SMLRuntimeMaintenanceReport {
        let project = URL(fileURLWithPath: opts.project, isDirectory: true).standardizedFileURL
        let store = SMLRuntimeStore(fileURL: SMLRuntimeStore.defaultURL(projectRoot: project.path))
        func backupURL() throws -> URL {
            guard let path = opts.smlBackupPath, !path.isEmpty else {
                throw SMLRuntimeStoreError.io("backup and restore require --sml-backup <path>")
            }
            return URL(fileURLWithPath: path, relativeTo: project).standardizedFileURL
        }
        switch opts.smlStoreAction {
        case "verify":
            return try await store.verify()
        case "backup":
            return try await store.backup(to: backupURL()) { snapshot in
                try captureSMLRecoveryFiles(project: project, snapshot: snapshot)
            }
        case "restore":
            return try await store.restore(from: backupURL(), replacingExpectedSHA256: opts.smlReplaceSHA256) { files, quarantine in
                try restoreSMLRecoveryFiles(files, project: project, replacingRuntime: quarantine != nil)
            }
        case "archive":
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let input = opts.smlArchiveBefore ?? ""
            let fractional = format.date(from: input)
            format.formatOptions = [.withInternetDateTime]
            guard let cutoff = fractional ?? format.date(from: input) else {
                throw SMLRuntimeStoreError.io("--sml-archive-before requires an ISO8601 timestamp with timezone")
            }
            return try await store.archiveTerminalTasks(updatedBeforeEpoch: cutoff.timeIntervalSince1970,
                                                       maximumTasks: opts.smlArchiveMaximum ?? 1_000)
        default:
            throw SMLRuntimeStoreError.io("--sml-store requires verify, backup, restore, or archive")
        }
    }
}
