import Foundation

/// Verify-before-done: the trust spine applied to the completion signal. The most corrosive agent failure
/// is "it said it was done but wasn't" — it edited code, never compiled or tested it, and claimed success.
///
/// This deterministic gate refuses that: if the run MUTATED code (edit/write/patch/move) but ran NO
/// SUCCESSFUL build/test command AFTER the last mutation, a "done" claim is UNVERIFIED, and the loop steers
/// the model to actually verify before finishing (nudged once, so it can't loop forever). It reuses the
/// trajectory the loop already records — grounded in what the agent actually DID, not what it claims.
public struct CompletionVerifier: Sendable {
    /// Compatibility projections only. Verification decisions use each record's argument-aware effect
    /// observation; these names cannot distinguish docs from source or `swift test` from `ls`.
    @available(*, deprecated, message: "Use ActionRecord.observedEffects")
    public static let mutatingTools = ToolEffectCatalog.knownMutationTools
    @available(*, deprecated, message: "Use ActionRecord.observedEffects")
    public static let verifyingTools = ToolEffectCatalog.knownCommandTools

    public enum Verdict: Sendable, Equatable {
        case accept
        case needsVerification(reason: String)
        public var isAccept: Bool { if case .accept = self { return true }; return false }
    }

    public init() {}

    /// Compatibility helper retained for internal callers/tests. The shared catalog owns classification.
    static func mutationNeedsBuild(_ r: ActionRecord) -> Bool {
        r.observedEffects.requiresBuildVerification
    }

    public func check(trajectory: [ActionRecord], canRunCommands: Bool,
                      expectedOutcome: TaskBrief.ExpectedOutcome? = nil,
                      taskIntent: TaskBrief.Intent? = nil) -> Verdict {
        // A failed final mutation attempt is not completion, even for a doc/config artifact that would not
        // otherwise require a build. A later successful mutation can recover from an earlier failed try.
        if let lastMutation = trajectory.last(where: { $0.observedEffects.mutation != .none }),
           !lastMutation.success {
            return .needsVerification(reason:
                "the last mutation failed — failed work cannot be accepted as complete")
        }

        // A build/fleet contract promises a state change. A zero-tool or read-only run must not fall
        // through the "no source mutation" branch and turn a model's `done` claim into success.
        let fulfilledMutationContract = trajectory.contains {
            $0.success && ($0.observedEffects.confirmsMutation
                || (taskIntent == .fleet && $0.observedEffects.progress == .delegation))
        }
        if expectedOutcome == .mutation, !fulfilledMutationContract {
            return .needsVerification(reason:
                "the turn expected a workspace mutation, but no successful mutation was recorded")
        }

        // Research is complete only when a successful tool observation records gathered/synthesized
        // evidence. A fluent answer with an empty or failed trajectory is still an unsupported claim.
        if expectedOutcome == .evidence,
           !trajectory.contains(where: {
               $0.success && ($0.observedEffects.progress == .research
                   || $0.observedEffects.progress == .evidence)
           }) {
            return .needsVerification(reason:
                "the turn expected research evidence, but no successful research or evidence observation was recorded")
        }

        // Desktop intent promises an action in another application/system, not merely a description of
        // what should happen. Only a successful, argument-aware external-state observation satisfies it.
        if expectedOutcome == .externalAction,
           !trajectory.contains(where: {
               $0.success && $0.observedEffects.progress == .externalState
           }) {
            return .needsVerification(reason:
                "the turn expected an external action, but no successful external-state change was recorded")
        }

        // No SOURCE-CODE (or unknown-target) mutation ⇒ nothing needs execution verification.
        guard let lastSourceMutation = trajectory.lastIndex(where: {
            $0.observedEffects.requiresBuildVerification
        }) else {
            return .accept
        }
        // A later doc/config mutation does not erase a failed source change. Conversely, a later successful
        // source mutation supersedes an earlier failed attempt and may be verified normally.
        guard trajectory[lastSourceMutation].success else {
            return .needsVerification(reason:
                "the last source mutation failed — a later command cannot make an unsuccessful edit complete")
        }

        // Was there a SUCCESSFUL build/test AFTER the last code change? TEETH: a bare successful
        // run_command is NOT enough — `ls`/`echo`/`cat` "passing" proves nothing. The command must
        // actually be a build / test / typecheck / lint, as classified once in its recorded effect. Resume
        // inserts an unconfirmed workspace boundary after pre-pause proof, so only proof after that boundary
        // appears in this slice.
        let after = trajectory[(lastSourceMutation + 1)...]
        let verified = after.contains {
            $0.success && $0.observedEffects.verification == .buildOrTest
        }
        if verified { return .accept }

        // EXTERNAL-ACTION turns (dogfood 2026-08-06): the "source" the agent wrote is a script destined
        // for another system — a guest VM's BAT/VBS, an automation payload — and there is no host
        // build/test for it. Its execution IN that system is its verification: accept when a successful
        // external-state action was recorded AFTER the last source change (grounded tool evidence, not a
        // model claim; the win98 round had vm_type/vm_ocr proof of the app running and still failed on a
        // build demand nothing could satisfy). Build/answer/mutation turns keep the strict demand below.
        if expectedOutcome == .externalAction,
           after.contains(where: { $0.success && $0.observedEffects.progress == .externalState }) {
            return .accept
        }

        // Shell-off used to silently ACCEPT source changes because the verifier could not execute. That is
        // precisely an unverified result: disclose it rather than upgrading absence of evidence to success.
        guard canRunCommands else {
            return .needsVerification(reason:
                "source code changed, but shell/build execution is unavailable, so completion is unverified")
        }
        // Distinguish "ran nothing" from "ran a non-verifying command" so the steer is honest.
        let ranSomething = after.contains {
            $0.success && $0.observedEffects.verification == .nonVerifyingCommand
        }
        let reason = ranSomething
            ? "you changed code and ran a command, but it wasn't a build/test — a passing build or test must confirm the change before this is done"
            : "you changed code but ran no build/test after the last edit — a build/test must pass before this is done"
        return .needsVerification(reason: reason)
    }

    /// The steer injected when a "done" is unverified.
    public static func steering(reason: String) -> String {
        if reason.contains("expected a workspace mutation") {
            return """
            Not done yet: \(reason).
            Perform the requested workspace change now with the write/edit/patch tools (or, for fleet work,
            actually delegate the work). If source code changes, then run the project's real build/tests.
            Do not claim completion until the promised work exists and its required verification passes.
            """
        }
        if reason.contains("expected research evidence") {
            return """
            Not done yet: \(reason).
            Gather concrete evidence with the available read, search, fetch, or research tools, then answer
            from those observations. Do not claim the research is complete from unsupported model recall.
            """
        }
        if reason.contains("expected an external action") {
            return """
            Not done yet: \(reason).
            Perform the requested external action with an available desktop/control tool and confirm that
            the tool succeeded. Do not report an action as completed when it was only described or inspected.
            """
        }
        return """
        Not done yet: \(reason).
        Run the project's REAL build and/or test command now (run_command) — e.g. `swift build` / `swift test`,
        `npm test`, `pytest`, `cargo test`, `go test`, `make`. A trivial command like `ls` or `echo` does NOT
        count. If it passes, THEN finish and say exactly what you ran. If it fails, fix it and re-run. Do not
        claim completion on unverified code changes.
        """
    }
}

/// Argument-aware shell classification shared by progress accounting and verify-before-done. It parses
/// command *segments* instead of substring-searching the whole shell string: `echo "swift test"` and
/// `grep 'npm test' README` are data, while `cd Package && swift test` executes a real verifier.
public enum CommandClassifier {
    private struct Segment {
        var words: [String]
        var outputPaths: [String]
    }

    /// Only `&&` preserves verifier evidence: when the whole command succeeds, every dependency in that
    /// chain necessarily succeeded. Every other composition operator can hide, skip, or replace a failing
    /// verifier and therefore fails closed.
    private enum Connector: Equatable {
        case and
        case or
        case sequence
        case pipeline
        case background
        case grouping
    }

    private struct ParsedCommand {
        var segments: [Segment]
        var connectors: [Connector]
    }

    private enum Lexeme {
        case word(String)
        case separator(Connector)
        case outputRedirect
        case inputRedirect
    }

    /// Classify a live `run_command` call without round-tripping its argv through a truncated fingerprint.
    public static func observe(arguments: [String: Any]) -> ToolEffectObservation {
        // Match RunCommandTool's execution precedence and accepted argument types exactly. If both
        // forms are present, the executor runs `executable`; inspecting `command` first could credit a
        // verifier that never ran. `cmd` is not an executor argument and therefore is not live evidence.
        let executable = arguments["executable"] as? String
        let command = arguments["command"] as? String
        if executable?.isEmpty == false, command?.isEmpty == false {
            return ToolEffectObservation(verification: .nonVerifyingCommand)
        }
        if let executable, !executable.isEmpty {
            let args = (arguments["args"] as? [String]) ?? []
            return observe(parsed: ParsedCommand(
                segments: [Segment(words: [executable] + args, outputPaths: [])], connectors: []))
        }
        if let command, !command.isEmpty {
            return observeCommand(command)
        }
        return ToolEffectObservation(verification: .nonVerifyingCommand)
    }

    /// Classify the stable legacy forms `command=<shell>` and `executable=<e>&args=[…]&cwd=<c>`.
    public static func observe(_ fingerprint: String) -> ToolEffectObservation {
        if fingerprint.hasPrefix("command=") {
            return observeCommand(String(fingerprint.dropFirst("command=".count)))
        }
        if fingerprint.hasPrefix("cmd=") {
            return observeCommand(String(fingerprint.dropFirst("cmd=".count)))
        }
        if fingerprint.contains("executable=") {
            let executable = fingerprintValue("executable", in: fingerprint)
            let args = decodedArray(fingerprintValue("args", in: fingerprint))
            return observe(parsed: ParsedCommand(
                segments: [Segment(words: [executable] + args, outputPaths: [])], connectors: []))
        }
        // Some oldest records stored only the raw command.
        return observeCommand(fingerprint)
    }

    public static func isBuildOrTest(_ text: String) -> Bool {
        observe(text).verification == .buildOrTest
    }

    private static func observeCommand(_ command: String) -> ToolEffectObservation {
        let observed = observe(parsed: parse(command))
        let mutation: ToolEffectObservation.Mutation =
            containsActiveCommandSubstitution(command) && observed.mutation == .none
                ? .unknownTarget : observed.mutation
        let verification: ToolEffectObservation.Verification =
            observed.verification == .buildOrTest && containsUnprovenShellExpansion(command)
                ? .nonVerifyingCommand : observed.verification
        guard mutation != observed.mutation || verification != observed.verification else { return observed }
        // `$()` / backticks execute another command whose expansions are intentionally not interpreted by
        // this bounded parser. Parameter/arithmetic/ANSI-C/glob expansion can likewise synthesize a
        // verifier flag after parsing (for example `$FLAGS` → `--skip-build`), so shell-expanded
        // verification fails closed and the model must use structured executable + literal args.
        return ToolEffectObservation(mutation: mutation, verification: verification,
                                     progress: observed.progress,
                                     mutationEvidence: mutation == observed.mutation
                                        ? observed.mutationEvidence : .mayMutate)
    }

    private static func observe(parsed: ParsedCommand) -> ToolEffectObservation {
        let verification: ToolEffectObservation.Verification = verifies(parsed)
            ? .buildOrTest : .nonVerifyingCommand
        let segments = expandedSegments(parsed.segments)
        let mutations = segments.map(mutation(in:))
        let mutation: ToolEffectObservation.Mutation
        if mutations.contains(.source) { mutation = .source }
        else if mutations.contains(.unknownTarget) { mutation = .unknownTarget }
        else if mutations.contains(.nonSource) { mutation = .nonSource }
        else { mutation = .none }
        // A shell argv predicts what may mutate; it does not prove that bytes changed. Only explicit tools
        // returning concrete outcome metadata can satisfy a promised workspace mutation.
        return ToolEffectObservation(mutation: mutation, verification: verification,
                                     mutationEvidence: mutation == .none
                                        ? ToolEffectObservation.MutationEvidence.none : .mayMutate)
    }

    /// A small shell lexer. Quotes preserve one word, operators delimit commands, comments are ignored,
    /// and output redirects are retained as mutation evidence. It intentionally does not execute or expand.
    private static func lex(_ command: String) -> [Lexeme] {
        let characters = Array(command)
        var result: [Lexeme] = []
        var word = ""
        var quote: Character?
        var index = 0
        func flushWord() {
            guard !word.isEmpty else { return }
            result.append(.word(word)); word = ""
        }
        while index < characters.count {
            let character = characters[index]
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else if activeQuote == "\"", character == "\\", index + 1 < characters.count {
                    index += 1; word.append(characters[index])
                } else {
                    word.append(character)
                }
                index += 1
                continue
            }
            switch character {
            case "'", "\"":
                quote = character
            case "\\":
                if index + 1 < characters.count { index += 1; word.append(characters[index]) }
            case " ", "\t", "\r":
                flushWord()
            case "\n", ";":
                flushWord(); result.append(.separator(.sequence))
            case "|":
                flushWord()
                if index + 1 < characters.count, characters[index + 1] == "|" {
                    result.append(.separator(.or)); index += 1
                } else {
                    result.append(.separator(.pipeline))
                }
            case "(", ")":
                flushWord(); result.append(.separator(.grouping))
            case "&":
                flushWord()
                if index + 1 < characters.count, characters[index + 1] == ">" {
                    result.append(.outputRedirect); index += 1
                } else {
                    if index + 1 < characters.count, characters[index + 1] == "&" {
                        result.append(.separator(.and)); index += 1
                    } else {
                        result.append(.separator(.background))
                    }
                }
            case ">":
                // A numeric word immediately before `>` is a file descriptor, not an argument.
                if !word.isEmpty, word.allSatisfy(\.isNumber) { word = "" } else { flushWord() }
                if index + 2 < characters.count, characters[index + 1] == "&",
                   characters[index + 2].isNumber || characters[index + 2] == "-" {
                    // Descriptor duplication/closure (`2>&1`, `>&-`) does not write a filesystem path.
                    index += 2
                    while index + 1 < characters.count, characters[index + 1].isNumber { index += 1 }
                } else {
                    result.append(.outputRedirect)
                    if index + 1 < characters.count, characters[index + 1] == ">" { index += 1 }
                }
            case "<":
                flushWord(); result.append(.inputRedirect)
                if index + 1 < characters.count, characters[index + 1] == "<" { index += 1 }
            case "#":
                // `#` begins a comment only at a token boundary. Embedded hashes remain ordinary text.
                if word.isEmpty {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    // Leave the newline itself to the normal lexer path. A trailing comment does not turn
                    // a simple command into a sequence; a following line does.
                    if index < characters.count { index -= 1 }
                } else {
                    word.append(character)
                }
            default:
                word.append(character)
            }
            index += 1
        }
        flushWord()
        return result
    }

    private static func parse(_ command: String) -> ParsedCommand {
        var segments: [Segment] = []
        var connectors: [Connector] = []
        var words: [String] = []
        var outputs: [String] = []
        var redirect: Lexeme?
        func flush() {
            if !words.isEmpty || !outputs.isEmpty {
                segments.append(Segment(words: words, outputPaths: outputs))
            }
            words.removeAll(keepingCapacity: true)
            outputs.removeAll(keepingCapacity: true)
            redirect = nil
        }
        for token in lex(command) {
            switch token {
            case .word(let value):
                if let pending = redirect {
                    if case .outputRedirect = pending { outputs.append(value) }
                    redirect = nil
                } else {
                    words.append(value)
                }
            case .outputRedirect, .inputRedirect:
                redirect = token
            case .separator(let connector):
                if redirect != nil { outputs.append("") }
                flush()
                connectors.append(connector)
            }
        }
        if redirect != nil { outputs.append("") }
        flush()
        return ParsedCommand(segments: segments, connectors: connectors)
    }

    /// `sh -c '…'` and `eval '…'` contain an actual nested command, not merely quoted prose. Expand those
    /// explicit execution positions while leaving quoted arguments to echo/grep/etc. as inert data.
    private static func expandedSegments(_ input: [Segment], depth: Int = 0) -> [Segment] {
        guard depth < 3 else { return input }
        var result: [Segment] = []
        for segment in input {
            result.append(segment)
            let words = unwrapped(segment.words)
            guard let executable = words.first.map(executableName) else { continue }
            let args = Array(words.dropFirst())
            if ["sh", "bash", "zsh", "dash", "ksh"].contains(executable),
               let flag = args.firstIndex(of: "-c"), flag + 1 < args.count {
                result.append(contentsOf: expandedSegments(parse(args[flag + 1]).segments, depth: depth + 1))
            } else if executable == "eval", !args.isEmpty {
                result.append(contentsOf: expandedSegments(
                    parse(args.joined(separator: " ")).segments, depth: depth + 1))
            }
        }
        return result
    }

    /// Strip shell control words, env assignments, and transparent launch wrappers to expose the command
    /// whose argv actually determines whether work was verified or mutated.
    private static func unwrapped(_ original: [String]) -> [String] {
        var words = original
        func dropOptionsAndAssignments() {
            while let first = words.first, first.hasPrefix("-") || isAssignment(first) {
                words.removeFirst()
            }
        }
        while let first = words.first {
            let command = executableName(first)
            // `!` is deliberately NOT transparent: in a shell it inverts the child's status, so
            // `! swift test` succeeds precisely when the tests fail and can never be verification.
            if isAssignment(first) || ["if", "then", "do", "while", "until", "exec", "nohup"].contains(command) {
                words.removeFirst(); continue
            }
            switch command {
            case "env", "command", "builtin":
                words.removeFirst(); dropOptionsAndAssignments(); continue
            case "time":
                words.removeFirst(); dropOptionsAndAssignments(); continue
            case "sudo", "doas":
                words.removeFirst(); dropOptionsAndAssignments(); continue
            case "nice":
                words.removeFirst()
                if words.first == "-n" { words.removeFirst(); if !words.isEmpty { words.removeFirst() } }
                dropOptionsAndAssignments(); continue
            case "timeout", "gtimeout":
                words.removeFirst(); dropOptionsAndAssignments()
                if !words.isEmpty { words.removeFirst() } // duration
                continue
            default:
                return words
            }
        }
        return words
    }

    private static func verifies(_ parsed: ParsedCommand, depth: Int = 0) -> Bool {
        guard depth < 3, parsed.connectors.allSatisfy({ $0 == .and }) else { return false }
        return parsed.segments.contains { verifies($0, depth: depth) }
    }

    private static func verifies(_ segment: Segment, depth: Int) -> Bool {
        guard !containsWrapperInspection(segment.words) else { return false }
        guard let words = verificationWords(segment.words) else { return false }
        guard let first = words.first else { return false }
        let executable = executableName(first)
        let args = Array(words.dropFirst())
        if ["sh", "bash", "zsh", "dash", "ksh"].contains(executable) {
            // Only the direct execution form proves the nested command ran. `sh -n -c ...` syntax-checks
            // without executing, and exit-early options such as `--help` can otherwise launder proof.
            guard args.first == "-c", args.count >= 2 else { return false }
            return verifies(parse(args[1]), depth: depth + 1)
        }
        // `eval` performs another parse after shell expansion. It is deliberately not verifier evidence:
        // statically accepting it would re-open operator and substitution bypasses.
        guard executable != "eval" else { return false }
        return verifiesSimple(segment)
    }

    private static func verifiesSimple(_ segment: Segment) -> Bool {
        guard !containsWrapperInspection(segment.words) else { return false }
        guard let words = verificationWords(segment.words) else { return false }
        guard let first = words.first else { return false }
        let executable = executableName(first)
        let rawArgs = Array(words.dropFirst())
        let args = rawArgs.map { $0.lowercased() }
        let firstArg = args.first ?? ""
        let verificationTargets: Set<String> = ["test", "tests", "build", "check", "lint", "typecheck", "verify"]

        // Help/version/configuration discovery can exit zero without compiling or exercising the project.
        // Keep this centralized so every otherwise-recognized verifier fails closed on introspection.
        let commonIntrospection: Set<String> = [
            "--help", "-help", "-h", "--version", "help", "version", "--usage", "-usage",
        ]
        if args.contains(where: commonIntrospection.contains) || rawArgs.contains("-V") { return false }

        switch executable {
        case "swift":
            let swiftExitEarly = args.contains {
                ($0.hasPrefix("--show-") && $0.hasSuffix("-path"))
                    || ($0.hasPrefix("--print-") && $0.hasSuffix("graph"))
            }
            return (firstArg == "build" || firstArg == "test")
                && !args.contains("--list-tests") && !args.contains("--skip-build")
                && !args.contains("--show-bin-path") && !args.contains("--print-target-info")
                && !swiftExitEarly
                && !(firstArg == "test" && args.dropFirst().first == "list")
        case "xcodebuild":
            let inspectionFlags: Set<String> = [
                "-list", "-version", "-showbuildsettings", "-showsdks", "-showdestinations",
            ]
            guard !args.contains(where: inspectionFlags.contains),
                  !args.contains("test-without-building") else { return false }
            let actions: Set<String> = [
                "build", "test", "analyze", "archive", "install", "build-for-testing",
            ]
            // A truly argument-free invocation defaults to `build`. Once arguments are present, require
            // an explicit build action: xcodebuild also has successful maintenance/status modes such as
            // `-checkFirstLaunchStatus` and `-license check` that execute no project workload.
            return args.isEmpty || args.contains(where: actions.contains)
        case "npm":
            guard !args.contains("--if-present") else { return false }
            return firstArg == "test" || (firstArg == "run" && args.dropFirst().first.map(verificationTargets.contains) == true)
        case "yarn", "pnpm":
            guard !args.contains("--if-present") else { return false }
            return verificationTargets.contains(firstArg)
                || (firstArg == "run" && args.dropFirst().first.map(verificationTargets.contains) == true)
        case "go": return ["test", "build", "vet"].contains(firstArg) && !rawArgs.contains("-n")
        case "cargo": return ["test", "build", "check", "clippy"].contains(firstArg)
        case "make", "gmake":
            if args.contains(where: {
                ["-n", "--dry-run", "--just-print", "--recon", "-q", "--question",
                 "-t", "--touch"].contains($0)
            }) {
                return false
            }
            return args.isEmpty || args.contains(where: verificationTargets.contains)
        case "gradle", "gradlew":
            guard !args.contains("--dry-run"), !rawArgs.contains("-m") else { return false }
            let metaTasks: Set<String> = [
                "help", "tasks", "projects", "properties", "dependencies", "dependencyinsight",
                "components", "model", "buildenvironment", "outgoingvariants",
                "resolvableconfigurations",
            ]
            guard !args.contains(where: metaTasks.contains) else { return false }
            return args.contains { target in
                verificationTargets.contains(target) || target.hasSuffix("test") || target.hasSuffix("build")
            }
        case "mvn", "mvnw":
            guard !args.contains("--fail-never"), !args.contains("-fn"),
                  !args.contains(where: { flag in
                      flag.hasPrefix("-dmaven.test.failure.ignore")
                          || flag.hasPrefix("-dtestfailureignore")
                  }) else { return false }
            return ["test", "verify", "package", "compile"].contains(firstArg)
        case "dotnet":
            return (firstArg == "test" || firstArg == "build")
                && !args.contains("--no-build") && !args.contains("--list-tests")
        case "cmake":
            guard firstArg == "--build" else { return false }
            for spelling in ["--target", "-t"] {
                if let target = args.firstIndex(of: spelling), target + 1 < args.count,
                   ["help", "clean"].contains(args[target + 1]) { return false }
            }
            if args.contains(where: {
                $0 == "--target=help" || $0 == "--target=clean" || $0 == "-thelp" || $0 == "-tclean"
            }) { return false }
            if let native = args.firstIndex(of: "--"), args[(native + 1)...].contains(where: {
                ["-n", "--dry-run", "--just-print", "--recon"].contains($0)
            }) { return false }
            return true
        case "bazel", "bazelisk":
            return (firstArg == "test" || firstArg == "build") && !args.contains("--nobuild")
        case "ruby":
            return firstArg == "-c" && rawArgs.count >= 2
                && validSyntaxTarget(rawArgs[1], extensions: ["rb"], basenames: ["gemfile", "rakefile"])
        case "node":
            return firstArg == "--check" && rawArgs.count >= 2
                && validSyntaxTarget(rawArgs[1], extensions: ["js", "cjs", "mjs"])
        case "python", "python3":
            guard args.count >= 2, args[0] == "-m",
                  ["pytest", "unittest", "mypy", "ruff", "flake8", "tox"].contains(args[1]) else {
                return false
            }
            // `python -m tool` must obey the exact same action/flag rules as the direct executable.
            return verifiesSimple(Segment(words: [rawArgs[1]] + Array(rawArgs.dropFirst(2)),
                                          outputPaths: segment.outputPaths))
        case "pytest", "py.test":
            let discovery: Set<String> = [
                "--collect-only", "--co", "--fixtures", "--fixtures-per-test", "--markers", "--setup-plan",
            ]
            return !args.contains(where: discovery.contains)
        case "tsc":
            return !args.contains("--showconfig") && !args.contains("-v")
                && !args.contains("--init") && !args.contains("--listfilesonly")
                && !args.contains("--dry") && !args.contains("--clean")
        case "jest":
            return !args.contains("--listtests") && !args.contains("--showconfig")
                && !args.contains("--clearcache")
        case "ctest":
            return !rawArgs.contains("-N") && !args.contains("--print-labels")
                && !args.contains(where: { $0 == "--show-only" || $0.hasPrefix("--show-only=") })
        case "vitest":
            return firstArg != "list" && !args.contains("--list")
        case "rspec":
            return !args.contains("--dry-run") && !args.contains("--init")
        case "phpunit":
            let listing: Set<String> = ["--list-tests", "--list-tests-xml", "--list-groups", "--list-suites"]
            return !args.contains(where: listing.contains)
        case "eslint":
            return !args.contains("--print-config") && !args.contains("--env-info")
        case "ruff":
            guard !args.contains("--show-settings"), !args.contains("--show-files") else { return false }
            if firstArg == "check" { return true }
            return firstArg == "format" && args.contains("--check")
        case "gcc", "clang", "g++":
            let sourceExtensions: Set<String> = [
                "c", "cc", "cp", "cpp", "cxx", "m", "mm", "s", "asm", "f", "f90", "f95",
            ]
            return rawArgs.contains {
                isRelativeProjectPath($0)
                    && sourceExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
            }
        case "cobc":
            // Compiling a COBOL source IS the build (2026-08-06 dogfood: a correct payroll app
            // compiled clean with `cobc -x -o PAYROLL PAYROLL.CBL` after the final edit and was
            // still reported "unverified" — the exact nasm lesson below, one compiler later).
            // A bare version/help query (no source input) is not a build.
            let cobolExtensions: Set<String> = ["cbl", "cob", "cobol", "cpy"]
            return rawArgs.contains {
                isRelativeProjectPath($0)
                    && cobolExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
            }
        case "nasm", "yasm", "as", "ml", "ml64", "tasm", "wasm":
            // Assembling a source file IS the build for a DOS/asm project (2026-08-04 dogfood: a
            // correct hello.com was reported "unverified" because `nasm hello.asm` wasn't recognized).
            // A bare version/help query (no source input) is not a build.
            let asmExtensions: Set<String> = ["asm", "s", "nas", "inc", "a51"]
            return rawArgs.contains {
                isRelativeProjectPath($0)
                    && asmExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased())
            }
        case "flake8":
            return !args.contains("--bug-report")
        case "rubocop":
            let nonRunModes: Set<String> = [
                "--init", "--auto-gen-config", "--show-cops", "--show-docs-url",
                "--server-status", "--start-server", "--stop-server", "--restart-server", "--lsp",
            ]
            return !args.contains(where: nonRunModes.contains)
        case "pre-commit":
            return firstArg == "run"
        case "tox":
            let nonRunModes: Set<String> = ["list", "config", "devenv", "quickstart", "exec"]
            guard !nonRunModes.contains(firstArg), !args.contains("-l"), !args.contains("-a") else {
                return false
            }
            return !args.contains(where: { flag in
                flag == "--showconfig" || flag.hasPrefix("--showconfig=")
                    || flag.hasPrefix("--listenvs") || flag.hasPrefix("--print-deps")
            })
        case "unittest", "mypy", "clippy":
            return true
        default:
            return false
        }
    }

    /// `command -v/-V` inspects command availability; it does not execute the following tokens. This
    /// check runs before transparent-wrapper removal, including through a leading `env` wrapper.
    private static func containsWrapperInspection(_ original: [String]) -> Bool {
        for index in original.indices where executableName(original[index]) == "command" {
            var cursor = original.index(after: index)
            while cursor < original.endIndex, original[cursor].hasPrefix("-") {
                if original[cursor] == "-v" || original[cursor] == "-V" { return true }
                cursor = original.index(after: cursor)
            }
        }
        return false
    }

    /// Expose the executable behind transparent launch wrappers, but only when every consumed option is
    /// known to preserve child execution. The old generic "drop every dash option" rule turned
    /// `env --help swift test` and similar exit-early wrapper modes into fake passing tests.
    private static func verificationWords(_ original: [String]) -> [String]? {
        var words = original
        func dropAssignments() {
            while let first = words.first, isAssignment(first) { words.removeFirst() }
        }
        dropAssignments()
        while let first = words.first {
            // Classification is based on a small trusted basename vocabulary. Stripping an arbitrary
            // path first would let `/repo/swift` (or `/repo/env`) impersonate a verifier/wrapper while
            // executing unrelated code. Runtime path resolution is not part of this evidence record.
            guard isBareExecutableToken(first) else { return nil }
            switch executableName(first) {
            case "!", "if", "then", "do", "while", "until":
                return nil
            case "exec", "nohup":
                words.removeFirst()
                if words.first == "--" { words.removeFirst() }
                if words.first?.hasPrefix("-") == true { return nil }
            case "env":
                words.removeFirst()
                while let option = words.first {
                    if isAssignment(option) { words.removeFirst(); continue }
                    if option == "--" { words.removeFirst(); break }
                    if option == "-i" || option == "--ignore-environment" {
                        words.removeFirst(); continue
                    }
                    if option == "-u" {
                        guard words.count >= 2 else { return nil }
                        words.removeFirst(2); continue
                    }
                    if option.hasPrefix("--unset=") { words.removeFirst(); continue }
                    if option.hasPrefix("-") { return nil }
                    break
                }
            case "command":
                words.removeFirst()
                while let option = words.first, option.hasPrefix("-") {
                    guard option == "-p" || option == "--" else { return nil }
                    words.removeFirst()
                }
            case "builtin":
                words.removeFirst()
                if words.first?.hasPrefix("-") == true { return nil }
            case "time":
                words.removeFirst()
                while let option = words.first, option.hasPrefix("-") {
                    guard option == "-p" || option == "--" else { return nil }
                    words.removeFirst()
                }
            case "sudo", "doas":
                words.removeFirst()
                if words.first?.hasPrefix("-") == true { return nil }
            case "nice":
                words.removeFirst()
                if words.first == "-n" {
                    guard words.count >= 2 else { return nil }
                    words.removeFirst(2)
                } else if let option = words.first, option.hasPrefix("--adjustment=") {
                    words.removeFirst()
                } else if let option = words.first, option.hasPrefix("-") {
                    guard Int(option) != nil else { return nil }
                    words.removeFirst()
                }
            case "timeout", "gtimeout":
                words.removeFirst()
                guard let duration = words.first, !duration.hasPrefix("-") else { return nil }
                words.removeFirst()
            default:
                return words
            }
            dropAssignments()
        }
        return words
    }

    private static func isBareExecutableToken(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("/") && !value.contains("\\")
    }

    private static func isRelativeProjectPath(_ path: String) -> Bool {
        guard !path.isEmpty, path != "-", !path.hasPrefix("/"), !path.hasPrefix("../") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func validSyntaxTarget(_ path: String, extensions: Set<String>,
                                          basenames: Set<String> = []) -> Bool {
        guard isRelativeProjectPath(path) else { return false }
        let url = URL(fileURLWithPath: path)
        return extensions.contains(url.pathExtension.lowercased())
            || basenames.contains(url.lastPathComponent.lowercased())
    }

    private static func mutation(in segment: Segment) -> ToolEffectObservation.Mutation {
        var observed = mutationForPaths(segment.outputPaths)
        let words = unwrapped(segment.words)
        guard let first = words.first else { return observed }
        let executable = executableName(first)
        let args = Array(words.dropFirst())
        var semanticsKnown = true

        func merge(_ candidate: ToolEffectObservation.Mutation) {
            observed = mergedMutation(observed, candidate)
        }
        func operands(_ values: [String]) -> [String] {
            values.filter { !$0.isEmpty && !$0.hasPrefix("-") && !isAssignment($0) }
        }

        switch executable {
        case "git":
            let verb = args.first?.lowercased() ?? ""
            if ["apply", "am", "checkout", "restore", "reset", "clean", "merge", "rebase",
                "cherry-pick", "revert", "pull"].contains(verb) { merge(.unknownTarget) }
            else if ["add", "commit", "fetch", "tag", "stash"].contains(verb) { merge(.nonSource) }
            else if !["status", "diff", "log", "show", "rev-parse", "ls-files", "grep", "blame"].contains(verb) {
                merge(.unknownTarget)
            }
        case "patch":
            merge(.unknownTarget)
        case "sed":
            if args.contains(where: { $0 == "-i" || $0.hasPrefix("-i") }) {
                merge(mutationForPaths(Array(operands(args).suffix(1))))
            } else { merge(.unknownTarget) } // sed scripts can use the `w` command to create files
        case "perl", "ruby":
            if args.contains(where: { $0.hasPrefix("-") && $0.dropFirst().contains("i") }) {
                merge(.unknownTarget)
            } else if !verifiesSimple(segment) { merge(.unknownTarget) }
        case "python", "python3":
            let lower = args.map { $0.lowercased() }
            if lower.count >= 2, lower[0] == "-m", lower[1] == "ruff",
               ruffMutates(Array(lower.dropFirst(2))) {
                merge(.unknownTarget)
            } else if !verifiesSimple(segment) { merge(.unknownTarget) }
        case "node":
            if !verifiesSimple(segment) { merge(.unknownTarget) }
        case "sh", "bash", "zsh", "dash", "ksh", "eval":
            // `-c`/eval payloads are expanded into additional segments above. A script path remains
            // arbitrary executable code and therefore unknown.
            if executable != "eval" && !args.contains("-c") { merge(.unknownTarget) }
        case "cp", "install", "rsync":
            merge(mutationForPaths(Array(operands(args).suffix(1))))
        case "mv", "rm", "unlink", "touch", "truncate", "ln":
            merge(mutationForPaths(operands(args)))
        case "mkdir", "rmdir":
            merge(.nonSource)
        case "tee":
            let paths = operands(args).filter { $0 != "/dev/null" }
            if !paths.isEmpty { merge(mutationForPaths(paths)) }
        case "dd":
            let paths = args.compactMap { $0.hasPrefix("of=") ? String($0.dropFirst(3)) : nil }
            if !paths.isEmpty { merge(mutationForPaths(paths)) }
        case "find":
            if args.contains("-delete") || args.contains("-exec") || args.contains("-execdir") {
                merge(.unknownTarget)
            }
        case "xargs":
            // Input supplies additional target paths, so even a recognizable nested mutator has an
            // unknowable target at classification time.
            let lower = args.map { executableName($0) }
            if lower.contains(where: explicitMutatorExecutables.contains) { merge(.unknownTarget) }
            else { merge(.unknownTarget) } // the command receives targets from stdin, outside this argv
        case "swiftformat", "gofmt", "black", "prettier":
            merge(.unknownTarget)
        case "eslint":
            // `--fix-dry-run` computes fixes without writing them and remains a valid lint oracle.
            // A real `--fix` can rewrite any linted source, so it needs a later, separate verifier.
            if enabledBooleanFlag("--fix", in: args) { merge(.unknownTarget) }
        case "ruff":
            if ruffMutates(args) { merge(.unknownTarget) }
        case "rubocop":
            if args.contains(where: { ["-a", "-A", "--autocorrect", "--autocorrect-all",
                                      "--auto-gen-config"].contains($0) }) {
                merge(.unknownTarget)
            }
        case "go":
            if args.first?.lowercased() == "fmt" { merge(.unknownTarget) }
            else if !verifiesSimple(segment) { merge(.unknownTarget) }
        case "cargo":
            let lower = args.map { $0.lowercased() }
            if lower.first == "fmt"
                || (lower.first == "clippy" && enabledBooleanFlag("--fix", in: lower)) {
                merge(.unknownTarget)
            }
            else if !verifiesSimple(segment) { merge(.unknownTarget) }
        case "jest":
            if args.contains(where: { flag in
                let lower = flag.lowercased()
                return lower == "-u" || enabledBooleanFlag("--updatesnapshot", in: [lower])
            }) { merge(.unknownTarget) }
        case "vitest":
            if args.contains(where: { flag in
                let lower = flag.lowercased()
                return lower == "-u" || enabledBooleanFlag("--update", in: [lower])
                    || enabledBooleanFlag("--update-snapshot", in: [lower])
            }) { merge(.unknownTarget) }
        case "pre-commit":
            // Hooks are arbitrary project programs and commonly rewrite files (formatters, generated
            // snapshots, lockfiles). Even a successful run cannot prove it left the workspace unchanged.
            if args.first?.lowercased() == "run" { merge(.unknownTarget) }
        default:
            semanticsKnown = knownReadOnlyExecutables.contains(executable) || verifiesSimple(segment)
        }
        if !semanticsKnown {
            // A project-local script or newly added executable can mutate source even when its name is
            // unfamiliar. Unknown-by-default closes that extension point while explicit inspection tools
            // remain read-only above.
            merge(.unknownTarget)
        }
        return observed
    }

    private static func ruffMutates(_ rawArgs: [String]) -> Bool {
        let args = rawArgs.map { $0.lowercased() }
        if args.contains("--fix") || args.contains("--fix-only") { return true }
        return args.contains("format") && !args.contains("--check")
    }

    private static func enabledBooleanFlag(_ name: String, in rawArgs: [String]) -> Bool {
        let normalizedName = name.lowercased()
        return rawArgs.contains { raw in
            let value = raw.lowercased()
            return value == normalizedName || value == normalizedName + "=true"
        }
    }

    private static let explicitMutatorExecutables: Set<String> = [
        "git", "patch", "sed", "perl", "ruby", "cp", "mv", "rm", "touch", "truncate", "tee",
        "dd", "install", "rsync", "swiftformat", "gofmt", "black", "prettier",
    ]

    private static let knownReadOnlyExecutables: Set<String> = [
        "ls", "pwd", "rg", "grep", "egrep", "fgrep", "cat", "head", "tail", "less", "more", "wc",
        "stat", "file", "which", "whereis", "type", "printenv", "echo", "printf", "true", "false",
        "test", "[", "uname", "date", "whoami", "id", "du", "df", "sort", "uniq", "cut", "tr",
        "jq", "readlink", "realpath", "basename", "dirname", "diff", "cmp", "md5", "shasum", "sha256sum",
        "cd", "export", "unset", "set", "ulimit",
        // Binary/artifact inspection — read-only, the shape a build VERIFIES itself with (2026-08-04
        // dogfood: `strings hello.com` was misread as a mutation, becoming the "last edit" so the
        // build before it was never credited). None of these write their input.
        "strings", "xxd", "od", "hexdump", "nm", "objdump", "otool", "readelf", "size",
        "base64", "cksum", "sha1sum", "sha512sum", "b2sum", "tac", "nl", "column", "comm",
        "join", "paste", "fold", "expand", "unexpand", "tabs",
    ]

    /// Raw-shell expansion happens after this parser sees the argv. It can synthesize an exit-early flag
    /// such as `--skip-build`, so an otherwise-recognizable verifier is not evidence when any argument is
    /// still shell-computed. Single-quoted literals (and escaped metacharacters) remain provably inert.
    /// A single-quoted `sh -c` payload becomes active in the nested shell, so inspect those recursively.
    private static func containsUnprovenShellExpansion(_ command: String, depth: Int = 0) -> Bool {
        if containsActiveExpansionInCurrentShell(command) { return true }
        guard depth < 3 else { return false }
        for segment in parse(command).segments {
            guard let words = verificationWords(segment.words),
                  let first = words.first,
                  ["sh", "bash", "zsh", "dash", "ksh"].contains(executableName(first)) else {
                continue
            }
            let args = Array(words.dropFirst())
            if args.first == "-c", args.count >= 2,
               containsUnprovenShellExpansion(args[1], depth: depth + 1) {
                return true
            }
        }
        return false
    }

    private static func containsActiveExpansionInCurrentShell(_ command: String) -> Bool {
        let characters = Array(command)
        var singleQuoted = false
        var doubleQuoted = false
        var index = 0
        let specialParameters: Set<Character> = ["@", "*", "#", "?", "-", "$", "!", "0"]
        while index < characters.count {
            let character = characters[index]
            if character == "\\" { index += 2; continue }
            if character == "'", !doubleQuoted { singleQuoted.toggle(); index += 1; continue }
            if character == "\"", !singleQuoted { doubleQuoted.toggle(); index += 1; continue }
            guard !singleQuoted else { index += 1; continue }

            if character == "`" { return true }
            if character == "$", index + 1 < characters.count {
                let next = characters[index + 1]
                if next == "(" || next == "{" || next == "'" || next == "\""
                    || next == "_" || next.isLetter || next.isNumber
                    || specialParameters.contains(next) {
                    return true
                }
            }
            // Filename generation is inactive inside double quotes; outside them even a currently
            // unmatched pattern is environment-dependent and therefore not proof-grade argv.
            if !doubleQuoted, character == "*" || character == "?" || character == "[" {
                return true
            }
            index += 1
        }
        return false
    }

    /// Command substitution is executable syntax outside single quotes. We do not attempt shell expansion;
    /// its presence simply upgrades an otherwise read-only outer command to unknown/may-mutate.
    private static func containsActiveCommandSubstitution(_ command: String) -> Bool {
        let characters = Array(command)
        var singleQuoted = false
        var doubleQuoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\" { index += 2; continue }
            if character == "'", !doubleQuoted { singleQuoted.toggle(); index += 1; continue }
            if character == "\"", !singleQuoted { doubleQuoted.toggle(); index += 1; continue }
            if !singleQuoted {
                if character == "`" { return true }
                if character == "$", index + 1 < characters.count, characters[index + 1] == "(",
                   !(index + 2 < characters.count && characters[index + 2] == "(") {
                    return true
                }
            }
            index += 1
        }
        return false
    }

    private static func mutationForPaths(_ paths: [String]) -> ToolEffectObservation.Mutation {
        guard !paths.isEmpty else { return .none }
        let effects = paths.map(ToolEffectCatalog.mutationKind(forPath:))
        if effects.contains(.source) { return .source }
        if effects.contains(.unknownTarget) { return .unknownTarget }
        if effects.contains(.nonSource) { return .nonSource }
        return .none
    }

    private static func mergedMutation(_ lhs: ToolEffectObservation.Mutation,
                                       _ rhs: ToolEffectObservation.Mutation) -> ToolEffectObservation.Mutation {
        if lhs == .source || rhs == .source { return .source }
        if lhs == .unknownTarget || rhs == .unknownTarget { return .unknownTarget }
        if lhs == .nonSource || rhs == .nonSource { return .nonSource }
        return .none
    }

    private static func executableName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent.lowercased()
    }

    private static func isAssignment(_ value: String) -> Bool {
        guard let equals = value.firstIndex(of: "="), equals != value.startIndex else { return false }
        let name = value[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Pull a value out of the legacy `k=v&…` form. The writer places cwd after args, so stop there.
    static func fingerprintValue(_ key: String, in fingerprint: String) -> String {
        guard let start = fingerprint.range(of: key + "=") else { return "" }
        let suffix = fingerprint[start.upperBound...]
        if key == "args", let end = suffix.range(of: "&cwd=") { return String(suffix[..<end.lowerBound]) }
        if let end = suffix.firstIndex(of: "&") { return String(suffix[..<end]) }
        return String(suffix)
    }

    private static func decodedArray(_ text: String) -> [String] {
        if let data = text.data(using: .utf8),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return result
        }
        return text
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) }
            .filter { !$0.isEmpty }
    }
}
