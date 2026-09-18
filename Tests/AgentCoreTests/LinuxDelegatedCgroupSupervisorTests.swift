import XCTest
@testable import AgentCore

/// Contract tests for the delegated cgroup-v2 supervisor. The full membership/limit/cleanup behaviour is
/// proven against a real cgroup2 host by `scripts/evolution/linux-supervisor-proof` (which compiles the
/// exact shipped source). These tests pin the platform-invariant surfaces that run in the macOS suite:
/// config validation and, off Linux, the fail-closed refusal that keeps advisory hosts from minting a
/// hard-containment receipt.
final class LinuxDelegatedCgroupSupervisorTests: XCTestCase {
    private let hex64 = String(repeating: "a", count: 64)

    private func config(scopeID: String = "11111111-1111-4111-8111-111111111111",
                        root: String = "/sys/fs/cgroup/evolution",
                        cpu: UInt64 = 30_000_000, memory: UInt64 = 128 * 1_024 * 1_024,
                        pids: UInt32 = 16, exec: String? = nil)
        -> LinuxDelegatedCgroupSupervisor.Config {
        LinuxDelegatedCgroupSupervisor.Config(
            delegatedRoot: root, scopeID: scopeID,
            limits: HardProcessContainmentLimits(
                aggregateCPUTimeMicros: cpu, aggregateMemoryBytes: memory, aggregateProcessCount: pids),
            mechanismDigest: hex64, policyDigest: hex64, executionDigest: exec ?? hex64)
    }

    private func run(_ config: LinuxDelegatedCgroupSupervisor.Config, launchPath: String = "/bin/true")
        throws -> (LinuxDelegatedCgroupSupervisor.RunResult, HardProcessContainmentReceipt) {
        try LinuxDelegatedCgroupSupervisor.runContained(
            config: config, launchPath: launchPath, argv: [], environment: ["PATH": "/usr/bin:/bin"],
            cwd: "/", timeoutSeconds: 30)
    }

    #if !os(Linux)
    func testFailsClosedOffLinux() {
        // Off Linux there is no delegated cgroup-v2 authority: the supervisor must refuse rather than
        // return a receipt. This is the exact forgery guard — an advisory macOS host cannot mint one.
        XCTAssertThrowsError(try run(config())) { error in
            guard case LinuxDelegatedCgroupSupervisor.SupervisorError.unavailable = error else {
                return XCTFail("expected .unavailable off Linux, got \(error)")
            }
        }
    }

    func testFailsClosedOffLinuxEvenWithWellFormedConfig() {
        // A perfectly valid-looking config still cannot conjure containment on a non-Linux host.
        let c = config(scopeID: "22222222-2222-4222-8222-222222222222", exec: String(repeating: "f", count: 64))
        XCTAssertThrowsError(try run(c, launchPath: "/usr/bin/env")) { error in
            guard case LinuxDelegatedCgroupSupervisor.SupervisorError.unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
    }
    #endif

    func testAvailabilityRuntimeIsNotSilentlyFlippedBySupervisor() {
        // Adding the supervisor source must NOT, on its own, flip the readiness gate. Activation is a
        // separate, reviewed step gated on the Linux AgentCore build. On macOS the gate stays closed.
        let availability = HardProcessContainmentRuntime.currentAvailability
        #if os(Linux)
        // The committed default remains the advisory bubblewrap path until the backend is wired.
        XCTAssertFalse(availability.available)
        #else
        XCTAssertFalse(availability.available)
        XCTAssertEqual(availability.platform, .macOS)
        #endif
    }
}
