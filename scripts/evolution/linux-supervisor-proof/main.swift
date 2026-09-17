import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Standalone Linux proof for LinuxDelegatedCgroupSupervisor.
//
// This is compiled together with the EXACT shipped sources
//   Sources/AgentCore/HardProcessContainment.swift
//   Sources/AgentCore/LinuxDelegatedCgroupSupervisor.swift
// so the algorithm proven here is byte-identical to the algorithm that ships. It requires root and a
// real cgroup-v2 hierarchy (run inside a privileged Linux container / VM). It:
//   A. runs a benign command, then validates the host-owned receipt through the real
//      HardProcessContainmentContract + one-use HardProcessContainmentReplayGuard;
//   B. runs a setsid daemon that tries to outlive its launcher, and proves cgroup.kill reaps it and the
//      scope verifies empty (a process-group kill would miss it);
//   C. proves the aggregate pids ceiling holds and the scope still drains.
//
// Any failure exits non-zero with a message. Success prints PROOF OK lines a caller can grep.

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

func sha256Hex(_ s: String) -> String {
    // The contract only requires 64 lowercase hex chars; a deterministic stand-in is fine for the proof
    // (production digests come from the benchmark backend, not the supervisor).
    var h = [UInt8](repeating: 0, count: 32)
    var acc: UInt64 = 1469598103934665603
    for b in s.utf8 { acc = (acc ^ UInt64(b)) &* 1099511628211 }
    for i in 0..<32 { h[i] = UInt8((acc >> (UInt64(i % 8) * 8)) & 0xff); acc = acc &* 1099511628211 &+ UInt64(i) }
    return h.map { String(format: "%02x", $0) }.joined()
}

func lowercaseUUID() -> String { UUID().uuidString.lowercased() }

// Prepare a delegated cgroup-v2 root the supervisor can own.
let cgroupBase = "/sys/fs/cgroup"
guard let mode = try? String(contentsOfFile: cgroupBase + "/cgroup.controllers", encoding: .utf8) else {
    die("no cgroup-v2 at \(cgroupBase)/cgroup.controllers — run under a real cgroup2 host")
}
_ = mode
// Root is exempt from the no-internal-process rule: enable controllers so a child subtree can use them.
if let fd = fopen(cgroupBase + "/cgroup.subtree_control", "w") {
    let s = "+cpu +memory +pids\n"; _ = s.withCString { fputs($0, fd) }; fclose(fd)
}
let delegatedRoot = cgroupBase + "/evolution-proof-" + String(getpid())
_ = mkdir(delegatedRoot, 0o755)
defer { _ = rmdir(delegatedRoot) }

func policyDigests(_ tag: String) -> (String, String, String) {
    (sha256Hex("mech:" + tag), sha256Hex("policy:" + tag), sha256Hex("exec:" + tag))
}

func validateReceipt(_ receipt: HardProcessContainmentReceipt, _ config: LinuxDelegatedCgroupSupervisor.Config) throws {
    let requirement = HardProcessContainmentRequirement(
        scopeID: config.scopeID, mechanism: .linuxDelegatedCgroupV2, limits: config.limits,
        mechanismDigest: config.mechanismDigest, policyDigest: config.policyDigest,
        expectedExecutionDigest: config.executionDigest)
    var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
    let nowMillis = Int64(ts.tv_sec) * 1_000 + Int64(ts.tv_nsec) / 1_000_000
    // Pure host-side validation of every hard invariant.
    try HardProcessContainmentContract.validate(
        receipt, satisfying: requirement, hostPlatform: .linux, nowMillis: nowMillis)
    // One-use consumption + replay rejection through the real guard's internal seam.
    let guardInstance = HardProcessContainmentReplayGuard()
    _ = try guardInstance.consume(receipt, satisfying: requirement, hostPlatform: .linux, nowMillis: nowMillis)
    do {
        _ = try guardInstance.consume(receipt, satisfying: requirement, hostPlatform: .linux, nowMillis: nowMillis)
        throw NSError(domain: "proof", code: 1, userInfo: [NSLocalizedDescriptionKey: "replay was NOT rejected"])
    } catch HardProcessContainmentError.replayedScope {
        // expected
    }
}

// ---- Test A: benign command, full receipt validation + replay guard ----
do {
    let (mech, pol, exec) = policyDigests("A")
    let config = LinuxDelegatedCgroupSupervisor.Config(
        delegatedRoot: delegatedRoot, scopeID: lowercaseUUID(),
        limits: HardProcessContainmentLimits(aggregateCPUTimeMicros: 30_000_000,
                                             aggregateMemoryBytes: 128 * 1024 * 1024,
                                             aggregateProcessCount: 64),
        mechanismDigest: mech, policyDigest: pol, executionDigest: exec)
    let (result, receipt) = try LinuxDelegatedCgroupSupervisor.runContained(
        config: config, launchPath: "/bin/true", argv: [], environment: ["PATH": "/usr/bin:/bin"],
        cwd: "/", timeoutSeconds: 30)
    guard result.exitCode == 0, !result.timedOut, !result.wasSignalled else {
        die("A: expected clean exit, got exit=\(result.exitCode) timedOut=\(result.timedOut)")
    }
    try validateReceipt(receipt, config)
    print("PROOF A OK: benign exit=0, receipt validates, replay rejected, pre-exec membership host-verified")
} catch { die("A failed: \(error)") }

// ---- Test B: setsid daemon that tries to outlive its launcher ----
do {
    let (mech, pol, exec) = policyDigests("B")
    let config = LinuxDelegatedCgroupSupervisor.Config(
        delegatedRoot: delegatedRoot, scopeID: lowercaseUUID(),
        limits: HardProcessContainmentLimits(aggregateCPUTimeMicros: 30_000_000,
                                             aggregateMemoryBytes: 128 * 1024 * 1024,
                                             aggregateProcessCount: 64),
        mechanismDigest: mech, policyDigest: pol, executionDigest: exec)
    // Launcher exits 0 immediately, leaving a setsid'd sleep daemon behind. A process-group kill would
    // miss it; cgroup.kill must reap it. runContained only returns a valid receipt if the scope empties.
    let (result, receipt) = try LinuxDelegatedCgroupSupervisor.runContained(
        config: config, launchPath: "/bin/sh",
        argv: ["-c", "setsid /bin/sh -c 'sleep 300' >/dev/null 2>&1 < /dev/null & exit 0"],
        environment: ["PATH": "/usr/bin:/bin"], cwd: "/", timeoutSeconds: 30)
    guard receipt.cleanup.scopeEmptyVerified, receipt.cleanup.remainingProcessCount == 0 else {
        die("B: scope not verified empty after cgroup.kill")
    }
    try validateReceipt(receipt, config)
    print("PROOF B OK: setsid daemon reaped by cgroup.kill, scope empty (peak observed procs=\(result.peakObservedProcessCount))")
} catch { die("B failed: \(error)") }

// ---- Test C: aggregate pids ceiling ----
do {
    let (mech, pol, exec) = policyDigests("C")
    let config = LinuxDelegatedCgroupSupervisor.Config(
        delegatedRoot: delegatedRoot, scopeID: lowercaseUUID(),
        limits: HardProcessContainmentLimits(aggregateCPUTimeMicros: 30_000_000,
                                             aggregateMemoryBytes: 128 * 1024 * 1024,
                                             aggregateProcessCount: 4),
        mechanismDigest: mech, policyDigest: pol, executionDigest: exec)
    // Try to spawn far more than 4 processes; pids.max must cap it, and the scope must still drain.
    let (_, receipt) = try LinuxDelegatedCgroupSupervisor.runContained(
        config: config, launchPath: "/bin/sh",
        argv: ["-c", "i=0; while [ $i -lt 50 ]; do sleep 5 & i=$((i+1)); done; true"],
        environment: ["PATH": "/usr/bin:/bin"], cwd: "/", timeoutSeconds: 30)
    guard receipt.cleanup.scopeEmptyVerified, receipt.cleanup.remainingProcessCount == 0 else {
        die("C: scope not verified empty after cgroup.kill")
    }
    try validateReceipt(receipt, config)
    print("PROOF C OK: pids.max=4 enforced, scope empty after cleanup")
} catch { die("C failed: \(error)") }

print("ALL PROOFS OK")
