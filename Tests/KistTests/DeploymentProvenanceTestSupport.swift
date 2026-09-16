import Foundation
import Darwin
import XCTest
@testable import Kist

extension DeploymentProvenanceTests {
    final class DataBox: @unchecked Sendable {
        var value = Data()
    }

    struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    func run(
        _ executable: URL,
        arguments: [String] = [],
        environment additions: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputBox = DataBox()
        let errorBox = DataBox()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputBox.value = output.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorBox.value = error.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        process.waitUntilExit()
        readers.wait()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: outputBox.value, as: UTF8.self),
            stderr: String(decoding: errorBox.value, as: UTF8.self))
    }

    func temporaryDirectory(named name: String) throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-provenance-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let canonical = try canonicalURL(raw)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: canonical)
        }
        return canonical
    }

    /// `--provenance-evaluate` deliberately accepts candidates only beneath the
    /// installation home. Keep evaluator fixtures there so the valid-path tests
    /// exercise payload validation instead of failing early when the checkout is
    /// on an external volume.
    func evaluatorScratchDirectory(named name: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let raw = home.appendingPathComponent(
            ".kist-provenance-\(name)-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: raw.path)
        let canonical = try canonicalURL(raw)
        guard canonical.path.hasPrefix(home.path + "/") else {
            throw NSError(
                domain: "DeploymentProvenanceTests",
                code: 2,
                userInfo: [NSFilePathErrorKey: canonical.path])
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: canonical)
        }
        return canonical
    }

    func canonicalURL(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path, nil) else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: url.path])
        }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    func write(
        _ contents: String,
        to url: URL,
        executable: Bool = false
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: url.path)
        }
    }

    func makeCanonicalRepo(in root: URL, name: String) throws -> URL {
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try write(
            """
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "Fixture",
                products: [.executable(name: "kist", targets: ["Kist"])],
                targets: [.executableTarget(name: "Kist")])
            """,
            to: repo.appendingPathComponent("Package.swift"))
        for path in [
            "Sources/Kist/KistRunner.swift",
            "Sources/AgentCore/CaptainOrchestrator.swift",
            "Tests/KistTests/KistOptionsTests.swift",
        ] {
            try write("// fixture\n", to: repo.appendingPathComponent(path))
        }
        return try canonicalURL(repo)
    }

    func installSafeRebuildFakes(in home: URL) throws -> URL {
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try write(
            """
            #!/bin/sh
            set -eu
            if [ "${1-}" = "--validate-deployment" ]; then
              [ "${FAKE_VALIDATE_STATUS-0}" = 0 ] || exit "$FAKE_VALIDATE_STATUS"
              printf 'validated deployment: %s\\n' "${FAKE_DEPLOYED_REPO:?}"
              if [ "${FAKE_LEGACY_VALIDATE-0}" != 1 ]; then
                printf 'manifest-sha256: %s\\n' \
                  "$(/usr/bin/shasum -a 256 "${HOME:?}/bin/kist-current.manifest" | /usr/bin/awk '{print $1}')"
              fi
              exit 0
            fi
            printf 'cwd=%s\\nrepo=%s\\nargs=%s\\n' "$PWD" "${MYTHOS_REPO-}" "$*" >> "${KIST_TEST_LOG:?}"
            """,
            to: bin.appendingPathComponent("kist-rebuild"),
            executable: true)
        try write(
            """
            #!/bin/sh
            [ "${1-}" = "--provenance-validate" ]
            """,
            to: bin.appendingPathComponent("kist-dashboard"),
            executable: true)
        try write(
            """
            #!/bin/sh
            case "${1-}" in
              --help) exit 0 ;;
              --version) printf '%s\\n' 'kist 0.15.0-captain.1'; exit 0 ;;
              *) exit 64 ;;
            esac
            """,
            to: bin.appendingPathComponent("kist"),
            executable: true)
        let safeRebuild = try source("scripts/kist-safe-rebuild.sh")
            .replacingOccurrences(
                of: #"readonly INSTALL_HOME="/Users/lukekist""#,
                with: #"readonly INSTALL_HOME="\#(home.path)""#)
        try write(
            safeRebuild,
            to: bin.appendingPathComponent("kist-safe-rebuild.sh"),
            executable: true)
        return bin
    }

    func installPatchedScript(
        _ relativePath: String,
        in home: URL,
        named name: String
    ) throws -> URL {
        let contents = try source(relativePath)
            .replacingOccurrences(
                of: #"readonly INSTALL_HOME="/Users/lukekist""#,
                with: #"readonly INSTALL_HOME="\#(home.path)""#)
            .replacingOccurrences(
                of: "INSTALL_HOME=/Users/lukekist",
                with: "INSTALL_HOME=\(home.path)")
        let destination = home.appendingPathComponent("bin/\(name)")
        try write(contents, to: destination, executable: true)
        return destination
    }

    func scaffoldCaptainConfig(in home: URL) throws {
        let kistDir = home.appendingPathComponent(".kist/captain-config/kist", isDirectory: true)
        try write(
            "{\"provider\": \"openai\", \"model\": \"gpt-5.5\", \"autoRouting\": true}\n",
            to: kistDir.appendingPathComponent("config.json"))
        try write(
            "{\"profiles\": {\"truth-team\": {\"planner\": \"openai:gpt-5.5\", " +
            "\"worker\": \"deepseek:deepseek-v4-pro\", \"coder\": \"deepseek:deepseek-v4-pro\", " +
            "\"critic\": \"openai:gpt-5.5\"}}}\n",
            to: kistDir.appendingPathComponent("roles.json"))
    }

    func sourceFile(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
