import XCTest
@testable import AgentCore

final class LessonStoreTests: XCTestCase {

    private func tempStore() -> (LessonStore, String) {
        let path = NSTemporaryDirectory() + "lessons_\(UUID().uuidString).jsonl"
        return (LessonStore(path: path, capacity: 100), path)
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
}
