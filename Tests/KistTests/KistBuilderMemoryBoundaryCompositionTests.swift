import Foundation
import XCTest

final class KistBuilderMemoryBoundaryCompositionTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testNestedPlanExecuteReadsHostMemoryWithoutPersistingInsideTransaction() throws {
        let runner = kistRunnerFamilySource()
        XCTAssertTrue(runner.contains("let memoryReadRoot = memoryRoot ?? root"))
        XCTAssertTrue(runner.contains("opts.noMemory || !persistMemoryEpisode"))
        XCTAssertTrue(runner.contains("ProjectMemory(root: memoryReadRoot)"))
        XCTAssertTrue(runner.contains("sessionMemory(root: memoryReadRoot, opts: opts)"))

        let adapter = try source("Sources/Kist/KistRunner+BuilderAdapters.swift")
        XCTAssertTrue(adapter.contains("memoryRoot: root"))
        XCTAssertTrue(adapter.contains("persistMemoryEpisode: false"))
    }
}
