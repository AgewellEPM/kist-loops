import Foundation

/// Reads and indexes project files for context
@MainActor
final class ProjectContextService: ObservableObject {
    static let shared = ProjectContextService()

    @Published var currentProject: ProjectInfo?
    @Published var isLoading = false

    struct ProjectInfo {
        let path: String
        let xcodeProject: String?
        let swiftFiles: [String]
        let structure: String  // Tree representation
        let fileContents: [String: String]  // path -> content for key files
    }

    private init() {}

    // MARK: - Load Project

    func loadProject(at path: String) async throws -> ProjectInfo {
        isLoading = true
        defer { isLoading = false }

        let fileManager = FileManager.default

        // Verify path exists
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectError.invalidPath(path)
        }

        // Find Xcode project
        let contents = try fileManager.contentsOfDirectory(atPath: path)
        let xcodeProject = contents.first { $0.hasSuffix(".xcodeproj") }

        // Find all Swift files
        let swiftFiles = try findSwiftFiles(in: path)

        // Generate structure tree
        let structure = try generateStructureTree(at: path)

        // Read key file contents (limit to avoid memory issues)
        var fileContents: [String: String] = [:]
        for file in swiftFiles.prefix(50) {
            let fullPath = path + "/" + file
            if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                fileContents[file] = content
            }
        }

        let info = ProjectInfo(
            path: path,
            xcodeProject: xcodeProject,
            swiftFiles: swiftFiles,
            structure: structure,
            fileContents: fileContents
        )

        currentProject = info
        return info
    }

    // MARK: - Find Swift Files

    private func findSwiftFiles(in path: String) throws -> [String] {
        var swiftFiles: [String] = []
        let fileManager = FileManager.default

        let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            // Skip certain directories
            let pathComponents = url.pathComponents
            if pathComponents.contains("DerivedData") ||
               pathComponents.contains(".build") ||
               pathComponents.contains("Pods") ||
               pathComponents.contains("Carthage") ||
               pathComponents.contains(".git") {
                continue
            }

            if url.pathExtension == "swift" {
                // Get relative path
                let relativePath = url.path.replacingOccurrences(of: path + "/", with: "")
                swiftFiles.append(relativePath)
            }
        }

        return swiftFiles.sorted()
    }

    // MARK: - Generate Structure Tree

    private func generateStructureTree(at path: String, maxDepth: Int = 4) throws -> String {
        var result = ""
        let rootName = (path as NSString).lastPathComponent
        result += "\(rootName)/\n"

        try addTreeLevel(
            path: path,
            prefix: "",
            depth: 0,
            maxDepth: maxDepth,
            result: &result
        )

        return result
    }

    private func addTreeLevel(
        path: String,
        prefix: String,
        depth: Int,
        maxDepth: Int,
        result: inout String
    ) throws {
        guard depth < maxDepth else { return }

        let fileManager = FileManager.default
        var contents = try fileManager.contentsOfDirectory(atPath: path)

        // Filter out hidden files and common non-essential directories
        contents = contents.filter { item in
            !item.hasPrefix(".") &&
            item != "DerivedData" &&
            item != "build" &&
            item != "Pods" &&
            item != "Carthage" &&
            item != "xcuserdata"
        }

        contents.sort()

        for (index, item) in contents.enumerated() {
            let isLast = index == contents.count - 1
            let connector = isLast ? "└── " : "├── "
            let childPrefix = isLast ? "    " : "│   "

            let itemPath = path + "/" + item
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                result += "\(prefix)\(connector)\(item)/\n"
                try addTreeLevel(
                    path: itemPath,
                    prefix: prefix + childPrefix,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    result: &result
                )
            } else {
                // Only show Swift files and important config files
                if item.hasSuffix(".swift") ||
                   item.hasSuffix(".xcodeproj") ||
                   item.hasSuffix(".xcworkspace") ||
                   item == "Package.swift" ||
                   item == "Info.plist" {
                    result += "\(prefix)\(connector)\(item)\n"
                }
            }
        }
    }

    // MARK: - Get File Content

    func getFileContent(at relativePath: String) throws -> String {
        guard let project = currentProject else {
            throw ProjectError.noProjectLoaded
        }

        let fullPath = project.path + "/" + relativePath

        guard FileManager.default.fileExists(atPath: fullPath) else {
            throw ProjectError.fileNotFound(relativePath)
        }

        return try String(contentsOfFile: fullPath, encoding: .utf8)
    }

    // MARK: - Find Relevant Files

    func findRelevantFiles(for query: String) -> [String] {
        guard let project = currentProject else { return [] }

        let keywords = query.lowercased().split(separator: " ").map(String.init)
        var scores: [(file: String, score: Int)] = []

        for file in project.swiftFiles {
            var score = 0
            let fileName = (file as NSString).lastPathComponent.lowercased()

            // Check file name matches
            for keyword in keywords {
                if fileName.contains(keyword) {
                    score += 10
                }
            }

            // Check content if available
            if let content = project.fileContents[file]?.lowercased() {
                for keyword in keywords {
                    let count = content.components(separatedBy: keyword).count - 1
                    score += min(count, 5)  // Cap at 5 to avoid overweighting
                }
            }

            if score > 0 {
                scores.append((file, score))
            }
        }

        // Sort by score descending, return top 10
        return scores
            .sorted { $0.score > $1.score }
            .prefix(10)
            .map { $0.file }
    }

    // MARK: - Refresh Project

    func refresh() async {
        guard let project = currentProject else { return }
        _ = try? await loadProject(at: project.path)
    }
}

// MARK: - Errors

enum ProjectError: LocalizedError {
    case invalidPath(String)
    case noProjectLoaded
    case fileNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "Invalid project path: \(path)"
        case .noProjectLoaded:
            return "No project is currently loaded"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        }
    }
}
