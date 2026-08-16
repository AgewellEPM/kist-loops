import Foundation
import AgentCore

// Builder preflight — planned-graph / fleet-subtask / verification helpers, extracted from
// KistRunner+BuilderPreflightV2.swift to keep it under the size limit. Part of `extension KistRunner`.
extension KistRunner {
    static func builderPlannedExecutionNodeID(
        for adapter: BuilderCompatibilityAdapter
    ) -> String {
        adapter == .mission || adapter == .greatLoop ? "execution" : "build"
    }

    static func builderFleetNodeID(_ partitionID: String) -> String {
        "fleet-" + partitionID
    }

    static func builderPlannedExecutionNodeIDs(
        for adapter: BuilderCompatibilityAdapter,
        plan: BuilderPreflightPlan?
    ) -> Set<String> {
        if adapter == .fleet {
            return Set((plan?.partitions ?? []).map { builderFleetNodeID($0.id) })
        }
        return [builderPlannedExecutionNodeID(for: adapter)]
    }

    static func builderPlannedGraph(
        adapter: BuilderCompatibilityAdapter,
        goal: String,
        plan: BuilderPreflightPlan
    ) throws -> BuilderGraph {
        let executionID = builderPlannedExecutionNodeID(for: adapter)
        let writes = plan.allowedPaths.map {
            BuilderResourceClaim(path: $0, access: .write)
        }
        if adapter == .fleet {
            return try BuilderGraph(nodes: plan.partitions.map { partition in
                BuilderNode(
                    id: builderFleetNodeID(partition.id),
                    objective: "Fleet partition \(partition.id) for: \(goal)\n"
                        + "Exact paths: " + partition.paths.joined(separator: ", "),
                    resources: partition.paths.map {
                        BuilderResourceClaim(path: $0, access: .write)
                    },
                    isolation: .sandbox, role: .builder, retryLimit: 1)
            })
        }
        if adapter == .mission || adapter == .greatLoop {
            return try BuilderGraph(nodes: [
                BuilderNode(
                    id: "research", objective: "Produce exact-run read-only research for: \(goal)",
                    resources: [BuilderResourceClaim(path: ".", access: .read)],
                    isolation: .shared, role: .planner, retryLimit: 0),
                BuilderNode(
                    id: "symbolic-peel", objective: "Apply deterministic symbolic PEEL to the accepted research receipt",
                    dependencies: ["research"],
                    resources: [BuilderResourceClaim(path: ".", access: .read)],
                    isolation: .shared, role: .verifier, retryLimit: 0),
                BuilderNode(
                    id: "council", objective: "Issue a council decision bound to the accepted PEEL receipt",
                    dependencies: ["symbolic-peel"],
                    resources: [BuilderResourceClaim(path: ".", access: .read)],
                    isolation: .shared, role: .planner, retryLimit: 0),
                BuilderNode(
                    id: "task-board-projection", objective: "Project the council decision to an advisory, non-authoritative task board",
                    dependencies: ["council"],
                    resources: [BuilderResourceClaim(path: ".", access: .read)],
                    isolation: .shared, role: .coordinator, retryLimit: 0),
                BuilderNode(
                    id: executionID, objective: goal,
                    dependencies: ["task-board-projection"], resources: writes,
                    isolation: .sandbox, role: .builder, retryLimit: 1),
                BuilderNode(
                    id: "independent-review",
                    objective: "Independently review the accepted execution receipt and deterministic evidence",
                    dependencies: [executionID],
                    resources: [BuilderResourceClaim(path: ".", access: .read)],
                    isolation: .shared, role: .reviewer, retryLimit: 0),
            ])
        }
        return try BuilderGraph(nodes: [BuilderNode(
            id: executionID, objective: goal, resources: writes,
            isolation: .sandbox, role: .builder, retryLimit: 1)])
    }

    static func builderBoundedMutationAttemptGoal(_ goal: String, attempt: Int) -> String {
        guard attempt > 1 else { return goal }
        return """
        \(goal)

        Bounded mutation recovery attempt \(attempt) of 2: the prior isolated attempt made zero
        declared filesystem mutations and was rolled back. Execute the same sealed operations now.
        Do not widen paths, commands, tools, or scope. Host verification remains mandatory.
        """
    }

    static func builderPlannedGraphPolicy(
        graph: BuilderGraph,
        executionNodeIDs: Set<String>
    ) -> BuilderGraphExecutionPolicy {
        .init(nodeClasses: Dictionary(uniqueKeysWithValues: graph.nodes.map {
            ($0.id, executionNodeIDs.contains($0.id) ? .mutation : .readOnly)
        }))
    }

    static func builderFleetSubtasks(
        plan: BuilderPreflightPlan,
        goal: String
    ) throws -> [FleetSubtask] {
        guard plan.adapter == BuilderCompatibilityAdapter.fleet.rawValue,
              !plan.partitions.isEmpty else {
            throw BuilderPreflightError.invalid("sealed fleet plan has no partitions")
        }
        return try plan.partitions.map { partition in
            let childPlan = try builderFleetChildVerificationPlan(
                plan: plan, nodeID: builderFleetNodeID(partition.id))
            let acceptance = childPlan.verificationCommands
                .map(\.canonicalStatement).joined(separator: " && ")
            return FleetSubtask(
                title: partition.id,
                intent: goal + "\nModify only: " + partition.paths.joined(separator: ", "),
                scopeGlobs: partition.paths,
                acceptanceCriterion: acceptance)
        }
    }

    static func builderFleetChildVerificationPlan(
        plan: BuilderPreflightPlan,
        nodeID: String
    ) throws -> BuilderPreflightPlan {
        guard plan.adapter == BuilderCompatibilityAdapter.fleet.rawValue,
              let partition = plan.partitions.first(where: {
                  builderFleetNodeID($0.id) == nodeID
              }) else {
            throw BuilderPreflightError.invalid(
                "fleet verification node has no exact sealed partition")
        }
        let paths = Set(partition.paths)
        let operations = plan.operations.filter { paths.contains($0.path) }
        guard !operations.isEmpty,
              Set(operations.map(\.path)) == paths,
              operations.count == paths.count else {
            throw BuilderPreflightError.invalid(
                "fleet verification partition does not map exactly to planned operations")
        }
        let commands = try operations.map { operation -> BuilderPreflightCommand in
            let path = try builderNormalizePreflightPath(operation.path)
            guard path == operation.path else {
                throw BuilderPreflightError.invalid(
                    "fleet child verification path is not canonical")
            }
            let arguments: [String]
            switch operation.kind {
            case .delete:
                arguments = ["!", "-e", path, "-a", "!", "-L", path]
            case .create, .modify:
                arguments = ["-f", path, "-a", "!", "-L", path]
            }
            return BuilderPreflightCommand(
                executable: "/bin/test", arguments: arguments, timeoutSeconds: 30)
        }
        return BuilderPreflightPlan(
            schemaVersion: plan.schemaVersion,
            adapter: plan.adapter,
            operations: operations,
            verificationCommands: commands,
            partitions: [partition])
    }

    static func builderRunPlannedVerification(
        plan: BuilderPreflightPlan,
        workspace: BuilderExecutionWorkspace,
        context: ToolContext,
        builderContractID: String,
        contractFingerprint: String,
        nodeID: String,
        wallDeadline: Date
    ) async throws -> BuilderVerifierReceipt {
        struct CommandCapture: Sendable {
            let criterionID: String
            let command: BuilderPreflightCommand
            let result: ToolResult
            let reference: BuilderTrustedCommandReference
            let gateArgumentsDigest: String
        }

        let commandTools = ToolRegistry([RunCommandTool()])
        // BuilderExecutionGovernance owns the registered, contract-bound sandbox scope for this
        // entire node-verification callback.
        // Disable only RunCommandTool's generic Seatbelt wrapper so ProcessGroupRunner applies the
        // registered, contract-bound Builder profile exactly once. Nesting sandbox-exec causes the
        // inner sandbox_apply to fail with EX_OSERR (71); it does not add confinement.
        let stagedContext = ToolContext(
            projectRoot: workspace.rootPath,
            shell: context.shell,
            sandbox: .disabled,
            authorizationScope: context.authorizationScope,
            scopeOverrideApproved: context.scopeOverrideApproved,
            skillLocations: context.skillLocations,
            skillTracker: context.skillTracker,
            auditLog: context.auditLog,
            externalReadRoots: context.externalReadRoots)
        var captures: [CommandCapture] = []
        for (index, command) in plan.verificationCommands.enumerated() {
                let remaining = Int(floor(wallDeadline.timeIntervalSinceNow))
                guard remaining > 0 else {
                    throw BuilderRunError.finalVerificationFailed(
                        "sealed verification wall-clock budget expired before command \(index + 1)")
                }
                let effectiveTimeout = max(1, min(command.timeoutSeconds, remaining))
                let arguments: [String: Any] = [
                    "executable": command.executable,
                    "args": command.arguments,
                    "cwd": ".",
                    "timeout": effectiveTimeout,
                    "allowed_exit_codes": [0],
                ]
                let gateArgumentsDigest = AuditLog.digest(arguments).1
                let result = await commandTools.execute(
                    name: "run_command", arguments: arguments, context: stagedContext)
                guard result.success,
                      result.metadata["builder_os_sandboxed"] == "true",
                      result.metadata["verification_eligible"] == "true",
                      result.metadata["timed_out"] == "false",
                      result.metadata["was_signalled"] == "false",
                      result.metadata["stdout_truncated"] == "false",
                      result.metadata["stderr_truncated"] == "false",
                      result.metadata["output_truncated"] == "false",
                      result.metadata["exit_code"] == "0",
                      let reference = result.trustedCommandReference,
                      reference.isValid,
                      reference.exitCode == 0,
                      reference.gateArgumentsDigest == gateArgumentsDigest,
                      reference.stdoutDigest.count == 64,
                      reference.stderrDigest.count == 64,
                      reference.fullStreamDigest.count == 64,
                      reference.stdoutByteCount >= 0,
                      reference.stderrByteCount >= 0 else {
                    let executionState = [
                        "success=\(result.success)",
                        "sandboxed=\(result.metadata["sandboxed"] ?? "missing")",
                        "builder_os_sandboxed=\(result.metadata["builder_os_sandboxed"] ?? "missing")",
                        "verification_eligible=\(result.metadata["verification_eligible"] ?? "missing")",
                        "exit_code=\(result.metadata["exit_code"] ?? "missing")",
                        "timed_out=\(result.metadata["timed_out"] ?? "missing")",
                        "was_signalled=\(result.metadata["was_signalled"] ?? "missing")",
                        "stdout_truncated=\(result.metadata["stdout_truncated"] ?? "missing")",
                        "stderr_truncated=\(result.metadata["stderr_truncated"] ?? "missing")",
                        "output_truncated=\(result.metadata["output_truncated"] ?? "missing")",
                        "trusted_reference=\(result.trustedCommandReference?.isValid == true)",
                    ].joined(separator: ",")
                    throw BuilderRunError.finalVerificationFailed(
                        "sealed verification command failed: \(command.canonicalStatement); "
                            + executionState + "; " + (result.error ?? result.output))
                }
                captures.append(.init(
                    criterionID: "command-\(index + 1)", command: command,
                    result: result, reference: reference,
                    gateArgumentsDigest: gateArgumentsDigest))
        }
        let subjectDigest = PlanExecuteLoop.governedWorkspaceDigest(projectRoot: workspace.rootPath)
        guard !subjectDigest.hasPrefix("unavailable:") else {
            throw BuilderRunError.finalVerificationFailed(
                "staged workspace digest is unavailable after deterministic verification")
        }
        let evidence = captures.map { capture in
            return BuilderCommandEvidenceReceipt.boundPrehashed(
                tool: "run_command", verifierStatus: .passed, exitCode: 0,
                allowedExitCodes: "0", semanticStatus: "success",
                argsFingerprint: capture.gateArgumentsDigest,
                outputDigest: capture.reference.fullStreamDigest,
                boundedRedactedOutputExcerpt: capture.result.output,
                subjectDigestAfter: subjectDigest,
                contractFingerprint: contractFingerprint,
                trustedCommandReference: capture.reference)
        }
        guard evidence.count == plan.verificationCommands.count,
              zip(evidence, captures).allSatisfy({ receipt, capture in
                  receipt.isBound(contractFingerprint: contractFingerprint,
                                  subjectDigest: subjectDigest)
                      && receipt.argsFingerprint == capture.reference.gateArgumentsDigest
                      && receipt.trustedCommandReference?.observationID
                        == capture.reference.observationID
              }),
              Set(evidence.compactMap { $0.trustedCommandReference?.observationID }).count
                == evidence.count else {
            throw BuilderRunError.finalVerificationFailed(
                "deterministic command receipts are missing, reused, or not bound to the selected child contract")
        }
        let checks = captures.map {
            BuilderCheckReceipt(
                name: $0.criterionID,
                passed: true,
                details: $0.command.sealedCriterionStatement
                    + ";gate_arguments_digest=\($0.gateArgumentsDigest);"
                    + "stdout_sha256=\($0.reference.stdoutDigest);"
                    + "stdout_bytes=\($0.reference.stdoutByteCount);"
                    + "stderr_sha256=\($0.reference.stderrDigest);"
                    + "stderr_bytes=\($0.reference.stderrByteCount)")
        }
        return BuilderVerifierReceipt(
            scope: .node(nodeID), provider: "host", model: "deterministic",
            deterministic: true, passed: true, checks: checks,
            verificationSubject: workspace.rootPath,
            baselineDigest: workspace.attestation.governedRootDigest,
            subjectDigest: subjectDigest,
            contractFingerprint: contractFingerprint,
            completionMode: .build, commandEvidence: evidence,
            verifiedAt: Date())
    }

    static func builderModelIdentity(_ canonical: String) throws -> BuilderModelIdentity {
        let pieces = canonical.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
            throw BuilderPreflightError.invalid("identity is not provider:model: \(canonical)")
        }
        return try BuilderModelIdentity(providerID: String(pieces[0]), modelID: String(pieces[1]))
    }

    static func builderRejectUnknownKeys(
        _ object: [String: Any], allowed: Set<String>, at location: String
    ) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw BuilderPreflightError.invalid(
                "unknown keys at \(location): \(unknown.sorted().joined(separator: ", "))")
        }
    }

    static func builderNormalizePreflightPath(_ raw: String) throws -> String {
        let value = raw.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 1_024,
              !value.hasPrefix("/"), !value.hasPrefix("~"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw BuilderPreflightError.invalid("unsupported relative path: \(raw)")
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let protected: Set<String> = [
            ".", "..", ".git", ".kist", ".mythos", ".build", "node_modules",
            "vendor", "deriveddata", ".env", ".mcp.json",
        ]
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty && !protected.contains(component.lowercased())
              }) else {
            throw BuilderPreflightError.invalid("protected or non-normal path: \(raw)")
        }
        return components.joined(separator: "/")
    }

    static func builderProjectRootIdentity(_ raw: String) throws -> String {
        guard let canonical = ToolContext.canonicalize(raw) else {
            throw BuilderPreflightError.invalid("project root does not exist")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: canonical)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device = attributes[.systemNumber],
              let inode = attributes[.systemFileNumber] else {
            throw BuilderPreflightError.invalid("project root filesystem identity is unavailable")
        }
        return BuilderEvidenceDigest.sha256(
            [canonical, String(describing: device), String(describing: inode)]
                .joined(separator: "\u{0}"))
    }

    static func builderValidatePreflightAncestors(
        path: String, projectRoot: URL
    ) throws {
        let components = path.split(separator: "/").map(String.init)
        var cursor = projectRoot
        for (index, component) in components.enumerated() {
            cursor.appendPathComponent(component)
            let values = try? cursor.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
            ])
            if values?.isSymbolicLink == true {
                throw BuilderPreflightError.invalid(
                    "symbolic-link path component is refused: "
                        + components.prefix(index + 1).joined(separator: "/"))
            }
            let exists = FileManager.default.fileExists(atPath: cursor.path)
            if exists, index < components.count - 1, values?.isDirectory != true {
                throw BuilderPreflightError.invalid(
                    "non-directory path ancestor is refused: "
                        + components.prefix(index + 1).joined(separator: "/"))
            }
            if !exists { break }
        }
    }

    static func builderHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func builderReadOnlyPreflightInventory(projectRoot: String, goal: String) throws -> String {
        guard let canonicalRoot = ToolContext.canonicalize(projectRoot) else {
            throw BuilderPreflightError.invalid("project inventory root cannot be canonicalized")
        }
        let rootURL = URL(
            fileURLWithPath: canonicalRoot, isDirectory: true
        ).standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }) else {
            throw BuilderPreflightError.invalid("project inventory cannot be enumerated")
        }
        let denied = ["node_modules/", "vendor/", ".build/", "DerivedData/"]
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard paths.count < 2_000 else { break }
            let candidateComponents = url.standardizedFileURL.pathComponents
            guard candidateComponents.count > rootComponents.count,
                  candidateComponents.starts(with: rootComponents) else {
                throw BuilderPreflightError.invalid(
                    "project inventory enumerated a path outside its canonical root")
            }
            let relativeComponents = candidateComponents.dropFirst(rootComponents.count)
            guard relativeComponents.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
            }) else {
                throw BuilderPreflightError.invalid(
                    "project inventory produced a non-normal relative path")
            }
            let relative = relativeComponents.joined(separator: "/")
            if denied.contains(where: relative.hasPrefix) {
                enumerator.skipDescendants(); continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  (values?.fileSize ?? 0) <= 2_000_000 else { continue }
            paths.append(relative)
        }
        paths.sort()
        let terms = Set(goal.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 4 }.map(String.init))
        var excerptBytes = 0
        var excerpts: [String] = []
        for path in paths where excerpts.count < 8 && excerptBytes < 96_000 {
            let lowered = path.lowercased()
            guard terms.contains(where: lowered.contains) else { continue }
            let url = rootURL.appendingPathComponent(path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = try handle.read(upToCount: min(12_000, 96_000 - excerptBytes)) ?? Data()
            try? handle.close()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
            excerptBytes += data.count
            excerpts.append("--- \(path) ---\n\(text)")
        }
        return "FILES\n" + paths.joined(separator: "\n")
            + (excerpts.isEmpty ? "" : "\n\nMATCHED EXCERPTS\n" + excerpts.joined(separator: "\n"))
    }
}
