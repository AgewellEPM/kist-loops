import Foundation

/// Tool to get the project structure overview
final class GetProjectStructureTool: AgentTool {
    let name = "get_project_structure"
    let description = "Get an overview of the project structure including key directories and files."
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], projectPath: String) async throws -> ToolResult {
        var output = ""
        var stats = ProjectStats()

        // Get project name
        let projectName = (projectPath as NSString).lastPathComponent
        output += "📁 Project: \(projectName)\n"
        output += String(repeating: "=", count: 40) + "\n\n"

        // Find Xcode project/workspace
        let contents = try FileManager.default.contentsOfDirectory(atPath: projectPath)

        if let workspace = contents.first(where: { $0.hasSuffix(".xcworkspace") }) {
            output += "🔧 Workspace: \(workspace)\n"
        }
        if let xcodeproj = contents.first(where: { $0.hasSuffix(".xcodeproj") }) {
            output += "🔧 Project: \(xcodeproj)\n"
        }
        if contents.contains("Package.swift") {
            output += "📦 Swift Package: Package.swift\n"
        }
        if contents.contains("Podfile") {
            output += "🫛 CocoaPods: Podfile\n"
        }

        output += "\n"

        // Analyze structure
        output += "📂 Structure:\n"
        output += analyzeDirectory(at: projectPath, depth: 0, maxDepth: 2, stats: &stats)

        output += "\n📊 Statistics:\n"
        output += "  Swift files: \(stats.swiftFiles)\n"
        output += "  Total files: \(stats.totalFiles)\n"
        output += "  Directories: \(stats.directories)\n"

        // List key Swift files
        output += "\n🔶 Key Swift Files:\n"
        let swiftFiles = findSwiftFiles(in: projectPath)
        for file in swiftFiles.prefix(20) {
            output += "  \(file)\n"
        }
        if swiftFiles.count > 20 {
            output += "  ... and \(swiftFiles.count - 20) more\n"
        }

        return ToolResult(
            success: true,
            output: output,
            metadata: [
                "swift_files": String(stats.swiftFiles),
                "total_files": String(stats.totalFiles),
                "directories": String(stats.directories)
            ]
        )
    }

    private struct ProjectStats {
        var swiftFiles = 0
        var totalFiles = 0
        var directories = 0
    }

    private func analyzeDirectory(at path: String, depth: Int, maxDepth: Int, stats: inout ProjectStats) -> String {
        guard depth <= maxDepth else { return "" }

        var output = ""
        let indent = String(repeating: "  ", count: depth)

        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
        } catch {
            return ""
        }

        let filtered = contents.filter { item in
            !item.hasPrefix(".") &&
            !["DerivedData", "build", "Pods", "Carthage", "xcuserdata", "node_modules"].contains(item)
        }

        for item in filtered {
            let itemPath = path + "/" + item
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                stats.directories += 1
                output += "\(indent)📁 \(item)/\n"
                output += analyzeDirectory(at: itemPath, depth: depth + 1, maxDepth: maxDepth, stats: &stats)
            } else {
                stats.totalFiles += 1
                if item.hasSuffix(".swift") {
                    stats.swiftFiles += 1
                }
            }
        }

        return output
    }

    private func findSwiftFiles(in directory: String) -> [String] {
        var files: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: directory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            let pathComponents = url.pathComponents
            if pathComponents.contains("DerivedData") ||
               pathComponents.contains("Pods") ||
               pathComponents.contains(".build") {
                continue
            }

            if url.pathExtension == "swift" {
                let relativePath = url.path.replacingOccurrences(of: directory + "/", with: "")
                files.append(relativePath)
            }
        }

        return files.sorted()
    }
}
