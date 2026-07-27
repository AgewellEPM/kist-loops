import Foundation

/// Part 4: Executes builds and handles errors
final class BuildAgent {

    // MARK: - Execute and Build

    func executeAndBuild(
        generatedFiles: [GeneratedFile],
        projectPath: String,
        scheme: String
    ) async throws -> AgentBuildResult {
        let startTime = Date()

        // Write all generated files to disk
        for file in generatedFiles {
            let fullPath = projectPath + "/" + file.path

            // Create directory if needed
            let directory = (fullPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            // Write file
            try file.content.write(toFile: fullPath, atomically: true, encoding: .utf8)
        }

        // Add files to Xcode project if needed
        try await addFilesToXcodeProject(files: generatedFiles, projectPath: projectPath)

        // Run xcodebuild
        let result = try await runXcodebuild(
            projectPath: projectPath,
            scheme: scheme,
            configuration: "Debug"
        )

        let duration = Date().timeIntervalSince(startTime)

        return AgentBuildResult(
            success: result.success,
            output: result.output,
            errors: result.errors,
            warnings: result.warnings,
            duration: duration
        )
    }

    // MARK: - Xcode Build

    func runXcodebuild(
        projectPath: String,
        scheme: String,
        configuration: String = "Debug"
    ) async throws -> (success: Bool, output: String, errors: [AgentBuildError], warnings: [String]) {
        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")

        // Find .xcodeproj file
        let projectFiles = try FileManager.default.contentsOfDirectory(atPath: projectPath)
        let xcodeproj = projectFiles.first { $0.hasSuffix(".xcodeproj") }

        var arguments = ["-configuration", configuration, "build"]

        if let xcodeproj = xcodeproj {
            arguments.insert(contentsOf: ["-project", xcodeproj], at: 0)
        }

        if !scheme.isEmpty {
            arguments.insert(contentsOf: ["-scheme", scheme], at: 0)
        }

        process.arguments = arguments

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        return try await withCheckedThrowingContinuation { continuation in
            do {
                try process.run()

                process.terminationHandler = { _ in
                    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    let fullOutput = output + "\n" + errorOutput

                    let success = process.terminationStatus == 0
                    let errors = self.parseErrors(from: fullOutput)
                    let warnings = self.parseWarnings(from: fullOutput)

                    continuation.resume(returning: (success, fullOutput, errors, warnings))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Error Parsing

    private func parseErrors(from output: String) -> [AgentBuildError] {
        var errors: [AgentBuildError] = []

        // Match pattern: /path/file.swift:123:45: error: message
        let pattern = #"([^:\s]+\.swift):(\d+):(\d+)?:?\s*error:\s*(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return errors
        }

        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, options: [], range: range)

        for match in matches {
            let file = String(output[Range(match.range(at: 1), in: output)!])
            let line = Int(output[Range(match.range(at: 2), in: output)!]) ?? 0
            let column = match.range(at: 3).location != NSNotFound
                ? Int(output[Range(match.range(at: 3), in: output)!])
                : nil
            let message = String(output[Range(match.range(at: 4), in: output)!])

            errors.append(AgentBuildError(
                file: file,
                line: line,
                column: column,
                message: message.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        return errors
    }

    private func parseWarnings(from output: String) -> [String] {
        var warnings: [String] = []

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

    // MARK: - Add Files to Xcode Project

    private func addFilesToXcodeProject(files: [GeneratedFile], projectPath: String) async throws {
        // Find project.pbxproj
        let projectFiles = try FileManager.default.contentsOfDirectory(atPath: projectPath)
        guard let xcodeproj = projectFiles.first(where: { $0.hasSuffix(".xcodeproj") }) else {
            return
        }

        let pbxprojPath = projectPath + "/" + xcodeproj + "/project.pbxproj"

        guard FileManager.default.fileExists(atPath: pbxprojPath) else {
            return
        }

        var pbxprojContent = try String(contentsOfFile: pbxprojPath, encoding: .utf8)

        for file in files where file.isNew && file.path.hasSuffix(".swift") {
            // Generate unique IDs
            let fileRefId = generatePBXId()
            let buildFileId = generatePBXId()

            let fileName = (file.path as NSString).lastPathComponent
            let relativePath = file.path

            // Check if file already exists in project
            if pbxprojContent.contains(fileName) {
                continue
            }

            // Add to PBXFileReference section
            let fileRefEntry = "\t\t\(fileRefId) /* \(fileName) */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \(fileName); sourceTree = \"<group>\"; };\n"

            if let range = pbxprojContent.range(of: "/* End PBXFileReference section */") {
                pbxprojContent.insert(contentsOf: fileRefEntry, at: range.lowerBound)
            }

            // Add to PBXBuildFile section
            let buildFileEntry = "\t\t\(buildFileId) /* \(fileName) in Sources */ = {isa = PBXBuildFile; fileRef = \(fileRefId); };\n"

            if let range = pbxprojContent.range(of: "/* End PBXBuildFile section */") {
                pbxprojContent.insert(contentsOf: buildFileEntry, at: range.lowerBound)
            }

            // Add to Sources build phase
            let sourceEntry = "\t\t\t\t\(buildFileId) /* \(fileName) in Sources */,\n"

            // Find the Sources build phase and add the file
            if let sourcesRange = pbxprojContent.range(of: "/* Begin PBXSourcesBuildPhase section */"),
               let filesStart = pbxprojContent.range(of: "files = (", range: sourcesRange.upperBound..<pbxprojContent.endIndex),
               let filesEnd = pbxprojContent.range(of: ");", range: filesStart.upperBound..<pbxprojContent.endIndex) {
                pbxprojContent.insert(contentsOf: sourceEntry, at: filesEnd.lowerBound)
            }
        }

        // Write back
        try pbxprojContent.write(toFile: pbxprojPath, atomically: true, encoding: .utf8)
    }

    private func generatePBXId() -> String {
        // Generate a 24-character hex ID like Xcode does
        let chars = "0123456789ABCDEF"
        return String((0..<24).map { _ in chars.randomElement()! })
    }
}
