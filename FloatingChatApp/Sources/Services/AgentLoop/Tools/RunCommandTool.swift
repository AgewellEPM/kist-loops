import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.floatingchat.app", category: "RunCommand")

/// Tool to run shell commands - SECURITY HARDENED with streaming support
final class RunCommandTool: AgentTool {
    let name = "run_command"
    let description = "Run a shell command in the project directory. Use for git, swift, pod, or other CLI tools."
    let parameters = [
        ToolParameter(name: "command", type: "string", description: "Shell command to execute", required: true),
        ToolParameter(name: "timeout", type: "integer", description: "Timeout in seconds (default: 300 for builds, 60 otherwise)", required: false),
        ToolParameter(name: "stream", type: "boolean", description: "Stream output incrementally (default: true for long commands)", required: false)
    ]

    // Shared publisher for streaming command output
    static let outputStream = PassthroughSubject<CommandOutput, Never>()

    struct CommandOutput {
        let commandId: UUID
        let line: String
        let isError: Bool
        let timestamp: Date
    }

    // Commands that are allowed for safety
    private let allowedCommands: Set<String> = [
        "git", "swift", "xcodebuild", "xcodegen", "pod", "carthage", "mint",
        "swiftlint", "swiftformat", "ls", "cat", "head", "tail",
        "grep", "find", "wc", "diff", "echo", "pwd", "which",
        "mkdir", "cp", "mv", "rm", "touch", "chmod",
        "npm", "yarn", "node", "python3", "pip3",
        "open", "xcrun", "simctl", "instruments"
    ]

    // SECURITY: Dangerous patterns that should be blocked
    private let dangerousPatterns = [
        ";", "&&", "||", "|", "`", "$(",  // Shell metacharacters for command chaining
        ">", ">>", "<",                    // Redirects
        "sudo", "su ",                     // Privilege escalation
        "rm -rf /", "rm -rf ~",            // Dangerous deletions
        "../../../",                       // Excessive path traversal
        "/etc/", "/System/", "/Library/Preferences",  // System directories
        "curl | sh", "wget | sh", "bash <",  // Remote code execution
    ]

    // Commands that need longer timeouts (builds, package resolution, etc.)
    private let longRunningCommands: Set<String> = [
        "xcodebuild", "swift", "pod", "carthage", "npm", "yarn"
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let command = arguments["command"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing required parameter: command")
        }

        // Parse to determine if this is a long-running command
        let parsed = parseCommand(command)
        let isLongRunning = parsed.executable.map { longRunningCommands.contains($0) } ?? false

        // Use longer timeout for builds (5 min default, 60s for quick commands)
        let defaultTimeout = isLongRunning ? 300 : 60
        let timeout = arguments["timeout"] as? Int ?? defaultTimeout
        let shouldStream = arguments["stream"] as? Bool ?? isLongRunning

        let commandId = UUID()
        logger.info("Starting command [\(commandId.uuidString.prefix(8))]: \(command.prefix(50))... (timeout: \(timeout)s, streaming: \(shouldStream))")

        // SECURITY: Check for dangerous patterns
        for pattern in dangerousPatterns {
            if command.contains(pattern) {
                return ToolResult(
                    success: false,
                    output: "",
                    error: "Security: Command contains blocked pattern '\(pattern)'. Shell metacharacters and chaining are not allowed."
                )
            }
        }

        guard let executable = parsed.executable else {
            return ToolResult(success: false, output: "", error: "Could not parse command")
        }

        // Check if command is allowed
        guard allowedCommands.contains(executable) else {
            return ToolResult(
                success: false,
                output: "",
                error: "Command '\(executable)' is not in the allowed list. Allowed: \(allowedCommands.sorted().joined(separator: ", "))"
            )
        }

        // SECURITY: Find the actual executable path instead of using shell
        let executablePath = findExecutable(executable)
        guard let path = executablePath else {
            return ToolResult(
                success: false,
                output: "",
                error: "Could not find executable '\(executable)' in PATH"
            )
        }

        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = parsed.arguments  // Direct arguments, no shell interpretation

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        // Collected output for streaming
        var collectedOutput = ""
        var collectedError = ""
        var timedOut = false

        // Setup streaming handlers if enabled
        if shouldStream {
            outputPipe.fileHandleForReading.readabilityHandler = { [commandId] handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    collectedOutput += str
                    // Publish each line for UI
                    for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                        RunCommandTool.outputStream.send(CommandOutput(
                            commandId: commandId,
                            line: String(line),
                            isError: false,
                            timestamp: Date()
                        ))
                    }
                }
            }

            errorPipe.fileHandleForReading.readabilityHandler = { [commandId] handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    collectedError += str
                    for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                        RunCommandTool.outputStream.send(CommandOutput(
                            commandId: commandId,
                            line: String(line),
                            isError: true,
                            timestamp: Date()
                        ))
                    }
                }
            }
        }

        let startTime = Date()

        do {
            try process.run()
            logger.info("Process started with PID \(process.processIdentifier)")
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to execute command: \(error.localizedDescription)")
        }

        // Wait with timeout - check periodically instead of blocking completely
        let checkInterval: UInt64 = 1_000_000_000 // 1 second
        var elapsedChecks = 0
        let maxChecks = timeout

        while process.isRunning && elapsedChecks < maxChecks {
            try? await Task.sleep(nanoseconds: checkInterval)
            elapsedChecks += 1

            // Log progress for long-running commands
            if elapsedChecks % 10 == 0 && isLongRunning {
                logger.info("Command still running... (\(elapsedChecks)s elapsed)")
            }
        }

        // Clean up streaming handlers
        if shouldStream {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
        }

        // Check if we timed out
        if process.isRunning {
            logger.warning("Command timed out after \(timeout) seconds, terminating...")
            process.terminate()
            timedOut = true
            // Give it a moment to terminate
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process.isRunning {
                process.interrupt()
            }
        }

        let duration = Date().timeIntervalSince(startTime)

        if timedOut {
            // Include partial output even on timeout
            let partialOutput = collectedOutput.isEmpty ?
                (String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "") :
                collectedOutput
            return ToolResult(
                success: false,
                output: partialOutput.isEmpty ? "" : "Partial output before timeout:\n\(partialOutput.prefix(5000))",
                error: "Command timed out after \(timeout) seconds. For long builds, try increasing the timeout.",
                metadata: [
                    "command": command,
                    "timed_out": "true",
                    "duration": String(format: "%.2fs", duration)
                ]
            )
        }

        // Get any remaining output
        if !shouldStream {
            collectedOutput = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            collectedError = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }

        let success = process.terminationStatus == 0

        var fullOutput = collectedOutput
        if !collectedError.isEmpty && !success {
            fullOutput += "\n\nSTDERR:\n" + collectedError
        }

        // Truncate very long output
        if fullOutput.count > 10000 {
            fullOutput = String(fullOutput.prefix(5000)) + "\n\n... (output truncated) ...\n\n" + String(fullOutput.suffix(2000))
        }

        logger.info("Command completed: exit=\(process.terminationStatus), duration=\(String(format: "%.2fs", duration))")

        return ToolResult(
            success: success,
            output: fullOutput,
            error: success ? nil : "Command exited with code \(process.terminationStatus)",
            metadata: [
                "command": command,
                "executable": path,
                "exit_code": String(process.terminationStatus),
                "duration": String(format: "%.2fs", duration)
            ]
        )
    }

    // MARK: - Parsing Helpers

    /// Parse a command string into executable and arguments
    /// Handles quoted strings properly
    private func parseCommand(_ command: String) -> (executable: String?, arguments: [String]) {
        var args: [String] = []
        var current = ""
        var inQuote = false
        var quoteChar: Character = "\""

        for char in command {
            if inQuote {
                if char == quoteChar {
                    inQuote = false
                } else {
                    current.append(char)
                }
            } else {
                switch char {
                case "\"", "'":
                    inQuote = true
                    quoteChar = char
                case " ", "\t":
                    if !current.isEmpty {
                        args.append(current)
                        current = ""
                    }
                default:
                    current.append(char)
                }
            }
        }

        if !current.isEmpty {
            args.append(current)
        }

        guard !args.isEmpty else {
            return (nil, [])
        }

        let executable = args.removeFirst()
        return (executable, args)
    }

    /// Find the full path to an executable
    private func findExecutable(_ name: String) -> String? {
        // Common locations
        let searchPaths = [
            "/usr/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/bin",
            "/usr/sbin"
        ]

        for path in searchPaths {
            let fullPath = "\(path)/\(name)"
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        // Try using 'which' as fallback
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !path.isEmpty {
                    return path
                }
            }
        } catch {
            // Ignore errors from which
        }

        return nil
    }
}
