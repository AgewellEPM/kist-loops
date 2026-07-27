import Foundation
import AgentCore

/// Durable, local replay ledger for a Kist run. The calm terminal view stays compact, while this
/// store persists the same proof stream under `.kist/runs/<id>/` so a run can be inspected later.
/// It is intentionally fact-only: events, tool names, outputs/errors, approvals surfaced by sinks.
/// Correctness still comes from tests/critics/signoff, not from a trace existing.
final class RunReplayStore: @unchecked Sendable {
    struct Manifest: Codable, Equatable {
        let runID: String
        let projectRoot: String
        let provider: String
        let model: String?
        let createdAt: Double
    }

    struct Event: Codable, Equatable {
        let sequence: Int
        let turnID: String
        let at: Double
        let kind: String
        let tool: String?
        let success: Bool?
        let text: String
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var sequence = 0
    private var currentTurnID = UUID().uuidString

    let manifest: Manifest
    let runDirectory: String
    let eventsPath: String

    init(projectRoot: String, provider: String, model: String?, runID: String? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        self.manifest = Manifest(runID: runID ?? RunReplayStore.makeRunID(), projectRoot: root, provider: provider, model: model,
                                 createdAt: now().timeIntervalSince1970)
        self.runDirectory = Self.runsRoot(projectRoot: root) + "/" + manifest.runID
        self.eventsPath = runDirectory + "/events.jsonl"
        try? FileManager.default.createDirectory(atPath: runDirectory, withIntermediateDirectories: true)
        persistManifest()
    }

    func startTurn(goal: String) {
        lock.lock()
        currentTurnID = UUID().uuidString
        lock.unlock()
        append(kind: "turnStarted", tool: nil, success: nil, text: goal)
    }

    func record(_ entry: TurnProofStore.Entry) {
        append(kind: entry.kind.rawValue, tool: entry.tool, success: entry.success, text: entry.text)
    }

    private func append(kind: String, tool: String?, success: Bool?, text: String) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        let event = Event(sequence: sequence, turnID: currentTurnID, at: now().timeIntervalSince1970,
                          kind: kind, tool: tool, success: success, text: Self.safeText(text))

        guard let data = try? JSONEncoder().encode(event) else { return }
        var line = data
        line.append(0x0a)
        do {
            if !FileManager.default.fileExists(atPath: eventsPath) {
                FileManager.default.createFile(atPath: eventsPath, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: eventsPath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // Replay is evidence, not the action path. Never fail the agent because local evidence
            // persistence hit a transient filesystem issue.
        }
    }

    private func persistManifest() {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? FileManager.default.createDirectory(atPath: runDirectory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.manifestPath(projectRoot: manifest.projectRoot,
                                                                  runID: manifest.runID)),
                        options: [.atomic])
    }

    static func render(projectRoot: String, id: String? = nil, limit: Int = 120) -> String {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let selected: String
        if let id, !id.isEmpty, id != "latest" {
            guard isValidRunID(id) else { return "Invalid replay id '\(id)'." }
            selected = id
        } else {
            selected = latestRunID(projectRoot: root) ?? ""
        }
        guard !selected.isEmpty else { return "No replay runs found in .kist/runs yet." }
        let manifestPath = manifestPath(projectRoot: root, runID: selected)
        guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
            return "Replay '\(selected)' not found."
        }
        let events = loadEvents(projectRoot: root, runID: selected)
        var lines: [String] = []
        lines.append("Replay \(manifest.runID)")
        lines.append("Project: \(manifest.projectRoot)")
        lines.append("Model: \(manifest.provider)\(manifest.model.map { ":\($0)" } ?? "")")
        lines.append("Path: \(runsRoot(projectRoot: root))/\(manifest.runID)")
        lines.append("Events: \(events.count)")
        for event in events.prefix(limit) {
            let mark: String
            if let success = event.success { mark = success ? "ok" : "failed" }
            else { mark = event.kind }
            let tool = event.tool.map { " \($0)" } ?? ""
            lines.append(String(format: "%04d %@%@ - %@", event.sequence, mark, tool,
                                oneLine(event.text, max: 260)))
        }
        if events.count > limit { lines.append("... \(events.count - limit) more event(s)") }
        return lines.joined(separator: "\n")
    }

    static func latestRunID(projectRoot: String) -> String? {
        let root = ToolContext.canonicalize(projectRoot) ?? projectRoot
        let dir = runsRoot(projectRoot: root)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return entries.compactMap { name -> (String, Date)? in
            guard isValidRunID(name) else { return nil }
            let path = manifestPath(projectRoot: root, runID: name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return (name, modified)
        }.sorted { $0.1 > $1.1 }.first?.0
    }

    static func loadEvents(projectRoot: String, runID: String) -> [Event] {
        guard isValidRunID(runID) else { return [] }
        let path = runsRoot(projectRoot: projectRoot) + "/" + runID + "/events.jsonl"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(Event.self, from: Data(line.utf8))
        }
    }

    static func runsRoot(projectRoot: String) -> String {
        (ToolContext.canonicalize(projectRoot) ?? projectRoot) + "/.kist/runs"
    }

    static func manifestPath(projectRoot: String, runID: String) -> String {
        runsRoot(projectRoot: projectRoot) + "/" + runID + "/manifest.json"
    }

    static func isValidRunID(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == raw, (1...96).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
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

    private static func oneLine(_ text: String, max: Int) -> String {
        let compact = safeText(text)
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > max else { return compact.isEmpty ? "(empty)" : compact }
        return String(compact.prefix(max - 1)) + "..."
    }
}
