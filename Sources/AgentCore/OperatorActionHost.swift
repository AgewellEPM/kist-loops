import Foundation
import Crypto
#if os(macOS)
import Darwin
#endif

/// Deterministic, one-action edge for a host-reserved operator task. This is not an
/// autonomous promotion authority, paid-model client, shell, or hard containment claim.
public enum OperatorActionHost {
    public static let maximumRequestBytes = 128 * 1024
    public static let maximumFileBytes = 64 * 1024
    public static let maximumCheckOutputBytes = 128 * 1024
    static let maximumResultBytes = 256 * 1024
    /// Exact UTF-8 bytes (no trailing newline) identify the compiled action policy.
    public static let policyDescription = "kist.operator-action.v1;single-use-exact-request;owner-private-permit;physical-root-binding;root_scope=workspace,source,packet;access=read,write;read_file=65536;list_directory=512;replace_file=65536,sha256-or-missing;make_directory=24;packet_write=ACTION_PLAN.md,ARCHITECTURE.md,BUSINESS_ANALYSIS.md,BUILD_NOTES.md,BUILD_SCOPE.md,BUILD_VERIFICATION.md,DESIGN_REVIEW.md,DEVELOPMENT_PLAN.md,HANDOFF.md,OUTREACH_PLAN.md,PLAN.md,RELEASE_REVIEW.md,RESEARCH.md,REVIEW.md;check=git_diff_check:120,swift_test:300;output=131072;network=deny;home=deny;writes=granted-root;accepted=false;hard-containment=false"
    public static let policySHA256 = sha256(Data(policyDescription.utf8))

    public static func execute(requestData: Data, authorityDirectory: URL,
                               now: Date = Date()) async -> OperatorActionResponse {
        await execute(requestData: requestData, authorityDirectory: authorityDirectory,
                      now: now, runCheck: { await runSandboxedCheck($0) })
    }

    struct CheckInvocation: Sendable {
        let executable: String
        let arguments: [String]
        let workspace: String
        let authorityRoot: String
        let projectRoot: String
        let timeoutSeconds: Int
    }
    struct CheckObservation: Sendable {
        let output: String
        let exitCode: Int32
        let timedOut: Bool
        let cancelled: Bool
        let outputTruncated: Bool
        let wasSignalled: Bool
        let sandboxed: Bool
    }
    typealias CheckRunner = @Sendable (CheckInvocation) async -> CheckObservation

    // Internal dependency seam permits deterministic failure/timeout tests without model calls.
    static func execute(requestData: Data, authorityDirectory: URL, now: Date,
                        lockDirectory: URL? = nil,
                        resultCheckpoint: @Sendable (OperatorActionResultCheckpoint) throws -> Void = { _ in },
                        runCheck: CheckRunner) async -> OperatorActionResponse {
        guard requestData.count <= maximumRequestBytes else {
            return .make(.denied, code: "request_too_large", message: "Request exceeds the byte limit.", now: now)
        }
        var request: OperatorActionRequest?
        var allowedRoot: String?
        let digest = sha256(requestData)
        var consumed = false
        func response(_ disposition: OperatorActionDisposition, _ code: String, _ message: String,
                      evidence: [String: String] = [:], content: String? = nil,
                      entries: [OperatorActionDirectoryEntry]? = nil) -> OperatorActionResponse {
            var facts = evidence
            if let scope = request?.root_scope { facts["root_scope"] = scope }
            if let allowedRoot { facts["allowed_root"] = allowedRoot }
            return .make(disposition, code: code, message: message, request: request,
                  digest: digest, now: now, evidence: facts, content: content, entries: entries)
        }
        do {
            guard !Task.isCancelled else { return response(.denied, "cancelled", "Action cancelled before dispatch.") }
            let input = try OperatorActionValidation.decode(OperatorActionRequest.self, data: requestData,
                keys: OperatorActionRequest.keys, maximumBytes: maximumRequestBytes)
            guard input.schema_version == 1,
                  OperatorActionValidation.uuid(input.action_id) != nil,
                  OperatorActionValidation.uuid(input.claim_id) != nil,
                  OperatorActionValidation.identifier(input.mission_id), input.policy_sha256 == policySHA256,
                  ["workspace", "source", "packet"].contains(input.root_scope) else {
                throw OperatorActionValidation.Failure.invalid
            }
            // Do not echo unvalidated names, paths, or model prose into an error response.
            let operation = try PreparedOperation(input)
            let authorities = try OperatorActionDirectory(path: authorityDirectory.path, ownerPrivate: true)
            let project = try OperatorActionDirectory(path: input.project_root)
            let workspace = try OperatorActionDirectory(path: input.workspace_root)
            guard disjoint(authorities.path, workspace.path),
                  disjoint(authorities.path, project.path) else { throw OperatorActionValidation.Failure.unsafe }
            let permitName = input.action_id.lowercased() + ".json"
            let permitData = try authorities.privateFile(permitName, maximumBytes: 16 * 1024)
            let permit = try OperatorActionValidation.decode(OperatorActionPermit.self, data: permitData,
                keys: OperatorActionPermit.keys, maximumBytes: 16 * 1024)
            try validate(permit, input: input, requestDigest: digest, project: project, workspace: workspace, now: now)
            let target = try OperatorActionDirectory(path: permit.allowed_root)
            guard disjoint(authorities.path, target.path), target.device == permit.allowed_root_device,
                  target.inode == permit.allowed_root_inode else { throw OperatorActionValidation.Failure.unsafe }
            let expectedRoot: String
            switch input.root_scope {
            case "workspace": expectedRoot = workspace.path
            case "source": expectedRoot = project.path
            case "packet": expectedRoot = URL(fileURLWithPath: workspace.path).deletingLastPathComponent().path
            default: throw OperatorActionValidation.Failure.invalid
            }
            guard target.path == expectedRoot, ["read", "write"].contains(permit.access),
                  !operation.requiresWrite || permit.access == "write" else { throw OperatorActionValidation.Failure.unsafe }
            try operation.validateScope(input.root_scope)
            request = input
            allowedRoot = target.path
            try authorities.requireUnused(name: ".used-" + permitName)

            // Share the existing Kist workspace lock estate. The internal override is a test
            // seam; neither stdin nor CLI configuration may choose the lock authority.
            let coordinator = lockDirectory.map { WorkspaceExecutionCoordinator(lockDirectory: $0) }
                ?? WorkspaceExecutionCoordinator()
            let lease = try coordinator.acquire(projectRoot: target.path,
                missionInstanceID: input.claim_id, blocking: false)
            defer { lease.release() }
            if case .replace = operation { try resultCheckpoint(.workspaceLeaseAcquired) }
            // A duplicate can pass the earlier check before another holder consumes
            // its marker. Recheck under the target lease before any baseline denial.
            try authorities.requireUnused(name: ".used-" + permitName)
            try project.revalidate()
            try workspace.revalidate()
            try target.revalidate()
            try authorities.revalidate()
            let root = try ConfinedRoot(root: target.path)
            guard root.rootPath == target.path else { throw OperatorActionValidation.Failure.unsafe }
            try target.revalidate()

            // Reject stale existing-file and create-only baselines before consuming the permit. The
            // confined publication primitive rechecks both digest and inode at the mutation edge.
            if case .replace(let path, let expected, _) = operation {
                // Never execute a fresh replacement over an occupied evidence slot,
                // including a symlink, partial prior write or same-byte fabricated result.
                try authorities.requireResultAbsent(actionID: input.action_id)
                if expected == "missing" {
                    try target.requireMissingTarget(path)
                } else {
                    let previous = try root.readStableData(path, maxBytes: maximumFileBytes)
                    guard sha256(previous) == expected else { throw OperatorActionValidation.Failure.stale }
                }
            }
            if case .check(let id) = operation {
                let invocation = checkInvocation(id, input: input, target: target.path, authorities: authorities.path)
                guard case .wrapped = wrapped(invocation) else { throw OperatorActionValidation.Failure.unsupported }
            }
            guard !Task.isCancelled else { return response(.denied, "cancelled", "Action cancelled before dispatch.") }
            // Set uncertainty before attempting publication: even a failed fsync can leave a
            // durable marker. No retry may infer that a missing stdout response means no effect.
            consumed = true
            try authorities.consume(name: ".used-" + permitName,
                data: Data((digest + "\n").utf8))
            guard !Task.isCancelled else { return response(.unknown, "cancelled", "Reserved action cancelled; review its outcome before continuing.") }
            try target.revalidate()
            switch operation {
            case .read(let path):
                do {
                    let bytes = try root.readStableData(path, maxBytes: maximumFileBytes)
                    guard let content = String(data: bytes, encoding: .utf8) else { throw OperatorActionValidation.Failure.invalid }
                    let safe = SecretScanner.redactSecrets(in: content)
                    return response(.observed, "file_read", "File contents observed.",
                        evidence: ["path": path, "sha256": sha256(bytes), "bytes": String(bytes.count),
                                   "redacted": String(safe != content)], content: safe)
                } catch {
                    // No project mutation or child process can occur in this branch. A missing,
                    // oversized, non-UTF8, or unsafe file is a known read denial, even though
                    // its host permit remains consumed and can never be used for another try.
                    return response(.denied, "read_unavailable", "A bounded regular UTF-8 file could not be read.",
                        evidence: ["path": path, "permit_consumed": "true", "project_mutation": "false"])
                }
            case .list(let path):
                do {
                    let entries = try target.entries(path)
                    return response(.observed, "directory_listed", "Directory entries observed; protected names are omitted.",
                        evidence: ["path": path, "entries": String(entries.count)], entries: entries)
                } catch {
                    return response(.denied, "directory_unavailable", "The directory could not be listed within its bounds.",
                        evidence: ["path": path, "permit_consumed": "true", "project_mutation": "false"])
                }
            case .replace(let path, let expected, let bytes):
                let baseline: ConfinedRoot.ConditionalBaseline = expected == "missing" ? .missing : .sha256(unhex(expected))
                let published = try root.conditionalReplace(path, with: bytes, expectedSHA256: baseline, lease: lease)
                let observed = try root.readStableData(path, maxBytes: maximumFileBytes)
                guard Data(SHA256.hash(data: observed)) == published else { throw OperatorActionValidation.Failure.unsafe }
                try target.revalidate()
                let observedResult = response(.observed, "file_replaced", "Conditional file publication observed.",
                    evidence: ["path": path, "before_sha256": expected, "after_sha256": sha256(observed),
                               "bytes": String(observed.count)])
                // Preserve the invocation's observed_at meaning and exact existing wire
                // envelope. This closes only lost stdout after this durable publication;
                // a crash before it still leaves an unknown effect. The target lease is held.
                try resultCheckpoint(.effectObserved)
                try project.revalidate()
                try workspace.revalidate()
                try target.revalidate()
                guard try authorities.privateFile(".used-" + permitName, maximumBytes: 128)
                    == Data((digest + "\n").utf8) else { throw OperatorActionValidation.Failure.unsafe }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var wire = try encoder.encode(observedResult)
                guard wire.count < maximumResultBytes else { throw OperatorActionValidation.Failure.io }
                wire.append(0x0a) // Same canonical encoding as KistOperatorActionProtocol.wireResponse.
                try authorities.publishResult(actionID: input.action_id, data: wire, checkpoint: resultCheckpoint)
                return observedResult
            case .mkdir(let path):
                try root.makeDirectory(path)
                let directory = try OperatorActionDirectory(path: target.path + "/" + path)
                try target.revalidate()
                return response(.observed, "directory_observed", "Confined directory exists.",
                    evidence: ["path": path, "kind": "directory", "device": directory.device, "inode": directory.inode])
            case .check(let id):
                let result = await runCheck(checkInvocation(id, input: input, target: target.path, authorities: authorities.path))
                let redacted = SecretScanner.redactSecrets(in: result.output)
                let hostTruncated = redacted.utf8.count > maximumCheckOutputBytes
                let safe = boundedText(redacted, maximumBytes: maximumCheckOutputBytes)
                let evidence = ["check_id": id, "exit_code": String(result.exitCode),
                    "passed": String(result.exitCode == 0 && result.sandboxed && !result.timedOut
                        && !result.cancelled && !result.outputTruncated && !hostTruncated && !result.wasSignalled),
                    "sandboxed": String(result.sandboxed), "hard_containment": "false",
                    "timed_out": String(result.timedOut), "cancelled": String(result.cancelled),
                    "output_truncated": String(result.outputTruncated || hostTruncated),
                    "redacted": String(redacted != result.output),
                    "signalled": String(result.wasSignalled)]
                guard result.sandboxed, !result.timedOut, !result.cancelled, !result.outputTruncated,
                      !hostTruncated, !result.wasSignalled, !Task.isCancelled else {
                    return response(.unknown, "check_interrupted", "Check outcome requires review; do not replay automatically.", evidence: evidence, content: safe)
                }
                try target.revalidate()
                return response(.observed, "check_completed", "Bounded check exited; this is not an acceptance receipt.", evidence: evidence, content: safe)
            }
        } catch OperatorActionValidation.Failure.replayed {
            return response(.unknown, "already_consumed", "This action permit was already consumed; reconcile the prior outcome.")
        } catch OperatorActionValidation.Failure.stale {
            return response(.denied, "stale_baseline", "The file no longer matches the reserved baseline.")
        } catch OperatorActionValidation.Failure.unsupported {
            return response(.denied, "sandbox_unavailable", "Required check confinement is unavailable.")
        } catch {
            return response(consumed ? .unknown : .denied, consumed ? "outcome_unknown" : "request_denied",
                consumed ? "The reserved action did not produce a verified outcome; review before continuing."
                    : "Request, permit, workspace identity, or operation constraints were not satisfied.")
        }
    }

    private enum PreparedOperation {
        case read(String), list(String), replace(String, String, Data), mkdir(String), check(String)
        var requiresWrite: Bool {
            switch self { case .read, .list: return false; case .replace, .mkdir, .check: return true }
        }
        func validateScope(_ scope: String) throws {
            guard scope == "packet" else { return }
            switch self {
            case .read, .list: break
            case .replace(let path, _, _):
                guard OperatorActionHost.packetWriteNames.contains(path) else { throw OperatorActionValidation.Failure.unsafe }
            case .mkdir, .check: throw OperatorActionValidation.Failure.unsafe
            }
        }
        init(_ request: OperatorActionRequest) throws {
            let args = request.arguments
            switch request.operation {
            case "read_file", "list_directory":
                guard Set(args.keys) == ["path"] else { throw OperatorActionValidation.Failure.invalid }
                let path = try OperatorActionValidation.argument(args, "path")
                try OperatorActionValidation.relativePath(path, allowRoot: request.operation == "list_directory")
                self = request.operation == "read_file" ? .read(path) : .list(path)
            case "replace_file":
                guard Set(args.keys) == ["path", "expected_sha256", "content"] else { throw OperatorActionValidation.Failure.invalid }
                let path = try OperatorActionValidation.argument(args, "path")
                try OperatorActionValidation.mutationPath(path)
                let expected = try OperatorActionValidation.argument(args, "expected_sha256")
                let bytes = Data(try OperatorActionValidation.argument(args, "content").utf8)
                guard expected == "missing" || OperatorActionValidation.digest(expected), bytes.count <= maximumFileBytes else {
                    throw OperatorActionValidation.Failure.invalid
                }
                self = .replace(path, expected, bytes)
            case "make_directory":
                guard Set(args.keys) == ["path"] else { throw OperatorActionValidation.Failure.invalid }
                let path = try OperatorActionValidation.argument(args, "path")
                try OperatorActionValidation.mutationPath(path)
                self = .mkdir(path)
            case "check":
                guard Set(args.keys) == ["check_id"] else { throw OperatorActionValidation.Failure.invalid }
                let id = try OperatorActionValidation.argument(args, "check_id")
                guard ["git_diff_check", "swift_test"].contains(id) else { throw OperatorActionValidation.Failure.invalid }
                self = .check(id)
            default: throw OperatorActionValidation.Failure.invalid
            }
        }
    }

    private static func validate(_ permit: OperatorActionPermit, input: OperatorActionRequest,
                                 requestDigest: String, project: OperatorActionDirectory,
                                 workspace: OperatorActionDirectory, now: Date) throws {
        guard permit.schema_version == 1, permit.issuer == "buildroulette.operator.v1",
              OperatorActionValidation.uuid(permit.operator_request_id) != nil,
              permit.action_id == input.action_id, permit.claim_id == input.claim_id,
              permit.mission_id == input.mission_id, permit.project_root == input.project_root,
              permit.root_scope == input.root_scope,
              permit.workspace_root == input.workspace_root, permit.project_device == project.device,
              permit.project_inode == project.inode, permit.workspace_device == workspace.device,
              permit.workspace_inode == workspace.inode, permit.policy_sha256 == policySHA256,
              permit.request_sha256 == requestDigest,
              let issued = OperatorActionValidation.date(permit.issued_at),
              let expires = OperatorActionValidation.date(permit.expires_at),
              issued <= now, now < expires, expires.timeIntervalSince(issued) <= 1800 else {
            throw OperatorActionValidation.Failure.unsafe
        }
    }

    private static let packetWriteNames: Set<String> = ["HANDOFF.md", "BUSINESS_ANALYSIS.md", "OUTREACH_PLAN.md",
        "DESIGN_REVIEW.md", "DEVELOPMENT_PLAN.md", "RELEASE_REVIEW.md", "ACTION_PLAN.md", "BUILD_SCOPE.md",
        "BUILD_VERIFICATION.md", "RESEARCH.md", "PLAN.md", "ARCHITECTURE.md", "BUILD_NOTES.md", "REVIEW.md"]

    static func checkInvocation(_ id: String, input: OperatorActionRequest, target: String, authorities: String) -> CheckInvocation {
        if id == "git_diff_check" {
            return .init(executable: "/usr/bin/git", arguments: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                "diff", "--check", "--no-ext-diff", "--no-textconv"], workspace: target,
                authorityRoot: authorities, projectRoot: input.project_root, timeoutSeconds: 120)
        }
        // SwiftPM cannot apply a nested manifest sandbox inside the mandatory host
        // sandbox. Suppress only its inner layer; wrapped() remains required before launch.
        return .init(executable: "/usr/bin/swift", arguments: ["test", "--disable-sandbox", "--disable-automatic-resolution", "--skip-update",
            "--disable-netrc", "--disable-keychain", "--jobs", "2", "--no-parallel",
            "--scratch-path", ".operator-action/build", "--cache-path", ".operator-action/cache",
            "--config-path", ".operator-action/config", "--security-path", ".operator-action/security"],
            workspace: target, authorityRoot: authorities, projectRoot: input.project_root, timeoutSeconds: 300)
    }

    static func wrapped(_ invocation: CheckInvocation) -> SeatbeltSandbox.Wrap {
        // An application source check runs at project_root itself; do not accidentally deny
        // the granted root. Its authority directory remains disjoint and always denied.
        let deniedRoots = [invocation.authorityRoot] + (disjoint(invocation.workspace, invocation.projectRoot) ? [invocation.projectRoot] : [])
        #if os(macOS)
        if let home = ToolContext.canonicalize(NSHomeDirectory()), invocation.workspace.hasPrefix(home + "/") {
            // The shared wrapper rejects deny roots that contain the workspace. A worker's
            // private Workspace lives under home, so add the broad denial followed by the
            // exact workspace exception explicitly; never drop the home-read restriction.
            let policy = SandboxPolicy(enabled: true, denyNetwork: true, confineWrites: true,
                forbiddenReadPaths: deniedRoots,
                denyRealHomeReads: false, allowSharedTemporaryWrites: false,
                denyCrossProcessAccess: true, allowBackgroundProcesses: false)
            guard case .wrapped(let executable, var args) = SeatbeltSandbox.wrap(
                launchPath: invocation.executable, args: invocation.arguments, root: invocation.workspace,
                policy: policy, cwd: invocation.workspace), executable == "/usr/bin/sandbox-exec",
                  args.count >= 3, args[0] == "-p" else {
                return .unavailable(reason: "strict home-workspace profile unavailable")
            }
            args[1] += "\n(deny file-read* (subpath \(SeatbeltSandbox.quote(home))))"
            args[1] += "\n(allow file-read* (literal \(SeatbeltSandbox.quote(invocation.workspace))))"
            args[1] += "\n(allow file-read* (subpath \(SeatbeltSandbox.quote(invocation.workspace))))"
            return preparingCheckSandbox(.wrapped(path: executable, args: args), workspace: invocation.workspace)
        }
        #endif
        return preparingCheckSandbox(SeatbeltSandbox.wrap(launchPath: invocation.executable, args: invocation.arguments,
            root: invocation.workspace, policy: .strictAutonomous(forbiddenReadPaths: deniedRoots), cwd: invocation.workspace), workspace: invocation.workspace)
    }

    private static func preparingCheckSandbox(_ wrapped: SeatbeltSandbox.Wrap, workspace: String) -> SeatbeltSandbox.Wrap {
        #if os(macOS)
        guard case .wrapped(let executable, var arguments) = wrapped,
              executable == "/usr/bin/sandbox-exec", arguments.count >= 3, arguments[0] == "-p" else {
            return wrapped
        }
        // libdispatch asks for its own unique process identity during toolchain startup.
        // Keep the broad denial for other processes; self-inspection grants no such access.
        arguments[1] += "\n(allow process-info* (target self))"
        // Foundation prefers Darwin's shared temporary directory over TMPDIR. Making
        // that directory unreadable makes atomic replacement use its writable destination.
        // Writes remain confined to the granted workspace; no shared-temp grant is added.
        var temporary = [CChar](repeating: 0, count: 4_096)
        let count = confstr(_CS_DARWIN_USER_TEMP_DIR, &temporary, temporary.count)
        guard count > 0, count <= temporary.count,
              let sharedTemporary = ToolContext.canonicalize(String(cString: temporary)), sharedTemporary != "/" else {
            return .unavailable(reason: "cannot bind the shared temporary directory for check confinement")
        }
        arguments[1] += "\n(deny file-read* (subpath \(SeatbeltSandbox.quote(sharedTemporary))))"
        // The granted workspace can itself live inside Darwin's temporary tree.
        arguments[1] += "\n(allow file-read* (literal \(SeatbeltSandbox.quote(workspace))))"
        arguments[1] += "\n(allow file-read* (subpath \(SeatbeltSandbox.quote(workspace))))"
        return .wrapped(path: executable, args: arguments)
        #else
        return wrapped
        #endif
    }

    static func runSandboxedCheck(_ invocation: CheckInvocation) async -> CheckObservation {
        guard !Task.isCancelled, case .wrapped(let executable, let arguments) = wrapped(invocation) else {
            return .init(output: "", exitCode: -1, timedOut: false, cancelled: Task.isCancelled,
                         outputTruncated: false, wasSignalled: false, sandboxed: false)
        }
        do {
            let root = try ConfinedRoot(root: invocation.workspace)
            // The check's scratch area is reserved and cannot be edited using typed file actions.
            try root.makeDirectory(".operator-action/home")
            try root.makeDirectory(".operator-action/tmp")
        } catch {
            return .init(output: "", exitCode: -1, timedOut: false, cancelled: false,
                         outputTruncated: false, wasSignalled: false, sandboxed: false)
        }
        let result = await ProcessGroupRunner.runAsync(launchPath: executable, launchArgs: arguments,
            cwd: invocation.workspace, env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": invocation.workspace + "/.operator-action/home",
                "CFFIXED_USER_HOME": invocation.workspace + "/.operator-action/home",
                "TMPDIR": invocation.workspace + "/.operator-action/tmp/", "LANG": "C", "LC_ALL": "C",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"],
            timeoutSeconds: invocation.timeoutSeconds, capPerStream: maximumCheckOutputBytes / 2, graceSeconds: 1)
        return .init(output: result.combined, exitCode: result.exitCode, timedOut: result.timedOut,
            cancelled: result.cancelled, outputTruncated: result.outputTruncated,
            wasSignalled: result.wasSignalled, sandboxed: true)
    }

    private static func disjoint(_ a: String, _ b: String) -> Bool {
        a != b && !a.hasPrefix(b + "/") && !b.hasPrefix(a + "/")
    }
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func unhex(_ value: String) -> Data {
        let characters = Array(value.utf8)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(decoding: characters[$0...($0 + 1)], as: UTF8.self), radix: 16)!
        })
    }
    private static func boundedText(_ value: String, maximumBytes: Int) -> String {
        var bytes = Array(value.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let text = String(bytes: bytes, encoding: .utf8) { return text }
            bytes.removeLast()
        }
        return ""
    }
}
