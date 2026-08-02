import XCTest
@testable import Kist
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class StickyTurnCoordinatorTests: XCTestCase {
    private final class OutputRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ data: Data) {
            lock.lock()
            values.append(String(decoding: data, as: UTF8.self))
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }

        func clear() {
            lock.lock()
            values.removeAll()
            lock.unlock()
        }
    }

    private final class SizeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TerminalScreenCoordinator.TerminalSize

        init(_ value: TerminalScreenCoordinator.TerminalSize) { self.value = value }

        func get() -> TerminalScreenCoordinator.TerminalSize {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: TerminalScreenCoordinator.TerminalSize) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    private final class InterruptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: InterruptibleTurn.InterruptReason?

        func set(_ value: InterruptibleTurn.InterruptReason) {
            lock.lock(); self.value = value; lock.unlock()
        }

        func get() -> InterruptibleTurn.InterruptReason? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        func stop() { lock.lock(); stopped = true; lock.unlock() }
        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }
    }

    func testPanelUsesOnlyAbsoluteRowsAndEL() {
        let layout = PinnedBarLayout(rows: 30, cols: 18, panelRows: 6)
        let panel = TerminalScreenCoordinator.Panel(
            status: "\u{001B}[35mworking\u{001B}[0m\nstep 2",
            pending: "very long 中🙂 pending input",
            queuedCount: 12,
            hint: "a deliberately long hint")
        let sequence = TerminalScreenCoordinator.panelSequence(layout: layout, panel: panel)

        XCTAssertFalse(sequence.contains("\u{001B}[J"), "ED is forbidden in the fixed strip")
        XCTAssertFalse(sequence.contains("\n"), "panel control must never scroll via newline")
        XCTAssertFalse(sequence.contains("\r"), "panel control must never use relative CR repaint")
        XCTAssertEqual(sequence.components(separatedBy: "\u{001B}[K").count - 1, 6,
                       "every physical panel row is cleared with EL exactly once")
        for row in layout.panelTop...layout.rows {
            XCTAssertTrue(sequence.contains(TerminalANSI.moveTo(row: row, col: 1)))
        }

        let rows = TerminalScreenCoordinator.panelRows(layout: layout, panel: panel)
        XCTAssertEqual(rows.count, 6)
        XCTAssertTrue(rows.allSatisfy { TerminalCellText.width($0) <= layout.cols - 1 },
                      "nothing may write the physical rightmost cell")
    }

    func testUnicodeCellWidthAndTailClipping() {
        XCTAssertEqual(TerminalCellText.width("abc"), 3)
        XCTAssertEqual(TerminalCellText.width("中"), 2)
        XCTAssertEqual(TerminalCellText.width("🙂"), 2)
        XCTAssertEqual(TerminalCellText.width("⏳"), 2)
        XCTAssertEqual(TerminalCellText.width("©️"), 2)
        XCTAssertEqual(TerminalCellText.width("❤️"), 2)
        XCTAssertEqual(TerminalCellText.width("1️⃣"), 2)
        XCTAssertEqual(TerminalCellText.width("e\u{301}"), 1)
        XCTAssertEqual(TerminalCellText.width("👩‍💻"), 2,
                       "a harmless ZWJ emoji cluster is preserved and occupies one wide glyph")

        let clipped = TerminalCellText.clipTail("prefix-中🙂-END", maxCells: 8)
        XCTAssertTrue(clipped.hasPrefix("…"))
        XCTAssertTrue(clipped.hasSuffix("END"))
        XCTAssertLessThanOrEqual(TerminalCellText.width(clipped), 8)
    }

    func testResizeGrowShrinkAndTinyFallbackRebuildsLayout() {
        let recorder = OutputRecorder()
        let size = SizeBox(.init(rows: 24, cols: 50))
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { size.get() },
            output: { recorder.append($0) })
        coordinator.activate()
        XCTAssertTrue(coordinator.screenActive)
        XCTAssertTrue(coordinator.beginTurnCapture(
            panel: .init(status: "resize", pending: "typed", queuedCount: 1)))

        recorder.clear()
        size.set(.init(rows: 40, cols: 90))
        coordinator.refreshSizeIfNeeded()
        var output = recorder.snapshot().joined()
        XCTAssertTrue(output.contains(TerminalANSI.setScrollRegion(top: 1, bottom: 34)))
        XCTAssertFalse(output.contains(TerminalANSI.clearBelow))
        XCTAssertTrue(coordinator.screenActive)

        recorder.clear()
        size.set(.init(rows: 14, cols: 35))
        coordinator.refreshSizeIfNeeded()
        output = recorder.snapshot().joined()
        XCTAssertTrue(output.contains(TerminalANSI.setScrollRegion(top: 1, bottom: 8)))
        XCTAssertTrue(coordinator.screenActive)

        recorder.clear()
        size.set(.init(rows: 8, cols: 35))
        coordinator.refreshSizeIfNeeded()
        output = recorder.snapshot().joined()
        XCTAssertTrue(output.hasPrefix(TerminalANSI.resetScrollRegion))
        XCTAssertFalse(output.contains("\u{001B}[1;2r"), "tiny fallback must not arm DECSTBM")
        XCTAssertFalse(coordinator.screenActive)

        recorder.clear()
        size.set(.init(rows: 28, cols: 60))
        coordinator.refreshSizeIfNeeded()
        XCTAssertTrue(coordinator.screenActive, "growing out of tiny fallback must safely re-pin")
        XCTAssertTrue(recorder.snapshot().joined().contains(
            TerminalANSI.setScrollRegion(top: 1, bottom: 22)))

        coordinator.endTurnCapture()
        coordinator.deactivate()
    }

    func testSignalRestorationArmsBeforeEveryDECSTBMActivation() {
        let events = OutputRecorder()
        let size = SizeBox(.init(rows: 30, cols: 80))
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { size.get() },
            output: {
                events.append(Data(("output:" + String(decoding: $0, as: UTF8.self)).utf8))
            },
            updateSignalState: { active, _ in
                events.append(Data("signal:\(active)".utf8))
                return true
            })

        func assertArmedBeforeActivation(_ context: String) {
            let snapshot = events.snapshot()
            let activation = snapshot.firstIndex {
                $0.hasPrefix("output:")
                    && $0.contains(TerminalANSI.setScrollRegion(top: 1, bottom: 24))
            }
            let arm = snapshot.firstIndex(of: "signal:true")
            XCTAssertNotNil(activation, "\(context) did not emit DECSTBM")
            XCTAssertNotNil(arm, "\(context) did not arm signal restoration")
            if let activation, let arm {
                XCTAssertLessThan(arm, activation,
                                  "\(context) exposed a post-DECSTBM termination race")
            }
        }

        coordinator.activate()
        assertArmedBeforeActivation("initial activation")

        XCTAssertTrue(coordinator.suspend())
        events.clear()
        coordinator.resume()
        assertArmedBeforeActivation("resume")

        XCTAssertTrue(coordinator.beginTurnCapture(panel: .init(status: "lease")))
        XCTAssertTrue(coordinator.beginScreenLease())
        events.clear()
        XCTAssertTrue(coordinator.endScreenLease())
        assertArmedBeforeActivation("cooked-screen lease restoration")

        size.set(.init(rows: 8, cols: 80))
        coordinator.refreshSizeIfNeeded()
        XCTAssertFalse(coordinator.screenActive)
        events.clear()
        size.set(.init(rows: 30, cols: 80))
        coordinator.refreshSizeIfNeeded()
        assertArmedBeforeActivation("grow from tiny fallback")

        coordinator.endTurnCapture()
        coordinator.deactivate()
    }

    func testFailedSignalRegistrationCannotEmitDECSTBM() {
        let events = OutputRecorder()
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { .init(rows: 30, cols: 80) },
            output: { events.append($0) },
            updateSignalState: { active, _ in !active })

        coordinator.activate()

        XCTAssertFalse(coordinator.screenActive)
        XCTAssertFalse(
            events.snapshot().joined().contains(
                TerminalANSI.setScrollRegion(top: 1, bottom: 24)),
            "DECSTBM must not be emitted when its termination cleanup failed to arm")
        coordinator.deactivate()
    }

    func testSignalCleanupRestoresBeforeBoundedResetOnSaturatedFD() throws {
        #if canImport(Darwin) || canImport(Glibc)
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&descriptors), 0)
        let readFD = descriptors[0]
        let writeFD = descriptors[1]
        defer {
            close(readFD)
            close(writeFD)
        }

        let originalWriteFlags = fcntl(writeFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(originalWriteFlags, 0)
        XCTAssertEqual(fcntl(writeFD, F_SETFL, originalWriteFlags | O_NONBLOCK), 0)
        let fill = [UInt8](repeating: 0x78, count: 4_096)
        while true {
            let written = fill.withUnsafeBytes {
                write(writeFD, $0.baseAddress, $0.count)
            }
            if written > 0 { continue }
            XCTAssertEqual(written, -1)
            XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
            break
        }
        XCTAssertEqual(fcntl(writeFD, F_SETFL, originalWriteFlags), 0)

        var restoreRan = false
        let started = Date()
        RawMode.runSignalCleanupForTesting(resetFD: writeFD) {
            restoreRan = true
            // Make room only from the restoration callback. The reset can reach the pipe iff
            // callback restoration happens before the nonblocking visual cleanup attempt.
            var discarded = [UInt8](repeating: 0, count: 64)
            XCTAssertGreaterThan(read(readFD, &discarded, discarded.count), 0)
        }
        XCTAssertTrue(restoreRan)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5,
                          "a saturated reset fd must not stall signal termination")
        // Darwin adds an internal 0x10000 pipe-full marker to F_GETFL after EAGAIN, so compare the
        // public status bit this cleanup owns rather than kernel-private bookkeeping.
        let finalWriteFlags = fcntl(writeFD, F_GETFL)
        XCTAssertEqual(finalWriteFlags & O_NONBLOCK, originalWriteFlags & O_NONBLOCK,
                       "temporary O_NONBLOCK must not leak into normal terminal output")

        let originalReadFlags = fcntl(readFD, F_GETFL)
        XCTAssertGreaterThanOrEqual(originalReadFlags, 0)
        XCTAssertEqual(fcntl(readFD, F_SETFL, originalReadFlags | O_NONBLOCK), 0)
        defer { _ = fcntl(readFD, F_SETFL, originalReadFlags) }
        var drained = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(readFD, &buffer, buffer.count)
            if count > 0 {
                drained.append(contentsOf: buffer.prefix(Int(count)))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        let reset = RawMode.signalResetSequenceForTesting
        XCTAssertEqual(drained.suffix(reset.count), reset,
                      "reset must run after restoration creates output capacity")
        #else
        throw XCTSkip("POSIX pipe semantics unavailable")
        #endif
    }

    func testLegacyTerminalUIArmsBeforeDECSTBMAndDisarmsAfterReset() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Kist/TUI/TerminalUI.swift"),
            encoding: .utf8
        )

        let setup = try XCTUnwrap(source.range(of: "func setup()"))
        let teardown = try XCTUnwrap(source.range(of: "func teardown()"))
        let setupBody = source[setup.lowerBound..<teardown.lowerBound]
        let arm = try XCTUnwrap(setupBody.range(
            of: "RawMode.updateScrollRegionSignalState(active: true"))
        let activation = try XCTUnwrap(setupBody.range(of: "write(layout.scrollRegion)"))
        XCTAssertLessThan(arm.lowerBound, activation.lowerBound,
                          "legacy TerminalUI exposed an unowned DECSTBM activation")

        let teardownBody = source[teardown.lowerBound...]
        let reset = try XCTUnwrap(teardownBody.range(
            of: "write(TerminalANSI.resetScrollRegion)"))
        let disarm = try XCTUnwrap(teardownBody.range(
            of: "RawMode.updateScrollRegionSignalState(active: false"))
        XCTAssertLessThan(reset.lowerBound, disarm.lowerBound,
                          "legacy TerminalUI disarmed cleanup before resetting DECSTBM")
    }

    func testSessionCollectsBeforeDuringAndAfterModelWork() async {
        let queue = TurnInputQueue()
        let session = TurnInteractionSession(enabled: false, queue: queue)
        session.start()

        for byte in "before ".utf8 { session.feedForTesting(byte) }
        let value = await session.runModelTask(onInterrupt: { _ in XCTFail("unexpected interrupt") }) {
            for byte in "during ".utf8 { session.feedForTesting(byte) }
            return 42
        }
        XCTAssertEqual(value, 42)
        for byte in "after".utf8 { session.feedForTesting(byte) }
        XCTAssertEqual(queue.preview().pending, "before during after")

        await session.finish()
        session.feedForTesting(UInt8(ascii: "!"))
        XCTAssertEqual(queue.preview().pending, "before during after",
                       "collection must close at the next-prompt boundary")
    }

    func testSessionFailsClosedWhenRawWatchModeCannotActivate() async throws {
        #if canImport(Darwin) || canImport(Glibc)
        guard isatty(STDIN_FILENO) == 0 else {
            throw XCTSkip("test runner stdin is a TTY")
        }
        let queue = TurnInputQueue()
        let session = TurnInteractionSession(enabled: true, queue: queue)
        session.start()
        XCTAssertFalse(
            session.watcherActiveForTesting,
            "a failed raw-mode transition must not start a cooked-stdin reader")
        await session.finish()
        #else
        throw XCTSkip("raw mode is unavailable on this platform")
        #endif
    }

    func testOneSessionCancelsOnlyTheCurrentModelTask() async {
        let queue = TurnInputQueue()
        let reason = InterruptBox()
        let session = TurnInteractionSession(enabled: false, queue: queue)
        session.start()

        let operation = Task {
            await session.runModelTask(onInterrupt: { reason.set($0) }) {
                while !Task.isCancelled { await Task.yield() }
                return Task.isCancelled
            }
        }
        await session.waitForActiveModelTaskForTesting()
        session.interruptForTesting(.interject)
        let wasCancelled = await operation.value
        XCTAssertTrue(wasCancelled)
        XCTAssertEqual(reason.get(), .interject)

        // No task is active now; this must not poison the next model call.
        session.interruptForTesting(.cancel)
        let clean = await session.runModelTask(onInterrupt: { _ in XCTFail("stale ESC leaked") }) { 7 }
        XCTAssertEqual(clean, 7)
        await session.finish()
    }

    func testConcurrentTranscriptAndPanelWritesNeverInterleave() {
        let recorder = OutputRecorder()
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { .init(rows: 30, cols: 80) },
            output: { recorder.append($0) })
        coordinator.activate()
        XCTAssertTrue(coordinator.beginTurnCapture(panel: .init(status: "ordered")))
        recorder.clear()

        let group = DispatchGroup()
        let transcript = DispatchQueue(label: "test.transcript")
        let typeahead = DispatchQueue(label: "test.typeahead", attributes: .concurrent)
        group.enter()
        transcript.async {
            for index in 0..<100 {
                coordinator.acceptCaptured(Data("T\(index)|".utf8))
            }
            group.leave()
        }
        group.enter()
        typeahead.async {
            for index in 0..<100 {
                coordinator.updateTypeahead(pending: "中🙂\(index)", queuedCount: index % 4)
            }
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)

        let transcriptEvents = recorder.snapshot().filter { $0.hasPrefix("T") }
        XCTAssertEqual(transcriptEvents, (0..<100).map { "T\($0)|" },
                       "the serialized transcript producer's order must survive panel redraws")
        XCTAssertTrue(recorder.snapshot().filter { $0.hasPrefix(TerminalANSI.saveCursor) }
            .allSatisfy { $0.hasSuffix(TerminalANSI.restoreCursor) },
            "a transcript byte can never split a panel save/redraw/restore transaction")

        coordinator.endTurnCapture()
        coordinator.deactivate()
    }

    func testLongWrappedTranscriptNeverTouchesPanelRows() {
        let layout = PinnedBarLayout(rows: 20, cols: 17, panelRows: 6)
        var screen = StickyTranscriptScreenModel(layout: layout)
        for index in 0..<2_000 {
            screen.consume("row-\(index)-中🙂-" + String(repeating: "x", count: index % 29) + "\n")
        }
        XCTAssertFalse(screen.panelWasTouched)
        XCTAssertLessThanOrEqual(screen.row, layout.transcriptBottom)
        XCTAssertGreaterThanOrEqual(screen.row, 1)
    }

    func testStickyDefaultsOnWithOptOutAndSelfTestDispatchesBeforeRegistry() throws {
        XCTAssertTrue(KistOptions.parse(["hello"]).stickyTurns)                    // default ON (2026-08-02)
        XCTAssertTrue(KistOptions.parse(["--sticky-turns", "hello"]).stickyTurns)
        XCTAssertFalse(KistOptions.parse(["--no-sticky-turns", "hello"]).stickyTurns)   // opt-out still available
        XCTAssertFalse(KistOptions.parse(["--sticky-turns", "--no-sticky-turns", "hello"]).stickyTurns)
        XCTAssertTrue(KistOptions.parse(["--sticky-bar-self-test"]).stickyBarSelfTest)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Kist/KistRunner.swift"),
                                encoding: .utf8)
        let dispatch = try XCTUnwrap(runner.range(of: "if opts.stickyBarSelfTest"))
        let registry = try XCTUnwrap(runner.range(of: "var registry = makeRegistry()"))
        XCTAssertLessThan(dispatch.lowerBound, registry.lowerBound,
                          "offline diagnostic must dispatch before provider/MCP construction")
    }

    func testRawAndFixedScreenHandoffOrderIsPinnedAtEveryCallSite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repl = try String(contentsOf: root.appendingPathComponent("Sources/Kist/KistREPL.swift"),
                              encoding: .utf8)
        let session = try String(contentsOf:
            root.appendingPathComponent("Sources/Kist/UX/TurnInteractionSession.swift"),
                                 encoding: .utf8)
        let runner = try String(contentsOf: root.appendingPathComponent("Sources/Kist/KistRunner.swift"),
                                encoding: .utf8)

        let turnStart = try XCTUnwrap(repl.range(of: "let session = TurnInteractionSession("))
        let turnBody = repl[turnStart.lowerBound...]
        let rawOwner = try XCTUnwrap(turnBody.range(of: "session.start()"))
        let repin = try XCTUnwrap(turnBody.range(of: "pinnedBar.resume()"))
        let capture = try XCTUnwrap(turnBody.range(of: "pinnedBar.beginStickyTurn"))
        XCTAssertLessThan(rawOwner.lowerBound, repin.lowerBound)
        XCTAssertLessThan(repin.lowerBound, capture.lowerBound,
                          "sticky capture must start only after raw stdin ownership and re-pin")
        XCTAssertTrue(turnBody.contains("onScreenReleaseBeforeFinish: onScreenReleaseBeforeFinish"))

        let finishStart = try XCTUnwrap(session.range(of: "func finish() async"))
        let finishBody = session[finishStart.lowerBound...]
        let release = try XCTUnwrap(finishBody.range(of: "onScreenReleaseBeforeFinish?()"))
        let cancel = try XCTUnwrap(finishBody.range(of: "state.watcher?.cancel()"))
        XCTAssertLessThan(release.lowerBound, cancel.lowerBound,
                          "fixed screen must be released before watcher cancellation restores echo")

        let leaseStart = try XCTUnwrap(session.range(of: "private func suspendForStdinLease()"))
        let leaseBody = session[leaseStart.lowerBound...]
        let leaseRelease = try XCTUnwrap(leaseBody.range(of: "onScreenLeaseBegin?()"))
        let cooked = try XCTUnwrap(leaseBody.range(of: "raw.disable()"))
        XCTAssertLessThan(leaseRelease.lowerBound, cooked.lowerBound,
                          "cooked prompt lease must release the panel before enabling kernel echo")

        let selfTestStart = try XCTUnwrap(runner.range(of: "static func runStickyBarSelfTest"))
        let selfTestBody = runner[selfTestStart.lowerBound...]
        let diagnosticRawOwner = try XCTUnwrap(selfTestBody.range(of: "raw.enableForWatch()"))
        let screenActivation = try XCTUnwrap(selfTestBody.range(of: "bar.activate()"))
        let screenCapture = try XCTUnwrap(selfTestBody.range(of: "bar.beginStickyTurn"))
        XCTAssertLessThan(diagnosticRawOwner.lowerBound, screenActivation.lowerBound)
        XCTAssertLessThan(screenActivation.lowerBound, screenCapture.lowerBound)

        let normalTeardown = try XCTUnwrap(selfTestBody.range(of: "Release capture and DECSTBM"))
        let teardownBody = selfTestBody[normalTeardown.lowerBound...]
        let diagnosticRelease = try XCTUnwrap(teardownBody.range(of: "bar.suspend()"))
        let diagnosticCooked = try XCTUnwrap(teardownBody.range(of: "raw.disable()"))
        XCTAssertLessThan(diagnosticRelease.lowerBound, diagnosticCooked.lowerBound)
    }

    func testFirewallPreservesOnlyCompleteUTF8AndSafeCSIAtEveryBoundary() {
        let input = Data(("A🙂中"
            + "\u{001B}[31mred\u{001B}[0m"
            + "\rspin\u{001B}[2K\nZ").utf8)
        let expected = input

        // Every possible two-chunk boundary includes splits inside emoji/CJK and every CSI byte.
        for split in 0...input.count {
            var parser = StreamingTranscriptFirewall()
            var actual = parser.consume(input.prefix(split))
            actual.append(parser.consume(input.dropFirst(split)))
            actual.append(parser.finish())
            XCTAssertEqual(actual, expected, "split at byte \(split)")
        }

        // The strongest streaming case: one byte per callback.
        var bytewise = StreamingTranscriptFirewall()
        var bytewiseOutput = Data()
        for byte in input {
            bytewiseOutput.append(bytewise.consume(Data([byte])))
        }
        bytewiseOutput.append(bytewise.finish())
        XCTAssertEqual(bytewiseOutput, expected)

        // No partial scalar or CSI introducer is emitted before completion, so a panel transaction
        // can safely occur between any two receive callbacks.
        var partial = StreamingTranscriptFirewall()
        XCTAssertTrue(partial.consume(Data([0xF0, 0x9F])).isEmpty)
        XCTAssertEqual(partial.consume(Data([0x99, 0x82])), Data("🙂".utf8))
        XCTAssertTrue(partial.consume(Data([0x1B, 0x5B, 0x33])).isEmpty)
        XCTAssertEqual(partial.consume(Data([0x31, 0x6D])), Data("\u{001B}[31m".utf8))
    }

    func testFirewallNeutralizesHostileAndUnboundedTerminalControls() {
        let hostile = Data(("before"
            + "\u{001B}[2J"                      // ED
            + "\u{001B}[1;1H"                   // CUP
            + "\u{001B}[?6h"                    // DECOM
            + "\u{001B}[1;5r"                   // DECSTBM
            + "\u{001B}]8;;https://bad.invalid\u{0007}link\u{001B}]8;;\u{0007}" // OSC
            + "\u{001B}Ppayload\u{001B}\\"       // DCS
            + "\u{001B}_Gkitty-data\u{001B}\\"   // APC
            + "\u{001B}[?2004h"                  // private mode
            + "\u{001B}[" + String(repeating: "1", count: 200) + "J" // bounded discard
            + "after\u{001B}[32msafe\u{001B}[0m").utf8)
        var parser = StreamingTranscriptFirewall()
        var output = Data()
        for byte in hostile { output.append(parser.consume(Data([byte]))) }
        output.append(parser.finish())
        let rendered = String(decoding: output, as: UTF8.self)

        XCTAssertEqual(rendered, "beforelinkaftersafe"
            .replacingOccurrences(of: "safe", with: "\u{001B}[32msafe\u{001B}[0m"))
        for forbidden in [
            "\u{001B}[2J", "\u{001B}[1;1H", "\u{001B}[?6h", "\u{001B}[1;5r",
            "\u{001B}]", "\u{001B}P", "\u{001B}_", "\u{001B}[?2004h"
        ] {
            XCTAssertFalse(rendered.contains(forbidden), "leaked \(forbidden.debugDescription)")
        }

        var incompleteUTF8 = StreamingTranscriptFirewall()
        XCTAssertTrue(incompleteUTF8.consume(Data([0xE2, 0x82])).isEmpty)
        XCTAssertEqual(String(decoding: incompleteUTF8.finish(), as: UTF8.self), "\u{FFFD}")
        var incompleteCSI = StreamingTranscriptFirewall()
        XCTAssertTrue(incompleteCSI.consume(Data("\u{001B}[123".utf8)).isEmpty)
        XCTAssertTrue(incompleteCSI.finish().isEmpty, "an incomplete CSI must never leak")
    }

    func testFirewallDropsEncodedUnicodeControlsFormatsAndLogicalLineBreaksAtEveryBoundary() {
        let prohibited = "\u{009B}\u{009D}\u{009C}\u{202E}\u{2066}\u{2028}\u{2029}\u{FEFF}"
        let input = Data(("before-" + prohibited + "-after").utf8)

        for split in 0...input.count {
            var parser = StreamingTranscriptFirewall()
            var output = parser.consume(input.prefix(split))
            output.append(parser.consume(input.dropFirst(split)))
            output.append(parser.finish())
            let rendered = String(decoding: output, as: UTF8.self)
            XCTAssertTrue(rendered.hasPrefix("before-"), "split \(split)")
            XCTAssertTrue(rendered.hasSuffix("-after"), "split \(split)")
            XCTAssertFalse(rendered.unicodeScalars.contains { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator,
                     .surrogate, .unassigned:
                    return true
                default:
                    return false
                }
            }, "split \(split) leaked a prohibited Unicode scalar")
        }
    }

    func testCoordinatorNeverEmitsFragmentOrHostileControlAndDirectInputModeBypassesFirewall() {
        let recorder = OutputRecorder()
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { .init(rows: 30, cols: 80) },
            output: { recorder.append($0) })
        coordinator.activate()
        XCTAssertTrue(coordinator.beginTurnCapture(panel: .init(status: "firewall")))
        recorder.clear()

        for byte in Data("x🙂\u{001B}[2J\u{001B}[1;1Hy".utf8) {
            coordinator.acceptCaptured(Data([byte]))
            coordinator.updateTypeahead(pending: "typing", queuedCount: 0)
        }
        let transcriptEvents = recorder.snapshot().filter {
            !$0.hasPrefix(TerminalANSI.saveCursor)
        }
        let transcript = transcriptEvents.joined()
        XCTAssertTrue(transcript.contains("x🙂y"))
        XCTAssertFalse(transcript.contains("\u{001B}[2J"))
        XCTAssertFalse(transcript.contains("\u{001B}[1;1H"))
        XCTAssertFalse(transcriptEvents.contains("\u{001B}"))
        XCTAssertFalse(transcriptEvents.contains("\u{001B}["))

        recorder.clear()
        coordinator.acceptCaptured(Data("\u{001B}[?2004h".utf8))
        XCTAssertTrue(recorder.snapshot().isEmpty,
                      "private mode injected through captured stdout must be stripped")
        coordinator.setBracketedPasteEnabled(true)
        XCTAssertEqual(recorder.snapshot(), ["\u{001B}[?2004h"],
                       "watcher input mode must use the coordinator's direct control path")

        coordinator.endTurnCapture()
        coordinator.deactivate()
    }

    func testFixedPanelTextRemovesC1FormatsAndStringProtocolPayloads() {
        let hostile = "safe"
            + "\u{009B}2J"                    // Unicode C1 CSI
            + "\u{008D}"                      // reverse index C1
            + "\u{202E}bidi"                  // RTL override (format)
            + "\u{001B}]0;osc-title\u{0007}"  // OSC
            + "\u{001B}_Gkitty-payload\u{001B}\\" // APC
            + "\u{001B}Pdevice-data\u{001B}\\"    // DCS
            + "\u{001B}[2J"                  // 7-bit ED
            + "end"
        let clean = TerminalCellText.stripANSI(hostile)
        XCTAssertTrue(clean.hasPrefix("safe"))
        XCTAssertTrue(clean.hasSuffix("end"))
        XCTAssertFalse(clean.contains("osc-title"))
        XCTAssertFalse(clean.contains("kitty-payload"))
        XCTAssertFalse(clean.contains("device-data"))

        let rows = TerminalScreenCoordinator.panelRows(
            layout: .init(rows: 24, cols: 80, panelRows: 6),
            panel: .init(status: hostile, promptPrefix: hostile,
                         pending: hostile, hint: hostile))
        for row in rows {
            XCTAssertFalse(row.unicodeScalars.contains { scalar in
                if scalar.value < 0x20 || scalar.value == 0x7F
                    || (0x80...0x9F).contains(scalar.value) {
                    return true
                }
                switch scalar.properties.generalCategory {
                case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                    return true
                default:
                    return false
                }
            }, "fixed panel row leaked a control/format scalar: \(row.debugDescription)")
        }
    }

    func testGenerationGateDropsStaleReaderAndCancelledResizeCannotRepaint() {
        let recorder = OutputRecorder()
        let size = SizeBox(.init(rows: 30, cols: 80))
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { size.get() },
            output: { recorder.append($0) })
        coordinator.activate()
        XCTAssertTrue(coordinator.beginTurnCapture(panel: .init(status: "one")))
        let first = coordinator.acceptedGenerationForTesting
        XCTAssertNotNil(first)
        coordinator.endTurnCapture()

        recorder.clear()
        size.set(.init(rows: 36, cols: 90))
        usleep(300_000)
        XCTAssertTrue(recorder.snapshot().isEmpty,
                      "a cancelled resize callback must not repaint after capture end")

        XCTAssertTrue(coordinator.beginTurnCapture(panel: .init(status: "two")))
        let second = coordinator.acceptedGenerationForTesting
        XCTAssertNotEqual(first, second)
        recorder.clear()
        coordinator.acceptCaptured(Data("stale".utf8), generation: first!)
        coordinator.acceptCaptured(Data("fresh".utf8), generation: second!)
        XCTAssertFalse(recorder.snapshot().joined().contains("stale"))
        XCTAssertTrue(recorder.snapshot().joined().contains("fresh"))

        coordinator.endTurnCapture()
        coordinator.deactivate()
    }

    func testCookedPromptLeaseReleasesScreenBlocksRedrawAndRestoresBeforeWatcher() {
        let recorder = OutputRecorder()
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { .init(rows: 30, cols: 80) },
            output: { recorder.append($0) })
        let bar = PinnedBar(coordinator: coordinator)
        bar.activate()
        XCTAssertTrue(bar.beginStickyTurn(panel: .init(status: "lease", pending: "old")))
        recorder.clear()

        bar.setBracketedPasteEnabled(false)
        XCTAssertTrue(bar.beginInputScreenLease())
        let released = recorder.snapshot()
        XCTAssertEqual(released.first, "\u{001B}[?2004l")
        XCTAssertTrue(released.joined().contains(TerminalANSI.resetScrollRegion))
        XCTAssertFalse(bar.active)
        XCTAssertFalse(coordinator.turnCaptureActive)

        recorder.clear()
        coordinator.acceptCaptured(Data("must-not-appear".utf8))
        bar.updateStickyTypeahead(pending: "new", queuedCount: 2)
        XCTAssertTrue(recorder.snapshot().isEmpty,
                      "capture and panel redraw must both be inert during kernel tty echo")

        XCTAssertTrue(bar.endInputScreenLease())
        bar.setBracketedPasteEnabled(true)
        let restored = recorder.snapshot()
        let activateIndex = try? XCTUnwrap(restored.firstIndex {
            $0.contains(TerminalANSI.setScrollRegion(top: 1, bottom: 24))
        })
        let modeIndex = try? XCTUnwrap(restored.firstIndex(of: "\u{001B}[?2004h"))
        XCTAssertNotNil(activateIndex)
        XCTAssertNotNil(modeIndex)
        if let activateIndex, let modeIndex {
            XCTAssertLessThan(activateIndex, modeIndex,
                              "panel/capture restoration must finish before watcher resume")
        }
        XCTAssertTrue(restored.joined().contains("new"))
        XCTAssertTrue(bar.active)
        XCTAssertTrue(coordinator.turnCaptureActive)

        bar.endStickyTurn()
        bar.deactivate()
    }

    func testSessionCookedLeaseCallbacksBracketBodyExactlyOnce() async {
        let queue = TurnInputQueue()
        let log = OutputRecorder()
        let session = TurnInteractionSession(
            enabled: false,
            queue: queue,
            onScreenLeaseBegin: { log.append(Data("release".utf8)); return true },
            onScreenLeaseEnd: { log.append(Data("restore".utf8)); return true })
        session.start()
        session.suspendForStdinLeaseForTesting()
        log.append(Data("body".utf8))
        session.resumeFromStdinLeaseForTesting()
        XCTAssertEqual(log.snapshot(), ["release", "body", "restore"])
        await session.finish()
    }

    func testOrderedCaptureStopDrainsWithoutEOFOrTimeoutRace() {
        final class DataBox: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            func append(_ value: Data) {
                lock.lock(); data.append(value); lock.unlock()
            }
            func snapshot() -> Data {
                lock.lock(); defer { lock.unlock() }; return data
            }
        }
        let received = DataBox()
        let capture = OrderedProcessOutputCapture { received.append($0) }
        let started = capture.start()
        var inheritedWriter: Int32 = -1
        if started {
            inheritedWriter = dup(STDOUT_FILENO)
            let payload = Data("capture-quiescence-barrier".utf8)
            payload.withUnsafeBytes { bytes in
                _ = write(STDOUT_FILENO, bytes.baseAddress, bytes.count)
            }
        }
        let began = Date()
        let restored = capture.stop()
        let elapsed = Date().timeIntervalSince(began)
        if inheritedWriter >= 0 { close(inheritedWriter) }

        XCTAssertTrue(started)
        XCTAssertTrue(restored)
        XCTAssertLessThan(elapsed, 1.0,
                          "an inherited but idle writer must not force a timeout-based teardown")
        XCTAssertTrue(String(decoding: received.snapshot(), as: UTF8.self)
            .contains("capture-quiescence-barrier"))
    }

    func testOrderedCaptureContinuousInheritedWriterHasBoundedJoinedDrain() {
        final class CountBox: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func add(_ data: Data) {
                lock.lock(); count += data.count; lock.unlock()
            }
        }
        let previousSIGPIPE = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previousSIGPIPE) }

        let received = CountBox()
        let capture = OrderedProcessOutputCapture { received.add($0) }
        let started = capture.start()
        let writerFD = started ? dup(STDOUT_FILENO) : -1
        let firstWrite = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        if writerFD >= 0 {
            DispatchQueue.global(qos: .userInitiated).async {
                let chunk = Data(repeating: UInt8(ascii: "x"), count: 32_768)
                var signalled = false
                chunk.withUnsafeBytes { bytes in
                    while true {
                        let result = write(writerFD, bytes.baseAddress, bytes.count)
                        if result <= 0 { break }
                        if !signalled {
                            signalled = true
                            firstWrite.signal()
                        }
                    }
                }
                close(writerFD)
                writerDone.signal()
            }
            _ = firstWrite.wait(timeout: .now() + 1)
        }

        let began = Date()
        let restored = capture.stop()
        let elapsed = Date().timeIntervalSince(began)
        _ = writerDone.wait(timeout: .now() + 1)

        XCTAssertTrue(started)
        XCTAssertGreaterThanOrEqual(writerFD, 0)
        XCTAssertTrue(restored)
        XCTAssertLessThan(elapsed, 1.0,
                          "continuous inherited output must hit the reader's monotonic/byte bound")
    }

    func testPrivateDescriptorConfigurationRetriesEINTRAndFailsClosed() {
        var calls: [PrivateDescriptorSafety.Operation] = []
        let configured = PrivateDescriptorSafety.configure(
            fd: 42,
            nonBlocking: true
        ) { _, operation in
            calls.append(operation)
            if calls.count == 1 {
                errno = EINTR
                return -1
            }
            switch operation {
            case .getDescriptorFlags, .getStatusFlags:
                return 0
            case .setDescriptorFlags(let flags):
                return (flags & FD_CLOEXEC) != 0 ? 0 : -1
            case .setStatusFlags(let flags):
                return (flags & O_NONBLOCK) != 0 ? 0 : -1
            }
        }
        XCTAssertTrue(configured)
        XCTAssertEqual(Array(calls.prefix(2)), [.getDescriptorFlags, .getDescriptorFlags],
                       "EINTR must retry the same fcntl operation")

        var reachedStatusSet = false
        let failed = PrivateDescriptorSafety.configure(
            fd: 42,
            nonBlocking: true
        ) { _, operation in
            switch operation {
            case .getDescriptorFlags, .getStatusFlags:
                return 0
            case .setDescriptorFlags:
                return 0
            case .setStatusFlags:
                reachedStatusSet = true
                errno = EIO
                return -1
            }
        }
        XCTAssertFalse(failed)
        XCTAssertTrue(reachedStatusSet)

        let capture = OrderedProcessOutputCapture(
            receive: { _ in },
            configurePrivateDescriptor: { _, _ in false })
        XCTAssertFalse(capture.start(),
                       "capture must fail before dup2 if CLOEXEC/nonblocking setup fails")
        XCTAssertTrue(capture.privateFDsForTesting.isEmpty)
    }

    func testPrivateTerminalAndCaptureDescriptorsDoNotReachSpawnedChild() {
        let coordinator = TerminalScreenCoordinator(
            enabled: true,
            forceTTY: true,
            captureProcessDescriptors: false,
            size: { .init(rows: 24, cols: 80) })
        let terminalFD = coordinator.terminalFDForTesting
        let recorder = OutputRecorder()
        let capture = OrderedProcessOutputCapture { recorder.append($0) }
        let started = capture.start()
        let captureFDs = capture.privateFDsForTesting
        let privateFDs = ([terminalFD] + captureFDs).filter { $0 >= 0 }
        let allCloseOnExec = privateFDs.allSatisfy {
            let flags = fcntl($0, F_GETFD)
            return flags >= 0 && (flags & FD_CLOEXEC) != 0
        }
        let readIsNonBlocking: Bool
        if let readFD = captureFDs.first {
            let flags = fcntl(readFD, F_GETFL)
            readIsNonBlocking = flags >= 0 && (flags & O_NONBLOCK) != 0
        } else {
            readIsNonBlocking = false
        }

        var childError: String?
        var childStatus: Int32 = -1
        if started {
            let list = privateFDs.map(String.init).joined(separator: " ")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "for fd in \(list); do "
                    + "if [ -e /dev/fd/$fd ]; then printf 'PRIVATE_FD_LEAK:%s\\n' \"$fd\"; fi; "
                    + "done; printf 'CHILD_FD_SCAN_DONE\\n'"
            ]
            do {
                try process.run()
                process.waitUntilExit()
                childStatus = process.terminationStatus
            } catch {
                childError = String(describing: error)
            }
        }
        let restored = capture.stop()
        let childOutput = recorder.snapshot().joined()

        XCTAssertTrue(started)
        XCTAssertNil(childError)
        XCTAssertEqual(childStatus, 0)
        XCTAssertTrue(restored)
        XCTAssertGreaterThanOrEqual(terminalFD, 0)
        XCTAssertEqual(captureFDs.count, 3)
        XCTAssertTrue(allCloseOnExec,
                      "original TTY, pipe reader, and saved stdout/stderr must all be FD_CLOEXEC")
        XCTAssertTrue(readIsNonBlocking,
                      "the capture reader must be nonblocking before its thread starts")
        XCTAssertTrue(childOutput.contains("CHILD_FD_SCAN_DONE"))
        XCTAssertFalse(childOutput.contains("PRIVATE_FD_LEAK:"),
                       "an exec'd child must not see any coordinator-private descriptor")
    }

    func testMediaTurnSuspendsBeforeAnyInlineProtocolAndSignalsUseSafeRuntime() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repl = try String(contentsOf: root.appendingPathComponent("Sources/Kist/KistREPL.swift"),
                              encoding: .utf8)
        let mediaStart = try XCTUnwrap(repl.range(of: "func runMediaTurn("))
        let mediaTail = repl[mediaStart.lowerBound...]
        let suspend = try XCTUnwrap(mediaTail.range(of: "pinnedBar.suspend()"))
        let preview = try XCTUnwrap(mediaTail.range(of: "TerminalMediaRenderer.preview("))
        XCTAssertLessThan(suspend.lowerBound, preview.lowerBound,
                          "non-slash media must abandon sticky capture before OSC/APC/image bytes")

        XCTAssertEqual(
            Set(RawMode.terminationSignalsForTesting),
            Set([SIGINT, SIGQUIT, SIGTERM, SIGHUP]))
        XCTAssertEqual(RawMode.signalResetSequenceForTesting,
                       Data("\u{001B}[r\u{001B}[?25h".utf8))
        let rawMode = try String(contentsOf: root.appendingPathComponent("Sources/Kist/TUI/RawMode.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(rawMode.contains("DispatchSource.makeSignalSource"))
        XCTAssertTrue(rawMode.contains("source.setRegistrationHandler"),
                      "resuming a dispatch source is not an event-readiness barrier")
        XCTAssertTrue(rawMode.contains("waitUntilRegistered(registration)"),
                      "raw mode and DECSTBM must wait for kernel signal registration")
        XCTAssertFalse(rawMode.contains("let handler: @convention(c)"),
                       "terminal restoration must never execute in a C signal closure")
        XCTAssertTrue(rawMode.contains("kill(getpid(), signalNumber)"),
                      "the safe handler must re-raise the exact terminating signal")
        XCTAssertTrue(rawMode.contains("originalFlags | O_NONBLOCK"),
                      "visual reset output must never block terminal restoration/re-raise")
        let enableStart = try XCTUnwrap(rawMode.range(of: "private func enable(watchMode: Bool)"))
        let enableBody = rawMode[enableStart.lowerBound...]
        let register = try XCTUnwrap(enableBody.range(
            of: "RawModeSignalCoordinator.shared.register"))
        let rawTransition = try XCTUnwrap(enableBody.range(
            of: "setAttributes(&raw)"))
        XCTAssertLessThan(register.lowerBound, rawTransition.lowerBound,
                          "signal runtime must cover the entire transition into raw mode")
        let restoreTransition = try XCTUnwrap(enableBody.range(
            of: "setAttributes(&restore)"))
        let afterRestore = enableBody[restoreTransition.upperBound...]
        let idle = try XCTUnwrap(afterRestore.range(of: "modeState = .idle"))
        XCTAssertLessThan(restoreTransition.lowerBound, idle.lowerBound,
                          "RawMode must remain signal-restorable until cooked tcsetattr completes")
        XCTAssertTrue(rawMode.contains("if errno != EINTR { return false }"),
                      "raw and cooked termios transitions must retry transient EINTR")
    }

    func testExternalInterruptSignalsRestorePTYAndReraiseExactly() throws {
        for signalNumber in [SIGINT, SIGQUIT] {
            try assertStickyDiagnosticRestoresPTY(signalNumber: signalNumber)
        }
    }

    func testContinuousTypeaheadEchoStartsOnlyAfterStickyScreenIsReleased() throws {
        #if canImport(Darwin)
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw XCTSkip("openpty unavailable")
        }
        defer {
            if master >= 0 { close(master) }
            if slave >= 0 { close(slave) }
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/kist").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("kist executable is not present in the SwiftPM products directory")
        }

        let input = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        let output = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        let error = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        defer {
            try? input.close()
            try? output.close()
            try? error.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--sticky-bar-self-test"]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["KIST_STICKY_SELF_TEST_TICKS"] = "1"
        // Hold the process in cooked mode after the production teardown ordering. A
        // continuous input probe must echo there, but only after DECSTBM was reset.
        environment["KIST_STICKY_SELF_TEST_HANDOFF_DELAY_MS"] = "250"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let originalFlags = fcntl(master, F_GETFL)
        XCTAssertGreaterThanOrEqual(originalFlags, 0)
        XCTAssertEqual(fcntl(master, F_SETFL, originalFlags | O_NONBLOCK), 0)

        var observed = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline,
              !String(decoding: observed, as: UTF8.self)
                .contains("sticky-bar diagnostic ready") {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 { observed.append(contentsOf: buffer.prefix(Int(count))) }
            } else if ready < 0, errno != EINTR {
                break
            }
        }
        XCTAssertTrue(String(decoding: observed, as: UTF8.self)
            .contains("sticky-bar diagnostic ready"))

        let stop = StopFlag()
        let writerDone = DispatchSemaphore(value: 0)
        let probe = Data("KIST_ECHO_HANDOFF_PROBE".utf8)
        let masterFD = master
        DispatchQueue.global(qos: .userInitiated).async {
            defer { writerDone.signal() }
            while !stop.isStopped {
                probe.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        _ = write(masterFD, base, bytes.count)
                    }
                }
                usleep(10_000)
            }
        }

        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < exitDeadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 20)
            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 { observed.append(contentsOf: buffer.prefix(Int(count))) }
            } else if ready < 0, errno != EINTR {
                break
            }
        }
        stop.stop()
        XCTAssertEqual(writerDone.wait(timeout: .now() + 1), .success)
        if process.isRunning {
            XCTFail("sticky handoff diagnostic did not terminate")
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        let drainDeadline = Date().addingTimeInterval(0.3)
        while Date() < drainDeadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 20)
            if ready <= 0 { continue }
            let count = read(master, &buffer, buffer.count)
            if count > 0 { observed.append(contentsOf: buffer.prefix(Int(count))) }
        }

        let readyMarker = Data("sticky-bar diagnostic ready".utf8)
        let readyRange = try XCTUnwrap(observed.range(of: readyMarker))
        let afterReady = observed[readyRange.upperBound...]
        let reset = Data(RawMode.signalResetSequenceForTesting.prefix(3)) // ESC [ r
        let resetRange = try XCTUnwrap(afterReady.range(of: reset),
                                       "normal completion never released DECSTBM")
        let beforeReset = afterReady[..<resetRange.lowerBound]
        let afterReset = afterReady[resetRange.upperBound...]
        XCTAssertNil(beforeReset.range(of: probe),
                     "kernel echo bypassed capture while the fixed screen was still active")
        XCTAssertNotNil(afterReset.range(of: probe),
                        "probe did not exercise the cooked post-teardown handoff window")
        XCTAssertEqual(process.terminationStatus, 0)
        #else
        throw XCTSkip("PTY handoff integration is Darwin-only")
        #endif
    }

    func testRawControlBytesRestorePTYAndReraiseExactly() throws {
        try assertStickyDiagnosticRestoresPTY(signalNumber: SIGINT, inputByte: 0x03)
        try assertStickyDiagnosticRestoresPTY(signalNumber: SIGQUIT, inputByte: 0x1C)
    }

    private func assertStickyDiagnosticRestoresPTY(
        signalNumber: Int32,
        inputByte: UInt8? = nil
    ) throws {
        #if canImport(Darwin)
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: 30, ws_col: 100, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw XCTSkip("openpty unavailable")
        }
        defer {
            if master >= 0 { close(master) }
            if slave >= 0 { close(slave) }
        }

        var original = termios()
        XCTAssertEqual(tcgetattr(slave, &original), 0)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/kist").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("kist executable is not present in the SwiftPM products directory")
        }

        let input = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        let output = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        let error = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        defer {
            try? input.close()
            try? output.close()
            try? error.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--sticky-bar-self-test"]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let originalFlags = fcntl(master, F_GETFL)
        XCTAssertGreaterThanOrEqual(originalFlags, 0)
        XCTAssertEqual(fcntl(master, F_SETFL, originalFlags | O_NONBLOCK), 0)

        var observed = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline,
              !String(decoding: observed, as: UTF8.self)
                .contains("sticky-bar diagnostic ready") {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 { observed.append(contentsOf: buffer.prefix(Int(count))) }
            } else if ready < 0, errno != EINTR {
                break
            }
        }
        XCTAssertTrue(
            String(decoding: observed, as: UTF8.self).contains("sticky-bar diagnostic ready"),
            "diagnostic never entered raw + DECSTBM state for signal \(signalNumber)")

        var during = termios()
        XCTAssertEqual(tcgetattr(slave, &during), 0)
        XCTAssertEqual(during.c_lflag & tcflag_t(ICANON | ECHO | ISIG), 0,
                       "diagnostic PTY was not actually raw before signal \(signalNumber)")

        if var inputByte {
            XCTAssertEqual(write(master, &inputByte, 1), 1,
                           "could not inject raw control byte for signal \(signalNumber)")
        } else {
            XCTAssertEqual(kill(process.processIdentifier, signalNumber), 0)
        }
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < exitDeadline {
            // Keep consuming the PTY while the diagnostic winds down. A real terminal emulator
            // drains continuously; if the harness stops here, streamed output can fill the PTY and
            // block the signal runtime's DECSTBM reset before it reaches termios restoration.
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 10)
            if ready > 0 {
                let count = read(master, &buffer, buffer.count)
                if count > 0 { observed.append(contentsOf: buffer.prefix(Int(count))) }
            } else if ready < 0, errno != EINTR {
                break
            }
        }
        if process.isRunning {
            XCTFail("signal \(signalNumber) did not terminate the diagnostic")
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        let drainDeadline = Date().addingTimeInterval(0.5)
        while Date() < drainDeadline {
            var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 50)
            if ready <= 0 { continue }
            let count = read(master, &buffer, buffer.count)
            if count > 0 { observed.append(contentsOf: buffer.prefix(Int(count))) }
        }

        var restored = termios()
        XCTAssertEqual(tcgetattr(slave, &restored), 0)
        let restoredMask = tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
        XCTAssertEqual(restored.c_lflag & restoredMask, original.c_lflag & restoredMask,
                       "signal \(signalNumber) left the PTY in raw mode")
        XCTAssertTrue(observed.range(of: RawMode.signalResetSequenceForTesting) != nil,
                      "signal \(signalNumber) did not emit DECSTBM/cursor reset")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, signalNumber,
                       "handler must re-raise the exact incoming signal")
        #else
        throw XCTSkip("PTY signal integration is Darwin-only")
        #endif
    }
}
