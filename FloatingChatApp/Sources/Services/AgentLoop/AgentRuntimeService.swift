import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "AgentRuntime")

/// The missing piece that makes this a Claude Code wrapper, not just a chat app.
/// Provides:
/// 1. Auto-build after file changes
/// 2. Error parsing and auto-retry loop
/// 3. Project state persistence
/// 4. Validation loop (build → test → fix)
@MainActor
final class AgentRuntimeService: ObservableObject {
    static let shared = AgentRuntimeService()

    // MARK: - Configuration

    @Published var autoBuildEnabled: Bool = true
    @Published var autoRetryOnFailure: Bool = true
    @Published var maxRetryAttempts: Int = 3
    @Published var currentProjectPath: String = ""

    // MARK: - State

    @Published private(set) var pendingBuild: Bool = false
    @Published private(set) var currentRetryAttempt: Int = 0
    @Published private(set) var lastBuildErrors: [BuildError] = []
    @Published private(set) var projectState: ProjectState?

    // Files that trigger auto-build when modified
    private let buildTriggerExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cpp", "xib", "storyboard"
    ]

    // Queue of files changed since last build
    private var changedFilesSinceLastBuild: Set<String> = []

    // Debounce timer for builds
    private var buildDebounceTask: Task<Void, Never>?

    private init() {
        loadProjectState()
    }

    // MARK: - Tool Execution Hook

    /// Wraps tool execution with runtime behavior (auto-build, retry)
    /// Call this from AgentLoopEngine instead of direct tool execution
    func executeWithRuntime(
        tool: AgentTool,
        arguments: [String: Any],
        projectPath: String
    ) async throws -> ToolResult {
        // Update project path if needed
        if currentProjectPath != projectPath {
            currentProjectPath = projectPath
            loadProjectState()
        }

        // Execute the tool
        let result = try await tool.execute(arguments: arguments, projectPath: projectPath)

        // Post-execution hooks based on tool name
        switch tool.name {
        case "write_file":
            if result.success, let path = arguments["path"] as? String {
                await handleFileChange(path: path, projectPath: projectPath)
            }

        case "edit_file":
            if result.success, let path = arguments["path"] as? String {
                await handleFileChange(path: path, projectPath: projectPath)
            }

        case "run_build":
            // Store build result for potential retry
            await handleBuildResult(result)

        default:
            break
        }

        return result
    }

    // MARK: - File Change Handling

    private func handleFileChange(path: String, projectPath: String) async {
        let ext = (path as NSString).pathExtension.lowercased()

        // Track changed file
        changedFilesSinceLastBuild.insert(path)

        // Save to project state
        projectState?.addChangedFile(path)
        saveProjectState()

        // Auto-build if enabled and file type triggers build
        guard autoBuildEnabled && buildTriggerExtensions.contains(ext) else {
            return
        }

        scheduleBuildDebounce(projectPath: projectPath)
        logger.info("File changed: \(path) - auto-build queued")
    }

    /// Schedule (or reschedule) the debounced auto-build. Extracted so it can be
    /// exercised + cancelled deterministically in tests.
    func scheduleBuildDebounce(projectPath: String) {
        buildDebounceTask?.cancel()
        buildDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            if !Task.isCancelled {
                await triggerAutoBuild(projectPath: projectPath)
            }
        }
    }

    // MARK: - Auto Build

    private func triggerAutoBuild(projectPath: String) async {
        pendingBuild = true
        currentRetryAttempt = 0

        logger.info("Auto-build triggered for \(self.changedFilesSinceLastBuild.count) changed files")

        // Execute build
        let buildTool = RunBuildTool()
        do {
            let result = try await buildTool.execute(
                arguments: ["configuration": "Debug"],
                projectPath: projectPath
            )

            await handleBuildResult(result)

            // Clear changed files on successful build
            if result.success {
                changedFilesSinceLastBuild.removeAll()
            }
        } catch {
            logger.error("Auto-build failed: \(error.localizedDescription)")
        }

        pendingBuild = false
    }

    // MARK: - Build Result Handling

    private func handleBuildResult(_ result: ToolResult) async {
        if result.success {
            lastBuildErrors = []
            currentRetryAttempt = 0

            // Update project state
            projectState?.lastSuccessfulBuild = Date()
            projectState?.consecutiveFailures = 0
            saveProjectState()

            logger.info("Build succeeded")
        } else {
            // Parse errors from result
            lastBuildErrors = parseBuildErrors(from: result.output)

            // Update project state
            projectState?.consecutiveFailures += 1
            projectState?.lastBuildErrors = lastBuildErrors.map { $0.description }
            saveProjectState()

            logger.warning("Build failed with \(self.lastBuildErrors.count) errors")
        }
    }

    // MARK: - Error Parsing

    struct BuildError: Identifiable, CustomStringConvertible {
        let id = UUID()
        let file: String
        let line: Int
        let column: Int?
        let message: String
        let type: ErrorType

        enum ErrorType: String {
            case error
            case warning
        }

        var description: String {
            let col = column.map { ":\($0)" } ?? ""
            return "\(file):\(line)\(col): \(type.rawValue): \(message)"
        }

        /// Generate a prompt for the agent to fix this error
        var fixPrompt: String {
            """
            Fix the build error in \(file) at line \(line):
            \(message)

            1. Read the file to understand the context
            2. Make the minimal edit to fix the error
            3. Do not change any other code
            """
        }
    }

    private func parseBuildErrors(from output: String) -> [BuildError] {
        var errors: [BuildError] = []

        // Pattern: /path/file.swift:123:45: error: message
        let pattern = #"(.+\.(?:swift|m|mm|h|c|cpp)):(\d+):(?:(\d+):)?\s*(error|warning):\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return errors
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)

        for match in matches {
            guard let fileRange = Range(match.range(at: 1), in: output),
                  let lineRange = Range(match.range(at: 2), in: output),
                  let typeRange = Range(match.range(at: 4), in: output),
                  let messageRange = Range(match.range(at: 5), in: output) else {
                continue
            }

            let file = String(output[fileRange])
            let line = Int(output[lineRange]) ?? 0
            let column: Int? = {
                guard let colRange = Range(match.range(at: 3), in: output) else { return nil }
                return Int(output[colRange])
            }()
            let typeStr = String(output[typeRange])
            let message = String(output[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            let errorType: BuildError.ErrorType = typeStr == "error" ? .error : .warning

            errors.append(BuildError(
                file: file,
                line: line,
                column: column,
                message: message,
                type: errorType
            ))
        }

        return errors
    }

    // MARK: - Auto-Retry Logic

    /// Returns a prompt for the agent to fix current build errors
    /// Returns nil if no retry needed or max attempts reached
    func getRetryPrompt() -> String? {
        guard autoRetryOnFailure,
              !lastBuildErrors.isEmpty,
              currentRetryAttempt < maxRetryAttempts else {
            return nil
        }

        currentRetryAttempt += 1

        let errorPrompts = lastBuildErrors
            .filter { $0.type == .error }
            .prefix(5)
            .map { $0.fixPrompt }
            .joined(separator: "\n\n---\n\n")

        return """
        BUILD FAILED - Auto-retry attempt \(currentRetryAttempt)/\(maxRetryAttempts)

        The build failed with \(lastBuildErrors.count) error(s). Fix them:

        \(errorPrompts)

        After fixing, the build will run automatically.
        """
    }

    /// Check if there are errors that need to be fixed
    var hasPendingErrors: Bool {
        !lastBuildErrors.isEmpty && lastBuildErrors.contains { $0.type == .error }
    }

    // MARK: - Snapshot / Restore (sub-team isolation)

    /// Captures the mutable build/retry state so a nested sub-team run can be
    /// bracketed and its mutations rolled back — preventing a child's build
    /// errors / retry budget from bleeding into the parent (Codex HIGH).
    struct RuntimeSnapshot {
        let currentProjectPath: String
        let pendingBuild: Bool
        let currentRetryAttempt: Int
        let lastBuildErrors: [BuildError]
        let projectState: ProjectState?
        let changedFiles: Set<String>
    }

    func captureSnapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            currentProjectPath: currentProjectPath,
            pendingBuild: pendingBuild,
            currentRetryAttempt: currentRetryAttempt,
            lastBuildErrors: lastBuildErrors,
            projectState: projectState,
            changedFiles: changedFilesSinceLastBuild
        )
    }

    /// True if a debounced auto-build is pending (test/observability probe).
    var hasPendingAutoBuild: Bool { buildDebounceTask != nil }

    func restoreSnapshot(_ snapshot: RuntimeSnapshot) {
        // Cancel any debounce a child scheduled during the bracketed run, or it
        // would fire after restore and re-mutate the singleton (Codex HIGH-2).
        buildDebounceTask?.cancel()
        buildDebounceTask = nil
        currentProjectPath = snapshot.currentProjectPath
        pendingBuild = snapshot.pendingBuild
        currentRetryAttempt = snapshot.currentRetryAttempt
        lastBuildErrors = snapshot.lastBuildErrors
        projectState = snapshot.projectState
        changedFilesSinceLastBuild = snapshot.changedFiles
    }

    // MARK: - Project State Persistence

    struct ProjectState: Codable {
        var projectPath: String
        var lastSuccessfulBuild: Date?
        var lastBuildErrors: [String]
        var consecutiveFailures: Int
        var changedFiles: [String]
        var createdAt: Date
        var updatedAt: Date

        init(projectPath: String) {
            self.projectPath = projectPath
            self.lastSuccessfulBuild = nil
            self.lastBuildErrors = []
            self.consecutiveFailures = 0
            self.changedFiles = []
            self.createdAt = Date()
            self.updatedAt = Date()
        }

        mutating func addChangedFile(_ path: String) {
            if !changedFiles.contains(path) {
                changedFiles.append(path)
            }
            updatedAt = Date()
        }
    }

    private var stateFilePath: String {
        (currentProjectPath as NSString).appendingPathComponent(".agent_state.json")
    }

    private func loadProjectState() {
        guard !currentProjectPath.isEmpty else {
            projectState = nil
            return
        }

        let path = stateFilePath

        if FileManager.default.fileExists(atPath: path) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                projectState = try JSONDecoder().decode(ProjectState.self, from: data)
                logger.info("Loaded project state from \(path)")
            } catch {
                logger.warning("Failed to load project state: \(error.localizedDescription)")
                projectState = ProjectState(projectPath: currentProjectPath)
            }
        } else {
            projectState = ProjectState(projectPath: currentProjectPath)
        }
    }

    func saveProjectState() {
        guard var state = projectState else { return }

        state.updatedAt = Date()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: URL(fileURLWithPath: stateFilePath))

            projectState = state
            logger.info("Saved project state")
        } catch {
            logger.error("Failed to save project state: \(error.localizedDescription)")
        }
    }

    // MARK: - Validation Loop

    /// Run a full validation loop: build → test → report
    func runValidationLoop(projectPath: String) async -> ValidationResult {
        var result = ValidationResult()

        // Step 1: Build
        let buildTool = RunBuildTool()
        do {
            let buildResult = try await buildTool.execute(
                arguments: ["configuration": "Debug"],
                projectPath: projectPath
            )

            result.buildSuccess = buildResult.success
            result.buildOutput = buildResult.output

            if !buildResult.success {
                result.errors.append(contentsOf: lastBuildErrors.map { $0.description })
                return result
            }
        } catch {
            result.buildSuccess = false
            result.errors.append("Build failed: \(error.localizedDescription)")
            return result
        }

        // Step 2: Run tests (if available)
        let testTool = RunTestsTool()
        do {
            let testResult = try await testTool.execute(
                arguments: [:],
                projectPath: projectPath
            )

            result.testsRun = true
            result.testsSuccess = testResult.success
            result.testOutput = testResult.output
        } catch {
            result.testsRun = false
        }

        return result
    }

    struct ValidationResult {
        var buildSuccess: Bool = false
        var buildOutput: String = ""
        var testsRun: Bool = false
        var testsSuccess: Bool = false
        var testOutput: String = ""
        var errors: [String] = []

        var isFullyValid: Bool {
            buildSuccess && (!testsRun || testsSuccess)
        }

        var summary: String {
            var lines: [String] = []

            lines.append(buildSuccess ? "✅ Build: PASSED" : "❌ Build: FAILED")

            if testsRun {
                lines.append(testsSuccess ? "✅ Tests: PASSED" : "❌ Tests: FAILED")
            }

            if !errors.isEmpty {
                lines.append("\nErrors:")
                for error in errors.prefix(5) {
                    lines.append("  • \(error)")
                }
            }

            return lines.joined(separator: "\n")
        }
    }
}

