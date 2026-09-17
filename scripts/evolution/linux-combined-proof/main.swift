import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Standalone Linux keystone proof: one command run under BOTH containment layers the evolution backend
// composes — the delegated cgroup-v2 supervisor (LinuxDelegatedCgroupSupervisor) executing bubblewrap,
// which installs the seccomp escape-deny filter (EvolutionSeccompFilter) before exec'ing the candidate.
//
// Compiled with the EXACT shipped sources: HardProcessContainment.swift, LinuxDelegatedCgroupSupervisor.swift,
// EvolutionSeccompFilter.swift (+ a BuilderEvidenceDigest shim). Requires a real cgroup2 host, bubblewrap,
// and enough privilege to create a delegated subtree.
//
// It proves, in one run:
//   - seccomp layer: the candidate's hardlink attempt is DENIED (exit code carries the verdict),
//   - cgroup layer: a setsid daemon the candidate leaves behind is reaped by cgroup.kill (scope empties),
//   - the host-owned receipt validates through the real HardProcessContainmentContract.

enum BuilderEvidenceDigest {
    static func sha256(_ v: String) -> String { String(repeating: "0", count: 64) }
    static func sha256Bytes(_ b: [UInt8]) -> String { String(repeating: "0", count: 64) }
}

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }

func hex64(_ tag: String) -> String {
    var h = [UInt8](repeating: 0, count: 32); var a: UInt64 = 1469598103934665603
    for b in tag.utf8 { a = (a ^ UInt64(b)) &* 1099511628211 }
    for i in 0..<32 { h[i] = UInt8((a >> (UInt64(i % 8) * 8)) & 0xff); a = a &* 1099511628211 &+ UInt64(i) }
    return h.map { String(format: "%02x", $0) }.joined()
}

// Prepare a delegated cgroup-v2 root.
let base = "/sys/fs/cgroup"
guard (try? String(contentsOfFile: base + "/cgroup.controllers", encoding: .utf8)) != nil else {
    die("no cgroup-v2 at \(base)")
}
if let fd = fopen(base + "/cgroup.subtree_control", "w") {
    _ = "+cpu +memory +pids\n".withCString { fputs($0, fd) }; fclose(fd)
}
let delegatedRoot = base + "/combined-proof-\(getpid())"
_ = mkdir(delegatedRoot, 0o755)
defer { _ = rmdir(delegatedRoot) }

// Emit the real seccomp filter and open it (NOT close-on-exec) so bubblewrap inherits it across the
// supervisor's fork+exec and installs it via --seccomp <fd>.
let filterPath = "/tmp/combined-filter-\(getpid()).bpf"
FileManager.default.createFile(atPath: filterPath, contents: Data(EvolutionSeccompFilter.programBytes()))
let filterFD = open(filterPath, O_RDONLY)   // O_CLOEXEC deliberately omitted
guard filterFD >= 0 else { die("cannot open filter file") }

// Writable scratch the candidate can touch.
let work = "/tmp/combined-work-\(getpid())"
_ = mkdir(work, 0o755)

let config = LinuxDelegatedCgroupSupervisor.Config(
    delegatedRoot: delegatedRoot,
    scopeID: UUID().uuidString.lowercased(),
    limits: HardProcessContainmentLimits(aggregateCPUTimeMicros: 30_000_000,
                                         aggregateMemoryBytes: 256 * 1024 * 1024,
                                         aggregateProcessCount: 64),
    mechanismDigest: hex64("mech"), policyDigest: hex64("policy"), executionDigest: hex64("exec"))

// Candidate script: leave a setsid daemon behind (cgroup must reap it), then attempt a hardlink (seccomp
// must deny it) and encode the verdict in the exit code: 7 = link blocked (good), 42 = link succeeded (bad).
let script = """
setsid sleep 300 >/dev/null 2>&1 </dev/null &
touch \(work)/a
if ln \(work)/a \(work)/b 2>/dev/null; then exit 42; else exit 7; fi
"""
let bwrapArgs = [
    "--unshare-all", "--ro-bind", "/usr", "/usr", "--ro-bind", "/bin", "/bin",
    "--ro-bind", "/lib", "/lib", "--dev", "/dev", "--bind", work, work,
    "--seccomp", String(filterFD), "--", "/bin/sh", "-c", script,
]

let (result, receipt): (LinuxDelegatedCgroupSupervisor.RunResult, HardProcessContainmentReceipt)
do {
    (result, receipt) = try LinuxDelegatedCgroupSupervisor.runContained(
        config: config, launchPath: "/usr/bin/bwrap", argv: bwrapArgs,
        environment: ["PATH": "/usr/bin:/bin"], cwd: "/", timeoutSeconds: 30)
} catch { die("supervisor.runContained threw: \(error)") }

// seccomp layer: candidate exit code must be 7 (hardlink denied), never 42.
guard result.exitCode == 7 else {
    die("SECCOMP under supervisor FAILED: candidate exit \(result.exitCode) (42=hardlink succeeded=escape!)")
}
print("COMBINED OK (seccomp): candidate hardlink DENIED under bwrap+supervisor (exit 7)")

// cgroup layer: the setsid daemon must have been reaped; scope verified empty.
guard receipt.cleanup.scopeEmptyVerified, receipt.cleanup.remainingProcessCount == 0 else {
    die("CGROUP under supervisor FAILED: scope not empty after cgroup.kill")
}
print("COMBINED OK (cgroup): setsid daemon reaped by cgroup.kill, scope empty (peak procs \(result.peakObservedProcessCount))")

// receipt validates through the real contract.
let requirement = HardProcessContainmentRequirement(
    scopeID: config.scopeID, mechanism: .linuxDelegatedCgroupV2, limits: config.limits,
    mechanismDigest: config.mechanismDigest, policyDigest: config.policyDigest,
    expectedExecutionDigest: config.executionDigest)
var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
let now = Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
do {
    try HardProcessContainmentContract.validate(receipt, satisfying: requirement, hostPlatform: .linux, nowMillis: now)
} catch { die("receipt failed contract validation: \(error)") }
print("COMBINED OK (receipt): host-owned receipt validates through HardProcessContainmentContract")

close(filterFD)
try? FileManager.default.removeItem(atPath: filterPath)
print("ALL COMBINED PROOFS OK")
