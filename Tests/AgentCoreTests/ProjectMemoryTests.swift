import XCTest
import Foundation
@testable import AgentCore

/// Minimal cross-run memory: facts ingestion (+ AGENTS.md/CLAUDE.md), episodic run-log round-trip,
/// and the advisory planning-context preamble.
final class ProjectMemoryTests: XCTestCase {

    private var root: String!
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "mem-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    private var episodesPath: String { root + "/.mythos/memory/episodes.jsonl" }

    private func writeRawEpisodes(_ episodes: [Episode]) throws {
        try FileManager.default.createDirectory(
            atPath: root + "/.mythos/memory", withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let lines = try episodes.map { episode -> String in
            let data = try encoder.encode(episode)
            return try XCTUnwrap(String(data: data, encoding: .utf8))
        }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: URL(fileURLWithPath: episodesPath))
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    func testEmptyMemoryHasNoContent() {
        let mem = ProjectMemory(root: root)
        XCTAssertFalse(mem.hasContent)
        XCTAssertNil(mem.planningContext(now: now))
        XCTAssertTrue(mem.recentEpisodes(now: now).isEmpty)
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
        let t = now.addingTimeInterval(-100)
        for i in 1...7 {
            mem.recordEpisode(Episode(goal: "goal\(i)", success: i.isMultiple(of: 2), summary: "did \(i)", at: t.addingTimeInterval(Double(i))))
        }
        let recent = mem.recentEpisodes(limit: 3, now: now)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.map(\.goal), ["goal5", "goal6", "goal7"])   // newest-last, last 3
        XCTAssertEqual(recent.last?.success, false)                        // goal7 odd → false
        XCTAssertEqual(recent.last?.temporal?.createdAt, t.addingTimeInterval(7))
        XCTAssertNil(recent.last?.temporal?.lastConfirmedAt)
    }

    func testEpisodeStoreCompactsOldestRowsBelowMissionGraphCapacity() throws {
        let mem = ProjectMemory(
            root: root, maxEpisodeRows: 3, maxEpisodeBytes: 4_096)
        for index in 1...6 {
            mem.recordEpisode(Episode(
                goal: "bounded-\(index)", success: true, summary: "ok",
                at: now.addingTimeInterval(Double(index - 10))))
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: episodesPath))
        XCTAssertEqual(
            data.split(separator: 0x0A, omittingEmptySubsequences: true).count, 3)
        XCTAssertLessThanOrEqual(data.count, 4_096)
        XCTAssertEqual(
            mem.recentEpisodes(limit: 10, now: now).map(\.goal),
            ["bounded-4", "bounded-5", "bounded-6"])
    }

    func testOversizedSparseEpisodeStoreReadsOnlyTailAndCompactsOnWrite() throws {
        let memoryDir = root + "/.mythos/memory"
        try FileManager.default.createDirectory(
            atPath: memoryDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: episodesPath, contents: nil))
        let tail = Episode(
            goal: "bounded tail", success: true, summary: "survives",
            at: now.addingTimeInterval(-2))
        let tailRow = try JSONEncoder().encode(tail)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: episodesPath))
        try handle.truncate(atOffset: 16_384)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]) + tailRow + Data([0x0A]))
        try handle.close()

        let store = ProjectMemory(
            root: root, maxEpisodeRows: 10, maxEpisodeBytes: 4_096)
        XCTAssertEqual(
            store.recentEpisodes(limit: 10, now: now).map(\.goal),
            ["bounded tail"])

        store.recordEpisode(Episode(
            goal: "new tail", success: true, summary: "compacts",
            at: now.addingTimeInterval(-1)))
        let compacted = try Data(contentsOf: URL(fileURLWithPath: episodesPath))
        XCTAssertLessThanOrEqual(compacted.count, 4_096)
        XCTAssertEqual(
            store.recentEpisodes(limit: 10, now: now).map(\.goal),
            ["bounded tail", "new tail"])
    }

    func testRecordingPreservesMalformedRawEpisodeRows() throws {
        let memoryDir = root + "/.mythos/memory"
        try FileManager.default.createDirectory(
            atPath: memoryDir, withIntermediateDirectories: true)
        try "{malformed\n".write(
            toFile: episodesPath, atomically: true, encoding: .utf8)

        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "safe append", success: true, summary: "keep raw history",
            at: now.addingTimeInterval(-1)))
        let body = try String(contentsOfFile: episodesPath, encoding: .utf8)
        XCTAssertTrue(body.contains("{malformed"))
        XCTAssertEqual(
            ProjectMemory(root: root).recentEpisodes(limit: 10, now: now).map(\.goal),
            ["safe append"])
    }

    func testEpisodeSurvivesAcrossInstances() {
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "persist", success: true, summary: "ok", at: now.addingTimeInterval(-1)))
        // A fresh instance (next "run") sees the prior episode.
        let again = ProjectMemory(root: root).recentEpisodes(now: now)
        XCTAssertEqual(again.count, 1)
        XCTAssertEqual(again.first?.goal, "persist")
    }

    func testEpisodeCarriesValidatedMissionGraphJoinKeyAcrossInstances() {
        let mission = String(repeating: "a", count: 64)
        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "linked", success: true, summary: "ok",
            at: now.addingTimeInterval(-2), missionID: mission))
        let stored = ProjectMemory(root: root).recentEpisodes(limit: 1, now: now).first
        XCTAssertEqual(stored?.missionID, mission)

        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "untrusted", success: false, summary: "bad id",
            at: now.addingTimeInterval(-1), missionID: "not-a-mission"))
        XCTAssertNil(ProjectMemory(root: root).recentEpisodes(limit: 1, now: now).first?.missionID,
                     "advisory memory must not manufacture a reasoning-graph join from malformed text")
    }

    func testPlanningContextCombinesFactsAndEpisodes() throws {
        try "Build: swift build".write(toFile: root + "/AGENTS.md", atomically: true, encoding: .utf8)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "add feature", success: false, summary: "tests failed",
                                  at: now.addingTimeInterval(-1)))
        let ctx = try XCTUnwrap(mem.planningContext(now: now))
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
                                  at: now.addingTimeInterval(-1)))

        let stored = try XCTUnwrap(mem.recentEpisodes(limit: 1, now: now).first)
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
                          at: now.addingTimeInterval(-2))
        let data = try JSONEncoder().encode(raw)
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: dir + "/episodes.jsonl"))

        let mem = ProjectMemory(root: root)
        XCTAssertEqual(mem.recentEpisodes(limit: 1, now: now).first?.goal, "current exact task")
        let context = try XCTUnwrap(mem.planningContext(now: now))
        XCTAssertLessThanOrEqual(context.count, ProjectMemory.maxPlanningContextCharacters)
        XCTAssertTrue(context.contains("current exact task"))
        XCTAssertFalse(context.contains(String(repeating: "old topic ", count: 100)))
    }

    func testOutOfOrderPhysicalLinesAreSelectedByEventTime() throws {
        try writeRawEpisodes([
            Episode(goal: "latest", success: true, summary: "3",
                    at: now.addingTimeInterval(-10)),
            Episode(goal: "earliest", success: true, summary: "1",
                    at: now.addingTimeInterval(-30)),
            Episode(goal: "middle", success: true, summary: "2",
                    at: now.addingTimeInterval(-20)),
        ])

        let episodes = ProjectMemory(root: root).recentEpisodes(limit: 3, now: now)
        XCTAssertEqual(episodes.map(\.goal), ["earliest", "middle", "latest"])
        XCTAssertEqual(ProjectMemory(root: root).recentEpisodes(limit: 2, now: now).map(\.goal),
                       ["middle", "latest"])
    }

    func testEqualEventTimesUsePhysicalJSONLOrdinal() throws {
        let at = now.addingTimeInterval(-1)
        try writeRawEpisodes([
            Episode(goal: "first", success: true, summary: "1", at: at),
            Episode(goal: "second", success: true, summary: "2", at: at),
            Episode(goal: "third", success: true, summary: "3", at: at),
        ])

        let episodes = ProjectMemory(root: root).recentEpisodes(limit: 2, now: now)
        XCTAssertEqual(episodes.map(\.goal), ["second", "third"])
    }

    func testFuturePoisonAndInvalidEventsFailSoftWithoutHidingSafeRows() throws {
        let safe = now.addingTimeInterval(-1)
        let acceptedSkewBoundary = now.addingTimeInterval(
            MemoryTemporalEnvelope.maximumFutureEvidenceSkew)
        let rejectedFuture = acceptedSkewBoundary.addingTimeInterval(1)
        let futureConfirmation = try MemoryTemporalEnvelope(
            createdAt: safe, lastConfirmedAt: rejectedFuture, pinned: true)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "safe", success: true, summary: "ok", at: safe))
        mem.recordEpisode(Episode(goal: "at-boundary", success: true, summary: "ok",
                                  at: acceptedSkewBoundary))
        mem.recordEpisode(Episode(goal: "future-event", success: true, summary: "poison",
                                  at: rejectedFuture))
        mem.recordEpisode(Episode(goal: "future-confirmation", success: true, summary: "poison",
                                  at: safe, temporal: futureConfirmation))
        mem.recordEpisode(Episode(goal: "not-finite", success: false, summary: "poison",
                                  at: Date(timeIntervalSince1970: .nan)))
        mem.recordEpisode(Episode(goal: "outside-wire", success: false, summary: "poison",
                                  at: Date(timeIntervalSince1970: .greatestFiniteMagnitude)))

        XCTAssertEqual(mem.recentEpisodes(limit: 20, now: now).map(\.goal),
                       ["safe", "at-boundary"])
    }

    func testValidityIsStartInclusiveAndEndExclusive() throws {
        let event = now.addingTimeInterval(-60)
        let end = now.addingTimeInterval(10)
        let temporal = try MemoryTemporalEnvelope(
            createdAt: event, validFrom: now, validUntil: end,
            decayRate: .none, baseSalience: 1)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "windowed", success: true, summary: "ok",
                                  at: event, temporal: temporal))

        XCTAssertTrue(mem.recentEpisodes(now: now.addingTimeInterval(-0.001)).isEmpty)
        XCTAssertEqual(mem.recentEpisodes(now: now).map(\.goal), ["windowed"])
        XCTAssertTrue(mem.recentEpisodes(now: end).isEmpty)
    }

    func testRetiredAndSupersededStayExcludedEvenWhenPinned() throws {
        let old = now.addingTimeInterval(-1_000 * 86_400)
        let activePinned = try MemoryTemporalEnvelope(
            createdAt: old, decayRate: .session, baseSalience: 0.01, pinned: true)
        var retiredPinned = try MemoryTemporalEnvelope(
            createdAt: now.addingTimeInterval(-30), pinned: true)
        try retiredPinned.retire(now: now.addingTimeInterval(-20))
        var supersededPinned = try MemoryTemporalEnvelope(
            createdAt: now.addingTimeInterval(-15), pinned: true)
        try supersededPinned.markSuperseded(by: "replacement", now: now.addingTimeInterval(-10))
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "active-pinned", success: true, summary: "keep",
                                  at: old, temporal: activePinned))
        mem.recordEpisode(Episode(goal: "retired-pinned", success: true, summary: "drop",
                                  at: now.addingTimeInterval(-30), temporal: retiredPinned))
        mem.recordEpisode(Episode(goal: "superseded-pinned", success: true, summary: "drop",
                                  at: now.addingTimeInterval(-15), temporal: supersededPinned))

        XCTAssertEqual(mem.recentEpisodes(limit: 10, now: now).map(\.goal), ["active-pinned"])
    }

    func testLegacyDecodeDerivesOnlyEventBasedTemporalMetadataWithoutWritingItBack() throws {
        let event = now.addingTimeInterval(-60)
        try writeRawEpisodes([
            Episode(goal: "legacy", success: true, summary: "old wire", at: event),
        ])
        let before = try Data(contentsOf: URL(fileURLWithPath: episodesPath))

        let episode = try XCTUnwrap(
            ProjectMemory(root: root).recentEpisodes(limit: 1, now: now).first)
        XCTAssertEqual(episode.temporal?.createdAt, event)
        XCTAssertEqual(episode.temporal?.updatedAt, event)
        XCTAssertEqual(episode.temporal?.accessedAt, event)
        XCTAssertNil(episode.temporal?.lastConfirmedAt)
        XCTAssertNil(episode.temporal?.seasonalWindow)
        XCTAssertEqual(episode.temporal?.accessCount, 0)
        XCTAssertEqual(episode.temporal?.reinforcementCount, 0)
        XCTAssertEqual(episode.temporal?.status, .active)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: episodesPath)), before,
                       "legacy hydration is in-memory only")
    }

    func testRecordRefusesSplitScalarAndEnvelopeEventClocks() throws {
        let scalar = now.addingTimeInterval(-10)
        let mismatched = try MemoryTemporalEnvelope(
            createdAt: scalar.addingTimeInterval(1))

        ProjectMemory(root: root).recordEpisode(Episode(
            goal: "split clock must not persist", success: true, summary: "unsafe",
            at: scalar, temporal: mismatched))

        XCTAssertFalse(FileManager.default.fileExists(atPath: episodesPath),
                       "a rejected write must not manufacture an archive")
    }

    func testRawSplitClockEpisodeIsQuarantinedWithoutReadResurrectionOrMutation() throws {
        let oldScalar = now.addingTimeInterval(-10 * 365 * 86_400)
        let split = Episode(
            goal: "resurrected nested episode", success: true, summary: "unsafe",
            at: oldScalar,
            temporal: try MemoryTemporalEnvelope(
                createdAt: now.addingTimeInterval(-1), decayRate: .none,
                baseSalience: 1, pinned: true))
        let safe = Episode(
            goal: "safe episode", success: true, summary: "eligible",
            at: now.addingTimeInterval(-2))
        try writeRawEpisodes([split, safe])
        let before = try Data(contentsOf: URL(fileURLWithPath: episodesPath))

        XCTAssertEqual(
            ProjectMemory(root: root).recentEpisodes(limit: 10, now: now).map(\.goal),
            ["safe episode"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: episodesPath)), before,
                       "quarantine is read-only and cannot bless the split history")
    }

    func testDecayFloorFiltersWeakEpisodesBeforeRecencySelection() throws {
        let aboveFloorAt = now.addingTimeInterval(-4 * 86_400)
        let belowFloorAt = now.addingTimeInterval(-5 * 86_400)
        let aboveFloor = try MemoryTemporalEnvelope(
            createdAt: aboveFloorAt, decayRate: .session, baseSalience: 1)
        let belowFloor = try MemoryTemporalEnvelope(
            createdAt: belowFloorAt, decayRate: .session, baseSalience: 1)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "above-floor", success: true, summary: "keep",
                                  at: aboveFloorAt, temporal: aboveFloor))
        mem.recordEpisode(Episode(goal: "below-floor", success: true, summary: "drop",
                                  at: belowFloorAt, temporal: belowFloor))

        XCTAssertEqual(aboveFloor.evaluate(at: now).salience, 0.0625, accuracy: 0.000_001)
        XCTAssertEqual(belowFloor.evaluate(at: now).salience, 0.03125, accuracy: 0.000_001)
        XCTAssertEqual(mem.recentEpisodes(limit: 1, now: now).map(\.goal), ["above-floor"],
                       "filtering must happen before the result limit is applied")
    }

    func testOffSeasonEpisodeCanReactivateInItsExplicitSeason() throws {
        let event = date("2025-01-01T00:00:00Z")
        let july = date("2025-07-10T00:00:00Z")
        let nextJanuary = date("2026-01-10T00:00:00Z")
        let season = try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1, offSeasonFactor: 0.01)
        let temporal = try MemoryTemporalEnvelope(
            createdAt: event, seasonalWindow: season,
            decayRate: .none, baseSalience: 0.8)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "January release", success: true, summary: "seasonal",
                                  at: event, temporal: temporal))

        XCTAssertTrue(mem.recentEpisodes(now: july).isEmpty,
                      "off-season downranking may fall below the retrieval floor")
        XCTAssertEqual(mem.recentEpisodes(now: nextJanuary).map(\.goal), ["January release"],
                       "filtering must not permanently prune a recurring memory")
    }

    func testReadsNeverTouchOrReinforceStoredTemporalMetadata() throws {
        let event = now.addingTimeInterval(-60)
        let temporal = try MemoryTemporalEnvelope(
            createdAt: event, accessedAt: event, accessCount: 7,
            reinforcementCount: 2, decayRate: .none, baseSalience: 1)
        let mem = ProjectMemory(root: root)
        mem.recordEpisode(Episode(goal: "read-only", success: true, summary: "stable",
                                  at: event, temporal: temporal))
        let before = try Data(contentsOf: URL(fileURLWithPath: episodesPath))

        let first = try XCTUnwrap(mem.recentEpisodes(limit: 1, now: now).first)
        _ = mem.planningContext(episodeLimit: 1, now: now)
        let second = try XCTUnwrap(mem.recentEpisodes(limit: 1, now: now).first)

        XCTAssertEqual(first.temporal?.accessCount, 7)
        XCTAssertEqual(second.temporal?.accessCount, 7)
        XCTAssertEqual(second.temporal?.reinforcementCount, 2)
        XCTAssertNil(second.temporal?.lastConfirmedAt)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: episodesPath)), before)
    }

    func testCuratedFactsRemainAvailableWhenEveryEpisodeHasDecayed() throws {
        let dir = root + "/.mythos/memory"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "CURATED BUILD FACT".write(
            toFile: dir + "/facts.md", atomically: true, encoding: .utf8)
        let ancient = now.addingTimeInterval(-10 * 365 * 86_400)
        try writeRawEpisodes([
            Episode(goal: "ancient", success: true, summary: "stale", at: ancient),
        ])

        let mem = ProjectMemory(root: root)
        XCTAssertTrue(mem.recentEpisodes(now: now).isEmpty)
        let context = try XCTUnwrap(mem.planningContext(now: now))
        XCTAssertTrue(context.contains("CURATED BUILD FACT"))
        XCTAssertFalse(context.contains("ancient"))
    }
}
