import Foundation

/// Opt-in OS-level sandbox policy for `run_command`. When enabled, the resolved command is
/// wrapped so the OS kernel (not just our in-process gates) enforces: network egress
/// default-deny and filesystem-write confinement to the project root. This is the tier that
/// closes the "no kernel sandbox / no egress boundary" gap; it composes with the in-process
/// ShellPolicy + ConfinedRoot (defense in depth) and with ProcessGroupRunner (the sandbox
/// launcher is just another member of the spawned process group).
public struct SandboxPolicy: Sendable {
    public let enabled: Bool
    /// Deny all network egress from the spawned command (and its children).
    public let denyNetwork: Bool
    /// Deny filesystem writes outside the project root (+ temp/devices).
    public let confineWrites: Bool
    /// Exact loopback TCP proxy ports a sandboxed child may reach while all other egress stays denied.
    public let allowedLoopbackTCPPorts: Set<UInt16>

    public init(enabled: Bool, denyNetwork: Bool = true, confineWrites: Bool = true,
                allowedLoopbackTCPPorts: Set<UInt16> = []) {
        self.enabled = enabled
        self.denyNetwork = denyNetwork
        self.confineWrites = confineWrites
        self.allowedLoopbackTCPPorts = allowedLoopbackTCPPorts
    }

    /// No OS sandbox (default). In-process gates still apply.
    public static let disabled = SandboxPolicy(enabled: false, denyNetwork: false, confineWrites: false)

    /// Kernel-enforced: deny egress + confine writes to the root.
    public static func confined(denyNetwork: Bool = true, confineWrites: Bool = true) -> SandboxPolicy {
        SandboxPolicy(enabled: true, denyNetwork: denyNetwork, confineWrites: confineWrites)
    }

    /// Preserve the caller's sandbox posture while granting one ephemeral, process-local proxy port.
    /// This is deliberately narrower than disabling network denial for browser subprocesses.
    public func allowingLoopbackTCPPort(_ port: UInt16) -> SandboxPolicy {
        var ports = allowedLoopbackTCPPorts
        ports.insert(port)
        return SandboxPolicy(enabled: enabled, denyNetwork: denyNetwork,
                             confineWrites: confineWrites,
                             allowedLoopbackTCPPorts: ports)
    }
}

/// Wraps a resolved command in the macOS Seatbelt sandbox (`sandbox-exec`). Seatbelt is the
/// same mechanism Claude Code uses for local OS-level confinement. On Linux, `wrap` delegates to
/// `BubblewrapSandbox` (bubblewrap / unprivileged user namespaces) for the equivalent policy; if
/// bubblewrap isn't installed there, it returns `.unavailable` so the caller FAILS CLOSED (never
/// silently runs unsandboxed).
enum SeatbeltSandbox {
    enum Wrap: Equatable {
        case passthrough                          // sandbox disabled → run the command as-is
        case wrapped(path: String, args: [String])
        case unavailable(reason: String)          // requested but unsupported → caller must refuse
    }

    /// `root` is the confinement root (will be canonicalized — Seatbelt matches realpaths). `cwd` is the
    /// working directory the command runs in (used by the Linux bubblewrap tier for `--chdir`; Seatbelt
    /// inherits the outer process cwd so it ignores this).
    static func wrap(launchPath: String, args: [String], root: String, policy: SandboxPolicy,
                     cwd: String? = nil) -> Wrap {
        guard policy.enabled else { return .passthrough }
        #if os(macOS)
        guard let canonicalRoot = ToolContext.canonicalize(root) else {
            return .unavailable(reason: "cannot canonicalize sandbox root: \(root)")
        }
        let profile = seatbeltProfile(root: canonicalRoot, policy: policy)
        // sandbox-exec -p <profile> <launchPath> <args...>
        return .wrapped(path: "/usr/bin/sandbox-exec", args: ["-p", profile, launchPath] + args)
        #else
        return BubblewrapSandbox.wrap(launchPath: launchPath, args: args, root: root,
                                      cwd: cwd ?? root, policy: policy)
        #endif
    }

    /// Build a Seatbelt profile (TinyScheme). Reads are allowed (the command needs system
    /// libs/configs); writes are denied except under the root + temp + devices; network is
    /// denied. A `confineWrites`/`denyNetwork` flag can relax either half independently.
    static func seatbeltProfile(root: String, policy: SandboxPolicy) -> String {
        var lines = ["(version 1)", "(allow default)"]
        if policy.denyNetwork {
            lines.append("(deny network*)")
            for port in policy.allowedLoopbackTCPPorts.sorted() {
                lines.append("(allow network-outbound (remote ip \"localhost:\(port)\"))")
            }
        }
        // Deny READS of well-known secret stores so a verifier running agent-authored test code cannot
        // exfiltrate credentials/keys (last-match-wins over `(allow default)`). Reads are otherwise left
        // open because the toolchain needs system libs/configs; full deny-by-default is the container/
        // microVM upgrade tier (documented — same-host Seatbelt is a defense-in-depth LAYER, not a
        // containment boundary). Skip any secret path that overlaps the confinement root (never deny the
        // worktree's own files).
        for s in secretReadDenySubpaths() where s != root && !root.hasPrefix(s + "/") && !s.hasPrefix(root + "/") {
            lines.append("(deny file-read* (subpath \(quote(s))))")
        }
        if policy.confineWrites {
            lines.append("(deny file-write*)")
            for w in writableSubpaths(root: root) {
                lines.append("(allow file-write* (subpath \(quote(w))))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Write-allowed roots under write confinement: the project root, the classic shared
    /// `/private/tmp`, this process's own `$TMPDIR` (the canonical NSTemporaryDirectory —
    /// scratch space, narrowed from the whole `/private/var/folders` tree so other users'
    /// temp containers stay read-only), and `/dev/null` only (narrowed from all of `/dev`,
    /// which would expose every user-writable device node / tty / `/dev/fd` alias).
    static func writableSubpaths(root: String) -> [String] {
        var paths = [root, "/private/tmp", "/dev/null"]
        if let tmp = ToolContext.canonicalize(NSTemporaryDirectory()) { paths.append(tmp) }
        return paths
    }

    /// Well-known secret stores a sandboxed verifier is denied READ access to (defense-in-depth exfil
    /// block). Canonicalized when present (Seatbelt matches realpaths); the literal is used otherwise so
    /// a not-yet-created store is still covered. Covers per-user creds/keys, this app's own key + operator
    /// dirs (`~/.mythos`, `~/.kist`), and the login/system keychains.
    static func secretReadDenySubpaths() -> [String] {
        let home = NSHomeDirectory()
        let rels = [".ssh", ".aws", ".gnupg", ".config/gcloud", ".mythos", ".kist",
                    ".netrc", ".npmrc", "Library/Keychains"]
        var out: [String] = ["/Library/Keychains"]
        for r in rels {
            let p = (home as NSString).appendingPathComponent(r)
            out.append(ToolContext.canonicalize(p) ?? p)
        }
        return out
    }

    /// Quote a path as a TinyScheme string literal, escaping backslash and double-quote so a
    /// root path containing a `"` cannot break out of the profile (profile injection).
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
