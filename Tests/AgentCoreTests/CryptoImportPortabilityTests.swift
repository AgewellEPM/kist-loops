import XCTest
@testable import AgentCore

/// Portability regression for Codex finding P1-B ("Use the cross-platform Crypto module").
///
/// On Linux there is NO system `CryptoKit` module — swift-crypto ships a CryptoKit-compatible
/// API under the product/module name `Crypto` (BoringSSL-backed). `Package.swift` links ONLY
/// `.product(name: "Crypto", package: "swift-crypto")`, so any lingering `import CryptoKit`
/// makes the documented Linux build fail BEFORE compilation.
///
/// The invariant this pins: no Swift file under `Sources/` OR `Tests/` may `import CryptoKit` — the
/// root-package test targets are compiled by `swift test` on Linux too, so a `CryptoKit` import in a
/// TEST is the same landmine as one in Sources/. The two whole-tree walks
/// (`testNoSourceFileImportsCryptoKit`, `testNoTestFileImportsCryptoKit`) are the authoritative guards
/// and catch ANY new site, including files owned by sibling findings. The per-site tests below add one
/// named assertion per known crypto site so a regression tells you EXACTLY which file reverted.
final class CryptoImportPortabilityTests: XCTestCase {

    // MARK: - Repo layout resolution (fail-fast)

    /// Absolute path to `<repo>/Sources`, resolved from this test file's location.
    /// This file lives at `<repo>/Tests/AgentCoreTests/CryptoImportPortabilityTests.swift`,
    /// so the repo root is two directories up from its containing folder, and `Sources` is a sibling.
    private static func sourcesRoot(file: StaticString = #filePath) -> URL {
        let thisFile = URL(fileURLWithPath: "\(file)")
        let repoRoot = thisFile
            .deletingLastPathComponent()   // .../Tests/AgentCoreTests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // .../<repo>
        return repoRoot.appendingPathComponent("Sources", isDirectory: true)
    }

    /// The forbidden import. Anchored to a leading `import` token so an unrelated string literal
    /// or comment mentioning "CryptoKit" does not trip the guard, while a real import — regardless
    /// of leading indentation or a trailing `// comment` — is always caught.
    private func lineIsCryptoKitImport(_ rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("import ") else { return false }
        // Everything after `import`, stripped of a trailing line comment, must be exactly `CryptoKit`.
        var moduleSpec = String(trimmed.dropFirst("import ".count))
        if let commentRange = moduleSpec.range(of: "//") {
            moduleSpec = String(moduleSpec[..<commentRange.lowerBound])
        }
        return moduleSpec.trimmingCharacters(in: .whitespaces) == "CryptoKit"
    }

    /// Recursively collect every `*.swift` file under `root`. Fail-fast: throws if the tree
    /// is missing (a broken checkout should surface loudly, not silently pass on an empty walk).
    private func swiftFiles(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            XCTFail("Sources root not found at \(root.path) — cannot verify crypto-import portability")
            return []
        }
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            XCTFail("Could not enumerate \(root.path)")
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }

    /// Assert a single source file (relative to `Sources/`) does not import CryptoKit.
    /// The failure message names the file and the offending 1-based line number.
    private func assertNoCryptoKitImport(relativePath: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let url = Self.sourcesRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Expected source file missing: Sources/\(relativePath)", file: file, line: line)
            return
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        for (index, rawLine) in contents.components(separatedBy: "\n").enumerated() where lineIsCryptoKitImport(rawLine) {
            XCTFail(
                "Sources/\(relativePath):\(index + 1) imports CryptoKit — use swift-crypto's `Crypto` (Linux has no CryptoKit module).",
                file: file, line: line
            )
        }
    }

    // MARK: - Whole-tree invariant (authoritative guard, covers ALL sites)

    func testNoSourceFileImportsCryptoKit() throws {
        let root = Self.sourcesRoot()
        let files = try swiftFiles(under: root)
        XCTAssertFalse(files.isEmpty, "Walk found zero Swift files under \(root.path) — resolution is wrong")

        var offenders: [String] = []
        for fileURL in files {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, rawLine) in contents.components(separatedBy: "\n").enumerated() where lineIsCryptoKitImport(rawLine) {
                offenders.append("Sources/\(relative):\(index + 1)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Found `import CryptoKit` at \(offenders.count) site(s). Linux has no system CryptoKit \
            module; use swift-crypto's `Crypto` product instead. Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    // MARK: - Per-site assertions (P1-B fix, one named test per crypto site)

    // Each owned P1-B file gets its own assertion so a regression names the exact site.

    func testProviderCatalogUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/ProviderCatalog.swift")
    }

    func testPlanExecutorUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/PlanExecutor.swift")
    }

    func testPlanExecuteLoopUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/PlanExecuteLoop.swift")
    }

    func testWorkspaceExecutionCoordinatorUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Reasoning/WorkspaceExecutionCoordinator.swift")
    }

    func testReasoningTypesUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Reasoning/ReasoningTypes.swift")
    }

    func testBuilderIsolatedWorkspaceTransactionUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Builder/BuilderIsolatedWorkspaceTransaction.swift")
    }

    func testBuilderRunUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Builder/BuilderRun.swift")
    }

    func testBuilderGraphGovernanceAdmissionUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Builder/BuilderGraphGovernanceAdmission.swift")
    }

    func testBuilderWorkspaceManifestUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Builder/BuilderWorkspaceManifest.swift")
    }

    func testBuilderOSProcessSandboxAttestorUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Builder/BuilderOSProcessSandboxAttestor.swift")
    }

    // Sibling site owned by finding P2-H. Pinned here too so the invariant holds across BOTH findings:
    // if P2-H regresses (or was never landed), this named test fails and points at the exact file.
    func testProcessGroupRunnerUsesCrypto() throws {
        try assertNoCryptoKitImport(relativePath: "AgentCore/Tools/ProcessGroupRunner.swift")
    }

    // MARK: - Tests-tree invariant (the AgentCoreTests / KistTests targets `swift test` compiles on Linux)

    /// Absolute path to `<repo>/Tests`, resolved from this test file's location.
    private static func testsRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // .../Tests/AgentCoreTests
            .deletingLastPathComponent()   // .../Tests
    }

    /// A lingering `import CryptoKit` in a TEST file breaks `swift test` on Linux exactly like one in
    /// Sources/. Walk the whole `Tests/` tree and assert none imports CryptoKit. (`mcp-server` is a
    /// separate macOS-only package and is intentionally out of scope.)
    func testNoTestFileImportsCryptoKit() throws {
        let root = Self.testsRoot()
        let files = try swiftFiles(under: root)
        XCTAssertFalse(files.isEmpty, "Walk found zero Swift files under \(root.path) — resolution is wrong")

        var offenders: [String] = []
        for fileURL in files {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            let relative = fileURL.path.replacingOccurrences(of: root.path + "/", with: "")
            for (index, rawLine) in contents.components(separatedBy: "\n").enumerated() where lineIsCryptoKitImport(rawLine) {
                offenders.append("Tests/\(relative):\(index + 1)")
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Found `import CryptoKit` at \(offenders.count) test-tree site(s). `swift test` compiles these \
            on Linux; use swift-crypto's `Crypto` product instead. Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// Named per-site pin for the sibling the Sources-only walk could NOT see — the exact file the P1-B
    /// verifier flagged. A regression here names it without re-running a Linux build.
    func testBuilderIsolatedWorkspaceTransactionTestsUsesCrypto() throws {
        let url = Self.testsRoot().appendingPathComponent("AgentCoreTests/BuilderIsolatedWorkspaceTransactionTests.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)
        for (index, rawLine) in contents.components(separatedBy: "\n").enumerated() where lineIsCryptoKitImport(rawLine) {
            XCTFail("Tests/AgentCoreTests/BuilderIsolatedWorkspaceTransactionTests.swift:\(index + 1) imports CryptoKit — use swift-crypto's `Crypto`.")
        }
    }
}
