import XCTest
@testable import Kist

final class KistChangelogTests: XCTestCase {
    // The top changelog entry MUST match the shipped version — the whole point of /version is that
    // it tells the truth about what this binary is.
    func testTopReleaseMatchesProductVersion() {
        XCTAssertEqual(KistChangelog.releases.first?.version, KistBuildInfo.productVersion,
                       "bump the changelog when you bump KistBuildInfo.productVersion")
        XCTAssertEqual(KistChangelog.current()?.version, KistBuildInfo.productVersion)
    }

    func testReleasesAreWellFormed() {
        XCTAssertFalse(KistChangelog.releases.isEmpty)
        for r in KistChangelog.releases {
            XCTAssertFalse(r.version.isEmpty)
            XCTAssertFalse(r.date.isEmpty)
            XCTAssertFalse(r.headline.isEmpty)
            XCTAssertFalse(r.changes.isEmpty, "\(r.version) must list what changed")
        }
    }

    func testRenderShowsVersionHeadlineAndChanges() {
        let prov = KistBuildInfo.Provenance(commit: "fee3d5cff46fe7145a3e9ecfe37f1fb4acbb4fb7",
                                            branch: "feat/dig-in-deep-council",
                                            sourceDirty: false,
                                            builtAt: nil)
        let out = KistChangelog.render(provenance: prov, color: false)
        XCTAssertTrue(out.contains("kist v\(KistBuildInfo.productVersion)"))
        XCTAssertTrue(out.contains("fee3d5cff46f"), "shows the short commit from the manifest")
        XCTAssertTrue(out.contains("feat/dig-in-deep-council"))
        XCTAssertTrue(out.contains("What's new"))
        XCTAssertTrue(out.contains("╭") && out.contains("╰"), "rendered as a bordered card")
    }

    // The card must stay square: every row (top/content/bottom) is the same visible cell width even
    // with emoji + ANSI inside. This is the alignment guarantee the whole card rendering rests on.
    func testCardRowsAreEqualCellWidth() {
        let prov = KistBuildInfo.Provenance(commit: "abcdef012345", branch: "feat/dig-in-deep-council",
                                            sourceDirty: false, builtAt: nil)
        for color in [false, true] {
            let out = KistChangelog.render(provenance: prov, color: color, width: 76)
            let lines = out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            XCTAssertFalse(lines.isEmpty)
            for line in lines {
                XCTAssertEqual(TerminalCellText.width(line), 76,
                               "card row not 76 cells (color=\(color)): \(TerminalCellText.stripANSI(line))")
            }
        }
    }

    func testRenderColorFalseEmitsNoEscapes() {
        let prov = KistBuildInfo.Provenance(commit: "abc123", branch: "main", sourceDirty: true, builtAt: nil)
        let out = KistChangelog.render(provenance: prov, color: false)
        XCTAssertFalse(out.contains("\u{001B}"))
    }

    func testDirtyBuildIsFlagged() {
        let prov = KistBuildInfo.Provenance(commit: "abc123def456", branch: "main", sourceDirty: true, builtAt: nil)
        XCTAssertTrue(KistChangelog.render(provenance: prov, color: false).contains("dirty"))
    }

    func testMissingProvenanceShowsUnmanagedNotice() {
        let prov = KistBuildInfo.Provenance(commit: nil, branch: nil, sourceDirty: nil, builtAt: nil)
        XCTAssertTrue(KistChangelog.render(provenance: prov, color: false).contains("unavailable"))
    }

    func testVersionCommandsAreCompletable() {
        for cmd in ["/version", "/changelog", "/whatsnew"] {
            XCTAssertTrue(InputCompleter.builtInCommands.contains(cmd), "\(cmd) should tab-complete")
        }
    }
}
