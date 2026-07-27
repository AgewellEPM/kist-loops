import Foundation

/// Tool to run xcodebuild
final class RunBuildTool: AgentTool {
    let name = "run_build"
    let description = "Build the Xcode project using xcodebuild. Returns build output including any errors."
    let parameters = [
        ToolParameter(name: "scheme", type: "string", description: "Build scheme name (optional, uses default if not specified)", required: false),
        ToolParameter(name: "configuration", type: "string", description: "Build configuration: Debug or Release (default: Debug)", required: false),
        ToolParameter(name: "clean", type: "boolean", description: "Clean before building (default: false)", required: false)
    ]

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        let scheme = arguments["scheme"] as? String ?? ""
        let configuration = arguments["configuration"] as? String ?? "Debug"
        let clean = arguments["clean"] as? Bool ?? false

        // Find xcodeproj or xcworkspace
        let projectFiles = try FileManager.default.contentsOfDirectory(atPath: projectPath)
        let workspace = projectFiles.first { $0.hasSuffix(".xcworkspace") }
        let xcodeproj = projectFiles.first { $0.hasSuffix(".xcodeproj") }

        var args: [String] = []

        if let workspace = workspace {
            args.append(contentsOf: ["-workspace", workspace])
        } else if let xcodeproj = xcodeproj {
            args.append(contentsOf: ["-project", xcodeproj])
        }

        if !scheme.isEmpty {
            args.append(contentsOf: ["-scheme", scheme])
        }

        args.append(contentsOf: ["-configuration", configuration])

        if clean {
            args.append("clean")
        }
        args.append("build")

        // Run xcodebuild
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        process.arguments = args

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let startTime = Date()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ToolResult(success: false, output: "", error: "Failed to run xcodebuild: \(error.localizedDescription)")
        }

        let duration = Date().timeIntervalSince(startTime)

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        let fullOutput = output + "\n" + errorOutput

        let success = process.terminationStatus == 0

        // Parse errors and warnings
        let errors = parseErrors(from: fullOutput)
        let warnings = parseWarnings(from: fullOutput)

        var resultOutput = ""

        if success {
            resultOutput = "✅ BUILD SUCCEEDED"
            if !warnings.isEmpty {
                resultOutput += "\n\n⚠️ Warnings (\(warnings.count)):\n"
                resultOutput += warnings.prefix(5).joined(separator: "\n")
                if warnings.count > 5 {
                    resultOutput += "\n... and \(warnings.count - 5) more"
                }
            }
        } else {
            resultOutput = "❌ BUILD FAILED\n\n"
            if !errors.isEmpty {
                resultOutput += "Errors (\(errors.count)):\n"
                for error in errors.prefix(10) {
                    resultOutput += "  \(error.file):\(error.line): \(error.message)\n"
                }
                if errors.count > 10 {
                    resultOutput += "... and \(errors.count - 10) more errors"
                }
            } else {
                // Show raw output if no parsed errors
                resultOutput += fullOutput.suffix(2000)
            }
        }

        // Log build summary for synopsis
        await MainActor.run {
            ChangeLogStore.shared.logBuild(
                success: success,
                errors: errors.count,
                warnings: warnings.count,
                duration: String(format: "%.1fs", duration),
                scheme: scheme.isEmpty ? "default" : scheme,
                configuration: configuration,
                raw: fullOutput
            )
        }

        return ToolResult(
            success: success,
            output: resultOutput,
            error: success ? nil : "Build failed with \(errors.count) error(s)",
            metadata: [
                "duration": String(format: "%.1fs", duration),
                "errors": String(errors.count),
                "warnings": String(warnings.count),
                "scheme": scheme.isEmpty ? "default" : scheme,
                "configuration": configuration
            ]
        )
    }

    private struct BuildError {
        let file: String
        let line: Int
        let message: String
    }

    private func parseErrors(from output: String) -> [BuildError] {
        var errors: [BuildError] = []

        // Pattern matches: /path/file.swift:123:45: error: message
        // Groups: 1=filepath, 2=line, 3=column(optional), 4=message
        // Using non-capturing group (?:...) for extension to avoid capturing it
        let pattern = #"(.+\.(?:swift|m|mm|h|c|cpp)):(\d+):(?:(\d+):)?\s*error:\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return errors
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)

        for match in matches {
            guard let fileRange = Range(match.range(at: 1), in: output),
                  let lineRange = Range(match.range(at: 2), in: output),
                  let messageRange = Range(match.range(at: 4), in: output) else {
                continue
            }

            let file = String(output[fileRange])
            let line = Int(output[lineRange]) ?? 0
            let message = String(output[messageRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            errors.append(BuildError(file: file, line: line, message: message))
        }

        return errors
    }

    private func parseWarnings(from output: String) -> [String] {
        var warnings: [String] = []

        // Fixed: In raw strings, use single backslash (not \\)
        let pattern = #"warning:\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return warnings
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)

        for match in matches {
            if let range = Range(match.range(at: 1), in: output) {
                warnings.append(String(output[range]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return warnings
    }
}
