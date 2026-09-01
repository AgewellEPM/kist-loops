import XCTest

/// Pins the 2026-09-01 monolith split: KistRunner+SMLRuntimeExport.swift (6,347 lines) and
/// SMLWorkflowRuntimeBundle.swift (5,884 lines) were split into focused files. One assertion
/// PER FILE so a regrowing file names itself in the failure, and the deleted monolith cannot
/// silently return. Cap = 1,200 (the YELLOW ceiling): a file crossing it must be split before
/// it gains features, not after.
final class SourceFileSizeInvariantTests: XCTestCase {
    private static let lineCap = 1_200

    private static let splitFiles: [String] = [
        "Sources/Kist/KistRunner+SMLRuntimeExportTypes.swift",
        "Sources/Kist/KistRunner+SMLRuntimeScaffoldTypes.swift",
        "Sources/Kist/KistRunner+SMLRuntimeRunbookTypes.swift",
        "Sources/Kist/KistRunner+SMLRuntimeTranscriptTypes.swift",
        "Sources/Kist/KistRunner+SMLRuntimeCommands.swift",
        "Sources/Kist/KistRunner+SMLRuntimeRender.swift",
        "Sources/Kist/KistRunner+SMLRuntimeMake.swift",
        "Sources/Kist/KistRunner+SMLRuntimeScaffoldWriter.swift",
        "Sources/Kist/KistRunner+SMLRuntimeLoaders.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeBundle.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeDescriptors.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeExports.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeRoutes.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeMountContract.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimePlanning.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeRegistry.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeAPI.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeLaunch.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeModelAdapter.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeApp.swift",
        "Sources/AgentCore/SML/SMLWorkflowRuntimeOpenAPIGenerator.swift",
    ]

    private static let deletedMonoliths: [String] = [
        "Sources/Kist/KistRunner+SMLRuntimeExport.swift",
    ]

    private static var packageRoot: URL {
        // Tests/AgentCoreTests/SourceFileSizeInvariantTests.swift → package root is two levels up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEverySplitFileExistsAndStaysUnderTheLineCap() throws {
        for relativePath in Self.splitFiles {
            let url = Self.packageRoot.appendingPathComponent(relativePath)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("split file missing: \(relativePath) — was it renamed without updating this invariant?")
                continue
            }
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).count
            XCTAssertLessThanOrEqual(
                lines, Self.lineCap,
                "\(relativePath) is \(lines) lines — over the \(Self.lineCap) cap. Split it before adding features."
            )
        }
    }

    func testDeletedMonolithsDoNotReturn() {
        for relativePath in Self.deletedMonoliths {
            let url = Self.packageRoot.appendingPathComponent(relativePath)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: url.path),
                "\(relativePath) is back — the monolith was split on 2026-09-01; do not recreate it."
            )
        }
    }
}
