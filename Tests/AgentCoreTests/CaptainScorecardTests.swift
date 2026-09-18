import Dispatch
import XCTest
@testable import AgentCore

/// The per-model scorecard (Phase 1). These pin the SAFEGUARDS that keep it from making things worse:
/// backward-compatible decode, cold-start neutrality, chronic-only exclude, stale-probe (no permanent
/// blacklist), and recency (a recovered model isn't punished for ancient faults).
final class CaptainScorecardTests: XCTestCase {

    private func temporaryStore(
        maxSamples: Int = 5_000
    ) throws -> (store: CaptainLearningStore, root: String, path: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("captain-scorecard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            CaptainLearningStore(projectRoot: root.path, maxSamples: maxSamples),
            root.path,
            root.appendingPathComponent(CaptainLearningStore.relativePath).path)
    }

    private func encodedLine(_ value: CaptainLearningSample) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0a)
        return data
    }

    private func sample(_ success: Bool, loop: Bool = false, reason: String? = nil, epoch: Double,
                        provider: String = "mimo") -> CaptainLearningSample {
        CaptainLearningSample(taskSignature: "t", taskTags: ["coding"], language: nil, role: "turn",
                              providerId: provider, model: nil, source: .liveEval, success: success,
                              atEpoch: epoch, failureReason: reason,
                              loopKinds: loop ? ["runawayLoop"] : [], wasStuck: loop,
                              failureRate: success ? 0 : 1)
    }

    // MARK: - Backward-compatible decode (old JSONL lines must still load)

    func testDecodesOldLineWithoutNewFields() throws {
        let old = #"{"taskSignature":"x","taskTags":["coding"],"role":"turn","providerId":"gemini","source":"liveEval","success":true,"atEpoch":100}"#
        let s = try JSONDecoder().decode(CaptainLearningSample.self, from: Data(old.utf8))
        XCTAssertEqual(s.providerId, "gemini")
        XCTAssertEqual(s.loopKinds, [])
        XCTAssertFalse(s.wasStuck)
        XCTAssertNil(s.failureReason)
        XCTAssertEqual(s.failureRate, 0)
    }

    func testNewFieldsRoundTrip() throws {
        let s = sample(false, loop: true, reason: "runawayLoop", epoch: 5)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(CaptainLearningSample.self, from: data)
        XCTAssertEqual(back.loopKinds, ["runawayLoop"])
        XCTAssertEqual(back.failureReason, "runawayLoop")
        XCTAssertTrue(back.wasStuck)
    }

    func testRefusalSamplesRemainInAuditWithoutDemotingOrEvictingMeasuredPerformance() throws {
        let fixture = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let now = 4_000_000.0
        let measured = (0..<5).map { sample(true, epoch: now - 100 + Double($0)) }
        let stops = (0..<40).map {
            sample(false, reason: CaptainLearningSample.refusalOrPermissionStopReason,
                   epoch: now - 40 + Double($0))
        }
        XCTAssertTrue(fixture.store.record(measured + stops))
        let loaded = fixture.store.load()
        XCTAssertEqual(loaded, measured + stops, "raw labeled attempts must remain available")
        XCTAssertEqual(CaptainLearningStore.modelVerdicts(loaded, now: now),
                       CaptainLearningStore.modelVerdicts(measured, now: now))
        XCTAssertEqual(CaptainLearningStore.summarize(loaded, now: now),
                       CaptainLearningStore.summarize(measured, now: now))
        let failures = (0..<10).map { _ in sample(false, reason: "verificationFail", epoch: now) }
        XCTAssertTrue(CaptainLearningStore.verdict(
            providerId: "mimo", samples: failures, now: now).exclude,
            "actual measured failures must still affect routing")
    }

    func testDecodedAndDirectSamplesAreSanitizedBeforeRouting() throws {
        let raw = #"{"taskSignature":" x ","taskTags":[" Coding ","coding"],"language":" SWIFT ","role":" TURN ","providerId":" MiMo ","source":"liveEval","success":false,"judgeScore":9,"tokens":-1,"latencyMs":-2,"toolFailures":-3,"atEpoch":100,"failureRate":4}"#
        let decoded = try JSONDecoder().decode(
            CaptainLearningSample.self, from: Data(raw.utf8))
        XCTAssertEqual(decoded.taskTags, ["coding"])
        XCTAssertEqual(decoded.language, "swift")
        XCTAssertEqual(decoded.role, "turn")
        XCTAssertEqual(decoded.providerId, "mimo")
        XCTAssertEqual(decoded.judgeScore, 1)
        XCTAssertEqual(decoded.tokens, 0)
        XCTAssertEqual(decoded.latencyMs, 0)
        XCTAssertEqual(decoded.toolFailures, 0)
        XCTAssertEqual(decoded.failureRate, 1)

        let nonFinite = CaptainLearningSample(
            taskSignature: "x", taskTags: ["coding"], language: nil, role: "turn",
            providerId: "mimo", model: nil, source: .liveEval, success: true,
            judgeScore: .nan, atEpoch: .nan, failureRate: .infinity)
        XCTAssertNil(nonFinite.judgeScore)
        XCTAssertEqual(nonFinite.failureRate, 0)
        XCTAssertTrue(CaptainLearningStore.summarize([nonFinite], now: 100).isEmpty)
        XCTAssertTrue(CaptainLearningStore.modelVerdicts([nonFinite], now: 100).isEmpty)
    }

    func testSharedWindowRejectsOldAndFarFutureButIncludesExactBoundaries() {
        let now = 3_000_000.0
        let age = CaptainLearningRecencyPolicy.maximumAgeSeconds
        let skew = CaptainLearningRecencyPolicy.maximumFutureSkewSeconds
        let samples = [
            sample(true, epoch: now - age),
            sample(false, epoch: now + skew),
            sample(true, epoch: now - age - 0.001),
            sample(true, epoch: now + skew + 0.001),
            sample(true, epoch: .nan),
        ]
        let summary = CaptainLearningStore.summarize(samples, now: now).first
        XCTAssertEqual(summary?.samples, 2)
        XCTAssertEqual(summary?.successes, 1)
        let verdict = CaptainLearningStore.verdict(
            providerId: "mimo", samples: samples, now: now)
        XCTAssertEqual(verdict.samples, 2)
        XCTAssertEqual(verdict.successRate, 0.5)
        XCTAssertTrue(CaptainLearningStore.summarize(samples, now: .nan).isEmpty)
        XCTAssertTrue(CaptainLearningStore.modelVerdicts(samples, now: .nan).isEmpty)
    }

    func testCanonicalBucketCapUsesAppendOrderForEqualTimestamps() {
        let now = 4_000_000.0
        let samples = (0..<21).map { index in
            CaptainLearningSample(
                taskSignature: "x", taskTags: index.isMultiple(of: 2) ? [" Coding "] : ["CODING"],
                language: index.isMultiple(of: 2) ? " Swift " : "SWIFT",
                role: index.isMultiple(of: 2) ? " Coder " : "CODER",
                providerId: index.isMultiple(of: 2) ? " MiMo " : "MIMO",
                model: nil, source: .liveEval, success: index == 0,
                atEpoch: now)
        }
        let summary = CaptainLearningStore.summarize(samples, now: now).first
        XCTAssertEqual(summary?.providerId, "mimo")
        XCTAssertEqual(summary?.role, "coder")
        XCTAssertEqual(summary?.language, "swift")
        XCTAssertEqual(summary?.samples, 20)
        XCTAssertEqual(summary?.successes, 0,
                       "equal timestamps retain the later physical append suffix")
        let verdict = CaptainLearningStore.verdict(
            providerId: " MIMO ", samples: samples, now: now)
        XCTAssertEqual(verdict.samples, 20)
        XCTAssertEqual(verdict.successRate, 0)
    }

    func testMultiRoleMultiTagAggregatesUseSameDeduplicatedSurvivors() {
        let now = 5_000_000.0
        var samples = (0..<25).map { index in
            CaptainLearningSample(
                taskSignature: "coder-\(index)", taskTags: ["coding", "verification"],
                language: "swift", role: "coder", providerId: "mimo", model: nil,
                source: .liveEval, success: true, atEpoch: now)
        }
        samples += (0..<3).map { index in
            CaptainLearningSample(
                taskSignature: "worker-\(index)", taskTags: ["research", "verification"],
                language: nil, role: "worker", providerId: "mimo", model: nil,
                source: .liveEval, success: true, atEpoch: now)
        }

        let offsets = CaptainLearningStore.routingEligibleAppendOffsets(samples, now: now)
        XCTAssertEqual(offsets, Array(5..<28))
        let assignment = CaptainLearningStore.summarize(samples, now: now)
        XCTAssertEqual(assignment.first { $0.role == "coder" && $0.taskTags == ["coding"] }?.samples, 20)
        XCTAssertEqual(assignment.first { $0.role == "worker" && $0.taskTags == ["research"] }?.samples, 3)
        let verdict = CaptainLearningStore.modelVerdicts(samples, now: now)["mimo"]
        XCTAssertEqual(verdict?.samples, offsets.count)
        let retrieval = CaptainLearningStore.summarizeForRetrieval(samples, now: now)
        XCTAssertEqual(retrieval.reduce(0) { $0 + $1.samples }, offsets.count)
        XCTAssertEqual(retrieval.first { $0.role == "coder" }?.samples, 20,
                       "multi-tag rows are not duplicated when flattened")
    }

    func testAggregateArithmeticSaturatesInsteadOfOverflowing() {
        let now = 6_000_000.0
        let samples = (0..<2).map { _ in
            CaptainLearningSample(
                taskSignature: "x", taskTags: ["coding"], language: nil,
                role: "coder", providerId: "mimo", model: nil, source: .liveEval,
                success: true, tokens: Int.max, latencyMs: Int.max,
                toolFailures: Int.max, atEpoch: now)
        }
        let summary = CaptainLearningStore.summarize(samples, now: now).first
        XCTAssertEqual(summary?.averageTokens, Int.max)
        XCTAssertEqual(summary?.averageLatencyMs, Int.max)
        XCTAssertEqual(summary?.toolFailures, Int.max)
    }

    // MARK: - Bounded, non-destructive JSONL persistence

    func testMalformedAuditRowDoesNotHideNeighborsOrGetRewrittenAway() throws {
        let fixture = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var original = try encodedLine(sample(true, epoch: 10, provider: "first"))
        original.append(Data("{definitely-not-json}\n".utf8))
        original.append(try encodedLine(sample(false, epoch: 20, provider: "second")))
        try original.write(to: URL(fileURLWithPath: fixture.path))

        XCTAssertEqual(fixture.store.load().map(\.providerId), ["first", "second"],
                       "audit reads keep independently decodable rows around corruption")
        XCTAssertFalse(fixture.store.record(sample(true, epoch: 30, provider: "third")))
        XCTAssertEqual(FileManager.default.contents(atPath: fixture.path), original,
                       "a malformed archive must remain byte-for-byte untouched")
    }

    func testOversizedArchiveIsRefusedWithoutReadingOrReplacingIt() throws {
        let fixture = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let original = Data(repeating: 0x78, count: CaptainLearningStore.maximumFileBytes + 1)
        try original.write(to: URL(fileURLWithPath: fixture.path))

        XCTAssertTrue(fixture.store.load().isEmpty)
        XCTAssertFalse(fixture.store.record(sample(true, epoch: 30)))
        XCTAssertEqual(FileManager.default.contents(atPath: fixture.path), original)
    }

    func testOversizedRowIsSkippedForAuditButBlocksMutationWithoutByteLoss() throws {
        let fixture = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var original = try encodedLine(sample(true, epoch: 10, provider: "first"))
        original.append(Data(repeating: 0x78, count: CaptainLearningStore.maximumRowBytes + 1))
        original.append(0x0a)
        original.append(try encodedLine(sample(true, epoch: 20, provider: "second")))
        try original.write(to: URL(fileURLWithPath: fixture.path))

        XCTAssertEqual(fixture.store.load().map(\.providerId), ["first", "second"])
        XCTAssertFalse(fixture.store.record(sample(true, epoch: 30, provider: "third")))
        XCTAssertEqual(FileManager.default.contents(atPath: fixture.path), original)
    }

    func testExistingArchiveBeyondConfiguredRowCapIsAuditOnlyAndMutationRefuses() throws {
        let fixture = try temporaryStore(maxSamples: 100)
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var original = Data()
        for index in 0..<101 {
            original.append(try encodedLine(sample(
                true, epoch: Double(index), provider: "provider-\(index)")))
        }
        try original.write(to: URL(fileURLWithPath: fixture.path))

        XCTAssertEqual(fixture.store.load().count, 101,
                       "bounded audit inspection does not pretend an over-cap archive vanished")
        XCTAssertFalse(fixture.store.record(sample(true, epoch: 200, provider: "new")))
        XCTAssertEqual(FileManager.default.contents(atPath: fixture.path), original)
    }

    func testConcurrentStoreInstancesDoNotLoseScorecardRows() throws {
        let fixture = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let count = 48

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let writer = CaptainLearningStore(projectRoot: fixture.root)
            _ = writer.record(sample(
                index.isMultiple(of: 2), epoch: Double(index), provider: "provider-\(index)"))
        }

        let rows = fixture.store.load()
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(Set(rows.map(\.providerId)),
                       Set((0..<count).map { "provider-\($0)" }))
        let lockPath = fixture.path + ".lock"
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))
        let permissions = try FileManager.default.attributesOfItem(atPath: lockPath)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? -1) & 0o7777, 0o600)
    }

    func testSymlinkedSidecarLockFailsClosed() throws {
        let fixture = try temporaryStore()
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let decoy = fixture.root + "/decoy.lock"
        let decoyBytes = Data("do-not-touch".utf8)
        try decoyBytes.write(to: URL(fileURLWithPath: decoy))
        try FileManager.default.createSymbolicLink(
            atPath: fixture.path + ".lock", withDestinationPath: decoy)

        XCTAssertFalse(fixture.store.record(sample(true, epoch: 1)))
        XCTAssertEqual(FileManager.default.contents(atPath: decoy), decoyBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path))
    }

    // MARK: - Cold-start neutral (must behave exactly like before the scorecard existed)

    func testColdStartIsNeutral() {
        let v = CaptainLearningStore.verdict(providerId: "mimo",
            samples: [sample(false, epoch: 1), sample(false, epoch: 2)], now: 100)
        XCTAssertEqual(v.rankDelta, 0, "<3 runs ⇒ no nudge")
        XCTAssertFalse(v.exclude, "one or two blips never exile a model")
    }

    // MARK: - Chronic offender (this is the 'don't burn shit')

    func testChronicOffenderExcludedWhenRecent() {
        let now = 1_000_000.0
        let s = (0..<6).map { sample(false, loop: true, reason: "runawayLoop", epoch: now - Double($0 * 10)) }
        let v = CaptainLearningStore.verdict(providerId: "mimo", samples: s, now: now)
        XCTAssertTrue(v.exclude, "6 recent all-fail/loop runs = chronic → skip it")
        XCTAssertLessThan(v.rankDelta, 0)
        XCTAssertTrue(v.reason.contains("chronic"))
    }

    // MARK: - No permanent blacklist (a stale offender gets a probe)

    func testChronicButStaleGetsAProbe() {
        let now = 1_000_000.0
        let old = now - (48 * 3600)   // last failure 48h ago > 24h stale window
        let s = (0..<6).map { sample(false, loop: true, reason: "runawayLoop", epoch: old - Double($0 * 10)) }
        let v = CaptainLearningStore.verdict(providerId: "mimo", samples: s, now: now)
        XCTAssertFalse(v.exclude, "a model that had a bad week is probed again, never permanently blacklisted")
    }

    // MARK: - Reward + recency

    func testStrongModelGetsPositiveDelta() {
        let now = 1_000_000.0
        let s = (0..<6).map { sample(true, epoch: now - Double($0 * 10), provider: "claude") }
        let v = CaptainLearningStore.verdict(providerId: "claude", samples: s, now: now)
        XCTAssertGreaterThan(v.rankDelta, 0)
        XCTAssertFalse(v.exclude)
    }

    // The shared failure-reason categorizer (extracted so the two writers can't drift) — priority order.
    func testScorecardReasonPriority() {
        typealias S = CaptainLearningSample
        XCTAssertEqual(S.scorecardReason(providerFault: true, flaky: true, verificationRejected: true, loopKind: "runawayLoop", failureRate: 1, ungrounded: true), "providerFault")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: true, verificationRejected: true, loopKind: "x", failureRate: 1, ungrounded: true), "flaky")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: true, loopKind: "x", failureRate: 1, ungrounded: true), "verificationFail")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: "runawayLoop", failureRate: 1, ungrounded: true), "runawayLoop")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: nil, failureRate: 0.5, ungrounded: true), "toolFailures")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: nil, failureRate: 0.1, ungrounded: true), "ungrounded")
        XCTAssertEqual(S.scorecardReason(providerFault: false, flaky: false, verificationRejected: false, loopKind: nil, failureRate: 0.1, ungrounded: false), "incomplete")
    }

    func testRecencyWindowFadesAncientFailures() {
        let now = 1_000_000.0
        var s = (0..<30).map { sample(false, loop: true, epoch: Double($0), provider: "gemini") } // ancient fails
        s += (0..<20).map { sample(true, epoch: now - Double(20 - $0), provider: "gemini") } // recent wins
        let v = CaptainLearningStore.verdict(providerId: "gemini", samples: s, now: now)
        XCTAssertGreaterThan(v.rankDelta, 0, "the last 20 runs (all wins) dominate ancient failures")
        XCTAssertFalse(v.exclude)
    }
}
