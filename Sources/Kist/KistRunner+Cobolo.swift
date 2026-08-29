import Foundation
import AgentCore


extension KistRunner {
    static let coboloMaxAcceptedSourceBytes = 65_536

    private struct CoboloCriticResponse: Decodable {
        let contractID: String
        let candidateSHA256: String
        let compileEvidenceDigest: String
        let runEvidenceDigest: String
        let decision: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case contractID = "contract_id"
            case candidateSHA256 = "candidate_sha256"
            case compileEvidenceDigest = "compile_evidence_digest"
            case runEvidenceDigest = "run_evidence_digest"
            case decision, reason
        }
    }

    private struct CoboloPromotionResponse: Decodable {
        let contractID: String
        let candidateSHA256: String
        let semanticReceiptDigest: String
        let verificationDigest: String
        let decision: String
        let reason: String

        enum CodingKeys: String, CodingKey {
            case contractID = "contract_id"
            case candidateSHA256 = "candidate_sha256"
            case semanticReceiptDigest = "semantic_receipt_digest"
            case verificationDigest = "verification_digest"
            case decision, reason
        }
    }

    struct CoboloDecodedPlan: Equatable {
        let contractID: String
        let explorationDigest: String
        let revision: Int
        let plannerIdentity: String
        let upstreamPlanDigest: String?
        let feedbackDigest: String?
        let steps: [String]
        let acceptanceChecks: [String]
    }

    private struct CoboloDynamicCodingKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct CoboloStepItem: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let string = try? single.decode(String.self) {
                text = try Self.validated(string, decoder: decoder)
                return
            }
            let container = try decoder.container(keyedBy: CoboloDynamicCodingKey.self)
            guard Set(container.allKeys.map(\.stringValue)) == Set(["id", "action"]),
                  let idKey = CoboloDynamicCodingKey(stringValue: "id"),
                  let actionKey = CoboloDynamicCodingKey(stringValue: "action") else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "plan step objects require exactly id and action"))
            }
            let id = try Self.validated(container.decode(String.self, forKey: idKey), decoder: decoder)
            let action = try Self.validated(
                container.decode(String.self, forKey: actionKey), decoder: decoder)
            text = try Self.validated("\(id): \(action)", decoder: decoder)
        }

        private static func validated(_ value: String, decoder: Decoder) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "plan step must be 1...4096 UTF-8 bytes"))
            }
            return trimmed
        }
    }

    private struct CoboloCheckItem: Decodable {
        let text: String

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer(),
               let string = try? single.decode(String.self) {
                text = try Self.validated(string, decoder: decoder)
                return
            }
            let container = try decoder.container(keyedBy: CoboloDynamicCodingKey.self)
            guard Set(container.allKeys.map(\.stringValue)) == Set(["id", "check"]),
                  let idKey = CoboloDynamicCodingKey(stringValue: "id"),
                  let checkKey = CoboloDynamicCodingKey(stringValue: "check") else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "acceptance check objects require exactly id and check"))
            }
            let id = try Self.validated(container.decode(String.self, forKey: idKey), decoder: decoder)
            let check = try Self.validated(
                container.decode(String.self, forKey: checkKey), decoder: decoder)
            text = try Self.validated("\(id): \(check)", decoder: decoder)
        }

        private static func validated(_ value: String, decoder: Decoder) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "acceptance check must be 1...4096 UTF-8 bytes"))
            }
            return trimmed
        }
    }

    // `internal` (not `private`): the plan-parsing caller moved to KistRunner+CoboloAttempts.swift
    // in the file split, so this response type must be reachable across the sibling extension file.
    // Its decoding helpers (CoboloStepItem/CoboloCheckItem/CoboloDynamicCodingKey) stay private —
    // they're only referenced inside this file's init(from:).
    struct CoboloPlanResponse: Decodable {
        let decoded: CoboloDecodedPlan

        enum CodingKeys: String, CodingKey, CaseIterable {
            case contractID = "contract_id"
            case explorationDigest = "exploration_digest"
            case revision
            case plannerIdentity = "planner_identity"
            case upstreamPlanDigest = "upstream_plan_digest"
            case feedbackDigest = "feedback_digest"
            case steps
            case acceptanceChecks = "acceptance_checks"
        }

        init(from decoder: Decoder) throws {
            let all = try decoder.container(keyedBy: CoboloDynamicCodingKey.self)
            guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "plan response must contain exactly the governed schema keys"))
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let steps = try container.decode([CoboloStepItem].self, forKey: .steps).map(\.text)
            let checks = try container.decode([CoboloCheckItem].self,
                                              forKey: .acceptanceChecks).map(\.text)
            guard (1...16).contains(steps.count), (1...16).contains(checks.count) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "plan steps and checks must each contain 1...16 items"))
            }
            decoded = CoboloDecodedPlan(
                contractID: try container.decode(String.self, forKey: .contractID),
                explorationDigest: try container.decode(String.self, forKey: .explorationDigest),
                revision: try container.decode(Int.self, forKey: .revision),
                plannerIdentity: try container.decode(String.self, forKey: .plannerIdentity),
                upstreamPlanDigest: try container.decodeIfPresent(String.self,
                                                                  forKey: .upstreamPlanDigest),
                feedbackDigest: try container.decodeIfPresent(String.self, forKey: .feedbackDigest),
                steps: steps, acceptanceChecks: checks)
        }
    }

    struct CoboloBudgetReservation: Sendable {
        let id: Int
        let promptTokens: Int
        let maximumCompletionTokens: Int
        let reservedUSD: Double
    }

    static func coboloTargetValidationIssue(_ target: String) -> String? {
        guard !target.isEmpty, target.utf8.count <= 1024 else { return "target is empty or too long" }
        guard !target.hasPrefix("/"), !target.hasPrefix("~"), !target.utf8.contains(0) else {
            return "target must be a project-relative path"
        }
        let parts = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" || $0 == ".kist" }) else {
            return "target contains a forbidden path component"
        }
        let ext = (target as NSString).pathExtension.lowercased()
        guard ext == "cbl" || ext == "cob" else { return "target must end in .cbl or .cob" }
        return nil
    }

    static func coboloLocalOllamaEndpoint(environment: [String: String]) throws -> String {
        guard let raw = environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return "http://127.0.0.1:11434" }
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "http",
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty,
              let host = components.host.map({ parsedHost in
                  let lowercased = parsedHost.lowercased()
                  if lowercased.hasPrefix("["), lowercased.hasSuffix("]") {
                      return String(lowercased.dropFirst().dropLast())
                  }
                  return lowercased
              }),
              host == "127.0.0.1" || host == "::1",
              let port = components.port, (1...65535).contains(port) else {
            throw CoboloLoopError.configuration("OLLAMA_HOST must use numeric loopback 127.0.0.1 or [::1] over http with a port")
        }
        return host == "::1" ? "http://[::1]:\(port)" : "http://127.0.0.1:\(port)"
    }

    static func coboloReserveBudget(_ budget: BudgetLedger, providerID: String,
                                    prompt: String, maximumCompletionTokens: Int) async throws -> CoboloBudgetReservation {
        let promptTokens = max(1, (prompt.utf8.count + 3) / 4)
        let reservedUSD = CompetitiveBenchmark.priceUSD(
            vendor: providerID, promptTokens: promptTokens,
            completionTokens: maximumCompletionTokens) ?? 0
        guard let id = await budget.reserve(tokens: promptTokens + maximumCompletionTokens,
                                            usd: reservedUSD) else {
            throw CoboloLoopError.rejected("Cobolo budget denied \(providerID) model work before invocation")
        }
        return CoboloBudgetReservation(id: id, promptTokens: promptTokens,
                                       maximumCompletionTokens: maximumCompletionTokens,
                                       reservedUSD: reservedUSD)
    }

    static func coboloCommitBudget(_ reservation: CoboloBudgetReservation, budget: BudgetLedger,
                                   providerID: String, output: String?, completed: Bool) async {
        let completionTokens: Int
        if completed, let output {
            completionTokens = max(1, (output.utf8.count + 3) / 4)
        } else {
            // A failed transport/tool may still have consumed its whole allowance. Charge
            // conservatively rather than recording a misleading zero-token stage.
            completionTokens = reservation.maximumCompletionTokens
        }
        let actualUSD = CompetitiveBenchmark.priceUSD(
            vendor: providerID, promptTokens: reservation.promptTokens,
            completionTokens: completionTokens) ?? reservation.reservedUSD
        await budget.commit(reservation: reservation.id,
                            actualTokens: reservation.promptTokens + completionTokens,
                            actualUSD: actualUSD)
    }

    static func coboloValidatedGeneratedSource(success: Bool, output: String, error: String?,
                                                metadata: [String: String], expectedModel: String,
                                                endpoint: String) throws -> Data {
        guard success else {
            throw CoboloLoopError.rejected("cobol_generate failed: \(error ?? output)")
        }
        let data = Data(output.utf8)
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              data.count <= coboloMaxAcceptedSourceBytes else {
            throw CoboloLoopError.rejected("cobol_generate returned empty or source larger than 64 KiB")
        }
        let digest = BuilderEvidenceDigest.sha256(output)
        guard metadata["provider"] == "cobol",
              metadata["model"] == expectedModel,
              metadata["offline"] == "true",
              metadata["endpoint"] == endpoint,
              metadata["source_sha256"] == digest,
              metadata["compiled"] == "false",
              metadata["ran"] == "false",
              metadata["expect_met"] == "false" else {
            throw CoboloLoopError.rejected("cobol_generate source-only identity, endpoint, digest, or execution metadata was invalid")
        }
        return data
    }

    static func coboloSemanticReceipt(responseText: String, actualIdentity: String,
                                      expectedIdentity: String, contractID: String,
                                      candidateSHA256: String, compileEvidenceDigest: String,
                                      runEvidenceDigest: String) throws -> CoboloSemanticReviewReceipt {
        guard actualIdentity == expectedIdentity,
              let data = responseText.data(using: .utf8),
              let response = try? JSONDecoder().decode(CoboloCriticResponse.self, from: data),
              response.contractID == contractID,
              response.candidateSHA256 == candidateSHA256,
              response.compileEvidenceDigest == compileEvidenceDigest,
              response.runEvidenceDigest == runEvidenceDigest,
              response.decision == "APPROVE" || response.decision == "REJECT",
              !response.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoboloLoopError.rejected("semantic critic identity or contract-bound structured verdict was invalid")
        }
        return CoboloSemanticReviewReceipt(
            contractID: contractID, reviewerIdentity: actualIdentity,
            candidateSHA256: candidateSHA256,
            compileEvidenceDigest: compileEvidenceDigest,
            runEvidenceDigest: runEvidenceDigest,
            approved: response.decision == "APPROVE", reason: response.reason,
            reviewedAt: Date())
    }

    static func coboloPromotionReceipt(responseText: String, actualIdentity: String,
                                       expectedIdentity: String, contractID: String,
                                       candidateSHA256: String, semanticReceiptDigest: String,
                                       verificationDigest: String) throws -> CoboloPromotionReviewReceipt {
        guard actualIdentity == expectedIdentity,
              let data = responseText.data(using: .utf8),
              let response = try? JSONDecoder().decode(CoboloPromotionResponse.self, from: data),
              response.contractID == contractID,
              response.candidateSHA256 == candidateSHA256,
              response.semanticReceiptDigest == semanticReceiptDigest,
              response.verificationDigest == verificationDigest,
              response.decision == "APPROVE" || response.decision == "REJECT",
              !response.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoboloLoopError.rejected("promotion reviewer identity or contract-bound structured verdict was invalid")
        }
        return CoboloPromotionReviewReceipt(
            reviewerIdentity: actualIdentity, contractID: contractID,
            candidateSHA256: candidateSHA256,
            semanticReceiptDigest: semanticReceiptDigest,
            verificationDigest: verificationDigest,
            approved: response.decision == "APPROVE", reason: response.reason,
            votes: [], reviewedAt: Date())
    }

    static func coboloCommandReceipt(result: ToolResult, stage: String, executable: String,
                                     arguments: [String], expectedStdout: String? = nil,
                                     invocation: CoboloCommandInvocation? = nil,
                                     retryCandidateFailure: Bool = false) throws -> CoboloCommandReceipt {
        try coboloCommandReceipt(success: result.success, output: result.output, error: result.error,
                                 metadata: result.metadata, stage: stage, executable: executable,
                                 arguments: arguments, expectedStdout: expectedStdout,
                                 invocation: invocation,
                                 trustedCommandReference: result.trustedCommandReference,
                                 retryCandidateFailure: retryCandidateFailure)
    }

    static func coboloCommandReceipt(success: Bool, output: String = "", error: String? = nil,
                                     metadata: [String: String], stage: String, executable: String,
                                     arguments: [String], expectedStdout: String? = nil,
                                     invocation: CoboloCommandInvocation? = nil,
                                     trustedCommandReference: BuilderTrustedCommandReference? = nil,
                                     retryCandidateFailure: Bool = false) throws -> CoboloCommandReceipt {
        guard metadata["sandboxed"] == "true",
              metadata["timed_out"] == "false",
              metadata["was_signalled"] == "false",
              metadata["stdout_truncated"] == "false",
              metadata["stderr_truncated"] == "false",
              metadata["output_truncated"] == "false",
              let exitText = metadata["exit_code"], let exitCode = Int32(exitText),
              let stdout = metadata["stdout"], let stderr = metadata["stderr"] else {
            throw CoboloLoopError.rejected("\(stage) lacks complete sandboxed command provenance")
        }
        guard success, exitCode == 0 else {
            let detail = "\(stage) exited \(exitCode): \(error ?? (stderr.isEmpty ? output : stderr))"
            if retryCandidateFailure { throw CoboloLoopError.retryableCandidate(detail) }
            throw CoboloLoopError.rejected(detail)
        }
        guard metadata["verification_eligible"] == "true" else {
            throw CoboloLoopError.rejected("\(stage) is not eligible verification evidence")
        }
        if let expectedStdout, !stdout.contains(expectedStdout) {
            let detail = "\(stage) stdout did not contain the required expectation"
            if retryCandidateFailure { throw CoboloLoopError.retryableCandidate(detail) }
            throw CoboloLoopError.rejected(detail)
        }
        if let trustedCommandReference {
            guard let invocation,
                  invocation.executable == executable,
                  invocation.arguments == arguments,
                  trustedCommandReference.isValid,
                  trustedCommandReference.exitCode == Int(exitCode),
                  trustedCommandReference.timedOut == false,
                  trustedCommandReference.wasSignalled == false,
                  trustedCommandReference.gateArgumentsDigest
                    == AuditLog.digest(invocation.toolArguments).digest,
                  trustedCommandReference.stdoutDigest == BuilderEvidenceDigest.sha256(stdout),
                  trustedCommandReference.stderrDigest == BuilderEvidenceDigest.sha256(stderr),
                  trustedCommandReference.stdoutByteCount == stdout.utf8.count,
                  trustedCommandReference.stderrByteCount == stderr.utf8.count else {
                throw CoboloLoopError.rejected(
                    "\(stage) trusted command reference does not match its gated invocation or output")
            }
        }
        return CoboloCommandReceipt(stage: stage, executable: executable, arguments: arguments,
                                    exitCode: exitCode, sandboxed: true, timedOut: false,
                                    wasSignalled: false, stdoutTruncated: false,
                                    stderrTruncated: false, outputTruncated: false,
                                    stdout: stdout, stderr: stderr, capturedAt: Date(),
                                    invocation: invocation,
                                    trustedCommandReference: trustedCommandReference)
    }

    static func coboloIdentitiesConflict(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let leftColon = left.firstIndex(of: ":"), let rightColon = right.firstIndex(of: ":") else {
            return true
        }
        let leftModel = left[left.index(after: leftColon)...]
        let rightModel = right[right.index(after: rightColon)...]
        return left == right || leftModel == rightModel
    }

    static func coboloProductionIdentityPlan(
        providerId: String, model: String?, roles: RoleBindings, registry: ProviderRegistry
    ) throws -> CoboloIdentityPlan {
        let driver = try coboloResolvedBinding(
            ProviderBinding(providerId: providerId, model: model), registry: registry)
        let coder = try coboloResolvedBinding(roles.binding(for: .coder), registry: registry)
        let cobol = try coboloResolvedBinding(
            ProviderBinding(providerId: "cobol"), registry: registry)
        let critic = try coboloResolvedBinding(roles.binding(for: .critic), registry: registry)
        let producers = Array(Set([driver, coder, cobol].map(coboloIdentity))).sorted()
        let criticIdentity = coboloIdentity(critic)
        guard let promotion = coboloPromotionReviewer(
            registry: registry, roles: roles, excluding: producers + [criticIdentity]) else {
            throw CoboloLoopError.configuration("no distinct promotion reviewer model is available")
        }
        return CoboloIdentityPlan(
            driver: driver, coder: coder, cobol: cobol, critic: critic, promotion: promotion)
    }

    static func coboloValidateExecutionContract(
        _ sealed: SealedBuilderExecutionContract,
        builderContractID: String? = nil,
        builderNodeID: String? = nil,
        target: String,
        identityPlan: CoboloIdentityPlan
    ) throws {
        let contract = sealed.contract
        let expectedContractID = builderContractID ?? contract.builderContractID
        let expectedNodeID = builderNodeID ?? contract.builderNodeID
        try sealed.validate(
            builderContractID: expectedContractID, graphNodeIDs: [expectedNodeID])
        guard contract.builderNodeID == expectedNodeID,
              expectedNodeID == "cobolo-execution",
              contract.mutations.count == 1,
              contract.mutations[0].path == target,
              contract.mutations[0].kind != .delete else {
            throw CoboloLoopError.configuration(
                "Builder execution contract does not prescribe exactly the COBOL target")
        }
        let lineage = contract.lineage
        guard lineage.captainDecisionDigest != nil,
              lineage.research != nil,
              lineage.peelReceiptDigest != nil,
              lineage.councilArtifactDigest != nil else {
            throw CoboloLoopError.configuration("Builder execution contract lineage is incomplete")
        }
        let criteria = Dictionary(uniqueKeysWithValues: contract.criteria.map { ($0.id, $0) })
        guard criteria["cobolo-lineage"]?.kind == .lineageReceipt,
              criteria["cobolo-target"]?.kind == .artifactDigest,
              criteria["cobolo-compile"]?.kind == .deterministicCommand,
              criteria["cobolo-runtime"]?.kind == .deterministicCommand,
              criteria["cobolo-semantic-review"]?.kind == .modelJudgment,
              criteria["cobolo-promotion-review"]?.kind == .modelJudgment,
              criteria.values.allSatisfy({ $0.required }) else {
            throw CoboloLoopError.configuration(
                "Builder execution contract lacks required compile/runtime/review criteria")
        }
        func canonical(_ binding: ProviderBinding) -> String {
            "\(binding.providerId.lowercased()):\((binding.model ?? "").lowercased())"
        }
        let expectedProducers = Set([
            identityPlan.driver, identityPlan.coder, identityPlan.cobol,
        ].map(canonical))
        let expectedReviewers = Set([
            identityPlan.critic, identityPlan.promotion,
        ].map(canonical))
        guard Set(contract.identities.producers.map { $0.canonicalID }) == expectedProducers,
              Set(contract.identities.reviewers.map { $0.canonicalID }) == expectedReviewers else {
            throw CoboloLoopError.configuration(
                "Builder execution contract identities drifted from Cobolo role bindings")
        }
    }

    static func coboloValidateResumeLineage(
        persisted: SealedBuilderExecutionContract?, expected: SealedBuilderExecutionContract
    ) throws {
        guard let persisted else {
            throw CoboloLoopError.rejected(
                "pre-lineage Cobolo state is non-resumable; start a fresh migrated run")
        }
        guard persisted == expected else {
            throw CoboloLoopError.rejected("durable Cobolo Builder lineage drifted on resume")
        }
    }

    static func runCobolo(_ opts: KistOptions, goal: String, registry: ProviderRegistry, root: String,
                          tools: ToolRegistry, context: ToolContext, roles: RoleBindings,
                          providerId: String, model: String?, budget: BudgetLedger?,
                          executionContract: SealedBuilderExecutionContract? = nil,
                          durableStateRoot: String? = nil,
                          dependencies: CoboloDependencies? = nil,
                          outcomeCapture: (@Sendable (CoboloBuilderEvidence) -> Void)? = nil) async -> Int32 {
        guard let budget else {
            err("cobolo · a shared BudgetLedger is required")
            return 2
        }
        let dependencies = dependencies ?? CoboloDependencies()
        do {
            guard let target = opts.cobolTarget?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let expected = opts.cobolExpect?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !expected.isEmpty else {
                throw CoboloLoopError.configuration("--cobolo requires a goal, --cobol-target, and --cobol-expect")
            }
            if let issue = coboloTargetValidationIssue(target) {
                throw CoboloLoopError.configuration("unsafe COBOL target: \(issue)")
            }
            guard let executionContract else {
                throw CoboloLoopError.configuration(
                    "Cobolo requires a sealed Builder execution contract with complete lineage")
            }
            guard context.sandbox.enabled else {
                throw CoboloLoopError.configuration("Cobolo requires the OS sandbox")
            }
            let endpoint = try coboloLocalOllamaEndpoint(
                environment: dependencies.environment ?? ProcessInfo.processInfo.environment)
            let confined = try ConfinedRoot(root: root)
            let durableConfined: ConfinedRoot?
            if let durableStateRoot {
                try FileManager.default.createDirectory(
                    atPath: durableStateRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                durableConfined = try ConfinedRoot(root: durableStateRoot)
            } else {
                durableConfined = nil
            }
            try coboloRequireExistingTargetParent(root: confined, target: target)
            let identityPlan: CoboloIdentityPlan
            identityPlan = try dependencies.identityPlan ?? coboloProductionIdentityPlan(
                providerId: providerId, model: model, roles: roles, registry: registry)
            try coboloValidateExecutionContract(
                executionContract, target: target, identityPlan: identityPlan)
            let cobol = identityPlan.cobol
            let critic = identityPlan.critic
            let promotionReviewer = identityPlan.promotion
            let producers = identityPlan.producerIdentities
            let criticIdentity = coboloIdentity(critic)
            guard !producers.contains(where: { coboloIdentitiesConflict($0, criticIdentity) }) else {
                throw CoboloLoopError.configuration("semantic critic must use a model distinct from every producer")
            }
            let promotionIdentity = coboloIdentity(promotionReviewer)
            guard !producers.contains(where: { coboloIdentitiesConflict($0, promotionIdentity) }),
                  !coboloIdentitiesConflict(criticIdentity, promotionIdentity) else {
                throw CoboloLoopError.configuration("promotion reviewer must be distinct from producers and critic")
            }
            let runID = BuilderEvidenceDigest.sha256([
                goal, confined.rootPath, target, expected, endpoint
            ].joined(separator: "\u{0}"))
            let fingerprint = BuilderEvidenceDigest.sha256([
                runID, String(opts.cobolMaxRevisions), producers.joined(separator: ","),
                criticIdentity, promotionIdentity, executionContract.fingerprint
            ].joined(separator: "\u{0}"))
            let contract = CoboloContract(schemaVersion: 3, id: fingerprint, goal: goal,
                                          projectRoot: confined.rootPath, target: target,
                                          expectedStdout: expected, ollamaEndpoint: endpoint,
                                          producerIdentities: producers, criticIdentity: criticIdentity,
                                          promotionReviewerIdentity: promotionIdentity,
                                          maxRevisions: opts.cobolMaxRevisions,
                                          builderExecutionContract: executionContract)
            let attemptBinding = CoboloAttemptJournalBinding(
                runID: runID, contractID: fingerprint, projectRoot: confined.rootPath,
                maximumAttempts: opts.cobolMaxRevisions + 1)
            let attemptJournal: any CoboloAttemptJournal
            if let injected = dependencies.attemptJournal {
                attemptJournal = injected
            } else {
                attemptJournal = try CoboloAttemptJournalFactory.make(
                    projectRoot: durableConfined?.rootPath ?? confined.rootPath)
            }
            let coordinator = WorkspaceExecutionCoordinator()
            let lease = try coordinator.acquire(projectRoot: confined.rootPath,
                                                missionInstanceID: fingerprint, blocking: true)
            defer { lease.release() }
            let store = CoboloRunStore(
                root: confined, durableRoot: durableConfined, runID: runID)
            try store.prepare()
            var state: CoboloRunState
            var isResume = false
            let attemptAnchor: CoboloAttemptAnchor
            if let existing = try store.load() {
                try coboloValidateResumeLineage(
                    persisted: existing.contract.builderExecutionContract,
                    expected: executionContract)
                guard existing.contract == contract else {
                    throw CoboloLoopError.configuration("durable Cobolo contract does not match this invocation")
                }
                guard let loaded = try attemptJournal.load(binding: attemptBinding) else {
                    throw CoboloLoopError.rejected(
                        "durable Cobolo run has no authenticated attempt journal; explicit legacy migration is required")
                }
                attemptAnchor = loaded
                state = existing
                isResume = true
            } else {
                attemptAnchor = try attemptJournal.create(binding: attemptBinding)
                guard attemptAnchor.highWater == 0 else {
                    throw CoboloLoopError.rejected(
                        "authenticated attempt journal is not pristine for a new Cobolo run")
                }
                let baseline = try coboloCaptureBaseline(root: confined, target: target)
                state = CoboloRunState(contract: contract, baseline: baseline, stage: .initialized,
                                       candidatePath: "\(store.directory)/candidate.cbl",
                                       candidateSHA256: nil, promotedSHA256: nil, compilerPreflight: nil,
                                       verifications: [], critic: nil, promotionReview: nil, acceptance: nil,
                                       exploration: nil, explorationHistory: nil,
                                       planReceipts: [], activePlanDigest: nil, attemptsStarted: 0,
                                       revisionReceipts: [], feedback: nil,
                                       baselineSnapshot: nil, rollback: nil,
                                       lastError: nil, updatedAt: Date())
                try store.save(state)
            }

            do {
                if isResume {
                    try coboloReconcileInterruptedRollback(
                        state: &state, store: store, root: confined, lease: lease)
                }
                try coboloValidatePlanningState(state, identityPlan: identityPlan,
                                                store: store, root: confined)
                try coboloReconcileAttemptJournal(
                    state: &state, anchor: attemptAnchor, binding: attemptBinding,
                    identityPlan: identityPlan, store: store)
                try coboloValidatePlanningState(state, identityPlan: identityPlan,
                                                store: store, root: confined)
                try coboloValidateResumeTarget(state: state, root: confined)
                if state.baselineSnapshot == nil {
                    state.baselineSnapshot = try coboloCaptureBaselineSnapshot(
                        state: state, store: store, root: confined)
                    state.updatedAt = Date(); try store.save(state)
                }
                try coboloValidateBaselineSnapshot(state: state, root: confined)

                let preflightInvocation = CoboloCommandInvocation(
                    executable: "cobc", arguments: ["--version"], workingDirectory: ".",
                    timeoutSeconds: 30, allowedExitCodes: [0])
                let preflightResult = await coboloExecuteTool(
                    name: "run_command", arguments: preflightInvocation.toolArguments,
                    context: context, stage: "compiler-preflight",
                    tools: tools, dependencies: dependencies)
                let compilerPreflight = try coboloCommandReceipt(
                    success: preflightResult.success, output: preflightResult.output,
                    error: preflightResult.error, metadata: preflightResult.metadata,
                    stage: "compiler-preflight", executable: "cobc", arguments: ["--version"],
                    invocation: preflightInvocation,
                    trustedCommandReference: preflightResult.trustedCommandReference)
                let freshExploration = try coboloExplore(
                    contract: contract, baseline: state.baseline,
                    root: confined, compiler: compilerPreflight)
                _ = try coboloInstallFreshExploration(
                    state: &state, fresh: freshExploration, compiler: compilerPreflight,
                    store: store, root: confined, lease: lease)
                try coboloValidatePlanningState(state, identityPlan: identityPlan,
                                                store: store, root: confined)

                if state.stage == .completed {
                    let reviewVerification = try await coboloVerify(
                        sourcePath: target,
                        binaryPath: "\(store.directory)/resume-pre-review",
                        phase: "resume-pre-review", expected: expected,
                        root: confined, tools: tools, context: context,
                        dependencies: dependencies)
                    guard reviewVerification.sourceSHA256 == state.promotedSHA256 else {
                        throw CoboloLoopError.rejected("completed target digest drifted after acceptance")
                    }
                    guard let priorAcceptance = state.acceptance else {
                        throw CoboloLoopError.rejected("completed Cobolo run is missing its acceptance receipt")
                    }
                    let source = try confined.readStableData(
                        target, maxBytes: coboloMaxAcceptedSourceBytes)
                    let freshCritic = try await coboloSemanticReview(
                        contract: contract, binding: critic, source: source,
                        verification: reviewVerification, registry: registry, budget: budget,
                        dependencies: dependencies)
                    guard freshCritic.approved else {
                        throw CoboloLoopError.rejected(
                            "completed replay semantic critic rejected target: \(freshCritic.reason)")
                    }
                    let freshPromotion = try await coboloPromotionReview(
                        contract: contract, binding: promotionReviewer, source: source,
                        verifications: [reviewVerification], critic: freshCritic,
                        registry: registry, budget: budget, dependencies: dependencies)
                    guard freshPromotion.approved else {
                        throw CoboloLoopError.rejected(
                            "completed replay promotion reviewer rejected target: \(freshPromotion.reason)")
                    }
                    // The authoritative resume receipt is replayed after both fresh
                    // reviews so no old command receipt is promoted past newer review work.
                    let final = try await coboloVerify(
                        sourcePath: target,
                        binaryPath: "\(store.directory)/resume-final",
                        phase: "resume-post-promotion", expected: expected,
                        root: confined, tools: tools, context: context,
                        dependencies: dependencies)
                    guard final.sourceSHA256 == state.promotedSHA256 else {
                        throw CoboloLoopError.rejected("completed target drifted during fresh review replay")
                    }
                    let observedWorkspaceDigest = PlanExecuteLoop.governedWorkspaceDigest(
                        projectRoot: confined.rootPath)
                    guard !observedWorkspaceDigest.hasPrefix("unavailable:") else {
                        throw CoboloLoopError.rejected(
                            "governed workspace digest unavailable after completed replay")
                    }
                    let acceptance = CoboloAcceptanceReceipt(
                        schemaVersion: max(3, priorAcceptance.schemaVersion), contractID: contract.id,
                        target: target, baseline: state.baseline,
                        candidateSHA256: final.sourceSHA256, promotedSHA256: final.sourceSHA256,
                        observedWorkspaceDigest: observedWorkspaceDigest,
                        producerIdentities: contract.producerIdentities,
                        compilerPreflight: compilerPreflight,
                        critic: freshCritic, promotionReview: freshPromotion,
                        verifications: [reviewVerification, final], acceptedAt: Date(),
                        builderExecutionContract: executionContract)
                    state.compilerPreflight = compilerPreflight
                    state.verifications = [reviewVerification, final]; state.critic = freshCritic
                    state.promotionReview = freshPromotion; state.acceptance = acceptance
                    state.updatedAt = Date(); try store.save(state); try store.save(acceptance)
                    outcomeCapture?(CoboloBuilderEvidence(
                        producerIdentities: acceptance.producerIdentities,
                        target: acceptance.target,
                        promotedSHA256: acceptance.promotedSHA256,
                        observedWorkspaceDigest: observedWorkspaceDigest,
                        finalVerification: final,
                        reviewerIdentity: acceptance.promotionReview.reviewerIdentity,
                        executionContract: executionContract))
                    note("cobolo · durable accepted run \(fingerprint.prefix(12)) replayed successfully")
                    return 0
                }

                if isResume,
                   state.stage != .planned,
                   state.stage.rank >= CoboloStage.candidateWritten.rank,
                   state.candidateSHA256 != nil {
                    try await coboloRefreshPersistedReviews(
                        state: &state, store: store, contract: contract,
                        identityPlan: identityPlan, root: confined, tools: tools,
                        context: context, registry: registry, budget: budget,
                        dependencies: dependencies)
                }

                if state.stage.rank < CoboloStage.criticApproved.rank || state.critic == nil {
                    try await coboloRunAttempts(
                        state: &state, store: store, contract: contract,
                        identityPlan: identityPlan, root: confined, tools: tools,
                        context: context, registry: registry, budget: budget,
                        dependencies: dependencies, lease: lease,
                        attemptJournal: attemptJournal, attemptBinding: attemptBinding)
                }

                if state.stage.rank < CoboloStage.candidateWritten.rank || state.candidateSHA256 == nil {
                    state.stage = .generating; state.updatedAt = Date(); state.lastError = nil
                    try store.save(state)
                    let generationRequest = goal + "\nThe compiled program's stdout must contain: " + expected
                    var arguments: [String: Any] = ["request": generationRequest]
                    if !state.baseline.missing {
                        arguments["existing"] = try confined.readString(
                            target, maxBytes: coboloMaxAcceptedSourceBytes)
                    }
                    let generationPrompt = generationRequest + "\n" + ((arguments["existing"] as? String) ?? "")
                    let reservation = try await coboloReserveBudget(
                        budget, providerID: cobol.providerId, prompt: generationPrompt,
                        maximumCompletionTokens: coboloMaxAcceptedSourceBytes / 4)
                    let generated = await tools.execute(name: "cobol_generate", arguments: arguments, context: context)
                    await coboloCommitBudget(reservation, budget: budget,
                                             providerID: cobol.providerId,
                                             output: generated.output, completed: generated.success)
                    guard let cobolModel = cobol.model else {
                        throw CoboloLoopError.configuration("cobol provider did not resolve a concrete model")
                    }
                    let source = try coboloValidatedGeneratedSource(
                        success: generated.success, output: generated.output, error: generated.error,
                        metadata: generated.metadata, expectedModel: cobolModel, endpoint: endpoint)
                    try confined.writeData(state.candidatePath, source, createParents: true)
                    state.candidateSHA256 = coboloHex(try confined.fileSHA256(state.candidatePath))
                    state.stage = .candidateWritten; state.updatedAt = Date()
                    try store.save(state)
                }

                let candidateData = try confined.readStableData(
                    state.candidatePath, maxBytes: coboloMaxAcceptedSourceBytes)
                let candidateDigest = coboloHex(try confined.fileSHA256(state.candidatePath))
                guard candidateDigest == state.candidateSHA256 else {
                    throw CoboloLoopError.rejected("candidate changed since its durable checkpoint")
                }
                if state.stage.rank < CoboloStage.candidateVerified.rank {
                    state.verifications.append(try await coboloVerify(
                        sourcePath: state.candidatePath,
                        binaryPath: "\(store.directory)/candidate-pre-review",
                        phase: "candidate-pre-review", expected: expected,
                        root: confined, tools: tools, context: context,
                        dependencies: dependencies))
                    state.stage = .candidateVerified; state.updatedAt = Date()
                    try store.save(state)
                }

                if state.stage.rank < CoboloStage.criticApproved.rank {
                    guard let verification = state.verifications.last else {
                        throw CoboloLoopError.rejected("candidate verification receipt is missing")
                    }
                    let criticReceipt = try await coboloSemanticReview(
                        contract: contract, binding: critic, source: candidateData,
                        verification: verification, registry: registry, budget: budget)
                    state.critic = criticReceipt; state.updatedAt = Date()
                    try store.save(state)
                    guard criticReceipt.approved else {
                        throw CoboloLoopError.rejected("semantic critic rejected candidate: \(criticReceipt.reason)")
                    }
                    state.stage = .criticApproved; state.updatedAt = Date()
                    try store.save(state)
                }

                if !state.verifications.contains(where: {
                    $0.phase == "candidate-post-critic" && $0.sourceSHA256 == candidateDigest
                }) {
                    state.verifications.append(try await coboloVerify(
                        sourcePath: state.candidatePath,
                        binaryPath: "\(store.directory)/candidate-post-critic",
                        phase: "candidate-post-critic", expected: expected,
                        root: confined, tools: tools, context: context,
                        dependencies: dependencies))
                }
                guard coboloHex(try confined.fileSHA256(state.candidatePath)) == candidateDigest else {
                    throw CoboloLoopError.rejected("candidate drifted after semantic review")
                }

                if try coboloRefreshExplorationSnapshot(
                    state: &state, store: store, root: confined, lease: lease) {
                    throw CoboloLoopError.rejected(
                        "governed COBOL inputs changed before promotion review; resume to replan")
                }

                if state.stage.rank < CoboloStage.promotionApproved.rank {
                    guard let criticReceipt = state.critic else {
                        throw CoboloLoopError.rejected("semantic critic receipt is missing")
                    }
                    let receipt = try await coboloPromotionReview(
                        contract: contract, binding: promotionReviewer, source: candidateData,
                        verifications: state.verifications, critic: criticReceipt,
                        registry: registry, budget: budget, dependencies: dependencies)
                    state.promotionReview = receipt; state.updatedAt = Date()
                    try store.save(state)
                    guard receipt.approved else {
                        throw CoboloLoopError.rejected("promotion council rejected candidate: \(receipt.reason)")
                    }
                    state.verifications.append(try await coboloVerify(
                        sourcePath: state.candidatePath,
                        binaryPath: "\(store.directory)/candidate-post-council",
                        phase: "candidate-post-council", expected: expected,
                        root: confined, tools: tools, context: context))
                    guard coboloHex(try confined.fileSHA256(state.candidatePath)) == candidateDigest else {
                        throw CoboloLoopError.rejected("candidate drifted after promotion review")
                    }
                    state.stage = .promotionApproved; state.updatedAt = Date()
                    try store.save(state)
                }

                if try coboloRefreshExplorationSnapshot(
                    state: &state, store: store, root: confined, lease: lease) {
                    throw CoboloLoopError.rejected(
                        "governed COBOL inputs changed before publication; resume to replan")
                }

                // Publication, promoted-state persistence, final replay, and
                // acceptance form one rollback transaction. conditionalReplace
                // may have published even when it subsequently reports failure.
                do {
                if state.stage == .promotionApproved {
                    try dependencies.beforePromotion?()
                    if try coboloCurrentDigest(root: confined, target: target) == candidateDigest {
                        state.promotedSHA256 = candidateDigest
                        state.stage = .promoted; state.updatedAt = Date()
                        try dependencies.beforePromotedStateSave?()
                        try store.save(state)
                    } else {
                        let expectedBaseline = try coboloConditionalBaseline(state.baseline)
                        let promoted: Data
                        if let injected = dependencies.conditionalPromotion {
                            promoted = try injected(confined, target, candidateData, expectedBaseline)
                        } else {
                            promoted = try confined.conditionalReplace(
                                target, with: candidateData,
                                expectedSHA256: expectedBaseline, lease: lease)
                        }
                        let promotedDigest = coboloHex(promoted)
                        guard promotedDigest == candidateDigest else {
                            throw CoboloLoopError.rejected("conditional promotion returned an unexpected digest")
                        }
                        state.promotedSHA256 = promotedDigest
                        state.stage = .promoted; state.updatedAt = Date()
                        try dependencies.beforePromotedStateSave?()
                        try store.save(state)
                    }
                }

                if try coboloRefreshExplorationSnapshot(
                    state: &state, store: store, root: confined, lease: lease) {
                    throw CoboloLoopError.rejected(
                        "governed COBOL inputs changed during publication; candidate rolled back")
                }

                let finalVerification = try await coboloVerify(
                    sourcePath: target, binaryPath: "\(store.directory)/promoted-final",
                    phase: "post-promotion", expected: expected,
                    root: confined, tools: tools, context: context,
                    dependencies: dependencies)
                state.verifications.append(finalVerification)
                guard finalVerification.sourceSHA256 == candidateDigest,
                      coboloHex(try confined.fileSHA256(target)) == candidateDigest,
                      let compilerPreflight = state.compilerPreflight,
                      let criticReceipt = state.critic,
                      let promotionReceipt = state.promotionReview else {
                    throw CoboloLoopError.rejected("post-promotion source or review evidence is stale")
                }
                if try coboloRefreshExplorationSnapshot(
                    state: &state, store: store, root: confined, lease: lease) {
                    throw CoboloLoopError.rejected(
                        "governed COBOL inputs changed during final replay; candidate rolled back")
                }
                let observedWorkspaceDigest = PlanExecuteLoop.governedWorkspaceDigest(
                    projectRoot: confined.rootPath)
                guard !observedWorkspaceDigest.hasPrefix("unavailable:") else {
                    throw CoboloLoopError.rejected(
                        "governed workspace digest unavailable after post-promotion replay")
                }
                let acceptance = CoboloAcceptanceReceipt(
                    schemaVersion: 3, contractID: fingerprint, target: target,
                    baseline: state.baseline, candidateSHA256: candidateDigest,
                    promotedSHA256: candidateDigest,
                    observedWorkspaceDigest: observedWorkspaceDigest,
                    producerIdentities: producers,
                    compilerPreflight: compilerPreflight, critic: criticReceipt,
                    promotionReview: promotionReceipt, verifications: state.verifications,
                    acceptedAt: Date(), builderExecutionContract: executionContract)
                state.acceptance = acceptance; state.stage = .completed
                state.updatedAt = Date(); state.lastError = nil
                try store.save(state); try store.save(acceptance)
                let compact = JSONEncoder(); compact.outputFormatting = [.sortedKeys]
                if let line = String(data: try compact.encode(acceptance), encoding: .utf8) {
                    note("KIST_COBOLO_RECEIPT:\(line)")
                }
                outcomeCapture?(CoboloBuilderEvidence(
                    producerIdentities: acceptance.producerIdentities,
                    target: acceptance.target,
                    promotedSHA256: acceptance.promotedSHA256,
                    observedWorkspaceDigest: observedWorkspaceDigest,
                    finalVerification: finalVerification,
                    reviewerIdentity: acceptance.promotionReview.reviewerIdentity,
                    executionContract: executionContract))
                note("cobolo · accepted \(target) · \(candidateDigest.prefix(12))")
                return 0
                } catch {
                    let trigger = error.localizedDescription
                    let currentTargetDigest = try? coboloCurrentDigest(root: confined, target: target)
                    var rollbackFailure: Error?
                    if currentTargetDigest == candidateDigest {
                        do {
                            try coboloRollbackAfterPromotion(
                                state: &state, store: store, root: confined, lease: lease,
                                candidateDigest: candidateDigest)
                        } catch {
                            rollbackFailure = error
                        }
                    }
                    if rollbackFailure == nil {
                        do {
                            state.updatedAt = Date()
                            try store.save(state)
                        } catch {
                            rollbackFailure = error
                        }
                    }
                    if let rollbackFailure {
                        let action = state.baseline.missing ? "remove" : "restore"
                        state.rollback = CoboloRollbackReceipt(
                            action: action, candidateSHA256: candidateDigest,
                            baselineSHA256: state.baseline.sha256, succeeded: false,
                            error: "post-promotion failure: \(trigger); rollback failure: \(rollbackFailure.localizedDescription)",
                            rolledBackAt: Date())
                        state.updatedAt = Date(); try? store.save(state)
                        throw CoboloLoopError.rejected(
                            "post-promotion verification failed and rollback failed: \(rollbackFailure.localizedDescription)")
                    }
                    throw error
                }
            } catch {
                state.lastError = error.localizedDescription; state.updatedAt = Date()
                try? store.save(state)
                throw error
            }
        } catch let error as CoboloLoopError {
            err("cobolo · \(error.localizedDescription)")
            switch error {
            case .configuration: return 2
            case .rejected, .retryableCandidate: return 1
            }
        } catch {
            err("cobolo · \(error.localizedDescription)")
            return 1
        }
    }

}
