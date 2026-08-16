import Foundation
// Cross-platform crypto: swift-crypto's `Crypto` (CryptoKit-compatible, Linux-safe).
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum BuilderOSProcessSandboxError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest(String)
    case mechanismUnavailable(String)
    case mechanismUntrusted(String)
    case policyInvalid
    case attestationInvalid
    case sessionUnavailable
    case sessionReplay
    case workspaceMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let value): return "Invalid Builder sandbox request: \(value)"
        case .mechanismUnavailable(let value): return "Builder OS sandbox is unavailable: \(value)"
        case .mechanismUntrusted(let value): return "Builder OS sandbox mechanism is untrusted: \(value)"
        case .policyInvalid: return "Builder OS sandbox policy is invalid"
        case .attestationInvalid: return "Builder OS sandbox attestation is invalid"
        case .sessionUnavailable: return "Builder OS sandbox session is unavailable"
        case .sessionReplay: return "Builder OS sandbox attestation was already activated"
        case .workspaceMismatch: return "Builder subprocess is outside its attested staged workspace"
        }
    }
}

/// Host-owned process sandbox attestor for transactional Builder workers. An attestation is not a
/// bearer assertion: it becomes usable only when this type has registered the matching one-use
/// session in the current process. `withRegisteredScope` consumes that pending session, installs a
/// TaskLocal token, and removes all authority and private policy files when the operation returns.
public struct BuilderOSProcessSandboxAttestor: BuilderSandboxAttestor, Sendable {
    public init() {}

    public func attest(_ request: BuilderSandboxAttestationRequest) async throws
        -> BuilderSandboxAttestation {
        let normalized = try BuilderSandboxRequestBinding(request)
        let sessionID = UUID().uuidString.lowercased()
        let paths = try BuilderSandboxPrivatePaths(sessionID: sessionID)
        do {
            let backend = try BuilderSandboxBackend.make(
                stagedRoot: normalized.stagedRoot, stage: normalized.request.stage,
                privatePaths: paths)
            try backend.writePrivatePolicy(to: paths.policyURL)
            try backend.proveUsable(
                stagedRoot: normalized.stagedRoot, privatePaths: paths)
            guard backend.policy.utf8.count <= BuilderSandboxBackend.maximumPolicyBytes else {
                throw BuilderOSProcessSandboxError.policyInvalid
            }
            let canonical = BuilderSandboxRegisteredSession.canonicalEvidence(
                request: normalized.request, sessionID: sessionID, backend: backend,
                privatePaths: paths)
            let seal = ForgeSeal.sign(canonical)
            guard !seal.isEmpty else {
                throw BuilderOSProcessSandboxError.attestationInvalid
            }
            let attestation = try BuilderSandboxAttestation(
                request: normalized.request, mechanism: backend.mechanism,
                enforced: true, evidenceDigest: seal)
            try attestation.validate(normalized.request)
            let session = BuilderSandboxRegisteredSession(
                request: normalized.request, attestation: attestation,
                sessionID: sessionID, backend: backend, privatePaths: paths,
                canonicalEvidence: canonical)
            try session.validateEvidence()
            try BuilderSandboxSessionRegistry.shared.register(session)
            return attestation
        } catch {
            paths.remove()
            throw error
        }
    }

    func reattestIfNeeded(
        _ request: BuilderSandboxAttestationRequest,
        existing: BuilderSandboxAttestation
    ) async throws -> BuilderSandboxAttestation {
        try existing.validate(request)
        if BuilderSandboxSessionRegistry.shared.canActivate(
            request: request, attestation: existing) {
            return existing
        }
        return try await attest(request)
    }

    /// Governance wiring point. Reconstructs the exact request from the execution workspace plus
    /// the host-owned Builder contract ID, consumes its registered attestation, and confines every
    /// `ProcessGroupRunner` invocation made by the operation and its child Tasks.
    public static func withRegisteredScope<T: Sendable>(
        workspace: BuilderExecutionWorkspace,
        builderContractID: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let attestation = workspace.attestation
        let request = BuilderSandboxAttestationRequest(
            contractFingerprint: attestation.contractFingerprint,
            builderContractID: builderContractID,
            nodeID: attestation.nodeID,
            attempt: attestation.attempt,
            stagedRoot: workspace.rootPath,
            governedRootDigest: attestation.governedRootDigest,
            challenge: attestation.challenge,
            stage: attestation.stage ?? .build)
        return try await withRegisteredScope(
            request: request, attestation: attestation, operation: operation)
    }

    public static func withRegisteredScope<T: Sendable>(
        request: BuilderSandboxAttestationRequest,
        attestation: BuilderSandboxAttestation,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let normalized = try BuilderSandboxRequestBinding(request).request
        let activation = try BuilderSandboxSessionRegistry.shared.activate(
            request: normalized, attestation: attestation)
        defer { BuilderSandboxSessionRegistry.shared.deactivate(token: activation.token) }
        return try await BuilderSandboxTaskScope.$token.withValue(activation.token) {
            try await operation()
        }
    }
}

enum BuilderSandboxTaskScope {
    @TaskLocal static var token: String?
}

struct BuilderSandboxPreparedLaunch {
    let launchPath: String
    let launchArgs: [String]
    let cwd: String
    let environment: [String: String]
    let environmentDigest: String
    let sandboxProfileDigest: String
}

extension BuilderOSProcessSandboxAttestor {
    static func preparedLaunch(launchPath: String, launchArgs: [String], cwd: String,
                               environment: [String: String]) throws
        -> BuilderSandboxPreparedLaunch? {
        let session: BuilderSandboxRegisteredSession?
        if let token = BuilderSandboxTaskScope.token {
            guard let exact = BuilderSandboxSessionRegistry.shared.active(token: token) else {
                throw BuilderOSProcessSandboxError.sessionUnavailable
            }
            session = exact
        } else {
            // Existing tool implementations sometimes hop from a Swift Task to GCD before calling
            // ProcessGroupRunner. Resolve only an unambiguous active staged root in that case.
            session = try BuilderSandboxSessionRegistry.shared.active(containing: cwd)
        }
        guard let session else { return nil }
        try session.validateEvidence()
        guard BuilderSandboxPath.contains(parent: session.request.stagedRoot, child: cwd) else {
            throw BuilderOSProcessSandboxError.workspaceMismatch
        }
        return try session.backend.prepare(
            launchPath: launchPath, launchArgs: launchArgs, cwd: cwd,
            environment: environment,
            stagedRoot: BuilderSandboxPath.canonical(session.request.stagedRoot),
            privatePaths: session.privatePaths)
    }
}

private struct BuilderSandboxRequestBinding {
    let request: BuilderSandboxAttestationRequest
    let stagedRoot: String

    init(_ request: BuilderSandboxAttestationRequest) throws {
        guard request.attempt > 0 else {
            throw BuilderOSProcessSandboxError.invalidRequest("attempt must be positive")
        }
        _ = try BuilderExecutionValidation.digest(
            request.contractFingerprint, field: "sandbox contract fingerprint")
        _ = try BuilderExecutionValidation.identifier(
            request.builderContractID, field: "sandbox Builder contract")
        _ = try BuilderExecutionValidation.identifier(request.nodeID, field: "sandbox node")
        _ = try BuilderExecutionValidation.digest(
            request.governedRootDigest, field: "sandbox governed root digest")
        guard !request.challenge.isEmpty, request.challenge.utf8.count <= 512,
              !request.challenge.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw BuilderOSProcessSandboxError.invalidRequest("challenge is empty, oversized, or unsafe")
        }
        let standardized = URL(fileURLWithPath: request.stagedRoot, isDirectory: true)
            .standardizedFileURL.path
        let resolved = BuilderSandboxPath.canonical(standardized)
        let requestedIdentity = try? BuilderWorkspaceRootIdentity.capture(
            rootPath: request.stagedRoot)
        var isDirectory: ObjCBool = false
        guard request.stagedRoot.hasPrefix("/"),
              requestedIdentity?.canonicalPath == resolved,
              FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              isDirectory.boolValue, resolved.utf8.count <= 4_096 else {
            throw BuilderOSProcessSandboxError.invalidRequest(
                "staged root must be an existing canonical absolute directory")
        }
        self.stagedRoot = resolved
        self.request = request
    }
}

private struct BuilderSandboxPrivatePaths: Sendable {
    let root: String
    let temp: String
    let home: String
    let cache: String
    let swiftCache: String
    let clangCache: String
    let control: String
    let policyURL: URL

    init(sessionID: String) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-builder-sandbox-v1", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        let namespace = base.deletingLastPathComponent()
        try BuilderSandboxSecureIO.ensurePrivateDirectory(
            namespace, withIntermediateDirectories: true)
        try BuilderSandboxSecureIO.ensurePrivateDirectory(
            base, withIntermediateDirectories: false)
        let resolved = URL(
            fileURLWithPath: BuilderSandboxPath.canonical(base.path), isDirectory: true)
        let temp = resolved.appendingPathComponent("tmp", isDirectory: true)
        let home = resolved.appendingPathComponent("home", isDirectory: true)
        let cache = resolved.appendingPathComponent("cache", isDirectory: true)
        let swiftCache = cache.appendingPathComponent("swift", isDirectory: true)
        let clangCache = cache.appendingPathComponent("clang", isDirectory: true)
        let control = resolved.appendingPathComponent("control", isDirectory: true)
        for directory in [temp, home, cache, swiftCache, clangCache, control] {
            try BuilderSandboxSecureIO.ensurePrivateDirectory(
                directory, withIntermediateDirectories: false)
        }
        self.root = resolved.path
        self.temp = temp.path
        self.home = home.path
        self.cache = cache.path
        self.swiftCache = swiftCache.path
        self.clangCache = clangCache.path
        self.control = control.path
        self.policyURL = control.appendingPathComponent("profile.sb")
    }

    func remove() {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        var status = stat()
        guard lstat(root, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              status.st_uid == geteuid() else { return }
        try? FileManager.default.removeItem(at: rootURL)
        try? BuilderSandboxSecureIO.fsyncDirectory(rootURL.deletingLastPathComponent())
    }
}

private enum BuilderSandboxSecureIO {
    static func ensurePrivateDirectory(_ url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: withIntermediateDirectories,
            attributes: [.posixPermissions: 0o700])
        guard chmod(url.path, 0o700) == 0 else {
            throw BuilderOSProcessSandboxError.mechanismUnavailable(
                "cannot secure private sandbox directory")
        }
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              status.st_uid == geteuid(),
              (status.st_mode & mode_t(0o077)) == 0 else {
            throw BuilderOSProcessSandboxError.mechanismUntrusted(
                "private sandbox directory identity or permissions changed")
        }
        try fsyncDirectory(url)
    }

    static func fsyncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw BuilderOSProcessSandboxError.mechanismUnavailable(
                "cannot open private sandbox directory")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 || errno == EINVAL else {
            throw BuilderOSProcessSandboxError.mechanismUnavailable(
                "cannot persist private sandbox directory")
        }
    }

    static func fsyncFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw BuilderOSProcessSandboxError.mechanismUnavailable(
                "cannot open private sandbox policy")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw BuilderOSProcessSandboxError.mechanismUnavailable(
                "cannot persist private sandbox policy")
        }
    }
}

private struct BuilderSandboxBackend: Sendable {
    static let maximumPolicyBytes = 32 * 1_024

    enum Kind: String, Sendable { case seatbelt, bubblewrap }
    let kind: Kind
    let binaryPath: String
    let binaryDigest: String
    let policy: String
    let policyDigest: String
    let stage: BuilderExecutionStage
    let stagedWritable: Bool

    var mechanism: String {
        "builder-os-sandbox/v2;backend=\(kind.rawValue);binary=\(binaryDigest);policy=\(policyDigest);stage=\(stage.rawValue);staged=\(stagedWritable ? "rw" : "ro")"
    }

    static func make(stagedRoot: String, stage: BuilderExecutionStage,
                     privatePaths: BuilderSandboxPrivatePaths) throws -> Self {
        let stagedWritable = stage == .build
        #if os(macOS)
        let binary = "/usr/bin/sandbox-exec"
        let digest = try trustedBinaryDigest(binary)
        let policy = try seatbeltPolicy(
            stagedRoot: stagedRoot, stagedWritable: stagedWritable,
            writablePrivatePaths: [privatePaths.temp, privatePaths.home, privatePaths.cache])
        return Self(kind: .seatbelt, binaryPath: binary, binaryDigest: digest,
                    policy: policy, policyDigest: BuilderEvidenceDigest.sha256(policy),
                    stage: stage, stagedWritable: stagedWritable)
        #elseif os(Linux)
        guard let binary = ["/usr/bin/bwrap", "/bin/bwrap"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw BuilderOSProcessSandboxError.mechanismUnavailable("bubblewrap is not installed")
        }
        let digest = try trustedBinaryDigest(binary)
        let policy = "bwrap-v2|root=ro|staged=\(stagedWritable ? "rw" : "ro")|private=rw|network=deny|process=new-session|stage=\(stage.rawValue)"
        return Self(kind: .bubblewrap, binaryPath: binary, binaryDigest: digest,
                    policy: policy, policyDigest: BuilderEvidenceDigest.sha256(policy),
                    stage: stage, stagedWritable: stagedWritable)
        #else
        throw BuilderOSProcessSandboxError.mechanismUnavailable("unsupported operating system")
        #endif
    }

    func writePrivatePolicy(to url: URL) throws {
        guard policy.utf8.count <= Self.maximumPolicyBytes else {
            throw BuilderOSProcessSandboxError.policyInvalid
        }
        switch kind {
        case .seatbelt:
            // Seatbelt receives the bounded, attested non-secret profile directly with `-p`.
            // Never materialize an authoritative policy under a child-writable directory.
            return
        case .bubblewrap:
            try Data(policy.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            try BuilderSandboxSecureIO.fsyncFile(url)
            try BuilderSandboxSecureIO.fsyncDirectory(url.deletingLastPathComponent())
        }
    }

    func prepare(launchPath: String, launchArgs: [String], cwd: String,
                 environment: [String: String], stagedRoot: String,
                 privatePaths: BuilderSandboxPrivatePaths) throws
        -> BuilderSandboxPreparedLaunch {
        guard try Self.trustedBinaryDigest(binaryPath) == binaryDigest else {
            throw BuilderOSProcessSandboxError.mechanismUntrusted("binary identity changed")
        }
        _ = environment
        let env = Self.fixedEnvironment(privatePaths: privatePaths)
        let environmentDigest = Self.environmentDigest(env)
        switch kind {
        case .seatbelt:
            guard policy.utf8.count <= Self.maximumPolicyBytes,
                  BuilderEvidenceDigest.sha256(policy) == policyDigest else {
                throw BuilderOSProcessSandboxError.policyInvalid
            }
            return BuilderSandboxPreparedLaunch(
                launchPath: binaryPath,
                launchArgs: ["-p", policy, launchPath] + launchArgs,
                cwd: cwd, environment: env,
                environmentDigest: environmentDigest,
                sandboxProfileDigest: policyDigest)
        case .bubblewrap:
            var args = [
                "--die-with-parent", "--new-session", "--unshare-all",
                "--clearenv",
                "--ro-bind", "/", "/",
                "--bind", privatePaths.temp, privatePaths.temp,
                "--bind", privatePaths.home, privatePaths.home,
                "--bind", privatePaths.cache, privatePaths.cache,
                stagedWritable ? "--bind" : "--ro-bind", stagedRoot, stagedRoot,
                "--chdir", BuilderSandboxPath.canonical(cwd),
            ]
            for key in env.keys.sorted() {
                args += ["--setenv", key, env[key] ?? ""]
            }
            args += ["--", launchPath] + launchArgs
            return BuilderSandboxPreparedLaunch(
                launchPath: binaryPath, launchArgs: args, cwd: cwd, environment: env,
                environmentDigest: environmentDigest,
                sandboxProfileDigest: policyDigest)
        }
    }

    private static func fixedEnvironment(
        privatePaths: BuilderSandboxPrivatePaths
    ) -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "HOME": privatePaths.home,
            "CFFIXED_USER_HOME": privatePaths.home,
            "TMPDIR": privatePaths.temp + "/",
            "TMP": privatePaths.temp,
            "TEMP": privatePaths.temp,
            "XDG_CACHE_HOME": privatePaths.cache,
            "CLANG_MODULE_CACHE_PATH": privatePaths.clangCache,
            "SWIFT_MODULECACHE_PATH": privatePaths.swiftCache,
            "SWIFTPM_MODULECACHE_OVERRIDE": privatePaths.swiftCache,
            "PYTHONDONTWRITEBYTECODE": "1",
            "LANG": "C",
            "LC_ALL": "C",
            "TZ": "UTC",
        ]
    }

    static func environmentDigest(_ environment: [String: String]) -> String {
        BuilderEvidenceDigest.sha256(environment.keys.sorted().map {
            "\($0)=\(environment[$0] ?? "")"
        }.joined(separator: "\u{0}"))
    }

    func proveUsable(stagedRoot: String, privatePaths: BuilderSandboxPrivatePaths) throws {
        #if os(macOS)
        let truePath = "/usr/bin/true"
        #else
        let truePath = "/bin/true"
        #endif
        let launch = try prepare(
            launchPath: truePath, launchArgs: [], cwd: stagedRoot,
            environment: ["PATH": "/usr/bin:/bin"], stagedRoot: stagedRoot,
            privatePaths: privatePaths)
        let result = ProcessGroupRunner.run(
            launchPath: launch.launchPath, launchArgs: launch.launchArgs,
            cwd: launch.cwd, env: launch.environment,
            timeoutSeconds: 10, capPerStream: 16_384)
        guard result.exitCode == 0, !result.timedOut else {
            throw BuilderOSProcessSandboxError.mechanismUnavailable(
                "sandbox self-test failed: \(result.combined)")
        }
    }

    private static func seatbeltPolicy(stagedRoot: String, stagedWritable: Bool,
                                       writablePrivatePaths: [String]) throws -> String {
        let staged = try seatbeltString(stagedRoot)
        var lines = [
        """
        (version 1)
        (deny default)
        (import "system.sb")
        (allow process*)
        (allow signal (target self))
        (allow sysctl-read)
        (allow mach-lookup)
        (allow ipc-posix-shm*)
        (allow file-read*)
        (deny network*)
        """
        ]
        if stagedWritable {
            lines.append("(allow file-write* (literal \"\(staged)\"))")
            lines.append("(allow file-write* (subpath \"\(staged)\"))")
        }
        for path in writablePrivatePaths {
            let escaped = try seatbeltString(path)
            lines.append("(allow file-write* (literal \"\(escaped)\"))")
            lines.append("(allow file-write* (subpath \"\(escaped)\"))")
        }
        return lines.joined(separator: "\n")
    }

    private static func seatbeltString(_ value: String) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BuilderOSProcessSandboxError.policyInvalid
        }
        return value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func trustedBinaryDigest(_ path: String) throws -> String {
        var status = stat()
        guard lstat(path, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_uid == 0,
              (status.st_mode & mode_t(0o022)) == 0,
              FileManager.default.isExecutableFile(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            throw BuilderOSProcessSandboxError.mechanismUntrusted(path)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct BuilderSandboxRegisteredSession: Sendable {
    let request: BuilderSandboxAttestationRequest
    let attestation: BuilderSandboxAttestation
    let sessionID: String
    let backend: BuilderSandboxBackend
    let privatePaths: BuilderSandboxPrivatePaths
    let canonicalEvidence: String

    func validateEvidence() throws {
        try attestation.validate(request)
        guard attestation.mechanism == backend.mechanism,
              ForgeSeal.verify(canonicalEvidence, seal: attestation.evidenceDigest),
              backend.policyDigest == BuilderEvidenceDigest.sha256(backend.policy) else {
            throw BuilderOSProcessSandboxError.attestationInvalid
        }
    }

    static func canonicalEvidence(request: BuilderSandboxAttestationRequest, sessionID: String,
                                  backend: BuilderSandboxBackend,
                                  privatePaths: BuilderSandboxPrivatePaths) -> String {
        [
            "builder.os-process-sandbox.attestation.v1",
            "contractFingerprint=\(ForgeSeal.field(request.contractFingerprint))",
            "builderContractID=\(ForgeSeal.field(request.builderContractID))",
            "nodeID=\(ForgeSeal.field(request.nodeID))",
            "attempt=\(request.attempt)",
            "stage=\(request.stage.rawValue)",
            "stagedRoot=\(ForgeSeal.field(request.stagedRoot))",
            "governedRootDigest=\(ForgeSeal.field(request.governedRootDigest))",
            "challenge=\(ForgeSeal.field(request.challenge))",
            "mechanism=\(ForgeSeal.field(backend.mechanism))",
            "policyDigest=\(backend.policyDigest)",
            "sessionID=\(ForgeSeal.field(sessionID))",
            "privateRoot=\(ForgeSeal.field(privatePaths.root))",
        ].joined(separator: "|")
    }
}

private struct BuilderSandboxActivation { let token: String }

private final class BuilderSandboxSessionRegistry: @unchecked Sendable {
    static let shared = BuilderSandboxSessionRegistry()
    private let lock = NSLock()
    private var pending: [String: BuilderSandboxRegisteredSession] = [:]
    private var activeSessions: [String: BuilderSandboxRegisteredSession] = [:]

    func register(_ session: BuilderSandboxRegisteredSession) throws {
        lock.lock(); defer { lock.unlock() }
        guard pending.count + activeSessions.count < 128,
              pending[session.attestation.evidenceDigest] == nil,
              !activeSessions.values.contains(where: {
                  $0.attestation.evidenceDigest == session.attestation.evidenceDigest
              }) else {
            throw BuilderOSProcessSandboxError.sessionReplay
        }
        pending[session.attestation.evidenceDigest] = session
    }

    func canActivate(request: BuilderSandboxAttestationRequest,
                     attestation: BuilderSandboxAttestation) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let session = pending[attestation.evidenceDigest],
              session.request == request, session.attestation == attestation else {
            return false
        }
        return (try? session.validateEvidence()) != nil
    }

    func activate(request: BuilderSandboxAttestationRequest,
                  attestation: BuilderSandboxAttestation) throws -> BuilderSandboxActivation {
        lock.lock(); defer { lock.unlock() }
        guard let session = pending[attestation.evidenceDigest] else {
            throw BuilderOSProcessSandboxError.sessionReplay
        }
        do {
            try session.validateEvidence()
            try attestation.validate(request)
            guard session.request == request, session.attestation == attestation else {
                throw BuilderOSProcessSandboxError.attestationInvalid
            }
        } catch {
            throw error
        }
        pending.removeValue(forKey: attestation.evidenceDigest)
        let token = UUID().uuidString.lowercased()
        activeSessions[token] = session
        return BuilderSandboxActivation(token: token)
    }

    func deactivate(token: String) {
        lock.lock()
        let session = activeSessions.removeValue(forKey: token)
        lock.unlock()
        session?.privatePaths.remove()
    }

    func active(token: String) -> BuilderSandboxRegisteredSession? {
        lock.lock(); defer { lock.unlock() }
        return activeSessions[token]
    }

    func active(containing cwd: String) throws -> BuilderSandboxRegisteredSession? {
        lock.lock(); defer { lock.unlock() }
        let matches = activeSessions.values.filter {
            BuilderSandboxPath.contains(parent: $0.request.stagedRoot, child: cwd)
        }
        guard matches.count <= 1 else { throw BuilderOSProcessSandboxError.sessionUnavailable }
        return matches.first
    }
}

private enum BuilderSandboxPath {
    static func canonical(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.withCString { value in
            guard let resolved = realpath(value, nil) else { return standardized }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    static func contains(parent: String, child: String) -> Bool {
        let parent = canonical(parent)
        let child = canonical(child)
        return child == parent || child.hasPrefix(parent + "/")
    }
}
