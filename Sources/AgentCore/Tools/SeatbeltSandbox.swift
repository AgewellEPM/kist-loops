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
    /// Host authority directories whose bytes must be unreadable to the child. These are host-owned
    /// policy inputs, never model arguments; `wrap` canonicalizes and validates every entry before use.
    public let forbiddenReadPaths: [String]
    /// Mask the caller's real home directory. A private HOME environment is not a read boundary because
    /// untrusted code can still address the real home by absolute path.
    public let denyRealHomeReads: Bool
    /// Ordinary interactive tools historically receive shared temp write access. High-risk autonomous
    /// code can turn this off so a surviving child has no authority over future workspaces/private dirs.
    public let allowSharedTemporaryWrites: Bool
    /// Deny inspection/signalling of other processes. Fork/exec of descendants remains available.
    public let denyCrossProcessAccess: Bool
    /// Whether `run_command(background:true)` may detach a job from the bounded foreground call.
    public let allowBackgroundProcesses: Bool

    public init(enabled: Bool, denyNetwork: Bool = true, confineWrites: Bool = true,
                allowedLoopbackTCPPorts: Set<UInt16> = [],
                forbiddenReadPaths: [String] = [], denyRealHomeReads: Bool = false,
                allowSharedTemporaryWrites: Bool = true, denyCrossProcessAccess: Bool = false,
                allowBackgroundProcesses: Bool = true) {
        self.enabled = enabled
        self.denyNetwork = denyNetwork
        self.confineWrites = confineWrites
        self.allowedLoopbackTCPPorts = allowedLoopbackTCPPorts
        self.forbiddenReadPaths = forbiddenReadPaths
        self.denyRealHomeReads = denyRealHomeReads
        self.allowSharedTemporaryWrites = allowSharedTemporaryWrites
        self.denyCrossProcessAccess = denyCrossProcessAccess
        self.allowBackgroundProcesses = allowBackgroundProcesses
    }

    /// No OS sandbox (default). In-process gates still apply.
    public static let disabled = SandboxPolicy(enabled: false, denyNetwork: false, confineWrites: false)

    /// Kernel-enforced: deny egress + confine writes to the root.
    public static func confined(denyNetwork: Bool = true, confineWrites: Bool = true) -> SandboxPolicy {
        SandboxPolicy(enabled: true, denyNetwork: denyNetwork, confineWrites: confineWrites)
    }

    /// Fail-closed policy for autonomous, pre-commit source generation. It deliberately grants no
    /// shared-temp/background authority and masks both the real home and explicit host authority roots.
    public static func strictAutonomous(forbiddenReadPaths: [String]) -> SandboxPolicy {
        SandboxPolicy(enabled: true, denyNetwork: true, confineWrites: true,
                      forbiddenReadPaths: forbiddenReadPaths, denyRealHomeReads: true,
                      allowSharedTemporaryWrites: false, denyCrossProcessAccess: true,
                      allowBackgroundProcesses: false)
    }

    /// Preserve the caller's sandbox posture while granting one ephemeral, process-local proxy port.
    /// This is deliberately narrower than disabling network denial for browser subprocesses.
    public func allowingLoopbackTCPPort(_ port: UInt16) -> SandboxPolicy {
        var ports = allowedLoopbackTCPPorts
        ports.insert(port)
        return SandboxPolicy(enabled: enabled, denyNetwork: denyNetwork,
                             confineWrites: confineWrites,
                             allowedLoopbackTCPPorts: ports,
                             forbiddenReadPaths: forbiddenReadPaths,
                             denyRealHomeReads: denyRealHomeReads,
                             allowSharedTemporaryWrites: allowSharedTemporaryWrites,
                             denyCrossProcessAccess: denyCrossProcessAccess,
                             allowBackgroundProcesses: allowBackgroundProcesses)
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
        guard let deniedReads = validatedReadDenyPaths(root: canonicalRoot, policy: policy) else {
            return .unavailable(reason: "sandbox forbidden-read roots are invalid or overlap the project root")
        }
        let profile = seatbeltProfile(root: canonicalRoot, policy: policy,
                                      validatedReadDenyPaths: deniedReads)
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
    static func seatbeltProfile(root: String, policy: SandboxPolicy,
                                validatedReadDenyPaths: [String]? = nil) -> String {
        var lines = ["(version 1)", "(allow default)"]
        if policy.denyNetwork {
            lines.append("(deny network*)")
            for port in policy.allowedLoopbackTCPPorts.sorted() {
                lines.append("(allow network-outbound (remote ip \"localhost:\(port)\"))")
            }
        }
        if policy.denyCrossProcessAccess {
            lines.append("(deny process-info*)")
            lines.append("(deny signal)")
            lines.append("(allow signal (target self))")
            lines.append("(deny file-link)")
        }
        // Deny READS of well-known secret stores so a verifier running agent-authored test code cannot
        // exfiltrate credentials/keys (last-match-wins over `(allow default)`). Reads are otherwise left
        // open because the toolchain needs system libs/configs; full deny-by-default is the container/
        // microVM upgrade tier (documented — same-host Seatbelt is a defense-in-depth LAYER, not a
        // containment boundary). Skip any secret path that overlaps the confinement root (never deny the
        // worktree's own files).
        let requestedDenies = validatedReadDenyPaths
            ?? validatedReadDenyPathsForProfileOnly(root: root, policy: policy)
        for s in Array(Set(secretReadDenySubpaths() + requestedDenies)).sorted()
            where s != root && !root.hasPrefix(s + "/") && !s.hasPrefix(root + "/") {
            lines.append("(deny file-read* (subpath \(quote(s))))")
        }
        // A strict policy may mask a broad home/host parent. Re-allow only the exact autonomous
        // worktree after all broad denies; no sibling or future temp workspace is exposed.
        lines.append("(allow file-read* (literal \(quote(root))))")
        lines.append("(allow file-read* (subpath \(quote(root))))")
        if policy.confineWrites {
            lines.append("(deny file-write*)")
            for w in writableSubpaths(root: root, policy: policy) {
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
    static func writableSubpaths(root: String, policy: SandboxPolicy = .confined()) -> [String] {
        var paths = [root, "/dev/null"]
        if policy.allowSharedTemporaryWrites {
            paths.append("/private/tmp")
            if let tmp = ToolContext.canonicalize(NSTemporaryDirectory()) { paths.append(tmp) }
        }
        return paths
    }

    private static func validatedReadDenyPaths(root: String, policy: SandboxPolicy) -> [String]? {
        var raw = policy.forbiddenReadPaths
        if policy.denyRealHomeReads { raw.append(NSHomeDirectory()) }
        var out: [String] = []
        for path in raw {
            guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4_096,
                  !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let canonical = ToolContext.canonicalize(path), canonical != "/",
                  canonical != root, !root.hasPrefix(canonical + "/"),
                  !canonical.hasPrefix(root + "/") else { return nil }
            out.append(canonical)
        }
        return Array(Set(out)).sorted()
    }

    /// Pure profile tests use synthetic paths. Enforcement never calls this fallback: `wrap` supplies
    /// the fully canonicalized list above and refuses invalid/missing policy roots.
    private static func validatedReadDenyPathsForProfileOnly(
        root: String, policy: SandboxPolicy
    ) -> [String] {
        var raw = policy.forbiddenReadPaths
        if policy.denyRealHomeReads { raw.append(NSHomeDirectory()) }
        return Array(Set(raw.map { ToolContext.canonicalize($0) ?? $0 })).sorted().filter {
            $0 != "/" && $0 != root && !root.hasPrefix($0 + "/") && !$0.hasPrefix(root + "/")
        }
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
