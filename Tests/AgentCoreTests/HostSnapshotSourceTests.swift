import XCTest
@testable import AgentCore

// PROTOTYPE — host_snapshot frame acquisition. All bounds are exercised with injected seams + an injected
// clock — NEVER a live TinkyStream. Each bound (stale / oversized / timeout / missing) is an atomic
// fail-closed error with ZERO captured bytes.
//
// TOCTOU SEAM (Codex MEDIUM): the primary source is opened via a SINGLE injected `openLatestJPEG` that
// returns the mtime AND bytes from one fd (`LatestJPEG?`, nil = absent). The freshness decision and the
// bytes fed to `jpegToPNG` come from that same value — a test cannot express a "checked one file, converted
// another" split, which is exactly the class of bug the fix closes.
final class HostSnapshotSourceTests: XCTestCase {

    private var fixtureJpg: String!

    override func setUp() {
        super.setUp()
        fixtureJpg = NSTemporaryDirectory() + "kist-hs-fixture-\(UUID().uuidString).jpg"
        FileManager.default.createFile(atPath: fixtureJpg, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))  // minimal JPEG marker
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: fixtureJpg)
        super.tearDown()
    }

    private func tinyPNG() -> Data { HostSnapshotFrameTests.tinyPNG(width: 8, height: 6) }
    private func tinyJPEG() -> Data { Data([0xFF, 0xD8, 0xFF, 0xD9]) }

    // Convenience seam: a fresh/stale/absent latest.jpg with a fixed body, off one injected mtime.
    private func latest(mtime: Date?, body: Data) -> (@Sendable (String) throws -> HostSnapshotSource.LatestJPEG?) {
        { _ in mtime.map { HostSnapshotSource.LatestJPEG(mtime: $0, bytes: body) } }
    }

    // Stale latest.jpg (mtime > 3s old) with NO interactive fallback ⇒ atomic stale error, zero bytes.
    func testStaleFrameSourceIsAtomicError() async {
        let now = Date()
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg,
            now: { now },
            isInteractiveSession: { false },                    // no screencapture fallback
            openLatestJPEG: latest(mtime: now.addingTimeInterval(-10), body: tinyJPEG()), // 10s old ⇒ stale
            jpegToPNG: { _, _ in XCTFail("must not convert a stale frame"); return Data() },
            screencapturePNG: { _, _ in XCTFail("must not fall back when non-interactive"); return Data() })
        let result = await source.acquire(displayIndex: 0)
        guard case .failure(.staleFrameSource) = result else { return XCTFail("stale must be an atomic error, got \(result)") }
    }

    // Missing latest.jpg + non-interactive ⇒ atomic missing error (zero bytes).
    func testMissingFrameSourceIsAtomicError() async {
        let now = Date()
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { false },
            openLatestJPEG: latest(mtime: nil, body: Data()),   // file absent
            jpegToPNG: { _, _ in Data() }, screencapturePNG: { _, _ in Data() })
        let result = await source.acquire(displayIndex: 0)
        guard case .failure(.missingFrameSource) = result else { return XCTFail("missing must be an atomic error, got \(result)") }
    }

    // A PNG over the 8 MiB cap ⇒ oversized error and NO base64 (the acquired frame is refused whole).
    func testOversizedFrameIsRefusedWithNoBytes() async {
        let now = Date()
        var huge = tinyPNG()
        huge.append(Data(count: HostSnapshotSource.maxPNGBytes + 1))   // push past the cap
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { true },
            openLatestJPEG: latest(mtime: now, body: tinyJPEG()),       // fresh
            jpegToPNG: { _, _ in huge },
            screencapturePNG: { _, _ in Data() })
        let result = await source.acquire(displayIndex: 0)
        guard case .failure(.oversized) = result else { return XCTFail("oversized must be refused, got \(result)") }
    }

    // An oversized SOURCE JPEG (over the cap) is refused BEFORE conversion — the cap applies to the bytes
    // read from the single fd, not only the converted PNG.
    func testOversizedSourceJpegRefusedBeforeConversion() async {
        let now = Date()
        var hugeJpeg = tinyJPEG()
        hugeJpeg.append(Data(count: HostSnapshotSource.maxPNGBytes + 1))
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { false },
            openLatestJPEG: latest(mtime: now, body: hugeJpeg),         // fresh but over-cap source bytes
            jpegToPNG: { _, _ in XCTFail("over-cap source must not reach conversion"); return Data() },
            screencapturePNG: { _, _ in Data() })
        let result = await source.acquire(displayIndex: 0)
        guard case .failure(.oversized) = result else { return XCTFail("over-cap source jpeg must be refused, got \(result)") }
    }

    // A conversion that outlives the wall-clock window ⇒ .timedOut (runner maps to exit 3), zero bytes.
    // The injected clock returns REAL time each call, so the deadline (now + 12s) is real; but the
    // conversion sleeps 30s, so the deadline sleep wins the race deterministically. External 14s guard
    // prevents any hang if the deadline logic regressed. (Runs ~12s — the one intentionally slow test.)
    func testTimeoutIsAtomicError() async {
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg,
            now: { Date() },
            isInteractiveSession: { true },
            openLatestJPEG: { _ in HostSnapshotSource.LatestJPEG(mtime: Date(), bytes: Data([0xFF, 0xD8, 0xFF, 0xD9])) }, // fresh
            jpegToPNG: { _, _ in try await Task.sleep(nanoseconds: 30_000_000_000); return Data() },
            screencapturePNG: { _, _ in Data() })
        let result = await withTaskTimeout(seconds: 14) { await source.acquire(displayIndex: 0) }
        guard case .failure(.timedOut) = result else { return XCTFail("hung conversion must time out, got \(result)") }
    }

    // Happy path: fresh latest.jpg ⇒ sips stub returns a real PNG ⇒ source="tinkystream", dims parsed. The
    // bytes handed to conversion are EXACTLY the bytes the freshness check accepted (TOCTOU-safe seam).
    func testFreshFrameConvertsToSignedPNG() async {
        let now = Date()
        let png = tinyPNG()
        let jpeg = tinyJPEG()
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { false },
            openLatestJPEG: latest(mtime: now, body: jpeg),     // fresh
            jpegToPNG: { bytes, _ in XCTAssertEqual(bytes, jpeg, "conversion must receive the exact fd-read bytes"); return png },
            screencapturePNG: { _, _ in XCTFail("fresh frame must not fall back"); return Data() })
        let result = await source.acquire(displayIndex: 0)
        guard case let .success(acq) = result else { return XCTFail("fresh frame must succeed, got \(result)") }
        XCTAssertEqual(acq.source, "tinkystream")
        XCTAssertEqual(acq.width, 8); XCTAssertEqual(acq.height, 6)
        XCTAssertEqual(acq.pngBytes, png)
        XCTAssertEqual(acq.capturedDisplayIndex, 0, "the tinkystream path captures display 0")
    }

    // TOCTOU (Codex MEDIUM, highest priority): a fixture that is STALE-by-mtime still fails closed, and a
    // fresh one succeeds — the SAME injected single-fd seam drives both, so freshness and conversion can
    // never diverge across a re-open. Named per state.
    func testFreshnessAndConversionUseOneFdStaleFailsClosedFreshSucceeds() async {
        let now = Date()
        let jpeg = tinyJPEG()
        let png = tinyPNG()
        // Stale-by-mtime, non-interactive ⇒ fail closed, conversion never runs.
        let staleSource = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { false },
            openLatestJPEG: latest(mtime: now.addingTimeInterval(-10), body: jpeg),
            jpegToPNG: { _, _ in XCTFail("stale-by-mtime must never convert"); return Data() },
            screencapturePNG: { _, _ in XCTFail("no fallback when non-interactive"); return Data() })
        let stale = await staleSource.acquire(displayIndex: 0)
        guard case .failure(.staleFrameSource) = stale else { return XCTFail("stale fixture must fail closed, got \(stale)") }
        // Fresh from the SAME seam shape ⇒ succeeds, converting exactly the fd-read bytes.
        let freshSource = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { false },
            openLatestJPEG: latest(mtime: now, body: jpeg),
            jpegToPNG: { bytes, _ in XCTAssertEqual(bytes, jpeg); return png },
            screencapturePNG: { _, _ in Data() })
        let fresh = await freshSource.acquire(displayIndex: 0)
        guard case let .success(acq) = fresh else { return XCTFail("fresh fixture must succeed, got \(fresh)") }
        XCTAssertEqual(acq.source, "tinkystream")
    }

    // DISPLAY HONESTY (MEDIUM): tinkystream ignores --display, so a SPECIFIC non-zero --display must be a
    // fail-closed atomic error — never a frame falsely labeled with that display index.
    func testTinkystreamNonZeroDisplayFailsClosedNoMislabel() async {
        let now = Date()
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { true },                     // fallback available, but must NOT be used
            openLatestJPEG: latest(mtime: now, body: tinyJPEG()), // fresh ⇒ tinkystream path
            jpegToPNG: { _, _ in XCTFail("must not capture a mislabeled frame"); return Data() },
            screencapturePNG: { _, _ in XCTFail("must not fall back to satisfy a display it can't honor"); return Data() })
        let result = await source.acquire(displayIndex: 3)
        guard case .failure(.displayNotCapturable) = result else {
            return XCTFail("tinkystream + --display 3 must fail-closed (no mislabeled frame), got \(result)")
        }
    }

    // The screencapture path DOES honor --display, so the captured index equals the requested index.
    func testScreencaptureCapturesRequestedDisplayIndex() async {
        let now = Date()
        let png = tinyPNG()
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { true },
            openLatestJPEG: latest(mtime: now.addingTimeInterval(-10), body: tinyJPEG()), // stale ⇒ fallback
            jpegToPNG: { _, _ in XCTFail("stale must not convert primary"); return Data() },
            screencapturePNG: { idx, _ in XCTAssertEqual(idx, 2); return png })
        let result = await source.acquire(displayIndex: 2)
        guard case let .success(acq) = result else { return XCTFail("screencapture must succeed, got \(result)") }
        XCTAssertEqual(acq.capturedDisplayIndex, 2, "screencapture signs the honored (=requested) index")
    }

    // A negative or absurd --display is an atomic error BEFORE any capture.
    func testInvalidDisplayIndexIsAtomicError() async {
        let now = Date()
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now }, isInteractiveSession: { true },
            openLatestJPEG: latest(mtime: now, body: tinyJPEG()),
            jpegToPNG: { _, _ in XCTFail("must not capture on an invalid index"); return Data() },
            screencapturePNG: { _, _ in XCTFail("must not capture on an invalid index"); return Data() })
        let neg = await source.acquire(displayIndex: -1)
        guard case .failure(.invalidDisplayIndex) = neg else { return XCTFail("negative display must be atomic error, got \(neg)") }
        let absurd = await source.acquire(displayIndex: HostSnapshotSource.maxDisplayIndex + 1)
        guard case .failure(.invalidDisplayIndex) = absurd else { return XCTFail("absurd display must be atomic error, got \(absurd)") }
    }

    // BYTE CAP BEFORE SLURP (LOW): an on-disk temp file already over the cap is refused via stat, WITHOUT
    // reading the whole file into memory. Uses the REAL readCappedFile against a fixture.
    func testReadCappedFileRefusesOverCapWithoutFullSlurp() throws {
        let big = NSTemporaryDirectory() + "kist-hs-oversize-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: big) }
        // Write cap+1 bytes to disk (a valid PNG header prefix isn't needed — the cap gate fires first).
        FileManager.default.createFile(atPath: big, contents: Data(count: HostSnapshotSource.maxPNGBytes + 1))
        XCTAssertThrowsError(try HostSnapshotSource.readCappedFile(big, label: "test")) { err in
            XCTAssertEqual(err as? HostSnapshotSource.AcquireError, .oversized, "over-cap temp file must be refused as .oversized")
        }
        // A within-cap file reads back its exact bytes.
        let small = NSTemporaryDirectory() + "kist-hs-ok-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: small) }
        let bytes = tinyPNG()
        FileManager.default.createFile(atPath: small, contents: bytes)
        XCTAssertEqual(try HostSnapshotSource.readCappedFile(small, label: "test"), bytes)
    }

    // TOCTOU LIVE SEAM: the REAL single-fd open reads mtime AND bytes from the same fd, and refuses a
    // symlink (O_NOFOLLOW). Proves the default `openLatestJPEG` behaves as the seam contract promises.
    func testOpenLatestJPEGFromDiskReadsOneFdAndRefusesSymlink() throws {
        // Regular file: mtime + exact bytes from one fd.
        let real = NSTemporaryDirectory() + "kist-hs-real-\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: real) }
        let body = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        FileManager.default.createFile(atPath: real, contents: body)
        let opened = try HostSnapshotSource.openLatestJPEGFromDisk(real)
        XCTAssertEqual(opened?.bytes, body, "bytes must be the exact fd-read contents")
        XCTAssertNotNil(opened?.mtime, "mtime must come from the fstat of the same fd")
        // Absent file ⇒ nil (missing, not a throw).
        let absent = try HostSnapshotSource.openLatestJPEGFromDisk(NSTemporaryDirectory() + "kist-hs-absent-\(UUID().uuidString).jpg")
        XCTAssertNil(absent, "an absent file must return nil (⇒ missing), not throw")
        // Symlink at the path ⇒ refused (O_NOFOLLOW), never followed.
        let link = NSTemporaryDirectory() + "kist-hs-link-\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: link) }
        try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertThrowsError(try HostSnapshotSource.openLatestJPEGFromDisk(link), "a symlink at latest.jpg must be refused, not followed")
    }

    // Stale + interactive ⇒ screencapture fallback produces a "screencapture"-labeled frame.
    func testStaleButInteractiveUsesScreencaptureFallback() async {
        let now = Date()
        let png = tinyPNG()
        let source = HostSnapshotSource(
            latestJpgPath: fixtureJpg, now: { now },
            isInteractiveSession: { true },                     // interactive ⇒ fallback allowed
            openLatestJPEG: latest(mtime: now.addingTimeInterval(-10), body: tinyJPEG()), // stale
            jpegToPNG: { _, _ in XCTFail("stale must not convert primary"); return Data() },
            screencapturePNG: { _, _ in png })
        let result = await source.acquire(displayIndex: 0)
        guard case let .success(acq) = result else { return XCTFail("interactive fallback must succeed, got \(result)") }
        XCTAssertEqual(acq.source, "screencapture")
    }

    func testPngDimensionsRejectsNonPNG() {
        XCTAssertNil(HostSnapshotSource.pngDimensions(Data([0xFF, 0xD8, 0xFF])), "JPEG must not parse as PNG")
        XCTAssertNil(HostSnapshotSource.pngDimensions(Data()), "empty must not parse")
        XCTAssertEqual(HostSnapshotSource.pngDimensions(tinyPNG())?.width, 8)
        XCTAssertEqual(HostSnapshotSource.pngDimensions(tinyPNG())?.height, 6)
    }

    // Small helper so a stuck acquire can't hang the whole test target.
    private func withTaskTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T?.self) { group -> T in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            for await r in group { if let r { group.cancelAll(); return r } }
            fatalError("timeout")
        }
    }
}
