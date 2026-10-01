import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Verification receipts, deterministic replay, completion verdict, digests — static helpers extracted from PlanExecuteLoop.swift to keep the loop core under the size limit.
extension PlanExecuteLoop {
    static func mutationFrontierOrdinal(in control: ReasoningControlState) -> Int? {
        control.planNodes.values.flatMap { $0.invocationReceipts ?? [] }.compactMap { receipt in
            guard receipt.effectObservation.mutation != .none else { return nil }
            return receipt.supportingCommandReceipt?.captureOrdinal ?? receipt.executionPhase
        }.max()
    }

    static func nextCaptureOrdinal(in control: ReasoningControlState) -> Int {
        let maximum = control.planNodes.values.flatMap { $0.invocationReceipts ?? [] }.compactMap {
            $0.supportingCommandReceipt?.captureOrdinal ?? $0.executionPhase
        }.max() ?? 0
        return maximum + 1
    }

    static func rejectedPlanAttemptReceipt(
        plan: ExecutablePlan,
        providerID: String?,
        modelID: String?,
        validationErrors: [String],
        ordinal: Int
    ) -> RejectedPlanAttemptReceipt {
        func argumentType(_ value: Any) -> String {
            switch value {
            case is NSNull: return "null"
            case is String: return "string"
            case is [String: Any]: return "object"
            case is [Any]: return "array"
            case let number as NSNumber:
                let encoding = String(cString: number.objCType)
                return encoding == "c" || encoding == "B" ? "boolean" : "number"
            default: return "unknown"
            }
        }
        let summaries = plan.steps.map { step -> RejectedPlanStepSummary in
            let arguments: [String: Any]
            if let data = step.argumentsJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dictionary = object as? [String: Any] {
                arguments = dictionary
            } else {
                arguments = [:]
            }
            let stdinPresent = arguments.keys.contains("stdin")
            let stdin = arguments["stdin"] as? String
            return RejectedPlanStepSummary(
                stepID: step.id, tool: step.tool,
                argumentTypes: arguments.mapValues(argumentType),
                stdinPresent: stdinPresent,
                stdinByteCount: stdin?.utf8.count,
                stdinSHA256: stdin.map(secureDigest))
        }
        let canonicalPlanShape = ([plan.goal] + plan.steps.map {
            [$0.id, $0.tool, $0.argumentsJSON, $0.dependsOn.joined(separator: ",")]
                .joined(separator: "\u{0}")
        }).joined(separator: "\u{1e}")
        return RejectedPlanAttemptReceipt(
            planFingerprint: secureDigest(canonicalPlanShape),
            providerID: providerID, modelID: modelID,
            stepSummaries: summaries, validationErrors: validationErrors,
            ordinal: ordinal)
    }

    static func metadataExitCodes(_ value: String?) -> [Int] {
        guard let value else { return [] }
        return value.split(separator: ",").compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.sorted()
    }

    static func fixtureInputPath(_ arguments: [String: Any]) -> String? {
        let argv = (arguments["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let flag = argv.firstIndex(of: "--input"), argv.indices.contains(flag + 1) else { return nil }
        let value = argv[flag + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "-", value != "/dev/stdin", !value.hasPrefix("/dev/fd/") else {
            return nil
        }
        return value
    }

    static func isRealGovernedFixture(_ path: String, arguments: [String: Any], projectRoot: String) -> Bool {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let cwdText = (arguments["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd: URL
        if let cwdText, !cwdText.isEmpty {
            cwd = cwdText.hasPrefix("/")
                ? URL(fileURLWithPath: cwdText, isDirectory: true)
                : URL(fileURLWithPath: cwdText, isDirectory: true, relativeTo: root)
        } else {
            cwd = root
        }
        let candidate = (path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: path, relativeTo: cwd))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// Shape/content-size preflight without reading payload bytes. The live read still happens only
    /// after ToolGate authorization, on ConfinedRoot's stable O_NOFOLLOW descriptor.
    static func isRealGovernedStdinPath(_ path: String, arguments: [String: Any],
                                        projectRoot: String) -> Bool {
        guard let canonicalRoot = ToolContext.canonicalize(projectRoot),
              let confined = try? ConfinedRoot(root: canonicalRoot) else { return false }
        let cwdText = (arguments["cwd"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unresolvedCwd = (cwdText?.isEmpty == false)
            ? (cwdText!.hasPrefix("/") ? cwdText! : (canonicalRoot as NSString).appendingPathComponent(cwdText!))
            : canonicalRoot
        guard let cwd = ToolContext.canonicalize(unresolvedCwd),
              let relative = try? RunCommandTool.normalizedGovernedStdinPath(
                path, cwd: cwd, projectRoot: confined.rootPath),
              let metadata = try? confined.fileMetadata(relative) else { return false }
        return metadata.isRegular && metadata.bytes > 0 && metadata.bytes <= RunCommandTool.maxStdinBytes
    }

    static func hasValidStandardInputEvidence(arguments: [String: Any],
                                              metadata: [String: String],
                                              projectRoot: String) -> Bool {
        // Backwards compatibility for in-process/custom run_command implementations that predate
        // typed stdin metadata. Only inline bytes can be derived safely from exact arguments; a file
        // source is never inferred without RunCommandTool's same-FD receipt.
        if metadata["stdin_source_kind"] == nil,
           arguments["stdin_path"] == nil,
           let stdin = arguments["stdin"] as? String {
            let data = Data(stdin.utf8)
            guard !data.isEmpty else { return false }
            if let count = metadata["stdin_byte_count"].flatMap(Int.init), count != data.count {
                return false
            }
            if let digest = metadata["stdin_sha256"], digest != RunCommandTool.sha256(data) {
                return false
            }
            return true
        }
        guard let kindText = metadata["stdin_source_kind"],
              let kind = PlanStandardInputSourceKind(rawValue: kindText),
              kind != .none,
              let digest = metadata["stdin_sha256"], digest.count == 64,
              let byteCount = Int(metadata["stdin_byte_count"] ?? ""), byteCount > 0,
              byteCount <= RunCommandTool.maxStdinBytes else { return false }
        switch kind {
        case .none:
            return false
        case .inline:
            guard arguments["stdin_path"] == nil,
                  let stdin = arguments["stdin"] as? String else { return false }
            let data = Data(stdin.utf8)
            return data.count == byteCount && RunCommandTool.sha256(data) == digest
                && metadata["stdin_relative_path"] == nil
        case .governedPath:
            guard arguments["stdin"] == nil,
                  let path = arguments["stdin_path"] as? String,
                  let relativePath = metadata["stdin_relative_path"], !relativePath.isEmpty,
                  isRealGovernedStdinPath(path, arguments: arguments, projectRoot: projectRoot) else {
                return false
            }
            return true
        }
    }

    static func makeFinalVerificationReceipt(
        replay: DeterministicVerificationReplay,
        result: ToolResult,
        missionInstanceID: String,
        governedWorkspaceDigest: String,
        completionContractFingerprint: String,
        executionPolicyFingerprint: String,
        contractID: String,
        captureOrdinal: Int = 1,
        mutationFrontierOrdinal: Int? = nil,
        obligationsFingerprint: String = "",
        workspaceManifestDigest: String = "",
        canonicalFunctionalObjectiveFingerprint: String? = nil,
        workspaceManifestPolicyFingerprint: String? = nil,
        workspaceManifestRevision: Int? = nil,
        planID: String? = nil,
        planRevision: Int? = nil,
        workspaceActionReceiptDigest: String? = nil,
        canonicalArguments: [String: Any]? = nil
    ) -> PlanFinalVerificationReceipt? {
        let expected = configuredExitCodes(replay.arguments["allowed_exit_codes"])
        let observedAllowed = metadataExitCodes(result.metadata["allowed_exit_codes"])
        // Name the clause that refuses to mint (0.17.63): a silent nil here surfaced only as
        // "final deterministic replay receipt is missing" after the files were already committed.
        func refuse(_ clause: String) -> PlanFinalVerificationReceipt? {
            FileHandle.standardError.write(Data(("final receipt not minted: \(clause)\n").utf8))
            return nil
        }
        guard replay.tool == "run_command" else { return refuse("tool=\(replay.tool)") }
        guard expected == [0] else { return refuse("replay allowed_exit_codes=\(expected)") }
        guard observedAllowed == [0] else { return refuse("observed allowed_exit_codes=\(observedAllowed)") }
        guard result.metadata["verification_eligible"]?.lowercased() == "true" else {
            return refuse("verification_eligible=\(result.metadata["verification_eligible"] ?? "nil")")
        }
        guard let actual = Int(result.metadata["exit_code"] ?? ""), actual == 0 else {
            return refuse("exit_code=\(result.metadata["exit_code"] ?? "nil")")
        }
        guard let trustedCommandReference = result.trustedCommandReference else {
            return refuse("trustedCommandReference missing")
        }
        guard trustedCommandReference.isValid else { return refuse("trustedCommandReference invalid") }
        guard trustedCommandReference.exitCode == actual else { return refuse("reference.exitCode") }
        // The gate digested what the registry actually ran: the tool's CANONICAL view of the replay
        // arguments (a sealed wrapper binds the frozen timeout, or the sealed command itself). The
        // recipe stores the durable normalized form, so compare against the canonical view when the
        // caller supplies it (0.17.63: this clause refused every host replay of a sealed verifier).
        let gateSubject = canonicalArguments ?? replay.arguments
        guard trustedCommandReference.gateArgumentsDigest == AuditLog.digest(gateSubject).1 else {
            return refuse("gateArgumentsDigest≠digest(canonical replay arguments) keys=\(gateSubject.keys.sorted())")
        }
        let executable = (replay.arguments["executable"] as? String)
            ?? (replay.arguments["command"] as? String) ?? ""
        guard !executable.isEmpty else { return nil }
        let argv = (replay.arguments["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let standardInputSource = durableStandardInputSource(
            arguments: replay.arguments, metadata: result.metadata),
              standardInputSource == replay.durableRecipe.standardInputSource else { return nil }
        let stdout = result.metadata["stdout"] ?? result.output
        let stderr = result.metadata["stderr"] ?? ""
        let canonicalArguments = canonicalReceiptValue(
            durableCommandArguments(replay.arguments, source: standardInputSource))
        var receipt = PlanFinalVerificationReceipt(
            missionInstanceID: missionInstanceID,
            contractID: contractID,
            stepID: replay.stepID,
            tool: replay.tool,
            invocation: PlanFinalVerificationInvocation(
                executable: executable, argv: argv,
                workingDirectory: replay.arguments["cwd"] as? String,
                hasStandardInput: standardInputSource.kind != .none,
                standardInputDigest: standardInputSource.sha256,
                standardInputSourceKind: standardInputSource.kind,
                standardInputRelativePath: standardInputSource.relativePath,
                standardInputByteCount: standardInputSource.byteCount),
            commandFingerprint: durableCommandFingerprint(
                tool: replay.tool, canonicalArgumentsJSON: canonicalArguments,
                source: standardInputSource),
            expectedExitCode: 0, actualExitCode: actual,
            // Every consumer (ship pipeline, builder admission, accepted-run persistence) compares
            // this to the trusted reference's fullStreamDigest — a composite over the stream digests
            // and byte counts, never equal to a digest of the text itself. Bind to the reference
            // (0.17.63: this mismatch refused every real final receipt after the loop minted it).
            outputDigest: trustedCommandReference.fullStreamDigest,
            boundedRedactedOutputExcerpt: standardInputSource.kind == .none
                ? boundedRedactedOutput(stdout + (stderr.isEmpty ? "" : "\n" + stderr))
                : SecretMasker.marker + " stdin-bearing command output suppressed",
            governedWorkspaceDigest: governedWorkspaceDigest,
            completionContractFingerprint: completionContractFingerprint,
            executionPolicyFingerprint: executionPolicyFingerprint,
            verifiedAt: Date(), freshAfterMutationFrontier: true,
            captureOrdinal: captureOrdinal,
            mutationFrontierOrdinal: mutationFrontierOrdinal,
            obligationsFingerprint: obligationsFingerprint,
            workspaceManifestDigest: workspaceManifestDigest,
            canonicalFunctionalObjectiveFingerprint:
                canonicalFunctionalObjectiveFingerprint,
            workspaceManifestPolicyFingerprint:
                workspaceManifestPolicyFingerprint,
            workspaceManifestRevision: workspaceManifestRevision,
            planID: planID,
            planRevision: planRevision,
            workspaceActionReceiptDigest: workspaceActionReceiptDigest,
            trustedCommandReference: trustedCommandReference)
        receipt.evidenceDigest = receipt.computedEvidenceDigest
        return receipt
    }

    static func canonicalReceiptValue(_ value: Any) -> String {
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        if let string = value as? String,
           let data = try? JSONSerialization.data(withJSONObject: [string]),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return String(reflecting: value)
    }

    static func boundedRedactedOutput(_ raw: String, limit: Int = 2_000) -> String {
        var redacted = raw.replacingOccurrences(
            of: #"(?i)(authorization\s*:\s*bearer\s+)[^\s]+"#,
            with: "$1[REDACTED]", options: .regularExpression)
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\b(api[_-]?key|token|secret|password)\b(\s*[=:]\s*)[^\s,;]+"#,
            with: "$1$2[REDACTED]", options: .regularExpression)
        redacted = redacted.replacingOccurrences(
            of: #"\bsk-[A-Za-z0-9_-]{12,}\b"#, with: "[REDACTED]", options: .regularExpression)
        return String(redacted.prefix(limit))
    }

    /// R6: reconstruct the execution trajectory (in order) as `ActionRecord`s so the deterministic
    /// `CompletionVerifier` can gate the plan's "done". CRITICAL for a run_command step (the build/test
    /// the gate looks for): the args are RESOLVED first (`${id}` refs → the real command via the same
    /// `resolveArguments` the executor used — so a `${E1}`-chained `swift test` is recognized) and its
    /// command fingerprint is UNTRUNCATED (the generic 40-char repeat-detection fingerprint clips the
    /// build verb off `cd <long path> && swift build` and wrongly fails a genuinely-built run). Both
    /// were review-caught false-negatives that over-blocked done runs.
    static func verifyTrajectory(plan: ExecutablePlan, exec: PlanExecution) -> [ActionRecord] {
        let stepById = Dictionary(plan.steps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A phase is one concurrently-launched dependency wave (a retry receives a fresh later phase).
        // A verifier in the same phase as a possible source mutation has no happens-before relation to
        // that mutation, so it is deliberately downgraded. Legacy/manual StepResults have nil phases and
        // retain their historical sequential-array semantics.
        let mutatingPhases = Set(exec.attemptResults.compactMap { result -> Int? in
            guard let phase = result.executionPhase,
                  (result.effectObservation?.requiresBuildVerification ?? false) else { return nil }
            return phase
        })
        let allMutatingPhases = Set(exec.attemptResults.compactMap { result -> Int? in
            guard (result.effectObservation?.mutation ?? .unknownTarget) != .none else { return nil }
            return result.executionPhase
        })
        return exec.attemptResults.map { r in
            let resolved: [String: Any] = stepById[r.stepId]
                .map { ExecutablePlan.resolveArguments($0.argumentsJSON, outputs: exec.outputs) } ?? [:]
            let fingerprint = r.argsFingerprint ?? (r.tool == "run_command"
                ? Self.commandFingerprint(resolved)                       // full command, classifiable
                : TrajectoryAnalyzer.fingerprint(resolved))
            let observed = r.effectObservation
                ?? ToolEffectCatalog.observe(tool: r.tool, arguments: resolved, outcomeMetadata: r.metadata)
            let effect: ToolEffectObservation
            if let phase = r.executionPhase,
               (mutatingPhases.contains(phase) && observed.verification == .buildOrTest)
                || (allMutatingPhases.contains(phase) && observed.verification == .dataValidation) {
                effect = ToolEffectObservation(mutation: observed.mutation,
                                               verification: .nonVerifyingCommand,
                                               progress: observed.progress,
                                               mutationEvidence: observed.mutationEvidence)
            } else {
                effect = observed
            }
            return ActionRecord(tool: r.tool, argsFingerprint: fingerprint, success: r.success,
                                failureDetail: r.success ? nil : r.error,
                                effectObservation: effect)
        }
    }

    struct ReplayCapabilityBinding {
        let resolvedExecutable: String
        let workingDirectory: String
        let authorizationFingerprint: String
        let toolSchemaFingerprint: String
        let executableIdentity: String
        let capabilityFingerprint: String
    }

    static func durableStandardInputSource(
        arguments: [String: Any], metadata: [String: String]
    ) -> DurablePlanStandardInputSource? {
        let kind = metadata["stdin_source_kind"]
            .flatMap(PlanStandardInputSourceKind.init(rawValue:))
            ?? (arguments["stdin"] == nil && arguments["stdin_path"] == nil
                ? PlanStandardInputSourceKind.none : nil)
        guard let kind else { return nil }
        let digest = metadata["stdin_sha256"]
        let count = Int(metadata["stdin_byte_count"] ?? "") ?? 0
        switch kind {
        case .none:
            guard arguments["stdin"] == nil, arguments["stdin_path"] == nil,
                  digest == nil, count == 0, metadata["stdin_relative_path"] == nil else { return nil }
            return DurablePlanStandardInputSource.none
        case .inline:
            guard arguments["stdin_path"] == nil,
                  let stdin = arguments["stdin"] as? String,
                  let digest, digest == RunCommandTool.sha256(Data(stdin.utf8)),
                  count == stdin.utf8.count,
                  metadata["stdin_relative_path"] == nil else { return nil }
            return DurablePlanStandardInputSource(
                kind: .inline, sha256: digest, byteCount: count)
        case .governedPath:
            guard arguments["stdin"] == nil, arguments["stdin_path"] is String,
                  let digest, digest.count == 64,
                  (0...RunCommandTool.maxStdinBytes).contains(count),
                  let relativePath = metadata["stdin_relative_path"], !relativePath.isEmpty else { return nil }
            return DurablePlanStandardInputSource(
                kind: .governedPath, relativePath: relativePath, sha256: digest,
                byteCount: count,
                rootPolicyVersion: DurablePlanStandardInputSource.currentRootPolicyVersion)
        }
    }

    /// Arguments safe to persist. Replay-only bindings are regenerated from the typed source, and
    /// inline bytes are removed entirely (the typed digest/count remains but resume is forbidden).
    static func durableCommandArguments(
        _ arguments: [String: Any], source: DurablePlanStandardInputSource
    ) -> [String: Any] {
        var durable = arguments
        durable.removeValue(forKey: "expected_stdin_sha256")
        durable.removeValue(forKey: "expected_stdin_byte_count")
        if source.kind == .inline { durable.removeValue(forKey: "stdin") }
        return durable
    }

    static func durableCommandFingerprint(
        tool: String, canonicalArgumentsJSON: String,
        source: DurablePlanStandardInputSource
    ) -> String {
        secureDigest([
            tool, canonicalArgumentsJSON, source.kind.rawValue,
            source.relativePath ?? "-", source.sha256 ?? "-", String(source.byteCount),
            source.rootPolicyVersion ?? "-",
        ].joined(separator: "\u{0}"))
    }

    static func replayCapabilityBinding(
        tool: String,
        arguments: [String: Any],
        context: ToolContext,
        tools: ToolRegistry
    ) -> ReplayCapabilityBinding? {
        guard tool == "run_command", context.shell.enabled,
              RunCommandTool.argumentValidationIssue(arguments, planPreflight: true) == nil,
              arguments["background"] as? Bool != true,
              configuredExitCodes(arguments["allowed_exit_codes"]) == [0],
              context.authorizationScope?.toolBlockReason(
                tool: tool, arguments: arguments, scopeApproved: false) == nil,
              let executable = arguments["executable"] as? String,
              let workingDirectory = try? context.resolvedPath(
                (arguments["cwd"] as? String) ?? ".", mustExist: true),
              let resolvedExecutable = RunCommandTool.resolveExecutable(
                executable, env: RunCommandTool.scrubbedEnvironment(), cwd: workingDirectory) else {
            return nil
        }
        let argv = arguments["args"] as? [String] ?? []
        if RunCommandTool.interpreterRefusalReason(
            resolvedPath: resolvedExecutable, args: argv) != nil { return nil }
        let basename = (resolvedExecutable as NSString).lastPathComponent
        if !context.shell.allow.isEmpty && !context.shell.allow.contains(basename) { return nil }
        let rendered = ([resolvedExecutable] + argv).joined(separator: " ")
        if context.shell.deny.contains(where: rendered.contains) { return nil }

        guard let registered = tools.all().first(where: { $0.name == tool }) else { return nil }
        let schema = registered.parameters.sorted { $0.name < $1.name }.map {
            [$0.name, $0.type, $0.required ? "required" : "optional", $0.description]
                .joined(separator: "|")
        }.joined(separator: "\n")
        let toolSchemaFingerprint = secureDigest(
            registered.name + "\u{0}" + registered.description + "\u{0}" + schema)

        var executableStat = stat()
        guard lstat(resolvedExecutable, &executableStat) == 0 else { return nil }
        let executableIdentity = [
            resolvedExecutable, String(executableStat.st_dev), String(executableStat.st_ino),
            String(executableStat.st_mode), String(executableStat.st_size),
        ].joined(separator: "|")

        let authorization: String
        if let scope = context.authorizationScope {
            authorization = [
                scope.kind.rawValue, scope.gate.rawValue, scope.reason,
                scope.allowedActions.sorted().joined(separator: ","),
                scope.blockedActions.sorted().joined(separator: ","),
                scope.requiredEvidence.sorted().joined(separator: ","),
                "scopeOverrideApproved=false",
            ].joined(separator: "|")
        } else {
            authorization = "scope:none|scopeOverrideApproved=false"
        }
        let authorizationFingerprint = secureDigest(authorization)
        let shellBinding = [
            context.shell.enabled ? "shell:on" : "shell:off",
            context.shell.autoApprove ? "auto:on" : "auto:off",
            context.shell.sandboxed ? "shell-sandbox:on" : "shell-sandbox:off",
            context.shell.approval == nil ? "approval:none" : "approval:present",
            "allow=" + context.shell.allow.sorted().joined(separator: ","),
            "deny=" + context.shell.deny.joined(separator: "\u{1f}"),
            context.sandbox.enabled ? "sandbox:on" : "sandbox:off",
            context.sandbox.denyNetwork ? "network:deny" : "network:allow",
            context.sandbox.confineWrites ? "writes:confined" : "writes:unconfined",
            "env-policy=" + RunCommandTool.envAllowlist.sorted().joined(separator: ","),
        ].joined(separator: "\u{0}")
        let capabilityFingerprint = secureDigest([
            canonicalReceiptValue(arguments), resolvedExecutable, executableIdentity,
            workingDirectory, toolSchemaFingerprint, authorizationFingerprint, shellBinding,
        ].joined(separator: "\u{0}"))
        return ReplayCapabilityBinding(
            resolvedExecutable: resolvedExecutable, workingDirectory: workingDirectory,
            authorizationFingerprint: authorizationFingerprint,
            toolSchemaFingerprint: toolSchemaFingerprint,
            executableIdentity: executableIdentity,
            capabilityFingerprint: capabilityFingerprint)
    }

    static func restoreVerificationReplay(
        _ recipe: DurablePlanVerificationRecipe,
        completionContractFingerprint: String,
        obligationsFingerprint: String,
        executionPolicyFingerprint: String,
        workspaceManifestDigest: String,
        context: ToolContext,
        tools: ToolRegistry
    ) -> DeterministicVerificationReplay? {
        guard let canonicalProjectRoot = ToolContext.canonicalize(context.projectRoot),
              let standardInputSource = recipe.standardInputSource,
              standardInputSource.kind != .inline,
              recipe.completionContractFingerprint == completionContractFingerprint,
              recipe.obligationsFingerprint == obligationsFingerprint,
              recipe.executionPolicyFingerprint == executionPolicyFingerprint,
              recipe.workspaceManifestDigest == workspaceManifestDigest,
              let data = recipe.canonicalArgumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              canonicalReceiptValue(arguments) == recipe.canonicalArgumentsJSON,
              commandFingerprint(arguments) == recipe.argsFingerprint,
              durableCommandFingerprint(
                tool: recipe.tool, canonicalArgumentsJSON: recipe.canonicalArgumentsJSON,
                source: standardInputSource) == recipe.commandFingerprint,
              (arguments["args"] as? [String] ?? []) == recipe.argv,
              configuredExitCodes(arguments["allowed_exit_codes"]) == recipe.allowedExitCodes,
              let capability = replayCapabilityBinding(
                tool: recipe.tool, arguments: arguments, context: context, tools: tools),
              capability.resolvedExecutable == recipe.resolvedExecutable,
              capability.workingDirectory == recipe.workingDirectory,
              capability.authorizationFingerprint == recipe.authorizationFingerprint,
              capability.toolSchemaFingerprint == recipe.toolSchemaFingerprint,
              capability.executableIdentity == recipe.executableIdentity,
              capability.capabilityFingerprint == recipe.capabilityFingerprint else { return nil }

        var replayArguments = arguments
        switch standardInputSource.kind {
        case .none:
            guard arguments["stdin"] == nil, arguments["stdin_path"] == nil,
                  standardInputSource.relativePath == nil,
                  standardInputSource.sha256 == nil,
                  standardInputSource.byteCount == 0 else { return nil }
        case .inline:
            return nil
        case .governedPath:
            guard arguments["stdin"] == nil,
                  arguments["stdin_path"] is String,
                  let path = standardInputSource.relativePath, !path.isEmpty,
                  let digest = standardInputSource.sha256, digest.count == 64,
                  (0...RunCommandTool.maxStdinBytes).contains(standardInputSource.byteCount),
                  standardInputSource.rootPolicyVersion
                    == DurablePlanStandardInputSource.currentRootPolicyVersion,
                  let normalized = try? RunCommandTool.normalizedGovernedStdinPath(
                    arguments["stdin_path"] as! String,
                    cwd: capability.workingDirectory,
                    projectRoot: canonicalProjectRoot),
                  normalized == path else { return nil }
            replayArguments["expected_stdin_sha256"] = digest
            replayArguments["expected_stdin_byte_count"] = standardInputSource.byteCount
        }
        return DeterministicVerificationReplay(
            stepID: recipe.stepID, tool: recipe.tool, arguments: replayArguments,
            fingerprint: recipe.argsFingerprint, durableRecipe: recipe)
    }

    /// Capture only a verifier whose exact executed arguments still equal the frozen plan's resolved
    /// arguments. Repaired invocations are excluded rather than reconstructed from model prose.
    static func verificationReplayCandidate(
        plan: ExecutablePlan,
        exec: PlanExecution,
        sourcePlanID: String,
        missionInstanceID: String,
        completionContractFingerprint: String,
        obligationsFingerprint: String,
        executionPolicyFingerprint: String,
        workspaceManifestDigest: String,
        proofWorkspaceDigest: String,
        context: ToolContext,
        tools: ToolRegistry
    ) -> DeterministicVerificationReplay? {
        let records = verifyTrajectory(plan: plan, exec: exec)
        let stepById = Dictionary(plan.steps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in exec.attemptResults.indices.reversed() {
            let record = records[index]
            guard record.success, CompletionVerifier.isFinalVerification(record, in: records),
                  record.observedEffects.mutation == .none,
                  let step = stepById[exec.attemptResults[index].stepId] else { continue }
            let attempt = exec.attemptResults[index]
            let arguments = ExecutablePlan.resolveArguments(step.argumentsJSON, outputs: exec.outputs)
            let fingerprint = attempt.tool == "run_command"
                ? commandFingerprint(arguments)
                : TrajectoryAnalyzer.fingerprint(arguments)
            guard attempt.argsFingerprint == fingerprint,
                  Int(attempt.metadata["exit_code"] ?? "") == 0,
                  metadataExitCodes(attempt.metadata["allowed_exit_codes"]) == [0],
                  attempt.metadata["verification_eligible"]?.lowercased() == "true",
                  let capability = replayCapabilityBinding(
                    tool: attempt.tool, arguments: arguments, context: context, tools: tools) else { continue }
            guard let standardInputSource = durableStandardInputSource(
                arguments: arguments, metadata: attempt.metadata) else { continue }
            let durableArguments = durableCommandArguments(arguments, source: standardInputSource)
            let canonicalArgumentsJSON = canonicalReceiptValue(durableArguments)
            let stdout = attempt.metadata["stdout"] ?? attempt.output
            let stderr = attempt.metadata["stderr"] ?? ""
            let commandDigest = durableCommandFingerprint(
                tool: attempt.tool, canonicalArgumentsJSON: canonicalArgumentsJSON,
                source: standardInputSource)
            let proofOutputDigest = secureDigest(stdout + "\u{0}" + stderr)
            let recipeID = secureDigest([
                missionInstanceID, sourcePlanID, attempt.stepId, commandDigest,
                proofWorkspaceDigest, proofOutputDigest,
            ].joined(separator: "\u{0}"))
            let recipe = DurablePlanVerificationRecipe(
                id: recipeID, sourcePlanID: sourcePlanID, stepID: attempt.stepId, tool: attempt.tool,
                resolvedExecutable: capability.resolvedExecutable,
                argv: arguments["args"] as? [String] ?? [],
                workingDirectory: capability.workingDirectory,
                standardInputSource: standardInputSource,
                allowedExitCodes: configuredExitCodes(arguments["allowed_exit_codes"]),
                canonicalArgumentsJSON: canonicalArgumentsJSON,
                argsFingerprint: fingerprint, commandFingerprint: commandDigest,
                completionContractFingerprint: completionContractFingerprint,
                obligationsFingerprint: obligationsFingerprint,
                executionPolicyFingerprint: executionPolicyFingerprint,
                workspaceManifestDigest: workspaceManifestDigest,
                proofWorkspaceDigest: proofWorkspaceDigest,
                proofOutputDigest: proofOutputDigest, proofAt: Date(),
                capabilityFingerprint: capability.capabilityFingerprint,
                authorizationFingerprint: capability.authorizationFingerprint,
                toolSchemaFingerprint: capability.toolSchemaFingerprint,
                executableIdentity: capability.executableIdentity)
            return DeterministicVerificationReplay(
                stepID: attempt.stepId, tool: attempt.tool, arguments: arguments,
                fingerprint: fingerprint, durableRecipe: recipe)
        }
        return nil
    }

    /// Untruncated `run_command` fingerprint in the exact shapes `CommandClassifier.isBuildOrTest`
    /// accepts (`command=<full>` or `executable=<e>&args=[...]&cwd=<c>`) so a real build/test verb is
    /// never clipped away before classification.
    static func commandFingerprint(_ args: [String: Any]) -> String {
        ToolEffectCatalog.commandFingerprint(args)
    }

    static func deterministicReplayStateKey(
        missionInstanceID: String,
        workspaceDigest: String,
        goalFingerprint: String,
        replay: DeterministicVerificationReplay,
        invalidated: CompletionVerifier.InvalidatedVerification,
        trajectory: [ActionRecord],
        shellEnabled: Bool,
        contractFingerprint: String
    ) -> String {
        let suffix = trajectory.dropFirst(invalidated.lastPassedStep).filter {
            $0.observedEffects.mutation != .none
        }.map {
            "\($0.tool)|\($0.argsFingerprint)|\($0.success)|\($0.observedEffects.mutation.rawValue)|\($0.observedEffects.mutationEvidence.rawValue)"
        }.joined(separator: "\n")
        return secureDigest([
            missionInstanceID, workspaceDigest, goalFingerprint, contractFingerprint,
            replay.tool, replay.fingerprint,
            replay.durableRecipe.commandFingerprint,
            replay.durableRecipe.obligationsFingerprint,
            replay.durableRecipe.executionPolicyFingerprint,
            replay.durableRecipe.capabilityFingerprint,
            shellEnabled ? "shell:on" : "shell:off", secureDigest(suffix),
        ].joined(separator: "\u{0}"))
    }

    static func reviewBinding(trajectory: [ActionRecord], workspaceDigest: String,
                              workspaceManifestPolicyFingerprint: String = "legacy",
                              workspaceManifestRevision: Int = 0,
                              workspaceManifestDigest: String = "legacy",
                              contract: PlanExecuteCompletionContract,
                              hostOwnedFinalReview: Bool = false,
                              functionalObjectiveFingerprint: String = "inner") -> ReviewVerificationBinding {
        let lastMutation = trajectory.lastIndex { $0.observedEffects.mutation != .none } ?? -1
        let verified = trajectory.indices.last { index in
            index > lastMutation && trajectory[index].success
                && CompletionVerifier.isFinalVerification(trajectory[index], in: trajectory)
                && trajectory[index].observedEffects.mutation == .none
        }
        let receipt = verified.map { index in
            "step \(index + 1) [\(trajectory[index].tool): \(trajectory[index].argsFingerprint)]"
        } ?? "no build/test required after the final non-source mutation"
        return ReviewVerificationBinding(
                                         workspaceDigest: workspaceDigest,
                                         workspaceManifestPolicyFingerprint:
                                            workspaceManifestPolicyFingerprint,
                                         workspaceManifestRevision: workspaceManifestRevision,
                                         workspaceManifestDigest: workspaceManifestDigest,
                                         receipt: receipt,
                                         contractKind: contract.kind.rawValue,
                                         contractFingerprint: contract.fingerprint,
                                         hostOwnedFinalReview: hostOwnedFinalReview,
                                         functionalObjectiveFingerprint: functionalObjectiveFingerprint)
    }

    /// Apply the immutable requested-effect contract on top of the shared anti-laundering verifier.
    /// Verification-only is deliberately additive: it removes the false mutation promise but requires
    /// a fresh typed build/test bound after every possible mutation and to the unchanged governed digest.
    static func completionVerdict(verifier: CompletionVerifier, trajectory: [ActionRecord],
                                  canRunCommands: Bool, contract: PlanExecuteCompletionContract,
                                  missionDigestAvailable: Bool,
                                  workspaceUnchanged: Bool) -> CompletionVerifier.Verdict {
        if contract.kind == .verificationOnly {
            guard missionDigestAvailable else {
                return .needsVerification(reason:
                    "verification-only completion cannot bind an unavailable governed workspace digest")
            }
            guard workspaceUnchanged else {
                return .needsVerification(reason:
                    "verification-only completion changed the governed workspace; no-write audit proof is invalid")
            }
            guard canRunCommands else {
                return .needsVerification(reason:
                    "verification-only completion requires a fresh build/test, but shell/build execution is unavailable")
            }
        }

        let verdict = verifier.check(
            trajectory: trajectory, canRunCommands: canRunCommands,
            expectedOutcome: contract.requiresMutation ? .mutation : contract.expectedOutcome,
            taskIntent: contract.requiresMutation ? .build : contract.requestedIntent)
        guard verdict.isAccept, contract.requiresFreshVerification else { return verdict }

        let lastMutation = trajectory.lastIndex { $0.observedEffects.mutation != .none } ?? -1
        let freshVerifier = trajectory.indices.last { index in
            index > lastMutation && trajectory[index].success
                && trajectory[index].observedEffects.verification == .buildOrTest
                && trajectory[index].observedEffects.mutation == .none
        }
        guard freshVerifier != nil else {
            return .needsVerification(reason:
                "verification-only completion requires a successful build/test against the final unchanged revision")
        }
        return .accept
    }

    static func completionSteering(contract: PlanExecuteCompletionContract,
                                   reason: String) -> String {
        "IMMUTABLE COMPLETION CONTRACT: \(contract.kind.rawValue) "
            + "[\(contract.fingerprint)]. Do not reinterpret this contract during replanning.\n"
            + CompletionVerifier.steering(reason: reason)
    }

    /// Content-address the governed workspace while excluding host-generated caches and orchestration
    /// state. Failure to enumerate collapses to one stable unavailable key, which fails closed by refusing
    /// repeated retries rather than minting a new pseudo-revision.
    public static func governedWorkspaceDigest(projectRoot: String) -> String {
        // FileManager's enumerator resolves `/var` to `/private/var` (and likewise for user-selected
        // symlink roots), while Foundation's resolvingSymlinksInPath does not resolve macOS firmlinks.
        // POSIX realpath gives the same canonical namespace as the enumerator; otherwise every entry is
        // rejected by the prefix guard and the digest silently stays SHA256(empty).
        let resolvedRoot: String? = {
            #if canImport(Darwin) || canImport(Glibc)
            guard let pointer = realpath(projectRoot, nil) else { return nil }
            defer { free(pointer) }
            return String(cString: pointer)
            #else
            return nil
            #endif
        }()
        // Do not call standardizedFileURL on the realpath result: Foundation maps `/private/var`
        // straight back to `/var`, recreating the namespace mismatch we just removed.
        let root = resolvedRoot.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: projectRoot).standardizedFileURL
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles]) else {
            return "unavailable:" + stableFingerprint(root.path)
        }
        let excludedDirectories: Set<String> = [
            ".git", ".build", ".swiftpm", ".kist", ".mythos", "DerivedData", "node_modules",
        ]
        var entries: [(path: String, url: URL, symlink: Bool)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.path.hasPrefix(root.path + "/") else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
            entries.append((relative, url, values?.isSymbolicLink == true))
        }
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(entry.path.utf8))
            hasher.update(data: Data([0]))
            if entry.symlink {
                let target = (try? manager.destinationOfSymbolicLink(atPath: entry.url.path)) ?? "<unreadable-link>"
                hasher.update(data: Data(target.utf8))
            } else if let data = try? Data(contentsOf: entry.url, options: .mappedIfSafe) {
                hasher.update(data: data)
            } else {
                hasher.update(data: Data("<unreadable>".utf8))
            }
            hasher.update(data: Data([255]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Ask the model whether the goal is FULLY accomplished given what the steps produced. Verification
    /// is a gate: if the critic errors or returns unparseable text, we fail closed instead of laundering
    /// a mechanically-successful run into a verified success.
}
