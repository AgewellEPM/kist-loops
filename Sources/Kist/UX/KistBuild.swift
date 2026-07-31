import Foundation

/// The build stamp shown at startup so you always know EXACTLY which build is live — "instead of just a
/// header, label the version" (Luke, 2026-07-31). `commit`/`built` are rewritten by the deploy step
/// (`scripts/stamp-build.sh`) from the real git SHA + date right before the release build, so the running
/// binary never lies about what it is. `version` is the human product version — bump on meaningful releases.
enum KistBuild {
    static let version = "0.16.0"
    static let commit = "unstamped"        // ← overwritten at deploy by scripts/stamp-build.sh
    static let built = "dev"               // ← overwritten at deploy by scripts/stamp-build.sh

    /// One-line label: `v0.16.0 · 9534cc8 · 2026-07-31`.
    static var label: String {
        var s = "v\(version)"
        if commit != "unstamped" { s += " · \(commit)" }
        if built != "dev" { s += " · \(built)" }
        return s
    }
}
