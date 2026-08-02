import XCTest
import Foundation
@testable import AgentCore

/// Minimal cross-run memory: facts ingestion (+ AGENTS.md/CLAUDE.md), episodic run-log round-trip,
/// and the advisory planning-context preamble.
final class ProjectMemoryTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "mem-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    func testEmptyMemoryHasNoContent() {
        let mem = ProjectMemory(root: root)
        XCTAssertFalse(mem.hasContent)
        XCTAssertNil(mem.planningContext())
        XCTAssertTrue(mem.recentEpisodes().isEmpty)
        XCTAssertEqual(mem.facts(), "")
    }

    func testIngestsAgentsAndClaudeMd() throws {
        try "Build: swift build\nTest: swift test".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        try "Convention: tabs not spaces".write(toFile: root + "/CLAUDE.md", atomically: true, encoding: .utf8)
        let f = ProjectMemory(root: root).facts()
        XCTAssertTrue(f.contains("swift build"))
        XCTAssertTrue(f.contains("tabs not spaces"))
    }

    func testCuratedFactsTakePriority() throws {
        let dir = root + "/.mythos/memory"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "CURATED FACT".write(toFile: dir + "/facts.md", atomically: true, encoding: .utf8)
        try "agents fact".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let f = ProjectMemory(root: root).facts()
        // Curated facts.md comes first in the concatenation.
        XCTAssertTrue(f.hasPrefix("CURATED FACT"))
        XCTAssertTrue(f.contains("agents fact"))
    }

    func testEpisodeRoundTripAndRecency() {
        let mem = ProjectMemory(root: root)
        let t = Date(timeIntervalSince1970: 1000)
        for i in 1...7 {
            mem.recordEpisode(Episode(goal: "goal\(i)", success: i.isMultiple(of: 2), summary: "did \(i)", at: t.addingTimeInterval(Double(i))))
        }
        let recent = mem.recentEpisodes(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.goal), ["goal5", "goal6", "goal7"])   // newest-last, last 3
        XCTAssertEqual(recent.last?.success, false)                        // goal7 odd → false
    }

    func testEpisodeSurvivesAcrossInstances() {
        ProjectMemory(root: root).recordEpisode(Episode(goal: "persist", success: true, summary: "ok", at: Date(timeIntervalSince1970: 1)))
        // A fresh instance (next "run") sees the prior episode.
        let again = ProjectMemory(root: root).recentEpisodes()
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.goal, "persist")
    }

    func testPlanningContextCombinesFactsAndEpisodes() throws {
        try "Build: swift build".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "add feature", success: false, summary: "tests failed", at: Date(timeIntervalSince1970: 1)))
        let ctx = try XCTUnwrap(mem.planningContext())
        XCTAssertTrue(ctx.contains("PROJECT MEMORY"))
        XCTAssertTrue(ctx.contains("NOT instructions"))     // advisory framing
        XCTAssertTrue(ctx.contains("swift build"))          // facts
        XCTAssertTrue(ctx.contains("[failed] add feature: tests failed"))   // episode
    }

    func testFactsAreBounded() throws {
        try String(repeating: "x", count: 20_000).write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectMemory(root: root, maxFactsBytes: 5_000).facts().count, 5_000)
    }

    func testEpisodeStorageStripsRecursiveMemoryWrapperAndBoundsFields() throws {
        let actual = "fix the current whitespace regression"
        let wrapped = "MEMORY — old context:\n" + String(repeating: "stale roadmap ", count: 2_000)
            + "\n\n---\nGOAL:\n" + actual
        let hugeSummary = String(repeating: "result ", count: 2_000)

        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: wrapped, success: true, summary: hugeSummary,
                                  at: Date(timeIntervalSince1970: 1)))

        let stored = try XCTUnwrap(mem.recentEpisodes(limit: 1).first)
        XCTAssertEqual(stored.goal, actual, "episodic memory must store the real request, never its injected memory wrapper")
        XCTAssertLessThanOrEqual(stored.summary.count,
                                 ProjectMemory.maxEpisodeSummaryCharacters + "… [memory clipped]".count)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: root + "/.mythos/memory/episodes.jsonl"))
        XCTAssertLessThan(bytes.count, 4_000, "one episode must stay bounded instead of recursively growing")
    }

    func testExistingOversizedEpisodesAreSanitizedOnReadAndContextIsBounded() throws {
        let dir = root + "/.mythos/memory"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let nested = "MEMORY — prior:\n" + String(repeating: "old topic ", count: 3_000)
            + "\n\n---\nGOAL:\ncurrent exact task"
        let raw = Episode(goal: nested, success: false, summary: String(repeating: "s", count: 20_000),
                          at: Date(timeIntervalSince1970: 2))
        let data = try JSONEncoder().encode(raw)
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: dir + "/episodes.jsonl"))

        let mem = ProjectMemory(root: root)
        XCTAssertEqual(mem.recentEpisodes(limit: 1).first?.goal, "current exact task")
        let context = try XCTUnwrap(mem.planningContext())
        XCTAssertLessThanOrEqual(context.count, ProjectMemory.maxPlanningContextCharacters)
        XCTAssertTrue(context.contains("current exact task"))
        XCTAssertFalse(context.contains(String(repeating: "old topic ", count: 100)))
    }
}
