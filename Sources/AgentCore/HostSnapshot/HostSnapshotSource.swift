import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// PROTOTYPE — host_snapshot frame acquisition (SECURITY BOUNDARY). Fail-closed and bounded at every step:
// freshness gate rejects a stale desktop, a hard byte-cap refuses an oversized PNG (with NO base64), and a
// hard wall-clock timeout refuses a hung conversion. On ANY failure the returned result carries an error
// and ZERO captured bytes. All external dependencies (file path, clock, "is this an interactive session",
// and the two subprocess conversions) are injected so this is unit-testable without a live TinkyStream.

public struct HostSnapshotSource: Sendable {

    // Bounds — pinned by the contract.
    public static let freshnessWindowSeconds: TimeInterval = 3    // latest.jpg older than this ⇒ stale
    public static let maxPNGBytes = 8 * 1024 * 1024               // 8 MiB hard cap
    public static let hardTimeoutSeconds: TimeInterval = 12       // wall-clock cap on the whole acquire

    // Display bound — a signed frame that claims a display index the host can't plausibly have is a lie.
    public static let maxDisplayIndex = 63    // absurd-value guard; real fleets never exceed a handful

    /// A successfully acquired frame: the RAW PNG bytes, the source label, dimensions, AND the display index
    /// that was ACTUALLY captured. The caller signs `capturedDisplayIndex`, NEVER the merely-requested one,
    /// so a frame can never be mislabeled as a display it didn't capture.
    public struct Acquired: Sendable, Equatable {
        public let pngBytes: Data
        public let source: String   // "tinkystream" | "screencapture"
        public let width: Int
        public let height: Int
        public let capturedDisplayIndex: Int
    }

    public enum AcquireError: Error, Sendable, Equatable {
        case staleFrameSource
        case missingFrameSource
        case oversized              // PNG (or source JPEG) exceeded the byte cap — refused, NO base64
        case timedOut
        case conversionFailed(String)
        case decodeFailed(String)
        case invalidDisplayIndex    // requested display negative / above the absurd-value bound
        case displayNotCapturable   // requested a specific display the source can't honor (would mislabel)
    }

    /// The result of opening `latest.jpg` ONCE: the fstat'd mtime and the JPEG bytes read from THAT SAME fd.
    /// TOCTOU-safe by construction — the freshness decision (`mtime`) and the bytes converted to PNG
    /// (`bytes`) come from a single open fd, so the path can never be swapped between the freshness check and
    /// the conversion. `nil` (the whole optional) means the file was absent.
    public struct LatestJPEG: Sendable, Equatable {
        public let mtime: Date
        public let bytes: Data
        public init(mtime: Date, bytes: Data) { self.mtime = mtime; self.bytes = bytes }
    }

    // Injected dependencies (defaults wire the real host).
    let latestJpgPath: String
    let now: @Sendable () -> Date
    let isInteractiveSession: @Sendable () -> Bool
    /// Open `latest.jpg` ONCE and return its mtime + bytes from the SAME fd (fail-closed on symlink / over
    /// the byte cap). `nil` ⇒ file absent. This is the TOCTOU fix: the freshness mtime and the JPEG bytes
    /// fed to `jpegToPNG` originate from one open fd, never a re-opened path. Throws on a read/cap error.
    let openLatestJPEG: @Sendable (_ path: String) throws -> LatestJPEG?
    /// Convert already-read, IMMUTABLE JPEG bytes → raw PNG bytes (via sips on an owner-only private temp),
    /// or throw. `deadline` bounds the whole call. It takes BYTES (not a path) so the converted image is the
    /// exact bytes the freshness check accepted — a re-open can't smuggle different content in.
    let jpegToPNG: @Sendable (_ jpegBytes: Data, _ deadline: Date) async throws -> Data
    /// screencapture -x fallback. Returns raw PNG bytes or throws. `deadline` bounds the whole call.
    let screencapturePNG: @Sendable (_ displayIndex: Int, _ deadline: Date) async throws -> Data

    public init(latestJpgPath: String = HostSnapshotSource.defaultLatestJpgPath,
                now: @escaping @Sendable () -> Date = { Date() },
                isInteractiveSession: @escaping @Sendable () -> Bool = HostSnapshotSource.terminalIsInteractive,
                openLatestJPEG: (@Sendable (_ path: String) throws -> LatestJPEG?)? = nil,
                jpegToPNG: (@Sendable (_ jpegBytes: Data, _ deadline: Date) async throws -> Data)? = nil,
                screencapturePNG: (@Sendable (_ displayIndex: Int, _ deadline: Date) async throws -> Data)? = nil) {
        self.latestJpgPath = latestJpgPath
        self.now = now
        self.isInteractiveSession = isInteractiveSession
        self.openLatestJPEG = openLatestJPEG ?? { path in try Self.openLatestJPEGFromDisk(path) }
        self.jpegToPNG = jpegToPNG ?? { bytes, deadline in try await Self.runSipsToPNG(jpegBytes: bytes, deadline: deadline) }
        self.screencapturePNG = screencapturePNG ?? { idx, deadline in try await Self.runScreencapture(displayIndex: idx, deadline: deadline) }
    }

    public static var defaultLatestJpgPath: String {
        NSHomeDirectory() + "/.kist/runs/desktop-vision-console/stream/latest.jpg"
    }

    /// Acquire one frame, fail-closed. Preference order: a FRESH TinkyStream latest.jpg (converted to PNG);
    /// else, ONLY in an interactive session, a screencapture fallback. Non-interactive + stale/missing
    /// source ⇒ error, zero bytes.
    public func acquire(displayIndex: Int) async -> Result<Acquired, AcquireError> {
        // Bound the requested display FIRST: a negative or absurd index is an atomic error, never signed.
        guard displayIndex >= 0, displayIndex <= Self.maxDisplayIndex else {
            return .failure(.invalidDisplayIndex)
        }
        let deadline = now().addingTimeInterval(Self.hardTimeoutSeconds)

        // TOCTOU FIX: open latest.jpg ONCE. The returned mtime (for the freshness decision) and the JPEG
        // bytes (fed to conversion) come from the SAME fd — the path can't be swapped between "is it fresh"
        // and "convert it". An over-cap or unreadable source throws; a symlink is refused (O_NOFOLLOW). A
        // `nil` result means the file is absent (⇒ missing, not stale).
        let latest: LatestJPEG?
        do {
            latest = try openLatestJPEG(latestJpgPath)
        } catch let e as AcquireError {
            // The primary source itself errored (e.g. oversized). If we're interactive, still allow the
            // screencapture fallback below rather than fail on a bad primary; otherwise surface the error.
            if isInteractiveSession() { latest = nil } else { return .failure(e) }
        } catch {
            if isInteractiveSession() { latest = nil } else { return .failure(.conversionFailed("\(error)")) }
        }
        let fileWasPresent = latest != nil
        let fresh = latest.map {
            let age = now().timeIntervalSince($0.mtime)
            return age <= Self.freshnessWindowSeconds && age >= -Self.freshnessWindowSeconds
        } ?? false

        // Preferred path: fresh TinkyStream frame → sips → PNG, converting the EXACT bytes we just read from
        // the single fd. The stream carries the PRIMARY display (0) ONLY — it ignores --display. So a
        // specific non-zero --display CANNOT be honored on this path; fail-closed (no frame) rather than sign
        // a frame falsely labeled with that display index.
        if fresh, let jpeg = latest {
            guard displayIndex == 0 else { return .failure(.displayNotCapturable) }
            // Cap applies to the SOURCE bytes read from the fd, BEFORE conversion (defense-in-depth: the
            // openLatestJPEG default already caps, but an injected seam might not).
            guard jpeg.bytes.count <= Self.maxPNGBytes else { return .failure(.oversized) }
            do {
                let png = try await withDeadline(deadline) { try await self.jpegToPNG(jpeg.bytes, deadline) }
                return try Self.finish(png: png, source: "tinkystream", capturedDisplayIndex: 0)
            } catch let e as AcquireError {
                return .failure(e)
            } catch {
                return .failure(.conversionFailed("\(error)"))
            }
        }

        // Fallback path: ONLY when interactive AND the primary source was stale/missing. screencapture -D
        // honors the requested index, so the captured index IS the requested index here.
        guard isInteractiveSession() else {
            return .failure(fileWasPresent ? .staleFrameSource : .missingFrameSource)
        }
        do {
            let png = try await withDeadline(deadline) { try await self.screencapturePNG(displayIndex, deadline) }
            return try Self.finish(png: png, source: "screencapture", capturedDisplayIndex: displayIndex)
        } catch let e as AcquireError {
            return .failure(e)
        } catch {
            return .failure(.conversionFailed("\(error)"))
        }
    }

    /// Enforce the byte cap and decode dimensions AFTER acquisition. Oversized ⇒ refuse with NO bytes
    /// returned to the caller (the frame never becomes base64). A PNG whose header we can't read is a
    /// decode failure, not a silently-zero frame.
    static func finish(png: Data, source: String, capturedDisplayIndex: Int) throws -> Result<Acquired, AcquireError> {
        guard png.count <= maxPNGBytes else { return .failure(.oversized) }
        guard let (w, h) = pngDimensions(png) else { return .failure(.decodeFailed("not a PNG or truncated header")) }
        return .success(Acquired(pngBytes: png, source: source, width: w, height: h,
                                 capturedDisplayIndex: capturedDisplayIndex))
    }

    /// Wall-clock deadline wrapper. Races the work against a sleep to the deadline; whichever finishes
    /// first wins, and a timeout throws `.timedOut` (fail-closed — no bytes leak past the wall).
    func withDeadline<T: Sendable>(_ deadline: Date, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { throw AcquireError.timedOut }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                throw AcquireError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AcquireError.timedOut }
            return first
        }
    }

    // MARK: - PNG header parsing (pure, unit-tested)

    /// Read (width, height) from a PNG's IHDR chunk without any imaging framework. Layout: 8-byte
    /// signature, then a chunk whose length(4)+type(4)="IHDR" precede width(4 BE) at offset 16 and
    /// height(4 BE) at offset 20. Validates the 8-byte PNG magic so a JPEG/garbage buffer is rejected.
    public static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<8]) == sig else { return nil }
        guard bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52 else { return nil } // "IHDR"
        func be32(_ o: Int) -> Int {
            (Int(bytes[o]) << 24) | (Int(bytes[o + 1]) << 16) | (Int(bytes[o + 2]) << 8) | Int(bytes[o + 3])
        }
        let w = be32(16), h = be32(20)
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    // MARK: - Live host implementations (integration — not unit-tested)

    public static func terminalIsInteractive() -> Bool {
        #if canImport(Darwin)
        return isatty(STDIN_FILENO) == 1
        #else
        return false
        #endif
    }

    /// TOCTOU-safe primary read: open `latest.jpg` ONCE (O_RDONLY | O_NOFOLLOW | O_CLOEXEC), fstat THAT fd
    /// for the mtime, and read the JPEG bytes from the SAME fd (with the 8 MiB cap enforced before slurp).
    /// The mtime used for the freshness decision and the bytes fed to conversion therefore come from one
    /// open fd — the file at `path` cannot be swapped between the freshness check and the conversion. A
    /// symlink at `path` is refused (O_NOFOLLOW). Returns nil ONLY when the file is absent (ENOENT); any
    /// other failure (non-regular / read error / over cap) throws.
    static func openLatestJPEGFromDisk(_ path: String) throws -> LatestJPEG? {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }   // truly absent ⇒ missing (not stale), no throw
            throw AcquireError.conversionFailed("latest.jpg: open failed (errno \(errno))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw AcquireError.conversionFailed("latest.jpg: not a regular file")
        }
        // Pre-slurp cap gate on the fstat'd size — an over-cap source is refused WITHOUT reading it.
        guard st.st_size <= off_t(maxPNGBytes) else { throw AcquireError.oversized }
        #if canImport(Darwin)
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000)
        #else
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtim.tv_sec) + TimeInterval(st.st_mtim.tv_nsec) / 1_000_000_000)
        #endif
        let bytes = try readCappedFD(fd, label: "latest.jpg")
        guard !bytes.isEmpty else { throw AcquireError.conversionFailed("latest.jpg: empty") }
        return LatestJPEG(mtime: mtime, bytes: bytes)
    }

    /// Convert already-read, IMMUTABLE JPEG bytes → PNG. Writes the bytes to a PRIVATE owner-only temp
    /// (0600, inside a freshly-created 0700 owner-only dir) and runs sips on THAT temp — never on the
    /// re-opened source path. So the image sips converts is exactly the bytes the freshness check accepted;
    /// a swap of the original path after the read cannot change what gets converted.
    static func runSipsToPNG(jpegBytes: Data, deadline: Date) async throws -> Data {
        let (dir, inPath, outPath) = try makeOwnerOnlyConversionPaths()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try writeOwnerOnlyPrivateFile(jpegBytes, to: inPath)
        let ok = try await runProcess("/usr/bin/sips", ["-s", "format", "png", inPath, "--out", outPath], deadline: deadline)
        guard ok else { throw AcquireError.conversionFailed("sips JPEG→PNG failed") }
        return try readCappedFile(outPath, label: "sips JPEG→PNG")
    }

    /// A freshly-created, owner-only (0700) private directory + the in/out paths inside it. The directory is
    /// per-conversion (UUID) so no other process shares it; the 0700 mode denies group/other traversal.
    private static func makeOwnerOnlyConversionPaths() throws -> (dir: String, inPath: String, outPath: String) {
        let dir = NSTemporaryDirectory() + "kist-host-snapshot-\(UUID().uuidString)"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw AcquireError.conversionFailed("private temp dir create failed: \(error)")
        }
        return (dir, dir + "/in.jpg", dir + "/out.png")
    }

    /// Write bytes to an owner-only (0600) file via an EXCLUSIVE, no-follow open — never overwriting or
    /// following a symlink planted at the path (the dir is fresh+0700, so this is belt-and-suspenders).
    private static func writeOwnerOnlyPrivateFile(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AcquireError.conversionFailed("private temp file create failed (errno \(errno))") }
        defer { close(fd) }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var written = 0
            let total = raw.count
            guard let base = raw.baseAddress else { return }
            while written < total {
                let n = write(fd, base.advanced(by: written), total - written)
                if n < 0 { if errno == EINTR { continue }; throw AcquireError.conversionFailed("private temp write failed") }
                // A zero-byte write is not "done" — it means no progress (e.g. disk full). Fail closed so
                // sips can never convert a truncated JPEG into a mislabeled/short frame.
                if n == 0 { throw AcquireError.conversionFailed("private temp short write (no progress)") }
                written += n
            }
            guard written == total else { throw AcquireError.conversionFailed("private temp short write (\(written)/\(total))") }
        }
    }

    /// Read from an ALREADY-OPEN fd with the byte cap enforced during the read (used for the single-fd
    /// latest.jpg read so the bytes come from the same fd the freshness fstat used).
    static func readCappedFD(_ fd: Int32, label: String) throws -> Data {
        let limit = maxPNGBytes + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let want = min(buffer.count, limit - data.count)
            let n = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, want) }
            if n < 0 { if errno == EINTR { continue }; throw AcquireError.conversionFailed("\(label): read error") }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard data.count <= maxPNGBytes else { throw AcquireError.oversized }
        return data
    }

    static func runScreencapture(displayIndex: Int, deadline: Date) async throws -> Data {
        let tmp = NSTemporaryDirectory() + "kist-host-snapshot-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        var args = ["-x"]
        if displayIndex > 0 { args += ["-D", String(displayIndex + 1)] } // screencapture -D is 1-based
        args.append(tmp)
        let ok = try await runProcess("/usr/sbin/screencapture", args, deadline: deadline)
        guard ok else { throw AcquireError.conversionFailed("screencapture failed") }
        return try readCappedFile(tmp, label: "screencapture")
    }

    /// Read a temp file with the byte cap enforced BEFORE the whole file is slurped: stat the file and
    /// refuse if it is already over cap (no allocation of an oversized buffer), then read at most cap+1
    /// bytes and reject if it exceeded cap. Guarantees an oversized conversion never lands its bytes in
    /// memory — the cap is a real wall, not an after-the-fact length check on an already-read blob.
    static func readCappedFile(_ path: String, label: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw AcquireError.conversionFailed("\(label): output unreadable") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw AcquireError.conversionFailed("\(label): output not a regular file")
        }
        // Pre-slurp gate: an on-disk size over the cap is refused WITHOUT reading the bytes.
        guard st.st_size <= off_t(maxPNGBytes) else { throw AcquireError.oversized }
        // Read up to cap+1 to catch a file that grew between stat and read; > cap ⇒ oversized.
        let limit = maxPNGBytes + 1
        var data = Data(); data.reserveCapacity(min(Int(st.st_size), maxPNGBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < limit {
            let want = min(buffer.count, limit - data.count)
            let n = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress, want) }
            if n < 0 { if errno == EINTR { continue }; throw AcquireError.conversionFailed("\(label): read error") }
            if n == 0 { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard data.count <= maxPNGBytes else { throw AcquireError.oversized }
        guard !data.isEmpty else { throw AcquireError.conversionFailed("\(label): empty output") }
        return data
    }

    /// Bounded subprocess runner, fail-closed on the child's lifecycle. The wait is NON-BLOCKING (a
    /// `terminationHandler` resumes a continuation) so we never park a cooperative thread on
    /// `waitUntilExit`. On the deadline we escalate SIGTERM → SIGKILL so the child (sips/screencapture) is
    /// guaranteed dead on EVERY exit path, including timeout. True only on a clean exit 0.
    static func runProcess(_ path: String, _ args: [String], deadline: Date) async throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()

        // Shared "did we have to kill it" flag, set by the killer, read after the child exits.
        let killedFlag = KilledFlag()
        // Escalating killer: SIGTERM at the deadline, then SIGKILL a short grace later if still alive. The
        // sleeps are CANCELLABLE — once the child exits normally we cancel this task so it returns at once
        // (never blocks the caller for the full deadline). It only records a kill if it actually signaled.
        let killer = Task {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                catch { return }   // cancelled ⇒ child already exited; nothing to kill
            }
            if p.isRunning { p.terminate(); killedFlag.set() }            // SIGTERM
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }  // 0.5s grace (cancellable)
            if p.isRunning { kill(p.processIdentifier, SIGKILL); killedFlag.set() } // SIGKILL — guaranteed dead
        }

        do {
            try p.run()
        } catch {
            killer.cancel()
            throw AcquireError.conversionFailed("failed to launch \(path): \(error)")
        }

        // Non-blocking wait: resume exactly once when the child exits (no waitUntilExit on this thread).
        // A tiny lock-guarded flag makes resume idempotent against the handler-vs-already-exited race.
        let resumeGuard = ResumeOnce()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in if resumeGuard.claim() { cont.resume() } }
            // Race: if the child already exited before the handler was set, resume now.
            if !p.isRunning, resumeGuard.claim() { cont.resume() }
        }
        // Child has exited: stop the killer's countdown so we don't park on its sleep, then read its verdict.
        killer.cancel()
        _ = await killer.value
        let killed = killedFlag.get()
        // Timed out iff we had to kill it OR we're past the deadline with a non-clean exit.
        if killed || (Date() >= deadline && p.terminationStatus != 0) { throw AcquireError.timedOut }
        return p.terminationStatus == 0
    }
}

/// Thread-safe boolean latch the killer sets when it actually signals the child; read once after exit.
private final class KilledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// One-shot resume latch: makes a `CheckedContinuation.resume()` idempotent across the terminationHandler-
/// vs-already-exited race so the continuation resumes EXACTLY once (double-resume traps in Swift).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// True the FIRST time only; false on every subsequent call.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
