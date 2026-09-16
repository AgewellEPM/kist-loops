import Foundation
import Darwin
import XCTest
@testable import Kist

extension DeploymentProvenanceTests {
    func testUnsignedArtifactRetentionDoesNotTraverseSwiftPMReleaseSymlink() throws {
        let root = try temporaryDirectory(named: "unsigned-retention")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let rebuild = try installPatchedScript(
            "scripts/kist-rebuild", in: home, named: "kist-rebuild")
        let repo = try makeCanonicalRepo(in: root, name: "repo")
        let build = repo.appendingPathComponent(".build", isDirectory: true)
        let swiftPMRelease = build.appendingPathComponent(
            "arm64-apple-macosx/release", isDirectory: true)
        let releaseLink = build.appendingPathComponent("release")
        let swiftPMProduct = swiftPMRelease.appendingPathComponent("kist")
        let candidate = root.appendingPathComponent("unsigned-candidate")
        let retainedDirectory = build.appendingPathComponent(
            ".kist-provenance", isDirectory: true)
        let testing = ["KIST_REBUILD_TESTING": "1"]

        try FileManager.default.createDirectory(
            at: swiftPMRelease, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: releaseLink.path,
            withDestinationPath: "arm64-apple-macosx/release")
        try write(
            "#!/bin/sh\n# SwiftPM product sentinel\n",
            to: swiftPMProduct,
            executable: true)
        try write(
            "#!/bin/sh\n# exact unsigned candidate\n",
            to: candidate,
            executable: true)

        func sourceState() throws -> String {
            let result = try run(
                rebuild,
                arguments: ["--print-source-state", repo.path])
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func publish() throws -> ProcessResult {
            try run(
                rebuild,
                arguments: [
                    "--test-publish-unsigned-artifact", repo.path, candidate.path,
                ],
                environment: testing)
        }
        func retainedHash(_ expected: String) throws -> ProcessResult {
            try run(
                rebuild,
                arguments: [
                    "--test-hash-retained-unsigned-artifact", repo.path,
                    expected,
                ],
                environment: testing)
        }

        let stateBefore = try sourceState()
        var result = try publish()
        XCTAssertEqual(result.status, 0, result.stderr)
        let publishedHash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(publishedHash.count, 64)
        let retained = retainedDirectory.appendingPathComponent(publishedHash)
        result = try retainedHash(publishedHash)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedHash)
        XCTAssertEqual(
            try sourceFile(retained),
            "#!/bin/sh\n# exact unsigned candidate\n")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: releaseLink.path),
            "arm64-apple-macosx/release")
        XCTAssertEqual(
            try sourceFile(swiftPMProduct),
            "#!/bin/sh\n# SwiftPM product sentinel\n",
            "publication must not traverse or replace SwiftPM's release symlink")
        XCTAssertEqual(try sourceState(), stateBefore)
        let retainedDirectoryMode = try XCTUnwrap(
            try FileManager.default.attributesOfItem(
                atPath: retainedDirectory.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(retainedDirectoryMode.intValue & 0o777, 0o700)

        try write(
            "#!/bin/sh\n# second unsigned candidate\n",
            to: candidate,
            executable: true)
        result = try publish()
        XCTAssertEqual(result.status, 0, result.stderr)
        let secondHash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(secondHash, publishedHash)
        result = try retainedHash(publishedHash)
        XCTAssertEqual(
            result.status,
            0,
            "a later candidate destroyed the earlier retained pilot: \(result.stderr)")
        result = try retainedHash(secondHash)
        XCTAssertEqual(result.status, 0, result.stderr)
        try write(
            "#!/bin/sh\n# exact unsigned candidate\n",
            to: candidate,
            executable: true)
        result = try publish()
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedHash)

        let fillers = try (0..<62).map { index -> URL in
            let path = retainedDirectory.appendingPathComponent(
                String(format: "%064x", index + 1))
            try write("#!/bin/sh\n# cache-bound fixture\n", to: path, executable: true)
            return path
        }
        try write(
            "#!/bin/sh\n# cache saturation candidate\n",
            to: candidate,
            executable: true)
        // 2026-08-08: at the cap, publication now EVICTS the oldest and SUCCEEDS (it used to wedge —
        // once 64 accumulated every real deploy died here, freezing all promotions for hours).
        result = try publish()
        XCTAssertEqual(
            result.status,
            0,
            "at the 64-artifact cap, publication must evict the oldest and succeed, not wedge: \(result.stderr)")
        let saturationHash = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(saturationHash.count, 64)
        // the freshly published artifact is retained…
        result = try retainedHash(saturationHash)
        XCTAssertEqual(result.status, 0, "the just-published artifact must survive eviction: \(result.stderr)")
        // …and the cache stayed bounded at ≤ 64 (something old was dropped).
        let boundedCount = try FileManager.default
            .contentsOfDirectory(atPath: retainedDirectory.path)
            .filter { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
            .count
        XCTAssertLessThanOrEqual(boundedCount, 64, "the retention cache must stay bounded after eviction")
        // Tolerant cleanup — one filler may already have been evicted.
        for filler in fillers {
            try? FileManager.default.removeItem(at: filler)
        }
        // Re-publish the pilot so `retained` (publishedHash) exists for the hardlink checks below,
        // regardless of whether it was the one evicted above.
        try write(
            "#!/bin/sh\n# exact unsigned candidate\n",
            to: candidate,
            executable: true)
        result = try publish()
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            publishedHash)

        let hardlink = retainedDirectory.appendingPathComponent("retained-alias")
        try FileManager.default.linkItem(at: retained, to: hardlink)
        result = try retainedHash(publishedHash)
        XCTAssertNotEqual(result.status, 0, "a hardlinked retained artifact was accepted")
        try FileManager.default.removeItem(at: hardlink)
        result = try retainedHash(publishedHash)
        XCTAssertEqual(result.status, 0, result.stderr)

        let outsideVictim = root.appendingPathComponent("outside-victim")
        try write("outside must survive\n", to: outsideVictim, executable: true)
        try FileManager.default.removeItem(at: retained)
        try FileManager.default.createSymbolicLink(
            atPath: retained.path,
            withDestinationPath: outsideVictim.path)
        result = try retainedHash(publishedHash)
        XCTAssertNotEqual(result.status, 0, "a symlinked retained artifact was accepted")
        result = try publish()
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try sourceFile(outsideVictim), "outside must survive\n")
        XCTAssertEqual(
            try sourceFile(retained),
            "#!/bin/sh\n# exact unsigned candidate\n",
            "atomic publication should replace the unsafe name, not its target")

        let outsideDirectory = root.appendingPathComponent(
            "outside-retention", isDirectory: true)
        let outsideMarker = outsideDirectory.appendingPathComponent("marker")
        try write("outside directory must survive\n", to: outsideMarker)
        try FileManager.default.removeItem(at: retainedDirectory)
        try FileManager.default.createSymbolicLink(
            atPath: retainedDirectory.path,
            withDestinationPath: outsideDirectory.path)
        result = try publish()
        XCTAssertNotEqual(result.status, 0, "a symlinked retention directory was accepted")
        XCTAssertEqual(try sourceFile(outsideMarker), "outside directory must survive\n")

        try FileManager.default.removeItem(at: retainedDirectory)
        try FileManager.default.createDirectory(
            at: retainedDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: retainedDirectory.path)
        result = try publish()
        XCTAssertNotEqual(result.status, 0, "a writable retention directory was accepted")

        try FileManager.default.removeItem(at: build)
        let outsideBuild = root.appendingPathComponent("outside-build", isDirectory: true)
        let outsideBuildMarker = outsideBuild.appendingPathComponent("marker")
        try write("outside build must survive\n", to: outsideBuildMarker)
        try FileManager.default.createSymbolicLink(
            atPath: build.path,
            withDestinationPath: outsideBuild.path)
        result = try publish()
        XCTAssertNotEqual(result.status, 0, "a symlinked root build directory was accepted")
        XCTAssertEqual(try sourceFile(outsideBuildMarker), "outside build must survive\n")

        let rebuildSource = try source("scripts/kist-rebuild")
        XCTAssertTrue(
            rebuildSource.contains(
                #"CURRENT_UNSIGNED=$(retained_unsigned_artifact_sha256 "$VALIDATED_ROOT" "$MANIFEST_UNSIGNED")"#))
        XCTAssertTrue(
            rebuildSource.contains(
                #"READ_BACK_UNSIGNED_HASH=$(retained_unsigned_artifact_sha256 "$REPO" "$UNSIGNED_RELEASE_HASH")"#))
        XCTAssertFalse(rebuildSource.contains(#"$VALIDATED_ROOT/.build/release/kist"#))
    }

}
