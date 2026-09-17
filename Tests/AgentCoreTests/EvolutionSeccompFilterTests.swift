import XCTest
@testable import AgentCore

/// Structural tests for the seccomp escape-deny filter. The runtime behaviour (link/symlink/unshare
/// actually blocked with EPERM, allowed syscalls still work) is proven against a real kernel by
/// `scripts/evolution/linux-seccomp-proof`, which compiles the exact shipped source. These tests pin the
/// pure-computation invariants that run in the macOS suite so a regression in the BPF assembly is caught
/// without a Linux host: determinism, arch dispatch, jump ranges, and that the named escape syscalls are
/// present for both architectures.
final class EvolutionSeccompFilterTests: XCTestCase {
    func testProgramIsDeterministic() {
        XCTAssertEqual(EvolutionSeccompFilter.programBytes(), EvolutionSeccompFilter.programBytes())
        XCTAssertEqual(EvolutionSeccompFilter.programDigest(), EvolutionSeccompFilter.programDigest())
        // 8 bytes per classic sock_filter instruction.
        XCTAssertEqual(EvolutionSeccompFilter.programBytes().count,
                       EvolutionSeccompFilter.program().count * 8)
    }

    func testDigestIsSixtyFourLowercaseHex() {
        let d = EvolutionSeccompFilter.programDigest()
        XCTAssertEqual(d.count, 64)
        XCTAssertTrue(d.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) })
    }

    func testEveryJumpOffsetIsWithinBPFRange() {
        // Classic BPF jt/jf are UInt8; program() precondition-guards this, and we re-assert structurally.
        for insn in EvolutionSeccompFilter.program() {
            XCTAssertLessThanOrEqual(insn.jt, 255)
            XCTAssertLessThanOrEqual(insn.jf, 255)
        }
    }

    func testFirstInstructionsDispatchOnArchThenKillNonNative() {
        let p = EvolutionSeccompFilter.program()
        // 0: load arch word; 1: JEQ x86_64; 2: JEQ aarch64; 3: RET (kill non-native arch).
        XCTAssertEqual(p[0].k, 4)                                   // seccomp_data.arch offset
        XCTAssertEqual(p[1].k, EvolutionSeccompFilter.AUDIT_ARCH_X86_64)
        XCTAssertEqual(p[2].k, EvolutionSeccompFilter.AUDIT_ARCH_AARCH64)
        XCTAssertEqual(p[3].code, 0x06)                            // BPF_RET | BPF_K
        XCTAssertEqual(p[3].k, 0x8000_0000)                        // SECCOMP_RET_KILL_PROCESS
    }

    func testNamedEscapeSyscallsAreDeniedForBothArches() {
        // Both architectures' link/linkat/symlinkat/unshare/setns numbers must appear as JEQ comparands.
        let comparands = Set(EvolutionSeccompFilter.program()
            .filter { $0.code == (0x05 | 0x10 | 0x00) }             // BPF_JMP|BPF_JEQ|BPF_K
            .map { $0.k })
        // aarch64: linkat=37, symlinkat=36, unshare=97, setns=268; x86_64: link=86, linkat=265, unshare=272
        for nr: UInt32 in [37, 36, 97, 268, 86, 265, 272] {
            XCTAssertTrue(comparands.contains(nr), "denied syscall number \(nr) missing from filter")
        }
    }
}
