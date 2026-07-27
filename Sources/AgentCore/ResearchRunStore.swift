import Foundation

public struct ResearchRunManifest: Codable, Equatable, Sendable {
    public var runID: String
    public var goal: String
    public var projectRoot: String
    public var status: String
    public var createdAt: Double
    public var updatedAt: Double
    public var reportPath: String?
}

public struct ResearchEvidence: Codable, Equatable, Sendable {
    public var sequence: Int
    public var id: String
    public var kind: String
    public var title: String
    public var url: String?
    public var path: String?
    public var text: String
    public var metadata: [String: String]
    public var at: Double
}

public struct ResearchHeartbeat: Codable, Equatable, Sendable {
    public var sequence: Int
    public var status: String
    public var message: String
    public var at: Double
}

public final class ResearchRunStore: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var manifest: ResearchRunManifest
    private var evidenceSequence: Int
    private var heartbeatSequence: Int

    public let runDirectory: String
    public let manifestPath: String
    public let evidencePath: String
    public let heartbeatPath: String

    public init(projectRoot: String, goal: String, runID: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        self.now = now
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let id = try Self.validRunID(runID ?? Self.makeRunID())
        let created = now().timeIntervalSince1970
        self.runDirectory = Self.researchRoot(projectRoot: root) + "/" + id
        self.manifestPath = runDirectory + "/manifest.json"
        self.evidencePath = runDirectory + "/evidence.jsonl"
        self.heartbeatPath = runDirectory + "/heartbeats.jsonl"
        self.manifest = ResearchRunManifest(runID: id, goal: goal, projectRoot: root,
                                            status: "planning", createdAt: created,
                                            updatedAt: created, reportPath: nil)
        self.evidenceSequence = 0
        self.heartbeatSequence = 0
        try FileManager.default.createDirectory(atPath: runDirectory, withIntermediateDirectories: true)
        try persistManifest()
    }

    public static func open(projectRoot: String, runID: String,
                            now: @escaping @Sendable () -> Date = { Date() }) throws -> ResearchRunStore {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let id = try validRunID(runID)
        let path = manifestPath(projectRoot: root, runID: id)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let manifest = try JSONDecoder().decode(ResearchRunManifest.self, from: data)
        let store = try ResearchRunStore(projectRoot: root, goal: manifest.goal, runID: id, now: now)
        store.lock.lock()
        store.manifest = manifest
        store.evidenceSequence = loadEvidence(projectRoot: root, runID: id).map(\.sequence).max() ?? 0
        store.heartbeatSequence = loadHeartbeats(projectRoot: root, runID: id).map(\.sequence).max() ?? 0
        store.lock.unlock()
        try store.persistManifest()
        return store
    }

    public func currentManifest() -> ResearchRunManifest {
        lock.lock()
        let m = manifest
        lock.unlock()
        return m
    }

    @discardableResult
    public func heartbeat(status: String, message: String) throws -> ResearchHeartbeat {
        lock.lock()
        defer { lock.unlock() }
        heartbeatSequence += 1
        manifest.status = status
        manifest.updatedAt = now().timeIntervalSince1970
        let beat = ResearchHeartbeat(sequence: heartbeatSequence, status: status,
                                     message: Self.safeText(message), at: manifest.updatedAt)
        try? persistManifestLocked()
        try appendJSONLocked(beat, to: heartbeatPath)
        return beat
    }

    @discardableResult
    public func appendEvidence(kind: String, title: String, text: String,
                               url: String? = nil, path: String? = nil,
                               metadata: [String: String] = [:]) throws -> ResearchEvidence {
        lock.lock()
        defer { lock.unlock() }
        evidenceSequence += 1
        manifest.status = "gathering"
        manifest.updatedAt = now().timeIntervalSince1970
        let sequence = evidenceSequence
        let evidence = ResearchEvidence(sequence: sequence,
                                        id: "E\(String(format: "%03d", sequence))",
                                        kind: kind,
                                        title: Self.safeText(title),
                                        url: url,
                                        path: path,
                                        text: Self.safeText(text),
                                        metadata: metadata,
                                        at: now().timeIntervalSince1970)
        try? persistManifestLocked()
        try appendJSONLocked(evidence, to: evidencePath)
        return evidence
    }

    @discardableResult
    public func synthesize(maxEvidenceChars: Int = 24_000) throws -> String {
        let evidence = Self.loadEvidence(projectRoot: manifest.projectRoot, runID: manifest.runID)
        var lines: [String] = [
            "# Research Dossier",
            "",
            "- Run: \(manifest.runID)",
            "- Goal: \(manifest.goal)",
            "- Evidence items: \(evidence.count)",
            "",
            "## Evidence Index",
        ]
        for item in evidence {
            var row = "- [\(item.id)] \(item.kind): \(item.title)"
            if let url = item.url { row += " · \(url)" }
            if let path = item.path { row += " · \(path)" }
            lines.append(row)
        }
        lines += ["", "## Evidence Notes"]
        var budget = maxEvidenceChars
        for item in evidence {
            guard budget > 0 else { break }
            let excerpt = String(item.text.prefix(min(item.text.count, budget)))
            budget -= excerpt.count
            lines += [
                "",
                "### [\(item.id)] \(item.title)",
                "",
                excerpt.isEmpty ? "(empty evidence)" : excerpt,
            ]
        }
        if evidence.isEmpty {
            lines.append("")
            lines.append("No evidence gathered yet. Use research_run search/fetch/browse/context/add_evidence first.")
        }
        let report = lines.joined(separator: "\n") + "\n"
        let reportPath = runDirectory + "/report.md"
        try report.write(toFile: reportPath, atomically: true, encoding: .utf8)
        lock.lock()
        manifest.status = "synthesized"
        manifest.reportPath = ".kist/research-runs/\(manifest.runID)/report.md"
        manifest.updatedAt = now().timeIntervalSince1970
        try? persistManifestLocked()
        lock.unlock()
        return report
    }

    public static func loadEvidence(projectRoot: String, runID: String) -> [ResearchEvidence] {
        guard (try? validRunID(runID)) != nil else { return [] }
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let path = researchRoot(projectRoot: root) + "/" + runID + "/evidence.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(ResearchEvidence.self, from: Data(line.utf8))
        }
    }

    public static func loadHeartbeats(projectRoot: String, runID: String) -> [ResearchHeartbeat] {
        guard (try? validRunID(runID)) != nil else { return [] }
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let path = researchRoot(projectRoot: root) + "/" + runID + "/heartbeats.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(ResearchHeartbeat.self, from: Data(line.utf8))
        }
    }

    public static func renderStatus(projectRoot: String, runID: String) throws -> String {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let id = try validRunID(runID)
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath(projectRoot: root, runID: id)))
        let manifest = try JSONDecoder().decode(ResearchRunManifest.self, from: data)
        let evidence = loadEvidence(projectRoot: root, runID: id)
        let beats = loadHeartbeats(projectRoot: root, runID: id)
        var lines = [
            "Research \(manifest.runID) · \(manifest.status)",
            "Goal: \(manifest.goal)",
            "Evidence: \(evidence.count)",
            "Heartbeats: \(beats.count)",
        ]
        if let reportPath = manifest.reportPath { lines.append("Report: \(reportPath)") }
        if let last = beats.last { lines.append("Last: \(last.status) · \(last.message)") }
        return lines.joined(separator: "\n")
    }

    public static func researchRoot(projectRoot: String) -> String {
        (ToolContext.canonicalize(projectRoot) ?? projectRoot) + "/.kist/research-runs"
    }

    public static func manifestPath(projectRoot: String, runID: String) -> String {
        researchRoot(projectRoot: projectRoot) + "/" + runID + "/manifest.json"
    }

    public static func validRunID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(value.count) else { throw ToolError.execution("run_id must be 1-80 characters") }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ToolError.execution("run_id may contain only letters, numbers, underscore, and dash")
        }
        return value
    }

    private func persistManifest() throws {
        lock.lock()
        defer { lock.unlock() }
        try persistManifestLocked()
    }

    private func persistManifestLocked() throws {
        let data = try JSONEncoder().encode(manifest)
        try FileManager.default.createDirectory(atPath: runDirectory, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
    }

    private func appendJSONLocked<T: Encodable>(_ value: T, to path: String) throws {
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        var line = data
        line.append(0x0a)
        try handle.write(contentsOf: line)
    }

    private static func makeRunID() -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(ts)-\(suffix)"
    }

    private static func safeText(_ text: String) -> String {
        SecretScanner.redactSecrets(in: text)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
