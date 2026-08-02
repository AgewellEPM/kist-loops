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

    /// Render the `/version` panel as a bordered CARD (like Codex's `/status`): version + headline in
    /// the top border, the real build stamp (commit/branch/date from the manifest), the current
    /// release's changes in full, and earlier releases compact. Every row is padded to the same cell
    /// width so the box stays square even with emoji + ANSI inside (widths via TerminalCellText).
    static func render(provenance: KistBuildInfo.Provenance,
                       version: String = KistBuildInfo.productVersion,
                       color: Bool,
                       width: Int = 76) -> String {
        func c(_ code: String, _ s: String) -> String { color ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s }
        let W = max(48, width)
        let inner = W - 4                               // "│ " + content + " │"
        let cur = current(version: version)

        func pad(_ s: String) -> String {
            let w = TerminalCellText.width(s)
            return w >= inner ? s : s + String(repeating: " ", count: inner - w)
        }
        func row(_ content: String) -> String { c("2", "│ ") + pad(content) + c("2", " │") + "\n" }
        func blank() -> String { row("") }
        func wrap(_ text: String, _ w: Int) -> [String] {
            guard w > 4 else { return [text] }
            var lines: [String] = []; var cur = ""
            for word in text.split(separator: " ").map(String.init) {
                let cand = cur.isEmpty ? word : cur + " " + word
                if TerminalCellText.width(cand) <= w { cur = cand }
                else { if !cur.isEmpty { lines.append(cur) }; cur = word }
            }
            if !cur.isEmpty { lines.append(cur) }
            return lines.isEmpty ? [""] : lines
        }
        // A bulleted, wrapped content block: colored bullet on line 0, aligned continuations.
        func bullet(_ glyphCode: String, _ glyph: String, _ text: String, textCode: String) -> String {
            let lead = glyph + " "
            let leadCells = TerminalCellText.width(lead)
            let wrapped = wrap(text, inner - leadCells)
            var s = row(c(glyphCode, lead) + c(textCode, wrapped[0]))
            for cont in wrapped.dropFirst() {
                s += row(String(repeating: " ", count: leadCells) + c(textCode, cont))
            }
            return s
        }

        // Top border carries the title, Codex-style: ╭─ 🚀 kist v0.17.0 ─────╮
        let title = "🚀 kist v\(version)"
        let titleCells = TerminalCellText.width(title)
        let trailingDashes = max(0, W - 5 - titleCells)          // ╭ + "─ " + title + " " + dashes + ╮
        var out = "\n" + c("2", "╭─ ") + c("96;1", title) + c("2", " " + String(repeating: "─", count: trailingDashes) + "╮") + "\n"

        if let h = cur?.headline { out += bullet("2", " ", h, textCode: "37;1") }
        out += blank()

        // Build stamp — the honest "when / what shipped" line.
        var stamp: [String] = []
        if let sc = provenance.shortCommit { stamp.append(c("94", sc)) }
        if let b = provenance.branch { stamp.append(c("94", b)) }
        if let d = provenance.builtAt { stamp.append(c("94", isoStamp(d))) }
        if provenance.sourceDirty == true { stamp.append(c("33;1", "dirty")) }
        if stamp.isEmpty {
            out += row(c("2", "build stamp unavailable (unmanaged build)"))
        } else {
            out += row(c("2", "build ") + stamp.joined(separator: c("2", " · ")))
        }
        out += blank()

        if let cur {
            out += row(c("95;1", "What's new in \(cur.version)") + c("2", " · \(cur.date)"))
            for change in cur.changes { out += bullet("92;1", "•", change, textCode: "37") }
            out += blank()
        }

        let earlier = releases.filter { $0.version != (cur?.version ?? version) }
        if !earlier.isEmpty {
            out += row(c("2", "Earlier releases"))
            for r in earlier {
                out += bullet("94;1", "▪", "\(r.version) · \(r.date) · \(r.headline)", textCode: "37")
            }
        }
        out += c("2", "╰" + String(repeating: "─", count: W - 2) + "╯") + "\n"
        return out
    }

    /// A stable `YYYY-MM-DD HH:MM` in the local zone (no Date.now — takes the instant explicitly).
    private static func isoStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
