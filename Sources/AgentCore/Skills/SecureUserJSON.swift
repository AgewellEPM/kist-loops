import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Security-vetting reader for a USER-LEVEL trust file (never in the repo). One vetting path shared by
/// every trust store (`SkillTrustStore`, `SkillPublisherKeyStore`) so the checks can't drift apart —
/// a fix to one is a fix to all. Requires a PRIVATE, owner-owned, non-symlink, size-capped regular file
/// before returning a byte. FAIL CLOSED: anything off ⇒ no data ⇒ (for the caller) nothing trusted.
enum SecureUserJSON {
    /// Why the read produced no data — so each caller can craft its own warn-once message.
    /// `.absent` is the normal first-run state (silent); `.insecure`/`.unreadable` mean a file EXISTS
    /// but can't be trusted → the caller should warn AND treat everything as untrusted.
    enum Outcome {
        case ok(Data)
        case absent        // no file (or lstat error) — the normal, silent case
        case insecure      // exists but symlink / wrong owner / group- or world-accessible / oversized
        case unreadable    // exists, vetted, but the bytes couldn't be read
    }

    static func read(_ path: String) -> Outcome {
        // Open WITHOUT following a symlink at the leaf, then vet + read THE SAME file descriptor. This
        // closes the lstat→read TOCTOU (Codex + Gemini): we never re-evaluate the path, so a swap-to-
        // symlink after the check can't redirect the read. O_NOFOLLOW makes open() fail on a symlink leaf.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // ENOENT = the normal "no store yet" first-run case → silent. Anything else (ELOOP = symlink
            // leaf, EACCES, EIO, …) means a store may EXIST but is unreachable/insecure → warn + no trust.
            return errno == ENOENT ? .absent : .insecure
        }
        defer { close(fd) }

        // Vet the OPENED file via fstat — the checks apply to exactly the bytes we will read, no window
        // for a swap. Reject non-regular, wrong owner, group/world-accessible, or oversized.
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable }
        let isRegular = (st.st_mode & S_IFMT) == S_IFREG
        let ownerIsUs = st.st_uid == getuid()
        let ownerOnly = (st.st_mode & 0o077) == 0
        let saneSize = st.st_size >= 0 && st.st_size <= (1 << 20)   // ≤1 MiB
        guard isRegular, ownerIsUs, ownerOnly, saneSize else { return .insecure }

        // Read from the vetted fd, tolerant of partial reads, bounded by the same 1 MiB cap in case the
        // file grows under us (a growing file ⇒ refuse rather than slurp unboundedly).
        var out = [UInt8]()
        out.reserveCapacity(Int(st.st_size))
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = chunk.withUnsafeMutableBytes { buf -> Int in
                #if canImport(Darwin)
                return Darwin.read(fd, buf.baseAddress, buf.count)
                #else
                return Glibc.read(fd, buf.baseAddress, buf.count)
                #endif
            }
            if n < 0 { return .unreadable }
            if n == 0 { break }
            out.append(contentsOf: chunk[0..<n])
            if out.count > (1 << 20) { return .insecure }
        }
        return .ok(Data(out))
    }
}
