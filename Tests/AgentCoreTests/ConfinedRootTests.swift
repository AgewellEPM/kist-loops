import XCTest
import Foundation
@testable import AgentCore

/// Adversarial suite for `ConfinedRoot` — the openat/O_NOFOLLOW filesystem-confinement
/// layer that closes Codex HIGH#2 (TOCTOU). These tests pin the SECURITY PROPERTY the
/// primitive exists to guarantee: a symlink swapped in at the leaf OR at any intermediate
/// path component is refused, `..`/absolute escapes are refused, and writes/walks never
/// follow a link out of the root. The legacy string-based `resolvedPath` tests in
/// ToolsTests cover a DIFFERENT code path — they do not exercise this one.
final class ConfinedRootTests: XCTestCase {

    private var root: String!
    private var external: String!   // a dir OUTSIDE the root, to be a symlink target

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "confined-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)

        let ext = NSTemporaryDirectory() + "external-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: ext, withIntermediateDirectories: true)
        external = ToolContext.canonicalize(ext)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(atPath: root) }
        if let external { try? FileManager.default.removeItem(atPath: external) }
    }

    private func cr() throws -> ConfinedRoot { try ConfinedRoot(root: root) }

    private func lease(for projectRoot: String) throws -> WorkspaceExecutionLease {
        let estate = URL(fileURLWithPath: external, isDirectory: true)
            .appendingPathComponent("lease-estate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: estate, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return try WorkspaceExecutionCoordinator(
            lockDirectory: estate.appendingPathComponent("workspace-locks", isDirectory: true))
            .acquire(projectRoot: projectRoot, missionInstanceID: UUID().uuidString)
    }

    private func assertPathEscape(_ path: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body()) { error in
            guard case .pathEscape = (error as? ToolError) else {
                return XCTFail("expected .pathEscape for \(path), got \(error)")
            }
        }
    }

    // MARK: - Happy path (proves the confined I/O actually works)

    func testWriteReadRoundTripWithCreatedParents() throws {
        let c = try cr()
        try c.writeString("a/b/c.txt", "hello-kist", createParents: true)
        XCTAssertEqual(try c.readString("a/b/c.txt"), "hello-kist")
        XCTAssertEqual(try c.fileType("a/b/c.txt").exists, true)
        XCTAssertEqual(try c.fileType("a/b").isDir, true)
    }

    func testConditionalReplacePublishesOnlyMatchingBaseline() throws {
        let c = try cr()
        try c.writeString("program.cbl", "old", createParents: false)
        let baseline = try c.fileSHA256("program.cbl")
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        let published = try c.conditionalReplace(
            "program.cbl", with: Data("new".utf8),
            expectedSHA256: .sha256(baseline), lease: workspaceLease)

        XCTAssertEqual(try c.readString("program.cbl"), "new")
        XCTAssertEqual(published, try c.fileSHA256("program.cbl"))
    }

    func testConditionalReplaceCanAtomicallyPublishExpectedMissingTarget() throws {
        let c = try cr()
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        let published = try c.conditionalReplace(
            "new-program.cbl", with: Data("created".utf8),
            expectedSHA256: .missing, lease: workspaceLease)

        XCTAssertEqual(try c.readString("new-program.cbl"), "created")
        XCTAssertEqual(published, try c.fileSHA256("new-program.cbl"))
    }

    func testConditionalReplaceRejectsStaleBaselineWithoutMutation() throws {
        let c = try cr()
        try c.writeString("program.cbl", "baseline", createParents: false)
        let stale = try c.fileSHA256("program.cbl")
        try c.writeString("program.cbl", "concurrent-change", createParents: false)
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        XCTAssertThrowsError(try c.conditionalReplace(
            "program.cbl", with: Data("candidate".utf8),
            expectedSHA256: .sha256(stale), lease: workspaceLease))
        XCTAssertEqual(try c.readString("program.cbl"), "concurrent-change")
    }

    func testConditionalReplaceRejectsLeaseForDifferentCanonicalRoot() throws {
        let c = try cr()
        try c.writeString("program.cbl", "baseline", createParents: false)
        let baseline = try c.fileSHA256("program.cbl")
        let wrongLease = try lease(for: external)
        defer { wrongLease.release() }

        XCTAssertThrowsError(try c.conditionalReplace(
            "program.cbl", with: Data("candidate".utf8),
            expectedSHA256: .sha256(baseline), lease: wrongLease))
        XCTAssertEqual(try c.readString("program.cbl"), "baseline")
    }

    func testConditionalReplaceRejectsSymlinkLeafWithoutTouchingTarget() throws {
        let target = external + "/outside.cbl"
        try "outside".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/program.cbl", withDestinationPath: target)
        let c = try cr()
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        assertPathEscape("program.cbl") {
            _ = try c.conditionalReplace(
                "program.cbl", with: Data("candidate".utf8),
                expectedSHA256: .missing, lease: workspaceLease)
        }
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "outside")
    }

    func testConditionalRemoveDeletesOnlyMatchingRegularFile() throws {
        let c = try cr()
        try c.writeString("program.cbl", "verified", createParents: false)
        let expected = try c.fileSHA256("program.cbl")
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        let removed = try c.conditionalRemove(
            "program.cbl", expectedSHA256: expected, lease: workspaceLease)

        XCTAssertEqual(removed, expected)
        XCTAssertEqual(try c.fileType("program.cbl").exists, false)
    }

    func testConditionalRemoveRejectsStaleDigestWithoutMutation() throws {
        let c = try cr()
        try c.writeString("program.cbl", "baseline", createParents: false)
        let stale = try c.fileSHA256("program.cbl")
        try c.writeString("program.cbl", "concurrent-change", createParents: false)
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        XCTAssertThrowsError(try c.conditionalRemove(
            "program.cbl", expectedSHA256: stale, lease: workspaceLease))
        XCTAssertEqual(try c.readString("program.cbl"), "concurrent-change")
    }

    func testConditionalRemoveRejectsLeaseForDifferentCanonicalRoot() throws {
        let c = try cr()
        try c.writeString("program.cbl", "verified", createParents: false)
        let expected = try c.fileSHA256("program.cbl")
        let wrongLease = try lease(for: external)
        defer { wrongLease.release() }

        XCTAssertThrowsError(try c.conditionalRemove(
            "program.cbl", expectedSHA256: expected, lease: wrongLease))
        XCTAssertEqual(try c.readString("program.cbl"), "verified")
    }

    func testConditionalRemoveRejectsSymlinkLeafWithoutTouchingTarget() throws {
        let target = external + "/outside-remove.cbl"
        try "outside".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: root + "/program.cbl", withDestinationPath: target)
        let c = try cr()
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        assertPathEscape("program.cbl") {
            _ = try c.conditionalRemove(
                "program.cbl", expectedSHA256: Data(repeating: 0, count: 32),
                lease: workspaceLease)
        }
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "outside")
    }

    func testConditionalRemoveRejectsMissingLeaf() throws {
        let c = try cr()
        let workspaceLease = try lease(for: root)
        defer { workspaceLease.release() }

        XCTAssertThrowsError(try c.conditionalRemove(
            "missing.cbl", expectedSHA256: Data(repeating: 0, count: 32),
            lease: workspaceLease)) { error in
            guard case .notFound = (error as? ToolError) else {
                return XCTFail("expected .notFound for missing.cbl, got \(error)")
            }
        }
    }

    // Sprint 2 (Codex): the bounded read caps on the SAME fd (fstat + length-bounded read), so a file at
    // or under the cap reads fine and one over the cap is refused — no metadata-then-read race.
    func testBoundedReadAcceptsAtCapRejectsOver() throws {
        let c = try cr()
        try c.writeString("ok.sig", String(repeating: "x", count: 64), createParents: true)
        XCTAssertEqual(try c.readString("ok.sig", maxBytes: 64).count, 64, "exactly-at-cap reads")
        try c.writeString("big.sig", String(repeating: "y", count: 65), createParents: true)
        XCTAssertThrowsError(try c.readString("big.sig", maxBytes: 64)) { error in
            guard case .execution = (error as? ToolError) else { return XCTFail("expected .execution over-cap, got \(error)") }
        }
    }

    func testConstructorRejectsNonDirectoryRoot() throws {
        let file = root + "/just-a-file"
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ConfinedRoot(root: file))
    }

    // MARK: - String-level escapes (relativeComponents)

    func testDotDotComponentRejected() throws {
        let c = try cr()
        assertPathEscape("../escape.txt") { _ = try c.readData("../escape.txt") }
    }

    func testAbsoluteOutsideRootRejected() throws {
        let c = try cr()
        assertPathEscape("/etc/passwd") { _ = try c.readData("/etc/passwd") }
    }

    func testSiblingPrefixNotConfused() throws {
        // "<root>EVIL/x" shares a string prefix with root but is not inside it.
        let c = try cr()
        assertPathEscape(root + "EVIL/x") { _ = try c.readData(root + "EVIL/x") }
    }

    // MARK: - Symlink at the LEAF is not followed (O_NOFOLLOW on the open)

    func testReadThroughSymlinkLeafRefused() throws {
        try "TOP-SECRET".write(toFile: external + "/secret.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/leak", withDestinationPath: external + "/secret.txt")
        let c = try cr()
        // Must NOT return the target's contents; the symlinked leaf yields ELOOP → pathEscape.
        assertPathEscape("leak") { _ = try c.readData("leak") }
    }

    func testEveryContentReadRefusesPreexistingHardlinkedLeaf() throws {
        let outside = external + "/hardlink-secret.txt"
        let inside = root + "/hardlink-secret.txt"
        try "TOP-SECRET".write(
            toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(atPath: outside, toPath: inside)
        let c = try cr()

        XCTAssertThrowsError(try c.readData("hardlink-secret.txt"))
        XCTAssertThrowsError(try c.readData("hardlink-secret.txt", maxBytes: 64))
        XCTAssertThrowsError(try c.readStableData("hardlink-secret.txt", maxBytes: 64))
        XCTAssertThrowsError(try c.readDataPrefix("hardlink-secret.txt", maxBytes: 64))
        XCTAssertThrowsError(try c.fileSHA256("hardlink-secret.txt"))
    }

    func testWriteDoesNotClobberSymlinkTarget() throws {
        // A symlinked leaf must have the LINK replaced, never the external target written through.
        let target = external + "/target.txt"
        try "original".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/link.txt", withDestinationPath: target)

        let c = try cr()
        try c.writeString("link.txt", "HACKED", createParents: false)

        // External target is untouched...
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "original")
        // ...and the in-root name now holds our content (the link was atomically replaced).
        XCTAssertEqual(try c.readString("link.txt"), "HACKED")
    }

    // MARK: - Symlink at an INTERMEDIATE component is not followed (the TOCTOU defense)

    func testIntermediateSymlinkDirRefused() throws {
        try FileManager.default.createDirectory(atPath: external + "/inner", withIntermediateDirectories: true)
        try "x".write(toFile: external + "/inner/f.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/hop", withDestinationPath: external + "/inner")
        let c = try cr()
        // Opening the intermediate "hop" with O_NOFOLLOW → ELOOP → pathEscape, before the leaf.
        assertPathEscape("hop/f.txt") { _ = try c.readData("hop/f.txt") }
    }

    func testTOCTOUSwapAfterFirstReadIsRefused() throws {
        // Simulate the check-then-swap race directly: a benign dir is replaced by a symlink
        // to an attacker dir between uses. The second open must refuse — no stale-string trust.
        let c = try cr()
        try c.writeString("d/f.txt", "real", createParents: true)
        XCTAssertEqual(try c.readString("d/f.txt"), "real")   // first use: legitimate

        // Attacker swaps the directory component for a symlink pointing outside the root.
        try "EVIL".write(toFile: external + "/f.txt", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: root + "/d")
        try FileManager.default.createSymbolicLink(atPath: root + "/d", withDestinationPath: external)

        // Second use must NOT read "EVIL" — O_NOFOLLOW on "d" rejects the swapped symlink.
        assertPathEscape("d/f.txt") { _ = try c.readString("d/f.txt") }
    }

    func testRelativeComponents_rootIsSlash() throws {
        // Pins the rootPath == "/" edge: rootPath + "/" would be "//" and reject valid
        // absolute children. (Read-only on the path logic; just opens the root dir fd.)
        let c = try ConfinedRoot(root: "/")
        XCTAssertEqual(try c.relativeComponents("/etc/hosts"), ["etc", "hosts"])
        XCTAssertEqual(try c.relativeComponents("/"), [])
        XCTAssertEqual(try c.relativeComponents("etc"), ["etc"])
    }

    // MARK: - Held root fd survives a root-pathname swap (Codex CRITICAL)

    func testHeldRootFD_survivesRootPathnameSwap() throws {
        // Construct against the REAL root, then swap the root pathname for a symlink to an
        // external dir. Operations must keep using the original inode via the held O_NOFOLLOW
        // fd — never re-resolve the swapped pathname — so the external target stays unreachable.
        try "orig".write(toFile: root + "/inside.txt", atomically: true, encoding: .utf8)
        try "EVIL".write(toFile: external + "/planted.txt", atomically: true, encoding: .utf8)

        let c = try cr()                                  // opens & holds fd to the real root

        let moved = root + "-moved-\(UUID().uuidString)"
        try FileManager.default.moveItem(atPath: root, toPath: moved)
        try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: external)
        defer {
            try? FileManager.default.removeItem(atPath: root)     // the symlink
            try? FileManager.default.removeItem(atPath: moved)    // the real dir
        }

        // External-only file is unreachable (we did NOT follow the swapped symlink)...
        XCTAssertThrowsError(try c.readString("planted.txt"))
        // ...and the original content is still reachable through the held fd.
        XCTAssertEqual(try c.readString("inside.txt"), "orig")
    }

    // MARK: - Directory listing / walk never traverse a symlinked dir

    func testWalkDoesNotEscapeThroughSymlinkedDir() throws {
        let c = try cr()
        try c.writeString("real.txt", "1", createParents: false)
        try c.writeString("sub/inner.txt", "2", createParents: true)
        try "SECRET".write(toFile: external + "/secret.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root + "/evil", withDestinationPath: external)

        var visited: [String] = []
        try c.walk("", visit: { rel, _ in visited.append(rel) })

        XCTAssertTrue(visited.contains("real.txt"))
        XCTAssertTrue(visited.contains("sub"))
        XCTAssertTrue(visited.contains("sub/inner.txt"))
        // The symlinked dir is never descended → its contents stay invisible.
        XCTAssertFalse(visited.contains("secret.txt"))
        XCTAssertFalse(visited.contains("evil/secret.txt"))
    }

    func testEntriesTagsSymlinkAsNonDir() throws {
        let c = try cr()
        try c.writeString("realfile.txt", "1", createParents: false)
        try c.writeString("realdir/x.txt", "2", createParents: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/linkdir", withDestinationPath: external)

        let entries = try c.entries("")
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.isDir) })
        XCTAssertEqual(byName["realfile.txt"], false)
        XCTAssertEqual(byName["realdir"], true)
        // The symlink is listed but must NEVER be reported as a directory (would invite traversal).
        XCTAssertEqual(byName["linkdir"], false)
    }
}
