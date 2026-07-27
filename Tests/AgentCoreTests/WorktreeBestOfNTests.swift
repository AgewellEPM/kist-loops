import XCTest
@testable import AgentCore

/// Best-of-N git executor — real git in a temp repo. The winner's change lands in the live tree; a
/// dirty tree or no-winner leaves it untouched.
final class WorktreeBestOfNTests: XCTestCase {
    private func sh(_ args: [String], _ cwd: String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
    private func makeRepo() throws -> String {
        let root = NSTemporaryDirectory() + "bon-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        sh(["init"], root); sh(["config","user.email","t@t"], root); sh(["config","user.name","t"], root)
        try "seed\n".write(toFile: root+"/seed.txt", atomically: true, encoding: .utf8)
        sh(["add","."], root); sh(["commit","-m","init"], root)
        return root
    }

    func testVerifiedWinnerLandsInLiveTree() async throws {
        guard WorktreeBestOfN.isGitRepoAvailable() else { throw XCTSkip("git unavailable") }
        let root = try makeRepo(); defer { try? FileManager.default.removeItem(atPath: root) }
        // attempt 0: writes but "unverified"; attempt 1: writes win.txt + verifies → should land in root.
        let applied = await WorktreeBestOfN.run(root: root, width: 3, nowEpoch: 1) { wt, i in
            try? "attempt \(i)\n".write(toFile: wt+"/win.txt", atomically: true, encoding: .utf8)
            return (verified: i == 1, quality: 50)
        }
        XCTAssertTrue(applied, "a verified winner's diff applied")
        XCTAssertEqual(try? String(contentsOfFile: root+"/win.txt", encoding: .utf8), "attempt 1\n")
    }

    func testNoWinnerLeavesTreeUntouched() async throws {
        guard WorktreeBestOfN.isGitRepoAvailable() else { throw XCTSkip("git unavailable") }
        let root = try makeRepo(); defer { try? FileManager.default.removeItem(atPath: root) }
        let applied = await WorktreeBestOfN.run(root: root, width: 2, nowEpoch: 1) { wt, i in
            try? "x\n".write(toFile: wt+"/nope.txt", atomically: true, encoding: .utf8)
            return (verified: false, quality: 0)
        }
        XCTAssertFalse(applied)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root+"/nope.txt"), "root untouched — no winner")
    }

    func testDirtyTreeRefusesBestOfN() async throws {
        guard WorktreeBestOfN.isGitRepoAvailable() else { throw XCTSkip("git unavailable") }
        let root = try makeRepo(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "dirty\n".write(toFile: root+"/seed.txt", atomically: true, encoding: .utf8)   // uncommitted change
        XCTAssertFalse(WorktreeBestOfN.isCleanTree(root))
        let applied = await WorktreeBestOfN.run(root: root, width: 3, nowEpoch: 1) { _,_ in (true, 100) }
        XCTAssertFalse(applied, "dirty tree → best-of-N refused, caller falls back")
    }
}
