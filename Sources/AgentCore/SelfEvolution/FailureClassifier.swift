import Foundation

/// Self-evolution, phase 1 — the FAILURE CLASSIFIER.
///
/// kist already had a self-heal spine (`SelfHealHandoff`: researcher pins a root cause + repair spec,
/// builder fixes a target FILE). But it baked in one assumption — *every failure is a code bug to repair*.
/// That is exactly why a run that hit "unknown Windows 98 run command" gave up: there was no source file
/// to repair; the real answer was "discover the tool's real capabilities" or "this tool genuinely can't do
/// it — extend it". This classifier is the missing step: read the REAL tool errors (visible since 0.17.29's
/// failed-tools-show-output fix) and decide WHY the run failed, so the loop can route the fix instead of
/// flailing on the task or giving up with "I don't know".
///
/// DETERMINISTIC on purpose: an LLM already produced the failing trajectory; the classifier that decides how
/// to RECOVER must be a fixed, testable function of the evidence, not another model guess. It returns a
/// verdict with the evidence it used, so `/why` and the self-heal brief can show its reasoning.
public enum FailureCategory: String, Sendable, Codable, Equatable, CaseIterable {
    /// A code / build / test error the model can fix by editing OUR source. → the existing repair handoff.
    case taskBug
    /// The tool CAN do the thing; the model used it wrong or didn't discover the right form. The tool often
    /// says how ("Use e.g. …", "search: …"). → discover the tool's real capabilities, then RETRY (no edit).
    case knowledgeGap
    /// The tool GENUINELY cannot do what was asked (no form of it works, no usable hint). → extend the tool:
    /// a KIST tool can be auto-evolved (write+build+test+independently-verify before promote); a foreign
    /// tool (perslis MCP, …) gets a written capability spec handed to its owner — never blend repos.
    case toolLimit
    /// Permission / scope / authority stopped it (denied, plan-only scope, needs approval). → surface the
    /// exact authority needed; NOT a code or tool problem.
    case blocked
    case schemaRefusal
    case authorization
    case toolchain
    case infrastructure
    case codeOrTest
    case uncertainMutation
    case staleProof
}

/// One failed tool observation feeding the classifier — the tool's name and the REAL error text it returned.
public struct ToolFailure: Sendable, Equatable {
    public let tool: String
    public let error: String
    public init(tool: String, error: String) { self.tool = tool; self.error = error }
}

/// The evidence extracted from a failed run. Kept independent of the trajectory type so the classifier is a
/// pure function (an adapter maps the real trajectory → signals; see `FailureSignals.from(...)`).
public struct FailureSignals: Sendable, Equatable {
    public let toolFailures: [ToolFailure]
    /// Did the run edit OUR source (write_file/edit_file/apply_patch on a project file)?
    public let editedSource: Bool
    /// Did a build/test/compile actually run (cobc, swift build, run_command of a compiler/test)?
    public let ranBuildOrTest: Bool
    /// Typed receipts from the live run. Empty preserves compatibility for callers that only have errors.
    public let trajectory: [ActionRecord]
    public init(toolFailures: [ToolFailure], editedSource: Bool = false, ranBuildOrTest: Bool = false,
                trajectory: [ActionRecord] = []) {
        self.toolFailures = toolFailures
        self.editedSource = editedSource
        self.ranBuildOrTest = ranBuildOrTest
        self.trajectory = trajectory
    }
}

extension FailureSignals {
    /// Build signals from a turn's trajectory. Each failed `ActionRecord`'s `failureDetail` carries the
    /// tool's REAL error (populated since the 0.17.29 failed-tools-show-output fix), so we classify on what
    /// the model actually saw — not a bare "exit code 1".
    public static func from(_ trajectory: [ActionRecord]) -> FailureSignals {
        let editTools: Set<String> = ["write_file", "edit_file", "apply_patch", "create_file", "make_dir"]
        let failures = trajectory.filter { !$0.success }
            .map { ToolFailure(tool: $0.tool, error: $0.failureDetail ?? "") }
        let edited = trajectory.contains { editTools.contains($0.tool) && $0.success }
        let built = trajectory.contains {
            $0.success && $0.observedEffects.verification == .buildOrTest
        }
        return FailureSignals(toolFailures: failures, editedSource: edited,
                              ranBuildOrTest: built, trajectory: trajectory)
    }
}

public enum FailureClassifier {

    public struct Verdict: Sendable, Equatable {
        public let category: FailureCategory
        public let confidence: Double        // 0.0–1.0
        public let evidence: String          // the concrete string(s) that drove the decision
        public let culpritTool: String?      // the tool at the heart of a knowledgeGap / toolLimit
        public let discoveryHint: String?    // for knowledgeGap: how the tool said to use it (drives auto-retry)

        public init(category: FailureCategory, confidence: Double, evidence: String,
                    culpritTool: String?, discoveryHint: String?) {
            self.category = category
            self.confidence = confidence
            self.evidence = evidence
            self.culpritTool = culpritTool
            self.discoveryHint = discoveryHint
        }
    }

    // MARK: - Signal vocabularies (lowercased substring matches)

    /// Authority stopped it — NOT a code/tool problem. Checked FIRST (a denied build looks like a build fail).
    static let blockedPhrases = [
        "authorization scope", "plan-only scope", "planonly", "needs approval", "requires approval",
        "not permitted", "permission denied", "denied by", "not authorized", "blocked by", "confined to",
        "outside the project root", "escapes the project root", "approval required",
    ]
    /// The tool told the model HOW to use it → a knowledge gap the model can close by discovering + retrying.
    /// These are PRECISE "here's the right form" instructions — deliberately NOT generic words like "run" or
    /// "see" (which false-match "Windows 98 RUN command" and misroute a genuine tool-limit into a retry).
    static let hintPhrases = [
        "use e.g.", "use one of", "try one of", "expected one of", "expects one of", "did you mean",
        "search:", "(search:", "list with", "for a full list", "for the full list",
        "valid keys", "valid values", "valid options", "valid commands", "valid actions",
        "supported keys", "supported values", "supported commands", "supported actions",
        "available commands", "available actions", "one of:",
    ]
    /// The tool refused the request as unrecognized/unsupported — capability boundary language.
    static let capabilityMissPhrases = [
        "unknown ", "unsupported", "not supported", "no such", "not a valid", "not recognized",
        "unrecognized", "cannot ", "can't ", "not implemented", "unavailable", "only ", "not a qemu",
        "does not support", "isn't supported", "not available",
    ]
    /// Build/test/compile failure tells → a task bug in code we can edit.
    static let buildFailPhrases = [
        "error:", "swiftc: fail", "compilation", "compile error", "cannot find", "is not defined",
        "expected ", "undeclared", "no member", "type mismatch", "test failed", "assertion", "exit code",
        "traceback", "segmentation fault", "linker",
    ]
    static let schemaPhrases = [
        "schema", "invalid argument", "invalid arguments", "unknown field", "unexpected field",
        "missing required", "expected type", "malformed tool", "arguments object"
    ]
    static let toolchainPhrases = [
        "command not found", "executable not found", "compiler not found", "sdk not found",
        "toolchain", "unable to find tool", "no such module"
    ]
    static let infrastructurePhrases = [
        "timed out", "timeout", "connection reset", "connection refused", "service unavailable",
        "temporarily unavailable", "no space left", "disk full", "cancelled", "canceled"
    ]

    private static func hasAny(_ text: String, _ needles: [String]) -> Bool {
        let t = text.lowercased()
        return needles.contains { t.contains($0) }
    }

    /// Pull the tool's usage hint out of an error like
    /// "unknown key 'exit' — not a QEMU qcode. Use e.g. ret, esc, tab" → "Use e.g. ret, esc, tab".
    static func extractHint(_ error: String) -> String? {
        let markers = ["use e.g.", "use one of", "search:", "expected one of", "expects one of",
                       "valid keys", "valid values", "valid options", "supported keys", "supported commands",
                       "available commands", "did you mean", "try one of", "one of:"]
        let lower = error.lowercased()
        for m in markers {
            guard let r = lower.range(of: m) else { continue }
            let start = error.index(error.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
            let tail = String(error[start...]).trimmingCharacters(in: .whitespaces)
            // Trim a trailing ellipsis / closing brace noise from the observation wrapper.
            let cleaned = tail.replacingOccurrences(of: "…", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " .\"}"))
            if cleaned.count >= 3 { return String(cleaned.prefix(200)) }
        }
        return nil
    }

    /// Classify a failed run. Priority: blocked → knowledgeGap (tool said how) → toolLimit (capability
    /// boundary, no hint / repeated) → taskBug (default; a real code/build error to repair).
    public static func classify(_ signals: FailureSignals) -> Verdict {
        if !signals.trajectory.isEmpty {
            let failedRecords = signals.trajectory.filter { !$0.success }

            if let denied = failedRecords.first(where: {
                hasAny($0.failureDetail ?? "", blockedPhrases)
            }) {
                let sameExecutableSucceeded = executableIdentity(denied).map { identity in
                    signals.trajectory.contains {
                        $0.success && executableIdentity($0) == identity
                    }
                } ?? false
                let suffix = sameExecutableSucceeded
                    ? "; the same executable already succeeded, so capability widening is forbidden"
                    : ""
                return Verdict(category: .authorization, confidence: 0.95,
                               evidence: "actual denial — \(denied.tool): \((denied.failureDetail ?? "").prefix(180))\(suffix)",
                               culpritTool: denied.tool, discoveryHint: nil)
            }

            if let stale = CompletionVerifier().invalidatedVerification(in: signals.trajectory) {
                return Verdict(category: .staleProof, confidence: 0.98,
                               evidence: stale.reason,
                               culpritTool: stale.lastPassedTool, discoveryHint: nil)
            }

            if let uncertain = signals.trajectory.last(where: {
                $0.observedEffects.mutation == .unknownTarget
                    || $0.observedEffects.mutationEvidence == .mayMutate
            }) {
                return Verdict(category: .uncertainMutation, confidence: 0.9,
                               evidence: "uncertain mutation receipt — \(uncertain.tool): \(uncertain.argsFingerprint.prefix(180))",
                               culpritTool: uncertain.tool, discoveryHint: nil)
            }

            if let refusal = failedRecords.first(where: {
                hasAny($0.failureDetail ?? "", schemaPhrases)
            }) {
                return Verdict(category: .schemaRefusal, confidence: 0.9,
                               evidence: "\(refusal.tool): \((refusal.failureDetail ?? "").prefix(180))",
                               culpritTool: refusal.tool, discoveryHint: nil)
            }
            if let toolchain = failedRecords.first(where: {
                hasAny($0.failureDetail ?? "", toolchainPhrases)
            }) {
                return Verdict(category: .toolchain, confidence: 0.88,
                               evidence: "\(toolchain.tool): \((toolchain.failureDetail ?? "").prefix(180))",
                               culpritTool: toolchain.tool, discoveryHint: nil)
            }
            if let infrastructure = failedRecords.first(where: {
                hasAny($0.failureDetail ?? "", infrastructurePhrases)
            }) {
                return Verdict(category: .infrastructure, confidence: 0.86,
                               evidence: "\(infrastructure.tool): \((infrastructure.failureDetail ?? "").prefix(180))",
                               culpritTool: infrastructure.tool, discoveryHint: nil)
            }
            if let code = failedRecords.first(where: {
                $0.observedEffects.verification == .buildOrTest
                    || hasAny($0.failureDetail ?? "", buildFailPhrases)
            }) {
                let sameExecutableSucceeded = executableIdentity(code).map { identity in
                    signals.trajectory.contains { $0.success && executableIdentity($0) == identity }
                } ?? false
                let suffix = sameExecutableSucceeded
                    ? "; same executable previously succeeded, so this is not a sandbox/capability failure"
                    : ""
                return Verdict(category: .codeOrTest, confidence: 0.88,
                               evidence: "\(code.tool): \((code.failureDetail ?? "").prefix(180))\(suffix)",
                               culpritTool: code.tool, discoveryHint: nil)
            }
        }

        // No tool ever failed → whatever went wrong is in the work itself (or an honest give-up). Repair path.
        guard !signals.toolFailures.isEmpty else {
            return Verdict(category: .taskBug, confidence: 0.4,
                           evidence: "no tool errors; treat as a task/build issue",
                           culpritTool: nil, discoveryHint: nil)
        }

        // 1) BLOCKED — authority, checked first so a denied action isn't read as a broken tool.
        if let f = signals.toolFailures.first(where: { hasAny($0.error, blockedPhrases) }) {
            return Verdict(category: .blocked, confidence: 0.9,
                           evidence: "\(f.tool): \(f.error.prefix(160))", culpritTool: f.tool, discoveryHint: nil)
        }

        // Tool calls that hit a capability boundary ("unknown …", "unsupported", "only cataloged …").
        let capabilityMisses = signals.toolFailures.filter { hasAny($0.error, capabilityMissPhrases) }

        // 2) KNOWLEDGE GAP — a capability-miss WHOSE ERROR TELLS THE MODEL HOW. The fix is to discover the
        //    real usage and retry, never to edit code. This is the piece that would have saved the perslis
        //    run (the tool literally said "search: win98_run_commands").
        if let f = capabilityMisses.first(where: { hasAny($0.error, hintPhrases) }) {
            return Verdict(category: .knowledgeGap, confidence: 0.85,
                           evidence: "\(f.tool): \(f.error.prefix(160))",
                           culpritTool: f.tool, discoveryHint: extractHint(f.error))
        }

        // 3) TOOL LIMIT — a capability-miss with NO usable hint, and either repeated on the same tool
        //    (the model tried variations and every one was refused) or the only failure. The tool genuinely
        //    can't; extending it is the only way forward.
        if !capabilityMisses.isEmpty {
            let byTool = Dictionary(grouping: capabilityMisses, by: { $0.tool })
            let repeated = byTool.first(where: { $0.value.count >= 2 })
            let f = repeated?.value.first ?? capabilityMisses[0]
            let conf = repeated != nil ? 0.85 : 0.6
            return Verdict(category: .toolLimit, confidence: conf,
                           evidence: "\(f.tool): \(f.error.prefix(160))"
                               + (repeated != nil ? " (\(repeated!.value.count) refused attempts)" : ""),
                           culpritTool: f.tool, discoveryHint: nil)
        }

        // 4) TASK BUG — a genuine build/test/code error we can repair by editing source.
        if let f = signals.toolFailures.first(where: { hasAny($0.error, buildFailPhrases) }) {
            return Verdict(category: .taskBug, confidence: signals.editedSource ? 0.85 : 0.7,
                           evidence: "\(f.tool): \(f.error.prefix(160))", culpritTool: f.tool, discoveryHint: nil)
        }

        // Fallback: a tool failed for a reason we can't categorize — treat as a task issue (safest: repair).
        let f = signals.toolFailures[0]
        return Verdict(category: .taskBug, confidence: 0.4,
                       evidence: "uncategorized tool error — \(f.tool): \(f.error.prefix(160))",
                       culpritTool: f.tool, discoveryHint: nil)
    }

    private static func executableIdentity(_ record: ActionRecord) -> String? {
        guard record.tool == "run_command" else { return nil }
        let fingerprint = record.argsFingerprint
        if fingerprint.hasPrefix("executable=") {
            return String(fingerprint.dropFirst("executable=".count).split(separator: "&", maxSplits: 1).first ?? "")
        }
        guard fingerprint.hasPrefix("command=") else { return nil }
        let command = fingerprint.dropFirst("command=".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return command.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "&" || $0 == "|" })
            .first.map(String.init)
    }
}
