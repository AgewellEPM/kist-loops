import Foundation
import Darwin
import XCTest
@testable import Kist

final class DeploymentProvenanceTests: XCTestCase {
    func testBuildInfoIsHonestSemanticVersionAndVersionFastPathPrecedesInitialization() throws {
        // Version-agnostic: derived strings must stay consistent with productVersion on every bump
        // (the semver-format check below pins that productVersion itself is a valid version).
        XCTAssertEqual(KistBuildInfo.versionText, "kist \(KistBuildInfo.productVersion)")
        XCTAssertEqual(KistBuildInfo.startupLabel, "v\(KistBuildInfo.productVersion)")
        let semver = try NSRegularExpression(
            pattern: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#)
        let versionRange = NSRange(
            KistBuildInfo.productVersion.startIndex..<KistBuildInfo.productVersion.endIndex,
            in: KistBuildInfo.productVersion)
        XCTAssertNotNil(semver.firstMatch(
            in: KistBuildInfo.productVersion,
            range: versionRange))

        XCTAssertTrue(KistBuildInfo.isVersionRequest(["--version"]))
        XCTAssertTrue(KistBuildInfo.isVersionRequest([
            "--allow-read", "/Volumes", "--allow-shell", "--enable-computer-use", "--version",
        ]), "the captain wrapper's default authority flags must not defeat metadata inspection")
        XCTAssertFalse(KistBuildInfo.isVersionRequest(["version"]))

        let main = try source("Sources/Kist/main.swift")
        let versionGate = try XCTUnwrap(main.range(of: "KistBuildInfo.isVersionRequest"))
        let activeMutation = try XCTUnwrap(main.range(of: #"setenv("KIST_ACTIVE""#))
        let optionParsing = try XCTUnwrap(main.range(of: "KistOptions.parse"))
        XCTAssertLessThan(versionGate.lowerBound, activeMutation.lowerBound)
        XCTAssertLessThan(versionGate.lowerBound, optionParsing.lowerBound)
        XCTAssertTrue(main.contains("print(KistBuildInfo.versionText)"))

        let header = try source("Sources/Kist/UX/StartupHeader.swift")
        XCTAssertTrue(header.contains("KistBuildInfo.startupLabel"))
        XCTAssertFalse(header.contains("KistBuild.label"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repositoryRoot
                .appendingPathComponent("Sources/Kist/UX/KistBuild.swift").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: repositoryRoot.appendingPathComponent("scripts/stamp-build.sh").path))
        XCTAssertFalse(
            try source("scripts/kist-rebuild").contains("stamp-build"),
            "the deployment gate must never rewrite tracked source to stamp itself")
    }

    // The unsigned-artifact provenance cache must AUTO-EVICT the oldest at its cap, not wedge every
    // deploy (2026-08-08: at 64 retained artifacts, publish_unsigned_artifact failed and froze ALL
    // deploys for hours). Pin the eviction + that it stays fail-closed (re-stat before unlink).
    func testProvenanceCacheAutoEvictsAtCap() throws {
        let s = try source("scripts/kist-rebuild")
        XCTAssertTrue(s.contains("AUTO-EVICT oldest-first"),
                      "the provenance cache must evict, not fail, at the retention cap")
        XCTAssertTrue(s.contains("retained_meta.sort()") && s.contains("os.unlink(victim,dir_fd=dfd)"),
                      "eviction must drop the OLDEST (sorted by mtime) under the dir fd")
        XCTAssertTrue(s.contains("vst.st_size!=vsize"),
                      "eviction must re-stat + verify identity before unlink (fail-closed)")
    }

    func testCaptainWrapperSourcesSecretsAndPreservesExplicitAuthority() throws {
        let root = try temporaryDirectory(named: "wrapper")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let capture = root.appendingPathComponent("capture")
        try write(
            "KIST_TEST_SECRET=loaded\nexport KIST_TEST_SECRET\n",
            to: home.appendingPathComponent(".config/kist/secrets.env"))
        try scaffoldCaptainConfig(in: home)
        try write(
            """
            #!/bin/sh
            printf '%s\\n' "${KIST_TEST_SECRET-}" > "${KIST_CAPTURE:?}.secret"
            printf '%s\\n' "${XDG_CONFIG_HOME-}" > "${KIST_CAPTURE:?}.xdg"
            pwd -P > "${KIST_CAPTURE:?}.pwd"
            : > "${KIST_CAPTURE:?}.args"
            for argument in "$@"; do
              printf '%s\\n' "$argument" >> "${KIST_CAPTURE}.args"
            done
            """,
            to: home.appendingPathComponent("bin/kist-current"),
            executable: true)

        let wrapper = try installPatchedScript(
            "scripts/kist-wrapper", in: home, named: "kist")
        let projectDir = root.appendingPathComponent("some-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        var result = try run(
            wrapper,
            environment: ["HOME": home.path, "KIST_CAPTURE": capture.path],
            currentDirectory: projectDir)
        XCTAssertEqual(result.status, 0, result.stderr)
        // The wrapper must NEVER inject --sticky-turns (CLAUDE.md opt-in contract; the 19dbb9c
        // force caused the 2026-08-03 white-out + resize corruption). Authority + roles only.
        let bareArgs = try sourceFile(capture.appendingPathExtension("args"))
        XCTAssertEqual(
            bareArgs,
            "--roles\ntruth-team\n--allow-read\n/Volumes\n--allow-shell\n--enable-computer-use\n")
        XCTAssertFalse(bareArgs.contains("--sticky-turns"),
                       "wrapper must never force --sticky-turns (19dbb9c regression)")
        XCTAssertEqual(
            try sourceFile(capture.appendingPathExtension("secret")),
            "loaded\n")
        // Contract v2: routing/roles config is PINNED — the session must read the captain config
        // root, never ~/.config/kist (the rejected 2026-08-30 account routing).
        XCTAssertEqual(
            try sourceFile(capture.appendingPathExtension("xdg")),
            home.appendingPathComponent(".kist/captain-config").path + "\n")
        // Launching from a real project directory keeps that directory as the project root.
        XCTAssertEqual(
            try sourceFile(capture.appendingPathExtension("pwd")),
            projectDir.path + "\n",
            "a project-directory launch must not be redirected to the captain workspace")

        // Launching from the account HOME must land in the clean captain workspace — a
        // home-rooted session reads ~/.kist directly (the 2026-08-30 contamination).
        result = try run(
            wrapper,
            environment: ["HOME": home.path, "KIST_CAPTURE": capture.path],
            currentDirectory: home)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            try sourceFile(capture.appendingPathExtension("pwd")),
            home.appendingPathComponent(".kist/workspaces/captain").path + "\n",
            "a HOME launch must be redirected into the clean captain workspace")

        let explicit = [
            "--roles", "quality",
            "--enable-computer-use", "--allow-shell", "--allow-read", "/private/tmp/media", "goal",
        ]
        result = try run(
            wrapper,
            arguments: explicit,
            environment: ["HOME": home.path, "KIST_CAPTURE": capture.path],
            currentDirectory: projectDir)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(
            try sourceFile(capture.appendingPathExtension("args")),
            explicit.map { "\($0)\n" }.joined(),
            "explicit caller authority and roles forwarded exactly once in order; nothing injected")

        // Missing pinned captain config must FAIL CLOSED (exit 126), never fall back to
        // ~/.config/kist — that silent fallback would reload the rejected account routing.
        let bareHome = root.appendingPathComponent("bare-home", isDirectory: true)
        try write(
            "#!/bin/sh\nexit 0\n",
            to: bareHome.appendingPathComponent("bin/kist-current"),
            executable: true)
        let unpinnedWrapper = try installPatchedScript(
            "scripts/kist-wrapper", in: bareHome, named: "kist")
        result = try run(
            unpinnedWrapper,
            environment: ["HOME": bareHome.path, "KIST_CAPTURE": capture.path],
            currentDirectory: projectDir)
        XCTAssertEqual(result.status, 126,
                       "wrapper must refuse to run without the pinned captain config")
        XCTAssertTrue(result.stderr.contains("pinned captain config"), result.stderr)

        let attackerHome = root.appendingPathComponent("attacker-home", isDirectory: true)
        let startupMarker = root.appendingPathComponent("hostile-startup-ran")
        let startup = root.appendingPathComponent("hostile-bash-env")
        try write(
            "#!/bin/sh\nexit 91\n",
            to: attackerHome.appendingPathComponent("bin/kist-current"),
            executable: true)
        try write(
            "/usr/bin/touch '\(startupMarker.path)'\n",
            to: startup)
        result = try run(
            wrapper,
            environment: [
                "HOME": attackerHome.path,
                "PATH": attackerHome.appendingPathComponent("bin").path,
                "ENV": startup.path,
                "BASH_ENV": startup.path,
                "KIST_CAPTURE": capture.path,
            ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: startupMarker.path))
        XCTAssertEqual(
            try sourceFile(capture.appendingPathExtension("secret")),
            "loaded\n",
            "the wrapper must source and execute only its fixed installation")
    }

    func testTrackedDeploymentArtifactsAreExecutableProtocolSourcesAndShellValid() throws {
        let artifacts: [(path: String, shell: String, markers: [String])] = [
            (
                "scripts/kist-rebuild",
                "/bin/sh",
                ["kist-safe-rebuild.sh", "--expect-installed-manifest-sha256",
                 "safe-rebuild-sha256"]
            ),
            (
                "scripts/kist-dashboard",
                "/bin/bash",
                ["kist-artifact-closure-v2", "kist-artifact-closure-v3",
                 "safe-rebuild-sha256"]
            ),
            (
                "scripts/kist-wrapper",
                "/bin/sh",
                ["secrets.env", "kist-current"]
            ),
            (
                "scripts/kist-safe-rebuild.sh",
                "/bin/bash",
                ["--expect-installed-manifest-sha256", "validated deployment:"]
            ),
        ]

        for artifact in artifacts {
            let relativePath = artifact.path
            let path = repositoryRoot.appendingPathComponent(relativePath)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path.path), relativePath)
            let syntax = try run(
                URL(fileURLWithPath: artifact.shell),
                arguments: ["-n", path.path])
            XCTAssertEqual(syntax.status, 0, "\(relativePath): \(syntax.stderr)")
            let contents = try source(relativePath)
            for marker in artifact.markers {
                XCTAssertTrue(contents.contains(marker), "\(relativePath) omitted \(marker)")
            }
        }

        for relativePath in ["scripts/kist-wrapper", "scripts/kist-safe-rebuild.sh"] {
            XCTAssertFalse(
                try source(relativePath).contains("kist-integrate-all"),
                "\(relativePath) must never fall back to a checkout name")
        }
    }

    func testV3ClosureEvaluatorBindsPayloadAndExactOperationalStateSeparately() throws {
        let root = try evaluatorScratchDirectory(named: "closure-v3")
        let dashboard = try installPatchedScript(
            "scripts/kist-dashboard", in: root, named: "kist-dashboard")
        let runtime = root.appendingPathComponent(".kist/scripts/kist_runtime.py")
        let cortexApp = root.appendingPathComponent(".kist/cortex/live/app.py")
        let cortexAsset = root.appendingPathComponent(".kist/cortex/live/assets/app.js")
        try write("#!/usr/bin/python3\n# runtime v1\n", to: runtime, executable: true)
        try write("# cortex v1\n", to: cortexApp)
        try write("const cortexV1 = true;\n", to: cortexAsset)
        let payloads = try (0..<5).map { index -> URL in
            let path = root.appendingPathComponent("payload-\(index)")
            try write("#!/bin/sh\n# payload \(index)\n", to: path, executable: true)
            return path
        }

        func evaluate(_ paths: [URL]) throws -> ProcessResult {
            try run(
                dashboard,
                arguments: ["--provenance-evaluate"] + paths.map(\.path))
        }
        func projection(_ output: String) throws -> [String: String] {
            var values: [String: String] = [:]
            for line in output.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, values[parts[0]] == nil else {
                    throw NSError(domain: "DeploymentProvenanceTests", code: 1)
                }
                values[parts[0]] = parts[1]
            }
            return values
        }

        var result = try evaluate(payloads)
        XCTAssertEqual(result.status, 0, result.stderr)
        let before = try projection(result.stdout)
        XCTAssertEqual(
            Set(before.keys),
            Set([
                "binary-sha256", "wrapper-sha256", "dashboard-launcher-sha256",
                "rebuild-sha256", "safe-rebuild-sha256",
                "dashboard-runtime-sha256", "dashboard-cortex-sha256",
                "dashboard-cortex-count",
                "artifact-closure-sha256", "artifact-closure-count",
            ]))
        XCTAssertEqual(before["artifact-closure-count"], "5")
        XCTAssertEqual(before["dashboard-cortex-count"], "2")
        XCTAssertEqual(before["dashboard-runtime-sha256"]?.count, 64)
        XCTAssertEqual(before["dashboard-cortex-sha256"]?.count, 64)

        try write(
            "#!/bin/sh\n# payload 4 changed\n",
            to: payloads[4],
            executable: true)
        result = try evaluate(payloads)
        XCTAssertEqual(result.status, 0, result.stderr)
        let after = try projection(result.stdout)
        XCTAssertNotEqual(after["safe-rebuild-sha256"], before["safe-rebuild-sha256"])
        XCTAssertNotEqual(after["artifact-closure-sha256"], before["artifact-closure-sha256"])
        for key in [
            "binary-sha256", "wrapper-sha256",
            "dashboard-launcher-sha256", "rebuild-sha256",
        ] {
            XCTAssertEqual(after[key], before[key], key)
        }
        XCTAssertEqual(after["dashboard-runtime-sha256"], before["dashboard-runtime-sha256"])
        XCTAssertEqual(after["dashboard-cortex-sha256"], before["dashboard-cortex-sha256"])
        XCTAssertEqual(after["dashboard-cortex-count"], before["dashboard-cortex-count"])

        try write("#!/usr/bin/python3\n# runtime v2\n", to: runtime, executable: true)
        result = try evaluate(payloads)
        XCTAssertEqual(result.status, 0, result.stderr)
        let afterRuntime = try projection(result.stdout)
        XCTAssertNotEqual(
            afterRuntime["dashboard-runtime-sha256"], after["dashboard-runtime-sha256"])
        XCTAssertEqual(
            afterRuntime["dashboard-cortex-sha256"], after["dashboard-cortex-sha256"])
        XCTAssertEqual(afterRuntime["dashboard-cortex-count"], "2")
        XCTAssertEqual(afterRuntime["artifact-closure-sha256"], after["artifact-closure-sha256"])

        try write("# cortex v2\n", to: cortexApp)
        result = try evaluate(payloads)
        XCTAssertEqual(result.status, 0, result.stderr)
        let afterCortex = try projection(result.stdout)
        XCTAssertEqual(
            afterCortex["dashboard-runtime-sha256"], afterRuntime["dashboard-runtime-sha256"])
        XCTAssertNotEqual(
            afterCortex["dashboard-cortex-sha256"], afterRuntime["dashboard-cortex-sha256"])
        XCTAssertEqual(afterCortex["dashboard-cortex-count"], "2")
        XCTAssertEqual(afterCortex["artifact-closure-sha256"], afterRuntime["artifact-closure-sha256"])

        try write("# selected addition\n", to: root.appendingPathComponent(".kist/cortex/live/added.py"))
        result = try evaluate(payloads)
        XCTAssertEqual(result.status, 0, result.stderr)
        let afterAddition = try projection(result.stdout)
        XCTAssertEqual(afterAddition["dashboard-cortex-count"], "3")
        XCTAssertNotEqual(
            afterAddition["dashboard-cortex-sha256"], afterCortex["dashboard-cortex-sha256"])
        XCTAssertEqual(
            afterAddition["artifact-closure-sha256"], afterCortex["artifact-closure-sha256"])

        for invalid in [Array(payloads.prefix(3)), payloads + [payloads[0]]] {
            result = try evaluate(invalid)
            XCTAssertNotEqual(result.status, 0, "invalid evaluator arity was accepted")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: payloads[4].path)
        result = try evaluate(payloads)
        XCTAssertNotEqual(result.status, 0, "writable safe-rebuild payload was accepted")
    }

    func testSigningEvaluationRejectsTamperedAdHocSignedMachO() throws {
        let root = try temporaryDirectory(named: "signing-tamper")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let rebuild = try installPatchedScript(
            "scripts/kist-rebuild", in: home, named: "kist-rebuild")
        let source = root.appendingPathComponent("signed-tool.c")
        let binary = root.appendingPathComponent("signed-tool")
        let marker = "kist-signing-tamper-marker"
        try write(
            """
            static volatile const char marker[] = "\(marker)";
            int main(void) { return marker[0] == '\\0'; }
            """,
            to: source)

        var result = try run(
            URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [source.path, "-o", binary.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        result = try run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", binary.path])
        XCTAssertEqual(result.status, 0, result.stderr)

        result = try run(rebuild, arguments: ["--signing-evaluate", binary.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("signing-type=ad-hoc"), result.stdout)

        var bytes = try Data(contentsOf: binary)
        let markerRange = try XCTUnwrap(bytes.range(of: Data(marker.utf8)))
        let tamperOffset = markerRange.lowerBound + marker.count / 2
        bytes[tamperOffset] = bytes[tamperOffset] ^ 0x01
        try bytes.write(to: binary)

        let metadataOnly = try run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["-d", "--verbose=4", binary.path])
        XCTAssertEqual(
            metadataOnly.status,
            0,
            "the fixture must remain metadata-readable after tampering: \(metadataOnly.stderr)")
        let verification = try run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--strict", "--all-architectures", binary.path])
        XCTAssertNotEqual(
            verification.status,
            0,
            "the fixture mutation did not invalidate its code signature")

        result = try run(rebuild, arguments: ["--signing-evaluate", binary.path])
        XCTAssertNotEqual(
            result.status,
            0,
            "metadata inspection accepted a Mach-O whose signed bytes were tampered")
    }

    func testClosureEvaluatorRejectsHardlinkedPayload() throws {
        let root = try evaluatorScratchDirectory(named: "closure-hardlink")
        let payloads = try (0..<5).map { index -> URL in
            let path = root.appendingPathComponent("payload-\(index)")
            try write("#!/bin/sh\n# payload \(index)\n", to: path, executable: true)
            return path
        }
        let alias = root.appendingPathComponent("payload-alias")
        try FileManager.default.linkItem(at: payloads[0], to: alias)
        let result = try run(
            repositoryRoot.appendingPathComponent("scripts/kist-dashboard"),
            arguments: ["--provenance-evaluate"] + payloads.map(\.path))
        XCTAssertNotEqual(result.status, 0, "hardlinked closure payload was accepted")
    }

    func testFixedLaunchersIgnoreHostileHomePathAndBashStartup() throws {
        let root = try temporaryDirectory(named: "hostile-environment")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = try installSafeRebuildFakes(in: home)
        let dashboard = try installPatchedScript(
            "scripts/kist-dashboard", in: home, named: "kist-dashboard-real")
        let rebuild = try installPatchedScript(
            "scripts/kist-rebuild", in: home, named: "kist-rebuild-real")
        try write(
            "#!/usr/bin/python3\n# trusted fixture runtime\n",
            to: home.appendingPathComponent(".kist/scripts/kist_runtime.py"),
            executable: true)
        try write(
            "# trusted fixture cortex\n",
            to: home.appendingPathComponent(".kist/cortex/live/app.py"))
        let attacker = root.appendingPathComponent("attacker", isDirectory: true)
        let marker = root.appendingPathComponent("startup-marker")
        let startup = root.appendingPathComponent("startup")
        let pythonMarker = root.appendingPathComponent("python-startup-marker")
        let pythonStartup = attacker.appendingPathComponent("sitecustomize.py")
        try write(
            "#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 97\n",
            to: attacker.appendingPathComponent("bash"),
            executable: true)
        try write("/usr/bin/touch '\(marker.path)'\n", to: startup)
        try write(
            "open(\(String(reflecting: pythonMarker.path)), 'w').close()\n",
            to: pythonStartup)
        let hostile = [
            "HOME": attacker.path,
            "PATH": attacker.path,
            "ENV": startup.path,
            "BASH_ENV": startup.path,
            "BASH_FUNC_date%%": "() { /usr/bin/touch '\(marker.path)'; }",
            "PYTHONHOME": attacker.path,
            "PYTHONPATH": attacker.path,
            "PYTHONSTARTUP": pythonStartup.path,
            "PYTHONWARNINGS": "error",
        ]

        var result = try run(dashboard, arguments: ["--help"], environment: hostile)
        XCTAssertEqual(result.status, 0, result.stderr)
        result = try run(
            bin.appendingPathComponent("kist-safe-rebuild.sh"),
            arguments: ["--help"],
            environment: hostile)
        XCTAssertEqual(result.status, 0, result.stderr)
        let repo = try makeCanonicalRepo(in: root, name: "repo")
        result = try run(
            rebuild,
            arguments: ["--print-source-state", repo.path],
            environment: hostile)
        XCTAssertEqual(result.status, 0, result.stderr)

        let evaluatorPayloads = try (0..<5).map { index -> URL in
            let path = home.appendingPathComponent("payload-\(index)")
            try write("#!/bin/sh\n# payload \(index)\n", to: path, executable: true)
            return path
        }
        result = try run(
            dashboard,
            arguments: ["--provenance-evaluate"] + evaluatorPayloads.map(\.path),
            environment: hostile)
        XCTAssertEqual(result.status, 0, result.stderr)

        let safeLog = root.appendingPathComponent("safe-rebuild.log")
        result = try run(
            bin.appendingPathComponent("kist-safe-rebuild.sh"),
            arguments: ["--repo", repo.path, "--skip-service-stop"],
            environment: hostile.merging(["KIST_TEST_LOG": safeLog.path]) { _, new in new })
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: pythonMarker.path),
            "hostile Python startup code ran before a privileged validator")

        let rebuildSource = try source("scripts/kist-rebuild")
        XCTAssertTrue(rebuildSource.contains("SWIFT=/usr/bin/swift"))
        XCTAssertTrue(rebuildSource.contains("/usr/bin/env -i HOME="))
        XCTAssertTrue(rebuildSource.contains("PYTHONNOUSERSITE=1"))
        XCTAssertFalse(rebuildSource.contains("&& swift build"))
        XCTAssertFalse(rebuildSource.contains("\nswift build"))
    }

    func testPrivateSourceSnapshotBindsKistConfigurationAndExcludesOnlyTelemetry() throws {
        let root = try temporaryDirectory(named: "source-snapshot")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let rebuild = try installPatchedScript(
            "scripts/kist-rebuild", in: home, named: "kist-rebuild")
        let repo = try makeCanonicalRepo(in: root, name: "repo")
        let agent = repo.appendingPathComponent(".kist/agents/reviewer.md")
        let usage = repo.appendingPathComponent(".kist/usage.jsonl")
        let runEvent = repo.appendingPathComponent(".kist/runs/run-1/events.jsonl")
        let nestedSource = repo.appendingPathComponent(
            "Sources/Kist/node_modules/Explicit.swift")
        let canonicalScript = repo.appendingPathComponent("scripts/kist-wrapper")
        let plan = repo.appendingPathComponent(".kist/plan.json")
        let modeSensitiveDirectory = repo.appendingPathComponent(
            "Sources/Kist/ModeSensitive", isDirectory: true)
        let alternateBuildCache = repo.appendingPathComponent(
            ".build-local", isDirectory: true)
        let alternateBuildNearMiss = repo.appendingPathComponent(
            ".build-local-source/Tracked.swift")
        try write("reviewer-v1\n", to: agent)
        try write("#!/bin/sh\n# canonical fixture\n", to: canonicalScript, executable: true)
        try write("{\"plan\":\"bound\"}\n", to: plan)
        try FileManager.default.createDirectory(
            at: modeSensitiveDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o750], ofItemAtPath: modeSensitiveDirectory.path)

        func sourceState(of selectedRepo: URL) throws -> String {
            let result = try run(
                rebuild,
                arguments: ["--print-source-state", selectedRepo.path])
            XCTAssertEqual(result.status, 0, result.stderr)
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func snapshot(named name: String) throws -> (URL, String) {
            let destination = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: destination.path)
            let result = try run(
                rebuild,
                arguments: ["--test-snapshot-source", repo.path, destination.path],
                environment: ["KIST_REBUILD_TESTING": "1"])
            XCTAssertEqual(result.status, 0, result.stderr)
            return (
                destination,
                result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let initial = try sourceState(of: repo)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: modeSensitiveDirectory.path)
        XCTAssertNotEqual(
            try sourceState(of: repo),
            initial,
            "a child directory mode change must change the bound source state")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o750], ofItemAtPath: modeSensitiveDirectory.path)
        XCTAssertEqual(try sourceState(of: repo), initial)

        let renamedDirectory = repo.appendingPathComponent(
            "Sources/Kist/ModeSensitiveRenamed", isDirectory: true)
        try FileManager.default.moveItem(at: modeSensitiveDirectory, to: renamedDirectory)
        XCTAssertNotEqual(
            try sourceState(of: repo),
            initial,
            "an empty child directory path change must change the bound source state")
        try FileManager.default.moveItem(at: renamedDirectory, to: modeSensitiveDirectory)
        XCTAssertEqual(try sourceState(of: repo), initial)

        let alternateBuildTarget = alternateBuildCache.appendingPathComponent(
            "arm64-apple-macosx/debug", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alternateBuildTarget, withIntermediateDirectories: true)
        try write(
            "ignored SwiftPM cache\n",
            to: alternateBuildTarget.appendingPathComponent("cache-entry"))
        try FileManager.default.createSymbolicLink(
            atPath: alternateBuildCache.appendingPathComponent("debug").path,
            withDestinationPath: "arm64-apple-macosx/debug")
        XCTAssertEqual(
            try sourceState(of: repo),
            initial,
            "the exact root alternate SwiftPM cache must not affect source identity")

        let first = try snapshot(named: "snapshot-one")
        XCTAssertEqual(first.1, initial)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.0.appendingPathComponent(".build-local").path),
            "the private source snapshot must omit the root alternate SwiftPM cache")
        let snapshottedDirectoryAttributes = try FileManager.default.attributesOfItem(
            atPath: first.0.appendingPathComponent("Sources/Kist/ModeSensitive").path)
        let snapshottedDirectoryMode = try XCTUnwrap(
            snapshottedDirectoryAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(
            snapshottedDirectoryMode.intValue & 0o777,
            0o750,
            "the private snapshot must preserve child directory modes")
        XCTAssertEqual(
            try sourceFile(first.0.appendingPathComponent(".kist/agents/reviewer.md")),
            "reviewer-v1\n")
        XCTAssertEqual(
            try sourceFile(first.0.appendingPathComponent("scripts/kist-wrapper")),
            "#!/bin/sh\n# canonical fixture\n")
        XCTAssertEqual(
            try sourceFile(first.0.appendingPathComponent(".kist/plan.json")),
            "{\"plan\":\"bound\"}\n")

        try write("reviewer-transient\n", to: agent)
        XCTAssertEqual(
            try sourceFile(first.0.appendingPathComponent(".kist/agents/reviewer.md")),
            "reviewer-v1\n",
            "the private snapshot must not alias later original-tree writes")
        try write("reviewer-v1\n", to: agent)
        XCTAssertEqual(try sourceState(of: repo), initial)

        try FileManager.default.removeItem(at: alternateBuildCache)
        try write("not a build directory\n", to: alternateBuildCache)
        let wrongBuildCacheType = try run(
            rebuild,
            arguments: ["--print-source-state", repo.path])
        XCTAssertNotEqual(
            wrongBuildCacheType.status,
            0,
            "a regular file must not masquerade as the excluded alternate build directory")
        try FileManager.default.removeItem(at: alternateBuildCache)
        XCTAssertEqual(try sourceState(of: repo), initial)

        let nestedAlternateBuild = repo.appendingPathComponent(
            "Sources/Kist/.build-local/Hidden.swift")
        try write("// nested generated cache is excluded\n", to: nestedAlternateBuild)
        XCTAssertEqual(
            try sourceState(of: repo),
            initial,
            "known build-output directories must be excluded at any depth")
        try FileManager.default.removeItem(
            at: nestedAlternateBuild.deletingLastPathComponent())
        XCTAssertEqual(try sourceState(of: repo), initial)

        let nestedBuildCache = nestedAlternateBuild.deletingLastPathComponent()
        try write("not a nested build directory\n", to: nestedBuildCache)
        let wrongNestedBuildCacheType = try run(
            rebuild,
            arguments: ["--print-source-state", repo.path])
        XCTAssertNotEqual(
            wrongNestedBuildCacheType.status,
            0,
            "a nested regular file must not masquerade as an excluded build directory")
        try FileManager.default.removeItem(at: nestedBuildCache)
        XCTAssertEqual(try sourceState(of: repo), initial)

        try write("// root near-miss remains bound\n", to: alternateBuildNearMiss)
        XCTAssertNotEqual(
            try sourceState(of: repo),
            initial,
            "the alternate build exclusion must not broaden to root path prefixes")
        try FileManager.default.removeItem(
            at: alternateBuildNearMiss.deletingLastPathComponent())
        XCTAssertEqual(try sourceState(of: repo), initial)

        try write(
            (try sourceFile(first.0.appendingPathComponent("Package.swift")))
                + "\n// in-snapshot mutation\n",
            to: first.0.appendingPathComponent("Package.swift"))
        XCTAssertNotEqual(
            try sourceState(of: first.0),
            first.1,
            "a deterministic in-snapshot mutation must change the bound state")

        try FileManager.default.createDirectory(at: usage, withIntermediateDirectories: false)
        try write("hidden\n", to: usage.appendingPathComponent("hidden-source"))
        let wrongType = try run(
            rebuild,
            arguments: ["--print-source-state", repo.path])
        XCTAssertNotEqual(
            wrongType.status,
            0,
            "a directory must not masquerade as the excluded usage telemetry file")
        try FileManager.default.removeItem(at: usage)

        try write("{\"usage\":1}\n", to: usage)
        try write("{\"event\":1}\n", to: runEvent)
        XCTAssertEqual(try sourceState(of: repo), initial)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.0.appendingPathComponent(".kist/usage.jsonl").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.0.appendingPathComponent(".kist/runs").path))

        try write("reviewer-v2\n", to: agent)
        let agentChanged = try sourceState(of: repo)
        XCTAssertNotEqual(agentChanged, initial)
        try write("// explicit nested source\n", to: nestedSource)
        let nestedChanged = try sourceState(of: repo)
        XCTAssertNotEqual(nestedChanged, agentChanged)
        let second = try snapshot(named: "snapshot-two")
        XCTAssertEqual(second.1, nestedChanged)
        XCTAssertEqual(
            try sourceFile(
                second.0.appendingPathComponent(
                    "Sources/Kist/node_modules/Explicit.swift")),
            "// explicit nested source\n")
    }

    func testSafeRebuildExplicitRepoWinsWithoutInstalledProvenance() throws {
        let root = try temporaryDirectory(named: "explicit")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = try installSafeRebuildFakes(in: home)
        let selected = try makeCanonicalRepo(in: root, name: "selected")
        let ignored = try makeCanonicalRepo(in: root, name: "ignored")
        let log = root.appendingPathComponent("rebuild.log")

        let result = try run(
            bin.appendingPathComponent("kist-safe-rebuild.sh"),
            arguments: [
                "--repo", selected.path, "--retries", "0", "--skip-service-stop",
            ],
            environment: [
                "HOME": home.path,
                "TMPDIR": root.path,
                "KIST_TEST_LOG": log.path,
                "KIST_MYTHOS_REPO": ignored.path,
                "MYTHOS_REPO": ignored.path,
            ])
        XCTAssertEqual(result.status, 0, result.stderr)
        let record = try sourceFile(log)
        XCTAssertTrue(record.contains("cwd=\(selected.path)\n"), record)
        XCTAssertTrue(record.contains("repo=\(selected.path)\n"), record)
        XCTAssertTrue(record.contains("args=--force\n"), record)
        XCTAssertFalse(record.contains(ignored.path), record)
    }

    func testSafeRebuildUsesOnlyValidatedManifestWorktree() throws {
        let root = try temporaryDirectory(named: "manifest")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = try installSafeRebuildFakes(in: home)
        let deployed = try makeCanonicalRepo(in: root, name: "deployed")
        let other = try makeCanonicalRepo(in: root, name: "other")
        let log = root.appendingPathComponent("rebuild.log")
        try write(
            "schema: 4\nworktree: \(deployed.path)\n",
            to: bin.appendingPathComponent("kist-current.manifest"))

        var result = try run(
            bin.appendingPathComponent("kist-safe-rebuild.sh"),
            arguments: ["--retries", "0", "--skip-service-stop"],
            environment: [
                "HOME": home.path,
                "TMPDIR": root.path,
                "KIST_TEST_LOG": log.path,
                "FAKE_DEPLOYED_REPO": other.path,
            ])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("does not match the manifest worktree"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))

        result = try run(
            bin.appendingPathComponent("kist-safe-rebuild.sh"),
            arguments: ["--retries", "0", "--skip-service-stop"],
            environment: [
                "HOME": home.path,
                "TMPDIR": root.path,
                "KIST_TEST_LOG": log.path,
                "FAKE_DEPLOYED_REPO": deployed.path,
            ])
        XCTAssertEqual(result.status, 0, result.stderr)
        let record = try sourceFile(log)
        XCTAssertTrue(record.contains("cwd=\(deployed.path)\n"), record)
        XCTAssertTrue(record.contains("repo=\(deployed.path)\n"), record)
        let argumentLine = try XCTUnwrap(
            record.split(separator: "\n").first { $0.hasPrefix("args=") })
        let arguments = argumentLine.dropFirst("args=".count).split(separator: " ").map(String.init)
        XCTAssertEqual(arguments.count, 3, String(argumentLine))
        XCTAssertEqual(arguments[0], "--force")
        XCTAssertEqual(arguments[1], "--expect-installed-manifest-sha256")
        XCTAssertEqual(arguments[2].count, 64)
        XCTAssertTrue(arguments[2].allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    func testSafeRebuildLegacyBootstrapOmitsUnsupportedCASOption() throws {
        let root = try temporaryDirectory(named: "legacy-bootstrap")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = try installSafeRebuildFakes(in: home)
        let deployed = try makeCanonicalRepo(in: root, name: "deployed")
        let log = root.appendingPathComponent("rebuild.log")
        try write(
            "schema: 4\nworktree: \(deployed.path)\n",
            to: bin.appendingPathComponent("kist-current.manifest"))

        let result = try run(
            bin.appendingPathComponent("kist-safe-rebuild.sh"),
            arguments: ["--retries", "0", "--skip-service-stop"],
            environment: [
                "HOME": home.path,
                "TMPDIR": root.path,
                "KIST_TEST_LOG": log.path,
                "FAKE_DEPLOYED_REPO": deployed.path,
                "FAKE_LEGACY_VALIDATE": "1",
            ])
        XCTAssertEqual(result.status, 0, result.stderr)
        let record = try sourceFile(log)
        XCTAssertTrue(record.contains("args=--force\n"), record)
        XCTAssertFalse(record.contains("--expect-installed-manifest-sha256"), record)
    }

    func testSafeRebuildFailsClosedWhenInstalledProvenanceIsMissing() throws {
        let root = try temporaryDirectory(named: "missing")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = try installSafeRebuildFakes(in: home)
        let log = root.appendingPathComponent("rebuild.log")

        let result = try run(
            bin.appendingPathComponent("kist-safe-rebuild.sh"),
            arguments: ["--retries", "0", "--skip-service-stop"],
            environment: [
                "HOME": home.path,
                "TMPDIR": root.path,
                "KIST_TEST_LOG": log.path,
            ])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("provenance is missing"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))
    }

    func testDeploymentProtocolFixtureCoversBoundV3OldV3AndLegacyRecovery() throws {
        let fixture = repositoryRoot
            .appendingPathComponent("scripts/tests/kist-deployment-protocol.sh")
        let fixtureSource = try source("scripts/tests/kist-deployment-protocol.sh")
        XCTAssertTrue(fixtureSource.contains("partial-v3-operational-binding"))
        XCTAssertTrue(fixtureSource.contains("UNBOUND_V3_ARCHIVE_ID"))
        XCTAssertTrue(fixtureSource.contains("bound-operational-rollback"))
        XCTAssertTrue(fixtureSource.contains("post-validation-cortex-drift"))
        XCTAssertTrue(fixtureSource.contains("legacy-operational-closure"))
        let result = try run(fixture)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(
            result.stdout.contains("PASS kist deployment protocol"),
            result.stdout)
    }


}
