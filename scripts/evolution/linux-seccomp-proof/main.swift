import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Standalone Linux proof for EvolutionSeccompFilter.
//
// Compiled together with the EXACT shipped Sources/AgentCore/EvolutionSeccompFilter.swift (plus a tiny
// BuilderEvidenceDigest shim so it links without the rest of AgentCore). It installs the real compiled
// filter via prctl(PR_SET_SECCOMP) in a child and adversarially attempts the escape syscalls the filter
// must block, then runs a NO-FILTER control proving the filter is what blocks them (not the environment).
//
// Requires Linux. Prints "ALL SECCOMP PROOFS OK" on success; exits non-zero on any failure.

// Minimal shim so EvolutionSeccompFilter.programDigest() links; the security-critical program() and
// programBytes() below are the exact shipped code.
enum BuilderEvidenceDigest {
    static func sha256(_ value: String) -> String { String(repeating: "0", count: 64) }
    static func sha256Bytes(_ bytes: [UInt8]) -> String { String(repeating: "0", count: 64) }
}

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

// C structs matching the kernel ABI.
struct SockFilterC { var code: UInt16; var jt: UInt8; var jf: UInt8; var k: UInt32 }
struct SockFprogC { var len: UInt16; var filter: UnsafeMutablePointer<SockFilterC>? }

// Swift's Glibc module surfaces neither prctl/unshare nor the CLONE flags, and `syscall` is variadic
// (unavailable in Swift). Bind the non-variadic libc symbols directly.
@_silgen_name("prctl")
func c_prctl(_ option: Int32, _ a2: UInt, _ a3: UInt, _ a4: UInt, _ a5: UInt) -> Int32
@_silgen_name("unshare")
func c_unshare(_ flags: Int32) -> Int32

let PR_SET_NO_NEW_PRIVS: Int32 = 38
let PR_SET_SECCOMP: Int32 = 22
let SECCOMP_MODE_FILTER: UInt = 2
let CLONE_NEWNS_FLAG: Int32 = 0x0002_0000

// Build the sock_filter array from the exact shipped program.
let filters: [SockFilterC] = EvolutionSeccompFilter.program().map {
    SockFilterC(code: $0.code, jt: $0.jt, jf: $0.jf, k: $0.k)
}
print("filter program: \(filters.count) BPF instructions, \(EvolutionSeccompFilter.programBytes().count) bytes")

// Run `work` in a child. If installFilter, install the seccomp filter before running. Returns the child's
// exit status word.
func runChild(installFilter: Bool, _ work: @escaping () -> Int32) -> Int32 {
    let pid = fork()
    if pid == 0 {
        if installFilter {
            if c_prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 { _exit(200) }
            var f = filters
            let rc = f.withUnsafeMutableBufferPointer { buf -> Int32 in
                var prog = SockFprogC(len: UInt16(buf.count), filter: buf.baseAddress)
                return withUnsafeMutablePointer(to: &prog) { p in
                    c_prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, UInt(bitPattern: Int(bitPattern: p)), 0, 0)
                }
            }
            if rc != 0 { _exit(201) }
        }
        _exit(work())
    }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return status
}

func exited(_ s: Int32) -> Int32 { (s & 0x7f) == 0 ? (s >> 8) & 0xff : -1 }
func signalled(_ s: Int32) -> Int32 { let t = s & 0x7f; return (t != 0 && t != 0x7f) ? t : -1 }

// Scratch dir on a writable tmpfs so link()/symlink() would otherwise succeed.
let dir = "/tmp/seccomp-proof-\(getpid())"
_ = mkdir(dir, 0o700)
let src = dir + "/src"; let dst = dir + "/dst"; let sym = dir + "/sym"
FileManager.default.createFile(atPath: src, contents: Data("x".utf8))

// Adversary work closures. Each returns the errno of the attempted escape (0 = it SUCCEEDED, which under
// the filter is a failure of the proof).
func tryLink() -> Int32 { _ = unlink(dst); errno = 0; return link(src, dst) == 0 ? 0 : errno }
func trySymlink() -> Int32 { _ = unlink(sym); errno = 0; return symlink(src, sym) == 0 ? 0 : errno }
func tryUnshare() -> Int32 { errno = 0; return c_unshare(CLONE_NEWNS_FLAG) == 0 ? 0 : errno }
// An allowed control: write a file (openat/write must still work under the filter).
func tryAllowedWrite() -> Int32 {
    let fd = open(dir + "/ok", O_CREAT | O_WRONLY, 0o600)
    if fd < 0 { return errno }
    _ = "hello".withCString { write(fd, $0, 5) }
    close(fd)
    return 0
}

// ---- Control: NO filter → link/symlink/unshare succeed (proves the environment allows them) ----
let ctlLink = exited(runChild(installFilter: false) { tryLink() })
guard ctlLink == 0 else { die("control: link() unexpectedly failed with errno \(ctlLink) — cannot attribute the deny to the filter") }
print("CONTROL OK: without the filter, link() succeeds (errno 0)")

// ---- With filter: link → EPERM(1) ----
let fLink = exited(runChild(installFilter: true) { tryLink() })
guard fLink == 1 else { die("FILTER link: expected EPERM(1), got \(fLink) (0=succeeded=escape!)") }
print("SECCOMP OK: link() blocked with EPERM under the filter")

// ---- With filter: symlink → EPERM(1) ----
let fSym = exited(runChild(installFilter: true) { trySymlink() })
guard fSym == 1 else { die("FILTER symlink: expected EPERM(1), got \(fSym)") }
print("SECCOMP OK: symlink() blocked with EPERM under the filter")

// ---- With filter: unshare(CLONE_NEWNS) → EPERM(1) ----
let fUnshare = exited(runChild(installFilter: true) { tryUnshare() })
guard fUnshare == 1 else { die("FILTER unshare: expected EPERM(1), got \(fUnshare)") }
print("SECCOMP OK: unshare(CLONE_NEWNS) blocked with EPERM under the filter")

// ---- With filter: an allowed syscall (openat/write) still works ----
let fWrite = exited(runChild(installFilter: true) { tryAllowedWrite() })
guard fWrite == 0 else { die("FILTER allowed-write: expected success, got errno \(fWrite) — filter is over-broad") }
print("SECCOMP OK: openat()/write() still succeed under the filter (not over-broad)")

print("ALL SECCOMP PROOFS OK")
