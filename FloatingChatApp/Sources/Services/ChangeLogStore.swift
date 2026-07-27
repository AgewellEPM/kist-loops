import Foundation

/// Tracks file changes and build results during a session for synopsis generation
@MainActor
final class ChangeLogStore: ObservableObject {
    static let shared = ChangeLogStore()

    // MARK: - Published State

    @Published private(set) var fileEdits: [FileEdit] = []
    @Published private(set) var fileWrites: [FileWrite] = []
    @Published private(set) var buildResults: [BuildResult] = []
    @Published private(set) var sessionStarted: Date = Date()

    // MARK: - Models

    struct FileEdit: Identifiable, Codable {
        let id: UUID
        let path: String
        let lineDiff: Int
        let timestamp: Date

        init(path: String, lineDiff: Int) {
            self.id = UUID()
            self.path = path
            self.lineDiff = lineDiff
            self.timestamp = Date()
        }

        var fileName: String {
            URL(fileURLWithPath: path).lastPathComponent
        }
    }

    struct FileWrite: Identifiable, Codable {
        let id: UUID
        let path: String
        let resolvedPath: String
        let action: String  // "created" or "updated"
        let lineCount: Int
        let byteCount: Int
        let timestamp: Date

        init(path: String, resolved: String, action: String, lines: Int, bytes: Int) {
            self.id = UUID()
            self.path = path
            self.resolvedPath = resolved
            self.action = action
            self.lineCount = lines
            self.byteCount = bytes
            self.timestamp = Date()
        }

        var fileName: String {
            URL(fileURLWithPath: path).lastPathComponent
        }
    }

    struct BuildResult: Identifiable, Codable {
        let id: UUID
        let success: Bool
        let errorCount: Int
        let warningCount: Int
        let duration: String
        let scheme: String
        let configuration: String
        let timestamp: Date

        init(success: Bool, errors: Int, warnings: Int, duration: String, scheme: String, configuration: String) {
            self.id = UUID()
            self.success = success
            self.errorCount = errors
            self.warningCount = warnings
            self.duration = duration
            self.scheme = scheme
            self.configuration = configuration
            self.timestamp = Date()
        }
    }

    // MARK: - Initialization

    private init() {}

    // MARK: - Logging Methods

    /// Log a file edit
    func logEdit(path: String, lineDiff: Int) {
        let edit = FileEdit(path: path, lineDiff: lineDiff)
        fileEdits.append(edit)

        // Also feed to frontal cortex
        FrontalCortex.shared.store(
            content: "Edited file: \(edit.fileName) (\(lineDiff >= 0 ? "+" : "")\(lineDiff) lines)",
            category: .task,
            importance: 0.5,
            tags: ["file-edit", edit.fileName]
        )
    }

    /// Log a file write (new file creation or update)
    func logWrite(path: String, resolved: String, action: String, lines: Int, bytes: Int) {
        let write = FileWrite(path: path, resolved: resolved, action: action, lines: lines, bytes: bytes)
        fileWrites.append(write)

        // Also feed to frontal cortex
        let actionVerb = action == "created" ? "Created" : "Updated"
        FrontalCortex.shared.store(
            content: "\(actionVerb) file: \(write.fileName) (\(lines) lines, \(bytes) bytes)",
            category: .task,
            importance: action == "created" ? 0.6 : 0.5,
            tags: ["file-write", action, write.fileName]
        )
    }

    /// Log a build result
    func logBuild(success: Bool, errors: Int, warnings: Int, duration: String, scheme: String, configuration: String, raw: String = "") {
        let result = BuildResult(
            success: success,
            errors: errors,
            warnings: warnings,
            duration: duration,
            scheme: scheme,
            configuration: configuration
        )
        buildResults.append(result)

        // Feed to frontal cortex
        let status = success ? "successful" : "failed"
        FrontalCortex.shared.store(
            content: "Build \(status): \(scheme) (\(configuration)) - \(errors) errors, \(warnings) warnings in \(duration)",
            category: success ? .task : .error,
            importance: success ? 0.4 : 0.7,
            tags: ["build", status, scheme]
        )

        // If build failed, store error info for learning
        if !success && !raw.isEmpty {
            // Extract first few error lines for context
            let errorLines = raw.components(separatedBy: .newlines)
                .filter { $0.contains("error:") }
                .prefix(3)
                .joined(separator: "\n")

            if !errorLines.isEmpty {
                FrontalCortex.shared.store(
                    content: "Build errors: \(errorLines)",
                    category: .error,
                    importance: 0.6,
                    tags: ["build-error", scheme]
                )
            }
        }
    }

    // MARK: - Synopsis Generation

    /// Generate a synopsis of changes for this session
    func generateSynopsis() -> String {
        var synopsis = ""

        // File edits summary
        if !fileEdits.isEmpty {
            let uniqueFiles = Set(fileEdits.map { $0.fileName })
            let totalLines = fileEdits.reduce(0) { $0 + $1.lineDiff }

            synopsis += "Files Modified: \(uniqueFiles.count)\n"
            synopsis += "Net Line Change: \(totalLines >= 0 ? "+" : "")\(totalLines)\n"

            // List files
            for file in uniqueFiles.sorted() {
                let edits = fileEdits.filter { $0.fileName == file }
                let lineChange = edits.reduce(0) { $0 + $1.lineDiff }
                synopsis += "  - \(file) (\(lineChange >= 0 ? "+" : "")\(lineChange))\n"
            }
        }

        // Build results summary
        if !buildResults.isEmpty {
            let successCount = buildResults.filter { $0.success }.count
            let failCount = buildResults.count - successCount

            synopsis += "\nBuilds: \(successCount) successful, \(failCount) failed\n"

            if let lastBuild = buildResults.last {
                synopsis += "Last Build: \(lastBuild.success ? "✓" : "✗") \(lastBuild.scheme) (\(lastBuild.duration))\n"
            }
        }

        return synopsis.isEmpty ? "No changes logged." : synopsis
    }

    /// Get count of successful builds
    var successfulBuildCount: Int {
        buildResults.filter { $0.success }.count
    }

    /// Get count of failed builds
    var failedBuildCount: Int {
        buildResults.filter { !$0.success }.count
    }

    /// Get unique files edited
    var uniqueFilesEdited: Set<String> {
        Set(fileEdits.map { $0.fileName })
    }

    /// Get summary as markdown for inclusion in prompts
    var summaryMarkdown: String {
        var md = ""

        // File writes
        if !fileWrites.isEmpty {
            md += "**Created Files:**\n"
            for write in fileWrites {
                md += "- `\(write.fileName)` (\(write.lineCount) lines)\n"
            }
            md += "\n"
        }

        // File edits
        if !fileEdits.isEmpty {
            let uniqueFiles = Set(fileEdits.map { $0.fileName })
            md += "**Modified Files:**\n"
            for file in uniqueFiles.sorted() {
                let edits = fileEdits.filter { $0.fileName == file }
                let lineChange = edits.reduce(0) { $0 + $1.lineDiff }
                md += "- `\(file)` (\(lineChange >= 0 ? "+" : "")\(lineChange) lines)\n"
            }
            md += "\n"
        }

        // Build results
        if !buildResults.isEmpty {
            let successCount = buildResults.filter { $0.success }.count
            let failCount = buildResults.count - successCount
            md += "**Build Status:** \(successCount) successful, \(failCount) failed\n"
        }

        return md
    }

    // MARK: - Session Management

    /// Clear all logs for new session
    func clearSession() {
        fileEdits = []
        fileWrites = []
        buildResults = []
        sessionStarted = Date()
    }

    /// Get session duration
    var sessionDuration: TimeInterval {
        Date().timeIntervalSince(sessionStarted)
    }

    /// Get formatted session duration
    var formattedSessionDuration: String {
        let duration = sessionDuration
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
