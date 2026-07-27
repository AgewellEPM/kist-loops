import XCTest
@testable import AgentCore

/// Panel safety fix: an unattended --loop must REFUSE irreversible ops while still running build/test.
final class NonDestructiveInteractorTests: XCTestCase {
    func testApprovesNormalDeniesDangerous() async {
        let i = NonDestructiveInteractor()
        let normal = await i.requestApproval(planSummary: "run swift test", dangerous: false)
        let danger = await i.requestApproval(planSummary: "rm -rf /", dangerous: true)
        XCTAssertTrue(normal, "build/test/edit still runs")
        XCTAssertFalse(danger, "irreversible ops are refused unattended")
    }
    func testPlainApprovalDefaultsAllowed() async {
        let ok = await NonDestructiveInteractor().requestApproval(planSummary: "edit a file")
        XCTAssertTrue(ok)
    }
    // RepoMap sort: score DESC, file ASC (the fixed comparator).
    func testRepoMapRanksByScoreThenFile() {
        let files = [("zzz.swift", "func matchTokenParser() {}"),   // score 2 (token,parser), late name
                     ("aaa.swift", "func draw() {}")]                // score 0
        let map = RepoMap.render(files: files, goal: "token parser")
        XCTAssertTrue(map.range(of: "zzz.swift")!.lowerBound < (map.range(of: "aaa.swift")?.lowerBound ?? map.endIndex))
    }
}
