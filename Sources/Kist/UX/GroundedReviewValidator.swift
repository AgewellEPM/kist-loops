import Foundation

/// Lightweight post-answer grounding check for review/security/audit turns. It catches the failure we
/// saw live: a model returns confident findings with file paths that do not exist in this repo.
enum GroundedReviewValidator {
    struct Report: Equatable {
        let missingFiles: [String]
        var isGrounded: Bool { missingFiles.isEmpty }

        func render(color: Bool = true) -> String {
            guard !missingFiles.isEmpty else { return "" }
            func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
            let sample = missingFiles.prefix(5).joined(separator: ", ")
            let more = missingFiles.count > 5 ? " (+\(missingFiles.count - 5) more)" : ""
            return c("33;1", "grounding warning") + c("2", " · file refs not found: ") + sample + more +
                c("2", " · ask for /logs or rerun with a stricter reviewer")
        }
    }

    static func audit(_ text: String, projectRoot: String) -> Report {
        let refs = fileReferences(in: text)
        // Only flag PATH-like references (a directory component) that don't exist — those are the
        // "confident fabricated path" failure this guards against. A BARE filename (e.g. `preferences.md`,
        // `main.py`) is NOT flagged: the model usually saw it in a directory LISTING and it commonly lives
        // deeper in the tree, so checking only `projectRoot/<bare>` produced noisy false positives on real
        // files (seen live — flagged `preferences.md` that exists at `.kist/cortex/preferences.md`).
        let missing = refs.filter { $0.contains("/") && !exists($0, projectRoot: projectRoot) }
        return Report(missingFiles: missing)
    }

    static func fileReferences(in text: String) -> [String] {
        let pattern = #"(?<![A-Za-z0-9_./-])([A-Za-z0-9_./-]+\.(?:swift|md|json|yml|yaml|sh|py|js|ts|tsx|mjs|txt|toml|lock|plist))(?:[:#][0-9]+)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [String] = []
        for match in re.matches(in: text, range: range) where match.numberOfRanges > 1 {
            var ref = ns.substring(with: match.range(at: 1))
            while ref.hasPrefix("./") { ref.removeFirst(2) }
            if ref.hasPrefix("/") || ref.contains("://") { continue }
            if ref.hasPrefix(".build/") || ref.hasPrefix(".git/") { continue }
            if !out.contains(ref) { out.append(ref) }
        }
        return out
    }

    private static func exists(_ ref: String, projectRoot: String) -> Bool {
        let full = URL(fileURLWithPath: projectRoot).appendingPathComponent(ref).standardizedFileURL.path
        let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
        guard full == root || full.hasPrefix(root + "/") else { return false }
        return FileManager.default.fileExists(atPath: full)
    }
}
