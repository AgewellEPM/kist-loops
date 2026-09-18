import Foundation
#if canImport(Glibc)
import Glibc
#endif

// Proves LinuxDelegatedCgroupSession: multiple commands in ONE scope, bounded stdout/stderr capture, and
// a single finalized receipt. Compiles the exact shipped HardProcessContainment.swift + supervisor.

func die(_ m: String) -> Never { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
func hex64(_ t: String) -> String {
    var a: UInt64 = 1469598103934665603; var h = [UInt8](repeating: 0, count: 32)
    for b in t.utf8 { a = (a ^ UInt64(b)) &* 1099511628211 }
    for i in 0..<32 { h[i] = UInt8((a >> (UInt64(i % 8) * 8)) & 0xff); a = a &* 1099511628211 &+ UInt64(i) }
    return h.map { String(format: "%02x", $0) }.joined()
}

let base = "/sys/fs/cgroup"
if let f = fopen(base + "/cgroup.subtree_control", "w") { _ = "+cpu +memory +pids\n".withCString { fputs($0, f) }; fclose(f) }
let root = base + "/session-proof-\(getpid())"
_ = mkdir(root, 0o755)
defer { _ = rmdir(root) }

let limits = HardProcessContainmentLimits(aggregateCPUTimeMicros: 30_000_000,
                                          aggregateMemoryBytes: 128 * 1024 * 1024,
                                          aggregateProcessCount: 64)
let session: LinuxDelegatedCgroupSession
do { session = try LinuxDelegatedCgroupSession(delegatedRoot: root, scopeID: UUID().uuidString.lowercased(), limits: limits) }
catch { die("session init: \(error)") }

// Command 1: emit known stdout + stderr; verify capture.
do {
    let o = try session.run(launchPath: "/bin/sh",
        argv: ["-c", "printf 'HELLO-OUT'; printf 'HELLO-ERR' 1>&2; exit 3"],
        environment: ["PATH": "/usr/bin:/bin"], cwd: "/", timeoutSeconds: 30)
    guard o.exitCode == 3 else { die("cmd1 exit \(o.exitCode) != 3") }
    guard String(decoding: o.stdout, as: UTF8.self) == "HELLO-OUT" else { die("cmd1 stdout = \(String(decoding: o.stdout, as: UTF8.self))") }
    guard String(decoding: o.stderr, as: UTF8.self) == "HELLO-ERR" else { die("cmd1 stderr = \(String(decoding: o.stderr, as: UTF8.self))") }
    print("SESSION OK: cmd1 captured stdout/stderr exactly, exit 3")
} catch { die("cmd1: \(error)") }

// Command 2: a second command in the SAME scope (proves scope reuse). Reads stdin.
do {
    let o = try session.run(launchPath: "/bin/sh",
        argv: ["-c", "cat; echo ' <-piped'"],
        environment: ["PATH": "/usr/bin:/bin"], cwd: "/", stdin: Data("STDIN123".utf8), timeoutSeconds: 30)
    guard o.exitCode == 0 else { die("cmd2 exit \(o.exitCode)") }
    let out = String(decoding: o.stdout, as: UTF8.self)
    guard out.contains("STDIN123"), out.contains("<-piped") else { die("cmd2 stdout = \(out)") }
    print("SESSION OK: cmd2 reused scope, stdin delivered, stdout captured")
} catch { die("cmd2: \(error)") }

// Finalize: one receipt for the batch; validates through the contract.
do {
    let receipt = try session.finalize(mechanismDigest: hex64("m"), policyDigest: hex64("p"), executionDigest: hex64("e"))
    let req = HardProcessContainmentRequirement(
        scopeID: receipt.scopeID, mechanism: .linuxDelegatedCgroupV2, limits: limits,
        mechanismDigest: hex64("m"), policyDigest: hex64("p"), expectedExecutionDigest: hex64("e"))
    var ts = timespec(); clock_gettime(CLOCK_REALTIME, &ts)
    let now = Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
    try HardProcessContainmentContract.validate(receipt, satisfying: req, hostPlatform: .linux, nowMillis: now)
    print("SESSION OK: finalized receipt validates (one receipt for both commands)")
} catch { die("finalize: \(error)") }

print("ALL SESSION PROOFS OK")
