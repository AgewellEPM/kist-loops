import Foundation

/// Install or resolve project dependencies based on detected manager (SPM/Pods/Carthage)
final class InstallDependenciesTool: AgentTool {
    let name = "install_dependencies"
    let description = "Install project dependencies. Detects SwiftPM, CocoaPods, or Carthage and runs the appropriate commands."
    let parameters: [ToolParameter] = []

    func execute(arguments: [String : Any], projectPath: String) async throws -> ToolResult {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(atPath: projectPath)) ?? []

        // Detect dependency managers
        let hasSPM = items.contains("Package.swift") || items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") })
        let hasPods = items.contains("Podfile")
        let hasCarthage = items.contains("Cartfile")

        var outputs: [String] = []
        var success = true

        // SwiftPM/Xcode resolve
        if hasSPM {
            let spm = runCommand(
                cwd: projectPath,
                executable: "/usr/bin/xcodebuild",
                args: ["-resolvePackageDependencies"]
            )
            outputs.append("[SPM] \(spm.output)\n\(spm.error ?? "")")
            success = success && spm.success
        }

        // CocoaPods install
        if hasPods {
            let pod = runCommand(
                cwd: projectPath,
                executable: "/usr/bin/env",
                args: ["pod", "install"]
            )
            outputs.append("[Pods] \(pod.output)\n\(pod.error ?? "")")
            success = success && pod.success
        }

        // Carthage bootstrap
        if hasCarthage {
            let carthage = runCommand(
                cwd: projectPath,
                executable: "/usr/bin/env",
                args: ["carthage", "bootstrap", "--platform", "macOS"]
            )
            outputs.append("[Carthage] \(carthage.output)\n\(carthage.error ?? "")")
            success = success && carthage.success
        }

        if !hasSPM && !hasPods && !hasCarthage {
            return ToolResult(success: false, output: "", error: "No dependency manager detected (SPM/Pods/Carthage)")
        }

        return ToolResult(
            success: success,
            output: outputs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines),
            error: success ? nil : "Some dependency installation steps failed"
        )
    }

    private func runCommand(cwd: String, executable: String, args: [String]) -> (success: Bool, output: String, error: String?) {
        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run(); proc.waitUntilExit() } catch {
            return (false, "", "Failed to run command: \(error.localizedDescription)")
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (proc.terminationStatus == 0, stdout, stderr.isEmpty ? nil : stderr)
    }
}

