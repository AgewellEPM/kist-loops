import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Tool value types
//
// Cross-platform, Foundation-only tool layer for AgentCore. Mirrors the GUI app's
// `AgentTool`/`ToolResult`/`ToolParameter` shape so the GUI can later adopt these
// without churn, but with two deliberate upgrades the GUI version lacks:
//   1. Execution is parameterized by an injectable `ToolContext` (project root +
//      shell policy) instead of a bare `projectPath: String` + singleton registry.
//   2. All filesystem access is CONFINED to the project root and symlink-safe — the
//      GUI tools happily read/write absolute paths anywhere, which is unacceptable
//      once Kist runs shell-on-by-default for real users.

/// Result of executing a tool. Sendable so it can cross actor/task boundaries.
public struct ToolResult: Sendable, Equatable {
    public let success: Bool
    public let output: String
    public let error: String?
    public let metadata: [String: String]
    /// Host-only proof handle. Publicly readable by orchestration code, but public callers cannot
    /// populate it and it is never serialized into model-visible metadata/output.
    public private(set) var trustedCommandReference: BuilderTrustedCommandReference?
    /// One-shot host authority proving this exact successful command matched a frozen Builder
    /// verification command. It is deliberately internal and never enters model-visible metadata.
    var trustedBuilderVerification: BuilderVerificationCommandAuthorityReceipt?

    public init(success: Bool, output: String, error: String? = nil, metadata: [String: String] = [:]) {
        self.success = success
        self.output = output
        self.error = error
        self.metadata = metadata
        self.trustedCommandReference = nil
        self.trustedBuilderVerification = nil
    }

    init(success: Bool, output: String, error: String? = nil,
         metadata: [String: String] = [:],
         trustedCommandReference: BuilderTrustedCommandReference?,
         trustedBuilderVerification: BuilderVerificationCommandAuthorityReceipt? = nil) {
        self.success = success; self.output = output; self.error = error
        self.metadata = metadata
        self.trustedCommandReference = trustedCommandReference
        self.trustedBuilderVerification = trustedBuilderVerification
    }

    /// Convenience for the common failure shape.
    public static func failure(_ message: String) -> ToolResult {
        ToolResult(success: false, output: "", error: message)
    }
}

/// Declarative parameter description used to build the tool JSON schema sent to models.
public struct ToolParameter: Sendable, Codable, Equatable {
    public let name: String
    public let type: String
    public let description: String
    public let required: Bool

    public init(name: String, type: String, description: String, required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// Errors thrown by tools and the execution context. `CustomStringConvertible` so the
/// message round-trips cleanly into `ToolResult.error`.
public enum ToolError: Error, LocalizedError, Sendable, CustomStringConvertible, Equatable {
    case configuration(String)
    case missingParameter(String)
    case invalidParameter(String)
    case permissionDenied(String)
    case pathEscape(path: String, root: String)
    case notFound(String)
    case shellDenied(String)
    case execution(String)

    public var description: String {
        switch self {
        case .configuration(let m): return "configuration error: \(m)"
        case .missingParameter(let p): return "missing required parameter: \(p)"
        case .invalidParameter(let m): return "invalid tool parameter: \(m)"
        case .permissionDenied(let m): return "permission denied: \(m)"
        case .pathEscape(let path, let root): return "path '\(path)' escapes the project root (\(root)) — refused"
        case .notFound(let p): return "not found: \(p)"
        case .shellDenied(let m): return "shell command denied: \(m)"
        case .execution(let m): return "execution failed: \(m)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Shell policy
//
// Kist runs shell ON BY DEFAULT (Luke's explicit choice), so the guardrails live in
// the type system, not in good intentions. A tool that wants to spawn a process MUST
// consult the policy: it is `enabled`, the command is not on the `deny` list, it is on
// the `allow` list (when one is set), and — unless `autoApprove` — the async
// `approval` handler says yes. Default is `.denied`: a context built without an
// explicit policy can run NO shell at all.

public struct ShellPolicy: Sendable {
    /// Master switch. When false, every shell tool refuses regardless of other fields.
    public let enabled: Bool
    /// Skip the interactive `approval` gate (e.g. a `--yolo`/headless batch run).
    public let autoApprove: Bool
    /// If non-empty, ONLY commands whose argv[0] basename is in this set may run.
    public let allow: Set<String>
    /// Substrings that hard-deny a command line even when otherwise allowed.
    public let deny: [String]
    /// Interactive per-command gate (returns true to permit). Ignored when `autoApprove`.
    public let approval: (@Sendable (String) async -> Bool)?
    /// The run is confined by the OS (Seatbelt) sandbox. RAW shell strings (pipes/redirects) can then
    /// auto-approve WITHOUT an interactive handler: the advisory deny-list is no longer the boundary —
    /// the KERNEL is (writes confined to the project root, network denied), and RunCommandTool
    /// fails CLOSED if a requested sandbox is unavailable. Un-sandboxed raw shell still needs a human.
    public let sandboxed: Bool

    public init(
        enabled: Bool,
        autoApprove: Bool = false,
        allow: Set<String> = [],
        deny: [String] = ShellPolicy.defaultDeny,
        approval: (@Sendable (String) async -> Bool)? = nil,
        sandboxed: Bool = false
    ) {
        self.enabled = enabled
        self.autoApprove = autoApprove
        self.allow = allow
        self.deny = deny
        self.approval = approval
        self.sandboxed = sandboxed
    }

    /// Shell completely off. The safe default for any context that doesn't opt in.
    public static let denied = ShellPolicy(enabled: false, deny: [])

    /// Conservative deny-list: destructive / exfiltration-prone shapes. Substring match
    /// on the full command line. Not a complete sandbox — defense in depth alongside
    /// path confinement and (in interactive mode) the approval gate.
    /// Catastrophic/irreversible shell patterns denied EVERYWHERE, armed or not.
    public static let baseDeny: [String] = [
        "rm -rf /", "rm -rf ~", ":(){", "mkfs", "dd if=", "> /dev/sd",
        "/etc/shadow", "/etc/passwd", "shutdown", "reboot",
        "curl http", "curl https", "wget http", "wget https",   // block silent network exfil; allow the agent's own HTTP tools
    ]

    /// The DEFAULT deny list = baseDeny + host-control. Host-control is denied BY DEFAULT at EVERY ShellPolicy
    /// construction site (main run, evolve, fleet workers, and any future site) — the ONLY code that may run
    /// host-control is the top-level armed path, which opts out by passing `deny: ShellPolicy.baseDeny`.
    /// Deny-by-default is the safe direction (Codex multi-site catch 2026-07-03: per-site opt-IN missed sites).
    public static let defaultDeny: [String] = baseDeny + hostControlDeny

    /// NAMED host-control / UI-automation / screen-capture binaries + URL schemes. Appended to `deny` ONLY
    /// when computer-use is NOT armed (--enable-computer-use), making the DIRECT shell route to desktop
    /// automation a HARD refusal (via binaryRefusalReason — un-bypassable against token tricks, and it also
    /// closes the nested-kist path since nested forces enableComputerUse=false). Council-mandated 2026-07-03.
    ///
    /// PARTIAL BY DESIGN: this catches direct invocation (`osascript`, `/usr/bin/osascript`, `env osascript`,
    /// `sh -c 'osascript …'`). It does NOT catch host-control reached through a DESCENDANT or in-language API
    /// (`python script.py` that calls CGEventPost, a compiled binary, `npm test`). Interpreters are
    /// deliberately NOT denied here (a coding agent needs python/node/ruby). The COMPLETE hard gate is
    /// OS-level capability denial (TCC/Accessibility/AppleEvents) for unarmed runs — see
    /// docs/kist/HOSTCONTROL_HARD_DENY_PLAN.md (layer 2). In practice the macOS TCC grant is the backstop for
    /// in-language injection: CGEventPost only works if the user already granted kist Accessibility.
    public static let hostControlDeny: [String] = [
        "osascript", "osacompile", "cliclick", "screencapture", "screencapturekit",
        "automator", "shortcuts", "system events",
        "open -a", "open shortcuts:", "open applescript:", "open x-apple",
        "ffmpeg -f avfoundation", "imagesnap", "isightcapture",
        "hidutil", "cgsession", "launchctl", "defaults write", "pbpaste", "pbcopy",
    ]

    /// Decide whether `command` may run. Pure except for the optional async approval.
    /// Returns nil if permitted, or a reason string if refused.
    ///
    /// NOTE: this matches the deny/allow rules against raw text, which is only
    /// reliable when the caller does NOT then hand that text to a shell. The
    /// STRUCTURED path (`binaryRefusalReason`) is the un-bypassable gate; raw shell
    /// strings must use `shellStringRefusalReason` (mandatory approval) instead.
    public func refusalReason(for command: String) async -> String? {
        guard enabled else { return "shell is disabled in this context" }
        let lower = command.lowercased()
        for bad in deny where lower.contains(bad.lowercased()) {
            return "matches deny-list entry '\(bad)'"
        }
        if !allow.isEmpty {
            let first = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
            let base = (first as NSString).lastPathComponent
            if !allow.contains(base) {
                return "'\(base)' is not on the allow-list"
            }
        }
        if !autoApprove, let approval = approval {
            let ok = await approval(command)
            if !ok { return "denied at the approval prompt" }
        }
        return nil
    }

    /// Gate for STRUCTURED execution (executable + args, spawned directly with NO
    /// shell). Un-bypassable against shell-token tricks: there's no shell to reinterpret
    /// tokens, so `rm${IFS}-rf` / `/tmp/git` spoofs don't apply. The allow-list matches
    /// the RESOLVED binary basename; the deny-list and approval evaluate the FULL argv
    /// line (`resolvedPath + args`) so argument-bearing deny entries (e.g. `curl https`,
    /// `dd if=`) actually fire — matching the binary path alone would let
    /// `curl https://exfil` through. Returns nil if permitted, else a reason.
    public func binaryRefusalReason(resolvedPath: String, args: [String]) async -> String? {
        guard enabled else { return "shell is disabled in this context" }
        let fullLine = ([resolvedPath] + args).joined(separator: " ")
        let lower = fullLine.lowercased()
        for bad in deny where lower.contains(bad.lowercased()) {
            return "command '\(fullLine)' matches deny-list entry '\(bad)'"
        }
        if !allow.isEmpty {
            let base = (resolvedPath as NSString).lastPathComponent
            if !allow.contains(base) { return "'\(base)' is not on the allow-list" }
        }
        if !autoApprove, let approval = approval {
            let ok = await approval(fullLine)
            if !ok { return "denied at the approval prompt" }
        }
        return nil
    }

    /// Gate for RAW SHELL STRINGS (`/bin/sh -c <command>`). Because the deny-list is
    /// only ADVISORY against arbitrary shell text (token-splitting can dodge it), a
    /// raw shell command can NEVER be auto-approved: a human/approval handler must say
    /// yes. With no approval handler available (e.g. non-interactive `--yolo`), raw
    /// shell is refused outright — the caller should use structured executable+args.
    public func shellStringRefusalReason(for command: String) async -> String? {
        guard enabled else { return "shell is disabled in this context" }
        let lower = command.lowercased()
        for bad in deny where lower.contains(bad.lowercased()) {
            return "matches deny-list entry '\(bad)'"
        }
        // Under the OS sandbox the kernel is the boundary, so a hands-off run may execute raw shell
        // (pipes/redirects) without an interactive handler — the advisory deny-list above still applies.
        if sandboxed { return nil }
        guard let approval = approval else {
            return "raw shell commands require interactive approval (unavailable here); "
                 + "use executable+args, or run under the OS sandbox (--sandbox / --auto)"
        }
        let ok = await approval(command)
        return ok ? nil : "denied at the approval prompt"
    }
}

// MARK: - Tool execution context
//
// Injectable replacement for the GUI app's `projectPath: String` + `ToolRegistry.shared`.
// Owns the confinement root and the shell policy. Path resolution here is the single
// security chokepoint every filesystem tool routes through.

public struct ToolContext: Sendable {
    /// The confinement root. All tool filesystem access is restricted to this subtree.
    public let projectRoot: String
    /// Explicitly-armed EXTERNAL READ-ONLY roots (canonicalized; e.g. `/Volumes` for a CD/USB
    /// drive via `--allow-read /Volumes`). READ tools may resolve absolute paths under these
    /// via `confinedRootForReading`/`resolvedPathForReading`; write/move/remove/mkdir stay
    /// confined to `projectRoot` (and the `ConfinedRoot.readOnly` flag enforces it again at
    /// the primitive level). Empty by default — fail-closed, exactly as before.
    public let externalReadRoots: [String]
    public let shell: ShellPolicy
    /// Opt-in OS-level sandbox for `run_command` (kernel-enforced egress-deny + write
    /// confinement). Disabled by default; in-process gates always apply regardless.
    public let sandbox: SandboxPolicy
    /// Deterministic authorization/scope decision for the current goal. This is enforced by
    /// ToolRegistry before a tool runs; prompts are advisory, this field is the runtime gate.
    public let authorizationScope: ScopeDecision?
    /// True only after the host has explicitly approved active work for a `.needsApproval` scope.
    /// `.needsScope` and `.planOnly` are never bypassed by this flag.
    public let scopeOverrideApproved: Bool

    /// Agent-Skills support (additive, all-optional). When a skill set is in play the loop passes
    /// the location→name index so `read_file` can recognize a SKILL.md load (lift its read window,
    /// mark it loaded) and resolve builtin `kist:` paths. Empty/nil ⇒ skills inert, read_file
    /// behaves exactly as before.
    public let skillLocations: [String: String]
    public let skillTracker: SkillTracker?
    /// Immutable per-call audit trail at the tool choke point (council #1). nil = off (library/tests);
    /// the CLI wires one writing `.kist/audit/tools.jsonl`.
    public let auditLog: AuditLog?

    public init(projectRoot: String, shell: ShellPolicy = .denied, sandbox: SandboxPolicy = .confined(),
                authorizationScope: ScopeDecision? = nil, scopeOverrideApproved: Bool = false,
                skillLocations: [String: String] = [:], skillTracker: SkillTracker? = nil,
                auditLog: AuditLog? = nil, externalReadRoots: [String] = []) {
        self.projectRoot = projectRoot
        self.shell = shell
        self.sandbox = sandbox
        self.authorizationScope = authorizationScope
        self.scopeOverrideApproved = scopeOverrideApproved
        self.skillLocations = skillLocations
        self.skillTracker = skillTracker
        self.auditLog = auditLog
        // Canonicalize once, drop non-existent entries (fail-closed: a bogus root grants nothing).
        // "/" is refused outright — it would un-confine every read; arm specific trees instead.
        self.externalReadRoots = externalReadRoots
            .compactMap { Self.canonicalize($0) }
            .filter { $0 != "/" }
    }

    public func withAuthorizationScope(_ decision: ScopeDecision?) -> ToolContext {
        ToolContext(projectRoot: projectRoot, shell: shell, sandbox: sandbox,
                    authorizationScope: decision, scopeOverrideApproved: false,
                    skillLocations: skillLocations, skillTracker: skillTracker, auditLog: auditLog,
                    externalReadRoots: externalReadRoots)
    }

    public func withScopeOverrideApproved(_ approved: Bool) -> ToolContext {
        ToolContext(projectRoot: projectRoot, shell: shell, sandbox: sandbox,
                    authorizationScope: authorizationScope, scopeOverrideApproved: approved,
                    skillLocations: skillLocations, skillTracker: skillTracker, auditLog: auditLog,
                    externalReadRoots: externalReadRoots)
    }

    /// Attach a discovered skill set to this context (used by the loop after discovery).
    public func withSkills(locations: [String: String], tracker: SkillTracker?) -> ToolContext {
        ToolContext(projectRoot: projectRoot, shell: shell, sandbox: sandbox,
                    authorizationScope: authorizationScope, scopeOverrideApproved: scopeOverrideApproved,
                    skillLocations: locations, skillTracker: tracker, auditLog: auditLog,
                    externalReadRoots: externalReadRoots)
    }

    /// Attach an audit log (used by the CLI when constructing the run's context).
    public func withAuditLog(_ log: AuditLog?) -> ToolContext {
        ToolContext(projectRoot: projectRoot, shell: shell, sandbox: sandbox,
                    authorizationScope: authorizationScope, scopeOverrideApproved: scopeOverrideApproved,
                    skillLocations: skillLocations, skillTracker: skillTracker, auditLog: log,
                    externalReadRoots: externalReadRoots)
    }

    /// TOCTOU-safe filesystem confinement for this context's root (Codex HIGH#2). File
    /// content I/O routes through this `openat`/`O_NOFOLLOW` layer rather than the
    /// string-based `resolvedPath`, which is only safe for a one-shot canonical path
    /// (e.g. validating a working directory before spawn).
    public func confinedRoot() throws -> ConfinedRoot {
        try ConfinedRoot(root: projectRoot)
    }

    /// Route a caller path to the right confinement root FOR READING. Relative paths and
    /// absolute paths inside the project resolve exactly as `confinedRoot()` always has. An
    /// ABSOLUTE path under one of the explicitly-armed `externalReadRoots` returns a
    /// READ-ONLY `ConfinedRoot` on that external root instead (same openat/O_NOFOLLOW
    /// enforcement — the string check below only CHOOSES the root; containment is enforced
    /// at open time). Anything else throws `.pathEscape` naming what IS readable, so the
    /// model gets an actionable error instead of a dead end.
    ///
    /// WRITE tools must keep using `confinedRoot()` — and even if one slips, the returned
    /// root's `readOnly` flag refuses the mutation at the primitive level.
    public func confinedRootForReading(_ path: String) throws -> (confined: ConfinedRoot, path: String) {
        guard path.hasPrefix("/") else { return (try confinedRoot(), path) }
        guard let rootReal = Self.canonicalize(projectRoot) else {
            throw ToolError.configuration("project root does not exist: \(projectRoot)")
        }
        let resolved = Self.canonicalizeAllowingMissing(path)
        // Project root wins: identical behavior to the historical single-root path.
        if resolved == rootReal || resolved.hasPrefix(rootReal + "/") {
            return (try confinedRoot(), path)
        }
        for ext in externalReadRoots where resolved == ext || resolved.hasPrefix(ext + "/") {
            return (try ConfinedRoot(root: ext, readOnly: true), resolved)
        }
        // macOS drag/screenshot inbox: a file the user ATTACHED (dragged/pasted a screenshot) lands
        // here read-only. Vision/media tools may read it without a --allow-read grant. See mediaDropInbox().
        if let inbox = Self.mediaDropInbox(), resolved == inbox || resolved.hasPrefix(inbox + "/") {
            // Screenshot/drag drops normally live in a unique OS-created subdirectory. Root the
            // descriptor confinement at the requested item's canonical parent instead of opening
            // the shared TemporaryItems directory: this grants a strictly smaller read surface and
            // avoids macOS file-coordination interruptions observed when the shared inbox is busy.
            // A request for the inbox itself keeps the inbox root; a missing parent falls back to it.
            let parent = (resolved as NSString).deletingLastPathComponent
            let attachmentRoot = resolved == inbox
                ? inbox
                : (Self.canonicalize(parent).flatMap {
                    ($0 == inbox || $0.hasPrefix(inbox + "/")) ? $0 : nil
                } ?? inbox)
            return (try ConfinedRoot(root: attachmentRoot, readOnly: true), resolved)
        }
        throw ToolError.pathEscape(path: path, root: readableRootsDescription(projectReal: rootReal))
    }

    /// Like `resolvedPath(_:mustExist:)` but for READ-ONLY consumers (view_image,
    /// analyze_media, read_spreadsheet): an absolute path under an armed external read
    /// root is also accepted. Never use for a path that will be written.
    public func resolvedPathForReading(_ path: String, mustExist: Bool) throws -> String {
        do { return try resolvedPath(path, mustExist: mustExist) }
        catch let escape as ToolError {
            guard case .pathEscape = escape else { throw escape }
            let resolved = Self.canonicalizeAllowingMissing(path)
            for ext in externalReadRoots where resolved == ext || resolved.hasPrefix(ext + "/") {
                if mustExist && !FileManager.default.fileExists(atPath: resolved) {
                    throw ToolError.notFound(path)
                }
                return resolved
            }
            // macOS drag/screenshot inbox — user-attached media is readable read-only (see mediaDropInbox()).
            // MUST mirror confinedRootForReading: view_image validates here, then reads bytes there — a fix
            // in one without the other passes validation and then fails the read (or vice versa).
            if let inbox = Self.mediaDropInbox(), resolved == inbox || resolved.hasPrefix(inbox + "/") {
                if mustExist && !FileManager.default.fileExists(atPath: resolved) {
                    throw ToolError.notFound(path)
                }
                return resolved
            }
            let rootReal = Self.canonicalize(projectRoot) ?? projectRoot
            throw ToolError.pathEscape(path: path, root: readableRootsDescription(projectReal: rootReal))
        }
    }

    /// TOCTOU-safe byte read honoring external read roots: resolve via `confinedRootForReading`
    /// and read on the SAME openat/O_NOFOLLOW layer as the core file tools — never a
    /// resolve-then-reopen-by-name window (the exact pattern ConfinedRoot exists to close,
    /// which matters MORE on other-process-writable external media).
    public func readDataForReading(_ path: String, maxBytes: Int? = nil) throws -> Data {
        let (confined, p) = try confinedRootForReading(path)
        return try confined.readData(p, maxBytes: maxBytes)
    }

    /// TOCTOU-safe UTF-8 read honoring external read roots (see `readDataForReading`).
    public func readStringForReading(_ path: String) throws -> String {
        let (confined, p) = try confinedRootForReading(path)
        return try confined.readString(p)
    }

    /// "…escapes the project root (<this>) — refused": name the armed read roots so the
    /// error itself tells the model where reads ARE allowed.
    private func readableRootsDescription(projectReal: String) -> String {
        var roots = externalReadRoots
        // Surface the auto-armed drag/screenshot inbox too — it IS readable, so an honest error
        // must name it (otherwise the model is steered to a pointless `cp` or --allow-read).
        if let inbox = Self.mediaDropInbox() { roots.append(inbox) }
        return roots.isEmpty
            ? projectReal
            : projectReal + "; also readable read-only: " + roots.joined(separator: ", ")
    }

    /// The macOS per-user drag/screenshot inbox: when you take a screenshot (⌘⇧⌃4 → clipboard, or
    /// drag the capture thumbnail) or drag a Finder item into the terminal, the OS stages the file
    /// under `<$TMPDIR>/TemporaryItems/…` (e.g. `…/T/TemporaryItems/NSIRD_screencaptureui_XXXX/
    /// Screenshot.png`). READ-ONLY vision/media tools (view_image, analyze_media, …) may read a file
    /// the user handed us there WITHOUT a `--allow-read` grant — attaching the file IS the grant.
    ///
    /// Evaluated LIVE per call (not existence-filtered at ToolContext init) so it works even when the
    /// inbox is created AFTER a long-lived session started — Luke keeps terminals open for weeks, so
    /// the inbox frequently does not exist at launch. Returns nil until the inbox exists; `canonicalize`
    /// resolves the `/var → /private/var` symlink so the prefix compare matches the caller's resolved
    /// path. Scoped to `TemporaryItems` (NOT all of $TMPDIR) so we don't expose other apps' temp files.
    /// WRITE tools are unaffected — they route through `confinedRoot()` (project root only).
    static func mediaDropInbox() -> String? {
        let base = NSTemporaryDirectory()          // per-user $TMPDIR, e.g. /var/folders/xx/…/T/
        guard !base.isEmpty else { return nil }
        let inbox = (base as NSString).appendingPathComponent("TemporaryItems")
        return canonicalize(inbox)                 // nil until it exists; re-checked live each call
    }

    /// Resolve a caller-supplied path to an absolute path GUARANTEED to live inside
    /// `projectRoot`, symlink-safe at the moment of the call. Relative paths resolve
    /// against the root; absolute paths are allowed only if inside the root after
    /// canonicalization. `..` and symlink escapes are rejected.
    ///
    /// NOTE: this is a point-in-time STRING check — for repeated file opens prefer
    /// `confinedRoot()` (TOCTOU-safe). Kept for one-shot uses like validating a cwd.
    ///
    /// - Parameter mustExist: when true, throws `.notFound` if the resolved path is absent.
    public func resolvedPath(_ path: String, mustExist: Bool) throws -> String {
        guard let rootReal = Self.canonicalize(projectRoot) else {
            throw ToolError.configuration("project root does not exist: \(projectRoot)")
        }
        let candidate = path.hasPrefix("/") ? path : rootReal + "/" + path
        let resolved = Self.canonicalizeAllowingMissing(candidate)

        // Containment: resolved must BE the root or sit strictly under it. The trailing
        // "/" prevents a sibling like "/rootEVIL" from passing a naive prefix check.
        if resolved != rootReal && !resolved.hasPrefix(rootReal + "/") {
            throw ToolError.pathEscape(path: path, root: rootReal)
        }
        if mustExist && !FileManager.default.fileExists(atPath: resolved) {
            throw ToolError.notFound(path)
        }
        return resolved
    }

    // MARK: Canonicalization (POSIX realpath — identical API on Darwin + Glibc)

    /// `realpath(3)`: fully resolves symlinks. Returns nil if the path does not exist.
    /// Public so hosts (Kist, mcp-server) can resolve a user-supplied project root.
    public static func canonicalize(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return path.withCString { cPath in
            guard realpath(cPath, &buffer) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    /// Canonicalize a path that may not exist yet (e.g. a file about to be written):
    /// resolve the deepest existing ancestor with `realpath` (so any symlink in the
    /// existing prefix is followed and caught by the containment check), then re-append
    /// the non-existent tail. This defeats "write through a symlinked dir" escapes.
    static func canonicalizeAllowingMissing(_ path: String) -> String {
        let std = URL(fileURLWithPath: path).standardizedFileURL   // collapse "." and ".."
        if let real = canonicalize(std.path) { return real }

        var dir = std.deletingLastPathComponent()
        var tail = [std.lastPathComponent]
        while true {
            if let real = canonicalize(dir.path) {
                return real + "/" + tail.reversed().joined(separator: "/")
            }
            if dir.path == "/" || dir.path.isEmpty { break }
            tail.append(dir.lastPathComponent)
            dir = dir.deletingLastPathComponent()
        }
        return std.path
    }
}

// MARK: - AgentTool protocol

/// A capability the agent can invoke. Stateless + `Sendable` so a single instance is
/// safely shared across the registry and concurrent tool calls.
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var parameters: [ToolParameter] { get }
    // Capability-contract surface (defaults in ToolContract.swift). Declared as REQUIREMENTS so a tool's
    // override dispatches dynamically through the `AgentTool` existential — an extension-only declaration
    // would statically bind to the empty default and the contract would never see a tool's real actions.
    var supportedActions: [String] { get }
    var unsupportedActions: [String] { get }
    var capabilityNote: String? { get }
    var usageExamples: [String] { get }

    /// Execute with caller-supplied arguments inside `context`. Implementations route
    /// all file content + directory access through `context.confinedRoot()` (the
    /// TOCTOU-safe `openat`/`O_NOFOLLOW` layer), use `context.resolvedPath(...)` only for
    /// one-shot canonical checks (e.g. validating a cwd), and route ALL process spawning
    /// through `context.shell`.
    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult
}

public extension AgentTool {
    /// Read a required string argument or throw `.missingParameter`.
    func requireString(_ key: String, from arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else { throw ToolError.missingParameter(key) }
        return value
    }

    /// Read an optional int argument, tolerating models that send it as a String.
    func optionalInt(_ key: String, from arguments: [String: Any]) -> Int? {
        if let i = arguments[key] as? Int { return i }
        if let s = arguments[key] as? String, let i = Int(s) { return i }
        if let d = arguments[key] as? Double { return Int(d) }
        return nil
    }

    /// Lenient optional bool: accepts a real Bool, or "true"/"1"/"yes" (case-insensitive) as a string.
    func optionalBool(_ key: String, from arguments: [String: Any]) -> Bool? {
        if let b = arguments[key] as? Bool { return b }
        if let s = (arguments[key] as? String)?.lowercased() {
            if ["true", "1", "yes", "y"].contains(s) { return true }
            if ["false", "0", "no", "n"].contains(s) { return false }
        }
        if let i = arguments[key] as? Int { return i != 0 }
        return nil
    }
}
