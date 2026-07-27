import Foundation

/// Tool to run xcodebuild test and summarize results
final class RunTestsTool: AgentTool {
    let name = "run_tests"
    let description = "Run unit/UI tests via xcodebuild test. Params: scheme (string, optional), configuration (string, default Debug), destination (string, default platform=macOS). Returns summary with test counts and failures."
    let parameters: [ToolParameter] = [
        ToolParameter(name: "scheme", type: "string", description: "Test scheme", required: false),
        ToolParameter(name: "configuration", type: "string", description: "Build configuration (Debug/Release)", required: false),
        ToolParameter(name: "destination", type: "string", description: "xcodebuild -destination value (default platform=macOS)", required: false)
    ]

    func execute(arguments: [String : Any], projectPath: String) async throws -> ToolResult {
        let scheme = arguments["scheme"] as? String ?? ""
        let configuration = arguments["configuration"] as? String ?? "Debug"
        let destination = arguments["destination"] as? String ?? "platform=macOS"

        // Detect workspace or project
        let items = (try? FileManager.default.contentsOfDirectory(atPath: projectPath)) ?? []
        let workspace = items.first { $0.hasSuffix(".xcworkspace") }
        let xcodeproj = items.first { $0.hasSuffix(".xcodeproj") }

        var args: [String] = []
        if let workspace = workspace {
            args += ["-workspace", workspace]
        } else if let xcodeproj = xcodeproj {
            args += ["-project", xcodeproj]
        }
        if !scheme.isEmpty { args += ["-scheme", scheme] }
        args += ["-configuration", configuration, "-destination", destination, "test"]

        let proc = Process()
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let start = Date()
        do { try proc.run(); proc.waitUntilExit() } catch {
            return ToolResult(success: false, output: "", error: "Failed to run tests: \(error.localizedDescription)")
        }
        let duration = Date().timeIntervalSince(start)
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let full = stdout + "\n" + stderr

        // Parse test summary lines
        // Example: "Executed 23 tests, with 0 failures (0 unexpected) in 12.345 (12.345) seconds"
        let summaryPattern = #"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?.*?in\s+([0-9.]+)"#
        let regex = try? NSRegularExpression(pattern: summaryPattern, options: [])
        var tests = 0; var failures = 0; var secs = duration
        if let r = regex {
            let range = NSRange(full.startIndex..., in: full)
            if let m = r.firstMatch(in: full, options: [], range: range) {
                if let rr = Range(m.range(at: 1), in: full) { tests = Int(full[rr]) ?? tests }
                if let rr = Range(m.range(at: 2), in: full) { failures = Int(full[rr]) ?? failures }
                if let rr = Range(m.range(at: 3), in: full) { secs = Double(full[rr]) ?? secs }
            }
        }

        let ok = proc.terminationStatus == 0 && failures == 0
        var output = ok ? "✅ TESTS PASSED" : "❌ TESTS FAILED"
        output += "\nExecuted: \(tests) tests, Failures: \(failures), Duration: \(String(format: "%.2fs", secs))\n"
        if !ok {
            // Provide last 2000 chars of log
            let tail = full.suffix(2000)
            output += "\n--- Log Tail ---\n" + tail
        }

        // Log into ChangeLogStore
        await MainActor.run {
            ChangeLogStore.shared.logBuild(success: ok, errors: failures, warnings: 0, duration: String(format: "%.2fs", secs), scheme: scheme.isEmpty ? "default" : scheme, configuration: "Tests", raw: full)
        }

        return ToolResult(success: ok, output: output, error: ok ? nil : "Some tests failed", metadata: [
            "tests": String(tests),
            "failures": String(failures),
            "duration": String(format: "%.2fs", secs)
        ])
    }
}

