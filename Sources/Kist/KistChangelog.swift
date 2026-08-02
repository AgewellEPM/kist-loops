import Foundation

/// The human changelog behind `/version` — so typing `/version` in the terminal shows the version,
/// WHAT we worked on in it, and WHEN it shipped (build stamp from the deployment manifest). Curated
/// by hand and compiled into the binary (the single-binary deploy has no sidecar resources), newest
/// release first. Keep the top entry in sync with `KistBuildInfo.productVersion` on every bump.
enum KistChangelog {
    struct Release: Equatable, Sendable {
        let version: String
        let date: String        // ISO date the release shipped
        let headline: String
        let changes: [String]
    }

    static let releases: [Release] = [
        Release(version: "0.17.0", date: "2026-08-02",
                headline: "Readable terminal — color, confidence, sticky bar",
                changes: [
                    "Neon per-category dashboard sections + green battery confidence gauge",
                    "/confidence (/why): why the score is what it is and how to raise it",
                    "Tool lane: an emoji per tool, category colors, dimmed metadata",
                    "Streamed answers get markdown coloring (bold / code / headers / lists); code fences stay raw",
                    "Bottom input bar now stays glued through turns (sticky-turns on by default; --no-sticky-turns opts out)",
                    "NO_COLOR + mono screen-reader theme honored on every surface",
                    "/version: this changelog view",
                ]),
        Release(version: "0.16.0", date: "2026-08-01",
                headline: "Consensus reviews + self-fixing captain",
                changes: [
                    "/ultra: consensus of minds — each model reviews then fixes until flawless",
                    "/bughunt: a fleet of isolated hunters for real-world bug hunting",
                    "The reviewer now auto-fixes what it finds",
                    "Auto-explore: answers lookup questions from our own files instead of hallucinating",
                    "Keyless claude-cli / codex-cli subscription providers",
                ]),
    ]

    /// The release matching the running binary's version, else the newest known.
    static func current(version: String = KistBuildInfo.productVersion) -> Release? {
        releases.first { $0.version == version } ?? releases.first
    }

    /// Render the `/version` panel: version + headline, the real build stamp (commit/branch/date from
    /// the manifest), the current release's changes in full, and a compact list of earlier releases.
    static func render(provenance: KistBuildInfo.Provenance,
                       version: String = KistBuildInfo.productVersion,
                       color: Bool,
                       width: Int = 72) -> String {
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let rule = c("2", String(repeating: "━", count: max(16, width)))
        let cur = current(version: version)

        var out = "\n" + rule + "\n\n"
        out += c("96;1", "🚀 kist v\(version)")
        if let h = cur?.headline { out += c("2", " · ") + c("37;1", h) }
        out += "\n"

        // Build stamp — the honest "when we upgraded / what's shipped" line.
        var stamp: [String] = []
        if let sc = provenance.shortCommit { stamp.append(c("94", sc)) }
        if let b = provenance.branch { stamp.append(c("94", b)) }
        if let d = provenance.builtAt { stamp.append(c("94", isoStamp(d))) }
        if provenance.sourceDirty == true { stamp.append(c("33;1", "dirty")) }
        if stamp.isEmpty {
            out += c("2", "build stamp unavailable (running an unmanaged build)") + "\n"
        } else {
            out += c("2", "build ") + stamp.joined(separator: c("2", " · ")) + "\n"
        }
        out += "\n"

        if let cur {
            out += c("95;1", "What's new in \(cur.version)") + c("2", " · \(cur.date)") + "\n\n"
            for change in cur.changes {
                out += c("92;1", "  • ") + c("37", change) + "\n"
            }
            out += "\n"
        }

        let earlier = releases.filter { $0.version != (cur?.version ?? version) }
        if !earlier.isEmpty {
            out += c("2", "Earlier releases") + "\n\n"
            for r in earlier {
                out += c("94;1", "  \(r.version)") + c("2", " · \(r.date) · ") + c("37", r.headline) + "\n"
                for change in r.changes.prefix(3) {
                    out += c("2", "     – ") + c("2", change) + "\n"
                }
                if r.changes.count > 3 { out += c("2", "     … +\(r.changes.count - 3) more") + "\n" }
                out += "\n"
            }
        }
        out += rule + "\n"
        return out
    }

    /// A stable `YYYY-MM-DD HH:MM` in the local zone (no Date.now — takes the instant explicitly).
    private static func isoStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
