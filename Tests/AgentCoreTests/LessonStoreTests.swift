import XCTest
@testable import AgentCore

final class LessonStoreTests: XCTestCase {
    private static let testNow = Date(timeIntervalSince1970: 100)

    private func tempStore() -> (LessonStore, String) {
        let path = NSTemporaryDirectory() + "lessons_\(UUID().uuidString).jsonl"
        return (LessonStore(path: path, capacity: 100, now: { Self.testNow }), path)
    }

    func testProvenWithoutSourceCoercedToObstacle() {
        // Honesty invariant: can't claim proven without a real source.
        let sourceless = Lesson(kind: .proven, text: "X works", source: nil, at: 1.0)
        XCTAssertEqual(sourceless.kind, .obstacle)
        let sourced = Lesson(kind: .proven, text: "X works", source: "signoff#7", at: 1.0)
        XCTAssertEqual(sourced.kind, .proven)
    }

    func testExtractKeywordsDropsStopwordsAndShorts() {
        let kw = Lesson.extractKeywords("The migration of the database to Postgres failed on indexes")
        XCTAssertTrue(kw.contains("migration"))
        XCTAssertTrue(kw.contains("postgres"))
        XCTAssertFalse(kw.contains("the"))
        XCTAssertFalse(kw.contains("to"))
    }

    func testRecordRetrieveRanksByKeywordOverlap() {
        let (store, path) = tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.record(Lesson(kind: .proven, text: "Postgres migrations need a lock timeout", source: "s1", at: 1))
        store.record(Lesson(kind: .obstacle, text: "Redis cache stampede on cold start", source: nil, at: 2))

        let hits = store.retrieve(forGoal: "fix the postgres migration", limit: 5)
        XCTAssertEqual(hits.first?.text, "Postgres migrations need a lock timeout")
        XCTAssertTrue(store.retrieve(forGoal: "unrelated dinosaurs", limit: 5).isEmpty)
    }

    func testObstaclesOutrankProvenOnEqualOverlap() {
        let (store, path) = tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.record(Lesson(kind: .proven, text: "deploy pipeline green", source: "s1", at: 1))
        store.record(Lesson(kind: .obstacle, text: "deploy pipeline flaky on cache", source: nil, at: 1))
        let hits = store.retrieve(forGoal: "deploy pipeline", limit: 2)
        XCTAssertEqual(hits.first?.kind, .obstacle)   // 1.2× weight
    }

    func testPersistsAcrossInstancesAndDedupes() {
        let (store, path) = tempStore()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let lesson = Lesson(kind: .obstacle, text: "watch the rate limit", source: nil, at: 5)
        store.record(lesson)
        store.record(lesson)                          // dedupe by id
        let reopened = LessonStore(path: path)
        XCTAssertEqual(reopened.all().count, 1)
    }

    func testLessonIdIsStableAcrossTimestamps() {
        let a = Lesson(kind: .obstacle, text: "watch the rate limit", source: nil, at: 5)
        let b = Lesson(kind: .obstacle, text: "watch the rate limit", source: nil, at: 999)
        XCTAssertEqual(a.id, b.id)
    }

    func testLessonTextRedactsSecretsAndHomePathBeforeStorage() {
        let raw = "failed in \(NSHomeDirectory()) with key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"
        let lesson = Lesson(kind: .obstacle, text: raw, source: nil, at: 1)
        XCTAssertFalse(lesson.text.contains(NSHomeDirectory()))
        XCTAssertFalse(lesson.text.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"))
        XCTAssertTrue(lesson.text.contains("~"))
    }

    func testConcurrentRecordsDoNotLoseLessons() {
        let (store, path) = tempStore()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let group = DispatchGroup()
        for i in 0..<40 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                store.record(Lesson(kind: .obstacle, text: "obstacle \(i)", source: nil, at: Double(i)))
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(store.all().count, 40)
    }

    func testPrimerLabelsKindAndIsAdvisory() {
        let (store, path) = tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.record(Lesson(kind: .proven, text: "use a lock timeout", source: "s1", at: 1))
        let primer = store.primer(forGoal: "lock timeout", limit: 3)
        XCTAssertNotNil(primer)
        XCTAssertTrue(primer!.contains("advisory"))
        XCTAssertTrue(primer!.contains("✓ proven"))
    }

    func testLegacyHydrationIsReadOnlyAndInventsNoConfirmationOrSeason() throws {
        let (store, path) = tempStore()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let raw = """
        {"id":"obstacle:-:c74dbb04ae5813f6","kind":"obstacle","text":"legacy cache warning","keywords":["legacy","cache","warning"],"at":1}
        """
        // Decode once to use the initializer's canonical ID rather than
        // trusting the illustrative hand-written ID above.
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let decoded = try JSONDecoder().decode(Lesson.self, from: Data(raw.utf8))
        object["id"] = decoded.id
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: path))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        let recalled = try XCTUnwrap(
            store.retrieve(forGoal: "cache warning", at: Self.testNow).first)
        XCTAssertEqual(recalled.temporal?.createdAt, Date(timeIntervalSince1970: 1))
        XCTAssertNil(recalled.temporal?.lastConfirmedAt)
        XCTAssertNil(recalled.temporal?.seasonalWindow)
        XCTAssertEqual(recalled.temporal?.accessCount, 0)
        XCTAssertEqual(recalled.temporal?.reinforcementCount, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    func testRecordRefusesSplitScalarAndEnvelopeEventClocks() throws {
        let (store, path) = tempStore()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let scalar = Date(timeIntervalSince1970: 1)
        let mismatched = try MemoryTemporalEnvelope(
            createdAt: scalar.addingTimeInterval(1))

        store.record(Lesson(
            kind: .obstacle, text: "split clock must not persist", source: nil,
            at: scalar.timeIntervalSince1970, temporal: mismatched))

        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "a rejected write must not manufacture an archive")
    }

    func testRawSplitClockLessonIsQuarantinedWithoutReadResurrectionOrMutation() throws {
        let (store, path) = tempStore()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let oldScalar = Date(timeIntervalSince1970: 1)
        let recentNested = Self.testNow.addingTimeInterval(-1)
        let split = Lesson(
            kind: .obstacle, text: "cache resurrected by nested time", source: nil,
            at: oldScalar.timeIntervalSince1970,
            temporal: try MemoryTemporalEnvelope(
                createdAt: recentNested, decayRate: .none, baseSalience: 1,
                pinned: true))
        let safe = Lesson(
            kind: .obstacle, text: "cache safe event", source: nil,
            at: Self.testNow.addingTimeInterval(-2).timeIntervalSince1970)
        let encoder = JSONEncoder()
        let body = try [split, safe].map {
            String(decoding: try encoder.encode($0), as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try Data(body.utf8).write(to: URL(fileURLWithPath: path))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        XCTAssertEqual(
            store.retrieve(forGoal: "cache", limit: 10, at: Self.testNow).map(\.text),
            ["cache safe event"])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before,
                       "quarantine is read-only and cannot bless the split history")
    }

    func testExactHalfLifeAndReadsNeverReinforce() throws {
        let now = Date(timeIntervalSince1970: 20_000_000)
        let created = now.addingTimeInterval(-180 * 86_400)
        let temporal = try MemoryTemporalEnvelope(
            createdAt: created, decayRate: .slow, baseSalience: 1)
        let lesson = Lesson(
            kind: .proven, text: "migration lock timeout", source: "receipt-locator",
            at: created.timeIntervalSince1970, temporal: temporal)
        let projection = try XCTUnwrap(
            LessonStore.temporalProjection(lesson, physicalOrdinal: 0, now: now))
        XCTAssertEqual(projection.salience, 0.5, accuracy: 0.000_001)

        let (store, path) = tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.record(lesson)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = store.retrieve(forGoal: "migration lock", at: now)
        _ = store.primer(forGoal: "migration lock", at: now)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    func testOffSeasonLessonReactivatesWithoutBeingRewritten() throws {
        let january = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
        let july = ISO8601DateFormatter().date(from: "2025-07-10T00:00:00Z")!
        let nextJanuary = ISO8601DateFormatter().date(from: "2026-01-10T00:00:00Z")!
        let season = try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1, offSeasonFactor: 0.01)
        let temporal = try MemoryTemporalEnvelope(
            createdAt: january, seasonalWindow: season,
            decayRate: .none, baseSalience: 0.8)
        let (store, path) = tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        store.record(Lesson(
            kind: .obstacle, text: "January release rollback", source: nil,
            at: january.timeIntervalSince1970, temporal: temporal))
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        XCTAssertTrue(store.retrieve(
            forGoal: "release rollback", at: july).isEmpty)
        XCTAssertEqual(store.retrieve(
            forGoal: "release rollback", at: nextJanuary).count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
    }

    func testRetiredExpiredAndFutureEvidenceStayExcludedWhenPinned() throws {
        let now = Date(timeIntervalSince1970: 30_000_000)
        let event = now.addingTimeInterval(-60)
        var retired = try MemoryTemporalEnvelope(createdAt: event, pinned: true)
        try retired.retire(now: event.addingTimeInterval(1))
        let expired = try MemoryTemporalEnvelope(
            createdAt: event, validUntil: now, pinned: true)
        let future = try MemoryTemporalEnvelope(
            createdAt: event,
            lastConfirmedAt: now.addingTimeInterval(
                MemoryTemporalEnvelope.maximumFutureEvidenceSkew + 1),
            pinned: true)
        let active = try MemoryTemporalEnvelope(createdAt: event, pinned: true)
        let (store, path) = tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        for (text, temporal) in [
            ("deploy retired", retired), ("deploy expired", expired),
            ("deploy future", future), ("deploy active", active),
        ] {
            store.record(Lesson(
                kind: .obstacle, text: text, source: nil,
                at: event.timeIntervalSince1970, temporal: temporal))
        }

        XCTAssertEqual(
            store.retrieve(forGoal: "deploy", limit: 10, at: now).map(\.text),
            ["deploy active"])
    }

    func testMalformedRowDoesNotHideSafeEqualTimeRowsAndPhysicalTieIsStable() throws {
        let (store, path) = tempStore()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = Lesson(kind: .obstacle, text: "cache first", source: nil, at: 1)
        let second = Lesson(kind: .obstacle, text: "cache second", source: nil, at: 1)
        let encoder = JSONEncoder()
        let body = [
            String(decoding: try encoder.encode(first), as: UTF8.self),
            "{malformed",
            String(decoding: try encoder.encode(second), as: UTF8.self),
        ].joined(separator: "\n") + "\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            store.retrieve(forGoal: "cache", limit: 2, at: Self.testNow).map(\.text),
            ["cache second", "cache first"])
    }

    func testMalformedLessonArchiveIsNeverRewrittenAsAPartialDecode() throws {
        let (store, path) = tempStore()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        let safe = Lesson(
            kind: .obstacle, text: "cache safe", source: nil, at: 1)
        let row = String(decoding: try JSONEncoder().encode(safe), as: UTF8.self)
        let body = row + "\n{malformed\n"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))

        store.record(Lesson(
            kind: .obstacle, text: "cache must not overwrite", source: nil, at: 2))

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertEqual(
            store.retrieve(forGoal: "cache", limit: 10, at: Self.testNow).map(\.text),
            ["cache safe"])
    }

    func testOversizedSparseLessonArchiveReadsTailAndCompactsOnWrite() throws {
        let (store, path) = tempStore()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".lock")
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
        let tail = Lesson(
            kind: .obstacle, text: "bounded lesson tail", source: nil, at: 1)
        let tailRow = try JSONEncoder().encode(tail)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: UInt64(LessonStore.maximumFileBytes * 2))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x0A]) + tailRow + Data([0x0A]))
        try handle.close()

        XCTAssertEqual(store.all().map(\.text), ["bounded lesson tail"])
        store.record(Lesson(
            kind: .obstacle, text: "new bounded lesson", source: nil, at: 2))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let bytes = try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        XCTAssertLessThanOrEqual(bytes, LessonStore.maximumFileBytes)
        XCTAssertEqual(
            store.all().map(\.text),
            ["bounded lesson tail", "new bounded lesson"])
    }
}
