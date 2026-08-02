import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns the physical terminal while a sticky turn is running.
///
/// There are two independent serialization problems here:
/// 1. stdout and stderr must arrive in one byte stream, in the order the process wrote them;
/// 2. transcript writes and fixed-panel control writes must never interleave.
///
/// Runtime turns solve (1) by dup'ing stdout + stderr onto one pipe. A single reader drains that
/// pipe into the original TTY. `stateLock` solves (2): lifecycle state, transcript chunks, and
/// absolute panel redraws all pass through the same lock. Panel control bytes bypass the captured
/// descriptors entirely.
final class TerminalScreenCoordinator: @unchecked Sendable {
    struct TerminalSize: Equatable, Sendable {
        var rows: Int
        var cols: Int

        init(rows: Int, cols: Int) {
            self.rows = max(1, rows)
            self.cols = max(1, cols)
        }
    }

    /// Everything required to rebuild the fixed strip. Values are deliberately plain text; ANSI
    /// from status/hint producers is stripped before clipping so an escape sequence can never be
    /// cut in half at the physical right edge.
    struct Panel: Equatable, Sendable {
        var status: String
        var promptPrefix: String
        var pending: String
        var queuedCount: Int
        var hint: String

        init(status: String,
             promptPrefix: String = "│ ❯ ",
             pending: String = "",
             queuedCount: Int = 0,
             hint: String = "shift+tab to cycle permissions · esc to interrupt") {
            self.status = status
            self.promptPrefix = promptPrefix
            self.pending = pending
            self.queuedCount = max(0, queuedCount)
            self.hint = hint
        }
    }

    private static let ownerLock = NSLock()
    private nonisolated(unsafe) static weak var diagnosticOwner: TerminalScreenCoordinator?

    /// True only while the safe coordinator owns the during-turn panel. The event sink uses this
    /// to avoid rendering the same typed tail in its spinner.
    static var isTypeaheadPanelActive: Bool {
        ownerLock.lock()
        let owner = diagnosticOwner
        ownerLock.unlock()
        guard let owner else { return false }
        return owner.withStateLock {
            owner.presentedGeneration != nil && owner.screenIsActive && !owner.screenLeaseActive
        }
    }

    /// MCPLog's process-wide diagnostic sink lands here. Before a REPL screen exists this is the
    /// normal stderr behavior; during a pinned turn it joins the serialized transcript path.
    static func routeDiagnosticLine(_ line: String) {
        ownerLock.lock()
        let owner = diagnosticOwner
        ownerLock.unlock()
        if let owner {
            owner.acceptDiagnostic(Data(line.utf8))
        } else {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    private let enabled: Bool
    private let captureProcessDescriptors: Bool
    private let terminalSize: @Sendable () -> TerminalSize
    private let testOutput: (@Sendable (Data) -> Void)?
    private let updateSignalState: @Sendable (_ active: Bool, _ resetFD: Int32) -> Bool
    /// Serializes compound lifecycle operations. It never protects state itself: every state read
    /// and write, including writes to the physical terminal, is under `stateLock`.
    private let lifecycleOperationLock = NSRecursiveLock()
    private let stateLock = NSRecursiveLock()
    private var terminalFD: Int32 = -1
    private var capture: OrderedProcessOutputCapture?
    private var resizePoller: GenerationResizePoller?
    private var layout: PinnedBarLayout?
    private var lastPanel: Panel?
    private var deferredDiagnostics: [Data] = []
    private var screenIsActive = false
    private var stickyTurnOpen = false
    private var screenLeaseActive = false
    private var nextGeneration: UInt64 = 0
    /// Data for this generation is still accepted while the pipe performs its final drain.
    private var acceptedGeneration: UInt64?
    /// Panel/resize work is allowed only for this generation. Cleared before any drain begins.
    private var presentedGeneration: UInt64?
    private var transcriptFirewall = StreamingTranscriptFirewall()

    init(enabled: Bool,
         forceTTY: Bool? = nil,
         captureProcessDescriptors: Bool = true,
         size: @escaping @Sendable () -> TerminalSize = {
             let s = RawMode().size()
             return TerminalSize(rows: s.rows, cols: s.cols)
         },
         output: (@Sendable (Data) -> Void)? = nil,
         updateSignalState: @escaping @Sendable (
             _ active: Bool,
             _ resetFD: Int32
         ) -> Bool = {
             RawMode.updateScrollRegionSignalState(active: $0, resetFD: $1)
         }) {
        let isTTY: Bool = forceTTY ?? {
            #if canImport(Darwin) || canImport(Glibc)
            return isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
            #else
            return false
            #endif
        }()
        // An injected forceTTY transport is a deterministic test screen, not the process terminal;
        // do not let the test runner's TERM=dumb disable it.
        let dumb = forceTTY == nil
            && (ProcessInfo.processInfo.environment["TERM"] ?? "").lowercased() == "dumb"
        self.enabled = enabled && isTTY && !dumb
        self.captureProcessDescriptors = captureProcessDescriptors
        self.terminalSize = size
        self.testOutput = output
        self.updateSignalState = updateSignalState
        #if canImport(Darwin) || canImport(Glibc)
        if self.enabled, output == nil {
            // The original TTY bypasses captured stdout, so leaking it to an exec'd child would
            // also bypass the transcript firewall. F_DUPFD_CLOEXEC makes the duplicate atomic.
            terminalFD = PrivateDescriptorSafety.duplicateCloseOnExec(STDOUT_FILENO)
        }
        #endif
    }

    deinit {
        endTurnCapture()
        deactivate()
        #if canImport(Darwin) || canImport(Glibc)
        if terminalFD >= 0 { close(terminalFD) }
        #endif
    }

    var canSafelyPinTurns: Bool {
        enabled && (testOutput != nil || terminalFD >= 0)
    }

    var currentLayout: PinnedBarLayout? { withStateLock { layout } }
    var screenActive: Bool { withStateLock { screenIsActive } }
    var turnCaptureActive: Bool {
        withStateLock { presentedGeneration != nil && !screenLeaseActive }
    }
    var terminalFDForTesting: Int32 { withStateLock { terminalFD } }

    func activate() {
        withLifecycleOperation {
            withStateLock {
            guard canSafelyPinTurns, !screenIsActive, !screenLeaseActive else { return }
            let s = terminalSize()
            guard s.rows >= PinnedBar.minTerminalRows else { return }
            let next = PinnedBarLayout(rows: s.rows, cols: s.cols, panelRows: PinnedBar.panelRows)
            layout = next
            guard activateScreen(next.activateSequence) else {
                layout = nil
                return
            }
            installAsDiagnosticOwner()
            }
        }
    }

    func deactivate() {
        withLifecycleOperation {
            quiesceTurnCapture(preserveTurn: false, releaseScreen: false)
            withStateLock {
            guard let current = layout else {
                setScreenActive(false)
                uninstallAsDiagnosticOwner()
                return
            }
            if screenIsActive {
                directWrite(current.deactivateSequence)
            }
            flushDeferredDiagnosticsLocked()
            layout = nil
            setScreenActive(false)
            uninstallAsDiagnosticOwner()
            }
        }
    }

    /// Begin safe during-turn ownership. A false return means descriptor capture could not be
    /// established; callers must suspend the pinned region and use the inline fallback.
    @discardableResult
    func beginTurnCapture(panel: Panel) -> Bool {
        withLifecycleOperation {
            establishTurnCapture(panel: panel, restoringLease: false)
        }
    }

    func endTurnCapture() {
        withLifecycleOperation {
            quiesceTurnCapture(preserveTurn: false, releaseScreen: false)
        }
    }

    /// A cooked `readLine` cannot run while a fixed DECSTBM panel or descriptor capture is live:
    /// kernel echo bypasses the pipe and would race the panel. This lease drains the current
    /// generation completely, releases the region, and remembers the panel for restoration.
    @discardableResult
    func beginScreenLease() -> Bool {
        withLifecycleOperation {
            let eligible = withStateLock {
                stickyTurnOpen && presentedGeneration != nil && screenIsActive && !screenLeaseActive
            }
            guard eligible else { return false }
            withStateLock { screenLeaseActive = true }
            quiesceTurnCapture(preserveTurn: true, releaseScreen: true)
            return true
        }
    }

    /// Re-establishes descriptor capture and the fixed panel before the stdin watcher is allowed to
    /// resume. Failure is fail-closed: the screen remains a normal full-screen terminal.
    @discardableResult
    func endScreenLease() -> Bool {
        withLifecycleOperation {
            guard let panel = withStateLock({
                screenLeaseActive && stickyTurnOpen ? lastPanel : nil
            }) else { return false }
            return establishTurnCapture(panel: panel, restoringLease: true)
        }
    }

    func updatePanel(_ panel: Panel) {
        withStateLock {
            lastPanel = panel
            guard let generation = presentedGeneration, !screenLeaseActive else { return }
            refreshSizeLocked(expectedGeneration: generation)
            guard screenIsActive, let layout else { return }
            directWrite(Self.panelSequence(layout: layout, panel: panel))
        }
    }

    func updateTypeahead(pending: String, queuedCount: Int) {
        withStateLock {
            guard var panel = lastPanel else { return }
            panel.pending = pending
            panel.queuedCount = max(0, queuedCount)
            lastPanel = panel
            guard let generation = presentedGeneration, !screenLeaseActive else { return }
            refreshSizeLocked(expectedGeneration: generation)
            guard screenIsActive, let layout else { return }
            directWrite(Self.panelSequence(layout: layout, panel: panel))
        }
    }

    /// Bracketed-paste mode belongs to the stdin watcher, not the transcript. It must bypass the
    /// captured descriptors (whose firewall correctly rejects private CSI modes) while remaining
    /// serialized with panel and transcript writes.
    func setBracketedPasteEnabled(_ enabled: Bool) {
        withStateLock {
            directWrite(enabled ? "\u{001B}[?2004h" : "\u{001B}[?2004l")
        }
    }

    /// Abandons any sticky capture before releasing the region. This is the required path before
    /// inline-image, video, fullscreen, or other terminal protocols.
    @discardableResult
    func suspend() -> Bool {
        withLifecycleOperation {
            let hadTerminalState = withStateLock {
                layout != nil || acceptedGeneration != nil || stickyTurnOpen
            }
            guard hadTerminalState else { return false }
            quiesceTurnCapture(preserveTurn: false, releaseScreen: true)
            withStateLock { flushDeferredDiagnosticsLocked() }
            return true
        }
    }

    func resume() {
        withLifecycleOperation {
            withStateLock {
            guard !screenIsActive, layout != nil, !screenLeaseActive, !stickyTurnOpen else { return }
            let size = terminalSize()
            guard size.rows >= PinnedBar.minTerminalRows else { return }
            let next = PinnedBarLayout(rows: size.rows, cols: size.cols, panelRows: PinnedBar.panelRows)
            layout = next
            // Scroll turn-trailing output up by panelRows BEFORE re-pinning so the panel band the loop
            // is about to clear holds no content — otherwise the last panelRows rows of the turn (the
            // second-opinion review) are erased, not saved to scrollback. See reReserveSequence.
            _ = activateScreen(next.reReserveSequence)
            }
        }
    }

    func refreshSizeIfNeeded() {
        withStateLock { refreshSizeLocked() }
    }

    /// Test seam and the one entry point used by the ordered pipe reader.
    func acceptCaptured(_ data: Data) {
        let generation = withStateLock { acceptedGeneration }
        guard let generation else { return }
        acceptCaptured(data, generation: generation)
    }

    /// Generation-aware seam used by the pipe reader and adversarial stale-reader tests.
    func acceptCaptured(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }
        withStateLock {
            guard acceptedGeneration == generation else { return }
            refreshSizeLocked(expectedGeneration: presentedGeneration)
            emitTranscriptLocked(data)
        }
    }

    var acceptedGenerationForTesting: UInt64? { withStateLock { acceptedGeneration } }

    private func acceptDiagnostic(_ data: Data) {
        guard !data.isEmpty else { return }
        withStateLock {
            // Prompt rendering is legacy/uncoordinated while idle. Buffering avoids an asynchronous
            // MCP warning splitting its multi-row frame; the next turn/lease flushes it visibly.
            if screenIsActive, acceptedGeneration == nil {
                deferredDiagnostics.append(data)
                if deferredDiagnostics.count > 64 { deferredDiagnostics.removeFirst() }
                return
            }
            if acceptedGeneration != nil {
                emitTranscriptLocked(data)
            } else {
                directWrite(StreamingTranscriptFirewall.sanitizeComplete(data))
            }
        }
    }

    private func flushDeferredDiagnosticsLocked() {
        guard !deferredDiagnostics.isEmpty else { return }
        for data in deferredDiagnostics {
            if acceptedGeneration != nil {
                emitTranscriptLocked(data)
            } else {
                directWrite(StreamingTranscriptFirewall.sanitizeComplete(data))
            }
        }
        deferredDiagnostics.removeAll(keepingCapacity: true)
    }

    private func emitTranscriptLocked(_ data: Data) {
        let safe = transcriptFirewall.consume(data)
        if !safe.isEmpty { directWrite(safe) }
    }

    private func refreshSizeLocked(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, presentedGeneration != expectedGeneration { return }
        guard !screenLeaseActive else { return }
        // A lifecycle transition has disabled presentation but is still draining its old pipe.
        if stickyTurnOpen, presentedGeneration == nil { return }
        guard let old = layout else { return }
        let size = terminalSize()
        guard size.rows != old.rows || size.cols != old.cols else { return }

        let next = PinnedBarLayout(rows: size.rows, cols: size.cols, panelRows: PinnedBar.panelRows)
        if size.rows < PinnedBar.minTerminalRows {
            if screenIsActive {
                directWrite(Self.resizeSequence(from: old, to: next, panel: nil, activate: false))
                setScreenActive(false)
            }
            layout = next
            return
        }

        let sequence = Self.resizeSequence(
            from: old,
            to: next,
            panel: lastPanel,
            clearOldPanel: screenIsActive)
        layout = next
        _ = activateScreen(sequence)
    }

    private func establishTurnCapture(panel: Panel, restoringLease: Bool) -> Bool {
        stateLock.lock()
        let eligible = canSafelyPinTurns
            && acceptedGeneration == nil
            && presentedGeneration == nil
            && (restoringLease
                ? (screenLeaseActive && stickyTurnOpen && !screenIsActive)
                : (!stickyTurnOpen && !screenLeaseActive && screenIsActive))
        guard eligible else {
            let alreadyRunning = !restoringLease && presentedGeneration != nil
            stateLock.unlock()
            return alreadyRunning
        }

        if restoringLease {
            let size = terminalSize()
            guard size.rows >= PinnedBar.minTerminalRows else {
                stickyTurnOpen = false
                screenLeaseActive = false
                lastPanel = nil
                stateLock.unlock()
                return false
            }
            layout = PinnedBarLayout(rows: size.rows, cols: size.cols,
                                     panelRows: PinnedBar.panelRows)
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        acceptedGeneration = generation
        presentedGeneration = generation
        stickyTurnOpen = true
        lastPanel = panel
        transcriptFirewall = StreamingTranscriptFirewall()

        let nextCapture: OrderedProcessOutputCapture?
        if captureProcessDescriptors {
            let candidate = OrderedProcessOutputCapture {
                [weak self] data in self?.acceptCaptured(data, generation: generation)
            }
            guard candidate.start() else {
                acceptedGeneration = nil
                presentedGeneration = nil
                stickyTurnOpen = false
                screenLeaseActive = false
                lastPanel = nil
                stateLock.unlock()
                return false
            }
            nextCapture = candidate
        } else {
            nextCapture = nil
        }
        capture = nextCapture

        if restoringLease, let layout {
            guard activateScreen(layout.activateSequence) else {
                capture = nil
                acceptedGeneration = nil
                presentedGeneration = nil
                stickyTurnOpen = false
                screenLeaseActive = false
                lastPanel = nil
                stateLock.unlock()
                _ = nextCapture?.stop()
                return false
            }
            screenLeaseActive = false
        }
        installAsDiagnosticOwner()
        refreshSizeLocked(expectedGeneration: generation)
        flushDeferredDiagnosticsLocked()
        if screenIsActive, let layout {
            directWrite(Self.panelSequence(layout: layout, panel: panel))
        }
        stateLock.unlock()
        startResizePolling(generation: generation)
        return true
    }

    /// Stops presentation first, joins resize cancellation, restores descriptors, drains through
    /// EOF/first post-restore idle, and only then retires the accepted generation.
    private func quiesceTurnCapture(preserveTurn: Bool, releaseScreen: Bool) {
        stateLock.lock()
        let generation = acceptedGeneration
        let oldCapture = capture
        capture = nil
        presentedGeneration = nil
        let oldPoller = resizePoller
        resizePoller = nil
        if releaseScreen, screenIsActive, let layout {
            directWrite(layout.suspendSequence)
            setScreenActive(false)
        }
        stateLock.unlock()

        // A cancelled timer may already have entered its callback. Join its cancellation handler;
        // the generation check makes any in-flight callback inert before this wait begins.
        oldPoller?.cancelAndWait()
        // stop() is a true quiescence barrier. The reader owns and closes its fd; this thread never
        // closes underneath a blocked read and never returns until the reader has exited.
        let descriptorsRestored = oldCapture?.stop() ?? true

        stateLock.lock()
        if !descriptorsRestored {
            directWrite("\r\n[kist] fatal terminal capture error: stdout/stderr restore failed\r\n")
        }
        if let generation, acceptedGeneration == generation {
            let tail = transcriptFirewall.finish()
            if !tail.isEmpty { directWrite(tail) }
            acceptedGeneration = nil
        }
        if !preserveTurn {
            stickyTurnOpen = false
            screenLeaseActive = false
            lastPanel = nil
        }
        stateLock.unlock()
    }

    private func startResizePolling(generation: UInt64) {
        let shouldCreate = withStateLock {
            presentedGeneration == generation && resizePoller == nil
        }
        guard shouldCreate else { return }
        let poller = GenerationResizePoller { [weak self] in
            guard let self else { return }
            self.withStateLock {
                guard self.presentedGeneration == generation else { return }
                self.refreshSizeLocked(expectedGeneration: generation)
            }
        }
        let installed = withStateLock {
            guard presentedGeneration == generation, resizePoller == nil else { return false }
            resizePoller = poller
            return true
        }
        if !installed { poller.cancelAndWait() }
    }

    @discardableResult
    private func setScreenActive(_ active: Bool) -> Bool {
        let resetFD = active && terminalFD >= 0 ? terminalFD : STDOUT_FILENO
        if active {
            guard updateSignalState(true, resetFD) else {
                screenIsActive = false
                return false
            }
            screenIsActive = true
            return true
        }
        screenIsActive = false
        _ = updateSignalState(false, resetFD)
        return true
    }

    /// Arm terminal restoration before emitting DECSTBM. If a terminating signal arrives during
    /// the write, the safe signal runtime will reset the region; there is no post-write gap in which
    /// the process can die with an unowned scroll region.
    @discardableResult
    private func activateScreen(_ sequence: String) -> Bool {
        guard setScreenActive(true) else { return false }
        directWrite(sequence)
        return true
    }

    private func installAsDiagnosticOwner() {
        Self.ownerLock.lock()
        Self.diagnosticOwner = self
        Self.ownerLock.unlock()
    }

    private func uninstallAsDiagnosticOwner() {
        Self.ownerLock.lock()
        if Self.diagnosticOwner === self { Self.diagnosticOwner = nil }
        Self.ownerLock.unlock()
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    @discardableResult
    private func withLifecycleOperation<T>(_ body: () -> T) -> T {
        lifecycleOperationLock.lock()
        defer { lifecycleOperationLock.unlock() }
        return body()
    }

    private func directWrite(_ string: String) { directWrite(Data(string.utf8)) }

    private func directWrite(_ data: Data) {
        if let testOutput {
            testOutput(data)
            return
        }
        #if canImport(Darwin) || canImport(Glibc)
        guard terminalFD >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = write(terminalFD, base, remaining)
                if n > 0 {
                    remaining -= n
                    base = base.advanced(by: n)
                } else if errno != EINTR {
                    break
                }
            }
        }
        #endif
    }

    // MARK: - Pure screen sequences

    static func clearPanelSequence(_ layout: PinnedBarLayout) -> String {
        (layout.panelTop...layout.rows).map {
            TerminalANSI.moveTo(row: $0, col: 1) + "\u{001B}[K"
        }.joined()
    }

    /// Absolute CUP + EL per physical row. No ED, relative moves, newline, carriage return, or
    /// right-edge write is permitted in this sequence.
    static func panelSequence(layout: PinnedBarLayout, panel: Panel) -> String {
        let rows = panelRows(layout: layout, panel: panel)
        var out = TerminalANSI.saveCursor
        for (offset, text) in rows.enumerated() {
            out += TerminalANSI.moveTo(row: layout.panelTop + offset, col: 1)
                + "\u{001B}[K" + text
        }
        out += TerminalANSI.restoreCursor
        return out
    }

    static func resizeSequence(from old: PinnedBarLayout,
                               to next: PinnedBarLayout,
                               panel: Panel?,
                               activate: Bool = true,
                               clearOldPanel: Bool = true) -> String {
        var out = TerminalANSI.resetScrollRegion
        let maxRow = next.rows
        let first = clearOldPanel ? min(old.panelTop, next.panelTop) : next.panelTop
        if first <= maxRow {
            for row in first...maxRow {
                out += TerminalANSI.moveTo(row: row, col: 1) + "\u{001B}[K"
            }
        }
        guard activate else {
            out += TerminalANSI.moveTo(row: max(1, next.transcriptBottom), col: 1)
            return out
        }
        out += next.activateSequence
        if let panel { out += panelSequence(layout: next, panel: panel) }
        return out
    }

    static func panelRows(layout: PinnedBarLayout, panel: Panel) -> [String] {
        let width = max(1, layout.cols - 1) // never print the physical rightmost cell
        let statuses = TerminalCellText.stripANSI(panel.status)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init).suffix(2)
        var statusRows = Array(repeating: "", count: 2)
        for (index, value) in statuses.enumerated() {
            statusRows[2 - statuses.count + index] = TerminalCellText.clipHead(value, maxCells: width)
        }

        let queue = panel.queuedCount > 0 ? " · \(panel.queuedCount) queued" : ""
        let prefix = TerminalCellText.clipHead(TerminalCellText.stripANSI(panel.promptPrefix), maxCells: width)
        let suffix = TerminalCellText.clipHead(queue, maxCells: max(0, width - TerminalCellText.width(prefix)))
        let pendingBudget = max(0, width - TerminalCellText.width(prefix) - TerminalCellText.width(suffix))
        let pending = TerminalCellText.clipTail(panel.pending, maxCells: pendingBudget)
        let input = prefix + pending + suffix

        let borderWidth = max(1, width)
        let top: String
        let bottom: String
        if borderWidth >= 2 {
            top = "╭" + String(repeating: "─", count: borderWidth - 2) + "╮"
            bottom = "╰" + String(repeating: "─", count: borderWidth - 2) + "╯"
        } else {
            top = "·"; bottom = "·"
        }
        let hint = TerminalCellText.clipHead(TerminalCellText.stripANSI(panel.hint), maxCells: width)
        return statusRows + [top, TerminalCellText.clipHead(input, maxCells: width), bottom, hint]
    }
}

/// A resize timer whose cancellation can be joined. Clearing `presentedGeneration` makes any event
/// already queued on the utility queue inert; joining the cancellation handler guarantees that event
/// cannot survive into a later prompt or capture generation.
private final class GenerationResizePoller: @unchecked Sendable {
    private let source: DispatchSourceTimer
    private let completion = CompletionLatch()
    private let cancelLock = NSLock()
    private var cancelled = false

    init(handler: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
        source.setEventHandler(handler: handler)
        source.setCancelHandler { [completion] in
            completion.finish()
        }
        source.resume()
    }

    func cancelAndWait() {
        cancelLock.lock()
        if !cancelled {
            cancelled = true
            source.cancel()
        }
        cancelLock.unlock()
        completion.wait()
    }
}

private final class CompletionLatch: @unchecked Sendable {
    private let condition = NSCondition()
    private var complete = false

    func finish() {
        condition.lock()
        complete = true
        condition.broadcast()
        condition.unlock()
    }

    func wait() {
        condition.lock()
        while !complete { condition.wait() }
        condition.unlock()
    }
}

/// Captures both process output descriptors through one pipe. Only the coordinator's single reader
/// writes the original TTY, preserving the pipe's byte order.
final class OrderedProcessOutputCapture: @unchecked Sendable {
    static let maximumPostStopBytes = 4 * 1024 * 1024
    static let maximumPostStopNanoseconds: UInt64 = 250_000_000

    private let receive: @Sendable (Data) -> Void
    private let configurePrivateDescriptor: @Sendable (Int32, Bool) -> Bool
    private let done = DispatchSemaphore(value: 0)
    private let operationLock = NSLock()
    private let stopFlag = CaptureStopFlag()
    private var readFD: Int32 = -1
    private var savedStdout: Int32 = -1
    private var savedStderr: Int32 = -1
    private var started = false

    init(
        receive: @escaping @Sendable (Data) -> Void,
        configurePrivateDescriptor: @escaping @Sendable (Int32, Bool) -> Bool = {
            PrivateDescriptorSafety.configure(fd: $0, nonBlocking: $1)
        }
    ) {
        self.receive = receive
        self.configurePrivateDescriptor = configurePrivateDescriptor
    }

    func start() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !started else { return true }
        _ = fflush(nil)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return false }
        let r = fds[0], w = fds[1]
        // Both ends are private until dup2 installs the write end as public stdout/stderr. The read
        // end must also be nonblocking or a hostile continuous writer can defeat stop bounds.
        guard configurePrivateDescriptor(r, true),
              configurePrivateDescriptor(w, false) else {
            close(r); close(w)
            return false
        }
        let out = PrivateDescriptorSafety.duplicateCloseOnExec(STDOUT_FILENO)
        let err = PrivateDescriptorSafety.duplicateCloseOnExec(STDERR_FILENO)
        guard out >= 0, err >= 0 else {
            if out >= 0 { close(out) }
            if err >= 0 { close(err) }
            close(r); close(w)
            return false
        }
        guard Self.duplicate(w, onto: STDOUT_FILENO),
              Self.duplicate(w, onto: STDERR_FILENO) else {
            _ = Self.duplicate(out, onto: STDOUT_FILENO)
            _ = Self.duplicate(err, onto: STDERR_FILENO)
            close(out); close(err); close(r); close(w)
            return false
        }
        close(w)
        readFD = r
        savedStdout = out
        savedStderr = err
        started = true

        let stopFlag = self.stopFlag
        DispatchQueue.global(qos: .userInitiated).async { [receive, done, stopFlag] in
            var bytes = [UInt8](repeating: 0, count: 16_384)
            var reachedEOF = false
            var bytesAfterStop = 0
            readerLoop: while !reachedEOF {
                if stopFlag.limitReached(bytesAfterStop: bytesAfterStop) { break }
                let pollBeganAfterStop = stopFlag.isRequested
                var descriptor = pollfd(fd: r, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 {
                    // After stdout/stderr have been restored, the first idle interval is the drain
                    // boundary even if an inherited writer still holds the pipe open. A poll that
                    // began before restoration cannot prove a full post-restore idle interval.
                    if pollBeganAfterStop { break }
                    continue
                }

                var drainedToIdle = false
                while true {
                    let readBeganAfterStop = stopFlag.isRequested
                    let n = read(r, &bytes, bytes.count)
                    if n > 0 {
                        receive(Data(bytes[0..<n]))
                        if stopFlag.isRequested {
                            bytesAfterStop += n
                            if stopFlag.limitReached(bytesAfterStop: bytesAfterStop) {
                                break readerLoop
                            }
                        }
                        continue
                    }
                    if n == 0 {
                        reachedEOF = true
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        // As with poll, do not let a stop racing an already-started read turn a
                        // pre-restore EAGAIN into the generation's post-restore idle boundary.
                        drainedToIdle = readBeganAfterStop
                    } else {
                        reachedEOF = true
                    }
                    break
                }
                if stopFlag.isRequested, drainedToIdle { break readerLoop }
            }
            close(r)
            done.signal()
        }
        return true
        #else
        return false
        #endif
    }

    @discardableResult
    func stop() -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        operationLock.lock()
        defer { operationLock.unlock() }
        guard started else { return true }
        _ = fflush(nil)
        let stdoutRestored = Self.duplicate(savedStdout, onto: STDOUT_FILENO)
        let stderrRestored = Self.duplicate(savedStderr, onto: STDERR_FILENO)
        close(savedStdout); close(savedStderr)
        savedStdout = -1; savedStderr = -1
        stopFlag.request()
        // No timeout and no cross-thread close: the reader drains to EOF/first idle, owns the read
        // descriptor through close(2), then signals. Return is a true quiescence barrier.
        done.wait()
        readFD = -1
        started = false
        return stdoutRestored && stderrRestored
        #else
        return false
        #endif
    }

    deinit { _ = stop() }

    var privateFDsForTesting: [Int32] {
        operationLock.lock()
        defer { operationLock.unlock() }
        return [readFD, savedStdout, savedStderr].filter { $0 >= 0 }
    }

    private static func duplicate(_ source: Int32, onto destination: Int32) -> Bool {
        while dup2(source, destination) < 0 {
            if errno != EINTR { return false }
        }
        return true
    }
}

/// Checked descriptor primitives shared by the terminal owner and capture pipe. Any fcntl failure
/// is fail-closed: capture never starts with an inheritable or potentially blocking private fd.
struct PrivateDescriptorSafety {
    enum Operation: Equatable {
        case getDescriptorFlags
        case setDescriptorFlags(Int32)
        case getStatusFlags
        case setStatusFlags(Int32)
    }

    static func duplicateCloseOnExec(_ source: Int32) -> Int32 {
        retry {
            fcntl(source, F_DUPFD_CLOEXEC, 0)
        }
    }

    static func configure(fd: Int32, nonBlocking: Bool) -> Bool {
        configure(fd: fd, nonBlocking: nonBlocking, invoke: perform)
    }

    /// Injected syscall seam for deterministic EINTR/failure tests.
    static func configure(
        fd: Int32,
        nonBlocking: Bool,
        invoke: (Int32, Operation) -> Int32
    ) -> Bool {
        let descriptorFlags = retry { invoke(fd, .getDescriptorFlags) }
        guard descriptorFlags >= 0 else { return false }
        guard retry({ invoke(fd, .setDescriptorFlags(descriptorFlags | FD_CLOEXEC)) }) >= 0
        else { return false }
        guard nonBlocking else { return true }

        let statusFlags = retry { invoke(fd, .getStatusFlags) }
        guard statusFlags >= 0 else { return false }
        return retry({ invoke(fd, .setStatusFlags(statusFlags | O_NONBLOCK)) }) >= 0
    }

    private static func perform(fd: Int32, operation: Operation) -> Int32 {
        switch operation {
        case .getDescriptorFlags:
            return fcntl(fd, F_GETFD)
        case .setDescriptorFlags(let flags):
            return fcntl(fd, F_SETFD, flags)
        case .getStatusFlags:
            return fcntl(fd, F_GETFL)
        case .setStatusFlags(let flags):
            return fcntl(fd, F_SETFL, flags)
        }
    }

    private static func retry(_ operation: () -> Int32) -> Int32 {
        while true {
            let result = operation()
            if result >= 0 || errno != EINTR { return result }
        }
    }
}

private final class CaptureStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedAt: UInt64?

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestedAt != nil
    }

    func request() {
        lock.lock()
        if requestedAt == nil {
            requestedAt = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()
    }

    func limitReached(bytesAfterStop: Int) -> Bool {
        lock.lock()
        let start = requestedAt
        lock.unlock()
        guard let start else { return false }
        if bytesAfterStop >= OrderedProcessOutputCapture.maximumPostStopBytes { return true }
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= start
            && now - start >= OrderedProcessOutputCapture.maximumPostStopNanoseconds
    }
}

/// Streaming firewall between arbitrary process output and the terminal owned by the fixed panel.
///
/// It emits only complete UTF-8 scalars, printable ASCII, CR/LF/tab, and a deliberately tiny ANSI
/// allow-list (bounded SGR and EL). Cursor motion, scroll regions, display erase, origin mode, device
/// strings, hyperlinks, and graphics protocols are consumed but never reach the TTY. Parser state is
/// constant-sized for control strings and bounded to 64 bytes for CSI, so a malicious/incomplete
/// sequence cannot grow memory without bound.
struct StreamingTranscriptFirewall {
    private enum ControlStringKind: Equatable {
        case osc
        case dcs
        case apc
        case pm
        case sos
    }

    private enum State {
        case ground
        case utf8(bytes: [UInt8], expected: Int)
        case escape
        case csi(parameters: [UInt8])
        case discardCSI
        case controlString(kind: ControlStringKind, sawEscape: Bool)
    }

    private static let replacement = Array("\u{FFFD}".utf8)
    private static let maxCSIBytes = 64
    private var state: State = .ground

    mutating func consume(_ data: Data) -> Data {
        var output: [UInt8] = []
        output.reserveCapacity(data.count)
        for byte in data {
            consume(byte, into: &output)
        }
        return Data(output)
    }

    /// Completes a stream without ever forwarding a partial terminal sequence. A truncated UTF-8
    /// scalar becomes one replacement character; incomplete escape/control strings are discarded.
    mutating func finish() -> Data {
        let output: [UInt8]
        if case .utf8 = state {
            output = Self.replacement
        } else {
            output = []
        }
        state = .ground
        return Data(output)
    }

    static func sanitizeComplete(_ data: Data) -> Data {
        var parser = Self()
        var safe = parser.consume(data)
        safe.append(parser.finish())
        return safe
    }

    private mutating func consume(_ initialByte: UInt8, into output: inout [UInt8]) {
        var pending: UInt8? = initialByte
        while let byte = pending {
            pending = nil
            switch state {
            case .ground:
                switch byte {
                case 0x09, 0x0A, 0x0D:
                    output.append(byte)
                case 0x20...0x7E:
                    output.append(byte)
                case 0x1B:
                    state = .escape
                case 0xC2...0xDF:
                    state = .utf8(bytes: [byte], expected: 2)
                case 0xE0...0xEF:
                    state = .utf8(bytes: [byte], expected: 3)
                case 0xF0...0xF4:
                    state = .utf8(bytes: [byte], expected: 4)
                default:
                    // C0/C1 and malformed UTF-8 never pass through as terminal controls.
                    if byte >= 0x80 { output.append(contentsOf: Self.replacement) }
                }

            case .utf8(var bytes, let expected):
                guard (0x80...0xBF).contains(byte) else {
                    output.append(contentsOf: Self.replacement)
                    state = .ground
                    pending = byte
                    continue
                }
                bytes.append(byte)
                if bytes.count == expected {
                    if let decoded = String(bytes: bytes, encoding: .utf8),
                       let scalar = decoded.unicodeScalars.first,
                       decoded.unicodeScalars.count == 1 {
                        switch scalar.properties.generalCategory {
                        case .format where scalar.value == 0x200D:
                            // ZWJ only joins a grapheme; it cannot move the cursor or reorder
                            // terminal text. Preserve legitimate emoji such as 👩‍💻.
                            output.append(contentsOf: bytes)
                        case .control, .format, .lineSeparator, .paragraphSeparator,
                             .surrogate, .unassigned:
                            // UTF-8 encodings of C1, bidi/format controls, and logical line
                            // separators are terminal control surfaces too; valid UTF-8 alone is
                            // not permission to forward them to the physical screen.
                            break
                        default:
                            output.append(contentsOf: bytes)
                        }
                    } else {
                        output.append(contentsOf: Self.replacement)
                    }
                    state = .ground
                } else {
                    state = .utf8(bytes: bytes, expected: expected)
                }

            case .escape:
                switch byte {
                case 0x1B:
                    state = .escape
                case 0x5B: // CSI
                    state = .csi(parameters: [])
                case 0x5D: // OSC
                    state = .controlString(kind: .osc, sawEscape: false)
                case 0x50: // DCS
                    state = .controlString(kind: .dcs, sawEscape: false)
                case 0x5F: // APC (Kitty graphics uses ESC _ G)
                    state = .controlString(kind: .apc, sawEscape: false)
                case 0x5E: // PM
                    state = .controlString(kind: .pm, sawEscape: false)
                case 0x58: // SOS
                    state = .controlString(kind: .sos, sawEscape: false)
                default:
                    // Includes RIS, DECSC/DECRC, IND/RI/NEL, and charset designation.
                    state = .ground
                }

            case .csi(var parameters):
                if (0x40...0x7E).contains(byte) {
                    if let sequence = Self.allowedCSI(parameters: parameters, final: byte) {
                        output.append(contentsOf: sequence)
                    }
                    state = .ground
                } else if (0x20...0x3F).contains(byte) {
                    if parameters.count < Self.maxCSIBytes {
                        parameters.append(byte)
                        state = .csi(parameters: parameters)
                    } else {
                        state = .discardCSI
                    }
                } else if byte == 0x1B {
                    state = .escape
                } else {
                    state = .discardCSI
                }

            case .discardCSI:
                if (0x40...0x7E).contains(byte) {
                    state = .ground
                } else if byte == 0x1B {
                    state = .escape
                }

            case .controlString(let kind, let sawEscape):
                if kind == .osc, byte == 0x07 { // OSC may terminate with BEL.
                    state = .ground
                } else if sawEscape, byte == 0x5C { // ST = ESC \
                    state = .ground
                } else {
                    state = .controlString(kind: kind, sawEscape: byte == 0x1B)
                }
            }
        }
    }

    private static func allowedCSI(parameters: [UInt8], final: UInt8) -> [UInt8]? {
        switch final {
        case 0x6D: // SGR
            guard parameters.allSatisfy({
                (0x30...0x39).contains($0) || $0 == 0x3B || $0 == 0x3A
            }) else { return nil }
        case 0x4B: // EL: only the standard 0/1/2 modes, never private/selective variants.
            guard parameters.isEmpty
                    || parameters == [0x30]
                    || parameters == [0x31]
                    || parameters == [0x32] else { return nil }
        default:
            // CUP/HVP, ED, DECSTBM, DECOM, private modes, reports, and every cursor command.
            return nil
        }
        return [0x1B, 0x5B] + parameters + [final]
    }
}

/// ANSI-free, terminal-cell-aware clipping for fixed physical rows.
enum TerminalCellText {
    static func stripANSI(_ string: String) -> String {
        // First consume OSC/APC/DCS and hostile CSI as complete byte-stream protocols. The only ESC
        // sequences left are the firewall's safe SGR/EL allow-list, which this plain-text layer strips.
        let firewalled = StreamingTranscriptFirewall.sanitizeComplete(Data(string.utf8))
        let scalars = Array(String(decoding: firewalled, as: UTF8.self).unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let value = scalars[i].value
            if value == 0x1B {
                i += 1
                guard i < scalars.count else { break }
                if scalars[i].value == 0x5B { // CSI
                    i += 1
                    while i < scalars.count {
                        let v = scalars[i].value
                        i += 1
                        if (0x40...0x7E).contains(v) { break }
                    }
                } else {
                    i += 1
                }
                continue
            }
            if value == 0x0A {
                out.append("\n")
            } else if value == 0x09 {
                out.append(" ")
            } else if value >= 0x20, value != 0x7F,
                      !(0x80...0x9F).contains(value) {
                switch scalars[i].properties.generalCategory {
                case .format where value == 0x200D:
                    // ZWJ joins an emoji grapheme (👩‍💻); unlike bidi/isolates it cannot steer the
                    // terminal. Preserve it so sanitization does not visibly rewrite user text.
                    out.append(scalars[i])
                case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned:
                    break
                default:
                    out.append(scalars[i])
                }
            }
            i += 1
        }
        return String(out)
    }

    static func width(_ string: String) -> Int {
        stripANSI(string).reduce(0) { $0 + width($1) }
    }

    static func clipHead(_ string: String, maxCells: Int) -> String {
        guard maxCells > 0 else { return "" }
        let clean = stripANSI(string).replacingOccurrences(of: "\n", with: " ")
        var used = 0
        var out = ""
        for character in clean {
            let w = width(character)
            guard used + w <= maxCells else { break }
            out.append(character)
            used += w
        }
        return out
    }

    static func clipTail(_ string: String, maxCells: Int) -> String {
        guard maxCells > 0 else { return "" }
        let clean = stripANSI(string).replacingOccurrences(of: "\n", with: " ")
        guard width(clean) <= maxCells else {
            if maxCells == 1 { return "…" }
            var used = 1
            var reversed: [Character] = []
            for character in clean.reversed() {
                let w = width(character)
                guard used + w <= maxCells else { break }
                reversed.append(character)
                used += w
            }
            return "…" + String(reversed.reversed())
        }
        return clean
    }

    private static func width(_ character: Character) -> Int {
        let scalars = Array(character.unicodeScalars)
        if scalars.contains(where: { $0.value == 0x200D }) { return 2 } // joined emoji cluster
        // Emoji variation/keycap sequences occupy one two-cell glyph in Terminal.app even when
        // their base scalar (©, ❤, a digit) is normally narrow.
        if scalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 }) { return 2 }
        var widest = 0
        for scalar in scalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x200D
                || (0xFE00...0xFE0F).contains(scalar.value) {
                continue
            }
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .enclosingMark, .format:
                continue
            default:
                break
            }
            widest = max(widest, isWide(scalar.value) ? 2 : 1)
        }
        return widest
    }

    private static func isWide(_ value: UInt32) -> Bool {
        (0x1100...0x115F).contains(value)
            || value == 0x2329 || value == 0x232A
            // BMP scalars with default Emoji_Presentation / East_Asian_Width=Wide. Emoji that
            // require VS16 are handled as clusters above.
            || (0x231A...0x231B).contains(value)
            || (0x23E9...0x23EC).contains(value)
            || value == 0x23F0 || value == 0x23F3
            || (0x25FD...0x25FE).contains(value)
            || (0x2614...0x2615).contains(value)
            || (0x2648...0x2653).contains(value)
            || value == 0x267F || value == 0x2693 || value == 0x26A1
            || (0x26AA...0x26AB).contains(value)
            || (0x26BD...0x26BE).contains(value)
            || (0x26C4...0x26C5).contains(value)
            || value == 0x26CE || value == 0x26D4 || value == 0x26EA
            || (0x26F2...0x26F3).contains(value)
            || value == 0x26F5 || value == 0x26FA || value == 0x26FD
            || value == 0x2705 || (0x270A...0x270B).contains(value)
            || value == 0x2728 || value == 0x274C || value == 0x274E
            || (0x2753...0x2755).contains(value) || value == 0x2757
            || (0x2795...0x2797).contains(value)
            || value == 0x27B0 || value == 0x27BF
            || (0x2B1B...0x2B1C).contains(value)
            || value == 0x2B50 || value == 0x2B55
            || (0x2E80...0xA4CF).contains(value)
            || (0xAC00...0xD7A3).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0xFE10...0xFE19).contains(value)
            || (0xFE30...0xFE6F).contains(value)
            || (0xFF00...0xFF60).contains(value)
            || (0xFFE0...0xFFE6).contains(value)
            || (0x1F000...0x1FAFF).contains(value)
            || (0x20000...0x3FFFD).contains(value)
    }
}

/// Tiny terminal model used by deterministic stress tests: wrapping/newlines may scroll the
/// transcript band, but can never enter the fixed panel rows while DECSTBM is active.
struct StickyTranscriptScreenModel: Equatable {
    let layout: PinnedBarLayout
    private(set) var row: Int
    private(set) var col: Int = 1
    private(set) var panelWasTouched = false

    init(layout: PinnedBarLayout) {
        self.layout = layout
        self.row = layout.transcriptBottom
    }

    mutating func consume(_ string: String) {
        for character in TerminalCellText.stripANSI(string) {
            if character == "\r" {
                col = 1
            } else if character == "\n" {
                advanceRow()
                col = 1
            } else {
                let cells = max(0, TerminalCellText.width(String(character)))
                for _ in 0..<cells {
                    col += 1
                    if col > layout.cols {
                        col = 1
                        advanceRow()
                    }
                }
            }
            if row > layout.transcriptBottom { panelWasTouched = true }
        }
    }

    private mutating func advanceRow() {
        row = min(layout.transcriptBottom, row + 1)
    }
}
