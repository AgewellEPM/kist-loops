import Foundation

/// Linux OS-level sandbox for `run_command` — the counterpart to macOS `SeatbeltSandbox`. Uses
/// bubblewrap (`bwrap`, unprivileged user namespaces) to enforce the SAME policy the Seatbelt profile
/// does:
///   • deny network egress            → `--unshare-net`
///   • confine filesystem writes to the project root → mount `/` read-only, then bind the project root
///     (and a fresh tmpfs `/tmp`) writable; everything else stays read-only.
///
/// Fail-closed by construction: if `bwrap` isn't installed we return `.unavailable` and the caller
/// (`RunCommandTool`) refuses to run — a sandbox that was REQUESTED is never silently downgraded.
///
/// The argv construction (`buildArgs`) is pure and unit-tested on every platform; only `wrap` touches
/// the filesystem (locating `bwrap`, canonicalizing paths).
enum BubblewrapSandbox {
    /// Absolute install locations checked, in order. PATH is intentionally not consulted — the launcher
    /// must be a predictable absolute path (a PATH-resolved `bwrap` could be a planted binary).
    static let candidatePaths = ["/usr/bin/bwrap", "/usr/local/bin/bwrap", "/bin/bwrap"]

    static func bwrapPath(fileManager: FileManager = .default) -> String? {
        candidatePaths.first { fileManager.isExecutableFile(atPath: $0) }
    }

    static func wrap(launchPath: String, args: [String], root: String, cwd: String,
                     policy: SandboxPolicy) -> SeatbeltSandbox.Wrap {
        guard policy.enabled else { return .passthrough }
        guard !policy.denyNetwork || policy.allowedLoopbackTCPPorts.isEmpty else {
            return .unavailable(reason: "Linux bubblewrap cannot expose an exact host loopback proxy port inside an unshared network namespace; refusing to weaken network confinement")
        }
        guard let bwrap = bwrapPath() else {
            return .unavailable(reason: "OS sandbox requires bubblewrap (bwrap); it is not installed — refusing to run unsandboxed")
        }
        guard let canonicalRoot = ToolContext.canonicalize(root) else {
            return .unavailable(reason: "cannot canonicalize sandbox root: \(root)")
        }
        let canonicalCwd = ToolContext.canonicalize(cwd) ?? canonicalRoot
        return .wrapped(path: bwrap,
                        args: buildArgs(root: canonicalRoot, cwd: canonicalCwd, policy: policy,
                                        launchPath: launchPath, args: args))
    }

    /// Pure bubblewrap argv for the given policy. Order matters: the read-only bind of `/` comes first,
    /// then the essential virtual filesystems and the writable root bind OVERRIDE it for their subtrees
    /// (bwrap applies binds left-to-right, later wins).
    static func buildArgs(root: String, cwd: String, policy: SandboxPolicy,
                          launchPath: String, args: [String]) -> [String] {
        // Namespace isolation (Codex-hardened):
        //   --unshare-pid : a fresh PID namespace so the sandbox can't see other processes' /proc/<pid>/
        //                   environ (which would leak API keys that never passed through SecretMasker).
        //   --new-session : detach the controlling terminal → no TIOCSTI keystroke injection into the tty.
        //   --die-with-parent : the sandboxed process dies if kist dies (no orphan).
        var a: [String] = ["--die-with-parent", "--unshare-pid", "--new-session"]
        if policy.confineWrites {
            a += ["--ro-bind", "/", "/"]                // whole host read-only …
        } else {
            a += ["--bind", "/", "/"]                   // … or fully writable (network may still be denied)
        }
        // Minimal dev + a FRESH pid-namespaced /proc, plus tmpfs over the runtime/socket dirs. `--tmpfs
        // /run` masks host pathname sockets (e.g. /var/run/docker.sock → /run/docker.sock) that
        // --unshare-net does NOT block — otherwise a confined command could talk to the Docker socket
        // and escape by launching a container that bind-mounts /.
        a += ["--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--tmpfs", "/run"]
        if policy.confineWrites {
            a += ["--bind", root, root]                 // make ONLY the project root writable (overrides ro-bind)
        }
        if policy.denyNetwork {
            a += ["--unshare-net"]                       // no network namespace → IP egress + abstract sockets denied
        }
        a += ["--chdir", cwd, "--", launchPath]
        a += args
        return a
    }
}
