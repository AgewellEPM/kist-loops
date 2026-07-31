/// Product metadata used by the deployment gate.
///
/// Keep this value as an honest Semantic Version: `kist-rebuild` binds the exact
/// release binary and its reported version into the deployment manifest.
enum KistBuildInfo {
    static let productVersion = "0.16.0"
    static let versionText = "kist \(productVersion)"
    static let startupLabel = "v\(productVersion)"

    /// The installed wrapper adds authority flags ahead of caller arguments, so
    /// `--version` must remain a metadata fast path wherever it appears.
    static func isVersionRequest(_ arguments: [String]) -> Bool {
        arguments.contains("--version")
    }
}
