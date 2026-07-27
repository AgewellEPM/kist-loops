import Foundation

/// Walks a project subtree and runs the deterministic scanners (secrets, SAST-lite, dependency
/// hygiene) over each text file, returning a grounded `AuditReport`. No LLM in the finding path → no
/// hallucinated vulnerabilities. `scanFile` is pure (text in → findings out) and unit-tested.
public enum SecurityAuditor {
    static let skipDirs: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "vendor", "dist", "build", "Pods",
        ".venv", "venv", "__pycache__", ".next", "target", ".gradle", "DerivedData"
    ]
    static let textExtensions: Set<String> = [
        "swift", "py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "kt", "rb", "php", "c", "h",
        "cpp", "cs", "sh", "bash", "zsh", "yml", "yaml", "toml", "json", "xml", "txt", "env",
        "cfg", "ini", "conf", "properties", "gradle", "tf", "md"
    ]
    /// Files always scanned regardless of extension (manifests, dotfiles that carry secrets).
    static let alwaysScan: Set<String> = [
        "package.json", "requirements.txt", "package.swift", "cargo.toml", "gemfile",
        ".env", ".env.local", ".env.production", "dockerfile", "makefile"
    ]

    /// Run the full audit under `root` (already a trusted, confined absolute path).
    public static func audit(root rawRoot: String, maxFileBytes: Int = 1_000_000, maxFiles: Int = 5000) -> AuditReport {
        // Canonicalize so enumerator paths (which resolve symlinks like /var→/private/var) align with
        // `root` when we compute the project-relative path.
        let root = ToolContext.canonicalize(rawRoot) ?? rawRoot
        var findings: [SecurityFinding] = []
        var scanned = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]) else {
            return AuditReport(findings: [], filesScanned: 0, root: root)
        }
        for case let url as URL in enumerator {
            if scanned >= maxFiles { break }
            let name = url.lastPathComponent.lowercased()
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            // NEVER read through a symlink — a repo-internal symlink to an external readable path would
            // otherwise leak that file's content into findings.
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            let ext = url.pathExtension.lowercased()
            guard textExtensions.contains(ext) || alwaysScan.contains(name) else { continue }
            if let size = values?.fileSize, size > maxFileBytes { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let rel = String(url.path.dropFirst(root.count).drop(while: { $0 == "/" }))
            findings.append(contentsOf: scanFile(text: text, relativePath: rel))
        }
        return AuditReport(findings: findings, filesScanned: scanned, root: root)
    }

    /// Pure: run every scanner over one file's text. The single place finding-producers compose.
    public static func scanFile(text: String, relativePath: String) -> [SecurityFinding] {
        SecretScanner.scan(text: text, file: relativePath)
            + StaticAnalyzer.scan(text: text, file: relativePath)
            + DependencyAuditor.scan(text: text, file: relativePath)
    }
}
