import Foundation

/// Product metadata used by the deployment gate.
///
/// Keep this value as an honest Semantic Version: `kist-rebuild` binds the exact
/// release binary and its reported version into the deployment manifest.
enum KistBuildInfo {
    static let productVersion = "0.17.60"
    static let versionText = "kist \(productVersion)"
    static let startupLabel = "v\(productVersion)"

    /// The installed wrapper adds authority flags ahead of caller arguments, so
    /// `--version` must remain a metadata fast path wherever it appears.
    static func isVersionRequest(_ arguments: [String]) -> Bool {
        arguments.contains("--version")
    }

    /// The real build identity of THIS binary, read at runtime from the deployment manifest that
    /// `kist-rebuild` writes next to the installed executable (`<exe>.manifest`). So `/version` can
    /// show the exact commit/branch shipped and WHEN it was built — not just a hardcoded number.
    struct Provenance: Equatable, Sendable {
        let commit: String?       // full git sha of the shipped source
        let branch: String?
        let sourceDirty: Bool?    // was the tree dirty at build time
        let builtAt: Date?        // manifest file mtime = install time

        var shortCommit: String? { commit.map { String($0.prefix(12)) } }
    }

    static func provenance() -> Provenance {
        guard let path = manifestPath(), let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return Provenance(commit: nil, branch: nil, sourceDirty: nil, builtAt: nil)
        }
        var fields: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            let value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { fields[key] = value }
        }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return Provenance(commit: nonEmpty(fields["commit"]),
                          branch: nonEmpty(fields["branch"]),
                          sourceDirty: fields["source-dirty"].map { $0 == "yes" },
                          builtAt: mtime)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// `kist-rebuild` installs `<executable>.manifest`. Resolve the running executable's path (through
    /// any symlink) and look for its sibling manifest; fall back to the canonical install location.
    private static func manifestPath() -> String? {
        let fm = FileManager.default
        if let exe = CommandLine.arguments.first, !exe.isEmpty {
            let resolved = (exe as NSString).resolvingSymlinksInPath
            let candidate = resolved + ".manifest"
            if fm.fileExists(atPath: candidate) { return candidate }
        }
        let fallback = fm.homeDirectoryForCurrentUser.appendingPathComponent("bin/kist-current.manifest").path
        return fm.fileExists(atPath: fallback) ? fallback : nil
    }
}
