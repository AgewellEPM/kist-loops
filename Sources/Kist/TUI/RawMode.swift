import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Puts stdin into raw mode and guarantees restoration on normal exit and process termination.
///
/// Signal delivery is intentionally handled by `DispatchSourceSignal`: no Swift closure, lock,
/// allocation, termios call, or array construction runs inside a C signal handler. The ordinary
/// interactive/termination signals are ignored only while terminal state is active, their previous
/// dispositions are restored when the final mode exits, and the dispatch handler restores the
/// terminal before re-raising the exact signal with its default disposition.
final class RawMode: @unchecked Sendable {
    #if canImport(Darwin) || canImport(Glibc)
    private enum ModeState: Equatable {
        case idle
        /// The original termios has been captured and the signal runtime is installed. This state
        /// deliberately covers both the transition into raw mode and steady-state raw mode.
        case restorable
    }

    private var original = termios()
    private var modeState: ModeState = .idle
    private var signalToken: UUID?
    private let stateLock = NSLock()
    private let fd = STDIN_FILENO

    var isActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return modeState == .restorable
    }

    func enable() {
        enable(watchMode: false)
    }

    /// Raw mode tuned for a background interrupt watcher: VMIN=0/VTIME=1 bounds watcher join time.
    func enableForWatch() {
        enable(watchMode: true)
    }

    private func enable(watchMode: Bool) {
        stateLock.lock()
        guard isatty(fd) != 0, modeState == .idle else {
            stateLock.unlock()
            return
        }
        guard tcgetattr(fd, &original) == 0 else {
            stateLock.unlock()
            return
        }
        // Install signal ownership while stdin is still cooked. Its callback may arrive now, but it
        // blocks on `stateLock` until either the raw transition succeeds or its failure is settled.
        guard let token = RawModeSignalCoordinator.shared.register({ [weak self] in
            self?.disable()
        }) else {
            stateLock.unlock()
            return
        }
        signalToken = token
        modeState = .restorable

        var raw = original
        raw.c_iflag &= ~(tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON))
        raw.c_lflag &= ~(tcflag_t(ECHO | ICANON | IEXTEN | ISIG))
        setControlChar(&raw, VMIN, watchMode ? 0 : 1)
        setControlChar(&raw, VTIME, watchMode ? 1 : 0)
        // TCSANOW preserves unread typeahead across prompt ↔ watcher handoffs.
        guard setAttributes(&raw) else {
            signalToken = nil
            modeState = .idle
            stateLock.unlock()
            RawModeSignalCoordinator.shared.unregister(token)
            return
        }
        stateLock.unlock()
    }

    /// One timed read for the watcher: the byte that arrived within the VTIME window, or nil.
    func readByteTimed() -> UInt8? {
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 1 ? byte : nil
    }

    func disable() {
        stateLock.lock()
        guard modeState == .restorable else {
            stateLock.unlock()
            return
        }
        let token = signalToken
        var restore = original
        // Keep the state restorable and the signal registration installed until tcsetattr has
        // completed. A signal callback racing this transition blocks on the lock, then either sees
        // an already-cooked idle state or retries restoration after a failure.
        guard setAttributes(&restore) else {
            stateLock.unlock()
            return
        }
        signalToken = nil
        modeState = .idle
        stateLock.unlock()
        if let token { RawModeSignalCoordinator.shared.unregister(token) }
    }

    /// Read up to `max` bytes (blocking for at least one). Returns [] on EOF/error.
    func readBytes(max: Int = 64) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: max)
        let count = read(fd, &buffer, max)
        guard count > 0 else { return [] }
        return Array(buffer[0..<count])
    }

    deinit { disable() }

    private func setControlChar(_ value: inout termios, _ index: Int32, _ byte: UInt8) {
        withUnsafeMutablePointer(to: &value.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) {
                $0[Int(index)] = byte
            }
        }
    }

    private func setAttributes(_ value: inout termios) -> Bool {
        while tcsetattr(fd, TCSANOW, &value) != 0 {
            if errno != EINTR { return false }
        }
        return true
    }

    @discardableResult
    static func updateScrollRegionSignalState(active: Bool, resetFD: Int32) -> Bool {
        RawModeSignalCoordinator.shared.updateScrollRegion(active: active, resetFD: resetFD)
    }

    static var terminationSignalsForTesting: [Int32] {
        RawModeSignalPlan.terminationSignals
    }

    static var signalResetSequenceForTesting: Data {
        RawModeSignalPlan.resetSequence
    }

    static func runSignalCleanupForTesting(resetFD: Int32, restore: @escaping () -> Void) {
        RawModeSignalCoordinator.restoreAndReset(
            callbacks: [restore],
            reset: true,
            resetFD: resetFD)
    }
    #else
    func enable() {}
    func enableForWatch() {}
    func disable() {}
    func readBytes(max: Int = 64) -> [UInt8] { [] }
    func readByteTimed() -> UInt8? { nil }
    var isActive: Bool { false }
    @discardableResult
    static func updateScrollRegionSignalState(active: Bool, resetFD: Int32) -> Bool { !active }
    static var terminationSignalsForTesting: [Int32] { [] }
    static var signalResetSequenceForTesting: Data { Data() }
    #endif

    /// Current terminal size (rows, cols); falls back to 24×80 when it cannot be read.
    func size() -> (rows: Int, cols: Int) {
        #if canImport(Darwin) || canImport(Glibc)
        var size = winsize()
        if ioctl(STDIN_FILENO, UInt(TIOCGWINSZ), &size) == 0, size.ws_row > 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }
        #endif
        return (24, 80)
    }
}

#if canImport(Darwin) || canImport(Glibc)
private enum RawModeSignalPlan {
    // Raw mode clears ISIG, but another process can still deliver SIGINT/SIGQUIT directly. Leaving
    // either at its default disposition would terminate before termios/DECSTBM cleanup.
    static let terminationSignals: [Int32] = [SIGINT, SIGQUIT, SIGTERM, SIGHUP]
    static let resetSequence = Data([
        0x1B, 0x5B, 0x72,                         // DECSTBM reset
        0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68       // cursor visible
    ])
}

private struct SavedSignalDisposition {
    let handler: (@convention(c) (Int32) -> Void)?
}

/// Process-wide safe signal runtime shared by nested RawMode instances.
private final class RawModeSignalCoordinator: @unchecked Sendable {
    static let shared = RawModeSignalCoordinator()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "kist.raw-mode.signal", qos: .userInitiated)
    private var restoreOrder: [UUID] = []
    private var restorers: [UUID: () -> Void] = [:]
    private var sources: [Int32: DispatchSourceSignal] = [:]
    /// Kept for the lifetime of `sources`. A completed group makes subsequent registrations an
    /// immediate wait; an incomplete group means no caller may enter raw mode or emit DECSTBM yet.
    private var sourceRegistration: DispatchGroup?
    private var sourceRegistrationGeneration: UInt64?
    private var previousDispositions: [Int32: SavedSignalDisposition] = [:]
    private var generation: UInt64 = 0
    private var terminating = false
    private var scrollRegionActive = false
    private var scrollRegionResetFD = STDOUT_FILENO

    func register(_ restore: @escaping () -> Void) -> UUID? {
        lock.lock()
        let token = UUID()
        restoreOrder.append(token)
        restorers[token] = restore
        let registration = sources.isEmpty
            ? installSourcesLocked()
            : currentRegistrationLocked()
        lock.unlock()

        guard let registration, waitUntilRegistered(registration) else {
            unregister(token)
            return nil
        }
        return token
    }

    func unregister(_ token: UUID) {
        lock.lock()
        restorers.removeValue(forKey: token)
        restoreOrder.removeAll { $0 == token }
        guard restoreOrder.isEmpty, !scrollRegionActive, !terminating else {
            lock.unlock()
            return
        }
        let teardown = takeDownSourcesLocked()
        finishTeardown(teardown)
        lock.unlock()
    }

    @discardableResult
    func updateScrollRegion(active: Bool, resetFD: Int32) -> Bool {
        lock.lock()
        scrollRegionActive = active
        scrollRegionResetFD = resetFD
        var registration: SignalSourceRegistration?
        if active, sources.isEmpty {
            registration = installSourcesLocked()
        } else if active {
            registration = currentRegistrationLocked()
        } else if !active, restoreOrder.isEmpty, !terminating {
            finishTeardown(takeDownSourcesLocked())
        }
        lock.unlock()

        guard active else { return true }
        guard let registration, waitUntilRegistered(registration) else {
            lock.lock()
            // Do not clobber a newer successful activation after this generation was retired.
            if sources.isEmpty { scrollRegionActive = false }
            lock.unlock()
            return false
        }
        return true
    }

    private struct SignalSourceRegistration {
        let group: DispatchGroup
        let generation: UInt64
    }

    /// libdispatch explicitly permits a delay between `resume()` and registration during which
    /// events are missed. Callers synchronously cross this bounded barrier before making any
    /// terminal state depend on the sources.
    private func installSourcesLocked() -> SignalSourceRegistration {
        precondition(sources.isEmpty)
        terminating = false
        generation &+= 1
        let installedGeneration = generation
        let registration = DispatchGroup()
        sourceRegistration = registration
        sourceRegistrationGeneration = installedGeneration
        for signalNumber in RawModeSignalPlan.terminationSignals {
            let previous = signal(signalNumber, SIG_IGN)
            previousDispositions[signalNumber] = SavedSignalDisposition(handler: previous)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            registration.enter()
            source.setRegistrationHandler {
                registration.leave()
            }
            source.setEventHandler { [weak self] in
                self?.handle(signal: signalNumber, generation: installedGeneration)
            }
            sources[signalNumber] = source
            source.resume()
        }
        return SignalSourceRegistration(group: registration, generation: installedGeneration)
    }

    private func currentRegistrationLocked() -> SignalSourceRegistration? {
        guard let group = sourceRegistration,
              let registrationGeneration = sourceRegistrationGeneration else {
            return nil
        }
        return SignalSourceRegistration(group: group, generation: registrationGeneration)
    }

    private func waitUntilRegistered(_ registration: SignalSourceRegistration) -> Bool {
        // Registration is a local kqueue operation and normally completes in microseconds. A bound
        // prevents a broken dispatch runtime from hanging terminal startup; timeout fails closed.
        guard registration.group.wait(timeout: .now() + 1) == .success else {
            lock.lock()
            if generation == registration.generation,
               sourceRegistration === registration.group {
                finishTeardown(takeDownSourcesLocked())
            }
            lock.unlock()
            return false
        }

        lock.lock()
        let stillCurrent = generation == registration.generation
            && sourceRegistration === registration.group
            && sources.count == RawModeSignalPlan.terminationSignals.count
            && !terminating
        lock.unlock()
        return stillCurrent
    }

    private func takeDownSourcesLocked()
        -> (sources: [DispatchSourceSignal],
            dispositions: [Int32: SavedSignalDisposition]) {
        generation &+= 1 // invalidate handlers already queued before cancel
        let teardown = (Array(sources.values), previousDispositions)
        sources.removeAll()
        sourceRegistration = nil
        sourceRegistrationGeneration = nil
        previousDispositions.removeAll()
        return teardown
    }

    /// Called under `lock`: restoring dispositions must be atomic with respect to a new registration,
    /// or a concurrent install can have its SIG_IGN dispositions overwritten by stale teardown.
    private func finishTeardown(
        _ teardown: (sources: [DispatchSourceSignal],
                     dispositions: [Int32: SavedSignalDisposition])
    ) {
        for source in teardown.sources { source.cancel() }
        for signalNumber in RawModeSignalPlan.terminationSignals {
            if let saved = teardown.dispositions[signalNumber] {
                _ = signal(signalNumber, saved.handler)
            }
        }
    }

    private func handle(signal signalNumber: Int32, generation expected: UInt64) {
        lock.lock()
        guard generation == expected, !terminating else {
            lock.unlock()
            return
        }
        terminating = true
        generation &+= 1
        let callbacks = restoreOrder.reversed().compactMap { restorers[$0] }
        let reset = scrollRegionActive
        let resetFD = scrollRegionResetFD
        let installedSources = Array(sources.values)
        lock.unlock()

        for source in installedSources { source.cancel() }
        Self.restoreAndReset(callbacks: callbacks, reset: reset, resetFD: resetFD)

        // Re-raise the exact signal with its own default disposition. The dispatch source may invoke
        // us on a worker with that signal masked, so unblock it and use thread-directed `raise` first.
        // Process-directed `kill` and `_exit` remain failed-delivery fallbacks.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        sigaddset(&unblocked, signalNumber)
        _ = pthread_sigmask(SIG_UNBLOCK, &unblocked, nil)
        _ = signal(signalNumber, SIG_DFL)
        _ = raise(signalNumber)
        _ = kill(getpid(), signalNumber)
        _exit(128 + signalNumber)
    }

    /// Nested modes restore in reverse order, leaving the oldest captured (cooked) state last.
    /// Termios comes first so visual cleanup can never strand the user's shell in raw mode.
    fileprivate static func restoreAndReset(
        callbacks: [() -> Void],
        reset: Bool,
        resetFD: Int32
    ) {
        for restore in callbacks { restore() }
        if reset {
            // A stopped terminal emulator or an undrained PTY can fill its output queue. Never let a
            // blocking reset write prevent cooked-termios restoration or exact signal re-raise.
            writeResetWithoutBlocking(to: resetFD)
        }
    }

    private static func writeResetWithoutBlocking(to fd: Int32) {
        let originalFlags = fcntl(fd, F_GETFL)
        guard originalFlags >= 0 else { return }
        let changedFlags = originalFlags & O_NONBLOCK == 0
        if changedFlags, fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) != 0 {
            return
        }
        defer {
            if changedFlags { _ = fcntl(fd, F_SETFL, originalFlags) }
        }

        RawModeSignalPlan.resetSequence.withUnsafeBytes { bytes in
            guard var base = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = write(fd, base, remaining)
                if written > 0 {
                    remaining -= written
                    base = base.advanced(by: written)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    // EAGAIN or a terminal error: termios is already cooked, so terminate rather
                    // than hanging indefinitely in best-effort visual cleanup.
                    break
                }
            }
        }
    }
}
#endif
