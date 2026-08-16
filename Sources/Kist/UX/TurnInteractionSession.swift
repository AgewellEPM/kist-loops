import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One stdin owner for the complete submitted-message lifecycle.
///
/// The old watcher existed only around `loop.turn`, leaving routing, prompt compilation, estate
/// lookup, model substitution, and post-review blind to typing. This session starts immediately
/// after a non-slash submit and stays alive until the next prompt. `InterruptibleTurn.run` borrows
/// it, registering only the currently active model/runner task for ESC cancellation; it never starts
/// a second reader.
final class TurnInteractionSession: @unchecked Sendable {
    private static let currentLock = NSLock()
    private nonisolated(unsafe) static weak var activeSession: TurnInteractionSession?

    static var current: TurnInteractionSession? {
        currentLock.lock()
        defer { currentLock.unlock() }
        return activeSession
    }

    private let interactive: Bool
    private let queue: TurnInputQueue
    private let raw = RawMode()
    private let stateLock = NSLock()
    private let modeLock = NSLock()
    private var watcher: Task<Void, Never>?
    private var queueHookID: UUID?
    private var started = false
    private var finished = false
    private var activeCancel: (@Sendable () -> Void)?
    private var activeReason: InterruptibleTurn.InterruptReason?
    private var activeGeneration = 0
    private let onInputChange: (@Sendable (_ pending: String, _ queuedCount: Int) -> Void)?
    private let onScreenLeaseBegin: (@Sendable () -> Bool)?
    private let onScreenLeaseEnd: (@Sendable () -> Bool)?
    private let onScreenReleaseBeforeFinish: (@Sendable () -> Void)?
    private let setBracketedPasteMode: (@Sendable (_ enabled: Bool) -> Void)?
    private let onInterruptUnavailable: (@Sendable () -> Void)?
    private var screenLeaseHeld = false
    private var interruptUnavailableReported = false

    init(enabled: Bool = InterruptibleTurn.isInteractive(),
         queue: TurnInputQueue = .shared,
         onInputChange: (@Sendable (_ pending: String, _ queuedCount: Int) -> Void)? = nil,
         onScreenLeaseBegin: (@Sendable () -> Bool)? = nil,
         onScreenLeaseEnd: (@Sendable () -> Bool)? = nil,
         onScreenReleaseBeforeFinish: (@Sendable () -> Void)? = nil,
         setBracketedPasteMode: (@Sendable (_ enabled: Bool) -> Void)? = nil,
         onInterruptUnavailable: (@Sendable () -> Void)? = nil) {
        self.interactive = enabled
        self.queue = queue
        self.onInputChange = onInputChange
        self.onScreenLeaseBegin = onScreenLeaseBegin
        self.onScreenLeaseEnd = onScreenLeaseEnd
        self.onScreenReleaseBeforeFinish = onScreenReleaseBeforeFinish
        self.setBracketedPasteMode = setBracketedPasteMode
        self.onInterruptUnavailable = onInterruptUnavailable
    }

    func start() {
        stateLock.lock()
        guard !started else { stateLock.unlock(); return }
        started = true
        stateLock.unlock()

        queue.begin()
        if let onInputChange {
            queueHookID = queue.addOnChange { [weak self] in
                guard let self else { return }
                let snapshot = self.queue.preview()
                onInputChange(snapshot.pending, snapshot.queuedCount)
            }
            let snapshot = queue.preview()
            onInputChange(snapshot.pending, snapshot.queuedCount)
        }
        installAsCurrent()
        guard interactive else { return }

        // A failed tcgetattr/tcsetattr transition must not start a reader against cooked stdin:
        // that read can block indefinitely and make the next-prompt join hang. Collection remains
        // active, but interrupt/type-ahead watching fails closed for this submitted-message session.
        guard armWatch() else {
            reportInterruptUnavailableOnce()
            return
        }
        StdinArbiter.shared.registerWatcher(
            suspend: { [weak self] in self?.suspendForStdinLease() },
            resume: { [weak self] in self?.resumeFromStdinLease() })

        watcher = Task.detached { [weak self] in
            guard let self else { return }
            defer {
                self.disarmWatch()
                StdinArbiter.shared.unregisterWatcher()
            }
            while !Task.isCancelled {
                guard StdinArbiter.shared.watcherMayRead() else {
                    usleep(15_000)
                    continue
                }
                // Re-arming after a cooked stdin lease can fail independently of initial startup.
                // Exit before read(2) rather than accidentally blocking in canonical mode.
                guard self.raw.isActive else {
                    if !Task.isCancelled { self.reportInterruptUnavailableOnce() }
                    break
                }
                let action = InterruptibleTurn.scanOnce(
                    readByte: { self.raw.readByteTimed() },
                    collect: { self.queue.feed($0) })
                switch action {
                case .interject:
                    self.interruptActive(.interject)
                case .cancel:
                    self.interruptActive(.cancel)
                case .none, .swallowedSequence:
                    break
                }
            }
        }
    }

    /// Register exactly one cancellable unit of model/runner work. The keyboard watcher remains the
    /// same task across sequential model calls; only this cancellation closure changes.
    func runModelTask<T>(
        onInterrupt: @escaping (InterruptibleTurn.InterruptReason) -> Void,
        _ work: @escaping () async -> T
    ) async -> T {
        let task = Task { await work() }

        let generation = withStateLock {
            activeGeneration += 1
            activeReason = nil
            activeCancel = { task.cancel() }
            return activeGeneration
        }

        let result = await task.value

        let reason = withStateLock {
            let value = generation == activeGeneration ? activeReason : nil
            if generation == activeGeneration {
                activeCancel = nil
                activeReason = nil
            }
            return value
        }
        if let reason { onInterrupt(reason) }
        return result
    }

    func finish() async {
        let state: (shouldFinish: Bool, watcher: Task<Void, Never>?) = withStateLock {
            guard started, !finished else { return (false, nil) }
            finished = true
            let task = watcher
            watcher = nil
            activeCancel = nil
            return (true, task)
        }
        guard state.shouldFinish else { return }

        // Keep stdin raw until descriptor capture and DECSTBM have both been released.
        // Kernel echo does not traverse the stdout/stderr capture pipe, so reversing these
        // operations lets continuous typeahead write through the fixed panel at turn end.
        onScreenReleaseBeforeFinish?()
        state.watcher?.cancel()
        if let watcher = state.watcher { _ = await watcher.value }
        // The watcher normally performs these in its defer. Repeating them is idempotent and
        // also closes the initial raw-mode-failure path, which never created a watcher.
        StdinArbiter.shared.unregisterWatcher()
        disarmWatch()
        if let queueHookID {
            queue.removeOnChange(queueHookID)
            self.queueHookID = nil
        }
        queue.end()
        uninstallAsCurrent()
    }

    /// Deterministic input seam: tests can prove collection remains active before, during, and after
    /// model work without racing a real terminal reader.
    func feedForTesting(_ byte: UInt8) {
        queue.feed(byte)
    }

    /// Deterministic ESC seam used to verify that the current task—not a stale earlier one—is cancelled.
    func interruptForTesting(_ reason: InterruptibleTurn.InterruptReason) {
        interruptActive(reason)
    }

    /// Wait for `runModelTask` to publish its cancellation closure before injecting a test interrupt.
    /// A fixed number of scheduler yields is racy on loaded builders.
    func waitForActiveModelTaskForTesting() async {
        while !withStateLock({ activeCancel != nil }) {
            await Task.yield()
        }
    }

    /// Deterministic seams for proving the exact cooked-prompt lease order without a real TTY.
    func suspendForStdinLeaseForTesting() { suspendForStdinLease() }
    func resumeFromStdinLeaseForTesting() { resumeFromStdinLease() }

    var watcherActiveForTesting: Bool {
        withStateLock { watcher != nil }
    }

    /// Sticky screen capture is safe only after this session has actually established
    /// its bounded raw stdin watcher. A failed tcsetattr must leave the screen unpinned.
    var safelyOwnsRawStdin: Bool {
        guard interactive, raw.isActive else { return false }
        return withStateLock { started && !finished && watcher != nil }
    }

    private func interruptActive(_ reason: InterruptibleTurn.InterruptReason) {
        stateLock.lock()
        guard activeCancel != nil else {
            stateLock.unlock()
            return
        }
        if activeReason != .cancel {
            activeReason = reason
        }
        let cancel = activeCancel
        stateLock.unlock()
        cancel?()
    }

    @discardableResult
    private func armWatch() -> Bool {
        guard interactive else { return false }
        modeLock.lock()
        defer { modeLock.unlock() }
        stateLock.lock()
        let shouldArm = started && !finished
        stateLock.unlock()
        guard shouldArm else { return false }
        raw.enableForWatch()
        guard raw.isActive else { return false }
        emitBracketedPasteMode(true)
        return true
    }

    private func disarmWatch() {
        guard interactive else { return }
        modeLock.lock()
        defer { modeLock.unlock() }
        if raw.isActive { emitBracketedPasteMode(false) }
        raw.disable()
    }

    private func suspendForStdinLease() {
        // Disable bracketed paste, release capture/DECSTBM while stdin is STILL raw, and
        // only then restore cooked mode. Kernel echo bypasses process stdout, so calling
        // disarmWatch() first creates a write-through race into the fixed panel.
        modeLock.lock()
        if interactive, raw.isActive { emitBracketedPasteMode(false) }
        let held = onScreenLeaseBegin?() ?? false
        raw.disable()
        modeLock.unlock()
        if held { withStateLock { screenLeaseHeld = true } }
    }

    private func resumeFromStdinLease() {
        let held = withStateLock {
            let value = screenLeaseHeld
            screenLeaseHeld = false
            return value
        }
        // Re-capture and re-pin before raw watcher input (and bracketed paste) resumes.
        if held { _ = onScreenLeaseEnd?() }
        if !armWatch() { reportInterruptUnavailableOnce() }
    }

    /// Raw watch mode is optional, but losing it must never be silent: without it ETX/ESC cannot
    /// cancel the active model task. Report at most once for this submitted-message session even if
    /// initial activation, a later stdin-lease re-arm, and the watcher all observe the same failure.
    private func reportInterruptUnavailableOnce() {
        let shouldReport = withStateLock {
            guard started, !finished, !interruptUnavailableReported else { return false }
            interruptUnavailableReported = true
            return true
        }
        if shouldReport { onInterruptUnavailable?() }
    }

    private func emitBracketedPasteMode(_ enabled: Bool) {
        if let setBracketedPasteMode {
            setBracketedPasteMode(enabled)
        } else {
            FileHandle.standardOutput.write(
                Data((enabled ? "\u{001B}[?2004h" : "\u{001B}[?2004l").utf8))
        }
    }

    private func installAsCurrent() {
        Self.currentLock.lock()
        assert(Self.activeSession == nil || Self.activeSession === self,
               "TurnInteractionSession: concurrent stdin owners")
        Self.activeSession = self
        Self.currentLock.unlock()
    }

    private func uninstallAsCurrent() {
        Self.currentLock.lock()
        if Self.activeSession === self { Self.activeSession = nil }
        Self.currentLock.unlock()
    }

    @discardableResult
    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    deinit {
        if let queueHookID { queue.removeOnChange(queueHookID) }
        if started && !finished {
            queue.end()
            disarmWatch()
            let held = withStateLock {
                let value = screenLeaseHeld
                screenLeaseHeld = false
                return value
            }
            if held { _ = onScreenLeaseEnd?() }
        }
        uninstallAsCurrent()
    }
}
