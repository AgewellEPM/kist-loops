import Foundation

/// The escape-syscall deny filter for the Linux evolution sandbox.
///
/// Bubblewrap already unshares namespaces, denies the network, and read-only-binds the host, but the
/// evolution plan additionally requires "an attested link/linkat syscall deny" before candidate code may
/// run: a hard link or symlink can defeat a read-only bind mount, and namespace/kernel/keyring/ptrace
/// syscalls are classic sandbox escapes. This builds a classic seccomp-BPF program that returns EPERM for
/// those syscalls, for BOTH x86_64 and aarch64, and KILLs any process making a syscall under a non-native
/// architecture (which closes the 32-bit-compat-ABI bypass where a different syscall table applies).
///
/// The compiled program is content-addressed (`programDigest`) so the sandbox attestor can bind the exact
/// filter bytes into its policy and refuse to run candidate code unless the attested filter is installed.
/// The program is produced deterministically here and installed by bubblewrap via `--seccomp <fd>` before
/// it execs the candidate; AgentCore never trusts the child to install its own containment.
public enum EvolutionSeccompFilter {
    /// The escape syscalls denied on every supported architecture, named for auditability. Numbers are
    /// resolved per-arch below (aarch64 numbers were confirmed against the kernel uapi headers; x86_64
    /// numbers are the stable syscall ABI). arm64 has no bare `link`/`symlink`/`mknod` — only `*at`.
    public enum DeniedSyscall: String, CaseIterable, Sendable {
        case link, linkat, symlink, symlinkat            // defeat a read-only bind via (sym)link
        case mount, umount2, pivot_root, chroot, move_mount, open_tree, fsopen, fsmount  // mount-ns escape
        case setns, unshare                              // namespace escape
        case ptrace, process_vm_readv, process_vm_writev // cross-process injection
        case add_key, request_key, keyctl                // kernel keyring
        case init_module, finit_module, delete_module    // kernel module load/unload
        case kexec_load, kexec_file_load, bpf            // kernel image / BPF load
        case mknod, mknodat                              // device node creation
    }

    /// Little-endian serialization of the classic seccomp-BPF program (array of 8-byte `sock_filter`).
    /// This is exactly what `bubblewrap --seccomp <fd>` consumes.
    public static func programBytes() -> [UInt8] {
        var out: [UInt8] = []
        for insn in program() {
            appendLE16(&out, insn.code)
            out.append(insn.jt)
            out.append(insn.jf)
            appendLE32(&out, insn.k)
        }
        return out
    }

    /// SHA-256 of the compiled program bytes, as 64 lowercase hex chars — the attestation identity of the
    /// filter. If a single instruction changes, this changes, so a stale or forged filter cannot be bound.
    public static func programDigest() -> String {
        BuilderEvidenceDigest.sha256Bytes(programBytes())
    }

    // MARK: - BPF assembly

    struct Instruction: Equatable { var code: UInt16; var jt: UInt8; var jf: UInt8; var k: UInt32 }

    // classic BPF opcodes
    private static let BPF_LD: UInt16 = 0x00
    private static let BPF_W: UInt16 = 0x00
    private static let BPF_ABS: UInt16 = 0x20
    private static let BPF_JMP: UInt16 = 0x05
    private static let BPF_JEQ: UInt16 = 0x10
    private static let BPF_K: UInt16 = 0x00
    private static let BPF_RET: UInt16 = 0x06

    // seccomp_data field offsets
    private static let offsetNr: UInt32 = 0
    private static let offsetArch: UInt32 = 4

    // audit arch identifiers
    static let AUDIT_ARCH_X86_64: UInt32 = 0xC000_003E
    static let AUDIT_ARCH_AARCH64: UInt32 = 0xC000_00B7

    // seccomp return actions
    private static let SECCOMP_RET_KILL_PROCESS: UInt32 = 0x8000_0000
    private static let SECCOMP_RET_ERRNO: UInt32 = 0x0005_0000
    private static let SECCOMP_RET_ALLOW: UInt32 = 0x7FFF_0000
    private static let EPERM: UInt32 = 1

    /// x86_64 syscall numbers (stable ABI, asm/unistd_64.h). nil where the syscall does not exist.
    private static func number(_ s: DeniedSyscall, archX86: Bool) -> UInt32? {
        if archX86 {
            switch s {
            case .link: return 86
            case .linkat: return 265
            case .symlink: return 88
            case .symlinkat: return 266
            case .mount: return 165
            case .umount2: return 166
            case .pivot_root: return 155
            case .chroot: return 161
            case .move_mount: return 429
            case .open_tree: return 428
            case .fsopen: return 430
            case .fsmount: return 432
            case .setns: return 308
            case .unshare: return 272
            case .ptrace: return 101
            case .process_vm_readv: return 310
            case .process_vm_writev: return 311
            case .add_key: return 248
            case .request_key: return 249
            case .keyctl: return 250
            case .init_module: return 175
            case .finit_module: return 313
            case .delete_module: return 176
            case .kexec_load: return 246
            case .kexec_file_load: return 320
            case .bpf: return 321
            case .mknod: return 133
            case .mknodat: return 259
            }
        } else {
            // aarch64 (asm-generic). Confirmed against kernel uapi headers on the target host.
            switch s {
            case .link, .symlink, .mknod: return nil   // arm64 has only the *at variants
            case .linkat: return 37
            case .symlinkat: return 36
            case .mount: return 40
            case .umount2: return 39
            case .pivot_root: return 41
            case .chroot: return 51
            case .move_mount: return 429
            case .open_tree: return 428
            case .fsopen: return 430
            case .fsmount: return 432
            case .setns: return 268
            case .unshare: return 97
            case .ptrace: return 117
            case .process_vm_readv: return 270
            case .process_vm_writev: return 271
            case .add_key: return 217
            case .request_key: return 218
            case .keyctl: return 219
            case .init_module: return 105
            case .finit_module: return 273
            case .delete_module: return 106
            case .kexec_load: return 104
            case .kexec_file_load: return 294
            case .bpf: return 280
            case .mknodat: return 33
            }
        }
    }

    /// Build the program. Layout:
    ///   0: A = arch
    ///   1: if A == X86_64  jump to x86 block
    ///   2: if A == AARCH64 jump to arm block
    ///   3: RET KILL_PROCESS            (non-native architecture: closes the compat-ABI bypass)
    ///   x86 block:  A = nr; for each denied nr: if A == nr jump to DENY; RET ALLOW
    ///   arm block:  A = nr; for each denied nr: if A == nr jump to DENY; RET ALLOW
    ///   DENY: RET ERRNO(EPERM)
    static func program() -> [Instruction] {
        let x86 = DeniedSyscall.allCases.compactMap { number($0, archX86: true) }
        let arm = DeniedSyscall.allCases.compactMap { number($0, archX86: false) }

        var p: [Instruction] = []
        p.append(Instruction(code: BPF_LD | BPF_W | BPF_ABS, jt: 0, jf: 0, k: offsetArch)) // 0
        let x86DispatchIdx = p.count
        p.append(Instruction(code: BPF_JMP | BPF_JEQ | BPF_K, jt: 0, jf: 0, k: AUDIT_ARCH_X86_64)) // 1
        let armDispatchIdx = p.count
        p.append(Instruction(code: BPF_JMP | BPF_JEQ | BPF_K, jt: 0, jf: 0, k: AUDIT_ARCH_AARCH64)) // 2
        p.append(Instruction(code: BPF_RET | BPF_K, jt: 0, jf: 0, k: SECCOMP_RET_KILL_PROCESS)) // 3

        var denyJumpIdxs: [Int] = []

        let x86Start = p.count
        p.append(Instruction(code: BPF_LD | BPF_W | BPF_ABS, jt: 0, jf: 0, k: offsetNr))
        for nr in x86 {
            denyJumpIdxs.append(p.count)
            p.append(Instruction(code: BPF_JMP | BPF_JEQ | BPF_K, jt: 0, jf: 0, k: nr))
        }
        p.append(Instruction(code: BPF_RET | BPF_K, jt: 0, jf: 0, k: SECCOMP_RET_ALLOW))

        let armStart = p.count
        p.append(Instruction(code: BPF_LD | BPF_W | BPF_ABS, jt: 0, jf: 0, k: offsetNr))
        for nr in arm {
            denyJumpIdxs.append(p.count)
            p.append(Instruction(code: BPF_JMP | BPF_JEQ | BPF_K, jt: 0, jf: 0, k: nr))
        }
        p.append(Instruction(code: BPF_RET | BPF_K, jt: 0, jf: 0, k: SECCOMP_RET_ALLOW))

        let denyIdx = p.count
        p.append(Instruction(code: BPF_RET | BPF_K, jt: 0, jf: 0, k: SECCOMP_RET_ERRNO | EPERM))

        // Resolve jumps (all forward; offsets are instruction counts after the jump instruction).
        p[x86DispatchIdx].jt = offset(from: x86DispatchIdx, to: x86Start)
        p[armDispatchIdx].jt = offset(from: armDispatchIdx, to: armStart)
        for i in denyJumpIdxs { p[i].jt = offset(from: i, to: denyIdx) }
        return p
    }

    private static func offset(from: Int, to: Int) -> UInt8 {
        let delta = to - from - 1
        precondition(delta >= 0 && delta <= 255, "seccomp jump offset \(delta) out of BPF range")
        return UInt8(delta)
    }

    private static func appendLE16(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
    }
    private static func appendLE32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
    }
}
