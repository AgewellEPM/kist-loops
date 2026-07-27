import Foundation

/// Git version control tool with safety checks
/// Supports: status, add, commit, push, pull, branch, diff, log, checkout, fetch
final class GitTool: AgentTool {
    let name = "git"
    let description = "Git version control operations: status, add, commit, push, pull, branch, diff, log, checkout, fetch. Use for all git-related tasks."

    let parameters = [
        ToolParameter(name: "operation", type: "string",
                     description: "Git operation: status|add|commit|push|pull|branch|diff|log|checkout|fetch|stash",
                     required: true),
        ToolParameter(name: "message", type: "string",
                     description: "Commit message (required for commit operation)",
                     required: false),
        ToolParameter(name: "files", type: "string",
                     description: "Files to operate on (space-separated, defaults to '.' for add)",
                     required: false),
        ToolParameter(name: "args", type: "string",
                     description: "Additional arguments (e.g., 'origin main' for push, '-n 10' for log)",
                     required: false)
    ]

    // MARK: - Safety Configuration

    private let allowedOperations = Set([
        "status", "add", "commit", "push", "pull",
        "branch", "diff", "log", "checkout", "fetch",
        "stash", "show", "remote"
    ])

    private let blockedPatterns = [
        "--force", "-f", "--hard",
        "push -f", "push --force",
        "reset --hard",
        "branch -D",
        "clean -f"
    ]

    // MARK: - Execute

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        guard let operation = arguments["operation"] as? String else {
            return ToolResult(success: false, output: "", error: "Missing 'operation' parameter")
        }

        guard allowedOperations.contains(operation) else {
            return ToolResult(success: false, output: "",
                            error: "Unknown git operation: \(operation). Allowed: \(allowedOperations.sorted().joined(separator: ", "))")
        }

        let message = arguments["message"] as? String
        let files = arguments["files"] as? String
        let args = arguments["args"] as? String ?? ""

        // Safety check
        let safetyResult = checkSafety(operation: operation, args: args, message: message)
        if !safetyResult.isAllowed {
            return ToolResult(success: false, output: "",
                            error: "Safety check failed: \(safetyResult.reason ?? "Unknown")")
        }

        // Build and execute command
        let result: ToolResult
        switch operation {
        case "status":
            result = await executeGit(["status", "--porcelain=v2", "--branch"], at: projectPath)
        case "add":
            let filesToAdd = files?.components(separatedBy: " ") ?? ["."]
            result = await executeGit(["add"] + filesToAdd, at: projectPath)
        case "commit":
            guard let commitMessage = message, !commitMessage.isEmpty else {
                return ToolResult(success: false, output: "", error: "Commit requires a 'message' parameter")
            }
            result = await executeGit(["commit", "-m", commitMessage], at: projectPath)
        case "push":
            let pushArgs = args.isEmpty ? ["push"] : ["push"] + args.components(separatedBy: " ")
            result = await executeGit(pushArgs, at: projectPath)
        case "pull":
            let pullArgs = args.isEmpty ? ["pull"] : ["pull"] + args.components(separatedBy: " ")
            result = await executeGit(pullArgs, at: projectPath)
        case "branch":
            let branchArgs = args.isEmpty ? ["branch", "-a"] : ["branch"] + args.components(separatedBy: " ")
            result = await executeGit(branchArgs, at: projectPath)
        case "diff":
            var diffArgs = ["diff"]
            if !args.isEmpty {
                diffArgs.append(contentsOf: args.components(separatedBy: " "))
            }
            if let file = files {
                diffArgs.append(file)
            }
            result = await executeGit(diffArgs, at: projectPath)
        case "log":
            var logArgs = ["log", "--oneline"]
            if args.isEmpty {
                logArgs.append("-n")
                logArgs.append("20")
            } else {
                logArgs.append(contentsOf: args.components(separatedBy: " "))
            }
            result = await executeGit(logArgs, at: projectPath)
        case "checkout":
            guard !args.isEmpty else {
                return ToolResult(success: false, output: "", error: "Checkout requires branch name in 'args'")
            }
            // Check for uncommitted changes first
            let statusCheck = await executeGit(["status", "--porcelain"], at: projectPath)
            if statusCheck.success && !statusCheck.output.isEmpty {
                return ToolResult(success: false, output: statusCheck.output,
                                error: "Uncommitted changes detected. Commit or stash before checkout.")
            }
            result = await executeGit(["checkout"] + args.components(separatedBy: " "), at: projectPath)
        case "fetch":
            let fetchArgs = args.isEmpty ? ["fetch", "--all"] : ["fetch"] + args.components(separatedBy: " ")
            result = await executeGit(fetchArgs, at: projectPath)
        case "stash":
            let stashArgs = args.isEmpty ? ["stash"] : ["stash"] + args.components(separatedBy: " ")
            result = await executeGit(stashArgs, at: projectPath)
        case "show":
            let showArgs = args.isEmpty ? ["show", "--stat"] : ["show"] + args.components(separatedBy: " ")
            result = await executeGit(showArgs, at: projectPath)
        case "remote":
            let remoteArgs = args.isEmpty ? ["remote", "-v"] : ["remote"] + args.components(separatedBy: " ")
            result = await executeGit(remoteArgs, at: projectPath)
        default:
            return ToolResult(success: false, output: "", error: "Unhandled operation: \(operation)")
        }

        // Parse and enhance output for certain operations
        return enhanceResult(result, operation: operation)
    }

    // MARK: - Git Execution

    private func executeGit(_ arguments: [String], at projectPath: String) async -> ToolResult {
        // Find git executable
        guard let gitPath = findGitExecutable() else {
            return ToolResult(success: false, output: "", error: "Git executable not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            let success = process.terminationStatus == 0

            // Combine output for display
            var fullOutput = output
            if !errorOutput.isEmpty && !success {
                fullOutput += "\n\nError:\n\(errorOutput)"
            }

            // Truncate if too long
            if fullOutput.count > 10000 {
                fullOutput = String(fullOutput.prefix(10000)) + "\n... (truncated)"
            }

            return ToolResult(
                success: success,
                output: fullOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                error: success ? nil : errorOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                metadata: [
                    "exitCode": String(process.terminationStatus),
                    "command": "git \(arguments.joined(separator: " "))"
                ]
            )
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to execute git: \(error.localizedDescription)")
        }
    }

    private func findGitExecutable() -> String? {
        let paths = [
            "/usr/bin/git",
            "/usr/local/bin/git",
            "/opt/homebrew/bin/git"
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Try which
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["git"]
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        } catch {}

        return nil
    }

    // MARK: - Safety

    private struct SafetyResult {
        let isAllowed: Bool
        let reason: String?
        let warnings: [String]
    }

    private func checkSafety(operation: String, args: String, message: String?) -> SafetyResult {
        var warnings: [String] = []

        // Check for blocked patterns
        let fullCommand = "\(operation) \(args)"
        for blocked in blockedPatterns {
            if fullCommand.contains(blocked) {
                return SafetyResult(isAllowed: false, reason: "Blocked: '\(blocked)' is not allowed for safety", warnings: [])
            }
        }

        // Operation-specific checks
        switch operation {
        case "commit":
            if let msg = message {
                if msg.count < 3 {
                    return SafetyResult(isAllowed: false, reason: "Commit message too short (min 3 chars)", warnings: [])
                }
                if msg.count > 500 {
                    warnings.append("Commit message is very long (>500 chars)")
                }
            }
        case "push":
            if args.contains("--force") || args.contains("-f") {
                return SafetyResult(isAllowed: false, reason: "Force push is not allowed", warnings: [])
            }
        case "branch":
            if args.contains("-D") {
                return SafetyResult(isAllowed: false, reason: "Force delete branch (-D) is not allowed. Use -d for safe delete.", warnings: [])
            }
        default:
            break
        }

        return SafetyResult(isAllowed: true, reason: nil, warnings: warnings)
    }

    // MARK: - Output Enhancement

    private func enhanceResult(_ result: ToolResult, operation: String) -> ToolResult {
        guard result.success else { return result }

        var metadata = result.metadata ?? [:]

        switch operation {
        case "status":
            // Parse porcelain v2 output for structured data
            let lines = result.output.components(separatedBy: "\n")
            var staged = 0, modified = 0, untracked = 0
            var branch = ""

            for line in lines {
                if line.hasPrefix("# branch.head ") {
                    branch = String(line.dropFirst("# branch.head ".count))
                } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                    // Changed entry
                    let parts = line.components(separatedBy: " ")
                    if parts.count > 1 {
                        let xy = parts[1]
                        if xy.first != "." { staged += 1 }
                        if xy.dropFirst().first != "." { modified += 1 }
                    }
                } else if line.hasPrefix("? ") {
                    untracked += 1
                }
            }

            metadata["branch"] = branch
            metadata["staged"] = String(staged)
            metadata["modified"] = String(modified)
            metadata["untracked"] = String(untracked)

        case "commit":
            // Extract commit hash from output
            if let match = result.output.range(of: #"\[[\w-]+ ([a-f0-9]+)\]"#, options: .regularExpression) {
                let hashPart = result.output[match]
                if let hashMatch = hashPart.range(of: #"[a-f0-9]{7,}"#, options: .regularExpression) {
                    metadata["commitHash"] = String(hashPart[hashMatch])
                }
            }

        case "log":
            // Count commits in output
            let commitCount = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
            metadata["commitCount"] = String(commitCount)

        default:
            break
        }

        return ToolResult(
            success: result.success,
            output: result.output,
            error: result.error,
            metadata: metadata
        )
    }
}
