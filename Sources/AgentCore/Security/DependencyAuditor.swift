import Foundation

/// Flags dependency-hygiene risks from manifest files: unpinned/floating versions that make builds
/// non-reproducible and silently pull new (possibly compromised) code. Deterministic + grounded at
/// the manifest line. (Live CVE lookup is a v2 add — this is the supply-chain HYGIENE layer.)
public enum DependencyAuditor {

    /// Returns findings for a manifest by filename. Unknown manifests yield nothing.
    public static func scan(text: String, file: String) -> [SecurityFinding] {
        switch (file as NSString).lastPathComponent.lowercased() {
        case "package.json":          return scanPackageJSON(text, file: file)
        case "requirements.txt":      return scanRequirements(text, file: file)
        case "package.swift":         return scanPackageSwift(text, file: file)
        case "cargo.toml":            return scanCargo(text, file: file)
        default:                      return []
        }
    }

    private static func finding(_ rule: String, _ title: String, file: String, line: Int, evidence: String) -> SecurityFinding {
        SecurityFinding(severity: .low, category: .dependency, rule: rule, title: title, file: file, line: line,
                        evidence: evidence.trimmingCharacters(in: .whitespaces),
                        recommendation: "Pin to an exact version and commit a lockfile for reproducible, auditable builds.",
                        owasp: "A06:2021 Vulnerable & Outdated Components")
    }

    private static func scanPackageJSON(_ text: String, file: String) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            // "name": "^1.2.3" / "~1.2" / "*" / "latest" / a git/url range — floating.
            guard let r = try? NSRegularExpression(pattern: #""[^"]+"\s*:\s*"([\^~]|>=|\*|latest|.*x)[^"]*""#),
                  r.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil else { continue }
            out.append(finding("npm-floating-version", "Floating npm dependency version", file: file, line: i + 1, evidence: line))
        }
        return out
    }

    private static func scanRequirements(_ text: String, file: String) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("-") { continue }
            // A bare package or one using >=,~=,> (not ==) is unpinned.
            if !line.contains("==") {
                out.append(finding("pip-unpinned", "Unpinned pip dependency", file: file, line: i + 1, evidence: line))
            }
        }
        return out
    }

    private static func scanPackageSwift(_ text: String, file: String) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            // `.package(... from: "x")` / `branch:` / `.upToNextMajor` = a moving target vs `.exact`.
            if line.contains(".package(") && (line.contains("from:") || line.contains("branch:") || line.contains("upToNextMajor")) {
                out.append(finding("spm-floating-version", "Floating SwiftPM dependency", file: file, line: i + 1, evidence: line))
            }
        }
        return out
    }

    private static func scanCargo(_ text: String, file: String) -> [SecurityFinding] {
        var out: [SecurityFinding] = []
        var inDeps = false
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inDeps = line.contains("dependencies"); continue }
            guard inDeps, line.contains("=") , !line.hasPrefix("#") else { continue }
            // `name = "1"` or `"^1"` / `"*"` — caret is the Cargo default and is floating.
            if line.contains("\"*\"") || line.contains("^") || (line.contains("\"") && !line.contains("=\"=")) {
                if !line.contains("path =") && !line.contains("git =") {
                    out.append(finding("cargo-floating-version", "Floating Cargo dependency", file: file, line: i + 1, evidence: line))
                }
            }
        }
        return out
    }
}
